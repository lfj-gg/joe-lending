// SPDX-License-Identifier: UNLICENSED

pragma solidity ^0.8.20;

import {Script} from "lib/forge-std/src/Script.sol";
import {EnumerableSet} from "lib/openzeppelin-contracts/contracts/utils/structs/EnumerableSet.sol";

import {TrustedLiquidator} from "../../contracts/TrustedLiquidator/TrustedLiquidator.sol";

interface IJToken {
    function underlying() external view returns (address);
    function borrowBalanceCurrent(address account) external returns (uint256);
}

contract CloseMarketScript is Script {
    using EnumerableSet for EnumerableSet.AddressSet;

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
        address user;
    }

    TrustedLiquidator public liquidator = TrustedLiquidator(payable(0x0000000000000000000000000000000000000000));


    EnumerableSet.AddressSet internal users;
    mapping(address => bytes[]) public calls;

    function run(string calldata jsonPath) external {
        uint256 deployerPrivateKey = vm.envUint("DEPLOYER_PRIVATE_KEY");

        // forge-lint: disable-next-line(unsafe-cheatcode)
        string memory json = vm.readFile(jsonPath);

        RedeemAction[] memory redeems = abi.decode(vm.parseJson(json, ".redeemOnBehalf"), (RedeemAction[]));
        LiquidateAction[] memory liquidations = abi.decode(vm.parseJson(json, ".liquidate"), (LiquidateAction[]));
        RepayAction[] memory repays = abi.decode(vm.parseJson(json, ".repayBorrowBehalf"), (RepayAction[]));

        for (uint256 i; i < liquidations.length; i++) {
            LiquidateAction memory a = liquidations[i];
            users.add(a.user);
            calls[a.user].push(abi.encodeCall(TrustedLiquidator.liquidate, (a.jTokenBorrowed, a.jTokenCollateral, a.user)));
        }
        for (uint256 i; i < repays.length; i++) {
            RepayAction memory a = repays[i];
            users.add(a.user);
            calls[a.user].push(abi.encodeCall(TrustedLiquidator.repayBorrowBehalf, (a.jToken, a.user)));
        }
        for (uint256 i; i < redeems.length; i++) {
            RedeemAction memory a = redeems[i];
            users.add(a.user);
            calls[a.user].push(abi.encodeCall(TrustedLiquidator.redeemOnBehalf, (a.jToken, a.user)));
        }

        vm.startBroadcast(deployerPrivateKey);
        
        uint256 length = users.length();
        for (uint256 i; i < length; i++) {
            address user = users.at(i);
            bytes[] memory userCalls = calls[user];
            require(userCalls.length > 0, "no calls for user");

            liquidator.multicall(userCalls);
        }

        vm.stopBroadcast();
    }
}
