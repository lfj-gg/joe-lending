// SPDX-License-Identifier: UNLICENSED

pragma solidity ^0.8.20;

import {Test, StdChains} from "lib/forge-std/src/Test.sol";

interface IJoetroller {
    function admin() external view returns (address);
    function oracle() external view returns (address);
    function closeFactorMantissa() external view returns (uint256);
    function liquidationIncentiveMantissa() external view returns (uint256);
    function pauseGuardian() external view returns (address);
    function borrowCapGuardian() external view returns (address);
    function supplyCapGuardian() external view returns (address);
    function rewardDistributor() external view returns (address);
    function allMarkets(uint256 index) external view returns (address);
    function isMarketListed(address jToken) external view returns (bool);
    function trustedLiquidator() external view returns (address);
    function borrowCaps(address jToken) external view returns (uint256);
    function supplyCaps(address jToken) external view returns (uint256);
    function _setPendingImplementation(address newPendingImpl) external returns (uint256);
    function _become(address joetroller) external;
}

interface IJToken {
    function admin() external view returns (address);
    function joetroller() external view returns (address);
    function underlying() external view returns (address);
    function totalSupply() external view returns (uint256);
    function totalBorrows() external view returns (uint256);
    function totalReserves() external view returns (uint256);
    function exchangeRateStored() external view returns (uint256);
    function borrowIndex() external view returns (uint256);
    function reserveFactorMantissa() external view returns (uint256);
    function interestRateModel() external view returns (address);
    function balanceOf(address account) external view returns (uint256);
    function borrowBalanceStored(address account) external view returns (uint256);
    function _setImplementation(address implementation_, bool allowResign, bytes memory becomeImplementationData)
        external;
    function implementation() external view returns (address);
    function totalCollateralTokens() external view returns (uint256);
    function collateralCap() external view returns (uint256);
    function name() external view returns (string memory);
    function symbol() external view returns (string memory);
    function decimals() external view returns (uint8);
}

