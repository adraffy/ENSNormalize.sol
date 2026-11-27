// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console} from "forge-std/Test.sol";
import {ENSNormalize} from "../src/ENSNormalize.sol";
import {ENSNormalizeDataDeployer} from "../src/generated/ENSNormalizeData.sol";

/// @dev Every known ENS label (adraffy/ens-labels) vs the reference implementation (ens-normalize-derive).
///      Not part of `forge test`: it's in its own profile.
///
///      bun scripts/labels.ts
///      FOUNDRY_PROFILE=exhaustive forge test
///
///      data/labels/<shard>.bin: [kind: u8][label length: u32][label]([norm length: u32][norm] if kind == 2)
///      kind 0: invalid, 1: normalized is the label, 2: normalized is different
contract LabelsTest is Test {
    uint256 constant SHARDS = 32; // scripts/labels.ts
    uint256 constant MAX_LOGS = 10;

    ENSNormalize ens;

    function setUp() external {
        ens = new ENSNormalize(ENSNormalizeDataDeployer.deploy());
    }

    function _run(uint256 shard) internal {
        vm.pauseGasMetering();
        assertEq(ens.specHash(), vm.parseBytes32(vm.readFile("data/labels/spec_hash.txt")), "labels are for this spec");
        bytes memory v = vm.readFileBinary(string.concat("data/labels/", vm.toString(shard), ".bin"));
        uint256 count;
        uint256 fails;
        uint256 p;
        uint256 end;
        assembly {
            p := add(v, 32)
            end := add(p, mload(v))
        }
        while (p < end) {
            uint256 kind;
            bytes32 labelHash;
            bytes32 normHash;
            uint256 label; // memory pointer to the label (and a free word before it, for its length)
            uint256 labelSize;
            assembly {
                kind := byte(0, mload(p))
                labelSize := shr(224, mload(add(p, 1)))
                label := add(p, 5)
                labelHash := keccak256(label, labelSize)
                p := add(label, labelSize)
                normHash := labelHash
                if eq(kind, 2) {
                    let n := shr(224, mload(p))
                    normHash := keccak256(add(p, 4), n)
                    p := add(p, add(4, n))
                }
            }
            (bool ok, bytes32 hash) = _normalize(label, labelSize);
            ++count;
            if (kind == 0 ? ok : !ok || hash != normHash) {
                if (fails++ < MAX_LOGS) {
                    bytes memory s = new bytes(labelSize);
                    assembly {
                        mcopy(add(s, 32), label, labelSize)
                    }
                    console.log("FAIL %s", kind == 0 ? "expected error" : ok ? "wrong norm" : "unexpected error");
                    console.logBytes(s);
                }
            }
        }
        console.log("shard %s: %s labels, %s failed", shard, count, fails);
        assertEq(fails, 0, "failures");
    }

    /// @dev Calls normalize() on the label at `label` in memory, returns the hash of the result.
    ///      Doesn't keep any memory: every label of the shard is in one buffer.
    function _normalize(uint256 label, uint256 size) internal view returns (bool ok, bytes32 hash) {
        address a = address(ens);
        bytes4 selector = ENSNormalize.normalize.selector;
        assembly {
            let m := mload(0x40)
            mstore(m, selector)
            mstore(add(m, 4), 0x20)
            mstore(add(m, 0x24), size)
            mcopy(add(m, 0x44), label, size)
            ok := staticcall(gas(), a, m, add(0x44, size), 0, 0)
            if ok {
                returndatacopy(m, 0, returndatasize())
                hash := keccak256(add(m, 0x40), mload(add(m, 0x20)))
            }
        }
    }

    function test_shard00() external {
        _run(0);
    }

    function test_shard01() external {
        _run(1);
    }

    function test_shard02() external {
        _run(2);
    }

    function test_shard03() external {
        _run(3);
    }

    function test_shard04() external {
        _run(4);
    }

    function test_shard05() external {
        _run(5);
    }

    function test_shard06() external {
        _run(6);
    }

    function test_shard07() external {
        _run(7);
    }

    function test_shard08() external {
        _run(8);
    }

    function test_shard09() external {
        _run(9);
    }

    function test_shard10() external {
        _run(10);
    }

    function test_shard11() external {
        _run(11);
    }

    function test_shard12() external {
        _run(12);
    }

    function test_shard13() external {
        _run(13);
    }

    function test_shard14() external {
        _run(14);
    }

    function test_shard15() external {
        _run(15);
    }

    function test_shard16() external {
        _run(16);
    }

    function test_shard17() external {
        _run(17);
    }

    function test_shard18() external {
        _run(18);
    }

    function test_shard19() external {
        _run(19);
    }

    function test_shard20() external {
        _run(20);
    }

    function test_shard21() external {
        _run(21);
    }

    function test_shard22() external {
        _run(22);
    }

    function test_shard23() external {
        _run(23);
    }

    function test_shard24() external {
        _run(24);
    }

    function test_shard25() external {
        _run(25);
    }

    function test_shard26() external {
        _run(26);
    }

    function test_shard27() external {
        _run(27);
    }

    function test_shard28() external {
        _run(28);
    }

    function test_shard29() external {
        _run(29);
    }

    function test_shard30() external {
        _run(30);
    }

    function test_shard31() external {
        _run(31);
    }
}
