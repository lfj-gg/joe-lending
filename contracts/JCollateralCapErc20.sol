// SPDX-License-Identifier: UNLICENSED

pragma solidity ^0.5.16;

import "./JToken.sol";
import "./ERC3156FlashLenderInterface.sol";
import "./ERC3156FlashBorrowerInterface.sol";

/**
 * @title Cream's JCollateralCapErc20 Contract
 * @notice JTokens which wrap an EIP-20 underlying with collateral cap
 * @author Cream
 */
contract JCollateralCapErc20 is JToken, JCollateralCapErc20Interface, JProtocolSeizeShareStorage {
    /**
     * @notice Initialize the new money market
     * @param underlying_ The address of the underlying asset
     * @param joetroller_ The address of the Joetroller
     * @param interestRateModel_ The address of the interest rate model
     * @param initialExchangeRateMantissa_ The initial exchange rate, scaled by 1e18
     * @param name_ ERC-20 name of this token
     * @param symbol_ ERC-20 symbol of this token
     * @param decimals_ ERC-20 decimal precision of this token
     */
    function initialize(
        address underlying_,
        JoetrollerInterface joetroller_,
        InterestRateModel interestRateModel_,
        uint256 initialExchangeRateMantissa_,
        string memory name_,
        string memory symbol_,
        uint8 decimals_
    ) public {
        // JToken initialize does the bulk of the work
        super.initialize(joetroller_, interestRateModel_, initialExchangeRateMantissa_, name_, symbol_, decimals_);

        // Set underlying and sanity check it
        underlying = underlying_;
        EIP20Interface(underlying).totalSupply();
    }

    /*** User Interface ***/

    /**
     * @notice Sender supplies assets into the market and receives jTokens in exchange
     * @dev Accrues interest whether or not the operation succeeds, unless reverted
     * @param mintAmount The amount of the underlying asset to supply
     * @return uint 0=success, otherwise a failure (see ErrorReporter.sol for details)
     */
    function mint(uint256 mintAmount) external returns (uint256) {
        (uint256 err, ) = mintInternal(mintAmount, false);
        return err;
    }

    /**
     * @notice Sender redeems jTokens in exchange for the underlying asset
     * @dev Accrues interest whether or not the operation succeeds, unless reverted
     * @param redeemTokens The number of jTokens to redeem into underlying
     * @return uint 0=success, otherwise a failure (see ErrorReporter.sol for details)
     */
    function redeem(uint256 redeemTokens) external returns (uint256) {
        return redeemInternal(redeemTokens, false);
    }

    /**
     * @notice Sender redeems jTokens in exchange for the underlying asset
     * @dev Accrues interest whether or not the operation succeeds, unless reverted
     * @param redeemer The address of the account which is redeeming the tokens
     * @param redeemTokens The number of jTokens to redeem into underlying
     * @return uint 0=success, otherwise a failure (see ErrorReporter.sol for details)
     */
    function redeemOnBehalf(address redeemer, uint256 redeemTokens) external returns (uint256) {
        if (JoetrollerInterfaceExtension(address(joetroller)).trustedLiquidator() != msg.sender) {
            return fail(Error.UNAUTHORIZED, FailureInfo.REDEEM_ON_BEHALF_NOT_TRUSTED_LIQUIDATOR);
        }
        return redeemInternal(redeemer, redeemTokens, false);
    }

    /**
     * @notice Sender redeems jTokens in exchange for a specified amount of underlying asset
     * @dev Accrues interest whether or not the operation succeeds, unless reverted
     * @param redeemAmount The amount of underlying to redeem
     * @return uint 0=success, otherwise a failure (see ErrorReporter.sol for details)
     */
    function redeemUnderlying(uint256 redeemAmount) external returns (uint256) {
        return redeemUnderlyingInternal(redeemAmount, false);
    }

    /**
     * @notice Sender borrows assets from the protocol to their own address
     * @param borrowAmount The amount of the underlying asset to borrow
     * @return uint 0=success, otherwise a failure (see ErrorReporter.sol for details)
     */
    function borrow(uint256 borrowAmount) external returns (uint256) {
        return borrowInternal(borrowAmount, false);
    }

    /**
     * @notice Sender repays their own borrow
     * @param repayAmount The amount to repay
     * @return uint 0=success, otherwise a failure (see ErrorReporter.sol for details)
     */
    function repayBorrow(uint256 repayAmount) external returns (uint256) {
        (uint256 err, ) = repayBorrowInternal(repayAmount, false);
        return err;
    }

    /**
     * @notice Sender repays a borrow belonging to borrower
     * @param borrower the account with the debt being payed off
     * @param repayAmount The amount to repay
     * @return uint 0=success, otherwise a failure (see ErrorReporter.sol for details)
     */
    function repayBorrowBehalf(address borrower, uint256 repayAmount) external returns (uint256) {
        (uint256 err, ) = repayBorrowBehalfInternal(borrower, repayAmount, false);
        return err;
    }

    /**
     * @notice The sender liquidates the borrowers collateral.
     *  The collateral seized is transferred to the liquidator.
     * @param borrower The borrower of this jToken to be liquidated
     * @param repayAmount The amount of the underlying borrowed asset to repay
     * @param jTokenCollateral The market in which to seize collateral from the borrower
     * @return uint 0=success, otherwise a failure (see ErrorReporter.sol for details)
     */
    function liquidateBorrow(
        address borrower,
        uint256 repayAmount,
        JTokenInterface jTokenCollateral
    ) external returns (uint256) {
        (uint256 err, ) = liquidateBorrowInternal(borrower, repayAmount, jTokenCollateral, false);
        return err;
    }

    /**
     * @notice The sender adds to reserves.
     * @param addAmount The amount fo underlying token to add as reserves
     * @return uint 0=success, otherwise a failure (see ErrorReporter.sol for details)
     */
    function _addReserves(uint256 addAmount) external returns (uint256) {
        return _addReservesInternal(addAmount, false);
    }

    /**
     * @notice Set the given collateral cap for the market.
     * @param newCollateralCap New collateral cap for this market. A value of 0 corresponds to no cap.
     */
    function _setCollateralCap(uint256 newCollateralCap) external {
        require(msg.sender == admin, "only admin can set collateral cap");

        collateralCap = newCollateralCap;
        emit NewCollateralCap(address(this), newCollateralCap);
    }

    /**
     * @notice Absorb excess cash into reserves.
     */
    function gulp() external nonReentrant {
        uint256 cashOnChain = getCashOnChain();
        uint256 cashPrior = getCashPrior();

        uint256 excessCash = sub_(cashOnChain, cashPrior);
        totalReserves = add_(totalReserves, excessCash);
        internalCash = cashOnChain;
    }

    /**
     * @notice Get the max flash loan amount
     */
    function maxFlashLoan() external view returns (uint256) {
        uint256 amount = 0;
        if (JoetrollerInterfaceExtension(address(joetroller)).flashloanAllowed(address(this), address(0), amount, "")) {
            amount = getCashPrior();
        }
        return amount;
    }

    /**
     * @notice Get the flash loan fees
     * @param amount amount of token to borrow
     */
    function flashFee(uint256 amount) external view returns (uint256) {
        require(
            JoetrollerInterfaceExtension(address(joetroller)).flashloanAllowed(address(this), address(0), amount, ""),
            "flashloan is paused"
        );
        return div_(mul_(amount, flashFeeBips), 10000);
    }

    /**
     * @notice Flash loan funds to a given account.
     * @param receiver The receiver address for the funds
     * @param token Token to be borrowed. This is a requirement from eip-3156
     * @param amount The amount of the funds to be loaned
     * @param data The other data
     * @return uint 0=success, otherwise a failure (see ErrorReporter.sol for details)
     */
    function flashLoan(
        ERC3156FlashBorrowerInterface receiver,
        address token,
        uint256 amount,
        bytes calldata data
    ) external nonReentrant returns (bool) {
        require(amount > 0, "flashLoan amount should be greater than zero");
        require(accrueInterest() == uint256(Error.NO_ERROR), "accrue interest failed");
        require(
            JoetrollerInterfaceExtension(address(joetroller)).flashloanAllowed(
                address(this),
                address(receiver),
                amount,
                data
            ),
            "flashloan is paused"
        );
        // Shh -- currently unused
        token;
        uint256 cashOnChainBefore = getCashOnChain();
        uint256 cashBefore = getCashPrior();
        require(cashBefore >= amount, "INSUFFICIENT_LIQUIDITY");

        // 1. calculate fee, 1 bips = 1/10000
        uint256 totalFee = this.flashFee(amount);

        // 2. transfer fund to receiver
        doTransferOut(address(uint160(address(receiver))), amount, false);

        // 3. update totalBorrows
        totalBorrows = add_(totalBorrows, amount);

        // 4. execute receiver's callback function

        require(
            receiver.onFlashLoan(msg.sender, underlying, amount, totalFee, data) ==
                keccak256("ERC3156FlashBorrower.onFlashLoan"),
            "IERC3156: Callback failed"
        );

        // 5. take amount + fee from receiver, then check balance
        uint256 repaymentAmount = add_(amount, totalFee);
        doTransferIn(address(receiver), repaymentAmount, false);

        uint256 cashOnChainAfter = getCashOnChain();

        require(cashOnChainAfter == add_(cashOnChainBefore, totalFee), "BALANCE_INCONSISTENT");

        // 6. update reserves and internal cash and totalBorrows
        uint256 reservesFee = mul_ScalarTruncate(Exp({mantissa: reserveFactorMantissa}), totalFee);
        totalReserves = add_(totalReserves, reservesFee);
        internalCash = add_(cashBefore, totalFee);
        totalBorrows = sub_(totalBorrows, amount);

        emit Flashloan(address(receiver), amount, totalFee, reservesFee);
        return true;
    }

    /**
     * @notice Register account collateral tokens if there is space.
     * @param account The account to register
     * @dev This function could only be called by joetroller.
     * @return The actual registered amount of collateral
     */
    function registerCollateral(address account) external returns (uint256) {
        // Make sure accountCollateralTokens of `account` is initialized.
        initializeAccountCollateralTokens(account);

        require(msg.sender == address(joetroller), "only joetroller may register collateral for user");

        uint256 amount = sub_(accountTokens[account], accountCollateralTokens[account]);
        return increaseUserCollateralInternal(account, amount);
    }

    /**
     * @notice Unregister account collateral tokens if the account still has enough collateral.
     * @dev This function could only be called by joetroller.
     * @param account The account to unregister
     */
    function unregisterCollateral(address account) external {
        // Make sure accountCollateralTokens of `account` is initialized.
        initializeAccountCollateralTokens(account);

        require(msg.sender == address(joetroller), "only joetroller may unregister collateral for user");

        decreaseUserCollateralInternal(account, accountCollateralTokens[account]);
    }

    /*** Safe Token ***/

    /**
     * @notice Gets internal balance of this contract in terms of the underlying.
     *  It excludes balance from direct transfer.
     * @dev This excludes the value of the current message, if any
     * @return The quantity of underlying tokens owned by this contract
     */
    function getCashPrior() internal view returns (uint256) {
        return internalCash;
    }

    /**
     * @notice Gets total balance of this contract in terms of the underlying
     * @dev This excludes the value of the current message, if any
     * @return The quantity of underlying tokens owned by this contract
     */
    function getCashOnChain() internal view returns (uint256) {
        EIP20Interface token = EIP20Interface(underlying);
        return token.balanceOf(address(this));
    }

    /**
     * @notice Initialize the account's collateral tokens. This function should be called in the beginning of every function
     *  that accesses accountCollateralTokens or accountTokens.
     * @param account The account of accountCollateralTokens that needs to be updated
     */
    function initializeAccountCollateralTokens(address account) internal {
        /**
         * If isCollateralTokenInit is false, it means accountCollateralTokens was not initialized yet.
         * This case will only happen once and must be the very beginning. accountCollateralTokens is a new structure and its
         * initial value should be equal to accountTokens if user has entered the market. However, it's almost impossible to
         * check every user's value when the implementation becomes active. Therefore, it must rely on every action which will
         * access accountTokens to call this function to check if accountCollateralTokens needed to be initialized.
         */
        if (!isCollateralTokenInit[account]) {
            if (JoetrollerInterfaceExtension(address(joetroller)).checkMembership(account, JToken(this))) {
                accountCollateralTokens[account] = accountTokens[account];
                totalCollateralTokens = add_(totalCollateralTokens, accountTokens[account]);

                emit UserCollateralChanged(account, accountCollateralTokens[account]);
            }
            isCollateralTokenInit[account] = true;
        }
    }

    /**
     * @dev Similar to EIP20 transfer, except it handles a False result from `transferFrom` and reverts in that case.
     *      This will revert due to insufficient balance or insufficient allowance.
     *      This function returns the actual amount received,
     *      which may be less than `amount` if there is a fee attached to the transfer.
     *
     *      Note: This wrapper safely handles non-standard ERC-20 tokens that do not return a value.
     *            See here: https://medium.com/coinmonks/missing-return-value-bug-at-least-130-tokens-affected-d67bf08521ca
     */
    function doTransferIn(
        address from,
        uint256 amount,
        bool isNative
    ) internal returns (uint256) {
        isNative; // unused

        EIP20NonStandardInterface token = EIP20NonStandardInterface(underlying);
        uint256 balanceBefore = EIP20Interface(underlying).balanceOf(address(this));
        token.transferFrom(from, address(this), amount);

        bool success;
        assembly {
            switch returndatasize()
            case 0 {
                // This is a non-standard ERC-20
                success := not(0) // set success to true
            }
            case 32 {
                // This is a joeliant ERC-20
                returndatacopy(0, 0, 32)
                success := mload(0) // Set `success = returndata` of external call
            }
            default {
                // This is an excessively non-joeliant ERC-20, revert.
                revert(0, 0)
            }
        }
        require(success, "TOKEN_TRANSFER_IN_FAILED");

        // Calculate the amount that was *actually* transferred
        uint256 balanceAfter = EIP20Interface(underlying).balanceOf(address(this));
        uint256 transferredIn = sub_(balanceAfter, balanceBefore);
        internalCash = add_(internalCash, transferredIn);
        return transferredIn;
    }

    /**
     * @dev Similar to EIP20 transfer, except it handles a False success from `transfer` and returns an explanatory
     *      error code rather than reverting. If caller has not called checked protocol's balance, this may revert due to
     *      insufficient cash held in this contract. If caller has checked protocol's balance prior to this call, and verified
     *      it is >= amount, this should not revert in normal conditions.
     *
     *      Note: This wrapper safely handles non-standard ERC-20 tokens that do not return a value.
     *            See here: https://medium.com/coinmonks/missing-return-value-bug-at-least-130-tokens-affected-d67bf08521ca
     */
    function doTransferOut(
        address payable to,
        uint256 amount,
        bool isNative
    ) internal {
        isNative; // unused

        EIP20NonStandardInterface token = EIP20NonStandardInterface(underlying);
        token.transfer(to, amount);

        bool success;
        assembly {
            switch returndatasize()
            case 0 {
                // This is a non-standard ERC-20
                success := not(0) // set success to true
            }
            case 32 {
                // This is a joelaint ERC-20
                returndatacopy(0, 0, 32)
                success := mload(0) // Set `success = returndata` of external call
            }
            default {
                // This is an excessively non-joeliant ERC-20, revert.
                revert(0, 0)
            }
        }
        require(success, "TOKEN_TRANSFER_OUT_FAILED");
        internalCash = sub_(internalCash, amount);
    }

    /**
     * @notice Transfer `tokens` tokens from `src` to `dst` by `spender`
     * @dev Called by both `transfer` and `transferFrom` internally
     * @param spender The address of the account performing the transfer
     * @param src The address of the source account
     * @param dst The address of the destination account
     * @param tokens The number of tokens to transfer
     * @return Whether or not the transfer succeeded
     */
    function transferTokens(
        address spender,
        address src,
        address dst,
        uint256 tokens
    ) internal returns (uint256) {
        // Make sure accountCollateralTokens of `src` and `dst` are initialized.
        initializeAccountCollateralTokens(src);
        initializeAccountCollateralTokens(dst);

        /**
         * For every user, accountTokens must be greater than or equal to accountCollateralTokens.
         * The buffer between the two values will be transferred first.
         * bufferTokens = accountTokens[src] - accountCollateralTokens[src]
         * collateralTokens = tokens - bufferTokens
         */
        uint256 bufferTokens = sub_(accountTokens[src], accountCollateralTokens[src]);
        uint256 collateralTokens = 0;
        if (tokens > bufferTokens) {
            collateralTokens = tokens - bufferTokens;
        }

        /**
         * Since bufferTokens are not collateralized and can be transferred freely, we only check with joetroller
         * whether collateralized tokens can be transferred.
         */
        uint256 allowed = joetroller.transferAllowed(address(this), src, dst, collateralTokens);
        if (allowed != 0) {
            return failOpaque(Error.JOETROLLER_REJECTION, FailureInfo.TRANSFER_JOETROLLER_REJECTION, allowed);
        }

        /* Do not allow self-transfers */
        if (src == dst) {
            return fail(Error.BAD_INPUT, FailureInfo.TRANSFER_NOT_ALLOWED);
        }

        /* Get the allowance, infinite for the account owner */
        uint256 startingAllowance = 0;
        if (spender == src) {
            startingAllowance = uint256(-1);
        } else {
            startingAllowance = transferAllowances[src][spender];
        }

        /* Do the calculations, checking for {under,over}flow */
        accountTokens[src] = sub_(accountTokens[src], tokens);
        accountTokens[dst] = add_(accountTokens[dst], tokens);
        if (collateralTokens > 0) {
            accountCollateralTokens[src] = sub_(accountCollateralTokens[src], collateralTokens);
            accountCollateralTokens[dst] = add_(accountCollateralTokens[dst], collateralTokens);

            emit UserCollateralChanged(src, accountCollateralTokens[src]);
            emit UserCollateralChanged(dst, accountCollateralTokens[dst]);
        }

        /* Eat some of the allowance (if necessary) */
        if (startingAllowance != uint256(-1)) {
            transferAllowances[src][spender] = sub_(startingAllowance, tokens);
        }

        /* We emit a Transfer event */
        emit Transfer(src, dst, tokens);

        // unused function
        // joetroller.transferVerify(address(this), src, dst, tokens);

        return uint256(Error.NO_ERROR);
    }

    /**
     * @notice Get the account's jToken balances
     * @param account The address of the account
     */
    function getJTokenBalanceInternal(address account) internal view returns (uint256) {
        if (isCollateralTokenInit[account]) {
            return accountCollateralTokens[account];
        } else {
            /**
             * If the value of accountCollateralTokens was not initialized, we should return the value of accountTokens.
             */
            return accountTokens[account];
        }
    }

    /**
     * @notice Increase user's collateral. Increase as much as we can.
     * @param account The address of the account
     * @param amount The amount of collateral user wants to increase
     * @return The actual increased amount of collateral
     */
    function increaseUserCollateralInternal(address account, uint256 amount) internal returns (uint256) {
        uint256 totalCollateralTokensNew = add_(totalCollateralTokens, amount);
        if (collateralCap == 0 || (collateralCap != 0 && totalCollateralTokensNew <= collateralCap)) {
            // 1. If collateral cap is not set,
            // 2. If collateral cap is set but has enough space for this user,
            // give all the user needs.
            totalCollateralTokens = totalCollateralTokensNew;
            accountCollateralTokens[account] = add_(accountCollateralTokens[account], amount);

            emit UserCollateralChanged(account, accountCollateralTokens[account]);
            return amount;
        } else if (collateralCap > totalCollateralTokens) {
            // If the collateral cap is set but the remaining cap is not enough for this user,
            // give the remaining parts to the user.
            uint256 gap = sub_(collateralCap, totalCollateralTokens);
            totalCollateralTokens = collateralCap;
            accountCollateralTokens[account] = add_(accountCollateralTokens[account], gap);

            emit UserCollateralChanged(account, accountCollateralTokens[account]);
            return gap;
        }
        return 0;
    }

    /**
     * @notice Decrease user's collateral. Reject if the amount can't be fully decrease.
     * @param account The address of the account
     * @param amount The amount of collateral user wants to decrease
     */
    function decreaseUserCollateralInternal(address account, uint256 amount) internal {
        require(joetroller.redeemAllowed(address(this), account, amount) == 0, "joetroller rejection");

        /*
         * Return if amount is zero.
         * Put behind `redeemAllowed` for accuring potential JOE rewards.
         */
        if (amount == 0) {
            return;
        }

        totalCollateralTokens = sub_(totalCollateralTokens, amount);
        accountCollateralTokens[account] = sub_(accountCollateralTokens[account], amount);

        emit UserCollateralChanged(account, accountCollateralTokens[account]);
    }

    struct MintLocalVars {
        uint256 exchangeRateMantissa;
        uint256 mintTokens;
        uint256 actualMintAmount;
    }

    /**
     * @notice User supplies assets into the market and receives jTokens in exchange
     * @dev Assumes interest has already been accrued up to the current timestamp
     * @param minter The address of the account which is supplying the assets
     * @param mintAmount The amount of the underlying asset to supply
     * @param isNative The amount is in native or not
     * @return (uint, uint) An error code (0=success, otherwise a failure, see ErrorReporter.sol), and the actual mint amount.
     */
    function mintFresh(
        address minter,
        uint256 mintAmount,
        bool isNative
    ) internal returns (uint256, uint256) {
        // Make sure accountCollateralTokens of `minter` is initialized.
        initializeAccountCollateralTokens(minter);

        /* Fail if mint not allowed */
        uint256 allowed = joetroller.mintAllowed(address(this), minter, mintAmount);
        if (allowed != 0) {
            return (failOpaque(Error.JOETROLLER_REJECTION, FailureInfo.MINT_JOETROLLER_REJECTION, allowed), 0);
        }

        /*
         * Return if mintAmount is zero.
         * Put behind `mintAllowed` for accuring potential JOE rewards.
         */
        if (mintAmount == 0) {
            return (uint256(Error.NO_ERROR), 0);
        }

        /* Verify market's block timestamp equals current block timestamp */
        if (accrualBlockTimestamp != getBlockTimestamp()) {
            return (fail(Error.MARKET_NOT_FRESH, FailureInfo.MINT_FRESHNESS_CHECK), 0);
        }

        MintLocalVars memory vars;

        vars.exchangeRateMantissa = exchangeRateStoredInternal();

        /////////////////////////
        // EFFECTS & INTERACTIONS
        // (No safe failures beyond this point)

        /*
         *  We call `doTransferIn` for the minter and the mintAmount.
         *  Note: The jToken must handle variations between ERC-20 and ETH underlying.
         *  `doTransferIn` reverts if anything goes wrong, since we can't be sure if
         *  side-effects occurred. The function returns the amount actually transferred,
         *  in case of a fee. On success, the jToken holds an additional `actualMintAmount`
         *  of cash.
         */
        vars.actualMintAmount = doTransferIn(minter, mintAmount, isNative);

        /*
         * We get the current exchange rate and calculate the number of jTokens to be minted:
         *  mintTokens = actualMintAmount / exchangeRate
         */
        vars.mintTokens = div_ScalarByExpTruncate(vars.actualMintAmount, Exp({mantissa: vars.exchangeRateMantissa}));

        /*
         * We calculate the new total supply of jTokens and minter token balance, checking for overflow:
         *  totalSupply = totalSupply + mintTokens
         *  accountTokens[minter] = accountTokens[minter] + mintTokens
         */
        totalSupply = add_(totalSupply, vars.mintTokens);
        accountTokens[minter] = add_(accountTokens[minter], vars.mintTokens);

        /*
         * We only allocate collateral tokens if the minter has entered the market.
         */
        if (JoetrollerInterfaceExtension(address(joetroller)).checkMembership(minter, JToken(this))) {
            increaseUserCollateralInternal(minter, vars.mintTokens);
        }

        /* We emit a Mint event, and a Transfer event */
        emit Mint(minter, vars.actualMintAmount, vars.mintTokens);
        emit Transfer(address(this), minter, vars.mintTokens);

        /* We call the defense hook */
        // unused function
        // joetroller.mintVerify(address(this), minter, vars.actualMintAmount, vars.mintTokens);

        return (uint256(Error.NO_ERROR), vars.actualMintAmount);
    }

    struct RedeemLocalVars {
        uint256 exchangeRateMantissa;
        uint256 redeemTokens;
        uint256 redeemAmount;
    }

    /**
     * @notice User redeems jTokens in exchange for the underlying asset
     * @dev Assumes interest has already been accrued up to the current timestamp. Only one of redeemTokensIn or redeemAmountIn may be non-zero and it would do nothing if both are zero.
     * @param redeemer The address of the account which is redeeming the tokens
     * @param redeemTokensIn The number of jTokens to redeem into underlying
     * @param redeemAmountIn The number of underlying tokens to receive from redeeming jTokens
     * @param isNative The amount is in native or not
     * @return uint 0=success, otherwise a failure (see ErrorReporter.sol for details)
     */
    function redeemFresh(
        address payable redeemer,
        uint256 redeemTokensIn,
        uint256 redeemAmountIn,
        bool isNative
    ) internal returns (uint256) {
        // Make sure accountCollateralTokens of `redeemer` is initialized.
        initializeAccountCollateralTokens(redeemer);

        require(redeemTokensIn == 0 || redeemAmountIn == 0, "one of redeemTokensIn or redeemAmountIn must be zero");

        RedeemLocalVars memory vars;

        /* exchangeRate = invoke Exchange Rate Stored() */
        vars.exchangeRateMantissa = exchangeRateStoredInternal();

        /* If redeemTokensIn > 0: */
        if (redeemTokensIn > 0) {
            /*
             * We calculate the exchange rate and the amount of underlying to be redeemed:
             *  redeemTokens = redeemTokensIn
             *  redeemAmount = redeemTokensIn x exchangeRateCurrent
             */
            vars.redeemTokens = redeemTokensIn;
            vars.redeemAmount = mul_ScalarTruncate(Exp({mantissa: vars.exchangeRateMantissa}), redeemTokensIn);
        } else {
            /*
             * We get the current exchange rate and calculate the amount to be redeemed:
             *  redeemTokens = redeemAmountIn / exchangeRate
             *  redeemAmount = redeemAmountIn
             */
            vars.redeemTokens = div_ScalarByExpTruncate(redeemAmountIn, Exp({mantissa: vars.exchangeRateMantissa}));
            vars.redeemAmount = redeemAmountIn;
        }

        /**
         * For every user, accountTokens must be greater than or equal to accountCollateralTokens.
         * The buffer between the two values will be redeemed first.
         * bufferTokens = accountTokens[redeemer] - accountCollateralTokens[redeemer]
         * collateralTokens = redeemTokens - bufferTokens
         */
        uint256 bufferTokens = sub_(accountTokens[redeemer], accountCollateralTokens[redeemer]);
        uint256 collateralTokens = 0;
        if (vars.redeemTokens > bufferTokens) {
            collateralTokens = vars.redeemTokens - bufferTokens;
        }

        uint256 allowed = joetroller.redeemAllowed(address(this), redeemer, collateralTokens);
        if (allowed != 0) {
            return failOpaque(Error.JOETROLLER_REJECTION, FailureInfo.REDEEM_JOETROLLER_REJECTION, allowed);
        }

        /* Verify market's block timestamp equals current block timestamp */
        if (accrualBlockTimestamp != getBlockTimestamp()) {
            return fail(Error.MARKET_NOT_FRESH, FailureInfo.REDEEM_FRESHNESS_CHECK);
        }

        /* Fail gracefully if protocol has insufficient cash */
        if (getCashPrior() < vars.redeemAmount) {
            return fail(Error.TOKEN_INSUFFICIENT_CASH, FailureInfo.REDEEM_TRANSFER_OUT_NOT_POSSIBLE);
        }

        /////////////////////////
        // EFFECTS & INTERACTIONS
        // (No safe failures beyond this point)

        /*
         * We invoke doTransferOut for the redeemer and the redeemAmount.
         *  Note: The jToken must handle variations between ERC-20 and ETH underlying.
         *  On success, the jToken has redeemAmount less of cash.
         *  doTransferOut reverts if anything goes wrong, since we can't be sure if side effects occurred.
         */
        doTransferOut(redeemer, vars.redeemAmount, isNative);

        /*
         * We calculate the new total supply and redeemer balance, checking for underflow:
         *  totalSupplyNew = totalSupply - redeemTokens
         *  accountTokensNew = accountTokens[redeemer] - redeemTokens
         */
        totalSupply = sub_(totalSupply, vars.redeemTokens);
        accountTokens[redeemer] = sub_(accountTokens[redeemer], vars.redeemTokens);

        /*
         * We only deallocate collateral tokens if the redeemer needs to redeem them.
         */
        decreaseUserCollateralInternal(redeemer, collateralTokens);

        /* We emit a Transfer event, and a Redeem event */
        emit Transfer(redeemer, address(this), vars.redeemTokens);
        emit Redeem(redeemer, vars.redeemAmount, vars.redeemTokens);

        /* We call the defense hook */
        joetroller.redeemVerify(address(this), redeemer, vars.redeemAmount, vars.redeemTokens);

        return uint256(Error.NO_ERROR);
    }

    /**
     * @notice Transfers collateral tokens (this market) to the liquidator.
     * @dev Called only during an in-kind liquidation, or by liquidateBorrow during the liquidation of another JToken.
     *  Its absolutely critical to use msg.sender as the seizer jToken and not a parameter.
     * @param seizerToken The contract seizing the collateral (i.e. borrowed jToken)
     * @param liquidator The account receiving seized collateral
     * @param borrower The account having collateral seized
     * @param seizeTokens The number of jTokens to seize
     * @return uint 0=success, otherwise a failure (see ErrorReporter.sol for details)
     */
    function seizeInternal(
        address seizerToken,
        address liquidator,
        address borrower,
        uint256 seizeTokens
    ) internal returns (uint256) {
        // Make sure accountCollateralTokens of `liquidator` and `borrower` are initialized.
        initializeAccountCollateralTokens(liquidator);
        initializeAccountCollateralTokens(borrower);

        /* Fail if seize not allowed */
        uint256 allowed = joetroller.seizeAllowed(address(this), seizerToken, liquidator, borrower, seizeTokens);
        if (allowed != 0) {
            return failOpaque(Error.JOETROLLER_REJECTION, FailureInfo.LIQUIDATE_SEIZE_JOETROLLER_REJECTION, allowed);
        }

        /*
         * Return if seizeTokens is zero.
         * Put behind `seizeAllowed` for accuring potential JOE rewards.
         */
        if (seizeTokens == 0) {
            return uint256(Error.NO_ERROR);
        }

        /* Fail if borrower = liquidator */
        if (borrower == liquidator) {
            return fail(Error.INVALID_ACCOUNT_PAIR, FailureInfo.LIQUIDATE_SEIZE_LIQUIDATOR_IS_BORROWER);
        }

        uint256 protocolSeizeTokens = mul_(seizeTokens, Exp({mantissa: protocolSeizeShareMantissa}));
        uint256 liquidatorSeizeTokens = sub_(seizeTokens, protocolSeizeTokens);

        uint256 exchangeRateMantissa = exchangeRateStoredInternal();
        uint256 protocolSeizeAmount = mul_ScalarTruncate(Exp({mantissa: exchangeRateMantissa}), protocolSeizeTokens);

        /*
         * We calculate the new borrower and liquidator token balances and token collateral balances, failing on underflow/overflow:
         *  accountTokens[borrower] = accountTokens[borrower] - seizeTokens
         *  accountTokens[liquidator] = accountTokens[liquidator] + seizeTokens
         *  accountCollateralTokens[borrower] = accountCollateralTokens[borrower] - seizeTokens
         *  accountCollateralTokens[liquidator] = accountCollateralTokens[liquidator] + seizeTokens
         */
        accountTokens[borrower] = sub_(accountTokens[borrower], seizeTokens);
        accountTokens[liquidator] = add_(accountTokens[liquidator], liquidatorSeizeTokens);
        accountCollateralTokens[borrower] = sub_(accountCollateralTokens[borrower], seizeTokens);
        accountCollateralTokens[liquidator] = add_(accountCollateralTokens[liquidator], liquidatorSeizeTokens);
        totalReserves = add_(totalReserves, protocolSeizeAmount);
        totalSupply = sub_(totalSupply, protocolSeizeTokens);

        /* Emit a Transfer, UserCollateralChanged and ReservesAdded events */
        emit Transfer(borrower, liquidator, seizeTokens);
        emit UserCollateralChanged(borrower, accountCollateralTokens[borrower]);
        emit UserCollateralChanged(liquidator, accountCollateralTokens[liquidator]);
        emit ReservesAdded(address(this), protocolSeizeAmount, totalReserves);

        /* We call the defense hook */
        // unused function
        // joetroller.seizeVerify(address(this), seizerToken, liquidator, borrower, seizeTokens);

        return uint256(Error.NO_ERROR);
    }

    /*** Admin Functions ***/

    /**
     * @notice Accrues interest and sets a new collateral seize share for the protocol using _setProtocolSeizeShareFresh
     * @dev Admin function to accrue interest and set a new collateral seize share
     * @return uint256 0=success, otherwise a failure (see ErrorReport.sol for details)
     */
    function _setProtocolSeizeShare(uint256 newProtocolSeizeShareMantissa) external nonReentrant returns (uint256) {
        uint256 error = accrueInterest();
        if (error != uint256(Error.NO_ERROR)) {
            return fail(Error(error), FailureInfo.SET_PROTOCOL_SEIZE_SHARE_ACCRUE_INTEREST_FAILED);
        }
        return _setProtocolSeizeShareFresh(newProtocolSeizeShareMantissa);
    }

    function _setProtocolSeizeShareFresh(uint256 newProtocolSeizeShareMantissa) internal returns (uint256) {
        // Check caller is admin
        if (msg.sender != admin) {
            return fail(Error.UNAUTHORIZED, FailureInfo.SET_PROTOCOL_SEIZE_SHARE_ADMIN_CHECK);
        }

        // Verify market's block timestamp equals current block timestamp
        if (accrualBlockTimestamp != getBlockTimestamp()) {
            return fail(Error.MARKET_NOT_FRESH, FailureInfo.SET_PROTOCOL_SEIZE_SHARE_FRESH_CHECK);
        }

        if (newProtocolSeizeShareMantissa > protocolSeizeShareMaxMantissa) {
            return fail(Error.BAD_INPUT, FailureInfo.SET_PROTOCOL_SEIZE_SHARE_BOUNDS_CHECK);
        }

        uint256 oldProtocolSeizeShareMantissa = protocolSeizeShareMantissa;
        protocolSeizeShareMantissa = newProtocolSeizeShareMantissa;

        emit NewProtocolSeizeShare(oldProtocolSeizeShareMantissa, newProtocolSeizeShareMantissa);

        return uint256(Error.NO_ERROR);
    }
}
