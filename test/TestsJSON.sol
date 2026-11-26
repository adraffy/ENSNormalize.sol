// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @dev Parses ens-normalize-derive's tests.json: [{name, norm?, error?, comment?, ...}, ...]
///      Forge's JSON cheatcodes coerce strings that look like numbers or hex, and reject lone surrogates,
///      so this is a minimal parser for this file: objects of strings, booleans, and numbers.
///      Strings are returned as UTF-8; a lone surrogate becomes U+FFFD (like TextEncoder).
library TestsJSON {
    struct Test {
        string name;
        string norm; // == name if the test has no norm
        bool fails;
        string specHash; // only the version entry
    }

    error ParseError(uint256 pos);

    function parse(bytes memory s) internal pure returns (Test[] memory tests) {
        tests = new Test[](1024);
        uint256 count;
        uint256 p = _ws(s, 0);
        p = _expect(s, p, "[");
        while (true) {
            p = _ws(s, p);
            if (_at(s, p) == "]") break;
            p = _expect(s, p, "{");
            Test memory t;
            bool hasNorm;
            while (true) {
                p = _ws(s, p);
                if (_at(s, p) == "}") {
                    ++p;
                    break;
                }
                bytes memory key;
                (key, p) = _string(s, p);
                p = _expect(s, _ws(s, p), ":");
                p = _ws(s, p);
                bytes1 c = _at(s, p);
                if (c == '"') {
                    bytes memory value;
                    (value, p) = _string(s, p);
                    bytes32 k = keccak256(key);
                    if (k == keccak256("name")) {
                        t.name = string(value);
                    } else if (k == keccak256("spec_hash")) {
                        t.specHash = string(value);
                    } else if (k == keccak256("norm")) {
                        t.norm = string(value);
                        hasNorm = true;
                    }
                } else if (c == "t") {
                    p += 4; // true
                    if (keccak256(key) == keccak256("error")) t.fails = true;
                } else {
                    // false, null, number
                    while (_at(s, p) != "," && _at(s, p) != "}") ++p;
                }
                p = _ws(s, p);
                if (_at(s, p) == ",") ++p;
            }
            if (!hasNorm) t.norm = t.name;
            if (count == tests.length) {
                Test[] memory v = new Test[](count << 1);
                for (uint256 i; i < count; ++i) {
                    v[i] = tests[i];
                }
                tests = v;
            }
            tests[count++] = t;
            p = _ws(s, p);
            if (_at(s, p) == ",") ++p;
        }
        assembly {
            mstore(tests, count)
        }
    }

    function _at(bytes memory s, uint256 p) private pure returns (bytes1 c) {
        if (p >= s.length) revert ParseError(p);
        assembly {
            c := mload(add(add(s, 32), p))
        }
    }

    function _ws(bytes memory s, uint256 p) private pure returns (uint256) {
        while (p < s.length) {
            bytes1 c = s[p];
            if (c != " " && c != "\n" && c != "\r" && c != "\t") break;
            ++p;
        }
        return p;
    }

    function _expect(bytes memory s, uint256 p, bytes1 c) private pure returns (uint256) {
        if (_at(s, p) != c) revert ParseError(p);
        return p + 1;
    }

    function _hex(bytes memory s, uint256 p) private pure returns (uint256 x) {
        for (uint256 i; i < 4; ++i) {
            uint8 c = uint8(_at(s, p + i));
            if (c >= 0x30 && c <= 0x39) c -= 0x30;
            else if (c >= 0x61 && c <= 0x66) c -= 0x57;
            else if (c >= 0x41 && c <= 0x46) c -= 0x37;
            else revert ParseError(p + i);
            x = (x << 4) | c;
        }
    }

    /// @dev Returns the decoded string at `p` (a quote) and the position after it.
    function _string(bytes memory s, uint256 p) private pure returns (bytes memory v, uint256) {
        p = _expect(s, p, '"');
        uint256 end = p;
        while (true) {
            bytes1 c = _at(s, end);
            if (c == '"') break;
            end += c == "\\" ? 2 : 1;
        }
        v = new bytes(end - p); // decoded is never longer
        uint256 n;
        while (p < end) {
            bytes1 c = s[p++];
            if (c != "\\") {
                v[n++] = c;
                continue;
            }
            c = s[p++];
            if (c == "u") {
                uint256 cp = _hex(s, p);
                p += 4;
                if (cp >= 0xd800 && cp < 0xdc00 && p + 6 <= end && s[p] == "\\" && s[p + 1] == "u") {
                    uint256 lo = _hex(s, p + 2);
                    if (lo >= 0xdc00 && lo < 0xe000) {
                        cp = 0x10000 + ((cp - 0xd800) << 10) + (lo - 0xdc00);
                        p += 6;
                    }
                }
                if (cp >= 0xd800 && cp < 0xe000) cp = 0xfffd; // lone surrogate
                n = _utf8(v, n, cp);
            } else if (c == "n") {
                v[n++] = "\n";
            } else if (c == "t") {
                v[n++] = "\t";
            } else if (c == "r") {
                v[n++] = "\r";
            } else if (c == "b") {
                v[n++] = 0x08;
            } else if (c == "f") {
                v[n++] = 0x0c;
            } else {
                v[n++] = c; // " \ /
            }
        }
        assembly {
            mstore(v, n)
        }
        return (v, end + 1);
    }

    function _utf8(bytes memory v, uint256 n, uint256 cp) private pure returns (uint256) {
        if (cp < 0x80) {
            v[n++] = bytes1(uint8(cp));
        } else if (cp < 0x800) {
            v[n++] = bytes1(uint8(0xc0 | (cp >> 6)));
            v[n++] = bytes1(uint8(0x80 | (cp & 0x3f)));
        } else if (cp < 0x10000) {
            v[n++] = bytes1(uint8(0xe0 | (cp >> 12)));
            v[n++] = bytes1(uint8(0x80 | ((cp >> 6) & 0x3f)));
            v[n++] = bytes1(uint8(0x80 | (cp & 0x3f)));
        } else {
            v[n++] = bytes1(uint8(0xf0 | (cp >> 18)));
            v[n++] = bytes1(uint8(0x80 | ((cp >> 12) & 0x3f)));
            v[n++] = bytes1(uint8(0x80 | ((cp >> 6) & 0x3f)));
            v[n++] = bytes1(uint8(0x80 | (cp & 0x3f)));
        }
        return n;
    }
}
