// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console} from "forge-std/Test.sol";
import {ENSNormalize} from "../src/ENSNormalize.sol";
import {IENSIP15} from "../src/IENSIP15.sol";
import {ENSNormalizeDataDeployer, TABLES_HASH} from "../src/generated/ENSNormalizeData.sol";
import {TestsJSON} from "./TestsJSON.sol";

contract ENSNormalizeTest is Test {
    uint256 constant SHARDS = 8;
    uint256 constant MAX_LOGS = 10;

    ENSNormalize ens;

    function setUp() external {
        ens = new ENSNormalize(ENSNormalizeDataDeployer.deploy());
    }

    // ************************************************************
    // tests.json (ens-normalize-derive), split into shards so forge runs them in parallel

    function test_tests0() external {
        _run(0);
    }

    function test_tests1() external {
        _run(1);
    }

    function test_tests2() external {
        _run(2);
    }

    function test_tests3() external {
        _run(3);
    }

    function test_tests4() external {
        _run(4);
    }

    function test_tests5() external {
        _run(5);
    }

    function test_tests6() external {
        _run(6);
    }

    function test_tests7() external {
        _run(7);
    }

    function _run(uint256 shard) internal {
        vm.pauseGasMetering();
        TestsJSON.Test[] memory tests = TestsJSON.parse(bytes(vm.readFile("data/tests.json")));
        assertEq(ens.specHash(), vm.parseBytes32(string.concat("0x", tests[0].specHash)), "tests are for this spec");
        uint256 fails;
        uint256 count;
        for (uint256 i = 1 + shard; i < tests.length; i += SHARDS) {
            // first entry is version info
            TestsJSON.Test memory t = tests[i];
            (bool ok, string memory norm) = _normalizeName(t.name);
            ++count;
            if (t.fails ? ok : !ok || keccak256(bytes(norm)) != keccak256(bytes(t.norm))) {
                if (fails++ < MAX_LOGS) {
                    console.log("FAIL #%s %s", i, t.fails ? "expected error" : ok ? "wrong norm" : "unexpected error");
                    console.logBytes(bytes(t.name));
                    if (ok) console.logBytes(bytes(norm));
                    if (!t.fails) console.logBytes(bytes(t.norm));
                }
            }
        }
        console.log("shard %s: %s tests, %s failed", shard, count, fails);
        assertEq(fails, 0, "failures");
    }

    /// @dev Normalizes a name label by label, like ensNormalize(): "" is "".
    function _normalizeName(string memory name) internal view returns (bool, string memory) {
        bytes memory v = bytes(name);
        if (v.length == 0) return (true, "");
        bytes memory out;
        uint256 start;
        for (uint256 i; i <= v.length; ++i) {
            if (i < v.length && v[i] != ".") continue;
            bytes memory label = new bytes(i - start);
            for (uint256 j; j < label.length; ++j) {
                label[j] = v[start + j];
            }
            try ens.normalize(string(label)) returns (string memory norm) {
                out = start == 0 ? bytes(norm) : abi.encodePacked(out, ".", norm);
            } catch (bytes memory err) {
                assertEq(bytes4(err), IENSIP15.CannotNormalize.selector, "error selector");
                return (false, "");
            }
            start = i + 1;
        }
        return (true, string(out));
    }

    // ************************************************************
    // examples

    function _ok(string memory label, string memory norm) internal view {
        assertEq(ens.normalize(label), norm, label);
    }

    function _fail(string memory label) internal {
        vm.expectRevert(abi.encodeWithSelector(IENSIP15.CannotNormalize.selector, label));
        ens.normalize(label);
    }

    function test_ascii() external {
        _ok("nick", "nick");
        _ok("RaFFY", "raffy");
        _ok("__a", "__a");
        _ok("$100", "$100");
        _fail("");
        _fail("a_b");
        _fail("xn--ls8h");
        _fail("a b");
        _fail("a.b");
    }

    function test_unicode() external {
        _ok(unicode"ＢＩＴ", "bit");
        _ok(unicode"Ａ́", unicode"á");
        _ok(unicode"🚴‍♂️", unicode"🚴‍♂");
        _ok(unicode"1⃣", unicode"1⃣");
        _ok(unicode"a’b", unicode"a’b");
        _ok("a'b", unicode"a’b");
        _ok(unicode"ξ", unicode"ξ");
    }

    function test_invalidUTF8() external {
        _fail(string(bytes(hex"80")));
        _fail(string(bytes(hex"c0af")));
        _fail(string(bytes(hex"eda080"))); // surrogate
        _fail(string(bytes(hex"f4908080"))); // > 10FFFF
        _fail(string(bytes(hex"e282"))); // truncated
    }

    function test_supportsInterface() external view {
        assertTrue(ens.supportsInterface(type(IENSIP15).interfaceId));
        assertTrue(ens.supportsInterface(0x01ffc9a7));
        assertFalse(ens.supportsInterface(0xffffffff));
    }

    function test_tables() external view {
        assertEq(keccak256(ens.tables()), TABLES_HASH, "tables()");
    }

    function test_invalidData() external {
        address[] memory data = ENSNormalizeDataDeployer.deploy();
        (data[0], data[1]) = (data[1], data[0]);
        vm.expectRevert(abi.encodeWithSelector(ENSNormalize.InvalidData.selector, 0));
        new ENSNormalize(data);
    }
}
