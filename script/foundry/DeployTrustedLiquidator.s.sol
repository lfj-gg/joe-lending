// SPDX-License-Identifier: UNLICENSED

pragma solidity ^0.8.20;

import {Script} from "lib/forge-std/src/Script.sol";

import {Escrow} from "../../contracts/TrustedLiquidator/Escrow.sol";
import {TrustedLiquidator} from "../../contracts/TrustedLiquidator/TrustedLiquidator.sol";

interface IJoetroller {
    function getAllMarkets() external view returns (address[] memory);
}

interface IJToken {
    function mintNative() external payable returns (uint256);
}

contract DeployTrustedLiquidatorScript is Script {
    struct Market {
        bool isNative;
        address jToken;
        address newImplementation;
    }

    uint256 public immutable ESCROW_DEADLINE = block.timestamp + 365 days;

    function run()
        external
        returns (
            address newJoetrollerDelegate,
            address erc20Delegate,
            address nativeDelegate,
            address liquidator,
            address escrow,
            Market[] memory markets
        )
    {
        address joetrollerAddr = vm.envAddress("JOETROLLER");
        uint256 deployerPrivateKey = vm.envUint("DEPLOY_PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        address[] memory allMarkets = IJoetroller(joetrollerAddr).getAllMarkets();

        vm.startBroadcast(deployerPrivateKey);

        // Core contracts
        newJoetrollerDelegate = deployCode("Joetroller.sol");
        erc20Delegate = deployCode("JCollateralCapErc20Delegate.sol");
        nativeDelegate = deployCode("JWrappedNativeDelegate.sol");
        liquidator = address(new TrustedLiquidator(deployer));
        escrow = address(new Escrow(liquidator, ESCROW_DEADLINE));

        markets = new Market[](allMarkets.length);

        vm.stopBroadcast();

        // Log market -> delegate mapping
        for (uint256 i = 0; i < allMarkets.length; i++) {
            bool isNative = _isNativeWrapper(allMarkets[i]);
            address delegate = isNative ? nativeDelegate : erc20Delegate;
            markets[i] = Market({isNative: isNative, jToken: allMarkets[i], newImplementation: delegate});
        }
    }

    /// @notice Detect if a jToken is a JWrappedNative by checking for mintNative()
    function _isNativeWrapper(address jToken) internal view returns (bool) {
        (bool success, bytes memory data) = jToken.staticcall("");
        require(!success, "call should fail");
        if (data.length <= 8) return false;
        bytes memory expected =
            abi.encodeWithSignature("Error(string)", "only wrapped native contract could send native token");
        return keccak256(data) == keccak256(expected);
    }
}
