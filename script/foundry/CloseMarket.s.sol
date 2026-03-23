// SPDX-License-Identifier: UNLICENSED

pragma solidity ^0.8.20;

import {Script} from "lib/forge-std/src/Script.sol";

import {TrustedLiquidator} from "../../contracts/TrustedLiquidator/TrustedLiquidator.sol";
import {Escrow} from "../../contracts/TrustedLiquidator/Escrow.sol";

contract CloseMarketScript is Script {
    struct RedeemAction {
        address jToken;
        address user;
    }

    struct LiquidateAction {
        address jTokenBorrowed;
        address jTokenCollateral;
        address user;
    }

    struct RepayAction {
        address jToken;
        uint256 maxRepay;
        address user;
    }

    TrustedLiquidator public liquidator = TrustedLiquidator(payable(vm.envAddress("TRUSTED_LIQUIDATOR")));
    Escrow public escrow = Escrow(vm.envAddress("ESCROW"));

    /// @notice Execute a single batch from the action plan.
    /// @param jsonPath Path to the action plan JSON.
    /// @param batchIndex Zero-based index of the batch to execute.
    function run(string calldata jsonPath, uint256 batchIndex) external {
        uint256 deployerPrivateKey = vm.envUint("DEPLOY_PRIVATE_KEY");

        // forge-lint: disable-next-line(unsafe-cheatcode)
        string memory json = vm.readFile(jsonPath);
        string memory batchKey = string.concat(".batches[", vm.toString(batchIndex), "]");

        LiquidateAction[] memory liquidations = abi.decode(
            vm.parseJson(json, string.concat(batchKey, ".liquidate")),
            (LiquidateAction[])
        );
        RepayAction[] memory repays = abi.decode(
            vm.parseJson(json, string.concat(batchKey, ".repayBorrowBehalf")),
            (RepayAction[])
        );
        RedeemAction[] memory redeems = abi.decode(
            vm.parseJson(json, string.concat(batchKey, ".transferAndRedeem")),
            (RedeemAction[])
        );

        uint256 totalCalls = liquidations.length + repays.length + redeems.length;
        bytes[] memory calls = new bytes[](totalCalls);
        uint256 idx;

        for (uint256 i; i < liquidations.length; i++) {
            LiquidateAction memory a = liquidations[i];
            calls[idx++] = abi.encodeCall(
                TrustedLiquidator.liquidate, (a.jTokenBorrowed, a.jTokenCollateral, a.user)
            );
        }
        for (uint256 i; i < repays.length; i++) {
            RepayAction memory a = repays[i];
            calls[idx++] = abi.encodeCall(
                TrustedLiquidator.repayBorrowBehalf, (a.jToken, a.user, a.maxRepay)
            );
        }
        for (uint256 i; i < redeems.length; i++) {
            RedeemAction memory a = redeems[i];
            calls[idx++] = abi.encodeCall(
                TrustedLiquidator.transferAndRedeem, (address(escrow), a.jToken, a.user)
            );
        }

        vm.startBroadcast(deployerPrivateKey);
        liquidator.multicall(calls);
        vm.stopBroadcast();
    }
}
