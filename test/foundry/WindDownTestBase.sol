// SPDX-License-Identifier: UNLICENSED

pragma solidity ^0.8.20;

import {Test, StdChains} from "lib/forge-std/src/Test.sol";
import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";

import {SimpleEscrow} from "../../contracts/TrustedLiquidator/SimpleEscrow.sol";

interface IJoetroller {
    function admin() external view returns (address);
    function trustedLiquidator() external view returns (address);
    function _setTrustedLiquidator(address newTrustedLiquidator) external returns (uint256);
    function getAllMarkets() external view returns (address[] memory);
    function enterMarkets(address[] calldata jTokens) external returns (uint256[] memory);
    function checkMembership(address account, address jToken) external view returns (bool);
    function _setMintPaused(address jToken, bool state) external returns (bool);
    function _setBorrowPaused(address jToken, bool state) external returns (bool);
}

interface IJTokenAdmin {
    function _setImplementation(address newImpl, bool allowResign, bytes memory data) external;
    function admin() external view returns (address);
    function implementation() external view returns (address);
    function totalSupply() external view returns (uint256);
    function totalBorrows() external view returns (uint256);
    function totalReserves() external view returns (uint256);
    function exchangeRateStored() external view returns (uint256);
    function borrowIndex() external view returns (uint256);
    function reserveFactorMantissa() external view returns (uint256);
    function interestRateModel() external view returns (address);
    function totalCollateralTokens() external view returns (uint256);
    function collateralCap() external view returns (uint256);
    function balanceOf(address account) external view returns (uint256);
    function accountCollateralTokens(address account) external view returns (uint256);
    function borrowBalanceStored(address account) external view returns (uint256);
    function underlying() external view returns (address);
    function mint(uint256 amount) external returns (uint256);
    function mintNative() external payable returns (uint256);
    function getCash() external view returns (uint256);
    function _setInterestRateModel(address newIRM) external returns (uint256);
    function accrueInterest() external returns (uint256);
    function _setReserveFactor(uint256 newMantissa) external returns (uint256);
    function _setPendingAdmin(address payable newPendingAdmin) external returns (uint256);
}

/// @notice Forks Avalanche, deploys fresh wind-down delegates, upgrades JUSDC and
///         JAVAX to use them, mints test balances on each (before upgrade so the
///         path still works), and wires SimpleEscrow as the trustedLiquidator.
abstract contract WindDownTestBase is Test {
    IJoetroller public joetroller = IJoetroller(0xdc13687554205E5b89Ac783db14bb5bba4A1eDaC);

    address public constant USDC = 0xA7D7079b0FEaD91F3e65f86E8915Cb59c1a4C664;
    address public constant JUSDC = 0xEd6AaF91a2B084bd594DBd1245be3691F9f637aC;
    address public constant WAVAX = 0xB31f66AA3C1e785363F0875A1B74E27b85FD66c7;
    address public constant JAVAX = 0xC22F01ddc8010Ee05574028528614634684EC29e;

    uint256 public constant ESCROW_DEADLINE = 365 days;
    uint256 public constant MINT_USDC = 1_000_000_000; // 1,000 USDC (6 dec)
    uint256 public constant MINT_AVAX = 10 ether;

    address public admin;
    address public alice = address(0xA11CE);
    address public bob = address(0xB0B);
    address public treasury = address(0x7EA);

    address public jCollateralDelegate; // wind-down delegate (compiled with reverts/burn/sweep)
    address public jWrappedDelegate;
    SimpleEscrow public escrow;
    uint256 public deadline;

    function _setupFork() internal {
        vm.createSelectFork(StdChains.getChain("avalanche").rpcUrl, 84123072);
        admin = joetroller.admin();
    }

    function _mintTestBalancesBeforeUpgrade() internal {
        // Alice mints jUSDC and enters as collateral.
        deal(USDC, alice, MINT_USDC);
        vm.startPrank(alice);
        IERC20(USDC).approve(JUSDC, type(uint256).max);
        require(IJTokenAdmin(JUSDC).mint(MINT_USDC) == 0, "mint jusdc failed");
        address[] memory toEnter = new address[](1);
        toEnter[0] = JUSDC;
        joetroller.enterMarkets(toEnter);
        vm.stopPrank();

        // Bob mints jAVAX with native AVAX, no collateral entry.
        vm.deal(bob, MINT_AVAX);
        vm.prank(bob);
        require(IJTokenAdmin(JAVAX).mintNative{value: MINT_AVAX}() == 0, "mint javax failed");
    }

    function _deployAndUpgradeDelegates() internal {
        jCollateralDelegate = deployCode("JCollateralCapErc20Delegate.sol");
        jWrappedDelegate = deployCode("JWrappedNativeDelegate.sol");

        vm.startPrank(admin);
        IJTokenAdmin(JUSDC)._setImplementation(jCollateralDelegate, false, "");
        IJTokenAdmin(JAVAX)._setImplementation(jWrappedDelegate, false, "");
        vm.stopPrank();
    }

    function _deployEscrowAndRegister() internal {
        deadline = block.timestamp + ESCROW_DEADLINE;
        escrow = new SimpleEscrow(admin, address(joetroller), deadline);

        vm.prank(admin);
        joetroller._setTrustedLiquidator(address(escrow));
    }

    function _fullSetup() internal {
        _setupFork();
        _mintTestBalancesBeforeUpgrade();
        _deployAndUpgradeDelegates();
        _deployEscrowAndRegister();
    }
}
