// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console} from "forge-std/Test.sol";
import {ENSNormalize} from "../src/ENSNormalize.sol";
import {ENSNormalizeDataDeployer} from "../src/generated/ENSNormalizeData.sol";

/// @dev Gas report: forge test --mc GasTest -vv
///      Writes snapshots/normalize.json and snapshots/deploy.json (the gas of the call or create itself).
///      The data contracts are warm here (created in the same transaction): a first call pays
///      an extra 2600 per data contract it reads (EIP-2929).
contract GasTest is Test {
    ENSNormalize ens;

    function setUp() external {
        ens = new ENSNormalize(ENSNormalizeDataDeployer.deploy());
    }

    function test_gasDeploy() external {
        address[] memory data = ENSNormalizeDataDeployer.deploy();
        uint256 total;
        for (uint256 i; i < data.length; ++i) {
            // code deposit + create, without the initcode's calldata
            uint256 g = 32000 + 200 * data[i].code.length;
            vm.snapshotValue("deploy", string.concat("data", vm.toString(i)), g);
            total += g;
        }
        new ENSNormalize(data);
        total += vm.snapshotGasLastFrame("deploy", "ENSNormalize");
        vm.snapshotValue("deploy", "total", total);
        console.log("deploy: %s gas", total);
    }

    function _gas(string memory name, string memory label) internal {
        ens.normalize(label);
        uint256 g = vm.snapshotGasLastFrame("normalize", name);
        console.log("%s gas: %s", g, label);
    }

    function _repeat(string memory s, uint256 n) internal pure returns (string memory r) {
        for (uint256 i; i < n; ++i) {
            r = string.concat(r, s);
        }
    }

    function test_gasNormalize() external {
        // ascii
        _gas("ascii: nick", "nick");
        _gas("ascii: vitalik-buterin", "vitalik-buterin");
        _gas("ascii: 40 hex", "d8da6bf26964af9d7eed9e03e53415d37aa96045");
        _gas("ascii: RaFFY", "RaFFY");
        _gas("ascii: _dnslink", "_dnslink");
        _gas("ascii: a x 255", _repeat("a", 255));
        // latin
        _gas(unicode"latin: café", unicode"café");
        _gas(unicode"latin: cafe + 0301", unicode"café");
        _gas(unicode"latin: a’b", unicode"a’b");
        _gas(unicode"latin: é x 100", _repeat(unicode"é", 100));
        _gas(unicode"latin: e + 0301 x 100", _repeat(unicode"e\u0301", 100));
        // emoji
        _gas(unicode"emoji: 💩", unicode"💩");
        _gas(unicode"emoji: 🚴‍♂️", unicode"🚴‍♂️");
        _gas(unicode"emoji: 🏳️‍🌈", unicode"🏳️‍🌈");
        _gas(unicode"emoji: 💩💩💩", unicode"💩💩💩");
        _gas(unicode"emoji: 123💩", unicode"123💩");
        _gas(unicode"emoji: abc💩def", unicode"abc💩def");
        _gas(unicode"emoji: 💩 x 100", _repeat(unicode"💩", 100));
        // mapped
        _gas(unicode"mapped: ＢＩＴＣＯＩＮ", unicode"ＢＩＴＣＯＩＮ");
        // scripts
        _gas(unicode"script: привет", unicode"привет");
        _gas(unicode"script: ελληνικά", unicode"ελληνικά");
        _gas(unicode"script: 日本語", unicode"日本語");
        _gas(unicode"script: 한국어", unicode"한국어");
        _gas(unicode"script: عربي", unicode"عربي");
        _gas(unicode"script: नमस्ते", unicode"नमस्ते");
        _gas(unicode"script: ไทย", unicode"ไทย");
    }
}
