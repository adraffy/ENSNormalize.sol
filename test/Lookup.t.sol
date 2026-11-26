// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ENSNormalize} from "../src/ENSNormalize.sol";
import {ENSNormalizeDataDeployer, LOOKUP_HASH} from "../src/generated/ENSNormalizeData.sol";

contract LookupHarness is ENSNormalize {
    constructor(address[] memory data) ENSNormalize(data) {}

    /// @dev keccak256 chain of _lookup() of the codepoints [start, end), 256 at a time.
    function lookupHash(bytes32 hash, uint256 start, uint256 end) external view returns (bytes32) {
        uint256 ctx = _context();
        uint256 buf = ctx + 0x10000;
        for (uint256 cp = start; cp < end; cp += 256) {
            for (uint256 i; i < 256; ++i) {
                uint256 v = _lookup(ctx, cp + i);
                assembly {
                    mstore(add(add(buf, 32), shl(5, i)), v)
                }
            }
            assembly {
                mstore(buf, hash)
                hash := keccak256(buf, 0x2020)
            }
        }
        return hash;
    }
}

/// @dev Checks the contract's lookup of every codepoint against the generator (scripts/make.ts).
contract LookupTest is Test {
    function test_lookup() external {
        LookupHarness ens = new LookupHarness(ENSNormalizeDataDeployer.deploy());
        bytes32 hash;
        for (uint256 cp; cp < 0x110000; cp += 0x10000) {
            hash = ens.lookupHash(hash, cp, cp + 0x10000);
        }
        assertEq(hash, LOOKUP_HASH);
    }
}
