// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IENSIP15} from "./IENSIP15.sol";
import {ENSNormalizeSpec as Spec} from "./generated/ENSNormalizeData.sol";

/// @title ENSNormalize
/// @notice ENSIP-15 label normalization.
/// @dev A port of the label validation in adraffy/ens-normalize.ts, using tables derived from
///      adraffy/ens-normalize-derive (scripts/make.ts). The tables live in immutable data contracts
///      (code read with EXTCODECOPY). There is no owner: a new spec is a new deployment.
///
///      normalize(label):
///      1. decode UTF-8
///      2. tokenize: longest emoji match, else valid / mapped / ignored / disallowed
///      3. NFC each text run
///      4. validate: underscore, label extension, combining marks, fenced, group, NSM, whole-script confusables
///      5. encode UTF-8
contract ENSNormalize is IENSIP15 {
    /// @dev A data contract doesn't match the spec.
    error InvalidData(uint256 index);

    // class record (scripts/make.ts)
    uint256 private constant C_MASK = 0xff; // index into MASKS
    uint256 private constant C_RANK_SHIFT = 8; // 6 bits
    uint256 private constant C_QC = 1 << 14;
    uint256 private constant C_CM = 1 << 15;
    uint256 private constant C_NSM = 1 << 16;
    uint256 private constant C_CONFUSED = 1 << 17;
    uint256 private constant C_UNIQUE = 1 << 18;
    uint256 private constant C_DECOMP = 1 << 19;
    uint256 private constant C_EMOJI_SHIFT = 20; // 6 bits
    uint256 private constant C_VALID = 1 << 26;
    uint256 private constant C_IGNORED = 1 << 27;
    uint256 private constant C_FENCED = 1 << 28;
    /// @dev _lookup(): the cp is mapped, the low 15 bits are its offset in MAP.
    uint256 private constant MAPPED = 1 << 31;

    // buffer entry: cp | class << 24 | flags
    uint256 private constant CP_MASK = 0xffffff;
    uint256 private constant CLASS_SHIFT = 24;
    uint256 private constant RANK_SHIFT = 32; // CLASS_SHIFT + C_RANK_SHIFT
    uint256 private constant EMOJI_BIT = 1 << 255; // part of an emoji token
    uint256 private constant COMPOSED_BIT = 1 << 254; // class must be looked up again

    // per-call cache, see _lookup() and _maskAll()
    uint256 private constant CTX_BUCKET0 = 0x000; // [tag][bucket 0 runs: 769 bytes]
    uint256 private constant CTX_BUCKET = 0x340; // [tag][last bucket runs]
    uint256 private constant CTX_CLASS = 0x680; // 16 x [tag << 32 | class record]
    uint256 private constant CTX_MASK = 0x880; // [tag][mask]
    uint256 private constant CTX_SIZE = 0x8c0;

    // SWAR
    uint256 private constant LANES = 0x0001000100010001000100010001000100010001000100010001000100010001;
    uint256 private constant BYTES = 0x00ff00ff00ff00ff00ff00ff00ff00ff00ff00ff00ff00ff00ff00ff00ff00ff;

    uint256 private constant UNDERSCORE = 0x5f;
    uint256 private constant HYPHEN = 0x2d;
    uint256 private constant FE0F = 0xfe0f;
    uint256 private constant NSM_MAX = 4;

    // hangul
    uint256 private constant S0 = 0xac00;
    uint256 private constant L0 = 0x1100;
    uint256 private constant V0 = 0x1161;
    uint256 private constant T0 = 0x11a7;
    uint256 private constant L_COUNT = 19;
    uint256 private constant V_COUNT = 21;
    uint256 private constant T_COUNT = 28;
    uint256 private constant N_COUNT = 588; // V_COUNT * T_COUNT
    uint256 private constant S_COUNT = 11172; // L_COUNT * N_COUNT

    address private immutable _index;
    address private immutable _runs;
    address private immutable _classes;
    address private immutable _emoji;
    address private immutable _map;
    address private immutable _masks;
    address private immutable _lists;
    address private immutable _conf;
    address private immutable _decomp;
    address private immutable _comp;

    /// @param data The data contracts: ENSNormalizeData0, ENSNormalizeData1, ...
    constructor(address[] memory data) {
        if (data.length != Spec.DATA_COUNT) revert InvalidData(data.length);
        for (uint256 i; i < data.length; ++i) {
            if (data[i].codehash != Spec.dataHash(i)) revert InvalidData(i);
        }
        _index = data[Spec.INDEX_DATA];
        _runs = data[Spec.RUNS_DATA];
        _classes = data[Spec.CLASSES_DATA];
        _emoji = data[Spec.EMOJI_DATA];
        _map = data[Spec.MAP_DATA];
        _masks = data[Spec.MASKS_DATA];
        _lists = data[Spec.LISTS_DATA];
        _conf = data[Spec.CONF_DATA];
        _decomp = data[Spec.DECOMP_DATA];
        _comp = data[Spec.COMP_DATA];
    }

    /// @notice ERC-165
    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return interfaceId == type(IENSIP15).interfaceId || interfaceId == 0x01ffc9a7;
    }

    /// @inheritdoc IENSIP15
    function normalize(string calldata label) external view returns (string memory) {
        (bool ok, bytes memory ret) = _normalizeASCII(bytes(label));
        if (!ok) revert CannotNormalize(label);
        if (ret.length != 0) return string(ret);
        uint256 ctx;
        assembly ("memory-safe") {
            ctx := mload(0x40)
            calldatacopy(ctx, calldatasize(), CTX_SIZE) // zero
            mstore(0x40, add(ctx, CTX_SIZE))
        }
        uint256[] memory cps = _decodeUTF8(bytes(label));
        uint256 len;
        bool emoji;
        if (cps.length != 0) (cps, len, emoji) = _tokenize(ctx, cps);
        if (len == 0 || !_isValid(ctx, cps, len, emoji)) revert CannotNormalize(label);
        return string(_encodeUTF8(cps, len));
    }

    // ************************************************************
    // ascii

    /// @dev Normalizes a label of only valid ascii and A-Z.
    ///      Returns (true, "") if it has other characters, and (false, "") if it's invalid.
    function _normalizeASCII(bytes calldata v) private pure returns (bool ok, bytes memory ret) {
        uint256 valid = Spec.ASCII_VALID;
        assembly ("memory-safe") {
            let n := v.length
            ret := mload(0x40)
            let p := add(ret, 32)
            let leading := 0 // underscores
            ok := gt(n, 0)
            for { let i := 0 } lt(i, n) { i := add(i, 1) } {
                let cp := byte(0, calldataload(add(v.offset, i)))
                switch lt(sub(cp, 0x41), 26)
                case 1 { cp := add(cp, 32) }
                default {
                    if or(gt(cp, 0x7f), iszero(and(shr(cp, valid), 1))) {
                        // not handled here
                        ret := 0x60
                        n := 0
                        break
                    }
                }
                if eq(cp, UNDERSCORE) {
                    if lt(leading, i) { ok := 0 } // underscore allowed only at start
                    leading := add(leading, 1)
                }
                mstore8(add(p, i), cp)
            }
            if n {
                // invalid label extension: ??--
                if and(gt(n, 3), eq(and(shr(224, mload(p)), 0xffff), 0x2d2d)) { ok := 0 }
                mstore(ret, n)
                mstore(0x40, add(p, and(add(n, 31), not(31))))
            }
        }
    }

    // ************************************************************
    // tokenize

    /// @dev Returns the output cps: text runs (NFC) and emoji (without FE0F, flagged).
    function _tokenize(uint256 ctx, uint256[] memory cps)
        private
        view
        returns (uint256[] memory buf, uint256 len, bool emoji)
    {
        uint256 n = cps.length;
        buf = new uint256[](n * Spec.MAX_EXPAND);
        uint256 run; // start of the current text run
        unchecked {
            for (uint256 i; i < n;) {
                uint256 cp = cps[i];
                uint256 c = _lookup(ctx, cp);
                if (c & MAPPED != 0) {
                    len = _appendMapped(ctx, buf, len, cp, c & 0x7fff);
                    ++i;
                    continue;
                }
                uint256 node = (c >> C_EMOJI_SHIFT) & 63;
                if (node != 0) {
                    uint256 end = _matchEmoji(cps, i, node);
                    if (end != 0) {
                        len = _nfc(ctx, buf, run, len);
                        for (; i < end; ++i) {
                            cp = cps[i];
                            if (cp != FE0F) buf[len++] = cp | EMOJI_BIT;
                        }
                        run = len;
                        emoji = true;
                        continue;
                    }
                }
                if (c & C_VALID != 0) {
                    buf[len++] = cp | (c << CLASS_SHIFT);
                } else if (c & C_IGNORED == 0) {
                    return (buf, 0, false); // disallowed
                }
                ++i;
            }
            len = _nfc(ctx, buf, run, len);
        }
    }

    /// @dev Returns the end of the longest emoji at `i`, or 0.
    function _matchEmoji(uint256[] memory cps, uint256 i, uint256 node) private view returns (uint256 end) {
        address a = _emoji;
        uint256 base = Spec.EMOJI_OFFSET;
        assembly ("memory-safe") {
            let n := mload(cps)
            let p := mload(0x40) // scratch
            for { let j := add(i, 1) } 1 { j := add(j, 1) } {
                // node: [term << 7 | count][edges: (cp:3, node:1) x count]
                extcodecopy(a, 0, add(base, shl(1, sub(node, 1))), 2)
                let off := add(base, shr(240, mload(0)))
                extcodecopy(a, p, off, 509)
                let hdr := byte(0, mload(p))
                if gt(hdr, 0x7f) { end := j }
                if eq(j, n) { break }
                let cp := mload(add(cps, shl(5, add(j, 1))))
                node := 0
                for {
                    let q := add(p, 1)
                    let e := add(q, shl(2, and(hdr, 0x7f)))
                } lt(q, e) { q := add(q, 4) } {
                    let x := shr(224, mload(q))
                    if eq(shr(8, x), cp) {
                        node := and(x, 0xff)
                        break
                    }
                }
                if iszero(node) { break }
            }
        }
    }

    /// @dev Appends the mapping of `cp` (at `off` in MAP) with its classes.
    function _appendMapped(uint256 ctx, uint256[] memory buf, uint256 len, uint256 cp, uint256 off)
        private
        view
        returns (uint256)
    {
        address a = _map;
        off += Spec.MAP_OFFSET;
        uint256 hdr = _read(a, off, 4);
        unchecked {
            if (hdr & 0x80000000 == 0) {
                // linear: cp + delta (i24)
                cp = (cp + hdr) & CP_MASK;
                buf[len++] = cp | (_lookup(ctx, cp) << CLASS_SHIFT);
            } else {
                // table: n cps of w bytes at [cp - base]
                uint256 count = (hdr >> 24) & 0x3f;
                uint256 w = hdr & 0x40000000 == 0 ? 2 : 3;
                off += 4 + (cp - (hdr & CP_MASK)) * count * w;
                uint256 v = _read(a, off, count * w); // <= 18 bytes
                for (uint256 i = count; i > 0;) {
                    --i;
                    cp = (v >> (i * w * 8)) & (w == 2 ? 0xffff : CP_MASK);
                    buf[len++] = cp | (_lookup(ctx, cp) << CLASS_SHIFT);
                }
            }
        }
        return len;
    }

    // ************************************************************
    // lookup

    /// @dev Returns the class record of `cp`, or MAPPED | offset.
    function _lookup(uint256 ctx, uint256 cp) private view returns (uint256 v) {
        if (cp >= Spec.LIMIT) {
            return cp >= Spec.IGNORED_LO && cp <= Spec.IGNORED_HI ? C_IGNORED : 0;
        }
        uint256 p = _bucket(ctx, cp >> 8);
        assembly ("memory-safe") {
            // bucket: [n - 1][starts: n][values: 2n]
            // the run is the number of starts <= lo, minus 1
            // count 32 starts at a time: in 16-bit lanes, (0x100 + lo - start) has bit 8 set if start <= lo
            let n := add(byte(0, mload(p)), 1)
            let lanes := mul(add(0x100, and(cp, 0xff)), LANES)
            let l := 0
            for { let q := add(p, 1) } lt(l, n) { q := add(q, 32) } {
                let w := or(mload(q), shr(shl(3, sub(n, l)), not(0))) // past the end: 0xff
                let c := and(shr(8, sub(lanes, and(w, BYTES))), LANES)
                c := add(c, and(shr(8, sub(lanes, and(shr(8, w), BYTES))), LANES))
                c := shr(240, mul(c, LANES)) // sum of lanes
                l := add(l, c)
                if lt(c, 32) { break }
            }
            if gt(l, n) { l := n } // lo = 0xff counts the padding
            l := sub(l, 1)
            v := shr(240, mload(add(p, add(add(1, n), shl(1, l)))))
        }
        if (v & 0x8000 != 0) return MAPPED | (v & 0x7fff);
        address classes = _classes;
        uint256 classesOffset = Spec.CLASSES_OFFSET;
        assembly ("memory-safe") {
            // cached class record
            let slot := add(ctx, add(CTX_CLASS, shl(5, and(v, 15))))
            let x := mload(slot)
            switch eq(shr(32, x), add(v, 1))
            case 1 { v := and(x, 0xffffffff) }
            default {
                extcodecopy(classes, 0, add(classesOffset, shl(2, v)), 4)
                x := shr(224, mload(0))
                mstore(slot, or(shl(32, add(v, 1)), x))
                v := x
            }
        }
    }

    /// @dev Returns the cached runs of bucket `b`: bucket 0 (ascii) has its own slot.
    function _bucket(uint256 ctx, uint256 b) private view returns (uint256 p) {
        address index = _index;
        address runs = _runs;
        uint256 indexOffset = Spec.INDEX_OFFSET;
        uint256 runsOffset = Spec.RUNS_OFFSET;
        assembly ("memory-safe") {
            let slot := add(ctx, CTX_BUCKET0)
            if b { slot := add(ctx, CTX_BUCKET) }
            p := add(slot, 32)
            if iszero(eq(mload(slot), add(b, 1))) {
                extcodecopy(index, 0, add(indexOffset, shl(1, b)), 2)
                extcodecopy(runs, p, add(runsOffset, shr(240, mload(0))), 769)
                mstore(slot, add(b, 1))
            }
        }
    }

    /// @dev Like _lookup() but a mapped cp is disallowed.
    function _class(uint256 ctx, uint256 cp) private view returns (uint256 c) {
        c = _lookup(ctx, cp);
        if (c & MAPPED != 0) c = 0;
    }

    /// @dev Reads `n` <= 32 bytes at `off` of `a`'s code as a big-endian uint.
    function _read(address a, uint256 off, uint256 n) private view returns (uint256 x) {
        assembly ("memory-safe") {
            extcodecopy(a, 0, off, n)
            x := shr(sub(256, shl(3, n)), mload(0))
        }
    }

    /// @dev Binary search of sorted fixed-size records by their leading `keySize` bytes.
    ///      Returns the record offset, or 0 if not found.
    function _search(address a, uint256 off, uint256 count, uint256 size, uint256 keySize, uint256 key)
        private
        view
        returns (uint256 ret)
    {
        assembly ("memory-safe") {
            let shift := sub(256, shl(3, keySize))
            let l := 0
            for { let h := count } lt(l, h) {} {
                let m := shr(1, add(l, h))
                let at := add(off, mul(m, size))
                extcodecopy(a, 0, at, keySize)
                let x := shr(shift, mload(0))
                if eq(x, key) {
                    ret := at
                    break
                }
                switch lt(x, key)
                case 1 { l := add(m, 1) }
                default { h := m }
            }
        }
    }

    // ************************************************************
    // NF

    /// @dev NFC of buf[s:e] in place, returns the new end.
    function _nfc(uint256 ctx, uint256[] memory buf, uint256 s, uint256 e) private view returns (uint256) {
        unchecked {
            // quick check: NFC_QC = Yes and canonical order
            uint256 prev;
            for (uint256 i = s;; ++i) {
                if (i == e) return e;
                uint256 c = buf[i] >> CLASS_SHIFT;
                uint256 r = (c >> C_RANK_SHIFT) & 63;
                if (c & C_QC != 0 || (r != 0 && r < prev)) break;
                prev = r;
            }
            (uint256[] memory tmp, uint256 t) = _nfd(ctx, buf, s, e, (e - s) * Spec.MAX_DECOMP);
            // compose
            uint256 w = s;
            uint256 starter = type(uint256).max;
            prev = 0; // 0 = adjacent to the starter, else rank + 1 of the last char
            for (uint256 i; i < t; ++i) {
                uint256 x = tmp[i];
                uint256 r = (x >> RANK_SHIFT) & 63;
                if (starter != type(uint256).max && prev <= r) {
                    uint256 cp = _compose(buf[starter] & CP_MASK, x & CP_MASK);
                    if (cp != 0) {
                        buf[starter] = cp | COMPOSED_BIT;
                        continue;
                    }
                }
                if (r != 0) {
                    prev = r + 1;
                } else {
                    starter = w;
                    prev = 0;
                }
                buf[w++] = x;
            }
            for (uint256 i = s; i < w; ++i) {
                uint256 x = buf[i];
                if (x & COMPOSED_BIT != 0) {
                    x &= CP_MASK;
                    buf[i] = x | (_class(ctx, x) << CLASS_SHIFT);
                }
            }
            return w;
        }
    }

    /// @dev NFD of the text in buf[s:e] (emoji skipped) into a new buffer of `cap` entries.
    function _nfd(uint256 ctx, uint256[] memory buf, uint256 s, uint256 e, uint256 cap)
        private
        view
        returns (uint256[] memory tmp, uint256 t)
    {
        tmp = new uint256[](cap);
        unchecked {
            for (uint256 i = s; i < e; ++i) {
                uint256 x = buf[i];
                if (x & EMOJI_BIT == 0) t = _decompose(ctx, tmp, t, x);
            }
            // canonical ordering: stable insertion sort of non-starters by rank
            for (uint256 i = 1; i < t; ++i) {
                uint256 x = tmp[i];
                uint256 r = (x >> RANK_SHIFT) & 63;
                if (r == 0) continue;
                uint256 j = i;
                for (; j > 0; --j) {
                    uint256 y = tmp[j - 1];
                    if ((y >> RANK_SHIFT) & 63 <= r) break;
                    tmp[j] = y;
                }
                tmp[j] = x;
            }
        }
    }

    function _decompose(uint256 ctx, uint256[] memory tmp, uint256 t, uint256 x) private view returns (uint256) {
        uint256 cp = x & CP_MASK;
        unchecked {
            if ((x >> CLASS_SHIFT) & C_DECOMP != 0) {
                uint256 off = _search(_decomp, Spec.DECOMP_OFFSET, Spec.DECOMP_COUNT, 9, 3, cp);
                uint256 ab = _read(_decomp, off + 3, 6);
                uint256 a = ab >> 24;
                uint256 b = ab & CP_MASK;
                t = _decompose(ctx, tmp, t, a | (_class(ctx, a) << CLASS_SHIFT));
                t = _decompose(ctx, tmp, t, b | (_class(ctx, b) << CLASS_SHIFT));
            } else if (cp - S0 < S_COUNT) {
                uint256 s = cp - S0;
                uint256 v = L0 + s / N_COUNT;
                tmp[t++] = v | (_class(ctx, v) << CLASS_SHIFT);
                v = V0 + (s % N_COUNT) / T_COUNT;
                tmp[t++] = v | (_class(ctx, v) << CLASS_SHIFT);
                s %= T_COUNT;
                if (s != 0) {
                    v = T0 + s;
                    tmp[t++] = v | (_class(ctx, v) << CLASS_SHIFT);
                }
            } else {
                tmp[t++] = x;
            }
        }
        return t;
    }

    /// @dev Returns the primary composite of `a` + `b`, or 0.
    function _compose(uint256 a, uint256 b) private view returns (uint256) {
        unchecked {
            if (a - L0 < L_COUNT && b - V0 < V_COUNT) {
                return S0 + (a - L0) * N_COUNT + (b - V0) * T_COUNT;
            } else if (a - S0 < S_COUNT && b > T0 && b < T0 + T_COUNT && (a - S0) % T_COUNT == 0) {
                return a + (b - T0);
            }
            uint256 off = _search(_comp, Spec.COMP_OFFSET, Spec.COMP_COUNT, 9, 6, (a << 24) | b);
            return off == 0 ? 0 : _read(_comp, off + 6, 3);
        }
    }

    // ************************************************************
    // validation

    function _isValid(uint256 ctx, uint256[] memory buf, uint256 len, bool emoji) private view returns (bool) {
        unchecked {
            // underscore allowed only at start
            uint256 i;
            while (i < len && buf[i] & CP_MASK == UNDERSCORE) ++i;
            for (; i < len; ++i) {
                if (buf[i] & CP_MASK == UNDERSCORE) return false;
            }
            if (!emoji) {
                bool ascii = true;
                for (i = 0; i < len; ++i) {
                    if (buf[i] & CP_MASK >= 0x80) {
                        ascii = false;
                        break;
                    }
                }
                if (ascii) {
                    // invalid label extension
                    return len < 4 || buf[2] & CP_MASK != HYPHEN || buf[3] & CP_MASK != HYPHEN;
                }
            }
            // combining marks: no CM at the start of a text run (leading, or after an emoji)
            // fenced: not leading, trailing, or adjacent
            // group: the highest priority group that contains every text cp
            uint256 g = type(uint256).max;
            uint256 prev = EMOJI_BIT;
            for (i = 0; i < len; ++i) {
                uint256 x = buf[i];
                if (x & EMOJI_BIT == 0) {
                    uint256 c = x >> CLASS_SHIFT;
                    if (c & C_CM != 0 && prev & EMOJI_BIT != 0) return false;
                    if (c & C_FENCED != 0) {
                        if (i == 0 || i == len - 1 || (prev >> CLASS_SHIFT) & C_FENCED != 0) return false;
                    }
                    g &= _maskAll(ctx, c & C_MASK);
                }
                prev = x;
            }
            if (g == type(uint256).max) return true; // emoji only
            if (g == 0) return false; // mixture or disallowed
            g &= ~g + 1;
            if (g & Spec.CHECK_NSM != 0 && !_checkNSM(ctx, buf, len, g)) return false;
            return _checkWhole(ctx, buf, len);
        }
    }

    /// @dev A CM's base must be primary in the group. Non-spacing marks (NFD): no duplicates, at most NSM_MAX in a row.
    function _checkNSM(uint256 ctx, uint256[] memory buf, uint256 len, uint256 g) private view returns (bool) {
        unchecked {
            uint256 base;
            bool any;
            for (uint256 i; i < len; ++i) {
                uint256 x = buf[i];
                if (x & EMOJI_BIT != 0) continue;
                uint256 c = x >> CLASS_SHIFT;
                if (c & C_CM != 0) {
                    if (_maskPri(base) & g == 0) return false;
                } else {
                    base = c & C_MASK;
                }
                if (c & (C_NSM | C_DECOMP) != 0) any = true;
            }
            if (!any) return true;
            (uint256[] memory d, uint256 t) = _nfd(ctx, buf, 0, len, len * Spec.MAX_DECOMP);
            for (uint256 i = 1; i < t; ++i) {
                if ((d[i] >> CLASS_SHIFT) & C_NSM == 0) continue;
                uint256 j = i + 1;
                for (; j < t; ++j) {
                    uint256 x = d[j];
                    if ((x >> CLASS_SHIFT) & C_NSM == 0) break;
                    x &= CP_MASK;
                    for (uint256 k = i; k < j; ++k) {
                        if (d[k] & CP_MASK == x) return false; // duplicate
                    }
                }
                if (j - i > NSM_MAX) return false; // excessive
                i = j;
            }
            return true;
        }
    }

    /// @dev Fails if every text cp could be a lookalike from one other group.
    function _checkWhole(uint256 ctx, uint256[] memory buf, uint256 len) private view returns (bool) {
        uint256 maker = type(uint256).max; // groups that could make a confusable whole
        uint256 shared = type(uint256).max; // groups that contain every non-confusable cp
        bool confusable;
        unchecked {
            for (uint256 i; i < len; ++i) {
                uint256 c = buf[i];
                if (c & EMOJI_BIT != 0) continue;
                c >>= CLASS_SHIFT;
                if (c & C_UNIQUE != 0) return true;
                if (c & C_CONFUSED == 0) shared &= _maskAll(ctx, c & C_MASK);
            }
            for (uint256 i; i < len; ++i) {
                uint256 x = buf[i];
                if (x & EMOJI_BIT != 0 || (x >> CLASS_SHIFT) & C_CONFUSED == 0) continue;
                confusable = true;
                uint256 off = _search(_conf, Spec.CONF_OFFSET, Spec.CONF_COUNT, 3, 3, x & CP_MASK);
                off = Spec.CONF_OFFSET + Spec.CONF_COUNT * 3 + ((off - Spec.CONF_OFFSET) / 3) * 4;
                uint256 ue = _read(_conf, off, 4);
                maker &= _list(ue >> 16) & ~_list(ue & 0xffff);
                if (maker & shared == 0) return true;
            }
        }
        return !confusable;
    }

    /// @dev The groups that contain any cp with this mask id (cached).
    function _maskAll(uint256 ctx, uint256 id) private view returns (uint256 mask) {
        unchecked {
            uint256 slot = ctx + CTX_MASK;
            uint256 tag;
            assembly ("memory-safe") {
                tag := mload(slot)
                mask := mload(add(slot, 32))
            }
            if (tag != id + 1) {
                mask = _list(_read(_masks, Spec.MASKS_OFFSET + (id << 2), 2));
                assembly ("memory-safe") {
                    mstore(slot, add(id, 1))
                    mstore(add(slot, 32), mask)
                }
            }
        }
    }

    /// @dev The groups that have any cp with this mask id as primary.
    function _maskPri(uint256 id) private view returns (uint256) {
        return _list(_read(_masks, Spec.MASKS_OFFSET + (id << 2) + 2, 2));
    }

    /// @dev Reads a mask stored as [n][bit indices...].
    function _list(uint256 off) private view returns (uint256 mask) {
        address a = _lists;
        off += Spec.LISTS_OFFSET;
        assembly ("memory-safe") {
            extcodecopy(a, 0, off, 64)
            let n := byte(0, mload(0))
            for { let i := 1 } iszero(gt(i, n)) { i := add(i, 1) } {
                mask := or(mask, shl(byte(0, mload(i)), 1))
            }
        }
    }

    // ************************************************************
    // utf8

    /// @dev Decodes UTF-8 into cps, or returns empty if invalid.
    function _decodeUTF8(bytes calldata v) private pure returns (uint256[] memory cps) {
        assembly ("memory-safe") {
            cps := mload(0x40)
            let p := add(cps, 32)
            let bad := 0
            let i := v.offset
            for { let e := add(i, v.length) } lt(i, e) {} {
                let cp := byte(0, calldataload(i))
                i := add(i, 1)
                if gt(cp, 0x7f) {
                    let k := 0 // continuation bytes
                    let min := 0
                    switch lt(cp, 0xe0)
                    case 1 {
                        bad := lt(cp, 0xc2) // continuation, or overlong
                        cp := and(cp, 0x1f)
                        k := 1
                    }
                    default {
                        switch lt(cp, 0xf0)
                        case 1 {
                            cp := and(cp, 0x0f)
                            k := 2
                            min := 0x800
                        }
                        default {
                            bad := gt(cp, 0xf4)
                            cp := and(cp, 0x07)
                            k := 3
                            min := 0x10000
                        }
                    }
                    if gt(add(i, k), e) { bad := 1 }
                    let w := calldataload(i)
                    for { let j := 0 } lt(j, k) { j := add(j, 1) } {
                        let b := byte(j, w)
                        if iszero(eq(and(b, 0xc0), 0x80)) { bad := 1 }
                        cp := or(shl(6, cp), and(b, 0x3f))
                    }
                    i := add(i, k)
                    if or(lt(cp, min), or(gt(cp, 0x10ffff), eq(shr(11, cp), 0x1b))) { bad := 1 } // overlong, too big, surrogate
                    if bad {
                        p := add(cps, 32)
                        break
                    }
                }
                mstore(p, cp)
                p := add(p, 32)
            }
            mstore(cps, shr(5, sub(p, add(cps, 32))))
            mstore(0x40, p)
        }
    }

    function _encodeUTF8(uint256[] memory buf, uint256 len) private pure returns (bytes memory ret) {
        assembly ("memory-safe") {
            ret := mload(0x40)
            let p := add(ret, 32)
            for {
                let q := add(buf, 32)
                let e := add(q, shl(5, len))
            } lt(q, e) { q := add(q, 32) } {
                let cp := and(mload(q), CP_MASK)
                switch lt(cp, 0x80)
                case 1 {
                    mstore8(p, cp)
                    p := add(p, 1)
                }
                default {
                    switch lt(cp, 0x800)
                    case 1 {
                        mstore8(p, or(0xc0, shr(6, cp)))
                        mstore8(add(p, 1), or(0x80, and(cp, 0x3f)))
                        p := add(p, 2)
                    }
                    default {
                        switch lt(cp, 0x10000)
                        case 1 {
                            mstore8(p, or(0xe0, shr(12, cp)))
                            mstore8(add(p, 1), or(0x80, and(shr(6, cp), 0x3f)))
                            mstore8(add(p, 2), or(0x80, and(cp, 0x3f)))
                            p := add(p, 3)
                        }
                        default {
                            mstore8(p, or(0xf0, shr(18, cp)))
                            mstore8(add(p, 1), or(0x80, and(shr(12, cp), 0x3f)))
                            mstore8(add(p, 2), or(0x80, and(shr(6, cp), 0x3f)))
                            mstore8(add(p, 3), or(0x80, and(cp, 0x3f)))
                            p := add(p, 4)
                        }
                    }
                }
            }
            mstore(ret, sub(p, add(ret, 32)))
            mstore(p, 0) // clean padding
            mstore(0x40, and(add(p, 63), not(31)))
        }
    }
}
