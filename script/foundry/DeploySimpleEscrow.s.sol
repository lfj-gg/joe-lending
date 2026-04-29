// SPDX-License-Identifier: UNLICENSED

pragma solidity ^0.8.20;

import {Script, console} from "lib/forge-std/src/Script.sol";

import {SimpleEscrow} from "../../contracts/TrustedLiquidator/SimpleEscrow.sol";

/// @notice Deploys the wind-down `SimpleEscrow`. The escrow auto-discovers every
///         market on the Joetroller via `getAllMarkets()` in its constructor;
///         markets listed after deployment are NOT picked up.
///
/// Required env vars:
///   JOETROLLER          — address of the Joetroller
///   ESCROW_ADMIN        — owner of the escrow (multisig)
///   ESCROW_DEADLINE     — unix timestamp; must be strictly in the future
///   DEPLOY_PRIVATE_KEY  — broadcaster
///
/// Post-deploy steps (NOT done here — must be executed by the multisig):
///   1. `joetroller._setTrustedLiquidator(escrow)` so `claim` can call jToken.burn
///   2. Fund the escrow with the underlying tokens to back every recorded claim
///   3. `escrow.set(positions[])` to record per-user payouts (chunked as needed)
contract DeploySimpleEscrowScript is Script {
    function run() external returns (address escrow) {
        address joetroller = vm.envAddress("JOETROLLER");
        address admin = vm.envAddress("ESCROW_ADMIN");
        uint256 deadline = vm.envUint("ESCROW_DEADLINE");
        uint256 deployerPrivateKey = vm.envUint("DEPLOY_PRIVATE_KEY");

        require(deadline > block.timestamp, "deadline must be in the future");
        require(admin != address(0), "admin cannot be zero");

        vm.startBroadcast(deployerPrivateKey);
        escrow = address(new SimpleEscrow(admin, joetroller, deadline));
        vm.stopBroadcast();

        console.log("SimpleEscrow deployed at:", escrow);
        console.log("  admin:    ", admin);
        console.log("  joetroller:", joetroller);
        console.log("  deadline: ", deadline);
    }
}
