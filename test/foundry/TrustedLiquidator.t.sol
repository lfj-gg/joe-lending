// SPDX-License-Identifier: UNLICENSED

pragma solidity ^0.8.20;

import {Test, StdChains} from "lib/forge-std/src/Test.sol";
import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";

import {TrustedLiquidator} from "../../contracts/TrustedLiquidator/TrustedLiquidator.sol";

interface IJoetroller {
    function admin() external view returns (address);
    function _setTrustedLiquidator(address newTrustedLiquidator) external returns (uint256);
    function _setPendingImplementation(address newPendingImplementation) external returns (uint256);
    function _become(address joetroller) external;
}

interface IJToken {
    function _setImplementation(address implementation_, bool allowResign, bytes memory becomeImplementationData)
        external;
    function balanceOfUnderlying(address account) external returns (uint256);
    function borrowBalanceCurrent(address account) external returns (uint256);
}

contract TrustedLiquidatorTest is Test {
    address public admin;
    TrustedLiquidator public liquidator;
    IJoetroller public joetroller = IJoetroller(0xdc13687554205E5b89Ac783db14bb5bba4A1eDaC);

    address public constant MIM = 0x130966628846BFd36ff31a822705796e8cb8C18D;
    address public constant JMIM = 0xcE095A9657A02025081E0607c8D8b081c76A75ea;

    address public constant BTC = 0x50b7545627a5162F82A992c33b87aDc75187B218;
    address public constant JBTC = 0x3fE38b7b610C0ACD10296fEf69d9b18eB7a9eB1F;

    address public constant USDC = 0xA7D7079b0FEaD91F3e65f86E8915Cb59c1a4C664;
    address public constant JUSDC = 0xEd6AaF91a2B084bd594DBd1245be3691F9f637aC;

    address public constant USDT = 0xc7198437980c041c805A1EDcbA50c1Ce5db95118;
    address public constant JUSDT = 0x8b650e26404AC6837539ca96812f0123601E4448;

    address public constant USER_DEPOSITED_MIM = 0x796BE5344E7076f363c7B6cb76Df11C9b1e91156;
    address public constant USER_BORROWED_MIM = 0xc3Fd4Acb7efFD92FC7a88c62b05776Fb6C4d0cDd;
    address public constant USER_MIM_BAD_DEBT = 0xa75D8527939adc9c370774b456727FD43a2272D9;
    address public constant USER_BORROWED_AGAINST_MIM = 0x3aa5F6e2Eb0F70699Ea9E72A90A0D8dA495FE53C;

    function setUp() public {
        vm.createSelectFork(StdChains.getChain("avalanche").rpcUrl, 80524427);

        admin = joetroller.admin();

        address newJoetroller = deployCode("Joetroller.sol");
        address newJmim = deployCode("JCollateralCapErc20Delegate.sol");
        liquidator = new TrustedLiquidator(admin);

        vm.startPrank(admin);
        joetroller._setPendingImplementation(newJoetroller);
        IJoetroller(newJoetroller)._become(address(joetroller));

        IJToken(JMIM)._setImplementation(newJmim, false, "");

        joetroller._setTrustedLiquidator(address(liquidator));
        vm.stopPrank();
    }

    function test_RedeemOnBehalf() public {
        uint256 mimBalance = IERC20(MIM).balanceOf(USER_DEPOSITED_MIM);
        uint256 underlyingBalance = IJToken(JMIM).balanceOfUnderlying(USER_DEPOSITED_MIM);
        uint256 jmimBalance = IERC20(JMIM).balanceOf(USER_DEPOSITED_MIM);

        assertGt(jmimBalance, 0, "test_RedeemOnBehalf::1");

        vm.startPrank(admin);
        liquidator.redeemOnBehalf(JMIM, USER_DEPOSITED_MIM);
        vm.stopPrank();

        assertEq(IERC20(JMIM).balanceOf(USER_DEPOSITED_MIM), 0, "test_RedeemOnBehalf::2");
        assertEq(IERC20(MIM).balanceOf(USER_DEPOSITED_MIM), mimBalance + underlyingBalance, "test_RedeemOnBehalf::3");
    }

    function test_Liquidate() public {
        uint256 jbtcBalance = IERC20(JBTC).balanceOf(USER_BORROWED_MIM);

        uint256 snapshot = vm.snapshotState();
        uint256 borrowed = IJToken(JMIM).borrowBalanceCurrent(USER_BORROWED_MIM);
        vm.revertToState(snapshot);

        assertGt(borrowed, 0, "test_Liquidate::1");

        deal(MIM, address(liquidator), borrowed);

        vm.startPrank(admin);
        liquidator.liquidate(JMIM, JBTC, USER_BORROWED_MIM);
        vm.stopPrank();

        assertLt(IERC20(JBTC).balanceOf(USER_BORROWED_MIM), jbtcBalance, "test_Liquidate::2");
        assertEq(IJToken(JMIM).borrowBalanceCurrent(USER_BORROWED_MIM), 0, "test_Liquidate::3");
        assertGt(IERC20(BTC).balanceOf(address(liquidator)), 0, "test_Liquidate::4");
    }

    function test_RepayBorrowBehalf() public {
        uint256 mimBalance = IERC20(MIM).balanceOf(USER_MIM_BAD_DEBT);

        uint256 snapshot = vm.snapshotState();
        uint256 borrowed = IJToken(JMIM).borrowBalanceCurrent(USER_MIM_BAD_DEBT);
        vm.revertToState(snapshot);

        assertGt(borrowed, 0, "test_RepayBorrowBehalf::1");

        deal(MIM, address(liquidator), borrowed);

        vm.startPrank(admin);
        liquidator.repayBorrowBehalf(JMIM, USER_MIM_BAD_DEBT);
        vm.stopPrank();

        assertEq(IJToken(JMIM).borrowBalanceCurrent(USER_MIM_BAD_DEBT), 0, "test_RepayBorrowBehalf::3");
        assertEq(IERC20(MIM).balanceOf(USER_MIM_BAD_DEBT), mimBalance, "test_RepayBorrowBehalf::4");
    }

    function test_LiquidateOtherTokens() public {
        uint256 mimBalance = IERC20(MIM).balanceOf(USER_BORROWED_AGAINST_MIM);

        uint256 snapshot = vm.snapshotState();
        uint256 borrowedUsdc = IJToken(JUSDC).borrowBalanceCurrent(USER_BORROWED_AGAINST_MIM);
        vm.revertToState(snapshot);

        assertGt(borrowedUsdc, 0, "test_LiquidateOtherTokens::1");

        deal(USDC, address(liquidator), borrowedUsdc);

        vm.startPrank(admin);
        liquidator.liquidate(JUSDC, JMIM, USER_BORROWED_AGAINST_MIM);
        liquidator.redeemOnBehalf(JMIM, USER_BORROWED_AGAINST_MIM);
        vm.stopPrank();

        assertEq(IJToken(JUSDC).borrowBalanceCurrent(USER_BORROWED_AGAINST_MIM), 0, "test_LiquidateOtherTokens::3");
        assertGt(IERC20(MIM).balanceOf(address(liquidator)), 0, "test_LiquidateOtherTokens::4");
        assertGt(IERC20(MIM).balanceOf(USER_BORROWED_AGAINST_MIM), mimBalance, "test_LiquidateOtherTokens::5");
    }
}
