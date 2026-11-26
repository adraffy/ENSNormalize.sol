// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IENSIP15} from "./IENSIP15.sol";
import {
    SPEC_HASH,
    LIMIT,
    IGNORED_LO,
    IGNORED_HI,
    ASCII_VALID,
    CHECK_NSM,
    INDEX_OFFSET,
    HOT_OFFSET,
    CLASSES_OFFSET,
    EMOJI_OFFSET,
    MASKS_OFFSET,
    LISTS_OFFSET,
    RUNS_DATA,
    RUNS_OFFSET,
    CONF_DATA,
    CONF_OFFSET,
    DECOMP_DATA,
    DECOMP_OFFSET,
    COMP_DATA,
    COMP_OFFSET,
    MAP_DATA,
    MAP_OFFSET,
    DECOMP_COUNT,
    COMP_COUNT,
    CONF_CLASS,
    BUCKET_SIZE,
    EMOJI_NODE_SIZE,
    LIST_BITMAP_SHIFT,
    DATA_COUNT,
    dataHash,
    TABLES_SIZE,
    TABLES
} from "./generated/ENSNormalizeData.sol";

/// @title ENSNormalize
/// @notice ENSIP-15 label normalization.
/// @dev Follows the reference implementation in adraffy/ens-normalize-derive (src/ensip15.ts), using tables
///      derived from its spec files (scripts/make.ts). The hot tables are in this contract's own code (CODECOPY),
///      the rest are in data contracts (EXTCODECOPY).
///      Contract is ownerless and immutable: a new spec is a new deployment.
///
///      normalize(label):
///      1. ASCII fast path: no tables
///      2. decode UTF-8
///      3. tokenize: longest emoji match, else valid / mapped / ignored / disallowed
///      4. NFC each text run
///      5. validate: underscore, label extension, combining marks, fenced, group, NSM, whole-script confusables
///      6. encode UTF-8
///
///      The general path doesn't allocate. From the free memory pointer:
///      [context][cps: decoded input][entries: output][scratch]
contract ENSNormalize is IENSIP15 {
    /// @dev A data contract doesn't match the spec.
    error InvalidData(uint256 index);

    // class record (scripts/make.ts)
    uint256 private constant C_MASK = 0xff; // index into MASKS
    uint256 private constant C_RANK_SHIFT = 8; // 6 bits, then NFC_QC != Yes
    uint256 private constant C_EMOJI_SHIFT = 20; // 6 bits
    uint256 private constant C_EMOJI = 63 << 20;
    uint256 private constant C_VALID = 1 << 26;
    uint256 private constant C_IGNORED = 1 << 27;
    /// @dev _lookup(): the cp is mapped, the low 15 bits are its offset in MAP.
    uint256 private constant MAPPED = 1 << 31;

    // entry: cp | class record << 24 | class id << 56 | flags
    uint256 private constant CP_MASK = 0xffffff;
    uint256 private constant E_CLASS = 24;
    uint256 private constant E_RANK = 32; // 6 bits
    uint256 private constant E_QC = 1 << 38;
    uint256 private constant E_CM = 1 << 39;
    uint256 private constant E_NSM = 1 << 40;
    uint256 private constant E_CONFUSED = 1 << 41;
    uint256 private constant E_UNIQUE = 1 << 42;
    uint256 private constant E_DECOMP = 1 << 43;
    uint256 private constant E_FENCED = 1 << 52;
    uint256 private constant E_ID = 56; // 16 bits
    uint256 private constant E_EMOJI = 1 << 255; // part of an emoji
    uint256 private constant E_COMPOSED = 1 << 254; // class must be looked up again

    // _tokenize()
    uint256 private constant F_CHANGED = 1; // the output isn't the input
    uint256 private constant NF_NEEDED = 0x100; // the run isn't NFC (low bits: rank of the last cp)

    // context
    uint256 private constant CTX_BUCKET_TAG = 0x00; // 2 x [bucket + 1]: bucket 0 (ascii), any other bucket
    uint256 private constant CTX_TABLES = 0x40; // offset of TABLES in this contract's code
    uint256 private constant CTX_MASK = 0x60; // 4 x [mask id + 1][mask]
    uint256 private constant CTX_BUCKET = 0x160; // 2 x BUCKET_SIZE, then EMOJI_NODE_SIZE + 32 of scratch
    uint256 private constant CTX_SIZE = CTX_BUCKET + 2 * BUCKET_SIZE + EMOJI_NODE_SIZE + 32;

    uint256 private constant UNDERSCORE = 0x5f;
    uint256 private constant HYPHEN = 0x2d;
    uint256 private constant FE0F = 0xfe0f;
    uint256 private constant NSM_MAX = 4;
    uint256 private constant GROUPS = (1 << 248) - 1; // _isValid(): the top byte caches a mask id

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

    // SWAR
    uint256 private constant LANES = 0x0001000100010001000100010001000100010001000100010001000100010001;
    uint256 private constant BYTES = 0x00ff00ff00ff00ff00ff00ff00ff00ff00ff00ff00ff00ff00ff00ff00ff00ff;
    uint256 private constant HIGHS = 0x8080808080808080808080808080808080808080808080808080808080808080;
    // for a byte b < 0x80: bit 7 of (b + 0x80 - lo) is set if b >= lo, bit 7 of (b + 0x7f - hi) if b > hi
    uint256 private constant AZ_LO = 0x1f1f1f1f1f1f1f1f1f1f1f1f1f1f1f1f1f1f1f1f1f1f1f1f1f1f1f1f1f1f1f1f;
    uint256 private constant AZ_HI = 0x0505050505050505050505050505050505050505050505050505050505050505;
    uint256 private constant DIGIT_LO = 0x5050505050505050505050505050505050505050505050505050505050505050;
    uint256 private constant DIGIT_HI = 0x4646464646464646464646464646464646464646464646464646464646464646;
    uint256 private constant HYPHEN_LO = 0x5353535353535353535353535353535353535353535353535353535353535353;
    uint256 private constant HYPHEN_HI = 0x5252525252525252525252525252525252525252525252525252525252525252;

    address private immutable _runs;
    address private immutable _conf;
    address private immutable _decomp;
    address private immutable _comp;
    address private immutable _map;

    /// @param data The data contracts: ENSNormalizeData0, ENSNormalizeData1, ...
    constructor(address[] memory data) {
        if (data.length != DATA_COUNT) revert InvalidData(data.length);
        for (uint256 i; i < data.length; ++i) {
            if (data[i].codehash != dataHash(i)) revert InvalidData(i);
        }
        _runs = data[RUNS_DATA];
        _conf = data[CONF_DATA];
        _decomp = data[DECOMP_DATA];
        _comp = data[COMP_DATA];
        _map = data[MAP_DATA];
    }

    /// @notice ERC-165
    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return interfaceId == type(IENSIP15).interfaceId || interfaceId == 0x01ffc9a7;
    }

    /// @notice The sha256 of the spec.json this was built from (spec_hash in ens-normalize-derive's tests.json).
    function specHash() external pure returns (bytes32) {
        return SPEC_HASH;
    }

    /// @notice The tables in this contract's code.
    /// @dev This is the only data in the code, so it's right before the metadata: see _context().
    function tables() external pure returns (bytes memory) {
        return TABLES;
    }

    /// @inheritdoc IENSIP15
    function normalize(string calldata label) external view returns (string memory) {
        if (!_normalizeASCII(label)) {
            uint256 ctx = _context();
            uint256 cps = ctx + CTX_SIZE;
            uint256 end = _decodeUTF8(label, cps);
            if (end != cps) {
                (uint256 top, uint256 flags) = _tokenize(ctx, cps, end);
                if (top != end && _isValid(ctx, end, top)) _return(label, end, top, flags);
            }
        }
        revert CannotNormalize(label);
    }

    // ************************************************************
    // ascii

    /// @dev Returns the normalized label if it's only valid ascii and A-Z (this doesn't return to the caller).
    ///      Else returns true if it's invalid, or false if it has other characters.
    function _normalizeASCII(string calldata label) private pure returns (bool bad) {
        uint256 lower = ASCII_VALID & ~(1 << UNDERSCORE);
        assembly ("memory-safe") {
            let n := label.length
            let off := label.offset
            for {} 1 {} {
                if iszero(n) {
                    bad := 1
                    break
                }
                // only a-z 0-9 hyphen (already normalized): 32 bytes at a time
                let same := 1
                for { let i := 0 } lt(i, n) { i := add(i, 32) } {
                    let w := calldataload(add(off, i))
                    let m := HIGHS
                    if lt(sub(n, i), 32) {
                        let keep := not(shr(shl(3, sub(n, i)), not(0)))
                        w := and(w, keep)
                        m := and(m, keep)
                    }
                    // bit 7 of each byte is set if it's in a range
                    let v := and(add(w, AZ_LO), not(add(w, AZ_HI)))
                    v := or(v, and(add(w, DIGIT_LO), not(add(w, DIGIT_HI))))
                    v := or(v, and(add(w, HYPHEN_LO), not(add(w, HYPHEN_HI))))
                    if or(and(w, HIGHS), and(m, not(v))) {
                        same := 0
                        break
                    }
                }
                if same {
                    // invalid label extension: ??--
                    if and(gt(n, 3), eq(and(shr(224, calldataload(off)), 0xffff), 0x2d2d)) {
                        bad := 1
                        break
                    }
                    mstore(0, 0x20)
                    mstore(0x20, n)
                    mstore(0x40, 0)
                    calldatacopy(0x40, off, n)
                    return(0, add(0x40, and(add(n, 31), not(31))))
                }
                // leading underscores, then valid ascii or A-Z
                let ptr := mload(0x40)
                let dst := add(ptr, 0x40)
                let i := 0
                for {} lt(i, n) { i := add(i, 1) } {
                    if iszero(eq(byte(0, calldataload(add(off, i))), UNDERSCORE)) { break }
                    mstore8(add(dst, i), UNDERSCORE)
                }
                for {} lt(i, n) { i := add(i, 1) } {
                    let cp := byte(0, calldataload(add(off, i)))
                    if iszero(and(shr(cp, lower), 1)) {
                        if gt(sub(cp, 0x41), 25) { break }
                        cp := add(cp, 32)
                    }
                    mstore8(add(dst, i), cp)
                }
                if lt(i, n) { break } // has other characters
                if and(gt(n, 3), eq(and(shr(224, mload(dst)), 0xffff), 0x2d2d)) {
                    bad := 1
                    break
                }
                mstore(ptr, 0x20)
                mstore(add(ptr, 0x20), n)
                mstore(add(dst, n), 0)
                return(ptr, add(0x40, and(add(n, 31), not(31))))
            }
        }
    }

    // ************************************************************
    // general

    function _context() private pure returns (uint256 ctx) {
        assembly ("memory-safe") {
            ctx := mload(0x40)
            calldatacopy(ctx, calldatasize(), CTX_BUCKET) // zero the tags
            // the code ends with [TABLES][metadata][metadata length: 2]
            codecopy(0, sub(codesize(), 2), 2)
            mstore(add(ctx, CTX_TABLES), sub(sub(codesize(), add(shr(240, mload(0)), 2)), TABLES_SIZE))
        }
    }

    /// @dev Decodes UTF-8 into cps. Returns the end, or `cps` if invalid.
    function _decodeUTF8(string calldata label, uint256 cps) private pure returns (uint256 end) {
        assembly ("memory-safe") {
            end := cps
            let i := label.offset
            for { let e := add(i, label.length) } lt(i, e) {} {
                let w := calldataload(i)
                let cp := byte(0, w)
                switch lt(cp, 0x80)
                case 1 { i := add(i, 1) }
                default {
                    let bad
                    switch lt(cp, 0xe0)
                    case 1 {
                        // 110xxxxx 10xxxxxx
                        let x := shr(240, w)
                        bad := or(lt(cp, 0xc2), xor(and(x, 0xc0), 0x80))
                        cp := or(shl(6, and(cp, 0x1f)), and(x, 0x3f))
                        i := add(i, 2)
                    }
                    default {
                        switch lt(cp, 0xf0)
                        case 1 {
                            // 1110xxxx 10xxxxxx 10xxxxxx
                            let x := shr(232, w)
                            cp := or(shl(12, and(cp, 0x0f)), or(and(shr(2, x), 0xfc0), and(x, 0x3f)))
                            bad := or(xor(and(x, 0xc0c0), 0x8080), or(lt(cp, 0x800), eq(shr(11, cp), 0x1b)))
                            i := add(i, 3)
                        }
                        default {
                            // 11110xxx 10xxxxxx 10xxxxxx 10xxxxxx
                            let x := shr(224, w)
                            bad := or(gt(cp, 0xf4), xor(and(x, 0xc0c0c0), 0x808080))
                            cp := or(
                                or(shl(18, and(cp, 0x07)), and(shr(4, x), 0x3f000)),
                                or(and(shr(2, x), 0xfc0), and(x, 0x3f))
                            )
                            bad := or(bad, or(lt(cp, 0x10000), gt(cp, 0x10ffff)))
                            i := add(i, 4)
                        }
                    }
                    if or(bad, gt(i, e)) {
                        end := cps
                        break
                    }
                }
                mstore(end, cp)
                end := add(end, 32)
            }
        }
    }

    /// @dev Writes the output entries at `end`: text runs (NFC) and emoji (without FE0F).
    ///      Returns their end, or `end` if a cp is disallowed.
    function _tokenize(uint256 ctx, uint256 cps, uint256 end) private view returns (uint256 top, uint256 flags) {
        top = end;
        uint256 run = end; // start of the current text run
        uint256 nf; // rank of the last cp, NF_NEEDED if the run isn't NFC
        unchecked {
            for (uint256 p = cps; p < end;) {
                uint256 cp;
                assembly ("memory-safe") {
                    cp := mload(p)
                }
                uint256 c = _lookup(ctx, cp);
                if (c & (MAPPED | C_EMOJI | C_VALID) != C_VALID) {
                    if (c & MAPPED != 0) {
                        (top, nf) = _appendMapped(ctx, top, nf, cp, c & 0x7fff);
                        flags = F_CHANGED;
                        p += 32;
                        continue;
                    }
                    if (c & C_EMOJI != 0) {
                        uint256 q = _matchEmoji(ctx, p, end, (c >> C_EMOJI_SHIFT) & 63);
                        if (q != 0) {
                            if (nf & NF_NEEDED != 0) {
                                top = _nfc(ctx, run, top);
                                flags = F_CHANGED;
                            }
                            assembly ("memory-safe") {
                                for {} lt(p, q) { p := add(p, 32) } {
                                    cp := mload(p)
                                    switch eq(cp, FE0F)
                                    case 1 { flags := F_CHANGED }
                                    default {
                                        mstore(top, or(cp, E_EMOJI))
                                        top := add(top, 32)
                                    }
                                }
                            }
                            run = top;
                            nf = 0;
                            continue;
                        }
                    }
                    if (c & C_VALID == 0) {
                        if (c & C_IGNORED == 0) return (end, 0); // disallowed
                        flags = F_CHANGED;
                        p += 32;
                        continue;
                    }
                }
                assembly ("memory-safe") {
                    mstore(top, or(cp, shl(E_CLASS, c)))
                    top := add(top, 32)
                    // NFC quick check: NFC_QC = Yes and canonical order
                    c := and(shr(C_RANK_SHIFT, c), 0x7f)
                    switch c
                    case 0 { nf := and(nf, NF_NEEDED) }
                    default {
                        if or(gt(c, 63), lt(c, and(nf, 63))) { nf := NF_NEEDED }
                        nf := or(and(nf, NF_NEEDED), and(c, 63))
                    }
                    p := add(p, 32)
                }
            }
            if (nf & NF_NEEDED != 0) {
                top = _nfc(ctx, run, top);
                flags = F_CHANGED;
            }
        }
    }

    /// @dev Returns the end of the longest emoji at `p`, or 0.
    function _matchEmoji(uint256 ctx, uint256 p, uint256 end, uint256 node) private pure returns (uint256 q) {
        uint256 scratch = ctx + CTX_BUCKET + 2 * BUCKET_SIZE;
        assembly ("memory-safe") {
            let emoji := add(mload(add(ctx, CTX_TABLES)), EMOJI_OFFSET)
            for { p := add(p, 32) } 1 { p := add(p, 32) } {
                // node: [term << 7 | count][edges: (cp:3, node:1) x count]
                codecopy(0, add(emoji, shl(1, sub(node, 1))), 2)
                codecopy(scratch, add(emoji, shr(240, mload(0))), EMOJI_NODE_SIZE)
                let hdr := byte(0, mload(scratch))
                if gt(hdr, 0x7f) { q := p }
                if eq(p, end) { break }
                let cp := mload(p)
                node := 0
                for {
                    let e := add(scratch, 1)
                    let z := add(e, shl(2, and(hdr, 0x7f)))
                } lt(e, z) { e := add(e, 4) } {
                    let x := shr(224, mload(e))
                    if eq(shr(8, x), cp) {
                        node := and(x, 0xff)
                        break
                    }
                }
                if iszero(node) { break }
            }
        }
    }

    /// @dev Appends the mapping of `cp` (at `off` in MAP).
    function _appendMapped(uint256 ctx, uint256 top, uint256 nf, uint256 cp, uint256 off)
        private
        view
        returns (uint256, uint256)
    {
        address a = _map;
        unchecked {
            off += MAP_OFFSET;
            uint256 hdr = _read(a, off, 4);
            uint256 count = 1;
            uint256 w = 3;
            uint256 v; // the mapped cps
            if (hdr & 0x80000000 == 0) {
                // linear: cp + delta (i24)
                v = (cp + hdr) & CP_MASK;
            } else {
                // table: n cps of w bytes at [cp - base]
                count = (hdr >> 24) & 0x3f;
                if (hdr & 0x40000000 == 0) w = 2;
                v = _read(a, off + 4 + (cp - (hdr & CP_MASK)) * count * w, count * w);
            }
            while (count != 0) {
                cp = (v >> (--count * w * 8)) & (w == 2 ? 0xffff : CP_MASK);
                uint256 c = _lookup(ctx, cp);
                assembly ("memory-safe") {
                    mstore(top, or(cp, shl(E_CLASS, c)))
                    top := add(top, 32)
                    c := and(shr(C_RANK_SHIFT, c), 0x7f)
                    if or(gt(c, 63), and(gt(c, 0), lt(c, and(nf, 63)))) { nf := NF_NEEDED }
                    nf := or(and(nf, NF_NEEDED), and(c, 63))
                }
            }
        }
        return (top, nf);
    }

    // ************************************************************
    // lookup

    /// @dev Returns the class record of `cp` | class id << 32, or MAPPED | offset.
    function _lookup(uint256 ctx, uint256 cp) private view returns (uint256 v) {
        address runs = _runs;
        assembly ("memory-safe") {
            switch lt(cp, LIMIT)
            case 0 { v := mul(C_IGNORED, and(gt(cp, sub(IGNORED_LO, 1)), lt(cp, add(IGNORED_HI, 1)))) }
            default {
                // the bucket of cp >> 8, cached: bucket 0 (ascii) has its own slot
                let b := shr(8, cp)
                let slot := gt(b, 0)
                let p := add(ctx, add(CTX_BUCKET, mul(slot, BUCKET_SIZE)))
                slot := add(ctx, shl(5, slot))
                if iszero(eq(mload(slot), add(b, 1))) {
                    // index: offset in RUNS, or 0x8000 | offset in HOT
                    let tables := mload(add(ctx, CTX_TABLES))
                    codecopy(0, add(add(tables, INDEX_OFFSET), shl(1, b)), 2)
                    let off := shr(240, mload(0))
                    switch and(off, 0x8000)
                    case 0 { extcodecopy(runs, p, add(RUNS_OFFSET, off), BUCKET_SIZE) }
                    default { codecopy(p, add(add(tables, HOT_OFFSET), and(off, 0x7fff)), BUCKET_SIZE) }
                    mstore(slot, add(b, 1))
                }
                // bucket: [n - 1][sub: 8][starts: n][values: 2n]
                // sub[lo >> 5] is the run that contains the sub-block: add the next 32 starts that are <= lo
                // in 16-bit lanes, (0x100 + lo - start) has bit 8 set if start <= lo
                let n := add(byte(0, mload(p)), 1)
                let lo := and(cp, 0xff)
                let l := byte(shr(5, lo), mload(add(p, 1)))
                let w := or(mload(add(p, add(10, l))), shr(shl(3, sub(n, add(l, 1))), not(0))) // past the end: 0xff
                lo := mul(add(0x100, lo), LANES)
                w := add(and(shr(8, sub(lo, and(w, BYTES))), LANES), and(shr(8, sub(lo, and(shr(8, w), BYTES))), LANES))
                l := add(l, shr(240, mul(w, LANES))) // sum of lanes
                if iszero(lt(l, n)) { l := sub(n, 1) } // lo = 0xff counts the padding
                v := shr(240, mload(add(p, add(add(9, n), shl(1, l))))) // values[l]
                switch and(v, 0x8000)
                case 0 {
                    codecopy(0, add(add(mload(add(ctx, CTX_TABLES)), CLASSES_OFFSET), shl(2, v)), 4)
                    v := or(shr(224, mload(0)), shl(32, v))
                }
                default { v := or(MAPPED, and(v, 0x7fff)) }
            }
        }
    }

    /// @dev The entry of a cp that isn't from the input: mapped is disallowed.
    function _entry(uint256 ctx, uint256 cp) private view returns (uint256) {
        uint256 c = _lookup(ctx, cp);
        return c & MAPPED == 0 ? cp | (c << E_CLASS) : cp;
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

    /// @dev NFC of the entries [s, e) in place (e is the top), returns the new end.
    function _nfc(uint256 ctx, uint256 s, uint256 e) private view returns (uint256 w) {
        uint256 t = _nfd(ctx, s, e, e);
        w = s;
        uint256 starter;
        uint256 prev; // 0 = adjacent to the starter, else rank + 1 of the last char
        unchecked {
            // compose: writes trail reads, since composing never adds
            for (uint256 p = e; p < t; p += 32) {
                uint256 x;
                assembly ("memory-safe") {
                    x := mload(p)
                }
                uint256 r = (x >> E_RANK) & 63;
                // only a cp with NFC_QC != Yes composes with a starter
                if (x & E_QC != 0 && starter != 0 && prev <= r) {
                    uint256 y;
                    assembly ("memory-safe") {
                        y := mload(starter)
                    }
                    y = _compose(y & CP_MASK, x & CP_MASK);
                    if (y != 0) {
                        assembly ("memory-safe") {
                            mstore(starter, or(y, E_COMPOSED))
                        }
                        continue;
                    }
                }
                if (r != 0) {
                    prev = r + 1;
                } else {
                    starter = w;
                    prev = 0;
                }
                assembly ("memory-safe") {
                    mstore(w, x)
                    w := add(w, 32)
                }
            }
            for (uint256 p = s; p < w; p += 32) {
                uint256 x;
                assembly ("memory-safe") {
                    x := mload(p)
                }
                if (x & E_COMPOSED != 0) {
                    x = _entry(ctx, x & CP_MASK);
                    assembly ("memory-safe") {
                        mstore(p, x)
                    }
                }
            }
        }
    }

    /// @dev Writes the NFD of the text in entries [s, e) at `t`, returns the end.
    function _nfd(uint256 ctx, uint256 s, uint256 e, uint256 t) private view returns (uint256 end) {
        end = t;
        unchecked {
            for (; s < e; s += 32) {
                uint256 x;
                assembly ("memory-safe") {
                    x := mload(s)
                }
                if (x & E_EMOJI == 0) end = _decompose(ctx, end, x);
            }
        }
        // canonical ordering: stable insertion sort of non-starters by rank
        assembly ("memory-safe") {
            for { let p := add(t, 32) } lt(p, end) { p := add(p, 32) } {
                let x := mload(p)
                let r := and(shr(E_RANK, x), 63)
                if r {
                    let q := p
                    for {} gt(q, t) { q := sub(q, 32) } {
                        let y := mload(sub(q, 32))
                        if iszero(gt(and(shr(E_RANK, y), 63), r)) { break }
                        mstore(q, y)
                    }
                    mstore(q, x)
                }
            }
        }
    }

    function _decompose(uint256 ctx, uint256 t, uint256 x) private view returns (uint256) {
        uint256 cp = x & CP_MASK;
        unchecked {
            if (x & E_DECOMP != 0) {
                address a = _decomp;
                uint256 ab = _read(a, _search(a, DECOMP_OFFSET, DECOMP_COUNT, 9, 3, cp) + 3, 6);
                t = _decompose(ctx, t, _entry(ctx, ab >> 24));
                return _decompose(ctx, t, _entry(ctx, ab & CP_MASK));
            } else if (cp - S0 < S_COUNT) {
                cp -= S0;
                t = _push(t, _entry(ctx, L0 + cp / N_COUNT));
                t = _push(t, _entry(ctx, V0 + (cp % N_COUNT) / T_COUNT));
                cp %= T_COUNT;
                return cp == 0 ? t : _push(t, _entry(ctx, T0 + cp));
            }
        }
        return _push(t, x);
    }

    function _push(uint256 t, uint256 x) private pure returns (uint256 end) {
        assembly ("memory-safe") {
            mstore(t, x)
            end := add(t, 32)
        }
    }

    /// @dev Returns the primary composite of `a` + `b`, or 0.
    function _compose(uint256 a, uint256 b) private view returns (uint256) {
        unchecked {
            if (a - L0 < L_COUNT && b - V0 < V_COUNT) {
                return S0 + (a - L0) * N_COUNT + (b - V0) * T_COUNT;
            } else if (a - S0 < S_COUNT && b > T0 && b < T0 + T_COUNT && (a - S0) % T_COUNT == 0) {
                return a + (b - T0);
            }
            address comp = _comp;
            uint256 off = _search(comp, COMP_OFFSET, COMP_COUNT, 9, 6, (a << 24) | b);
            return off == 0 ? 0 : _read(comp, off + 6, 3);
        }
    }

    // ************************************************************
    // validation

    function _isValid(uint256 ctx, uint256 buf, uint256 top) private view returns (bool) {
        unchecked {
            uint256 x;
            // underscore allowed only at start
            uint256 lead = buf;
            for (; lead < top; lead += 32) {
                assembly ("memory-safe") {
                    x := mload(lead)
                }
                if (x & CP_MASK != UNDERSCORE) break;
            }
            // combining marks: no CM at the start of a text run (leading, or after an emoji)
            // fenced: not leading, trailing, or adjacent
            // group: the highest priority group that contains every text cp
            uint256 all; // every entry or'd
            uint256 prev = E_EMOJI;
            uint256 g = type(uint256).max;
            uint256 mask; // top byte: mask id + 1, the rest: its groups
            for (uint256 p = buf; p < top; p += 32) {
                assembly ("memory-safe") {
                    x := mload(p)
                }
                if (x & CP_MASK == UNDERSCORE && p > lead) return false;
                all |= x;
                if (x & E_EMOJI == 0) {
                    if (x & (E_CM | E_FENCED) != 0) {
                        if (x & E_CM != 0 && prev & E_EMOJI != 0) return false;
                        if (x & E_FENCED != 0 && (p == buf || p + 32 == top || prev & E_FENCED != 0)) return false;
                    }
                    uint256 id = ((x >> E_CLASS) & C_MASK) + 1;
                    if (mask >> 248 != id) mask = _maskAll(ctx, id - 1) | (id << 248);
                    g &= mask;
                }
                prev = x;
            }
            if (all & (E_EMOJI | 0xffff80) == 0) {
                // ascii: invalid label extension
                if (top - buf < 128) return true;
                assembly ("memory-safe") {
                    x := or(shl(24, mload(add(buf, 64))), and(mload(add(buf, 96)), CP_MASK))
                }
                return x & 0xffffffffffff != (HYPHEN << 24) | HYPHEN;
            }
            if (g == type(uint256).max) return true; // emoji only
            g &= GROUPS;
            if (g == 0) return false; // mixture or disallowed
            g &= ~g + 1;
            if (g & CHECK_NSM != 0) {
                if (all & E_CM != 0 && !_checkBase(ctx, buf, top, g)) return false;
                if (all & (E_NSM | E_DECOMP) != 0 && !_checkNSM(ctx, buf, top)) return false;
            }
            // whole-script confusable: every cp could be a lookalike from one other group
            return all & E_UNIQUE != 0 || all & E_CONFUSED == 0 || _checkWhole(ctx, buf, top);
        }
    }

    /// @dev A CM's base must be primary in the group.
    function _checkBase(uint256 ctx, uint256 buf, uint256 top, uint256 g) private pure returns (bool) {
        unchecked {
            uint256 base;
            for (; buf < top; buf += 32) {
                uint256 x;
                assembly ("memory-safe") {
                    x := mload(buf)
                }
                if (x & E_EMOJI != 0) continue;
                if (x & E_CM == 0) {
                    base = (x >> E_CLASS) & C_MASK;
                } else if (_maskPri(ctx, base) & g == 0) {
                    return false;
                }
            }
        }
        return true;
    }

    /// @dev Non-spacing marks (NFD): no duplicates, at most NSM_MAX in a row.
    function _checkNSM(uint256 ctx, uint256 buf, uint256 top) private view returns (bool ok) {
        uint256 end = _nfd(ctx, buf, top, top);
        ok = true;
        assembly ("memory-safe") {
            for { let i := add(top, 32) } lt(i, end) { i := add(i, 32) } {
                if iszero(and(mload(i), E_NSM)) { continue }
                let j := add(i, 32)
                for {} lt(j, end) { j := add(j, 32) } {
                    let x := mload(j)
                    if iszero(and(x, E_NSM)) { break }
                    x := and(x, CP_MASK)
                    for { let k := i } lt(k, j) { k := add(k, 32) } {
                        if eq(and(mload(k), CP_MASK), x) { ok := 0 } // duplicate
                    }
                }
                if gt(sub(j, i), shl(5, NSM_MAX)) { ok := 0 } // excessive
                i := j
            }
        }
    }

    /// @dev Returns false if some group contains a lookalike of every confused cp, and every other cp.
    ///      Assumes there's a confused cp, and no cp unique to a group.
    function _checkWhole(uint256 ctx, uint256 buf, uint256 top) private view returns (bool) {
        address conf = _conf;
        uint256 shared = type(uint256).max; // groups that contain every other cp
        unchecked {
            uint256 x;
            for (uint256 p = buf; p < top; p += 32) {
                assembly ("memory-safe") {
                    x := mload(p)
                }
                if (x & (E_EMOJI | E_CONFUSED) == 0) shared &= _maskAll(ctx, (x >> E_CLASS) & C_MASK);
            }
            for (uint256 p = buf; p < top; p += 32) {
                assembly ("memory-safe") {
                    x := mload(p)
                }
                if (x & E_CONFUSED == 0) continue;
                // the groups of its whole, outside its extent
                x = _read(conf, CONF_OFFSET + ((((x >> E_ID) & 0xffff) - CONF_CLASS) << 2), 4);
                shared &= _list(ctx, x >> 16) & ~_list(ctx, x & 0xffff);
                if (shared == 0) return true;
            }
        }
        return false;
    }

    /// @dev The groups that contain any cp with this mask id (cached).
    function _maskAll(uint256 ctx, uint256 id) private pure returns (uint256 mask) {
        uint256 slot;
        assembly ("memory-safe") {
            slot := add(ctx, add(CTX_MASK, shl(6, and(id, 3))))
            if eq(mload(slot), add(id, 1)) { mask := mload(add(slot, 32)) }
        }
        if (mask == 0) {
            mask = _list(ctx, _table(ctx, MASKS_OFFSET + (id << 2), 2));
            assembly ("memory-safe") {
                mstore(slot, add(id, 1))
                mstore(add(slot, 32), mask)
            }
        }
    }

    /// @dev The groups that have any cp with this mask id as primary.
    function _maskPri(uint256 ctx, uint256 id) private pure returns (uint256) {
        return _list(ctx, _table(ctx, MASKS_OFFSET + (id << 2) + 2, 2));
    }

    /// @dev Reads a mask: [n][bit indices: n], or [0xff][bitmap].
    function _list(uint256 ctx, uint256 off) private pure returns (uint256 mask) {
        assembly ("memory-safe") {
            codecopy(0, add(add(mload(add(ctx, CTX_TABLES)), LISTS_OFFSET), off), 64)
            let n := byte(0, mload(0))
            switch n
            case 0xff { mask := shr(LIST_BITMAP_SHIFT, mload(1)) }
            default {
                for { let i := 1 } iszero(gt(i, n)) { i := add(i, 1) } {
                    mask := or(mask, shl(byte(0, mload(i)), 1))
                }
            }
        }
    }

    /// @dev Reads `n` <= 32 bytes at `off` of TABLES as a big-endian uint.
    function _table(uint256 ctx, uint256 off, uint256 n) private pure returns (uint256 x) {
        assembly ("memory-safe") {
            codecopy(0, add(mload(add(ctx, CTX_TABLES)), off), n)
            x := shr(sub(256, shl(3, n)), mload(0))
        }
    }

    // ************************************************************
    // output

    /// @dev Returns the entries [buf, top) as UTF-8 (this doesn't return to the caller).
    function _return(string calldata label, uint256 buf, uint256 top, uint256 flags) private pure {
        assembly ("memory-safe") {
            mstore(top, 0x20)
            let dst := add(top, 0x40)
            let p := dst
            switch flags
            case 0 {
                // unchanged
                calldatacopy(p, label.offset, label.length)
                p := add(p, label.length)
            }
            default {
                for {} lt(buf, top) { buf := add(buf, 32) } {
                    let cp := and(mload(buf), CP_MASK)
                    switch lt(cp, 0x80)
                    case 1 {
                        mstore8(p, cp)
                        p := add(p, 1)
                    }
                    default {
                        switch lt(cp, 0x800)
                        case 1 {
                            mstore(p, shl(240, or(0xc080, or(shl(2, and(cp, 0x7c0)), and(cp, 0x3f)))))
                            p := add(p, 2)
                        }
                        default {
                            let x := or(shl(2, and(cp, 0xfc0)), and(cp, 0x3f))
                            switch lt(cp, 0x10000)
                            case 1 {
                                mstore(p, shl(232, or(0xe08080, or(shl(4, and(cp, 0xf000)), x))))
                                p := add(p, 3)
                            }
                            default {
                                x := or(x, or(shl(6, and(cp, 0x1c0000)), shl(4, and(cp, 0x3f000))))
                                mstore(p, shl(224, or(0xf0808080, x)))
                                p := add(p, 4)
                            }
                        }
                    }
                }
            }
            mstore(add(top, 0x20), sub(p, dst))
            mstore(p, 0) // padding
            return(top, and(add(sub(p, top), 31), not(31)))
        }
    }
}
