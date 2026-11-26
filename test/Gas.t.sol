// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console} from "forge-std/Test.sol";
import {ENSNormalize} from "../src/ENSNormalize.sol";
import {ENSNormalizeDataDeployer} from "../src/generated/ENSNormalizeData.sol";

/// @dev Gas report: forge test --mc GasTest -vv
///      The data contracts are warm here (created in the same transaction): a first call pays
///      an extra 2600 per data contract it reads (EIP-2929).
contract GasTest is Test {
    ENSNormalize ens;

    function setUp() external {
        ens = new ENSNormalize(ENSNormalizeDataDeployer.deploy());
    }

    function test_gasDeploy() external {
        uint256 total;
        uint256 g = gasleft();
        address[] memory data = ENSNormalizeDataDeployer.deploy();
        g -= gasleft();
        console.log("data contracts: %s gas (%s)", g, data.length);
        total += g;
        g = gasleft();
        new ENSNormalize(data);
        g -= gasleft();
        console.log("ENSNormalize: %s gas", g);
        total += g;
        console.log("total: %s gas (excluding calldata and 21000 per transaction)", total);
    }

    function _gas(string memory label) internal view {
        uint256 g = gasleft();
        ens.normalize(label);
        g -= gasleft();
        console.log("%s gas: %s", g, label);
    }

    function test_gasNormalize() external view {
        _gas("nick");
        _gas("RaFFY");
        _gas("vitalik-buterin");
        _gas(unicode"café");
        _gas(unicode"café");
        _gas(unicode"💩");
        _gas(unicode"🚴‍♂️");
        _gas(unicode"🏳️‍🌈");
        _gas(unicode"abc💩def");
        _gas(unicode"ＢＩＴＣＯＩＮ");
        _gas(unicode"привет");
        _gas(unicode"ελληνικά");
        _gas(unicode"日本語");
        _gas(unicode"한국어");
        _gas(unicode"عربي");
        _gas(unicode"नमस्ते");
        _gas(unicode"a’b");
    }
}
