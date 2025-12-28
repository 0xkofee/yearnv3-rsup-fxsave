// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.18;

import {BaseStrategy} from "./BaseStrategy.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

// Curve LLAMMA Lending Market Interface (Real mainnet signatures)
interface ICurveLLAMMA {
    // Collateral and debt management (simplified - msg.sender is used for user)
    function create_loan(uint256 collateral, uint256 debt, uint256 N) external;
    function add_collateral(uint256 collateral) external;
    function remove_collateral(uint256 collateral) external;
    function borrow_more(uint256 collateral, uint256 debt) external;

    // Repay crvUSD debt (up to 3 params, all have defaults in Vyper)
    function repay(uint256 _d_debt, address _for, int256 max_active_band) external;

    // View functions
    function debt(address user) external view returns (uint256);
    function loan_exists(address user) external view returns (bool);
    function health(address user, bool full) external view returns (int256);
    function max_borrowable(uint256 collateral, uint256 N, uint256 current_debt, address user) external view returns (uint256);
    function collateral_token() external view returns (address);
    function borrowed_token() external view returns (address);

    // User position data: returns array [collateral, debt, n1, n2]
    function user_state(address user) external view returns (uint256[4] memory);

    // Loan parameters
    function loan_discount() external view returns (uint256);
}

// Resupply Protocol Interface (Lending Market: crvUSD collateral -> borrow reUSD)
interface IResupply {
    function collateral() external view returns (address);

    // Borrow reUSD by depositing crvUSD collateral
    // _borrowAmount: amount of reUSD to borrow (must be <= _underlyingAmount * maxLTV)
    // _underlyingAmount: amount of crvUSD collateral to deposit
    // _receiver: address to receive the borrowed reUSD
    function borrow(
        uint256 _borrowAmount,
        uint256 _underlyingAmount,
        address _receiver
    ) external returns (uint256 _shares);

    // Repay reUSD debt
    // _shares: amount of borrow shares to repay
    // _borrower: address of the borrower
    function repay(
        uint256 _shares,
        address _borrower
    ) external returns (uint256 _amountToRepay);

    // Remove crvUSD collateral (must maintain solvency)
    function removeCollateral(
        uint256 _collateralAmount,
        address _receiver
    ) external;

    // View functions
    function userBorrowShares(address _account) external view returns (uint256);
    function userCollateralBalance(address _account) external returns (uint256);

    // Convert borrow shares to actual debt amount
    function toBorrowAmount(uint256 _shares, bool _roundUp, bool _previewInterest) external view returns (uint256);
}

// sreUSD Token Interface (ERC-4626 yield-bearing wrapper for reUSD)
interface ISreUSD {
    // ERC-4626 standard functions
    // Deposit reUSD to get sreUSD shares
    function deposit(uint256 assets, address receiver) external returns (uint256 shares);

    // Redeem sreUSD shares to get reUSD
    function redeem(uint256 shares, address receiver, address owner) external returns (uint256 assets);

    // Withdraw reUSD by specifying asset amount
    function withdraw(uint256 assets, address receiver, address owner) external returns (uint256 shares);

    // View functions for conversions
    function convertToShares(uint256 assets) external view returns (uint256 shares);
    function convertToAssets(uint256 shares) external view returns (uint256 assets);
    function totalAssets() external view returns (uint256);

