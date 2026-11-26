// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {ENSNormalize} from "../src/ENSNormalize.sol";
import {ENSNormalizeDataDeployer} from "../src/generated/ENSNormalizeData.sol";

/// @dev forge script script/Deploy.s.sol --rpc-url $RPC_URL --broadcast
///      Deploys the data contracts, then ENSNormalize (one transaction each).
contract Deploy is Script {
    function run() external returns (ENSNormalize ens) {
        vm.startBroadcast();
        address[] memory data = ENSNormalizeDataDeployer.deploy();
        ens = new ENSNormalize(data);
        vm.stopBroadcast();
        for (uint256 i; i < data.length; ++i) {
            console.log("ENSNormalizeData%s: %s", i, data[i]);
        }
        console.log("ENSNormalize: %s", address(ens));
    }
}
