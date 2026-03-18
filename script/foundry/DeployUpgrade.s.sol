// SPDX-License-Identifier: UNLICENSED

pragma solidity ^0.8.20;

import {Script} from "lib/forge-std/src/Script.sol";

import {TrustedLiquidator} from "../../contracts/TrustedLiquidator/TrustedLiquidator.sol";

contract DeployUpgradeScript is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        vm.startBroadcast(deployerPrivateKey);

        deployCode("Joetroller.sol");
        deployCode("JCollateralCapErc20Delegate.sol");
        new TrustedLiquidator(deployer);

        vm.stopBroadcast();
    }
}
