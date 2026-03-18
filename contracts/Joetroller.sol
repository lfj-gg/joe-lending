// SPDX-License-Identifier: UNLICENSED

pragma solidity ^0.5.16;
pragma experimental ABIEncoderV2;

import "./JToken.sol";
import "./EIP20Interface.sol";
import "./ErrorReporter.sol";
import "./Exponential.sol";
import "./PriceOracle/PriceOracle.sol";
import "./JoetrollerInterface.sol";
import "./JoetrollerStorage.sol";
import "./RewardDistributor.sol";
import "./Unitroller.sol";

/**
 * @title Compound's Joetroller Contract
 * @author Compound (modified by Cream)
 */
contract Joetroller is JoetrollerV1Storage, JoetrollerInterface, JoetrollerErrorReporter, Exponential {
    /// @notice Emitted when an admin supports a market
    event MarketListed(JToken jToken);

    /// @notice Emitted when an admin delists a market
    event MarketDelisted(JToken jToken);

    /// @notice Emitted when an account enters a market
    event MarketEntered(JToken jToken, address account);

    /// @notice Emitted when an account exits a market
    event MarketExited(JToken jToken, address account);

    /// @notice Emitted when close factor is changed by admin
    event NewCloseFactor(uint256 oldCloseFactorMantissa, uint256 newCloseFactorMantissa);

    /// @notice Emitted when a collateral factor is changed by admin
    event NewCollateralFactor(JToken jToken, uint256 oldCollateralFactorMantissa, uint256 newCollateralFactorMantissa);

    /// @notice Emitted when liquidation incentive is changed by admin
    event NewLiquidationIncentive(uint256 oldLiquidationIncentiveMantissa, uint256 newLiquidationIncentiveMantissa);

    /// @notice Emitted when price oracle is changed
    event NewPriceOracle(PriceOracle oldPriceOracle, PriceOracle newPriceOracle);

    /// @notice Emitted when pause guardian is changed
    event NewPauseGuardian(address oldPauseGuardian, address newPauseGuardian);

    /// @notice Emitted when trusted liquidator is changed by admin
    event NewTrustedLiquidator(address oldTrustedLiquidator, address newTrustedLiquidator);

    /// @notice Emitted when trusted liquidator's liquidation incentive is changed by admin
    event NewTrustedLiquidationIncentiveMantissa(
        uint256 oldTrustedLiquidationIncentiveMantissa,
        uint256 newTrustedLiquidationIncentiveMantissa
    );

    /// @notice Emitted when an action is paused globally
    event ActionPaused(string action, bool pauseState);

    /// @notice Emitted when an action is paused on a market
    event ActionPaused(JToken jToken, string action, bool pauseState);

    /// @notice Emitted when borrow cap for a jToken is changed
    event NewBorrowCap(JToken indexed jToken, uint256 newBorrowCap);

    /// @notice Emitted when borrow cap guardian is changed
    event NewBorrowCapGuardian(address oldBorrowCapGuardian, address newBorrowCapGuardian);

    /// @notice Emitted when supply cap for a jToken is changed
    event NewSupplyCap(JToken indexed jToken, uint256 newSupplyCap);

    /// @notice Emitted when supply cap guardian is changed
    event NewSupplyCapGuardian(address oldSupplyCapGuardian, address newSupplyCapGuardian);

    /// @notice Emitted when protocol's credit limit has changed
    event CreditLimitChanged(address protocol, uint256 creditLimit);

    /// @notice Emitted when jToken version is changed
    event NewJTokenVersion(JToken jToken, Version oldVersion, Version newVersion);

    // No collateralFactorMantissa may exceed this value
    uint256 internal constant collateralFactorMaxMantissa = 0.9e18; // 0.9

    constructor() public {
        admin = msg.sender;
    }

    /**
     * @notice Return all of the markets
     * @dev The automatic getter may be used to access an individual market.
     * @return The list of market addresses
     */
    function getAllMarkets() public view returns (JToken[] memory) {
        return allMarkets;
    }

    function getBlockTimestamp() public view returns (uint256) {
        return block.timestamp;
    }

    /*** Assets You Are In ***/

    /**
     * @notice Returns the assets an account has entered
     * @param account The address of the account to pull assets for
     * @return A dynamic list with the assets the account has entered
     */
    function getAssetsIn(address account) external view returns (JToken[] memory) {
        JToken[] memory assetsIn = accountAssets[account];

        return assetsIn;
    }

    /**
     * @notice Returns whether the given account is entered in the given asset
     * @param account The address of the account to check
     * @param jToken The jToken to check
     * @return True if the account is in the asset, otherwise false.
     */
    function checkMembership(address account, JToken jToken) external view returns (bool) {
        return markets[address(jToken)].accountMembership[account];
    }

    /**
     * @notice Add assets to be included in account liquidity calculation
     * @param jTokens The list of addresses of the jToken markets to be enabled
     * @return Success indicator for whether each corresponding market was entered
     */
    function enterMarkets(address[] memory jTokens) public returns (uint256[] memory) {
        uint256 len = jTokens.length;

        uint256[] memory results = new uint256[](len);
        for (uint256 i = 0; i < len; i++) {
            JToken jToken = JToken(jTokens[i]);

            results[i] = uint256(addToMarketInternal(jToken, msg.sender));
        }

        return results;
    }

    /**
     * @notice Add the market to the borrower's "assets in" for liquidity calculations
     * @param jToken The market to enter
     * @param borrower The address of the account to modify
     * @return Success indicator for whether the market was entered
     */
    function addToMarketInternal(JToken jToken, address borrower) internal returns (Error) {
        Market storage marketToJoin = markets[address(jToken)];

        if (!marketToJoin.isListed) {
            // market is not listed, cannot join
            return Error.MARKET_NOT_LISTED;
        }

        if (marketToJoin.version == Version.COLLATERALCAP) {
            // register collateral for the borrower if the token is CollateralCap version.
            JCollateralCapErc20Interface(address(jToken)).registerCollateral(borrower);
        }

        if (marketToJoin.accountMembership[borrower] == true) {
            // already joined
            return Error.NO_ERROR;
        }

        // survived the gauntlet, add to list
        // NOTE: we store these somewhat redundantly as a significant optimization
        //  this avoids having to iterate through the list for the most common use cases
        //  that is, only when we need to perform liquidity checks
        //  and not whenever we want to check if an account is in a particular market
        marketToJoin.accountMembership[borrower] = true;
        accountAssets[borrower].push(jToken);

        emit MarketEntered(jToken, borrower);

        return Error.NO_ERROR;
    }

    /**
     * @notice Removes asset from sender's account liquidity calculation
     * @dev Sender must not have an outstanding borrow balance in the asset,
     *  or be providing necessary collateral for an outstanding borrow.
     * @param jTokenAddress The address of the asset to be removed
     * @return Whether or not the account successfully exited the market
     */
    function exitMarket(address jTokenAddress) external returns (uint256) {
        JToken jToken = JToken(jTokenAddress);
        /* Get sender tokensHeld and amountOwed underlying from the jToken */
        (uint256 oErr, uint256 tokensHeld, uint256 amountOwed, ) = jToken.getAccountSnapshot(msg.sender);
        require(oErr == 0, "exitMarket: getAccountSnapshot failed"); // semi-opaque error code

        /* Fail if the sender has a borrow balance */
        if (amountOwed != 0) {
            return fail(Error.NONZERO_BORROW_BALANCE, FailureInfo.EXIT_MARKET_BALANCE_OWED);
        }

        /* Fail if the sender is not permitted to redeem all of their tokens */
        uint256 allowed = redeemAllowedInternal(jTokenAddress, msg.sender, tokensHeld);
        if (allowed != 0) {
            return failOpaque(Error.REJECTION, FailureInfo.EXIT_MARKET_REJECTION, allowed);
        }

        Market storage marketToExit = markets[jTokenAddress];

        if (marketToExit.version == Version.COLLATERALCAP) {
            JCollateralCapErc20Interface(jTokenAddress).unregisterCollateral(msg.sender);
        }

        /* Return true if the sender is not already ‘in’ the market */
        if (!marketToExit.accountMembership[msg.sender]) {
            return uint256(Error.NO_ERROR);
        }

        /* Set jToken account membership to false */
        delete marketToExit.accountMembership[msg.sender];

        /* Delete jToken from the account’s list of assets */
        // load into memory for faster iteration
        JToken[] memory userAssetList = accountAssets[msg.sender];
        uint256 len = userAssetList.length;
        uint256 assetIndex = len;
        for (uint256 i = 0; i < len; i++) {
            if (userAssetList[i] == jToken) {
                assetIndex = i;
                break;
            }
        }

        // We *must* have found the asset in the list or our redundant data structure is broken
        assert(assetIndex < len);

        // copy last item in list to location of item to be removed, reduce length by 1
        JToken[] storage storedList = accountAssets[msg.sender];
        if (assetIndex != storedList.length - 1) {
            storedList[assetIndex] = storedList[storedList.length - 1];
        }
        storedList.length--;

        emit MarketExited(jToken, msg.sender);

        return uint256(Error.NO_ERROR);
    }

    /**
     * @notice Return whether a specific market is listed or not
     * @param jTokenAddress The address of the asset to be checked
     * @return Whether or not the market is listed
     */
    function isMarketListed(address jTokenAddress) public view returns (bool) {
        return markets[jTokenAddress].isListed;
    }

    /*** Policy Hooks ***/

    /**
     * @notice Checks if the account should be allowed to mint tokens in the given market
     * @param jToken The market to verify the mint against
     * @param minter The account which would get the minted tokens
     * @param mintAmount The amount of underlying being supplied to the market in exchange for tokens
     * @return 0 if the mint is allowed, otherwise a semi-opaque error code (See ErrorReporter.sol)
     */
    function mintAllowed(
        address jToken,
        address minter,
        uint256 mintAmount
    ) external returns (uint256) {
        // Pausing is a very serious situation - we revert to sound the alarms
        require(!mintGuardianPaused[jToken], "mint is paused");
        require(!isCreditAccount(minter), "credit account cannot mint");

        if (!isMarketListed(jToken)) {
            return uint256(Error.MARKET_NOT_LISTED);
        }

        uint256 supplyCap = supplyCaps[jToken];
        // Supply cap of 0 corresponds to unlimited supplying
        if (supplyCap != 0) {
            uint256 totalCash = JToken(jToken).getCash();
            uint256 totalBorrows = JToken(jToken).totalBorrows();
            uint256 totalReserves = JToken(jToken).totalReserves();
            // totalSupplies = totalCash + totalBorrows - totalReserves
            (MathError mathErr, uint256 totalSupplies) = addThenSubUInt(totalCash, totalBorrows, totalReserves);
            require(mathErr == MathError.NO_ERROR, "totalSupplies failed");

            uint256 nextTotalSupplies = add_(totalSupplies, mintAmount);
            require(nextTotalSupplies < supplyCap, "market supply cap reached");
        }

        // Keep the flywheel moving
        RewardDistributor(rewardDistributor).updateAndDistributeSupplierRewardsForToken(jToken, minter);

        return uint256(Error.NO_ERROR);
    }

    /**
     * @notice Validates mint and reverts on rejection. May emit logs.
     * @param jToken Asset being minted
     * @param minter The address minting the tokens
     * @param actualMintAmount The amount of the underlying asset being minted
     * @param mintTokens The number of tokens being minted
     */
    function mintVerify(
        address jToken,
        address minter,
        uint256 actualMintAmount,
        uint256 mintTokens
    ) external {
        // Shh - currently unused
        jToken;
        minter;
        actualMintAmount;
        mintTokens;

        // Shh - we don't ever want this hook to be marked pure
        if (false) {
            closeFactorMantissa = closeFactorMantissa;
        }
    }

    /**
     * @notice Checks if the account should be allowed to redeem tokens in the given market
     * @param jToken The market to verify the redeem against
     * @param redeemer The account which would redeem the tokens
     * @param redeemTokens The number of jTokens to exchange for the underlying asset in the market
     * @return 0 if the redeem is allowed, otherwise a semi-opaque error code (See ErrorReporter.sol)
     */
    function redeemAllowed(
        address jToken,
        address redeemer,
        uint256 redeemTokens
    ) external returns (uint256) {
        uint256 allowed = redeemAllowedInternal(jToken, redeemer, redeemTokens);
        if (allowed != uint256(Error.NO_ERROR)) {
            return allowed;
        }

        // Keep the flywheel going
        RewardDistributor(rewardDistributor).updateAndDistributeSupplierRewardsForToken(jToken, redeemer);
        return uint256(Error.NO_ERROR);
    }

    function redeemAllowedInternal(
        address jToken,
        address redeemer,
        uint256 redeemTokens
    ) internal view returns (uint256) {
        if (!isMarketListed(jToken)) {
            return uint256(Error.MARKET_NOT_LISTED);
        }

        /* If the redeemer is not 'in' the market, then we can bypass the liquidity check */
        if (!markets[jToken].accountMembership[redeemer]) {
            return uint256(Error.NO_ERROR);
        }

        /* Otherwise, perform a hypothetical liquidity check to guard against shortfall */
        (Error err, , uint256 shortfall) = getHypotheticalAccountLiquidityInternal(
            redeemer,
            JToken(jToken),
            redeemTokens,
            0
        );
        if (err != Error.NO_ERROR) {
            return uint256(err);
        }
        if (shortfall > 0) {
            return uint256(Error.INSUFFICIENT_LIQUIDITY);
        }

        return uint256(Error.NO_ERROR);
    }

    /**
     * @notice Validates redeem and reverts on rejection. May emit logs.
     * @param jToken Asset being redeemed
     * @param redeemer The address redeeming the tokens
     * @param redeemAmount The amount of the underlying asset being redeemed
     * @param redeemTokens The number of tokens being redeemed
     */
    function redeemVerify(
        address jToken,
        address redeemer,
        uint256 redeemAmount,
        uint256 redeemTokens
    ) external {
        // Shh - currently unused
        jToken;
        redeemer;

        // Require tokens is zero or amount is also zero
        if (redeemTokens == 0 && redeemAmount > 0) {
            revert("redeemTokens zero");
        }
    }

    /**
     * @notice Checks if the account should be allowed to borrow the underlying asset of the given market
     * @param jToken The market to verify the borrow against
     * @param borrower The account which would borrow the asset
     * @param borrowAmount The amount of underlying the account would borrow
     * @return 0 if the borrow is allowed, otherwise a semi-opaque error code (See ErrorReporter.sol)
     */
    function borrowAllowed(
        address jToken,
        address borrower,
        uint256 borrowAmount
    ) external returns (uint256) {
        // Pausing is a very serious situation - we revert to sound the alarms
        require(!borrowGuardianPaused[jToken], "borrow is paused");

        if (!isMarketListed(jToken)) {
            return uint256(Error.MARKET_NOT_LISTED);
        }

        if (!markets[jToken].accountMembership[borrower]) {
            // only jTokens may call borrowAllowed if borrower not in market
            require(msg.sender == jToken, "sender must be jToken");

            // attempt to add borrower to the market
            Error err = addToMarketInternal(JToken(jToken), borrower);
            if (err != Error.NO_ERROR) {
                return uint256(err);
            }

            // it should be impossible to break the important invariant
            assert(markets[jToken].accountMembership[borrower]);
        }

        if (oracle.getUnderlyingPrice(JToken(jToken)) == 0) {
            return uint256(Error.PRICE_ERROR);
        }

        uint256 borrowCap = borrowCaps[jToken];
        // Borrow cap of 0 corresponds to unlimited borrowing
        if (borrowCap != 0) {
            uint256 totalBorrows = JToken(jToken).totalBorrows();
            uint256 nextTotalBorrows = add_(totalBorrows, borrowAmount);
            require(nextTotalBorrows < borrowCap, "market borrow cap reached");
        }

        (Error err, , uint256 shortfall) = getHypotheticalAccountLiquidityInternal(
            borrower,
            JToken(jToken),
            0,
            borrowAmount
        );
        if (err != Error.NO_ERROR) {
            return uint256(err);
        }
        if (shortfall > 0) {
            return uint256(Error.INSUFFICIENT_LIQUIDITY);
        }

        // Keep the flywheel going
        Exp memory borrowIndex = Exp({mantissa: JToken(jToken).borrowIndex()});
        RewardDistributor(rewardDistributor).updateAndDistributeBorrowerRewardsForToken(jToken, borrower, borrowIndex);

        return uint256(Error.NO_ERROR);
    }

    /**
     * @notice Validates borrow and reverts on rejection. May emit logs.
     * @param jToken Asset whose underlying is being borrowed
     * @param borrower The address borrowing the underlying
     * @param borrowAmount The amount of the underlying asset requested to borrow
     */
    function borrowVerify(
        address jToken,
        address borrower,
        uint256 borrowAmount
    ) external {
        // Shh - currently unused
        jToken;
        borrower;
        borrowAmount;

        // Shh - we don't ever want this hook to be marked pure
        if (false) {
            closeFactorMantissa = closeFactorMantissa;
        }
    }

    /**
     * @notice Checks if the account should be allowed to repay a borrow in the given market
     * @param jToken The market to verify the repay against
     * @param payer The account which would repay the asset
     * @param borrower The account which borrowed the asset
     * @param repayAmount The amount of the underlying asset the account would repay
     * @return 0 if the repay is allowed, otherwise a semi-opaque error code (See ErrorReporter.sol)
     */
    function repayBorrowAllowed(
        address jToken,
        address payer,
        address borrower,
        uint256 repayAmount
    ) external returns (uint256) {
        // Shh - currently unused
        payer;
        borrower;
        repayAmount;

        if (!isMarketListed(jToken)) {
            return uint256(Error.MARKET_NOT_LISTED);
        }

        // Keep the flywheel going
        Exp memory borrowIndex = Exp({mantissa: JToken(jToken).borrowIndex()});
        RewardDistributor(rewardDistributor).updateAndDistributeBorrowerRewardsForToken(jToken, borrower, borrowIndex);
        return uint256(Error.NO_ERROR);
    }

    /**
     * @notice Validates repayBorrow and reverts on rejection. May emit logs.
     * @param jToken Asset being repaid
     * @param payer The address repaying the borrow
     * @param borrower The address of the borrower
     * @param actualRepayAmount The amount of underlying being repaid
     */
    function repayBorrowVerify(
        address jToken,
        address payer,
        address borrower,
        uint256 actualRepayAmount,
        uint256 borrowerIndex
    ) external {
        // Shh - currently unused
        jToken;
        payer;
        borrower;
        actualRepayAmount;
        borrowerIndex;

        // Shh - we don't ever want this hook to be marked pure
        if (false) {
            closeFactorMantissa = closeFactorMantissa;
        }
    }

    /**
     * @notice Checks if the liquidation should be allowed to occur
     * @param jTokenBorrowed Asset which was borrowed by the borrower
     * @param jTokenCollateral Asset which was used as collateral and will be seized
     * @param liquidator The address repaying the borrow and seizing the collateral
     * @param borrower The address of the borrower
     * @param repayAmount The amount of underlying being repaid
     */
    function liquidateBorrowAllowed(
        address jTokenBorrowed,
        address jTokenCollateral,
        address liquidator,
        address borrower,
        uint256 repayAmount
    ) external returns (uint256) {
        require(!isCreditAccount(borrower), "cannot liquidate credit account");

        if (!isMarketListed(jTokenBorrowed) || !isMarketListed(jTokenCollateral)) {
            return uint256(Error.MARKET_NOT_LISTED);
        }

        bool isTrustedLiquidator = liquidator == trustedLiquidator;

        /* The borrower must have shortfall in order to be liquidatable */
        if (!isTrustedLiquidator) {
            (Error err, , uint256 shortfall) = getAccountLiquidityInternal(borrower);
            if (err != Error.NO_ERROR) {
                return uint256(err);
            }
            if (shortfall == 0) {
                return uint256(Error.INSUFFICIENT_SHORTFALL);
            }
        }

        /* The liquidator may not repay more than what is allowed by the closeFactor */
        uint256 borrowBalance = JToken(jTokenBorrowed).borrowBalanceStored(borrower);
        if (!isTrustedLiquidator) {
            uint256 maxClose = mul_ScalarTruncate(Exp({mantissa: closeFactorMantissa}), borrowBalance);
            if (repayAmount > maxClose) {
                return uint256(Error.TOO_MUCH_REPAY);
            }
        }

        return uint256(Error.NO_ERROR);
    }

    /**
     * @notice Validates liquidateBorrow and reverts on rejection. May emit logs.
     * @param jTokenBorrowed Asset which was borrowed by the borrower
     * @param jTokenCollateral Asset which was used as collateral and will be seized
     * @param liquidator The address repaying the borrow and seizing the collateral
     * @param borrower The address of the borrower
     * @param actualRepayAmount The amount of underlying being repaid
     */
    function liquidateBorrowVerify(
        address jTokenBorrowed,
        address jTokenCollateral,
        address liquidator,
        address borrower,
        uint256 actualRepayAmount,
        uint256 seizeTokens
    ) external {
        // Shh - currently unused
        jTokenBorrowed;
        jTokenCollateral;
        liquidator;
        borrower;
        actualRepayAmount;
        seizeTokens;

        // Shh - we don't ever want this hook to be marked pure
        if (false) {
            closeFactorMantissa = closeFactorMantissa;
        }
    }

    /**
     * @notice Checks if the seizing of assets should be allowed to occur
     * @param jTokenCollateral Asset which was used as collateral and will be seized
     * @param jTokenBorrowed Asset which was borrowed by the borrower
     * @param liquidator The address repaying the borrow and seizing the collateral
     * @param borrower The address of the borrower
     * @param seizeTokens The number of collateral tokens to seize
     */
    function seizeAllowed(
        address jTokenCollateral,
        address jTokenBorrowed,
        address liquidator,
        address borrower,
        uint256 seizeTokens
    ) external returns (uint256) {
        // Pausing is a very serious situation - we revert to sound the alarms
        require(!seizeGuardianPaused, "seize is paused");
        require(!isCreditAccount(borrower), "cannot sieze from credit account");

        // Shh - currently unused
        liquidator;
        seizeTokens;

        if (!isMarketListed(jTokenCollateral) || !isMarketListed(jTokenBorrowed)) {
            return uint256(Error.MARKET_NOT_LISTED);
        }

        if (JToken(jTokenCollateral).joetroller() != JToken(jTokenBorrowed).joetroller()) {
            return uint256(Error.JOETROLLER_MISMATCH);
        }

        // Keep the flywheel moving
        RewardDistributor(rewardDistributor).updateAndDistributeSupplierRewardsForToken(jTokenCollateral, borrower);
        RewardDistributor(rewardDistributor).updateAndDistributeSupplierRewardsForToken(jTokenCollateral, liquidator);

        return uint256(Error.NO_ERROR);
    }

    /**
     * @notice Validates seize and reverts on rejection. May emit logs.
     * @param jTokenCollateral Asset which was used as collateral and will be seized
     * @param jTokenBorrowed Asset which was borrowed by the borrower
     * @param liquidator The address repaying the borrow and seizing the collateral
     * @param borrower The address of the borrower
     * @param seizeTokens The number of collateral tokens to seize
     */
    function seizeVerify(
        address jTokenCollateral,
        address jTokenBorrowed,
        address liquidator,
        address borrower,
        uint256 seizeTokens
    ) external {
        // Shh - currently unused
        jTokenCollateral;
        jTokenBorrowed;
        liquidator;
        borrower;
        seizeTokens;

        // Shh - we don't ever want this hook to be marked pure
        if (false) {
            closeFactorMantissa = closeFactorMantissa;
        }
    }

    /**
     * @notice Checks if the account should be allowed to transfer tokens in the given market
     * @param jToken The market to verify the transfer against
     * @param src The account which sources the tokens
     * @param dst The account which receives the tokens
     * @param transferTokens The number of jTokens to transfer
     * @return 0 if the transfer is allowed, otherwise a semi-opaque error code (See ErrorReporter.sol)
     */
    function transferAllowed(
        address jToken,
        address src,
        address dst,
        uint256 transferTokens
    ) external returns (uint256) {
        // Pausing is a very serious situation - we revert to sound the alarms
        require(!transferGuardianPaused, "transfer is paused");
        require(!isCreditAccount(dst), "cannot transfer to a credit account");

        // Shh - currently unused
        dst;

        // Currently the only consideration is whether or not
        //  the src is allowed to redeem this many tokens
        uint256 allowed = redeemAllowedInternal(jToken, src, transferTokens);
        if (allowed != uint256(Error.NO_ERROR)) {
            return allowed;
        }

        // Keep the flywheel moving
        RewardDistributor(rewardDistributor).updateAndDistributeSupplierRewardsForToken(jToken, src);
        RewardDistributor(rewardDistributor).updateAndDistributeSupplierRewardsForToken(jToken, dst);
        return uint256(Error.NO_ERROR);
    }

    /**
     * @notice Validates transfer and reverts on rejection. May emit logs.
     * @param jToken Asset being transferred
     * @param src The account which sources the tokens
     * @param dst The account which receives the tokens
     * @param transferTokens The number of jTokens to transfer
     */
    function transferVerify(
        address jToken,
        address src,
        address dst,
        uint256 transferTokens
    ) external {
        // Shh - currently unused
        jToken;
        src;
        dst;
        transferTokens;

        // Shh - we don't ever want this hook to be marked pure
        if (false) {
            closeFactorMantissa = closeFactorMantissa;
        }
    }

    /**
     * @notice Checks if the account should be allowed to transfer tokens in the given market
     * @param jToken The market to verify the transfer against
     * @param receiver The account which receives the tokens
     * @param amount The amount of the tokens
     * @param params The other parameters
     */

    function flashloanAllowed(
        address jToken,
        address receiver,
        uint256 amount,
        bytes calldata params
    ) external view returns (bool) {
        return !flashloanGuardianPaused[jToken];
    }

    /**
     * @notice Update JToken's version.
     * @param jToken Version of the asset being updated
     * @param newVersion The new version
     */
    function updateJTokenVersion(address jToken, Version newVersion) external {
        require(msg.sender == jToken, "only jToken could update its version");

        // This function will be called when a new JToken implementation becomes active.
        // If a new JToken is newly created, this market is not listed yet. The version of
        // this market will be taken care of when calling `_supportMarket`.
        if (isMarketListed(jToken)) {
            Version oldVersion = markets[jToken].version;
            markets[jToken].version = newVersion;

            emit NewJTokenVersion(JToken(jToken), oldVersion, newVersion);
        }
    }

    /**
     * @notice Check if the account is a credit account
     * @param account The account needs to be checked
     * @return The account is a credit account or not
     */
    function isCreditAccount(address account) public view returns (bool) {
        return creditLimits[account] > 0;
    }

    /*** Liquidity/Liquidation Calculations ***/

    /**
     * @dev Local vars for avoiding stack-depth limits in calculating account liquidity.
     *  Note that `jTokenBalance` is the number of jTokens the account owns in the market,
     *  whereas `borrowBalance` is the amount of underlying that the account has borrowed.
     */
    struct AccountLiquidityLocalVars {
        uint256 sumCollateral;
        uint256 sumBorrowPlusEffects;
        uint256 jTokenBalance;
        uint256 borrowBalance;
        uint256 exchangeRateMantissa;
        uint256 oraclePriceMantissa;
        Exp collateralFactor;
        Exp exchangeRate;
        Exp oraclePrice;
        Exp tokensToDenom;
    }

    /**
     * @notice Determine the current account liquidity wrt collateral requirements
     * @return (possible error code (semi-opaque),
                account liquidity in excess of collateral requirements,
     *          account shortfall below collateral requirements)
     */
    function getAccountLiquidity(address account)
        public
        view
        returns (
            uint256,
            uint256,
            uint256
        )
    {
        (Error err, uint256 liquidity, uint256 shortfall) = getHypotheticalAccountLiquidityInternal(
            account,
            JToken(0),
            0,
            0
        );

        return (uint256(err), liquidity, shortfall);
    }

    /**
     * @notice Determine the current account liquidity wrt collateral requirements
     * @return (possible error code,
                account liquidity in excess of collateral requirements,
     *          account shortfall below collateral requirements)
     */
    function getAccountLiquidityInternal(address account)
        internal
        view
        returns (
            Error,
            uint256,
            uint256
        )
    {
        return getHypotheticalAccountLiquidityInternal(account, JToken(0), 0, 0);
    }

    /**
     * @notice Determine what the account liquidity would be if the given amounts were redeemed/borrowed
     * @param jTokenModify The market to hypothetically redeem/borrow in
     * @param account The account to determine liquidity for
     * @param redeemTokens The number of tokens to hypothetically redeem
     * @param borrowAmount The amount of underlying to hypothetically borrow
     * @return (possible error code (semi-opaque),
                hypothetical account liquidity in excess of collateral requirements,
     *          hypothetical account shortfall below collateral requirements)
     */
    function getHypotheticalAccountLiquidity(
        address account,
        address jTokenModify,
        uint256 redeemTokens,
        uint256 borrowAmount
    )
        public
        view
        returns (
            uint256,
            uint256,
            uint256
        )
    {
        (Error err, uint256 liquidity, uint256 shortfall) = getHypotheticalAccountLiquidityInternal(
            account,
            JToken(jTokenModify),
            redeemTokens,
            borrowAmount
        );
        return (uint256(err), liquidity, shortfall);
    }

    /**
     * @notice Determine what the account liquidity would be if the given amounts were redeemed/borrowed
     * @param jTokenModify The market to hypothetically redeem/borrow in
     * @param account The account to determine liquidity for
     * @param redeemTokens The number of tokens to hypothetically redeem
     * @param borrowAmount The amount of underlying to hypothetically borrow
     * @dev Note that we calculate the exchangeRateStored for each collateral jToken using stored data,
     *  without calculating accumulated interest.
     * @return (possible error code,
                hypothetical account liquidity in excess of collateral requirements,
     *          hypothetical account shortfall below collateral requirements)
     */
    function getHypotheticalAccountLiquidityInternal(
        address account,
        JToken jTokenModify,
        uint256 redeemTokens,
        uint256 borrowAmount
    )
        internal
        view
        returns (
            Error,
            uint256,
            uint256
        )
    {
        // If credit limit is set to MAX, no need to check account liquidity.
        if (creditLimits[account] == uint256(-1)) {
            return (Error.NO_ERROR, uint256(-1), 0);
        }

        AccountLiquidityLocalVars memory vars; // Holds all our calculation results
        uint256 oErr;

        // For each asset the account is in
        JToken[] memory assets = accountAssets[account];
        for (uint256 i = 0; i < assets.length; i++) {
            JToken asset = assets[i];

            // Read the balances and exchange rate from the jToken
            (oErr, vars.jTokenBalance, vars.borrowBalance, vars.exchangeRateMantissa) = asset.getAccountSnapshot(
                account
            );
            if (oErr != 0) {
                // semi-opaque error code, we assume NO_ERROR == 0 is invariant between upgrades
                return (Error.SNAPSHOT_ERROR, 0, 0);
            }

            // Unlike compound protocol, getUnderlyingPrice is relatively expensive because we use ChainLink as our primary price feed.
            // If user has no supply / borrow balance on this asset, and user is not redeeming / borrowing this asset, skip it.
            if (vars.jTokenBalance == 0 && vars.borrowBalance == 0 && asset != jTokenModify) {
                continue;
            }

            vars.collateralFactor = Exp({mantissa: markets[address(asset)].collateralFactorMantissa});
            vars.exchangeRate = Exp({mantissa: vars.exchangeRateMantissa});

            // Get the normalized price of the asset
            vars.oraclePriceMantissa = oracle.getUnderlyingPrice(asset);
            if (vars.oraclePriceMantissa == 0) {
                return (Error.PRICE_ERROR, 0, 0);
            }
            vars.oraclePrice = Exp({mantissa: vars.oraclePriceMantissa});

            // Pre-compute a conversion factor from tokens -> ether (normalized price value)
            vars.tokensToDenom = mul_(mul_(vars.collateralFactor, vars.exchangeRate), vars.oraclePrice);

            // sumCollateral += tokensToDenom * jTokenBalance
            vars.sumCollateral = mul_ScalarTruncateAddUInt(vars.tokensToDenom, vars.jTokenBalance, vars.sumCollateral);

            // sumBorrowPlusEffects += oraclePrice * borrowBalance
            vars.sumBorrowPlusEffects = mul_ScalarTruncateAddUInt(
                vars.oraclePrice,
                vars.borrowBalance,
                vars.sumBorrowPlusEffects
            );

            // Calculate effects of interacting with jTokenModify
            if (asset == jTokenModify) {
                // redeem effect
                // sumBorrowPlusEffects += tokensToDenom * redeemTokens
                vars.sumBorrowPlusEffects = mul_ScalarTruncateAddUInt(
                    vars.tokensToDenom,
                    redeemTokens,
                    vars.sumBorrowPlusEffects
                );

                // borrow effect
                // sumBorrowPlusEffects += oraclePrice * borrowAmount
                vars.sumBorrowPlusEffects = mul_ScalarTruncateAddUInt(
                    vars.oraclePrice,
                    borrowAmount,
                    vars.sumBorrowPlusEffects
                );
            }
        }

        // If credit limit is set, no need to consider collateral.
        if (creditLimits[account] > 0) {
            vars.sumCollateral = creditLimits[account];
        }

        // These are safe, as the underflow condition is checked first
        if (vars.sumCollateral > vars.sumBorrowPlusEffects) {
            return (Error.NO_ERROR, vars.sumCollateral - vars.sumBorrowPlusEffects, 0);
        } else {
            return (Error.NO_ERROR, 0, vars.sumBorrowPlusEffects - vars.sumCollateral);
        }
    }

    /**
     * @notice Calculate number of tokens of collateral asset to seize given an underlying amount
     * @dev Used in liquidation (called in jToken.liquidateBorrowFresh)
     * @param jTokenBorrowed The address of the borrowed jToken
     * @param jTokenCollateral The address of the collateral jToken
     * @param actualRepayAmount The amount of jTokenBorrowed underlying to convert into jTokenCollateral tokens
     * @return (errorCode, number of jTokenCollateral tokens to be seized in a liquidation)
     */
    function liquidateCalculateSeizeTokens(
        address jTokenBorrowed,
        address jTokenCollateral,
        uint256 actualRepayAmount
    ) external view returns (uint256, uint256) {
        return liquidateCalculateSeizeTokens(address(0), jTokenBorrowed, jTokenCollateral, actualRepayAmount);
    }

    function liquidateCalculateSeizeTokens(
        address liquidator,
        address jTokenBorrowed,
        address jTokenCollateral,
        uint256 actualRepayAmount
    ) public view returns (uint256, uint256) {
        /* Read oracle prices for borrowed and collateral markets */
        uint256 priceBorrowedMantissa = oracle.getUnderlyingPrice(JToken(jTokenBorrowed));
        uint256 priceCollateralMantissa = oracle.getUnderlyingPrice(JToken(jTokenCollateral));
        if (priceBorrowedMantissa == 0 || priceCollateralMantissa == 0) {
            return (uint256(Error.PRICE_ERROR), 0);
        }

        /*
         * Get the exchange rate and calculate the number of collateral tokens to seize:
         *  seizeAmount = actualRepayAmount * liquidationIncentive * priceBorrowed / priceCollateral
         *  seizeTokens = seizeAmount / exchangeRate
         *   = actualRepayAmount * (liquidationIncentive * priceBorrowed) / (priceCollateral * exchangeRate)
         */
        uint256 exchangeRateMantissa = JToken(jTokenCollateral).exchangeRateStored(); // Note: reverts on error
        Exp memory numerator = mul_(
            Exp({mantissa: _getLiquidationIncentiveMantissa(liquidator)}),
            Exp({mantissa: priceBorrowedMantissa})
        );
        Exp memory denominator = mul_(Exp({mantissa: priceCollateralMantissa}), Exp({mantissa: exchangeRateMantissa}));
        Exp memory ratio = div_(numerator, denominator);
        uint256 seizeTokens = mul_ScalarTruncate(ratio, actualRepayAmount);

        return (uint256(Error.NO_ERROR), seizeTokens);
    }

    /**
     * @notice Get the liquidation incentive mantissa for the given liquidator
     * @param liquidator The address of the liquidator
     * @return The liquidation incentive mantissa
     */
    function _getLiquidationIncentiveMantissa(address liquidator) internal view returns (uint256) {
        if (liquidator == address(0) || liquidator != trustedLiquidator) {
            return liquidationIncentiveMantissa;
        }
        uint256 mantissa = trustedLiquidationIncentiveMantissa;
        if (mantissa == 0) {
            return liquidationIncentiveMantissa;
        }
        return mantissa;
    }

    /*** Admin Functions ***/

    function _setRewardDistributor(address payable newRewardDistributor) public returns (uint256) {
        if (msg.sender != admin) {
            return uint256(Error.UNAUTHORIZED);
        }
        (bool success, ) = newRewardDistributor.call.value(0)(abi.encodeWithSignature("initialize()", 0));
        if (!success) {
            return uint256(Error.REJECTION);
        }

        address oldRewardDistributor = rewardDistributor;
        rewardDistributor = newRewardDistributor;

        return uint256(Error.NO_ERROR);
    }

    /**
     * @notice Sets a new price oracle for the joetroller
     * @dev Admin function to set a new price oracle
     * @return uint 0=success, otherwise a failure (see ErrorReporter.sol for details)
     */
    function _setPriceOracle(PriceOracle newOracle) public returns (uint256) {
        // Check caller is admin
        if (msg.sender != admin) {
            return fail(Error.UNAUTHORIZED, FailureInfo.SET_PRICE_ORACLE_OWNER_CHECK);
        }

        // Track the old oracle for the joetroller
        PriceOracle oldOracle = oracle;

        // Set joetroller's oracle to newOracle
        oracle = newOracle;

        // Emit NewPriceOracle(oldOracle, newOracle)
        emit NewPriceOracle(oldOracle, newOracle);

        return uint256(Error.NO_ERROR);
    }

    /**
     * @notice Sets the closeFactor used when liquidating borrows
     * @dev Admin function to set closeFactor
     * @param newCloseFactorMantissa New close factor, scaled by 1e18
     * @return uint 0=success, otherwise a failure. (See ErrorReporter for details)
     */
    function _setCloseFactor(uint256 newCloseFactorMantissa) external returns (uint256) {
        // Check caller is admin
        if (msg.sender != admin) {
            return fail(Error.UNAUTHORIZED, FailureInfo.SET_CLOSE_FACTOR_OWNER_CHECK);
        }

        uint256 oldCloseFactorMantissa = closeFactorMantissa;
        closeFactorMantissa = newCloseFactorMantissa;
        emit NewCloseFactor(oldCloseFactorMantissa, closeFactorMantissa);

        return uint256(Error.NO_ERROR);
    }

    /**
     * @notice Sets the collateralFactor for a market
     * @dev Admin function to set per-market collateralFactor
     * @param jToken The market to set the factor on
     * @param newCollateralFactorMantissa The new collateral factor, scaled by 1e18
     * @return uint 0=success, otherwise a failure. (See ErrorReporter for details)
     */
    function _setCollateralFactor(JToken jToken, uint256 newCollateralFactorMantissa) external returns (uint256) {
        // Check caller is admin
        if (msg.sender != admin) {
            return fail(Error.UNAUTHORIZED, FailureInfo.SET_COLLATERAL_FACTOR_OWNER_CHECK);
        }

        // Verify market is listed
        Market storage market = markets[address(jToken)];
        if (!market.isListed) {
            return fail(Error.MARKET_NOT_LISTED, FailureInfo.SET_COLLATERAL_FACTOR_NO_EXISTS);
        }

        Exp memory newCollateralFactorExp = Exp({mantissa: newCollateralFactorMantissa});

        // Check collateral factor <= 0.9
        Exp memory highLimit = Exp({mantissa: collateralFactorMaxMantissa});
        if (lessThanExp(highLimit, newCollateralFactorExp)) {
            return fail(Error.INVALID_COLLATERAL_FACTOR, FailureInfo.SET_COLLATERAL_FACTOR_VALIDATION);
        }

        // If collateral factor != 0, fail if price == 0
        if (newCollateralFactorMantissa != 0 && oracle.getUnderlyingPrice(jToken) == 0) {
            return fail(Error.PRICE_ERROR, FailureInfo.SET_COLLATERAL_FACTOR_WITHOUT_PRICE);
        }

        // Set market's collateral factor to new collateral factor, remember old value
        uint256 oldCollateralFactorMantissa = market.collateralFactorMantissa;
        market.collateralFactorMantissa = newCollateralFactorMantissa;

        // Emit event with asset, old collateral factor, and new collateral factor
        emit NewCollateralFactor(jToken, oldCollateralFactorMantissa, newCollateralFactorMantissa);

        return uint256(Error.NO_ERROR);
    }

    /**
     * @notice Sets liquidationIncentive
     * @dev Admin function to set liquidationIncentive
     * @param newLiquidationIncentiveMantissa New liquidationIncentive scaled by 1e18
     * @return uint 0=success, otherwise a failure. (See ErrorReporter for details)
     */
    function _setLiquidationIncentive(uint256 newLiquidationIncentiveMantissa) external returns (uint256) {
        // Check caller is admin
        if (msg.sender != admin) {
            return fail(Error.UNAUTHORIZED, FailureInfo.SET_LIQUIDATION_INCENTIVE_OWNER_CHECK);
        }

        // Save current value for use in log
        uint256 oldLiquidationIncentiveMantissa = liquidationIncentiveMantissa;

        // Set liquidation incentive to new incentive
        liquidationIncentiveMantissa = newLiquidationIncentiveMantissa;

        // Emit event with old incentive, new incentive
        emit NewLiquidationIncentive(oldLiquidationIncentiveMantissa, newLiquidationIncentiveMantissa);

        return uint256(Error.NO_ERROR);
    }

    /**
     * @notice Add the market to the markets mapping and set it as listed
     * @dev Admin function to set isListed and add support for the market
     * @param jToken The address of the market (token) to list
     * @param version The version of the market (token)
     * @return uint 0=success, otherwise a failure. (See enum Error for details)
     */
    function _supportMarket(JToken jToken, Version version) external returns (uint256) {
        require(msg.sender == admin, "only admin may support market");
        require(!isMarketListed(address(jToken)), "market already listed");

        jToken.isJToken(); // Sanity check to make sure its really a JToken

        markets[address(jToken)] = Market({isListed: true, collateralFactorMantissa: 0, version: version});

        _addMarketInternal(address(jToken));

        emit MarketListed(jToken);

        return uint256(Error.NO_ERROR);
    }

    /**
     * @notice Remove the market from the markets mapping
     * @param jToken The address of the market (token) to delist
     */
    function _delistMarket(JToken jToken) external {
        require(msg.sender == admin, "only admin may delist market");
        require(isMarketListed(address(jToken)), "market not listed");
        require(jToken.totalSupply() == 0, "market not empty");

        jToken.isJToken(); // Sanity check to make sure its really a JToken

        delete markets[address(jToken)];

        for (uint256 i = 0; i < allMarkets.length; i++) {
            if (allMarkets[i] == jToken) {
                allMarkets[i] = allMarkets[allMarkets.length - 1];
                delete allMarkets[allMarkets.length - 1];
                allMarkets.length--;
                break;
            }
        }

        emit MarketDelisted(jToken);
    }

    function _addMarketInternal(address jToken) internal {
        for (uint256 i = 0; i < allMarkets.length; i++) {
            require(allMarkets[i] != JToken(jToken), "market already added");
        }
        allMarkets.push(JToken(jToken));
    }

    /**
     * @notice Admin function to change the Supply Cap Guardian
     * @param newSupplyCapGuardian The address of the new Supply Cap Guardian
     */
    function _setSupplyCapGuardian(address newSupplyCapGuardian) external {
        require(msg.sender == admin, "only admin can set supply cap guardian");

        // Save current value for inclusion in log
        address oldSupplyCapGuardian = supplyCapGuardian;

        // Store supplyCapGuardian with value newSupplyCapGuardian
        supplyCapGuardian = newSupplyCapGuardian;

        // Emit NewSupplyCapGuardian(OldSupplyCapGuardian, NewSupplyCapGuardian)
        emit NewSupplyCapGuardian(oldSupplyCapGuardian, newSupplyCapGuardian);
    }

    /**
     * @notice Set the given supply caps for the given jToken markets. Supplying that brings total supplys to or above supply cap will revert.
     * @dev Admin or supplyCapGuardian function to set the supply caps. A supply cap of 0 corresponds to unlimited supplying. If the total borrows
     *      already exceeded the cap, it will prevent anyone to borrow.
     * @param jTokens The addresses of the markets (tokens) to change the supply caps for
     * @param newSupplyCaps The new supply cap values in underlying to be set. A value of 0 corresponds to unlimited supplying.
     */
    function _setMarketSupplyCaps(JToken[] calldata jTokens, uint256[] calldata newSupplyCaps) external {
        require(
            msg.sender == admin || msg.sender == supplyCapGuardian,
            "only admin or supply cap guardian can set supply caps"
        );

        uint256 numMarkets = jTokens.length;
        uint256 numSupplyCaps = newSupplyCaps.length;

        require(numMarkets != 0 && numMarkets == numSupplyCaps, "invalid input");

        for (uint256 i = 0; i < numMarkets; i++) {
            supplyCaps[address(jTokens[i])] = newSupplyCaps[i];
            emit NewSupplyCap(jTokens[i], newSupplyCaps[i]);
        }
    }

    /**
     * @notice Set the given borrow caps for the given jToken markets. Borrowing that brings total borrows to or above borrow cap will revert.
     * @dev Admin or borrowCapGuardian function to set the borrow caps. A borrow cap of 0 corresponds to unlimited borrowing. If the total supplies
     *      already exceeded the cap, it will prevent anyone to mint.
     * @param jTokens The addresses of the markets (tokens) to change the borrow caps for
     * @param newBorrowCaps The new borrow cap values in underlying to be set. A value of 0 corresponds to unlimited borrowing.
     */
    function _setMarketBorrowCaps(JToken[] calldata jTokens, uint256[] calldata newBorrowCaps) external {
        require(
            msg.sender == admin || msg.sender == borrowCapGuardian,
            "only admin or borrow cap guardian can set borrow caps"
        );

        uint256 numMarkets = jTokens.length;
        uint256 numBorrowCaps = newBorrowCaps.length;

        require(numMarkets != 0 && numMarkets == numBorrowCaps, "invalid input");

        for (uint256 i = 0; i < numMarkets; i++) {
            borrowCaps[address(jTokens[i])] = newBorrowCaps[i];
            emit NewBorrowCap(jTokens[i], newBorrowCaps[i]);
        }
    }

    /**
     * @notice Admin function to change the Borrow Cap Guardian
     * @param newBorrowCapGuardian The address of the new Borrow Cap Guardian
     */
    function _setBorrowCapGuardian(address newBorrowCapGuardian) external {
        require(msg.sender == admin, "only admin can set borrow cap guardian");

        // Save current value for inclusion in log
        address oldBorrowCapGuardian = borrowCapGuardian;

        // Store borrowCapGuardian with value newBorrowCapGuardian
        borrowCapGuardian = newBorrowCapGuardian;

        // Emit NewBorrowCapGuardian(OldBorrowCapGuardian, NewBorrowCapGuardian)
        emit NewBorrowCapGuardian(oldBorrowCapGuardian, newBorrowCapGuardian);
    }

    /**
     * @notice Admin function to change the Pause Guardian
     * @param newPauseGuardian The address of the new Pause Guardian
     * @return uint 0=success, otherwise a failure. (See enum Error for details)
     */
    function _setPauseGuardian(address newPauseGuardian) public returns (uint256) {
        if (msg.sender != admin) {
            return fail(Error.UNAUTHORIZED, FailureInfo.SET_PAUSE_GUARDIAN_OWNER_CHECK);
        }

        // Save current value for inclusion in log
        address oldPauseGuardian = pauseGuardian;

        // Store pauseGuardian with value newPauseGuardian
        pauseGuardian = newPauseGuardian;

        // Emit NewPauseGuardian(OldPauseGuardian, NewPauseGuardian)
        emit NewPauseGuardian(oldPauseGuardian, pauseGuardian);

        return uint256(Error.NO_ERROR);
    }

    /**
     * @notice Admin function to change the Trusted Liquidator settings
     * @param newTrustedLiquidator The address of the new Trusted Liquidator
     * @return uint 0=success, otherwise a failure. (See enum Error for details)
    */
    function _setTrustedLiquidator(address newTrustedLiquidator) external returns (uint256) {
        if (msg.sender != admin) {
            return fail(Error.UNAUTHORIZED, FailureInfo.SET_TRUSTED_LIQUIDATOR_OWNER_CHECK);
        }

        // Save current value for inclusion in log
        address oldTrustedLiquidator = trustedLiquidator;

        // Store trustedLiquidator with value newTrustedLiquidator
        trustedLiquidator = newTrustedLiquidator;

        // Emit NewTrustedLiquidator(OldTrustedLiquidator, NewTrustedLiquidator)
        emit NewTrustedLiquidator(oldTrustedLiquidator, trustedLiquidator);

        return uint256(Error.NO_ERROR);
    }

    /**
     * @notice Admin function to change the Trusted Liquidator's liquidation incentive
     * @param newTrustedLiquidationIncentiveMantissa The new trusted liquidator's liquidation incentive
     * @return uint 0=success, otherwise a failure. (See enum Error for details)
    */
    function _setTrustedLiquidationIncentiveMantissa(uint256 newTrustedLiquidationIncentiveMantissa) external returns (uint256) {
        if (msg.sender != admin) {
            return fail(Error.UNAUTHORIZED, FailureInfo.SET_TRUSTED_LIQUIDATION_INCENTIVE_OWNER_CHECK);
        }
        
        // Save current value for inclusion in log
        uint256 oldTrustedLiquidationIncentiveMantissa = trustedLiquidationIncentiveMantissa;

        // Store trustedLiquidationIncentiveMantissa with value newTrustedLiquidationIncentiveMantissa
        trustedLiquidationIncentiveMantissa = newTrustedLiquidationIncentiveMantissa;

        // Emit NewTrustedLiquidationIncentiveMantissa(OldTrustedLiquidationIncentiveMantissa, NewTrustedLiquidationIncentiveMantissa)
        emit NewTrustedLiquidationIncentiveMantissa(oldTrustedLiquidationIncentiveMantissa, trustedLiquidationIncentiveMantissa);
        
        return uint256(Error.NO_ERROR);
    }

    function _setMintPaused(JToken jToken, bool state) public returns (bool) {
        require(isMarketListed(address(jToken)), "cannot pause a market that is not listed");
        require(msg.sender == pauseGuardian || msg.sender == admin, "only pause guardian and admin can pause");
        require(msg.sender == admin || state == true, "only admin can unpause");

        mintGuardianPaused[address(jToken)] = state;
        emit ActionPaused(jToken, "Mint", state);
        return state;
    }

    function _setBorrowPaused(JToken jToken, bool state) public returns (bool) {
        require(isMarketListed(address(jToken)), "cannot pause a market that is not listed");
        require(msg.sender == pauseGuardian || msg.sender == admin, "only pause guardian and admin can pause");
        require(msg.sender == admin || state == true, "only admin can unpause");

        borrowGuardianPaused[address(jToken)] = state;
        emit ActionPaused(jToken, "Borrow", state);
        return state;
    }

    function _setFlashloanPaused(JToken jToken, bool state) public returns (bool) {
        require(isMarketListed(address(jToken)), "cannot pause a market that is not listed");
        require(msg.sender == pauseGuardian || msg.sender == admin, "only pause guardian and admin can pause");
        require(msg.sender == admin || state == true, "only admin can unpause");

        flashloanGuardianPaused[address(jToken)] = state;
        emit ActionPaused(jToken, "Flashloan", state);
        return state;
    }

    function _setTransferPaused(bool state) public returns (bool) {
        require(msg.sender == pauseGuardian || msg.sender == admin, "only pause guardian and admin can pause");
        require(msg.sender == admin || state == true, "only admin can unpause");

        transferGuardianPaused = state;
        emit ActionPaused("Transfer", state);
        return state;
    }

    function _setSeizePaused(bool state) public returns (bool) {
        require(msg.sender == pauseGuardian || msg.sender == admin, "only pause guardian and admin can pause");
        require(msg.sender == admin || state == true, "only admin can unpause");

        seizeGuardianPaused = state;
        emit ActionPaused("Seize", state);
        return state;
    }

    function _become(Unitroller unitroller) public {
        require(msg.sender == unitroller.admin(), "only unitroller admin can change brains");
        require(unitroller._acceptImplementation() == 0, "change not authorized");
    }

    /**
     * @notice Sets whitelisted protocol's credit limit
     * @param protocol The address of the protocol
     * @param creditLimit The credit limit
     */
    function _setCreditLimit(address protocol, uint256 creditLimit) public {
        require(msg.sender == admin, "only admin can set protocol credit limit");

        creditLimits[protocol] = creditLimit;
        emit CreditLimitChanged(protocol, creditLimit);
    }

    /**
     * @notice Checks caller is admin, or this contract is becoming the new implementation
     */
    function adminOrInitializing() internal view returns (bool) {
        return msg.sender == admin || msg.sender == implementation;
    }

    /*** Reward distribution functions ***/

    /**
     * @notice Claim all the JOE/AVAX accrued by holder in all markets
     * @param holder The address to claim JOE/AVAX for
     */
    function claimReward(uint8 rewardType, address payable holder) public {
        RewardDistributor(rewardDistributor).claimReward(rewardType, holder);
    }

    /**
     * @notice Claim all the JOE/AVAX accrued by holder in the specified markets
     * @param holder The address to claim JOE/AVAX for
     * @param jTokens The list of markets to claim JOE/AVAX in
     */
    function claimReward(
        uint8 rewardType,
        address payable holder,
        JToken[] memory jTokens
    ) public {
        RewardDistributor(rewardDistributor).claimReward(rewardType, holder, jTokens);
    }

    /**
     * @notice Claim all JOE/AVAX  accrued by the holders
     * @param rewardType  0 = JOE, 1 = AVAX
     * @param holders The addresses to claim JOE/AVAX for
     * @param jTokens The list of markets to claim JOE/AVAX in
     * @param borrowers Whether or not to claim JOE/AVAX earned by borrowing
     * @param suppliers Whether or not to claim JOE/AVAX earned by supplying
     */
    function claimReward(
        uint8 rewardType,
        address payable[] memory holders,
        JToken[] memory jTokens,
        bool borrowers,
        bool suppliers
    ) public payable {
        RewardDistributor(rewardDistributor).claimReward(rewardType, holders, jTokens, borrowers, suppliers);
    }
}