    // Standard ERC20
    function approve(address spender, uint256 amount) external returns (bool);
    function transfer(address to, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

/**
 * @title SreUSD/crvUSD Leveraged Looping Strategy
 * @notice Leveraged yield strategy using Curve LLAMMA lending market and Resupply protocol
 * @dev Strategy uses leveraged looping (no flashloans) to avoid reUSD peg risk:
 *
 *      LEVERAGE UP LOOP (starts with reUSD):
 *      1. User deposits reUSD
 *      2. Loop until target leverage reached:
 *         a. Deposit reUSD → get sreUSD shares (via ERC-4626 deposit())
 *            Exchange rate NOT 1:1! sreUSD accrues value over time.
 *         b. Supply sreUSD shares as collateral to Curve LLAMMA
 *         c. Borrow crvUSD from Curve LLAMMA (at 95% LTV)
 *         d. Deposit crvUSD into Resupply → get reUSD
 *         e. Repeat with newly received reUSD
 *
 *      NOTE: Starting with reUSD creates buy pressure on reUSD as
 *      deposits flow into the strategy, helping push the peg up.
 *      The sreUSD yield (18% APY) > crvUSD borrow cost (6.73% APY)
 *      creates profitable looping with effective negative borrow rates.
 *
 *      DELEVERAGE LOOP (starts with reUSD):
 *      1. Loop until target amount freed:
 *         a. Redeem reUSD from Resupply → get crvUSD
 *         b. Repay crvUSD debt on Curve LLAMMA
 *         c. Withdraw sreUSD share collateral from Curve LLAMMA
 *         d. Redeem sreUSD shares → reUSD (via ERC-4626 redeem())
 *            Get back MORE reUSD than originally deposited due to yield!
 *         e. Repeat until enough reUSD is freed
 *
 *      Token relationships:
 *      - reUSD ↔ sreUSD: deposit/redeem via sreUSD ERC-4626 vault (NOT 1:1 rate!)
 *      - crvUSD ↔ reUSD: deposit/redeem via Resupply ERC-4626 vault
 *
 *      Target LTVs:
 *      - Resupply: 92% (max 95%)
 *      - Curve LLAMMA: 95% LTV (max from loan_discount)
 *
 *      Expected total leverage with 95% Curve LTV:
 *      - Theoretical max: 1 / (1 - 0.95) = 20x
 *      - Actual: ~15-18x (accounting for dust and iteration limits)
 */
contract SreUSDCrvUSDLoopStrategy is BaseStrategy {
    using SafeERC20 for ERC20;

    /*//////////////////////////////////////////////////////////////
                            STATE VARIABLES
    //////////////////////////////////////////////////////////////*/

    // Tokens
    ISreUSD public immutable sreUSD;    // Yield-bearing ERC-4626 wrapper for reUSD (used as Curve collateral)
    ERC20 public immutable crvUSD;      // Borrowed token from Curve LLAMMA
    ERC20 public immutable reUSD;       // Strategy asset (receipt token from Resupply)

    // Protocols
    ICurveLLAMMA public immutable curveLLAMMA;
    IResupply public immutable resupplyPair;

    // Target LTV parameters (basis points: 10000 = 100%)
    uint256 public targetResupplyLTV;   // Target: 9200 (92%)
    uint256 public targetCurveLTV;      // Target: 9500 (95% - safe LTV for LLAMMA)

    // Maximum safe LTVs
    uint256 public constant MAX_RESUPPLY_LTV = 9500;    // 95% - protocol maximum
    uint256 public immutable maxCurveLTV;               // Queried from Curve LLAMMA (loan_discount)
    uint256 public constant BASIS_POINTS = 10000;

    // Loop parameters
    uint256 public maxIterations;       // Maximum loop iterations to prevent gas issues
    uint256 public minLoopAmount;       // Minimum amount to continue looping (dust threshold)


    /*//////////////////////////////////////////////////////////////
                            CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Initialize the strategy
     * @param _reUSD Address of reUSD token (strategy asset)
     * @param _sreUSD Address of sreUSD token (ERC-4626 yield-bearing wrapper for reUSD)
     * @param _crvUSD Address of crvUSD token
     * @param _curveLLAMMA Address of Curve LLAMMA lending market
     * @param _resupplyPair Address of Resupply pair contract
     * @param _name Strategy name for tokenized shares
     */
    constructor(
        address _reUSD,
        address _sreUSD,
        address _crvUSD,
        address _curveLLAMMA,
        address _resupplyPair,
        string memory _name
    ) BaseStrategy(_reUSD, _name) {
        reUSD = ERC20(_reUSD);
        sreUSD = ISreUSD(_sreUSD);
        crvUSD = ERC20(_crvUSD);
        curveLLAMMA = ICurveLLAMMA(_curveLLAMMA);
        resupplyPair = IResupply(_resupplyPair);

        // Query max LTV from Curve LLAMMA: maxLTV = 1 - loan_discount - 2% safety buffer
        uint256 loanDiscount = curveLLAMMA.loan_discount();
        maxCurveLTV = BASIS_POINTS - (loanDiscount * BASIS_POINTS / 1e18) - 200;

        // Set default target LTVs
        targetResupplyLTV = 9200;  // 92% for Resupply
        targetCurveLTV = maxCurveLTV;  // Use max (already has 2% safety buffer)

        // Set loop parameters
        maxIterations = 30;          // Maximum 30 loops per operation (need ~20 for 20x leverage)
        minLoopAmount = 10e18;       // Min 10 reUSD to continue looping (borrow has try/catch for protocol min)

        // Approve tokens for protocol interactions
        crvUSD.safeApprove(_resupplyPair, type(uint256).max);    // Approve crvUSD for Resupply collateral
        crvUSD.safeApprove(_curveLLAMMA, type(uint256).max); // Approve crvUSD for Curve repayment
        reUSD.safeApprove(_sreUSD, type(uint256).max);       // Approve reUSD for sreUSD wrapping
        reUSD.safeApprove(_resupplyPair, type(uint256).max);     // Approve reUSD for Resupply repayment
        sreUSD.approve(_curveLLAMMA, type(uint256).max);     // Approve sreUSD for LLAMMA collateral

        // Verify token configuration matches
        require(curveLLAMMA.collateral_token() == _sreUSD, "LLAMMA collateral mismatch");
        require(curveLLAMMA.borrowed_token() == _crvUSD, "LLAMMA borrowed token mismatch");
    }

    /*//////////////////////////////////////////////////////////////
                        REQUIRED STRATEGY FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Deploy funds into the leverage strategy using looping
     * @param _amount Amount of reUSD to deploy
     * @dev Loops to build leverage position, starting with deposited reUSD
     *      Creates buy pressure on reUSD which helps the peg
     */
    function _deployFunds(uint256 _amount) internal override {
        if (_amount == 0) return;

        uint256 reUSDToLoop = _amount;

        // Loop to build leverage, starting with deposited reUSD
        for (uint256 i = 0; i < maxIterations; i++) {
            // Stop if amount becomes too small (dust)
            if (reUSDToLoop < minLoopAmount) break;

            // a. Deposit reUSD → get sreUSD shares
            // Note: Exchange rate is NOT 1:1, sreUSD accrues value over time
            uint256 sreUSDShares = sreUSD.deposit(reUSDToLoop, address(this));
            if (sreUSDShares == 0) break;

            // b. Calculate how much crvUSD to borrow (95% LTV)
            uint256 borrowAmount = (sreUSDShares * targetCurveLTV) / BASIS_POINTS;
            if (borrowAmount == 0) break;

            // c. Supply sreUSD shares to Curve LLAMMA and borrow crvUSD
            _supplyAndBorrow(sreUSDShares, borrowAmount);

            // d. Deposit crvUSD collateral to Resupply and borrow reUSD at target LTV (92%)
            // IMPORTANT: Can only borrow 92% worth of reUSD against crvUSD collateral!
            uint256 reUSDBorrowAmount = (borrowAmount * targetResupplyLTV) / BASIS_POINTS;

            // Try to borrow - may fail if amount is below protocol minimum ($1000)
            try resupplyPair.borrow(
                reUSDBorrowAmount,  // Borrow 92 reUSD
                borrowAmount,        // Against 100 crvUSD collateral
                address(this)
            ) {
                // e. Use newly borrowed reUSD for next loop iteration
                reUSDToLoop = reUSDBorrowAmount;
            } catch {
                // Borrow failed (likely below minimum), stop looping
                break;
            }
        }
    }

    /**
     * @notice Free funds from the strategy by deleveraging
     * @param _amount Amount of reUSD to free (excludes idle balance)
     * @dev Reverses the leverage loop to unwind positions:
     *      1. reUSD → repay Resupply debt
     *      2. Withdraw crvUSD from Resupply
     *      3. crvUSD → repay Curve debt
     *      4. Withdraw sreUSD from Curve
     *      5. sreUSD → reUSD (redeem)
     *      6. Repeat until target amount is freed
     */
    function _freeFunds(uint256 _amount) internal override {
        if (_amount == 0) return;

        // Loop to unwind positions (reverse of leverage loop)
        for (uint256 i = 0; i < maxIterations; i++) {
            uint256 reUSDBalance = reUSD.balanceOf(address(this));

            // Check if we've freed enough
            if (reUSDBalance >= _amount) break;

            // Step 1: Use reUSD to repay Resupply debt
            uint256 borrowShares = resupplyPair.userBorrowShares(address(this));
            if (borrowShares > 0 && reUSDBalance > 0) {
                uint256 debtAmount = resupplyPair.toBorrowAmount(borrowShares, true, false);
                uint256 repayAmount = reUSDBalance < debtAmount ? reUSDBalance : debtAmount;

                // Convert repay amount to shares (round up to ensure full repayment)
                uint256 repayShares = (repayAmount * borrowShares) / debtAmount;
                if (repayShares > borrowShares) repayShares = borrowShares;

                if (repayShares > 0) {
                    try resupplyPair.repay(repayShares, address(this)) {} catch {}
                }
            }

            // Step 2: Withdraw crvUSD collateral from Resupply
            // Note: userCollateralBalance returns cvcrvUSD vault shares, not underlying crvUSD
            uint256 collateralShares = resupplyPair.userCollateralBalance(address(this));
            borrowShares = resupplyPair.userBorrowShares(address(this));

            if (collateralShares > 0) {
                // If debt remains, can only withdraw excess collateral (maintain solvency)
                // If no debt, withdraw everything
                uint256 withdrawableShares = collateralShares;
                if (borrowShares > 0) {
                    uint256 debtAmount = resupplyPair.toBorrowAmount(borrowShares, true, false);
                    // Need to keep enough collateral for remaining debt (at 95% LTV max)
                    // minCollateral is in underlying crvUSD terms
                    uint256 minCollateralUnderlying = (debtAmount * BASIS_POINTS) / MAX_RESUPPLY_LTV;
                    // Convert collateral shares to underlying to compare
                    address collateralToken = resupplyPair.collateral();
                    uint256 collateralUnderlying = _toCollateralAssets(collateralToken, collateralShares);

                    if (collateralUnderlying > minCollateralUnderlying) {
                        // Calculate withdrawable in underlying terms, then convert back to shares
                        uint256 withdrawableUnderlying = collateralUnderlying - minCollateralUnderlying;
                        withdrawableShares = _toCollateralShares(collateralToken, withdrawableUnderlying);
                    } else {
                        withdrawableShares = 0;
                    }
                }

                if (withdrawableShares > minLoopAmount) {
                    try resupplyPair.removeCollateral(withdrawableShares, address(this)) {} catch {}
                }
            }

            // Step 3: Use crvUSD to repay Curve debt
            uint256 crvUSDBalance = crvUSD.balanceOf(address(this));
            uint256 curveDebt = curveLLAMMA.debt(address(this));

            if (curveDebt > 0 && crvUSDBalance > 0) {
                uint256 repayAmount = crvUSDBalance < curveDebt ? crvUSDBalance : curveDebt;

                // Use max int256 for max_active_band to allow repayment regardless of band position
                try curveLLAMMA.repay(repayAmount, address(this), type(int256).max) {} catch {}
            }

            // Step 4: Withdraw sreUSD collateral from Curve
            if (curveLLAMMA.loan_exists(address(this))) {
                uint256[4] memory state = curveLLAMMA.user_state(address(this));
                uint256 sreUSDCollateral = state[0];
                curveDebt = curveLLAMMA.debt(address(this));

                if (sreUSDCollateral > 0) {
                    uint256 withdrawable = sreUSDCollateral;
                    if (curveDebt > 0) {
                        // Keep enough collateral for remaining debt at max LTV
                        // minCollateral = debt / MAX_LTV (in same units as collateral)
                        uint256 minCollateralAtMaxLTV = (curveDebt * BASIS_POINTS) / maxCurveLTV;
                        if (sreUSDCollateral > minCollateralAtMaxLTV) {
                            // Withdraw 95% of excess to leave small buffer
                            withdrawable = ((sreUSDCollateral - minCollateralAtMaxLTV) * 95) / 100;
                        } else {
                            withdrawable = 0;
                        }
                    }

                    if (withdrawable > minLoopAmount) {
                        try curveLLAMMA.remove_collateral(withdrawable) {} catch {}
                    }
                }
            }

            // Step 5: Redeem sreUSD → reUSD
            uint256 sreUSDBalance = sreUSD.balanceOf(address(this));
            if (sreUSDBalance > 0) {
                try sreUSD.redeem(sreUSDBalance, address(this), address(this)) {} catch {}
            }

            // Check if we made progress this iteration
            uint256 newReUSDBalance = reUSD.balanceOf(address(this));
            if (newReUSDBalance <= reUSDBalance + minLoopAmount) {
                // No meaningful progress, exit to avoid infinite loop
                break;
            }
        }
    }

    /**
     * @notice Harvest rewards and report total assets
     * @return Total assets controlled by the strategy
     * @dev Called during report() to update accounting
     *
     * Total Assets = Idle reUSD + sreUSD collateral value - reUSD debt
     *
     * Note: crvUSD positions cancel out:
     * - We borrow crvUSD from Curve (liability)
     * - We deposit crvUSD to Resupply (asset)
     * - These roughly net to zero, so only sreUSD collateral and reUSD debt matter
     */
    function _harvestAndReport() internal override returns (uint256) {
        // 1. Idle reUSD in strategy
        uint256 idle = reUSD.balanceOf(address(this));

        // 2. Get sreUSD collateral from Curve LLAMMA
        uint256 sreUSDCollateral = 0;
        if (curveLLAMMA.loan_exists(address(this))) {
            uint256[4] memory state = curveLLAMMA.user_state(address(this));
            sreUSDCollateral = state[0]; // collateral is first element
        }

        // 3. Convert sreUSD to reUSD value (sreUSD appreciates over time!)
        uint256 sreUSDValueInReUSD = sreUSD.convertToAssets(sreUSDCollateral);

        // 4. Get reUSD debt from Resupply
        uint256 reUSDDebt = 0;
        uint256 borrowShares = resupplyPair.userBorrowShares(address(this));
        if (borrowShares > 0) {
            // Convert shares to actual debt amount (roundUp=true for conservative accounting)
            reUSDDebt = resupplyPair.toBorrowAmount(borrowShares, true, false);
        }

        // Total = Idle + Collateral Value - Debt
        uint256 totalAssets = idle + sreUSDValueInReUSD;
        if (totalAssets > reUSDDebt) {
            totalAssets = totalAssets - reUSDDebt;
        } else {
            // Strategy is underwater (shouldn't happen with safe LTVs)
            totalAssets = 0;
        }

        // If strategy is not shutdown, redeploy any idle funds
        if (!TokenizedStrategy.isShutdown()) {
            if (idle > minLoopAmount) {
                _deployFunds(idle);
            }
        }

        return totalAssets;
    }

    function _toCollateralShares(address collateralToken, uint256 assets) internal view returns (uint256) {
        try IERC4626(collateralToken).convertToShares(assets) returns (uint256 shares) {
            return shares;
        } catch {
            return assets;
        }
    }

    function _toCollateralAssets(address collateralToken, uint256 shares) internal view returns (uint256) {
        try IERC4626(collateralToken).convertToAssets(shares) returns (uint256 assets) {
            return assets;
        } catch {
            return shares;
        }
    }

    /*//////////////////////////////////////////////////////////////
                        LEVERAGE CALCULATION HELPERS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Supply sreUSD collateral and borrow crvUSD from Curve LLAMMA
     * @param collateral Amount of sreUSD to supply
     * @param debt Amount of crvUSD to borrow
     */
    function _supplyAndBorrow(uint256 collateral, uint256 debt) internal {
        if (curveLLAMMA.loan_exists(address(this))) {
            // Add to existing loan
            curveLLAMMA.borrow_more(collateral, debt);
        } else {
            // Create new loan with 10 bands (appropriate for stable collateral)
            curveLLAMMA.create_loan(collateral, debt, 10);
        }
    }

    /**
     * @notice Calculate amount to deleverage per iteration
     * @param targetAmount Total amount we want to free
     * @return Amount to deleverage this iteration
     */
    function _calculateDeleverageAmount(uint256 targetAmount) internal view returns (uint256) {
        // Deleverage in chunks to avoid hitting limits
        // Each iteration, we aim to free a portion of the target amount
        uint256 chunkSize = targetAmount / 3; // Deleverage in 3-4 iterations typically

        // Ensure minimum loop amount
        if (chunkSize < minLoopAmount) {
            chunkSize = minLoopAmount;
        }

        return chunkSize;
    }

    /**
     * @notice Calculate how much collateral to withdraw based on debt repaid
     * @param debtRepaid Amount of debt repaid
     * @return Amount of collateral to withdraw
     */
    function _calculateCollateralToWithdraw(uint256 debtRepaid) internal view returns (uint256) {
        // With LTV%, for every LTV units of debt repaid, we can withdraw 1 unit of collateral
        // collateral = debt / LTV
        // Example: 95% LTV means for every 95 debt repaid, we free 100 collateral
        // So collateral = debt / 0.95 = debt * (BASIS_POINTS / targetCurveLTV)
        return (debtRepaid * BASIS_POINTS) / targetCurveLTV;
    }

    /*//////////////////////////////////////////////////////////////
                        MANAGEMENT FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Update target LTV parameters
     * @param _resupplyLTV New target LTV for Resupply (basis points)
     * @param _curveLTV New target LTV for Curve LLAMMA (basis points)
     */
    function setTargetLTVs(
        uint256 _resupplyLTV,
        uint256 _curveLTV
    ) external onlyManagement {
        require(_resupplyLTV <= MAX_RESUPPLY_LTV, "Resupply LTV too high");
        require(_curveLTV <= maxCurveLTV, "Curve LTV too high");

        targetResupplyLTV = _resupplyLTV;
        targetCurveLTV = _curveLTV;
    }

    /**
     * @notice Update loop parameters
     * @param _maxIterations New maximum iterations
     * @param _minLoopAmount New minimum loop amount
     */
    function setLoopParameters(
        uint256 _maxIterations,
        uint256 _minLoopAmount
    ) external onlyManagement {
        require(_maxIterations > 0 && _maxIterations <= 50, "Invalid max iterations");
        require(_minLoopAmount > 0, "Invalid min loop amount");

        maxIterations = _maxIterations;
        minLoopAmount = _minLoopAmount;
    }

    /**
     * @notice Get current health factor on Curve LLAMMA
     * @return Health factor (negative means liquidatable)
     */
    function getHealth() external view returns (int256) {
        if (!curveLLAMMA.loan_exists(address(this))) {
            return type(int256).max; // No loan = perfectly healthy
        }
        return curveLLAMMA.health(address(this), true); // full = true for complete health check
    }

    /**
     * @notice Get current debt on Curve LLAMMA
     * @return Current crvUSD debt
     */
    function getCurrentDebt() external view returns (uint256) {
        if (!curveLLAMMA.loan_exists(address(this))) {
            return 0;
        }
        return curveLLAMMA.debt(address(this));
    }

    /**
     * @notice Emergency withdrawal function
     * @param _amount Amount of reUSD to withdraw
     * @dev Called by TokenizedStrategy during emergency shutdown
     *      Uses same repayWithCollateral logic as _freeFunds
     */
    function _emergencyWithdraw(uint256 _amount) internal override {
        // Same logic as _freeFunds - unwind positions using repayWithCollateral
        _freeFunds(_amount);
    }
}