contract UpgradeIntegrityTest is Test {
    address public admin;
    IJoetroller public joetroller = IJoetroller(0xdc13687554205E5b89Ac783db14bb5bba4A1eDaC);

    address public constant JMIM = 0xcE095A9657A02025081E0607c8D8b081c76A75ea;
    address public constant JUSDC = 0xEd6AaF91a2B084bd594DBd1245be3691F9f637aC;

    address public constant USER_DEPOSITED_MIM = 0x796BE5344E7076f363c7B6cb76Df11C9b1e91156;
    address public constant USER_BORROWED_MIM = 0xc3Fd4Acb7efFD92FC7a88c62b05776Fb6C4d0cDd;

    struct JoetrollerSnapshot {
        address adminAddr;
        address oracle;
        uint256 closeFactor;
        uint256 liquidationIncentive;
        address pauseGuardian;
        address borrowCapGuardian;
        address supplyCapGuardian;
        address rewardDistributor;
        uint256 allMarketsCount;
        address firstMarket;
    }

    struct JTokenSnapshot {
        address adminAddr;
        address joetrollerAddr;
        address underlying;
        uint256 totalSupply;
        uint256 totalBorrows;
        uint256 totalReserves;
        uint256 exchangeRate;
        uint256 borrowIndex;
        uint256 reserveFactor;
        address interestRateModel;
        uint256 totalCollateralTokens;
        uint256 collateralCap;
        string name;
        string symbol;
        uint8 decimals;
    }

    function _snapshotJoetroller() internal view returns (JoetrollerSnapshot memory s) {
        s.adminAddr = joetroller.admin();
        s.oracle = joetroller.oracle();
        s.closeFactor = joetroller.closeFactorMantissa();
        s.liquidationIncentive = joetroller.liquidationIncentiveMantissa();
        s.pauseGuardian = joetroller.pauseGuardian();
        s.borrowCapGuardian = joetroller.borrowCapGuardian();
        s.supplyCapGuardian = joetroller.supplyCapGuardian();
        s.rewardDistributor = joetroller.rewardDistributor();
        s.firstMarket = joetroller.allMarkets(0);

        uint256 count;
        for (uint256 i = 0; i < 50; i++) {
            try joetroller.allMarkets(i) {
                count++;
            } catch {
                break;
            }
        }
        s.allMarketsCount = count;
    }

    function _snapshotJToken(address jToken) internal view returns (JTokenSnapshot memory s) {
        IJToken jt = IJToken(jToken);
        s.adminAddr = jt.admin();
        s.joetrollerAddr = jt.joetroller();
        s.underlying = jt.underlying();
        s.totalSupply = jt.totalSupply();
        s.totalBorrows = jt.totalBorrows();
        s.totalReserves = jt.totalReserves();
        s.exchangeRate = jt.exchangeRateStored();
        s.borrowIndex = jt.borrowIndex();
        s.reserveFactor = jt.reserveFactorMantissa();
        s.interestRateModel = jt.interestRateModel();
        s.totalCollateralTokens = jt.totalCollateralTokens();
        s.collateralCap = jt.collateralCap();
        s.name = jt.name();
        s.symbol = jt.symbol();
        s.decimals = jt.decimals();
    }

    function test_JoetrollerStorageIntegrity() public {
        vm.createSelectFork(StdChains.getChain("avalanche").rpcUrl, 80524427);
        admin = joetroller.admin();

        JoetrollerSnapshot memory before = _snapshotJoetroller();
        bool jmimListedBefore = joetroller.isMarketListed(JMIM);
        bool jusdcListedBefore = joetroller.isMarketListed(JUSDC);
        uint256 jmimBorrowCapBefore = joetroller.borrowCaps(JMIM);
        uint256 jmimSupplyCapBefore = joetroller.supplyCaps(JMIM);

        address newJoetroller = deployCode("Joetroller.sol");
        vm.startPrank(admin);
        joetroller._setPendingImplementation(newJoetroller);
        IJoetroller(newJoetroller)._become(address(joetroller));
        vm.stopPrank();

        JoetrollerSnapshot memory after_ = _snapshotJoetroller();

        assertEq(after_.adminAddr, before.adminAddr, "admin changed");
        assertEq(after_.oracle, before.oracle, "oracle changed");
        assertEq(after_.closeFactor, before.closeFactor, "closeFactor changed");
        assertEq(after_.liquidationIncentive, before.liquidationIncentive, "liquidationIncentive changed");
        assertEq(after_.pauseGuardian, before.pauseGuardian, "pauseGuardian changed");
        assertEq(after_.borrowCapGuardian, before.borrowCapGuardian, "borrowCapGuardian changed");
        assertEq(after_.supplyCapGuardian, before.supplyCapGuardian, "supplyCapGuardian changed");
        assertEq(after_.rewardDistributor, before.rewardDistributor, "rewardDistributor changed");
        assertEq(after_.allMarketsCount, before.allMarketsCount, "allMarkets count changed");
        assertEq(after_.firstMarket, before.firstMarket, "firstMarket changed");
        assertEq(joetroller.isMarketListed(JMIM), jmimListedBefore, "JMIM listing changed");
        assertEq(joetroller.isMarketListed(JUSDC), jusdcListedBefore, "JUSDC listing changed");
        assertEq(joetroller.borrowCaps(JMIM), jmimBorrowCapBefore, "JMIM borrowCap changed");
        assertEq(joetroller.supplyCaps(JMIM), jmimSupplyCapBefore, "JMIM supplyCap changed");
        assertEq(joetroller.trustedLiquidator(), address(0), "trustedLiquidator not zero");
    }

    function test_JMimStorageIntegrity() public {
        vm.createSelectFork(StdChains.getChain("avalanche").rpcUrl, 80524427);
        admin = joetroller.admin();

        JTokenSnapshot memory before = _snapshotJToken(JMIM);
        uint256 userJmimBefore = IJToken(JMIM).balanceOf(USER_DEPOSITED_MIM);
        uint256 borrowerDebtBefore = IJToken(JMIM).borrowBalanceStored(USER_BORROWED_MIM);
        address implBefore = IJToken(JMIM).implementation();

        address newJmim = deployCode("JCollateralCapErc20Delegate.sol");
        vm.prank(admin);
        IJToken(JMIM)._setImplementation(newJmim, false, "");

        address implAfter = IJToken(JMIM).implementation();
        assertNotEq(implAfter, implBefore, "impl did not change");
        assertEq(implAfter, newJmim, "impl not set to new");

        JTokenSnapshot memory after_ = _snapshotJToken(JMIM);

        assertEq(after_.adminAddr, before.adminAddr, "admin changed");
        assertEq(after_.joetrollerAddr, before.joetrollerAddr, "joetroller changed");
        assertEq(after_.underlying, before.underlying, "underlying changed");
        assertEq(after_.totalSupply, before.totalSupply, "totalSupply changed");
        assertEq(after_.totalBorrows, before.totalBorrows, "totalBorrows changed");
        assertEq(after_.totalReserves, before.totalReserves, "totalReserves changed");
        assertEq(after_.exchangeRate, before.exchangeRate, "exchangeRate changed");
        assertEq(after_.borrowIndex, before.borrowIndex, "borrowIndex changed");
        assertEq(after_.reserveFactor, before.reserveFactor, "reserveFactor changed");
        assertEq(after_.interestRateModel, before.interestRateModel, "interestRateModel changed");
        assertEq(after_.totalCollateralTokens, before.totalCollateralTokens, "totalCollateralTokens changed");
        assertEq(after_.collateralCap, before.collateralCap, "collateralCap changed");
        assertEq(keccak256(bytes(after_.name)), keccak256(bytes(before.name)), "name changed");
        assertEq(keccak256(bytes(after_.symbol)), keccak256(bytes(before.symbol)), "symbol changed");
        assertEq(after_.decimals, before.decimals, "decimals changed");
        assertEq(IJToken(JMIM).balanceOf(USER_DEPOSITED_MIM), userJmimBefore, "user jToken balance changed");
        assertEq(IJToken(JMIM).borrowBalanceStored(USER_BORROWED_MIM), borrowerDebtBefore, "borrower debt changed");
    }

    function test_FullUpgradeStorageIntegrity() public {
        vm.createSelectFork(StdChains.getChain("avalanche").rpcUrl, 80524427);
        admin = joetroller.admin();

        JoetrollerSnapshot memory joeBefore = _snapshotJoetroller();
        JTokenSnapshot memory mimBefore = _snapshotJToken(JMIM);

        address newJoetroller = deployCode("Joetroller.sol");
        address newJmim = deployCode("JCollateralCapErc20Delegate.sol");

        vm.startPrank(admin);
        joetroller._setPendingImplementation(newJoetroller);
        IJoetroller(newJoetroller)._become(address(joetroller));
        IJToken(JMIM)._setImplementation(newJmim, false, "");
        vm.stopPrank();

        JoetrollerSnapshot memory joeAfter = _snapshotJoetroller();
        JTokenSnapshot memory mimAfter = _snapshotJToken(JMIM);

        assertEq(joeAfter.adminAddr, joeBefore.adminAddr, "joe admin");
        assertEq(joeAfter.oracle, joeBefore.oracle, "joe oracle");
        assertEq(joeAfter.closeFactor, joeBefore.closeFactor, "joe closeFactor");
        assertEq(joeAfter.allMarketsCount, joeBefore.allMarketsCount, "joe markets count");
        assertEq(mimAfter.totalSupply, mimBefore.totalSupply, "mim totalSupply");
        assertEq(mimAfter.totalBorrows, mimBefore.totalBorrows, "mim totalBorrows");
        assertEq(mimAfter.exchangeRate, mimBefore.exchangeRate, "mim exchangeRate");
    }
}
