// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console} from "forge-std/Test.sol";
import {ENSNormalize} from "../src/ENSNormalize.sol";
import {ENSNormalizeDataDeployer} from "../src/generated/ENSNormalizeData.sol";

/// @dev There is no length limit: forge test --mc LongTest -vv
contract LongTest is Test {
    ENSNormalize ens;

    function setUp() external {
        ens = new ENSNormalize(ENSNormalizeDataDeployer.deploy());
    }

    function _repeat(string memory s, uint256 n) internal pure returns (string memory r) {
        for (uint256 i; i < n; ++i) r = string.concat(r, s);
    }

    function _g(string memory name, string memory s, string memory expect) internal view {
        uint256 g = gasleft();
        string memory out = ens.normalize(s);
        g -= gasleft();
        assertEq(out, expect);
        console.log("%s: %s bytes, %s gas", name, bytes(s).length, g);
    }

    function test_long() external view {
        for (uint256 n = 64; n <= 1024; n <<= 2) {
            _g("ascii", _repeat("A", n), _repeat("a", n));
            _g("latin", _repeat(unicode"é", n), _repeat(unicode"é", n));
            _g("cyrillic", _repeat(unicode"п", n), _repeat(unicode"п", n));
            _g("emoji", _repeat(unicode"💩", n), _repeat(unicode"💩", n));
            _g("nfc", _repeat(unicode"é", n), _repeat(unicode"é", n));
        }
    }
}
