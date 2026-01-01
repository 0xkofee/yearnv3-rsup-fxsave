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

    // Claim reward tokens (CRV, CVX, RSUP)
    function getReward(address _account) external;
}

// Curve Pool Interface for swapping
interface ICurvePool {
    function exchange(int128 i, int128 j, uint256 dx, uint256 min_dy) external returns (uint256);
    function get_dy(int128 i, int128 j, uint256 dx) external view returns (uint256);
}

// Curve Tricrypto Pool Interface (uses uint256 indices)
interface ICurveTricrypto {
    function exchange(uint256 i, uint256 j, uint256 dx, uint256 min_dy) external returns (uint256);
    function get_dy(uint256 i, uint256 j, uint256 dx) external view returns (uint256);
}

// Uniswap V3 Router Interface
interface IUniswapV3Router {
    struct ExactInputParams {
        bytes path;
        address recipient;
        uint256 deadline;
        uint256 amountIn;
        uint256 amountOutMinimum;
    }
    function exactInput(ExactInputParams calldata params) external payable returns (uint256 amountOut);
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
    uint256 public targetCurveLTV;      // Target: 9500 (95%)

    // Protocol maximum LTVs (used to validate setter inputs)
    uint256 public constant PROTOCOL_MAX_RESUPPLY_LTV = 9500;  // 95% - Resupply protocol max
    // 96% max from Curve: LTV = 100% - loan_discount(2%) - N/(2*A)
    // where N = number of bands, A = amplification parameter
    uint256 public constant PROTOCOL_MAX_CURVE_LTV = 9600;
    uint256 public constant BASIS_POINTS = 10000;

    /*//////////////////////////////////////////////////////////////
                                EVENTS
    //////////////////////////////////////////////////////////////*/

    event FullWithdrawal(uint256 amount, uint256 vaultTotalAssets);
    event LeverageIteration(uint256 iteration, uint256 reUSDToLoop);
    event DeleverageIteration(
        uint256 iteration,
        uint256 reUSDBalance,
        uint256 targetTotal,
        uint256 curveDebt,
        uint256 resupplyDebt
    );

    // Loop parameters
    uint256 public maxIterations;       // Maximum loop iterations to prevent gas issues
    uint256 public minLoopAmount;       // Minimum amount to continue looping (leverage dust threshold)
    uint256 public minBufferAmount;     // Minimum idle buffer to maintain for withdrawals
    uint256 public idleBufferBps;       // Percentage of idle reUSD to keep as buffer (basis points)

    // Reward token handling
    // DEX types: 0 = Curve (int128 indices), 1 = Uniswap V3, 2 = Curve tricrypto (uint256 indices)
    struct SwapRoute {
        address router;         // DEX router/pool address
        bytes path;             // Swap path (Curve: encoded i,j indices; UniV3: encoded path)
        uint8 dexType;          // 0 = Curve, 1 = Uniswap V3, 2 = Curve tricrypto
        bool enabled;           // Whether this route is active
    }

    address[] public rewardTokens;                      // List of reward tokens to claim
    mapping(address => SwapRoute) public rewardRoutes;  // token => swap route to crvUSD
    uint256 public minSellAmount;                       // Minimum reward amount worth selling

    // Reward swap: crvUSD → scrvUSD → reUSD
    IERC4626 public scrvUSD;                            // scrvUSD vault (ERC4626 wrapper for crvUSD)
    ICurvePool public scrvUSDReUSDPool;                 // scrvUSD/reUSD Curve pool for final swap


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

        // Set default target LTVs (used for both leverage and deleverage)
        targetCurveLTV = 9500;     // 95% for Curve LLAMMA
        targetResupplyLTV = 9200;  // 92% for Resupply

        // Set loop parameters
        maxIterations = 30;          // Maximum 30 loops per operation (need ~20 for 20x leverage)
        minLoopAmount = 1100e18;     // Min 1100 reUSD to continue looping (above Resupply's $1000 minimum borrow)
        minBufferAmount = 1000e18;   // Min 1000 reUSD idle buffer for withdrawals
        idleBufferBps = 1000;        // 10% of idle reUSD kept as buffer for withdrawals
        minSellAmount = 5e16;        // Min 0.05 tokens (~$175 for WETH) - allows intermediate token swaps

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
     *      Keeps idleBufferBps% of deposit as idle buffer
     */
    function _deployFunds(uint256 _amount) internal override {
        if (_amount == 0) return;

        // Keep idleBufferBps% of current idle as buffer for deleverage operations
        // This ensures we always have reUSD to start unwinding positions
        // Note: We use currentIdle (not totalAssets) because totalAssets is stale until report()
        uint256 currentIdle = reUSD.balanceOf(address(this));
        uint256 targetIdle = (currentIdle * idleBufferBps) / BASIS_POINTS;

        // Only deploy excess above the buffer
        uint256 reUSDToLoop;
        if (currentIdle > targetIdle) {
            reUSDToLoop = currentIdle - targetIdle;
            // Don't deploy more than requested
            if (reUSDToLoop > _amount) {
                reUSDToLoop = _amount;
            }
        } else {
            // Already below buffer, don't deploy anything
            return;
        }

        // Loop to build leverage, starting with deposited reUSD
        for (uint256 i = 0; i < maxIterations; i++) {
            // Stop if amount becomes too small (dust)
            if (reUSDToLoop < minLoopAmount) break;

            emit LeverageIteration(i, reUSDToLoop);

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

        // Calculate buffer based on remaining assets after this withdrawal
        uint256 currentIdle = reUSD.balanceOf(address(this));
        uint256 freshTotalAssets = _calculateTotalAssets(currentIdle);

        // User will receive: currentIdle + _amount
        // Remaining after withdrawal: freshTotalAssets - userReceives
        uint256 userReceives = currentIdle + _amount;
        uint256 remainingAfter = freshTotalAssets > userReceives ? freshTotalAssets - userReceives : 0;

        // If user is withdrawing everything the vault tracks, close all positions
        // Using vault's totalAssets() avoids mismatch from yield accrual or profit locking
        // Note: _amount is only what needs to be freed; userReceives = idle + _amount = total withdrawn
        uint256 vaultTotalAssets = TokenizedStrategy.totalAssets();
        bool isFullWithdrawal = (userReceives >= vaultTotalAssets);

        if (isFullWithdrawal) {
            emit FullWithdrawal(userReceives, vaultTotalAssets);
        }

        // Buffer = X% of remaining assets (ensures future withdrawals can deleverage)
        uint256 targetBuffer = 0;
        if (!isFullWithdrawal) {
            targetBuffer = (remainingAfter * idleBufferBps) / BASIS_POINTS;
            if (targetBuffer < minBufferAmount) {
                targetBuffer = minBufferAmount;
            }
        }

        // Target: userReceives + buffer, so after transfer buffer remains
        // For full withdrawal, we'll keep trying until positions are closed
        uint256 targetTotal = userReceives + targetBuffer;

        // Loop to unwind positions (reverse of leverage loop)
        for (uint256 i = 0; i < maxIterations; i++) {
            uint256 reUSDBalance = reUSD.balanceOf(address(this));
            uint256 reUSDBalanceAtLoopStart = reUSDBalance;

            // Track Curve debt at start to measure progress
            uint256 curveDebtAtLoopStart = curveLLAMMA.loan_exists(address(this))
                ? curveLLAMMA.debt(address(this))
                : 0;

            // Emit iteration state for debugging
            uint256 resupplyDebt = resupplyPair.userBorrowShares(address(this)) > 0
                ? resupplyPair.toBorrowAmount(resupplyPair.userBorrowShares(address(this)), true, false)
                : 0;
            emit DeleverageIteration(i, reUSDBalance, targetTotal, curveDebtAtLoopStart, resupplyDebt);

            // Check if we've freed enough (including buffer for future withdrawals)
            if (reUSDBalance >= targetTotal) {
                break;
            }

            // Step 1: Use reUSD to repay Resupply debt
            uint256 borrowShares = resupplyPair.userBorrowShares(address(this));
            if (borrowShares > 0 && reUSDBalance > 0) {
                uint256 debtAmount = resupplyPair.toBorrowAmount(borrowShares, true, false);
                uint256 repayAmount = reUSDBalance < debtAmount ? reUSDBalance : debtAmount;
                uint256 repayShares = (repayAmount * borrowShares) / debtAmount;

                if (repayShares > 0) {
                    try resupplyPair.repay(repayShares, address(this)) {} catch {}
                }
            }

            // Step 2: Withdraw crvUSD collateral from Resupply
            uint256 crvUSDCollateralShares = resupplyPair.userCollateralBalance(address(this));
            borrowShares = resupplyPair.userBorrowShares(address(this));

            if (crvUSDCollateralShares > 0) {
                uint256 withdrawableCrvUSDShares = crvUSDCollateralShares;

                // Must maintain LTV if there's debt (protocol requirement)
                // Only skip LTV check when debt is fully repaid
                if (borrowShares > 0) {
                    uint256 debtAmount = resupplyPair.toBorrowAmount(borrowShares, true, false);
                    uint256 minCrvUSDCollateralValue = (debtAmount * BASIS_POINTS) / targetResupplyLTV;
                    address collateralToken = resupplyPair.collateral();
                    uint256 crvUSDCollateralValue = _toCollateralAssets(collateralToken, crvUSDCollateralShares);

                    if (crvUSDCollateralValue > minCrvUSDCollateralValue) {
                        uint256 withdrawableCrvUSDValue = crvUSDCollateralValue - minCrvUSDCollateralValue;
                        withdrawableCrvUSDShares = _toCollateralShares(collateralToken, withdrawableCrvUSDValue);
                    } else {
                        withdrawableCrvUSDShares = 0;
                    }
                }
                // If no debt, withdraw everything

                if (withdrawableCrvUSDShares > 0) {
                    try resupplyPair.removeCollateral(withdrawableCrvUSDShares, address(this)) {} catch {}
                }
            }

            // Step 3: Use crvUSD to repay Curve debt
            uint256 crvUSDBalance = crvUSD.balanceOf(address(this));
            uint256 curveDebt = curveLLAMMA.debt(address(this));

            // If we need crvUSD to repay Curve and don't have enough,
            // swap reUSD → crvUSD via scrvUSD pool
            // For full withdrawals: swap all available reUSD (aggressive close)
            // For partial withdrawals: only swap for small dust amounts
            if (curveDebt > 0 && crvUSDBalance < curveDebt && address(scrvUSDReUSDPool) != address(0)) {
                bool shouldSwap = isFullWithdrawal || curveDebt < minLoopAmount;
                if (shouldSwap) {
                    uint256 reUSDForSwap = reUSD.balanceOf(address(this));
                    if (reUSDForSwap > 0) {
                        // reUSD → scrvUSD via pool (index 0 → 1)
                        try scrvUSDReUSDPool.exchange(0, 1, reUSDForSwap, 0) returns (uint256 scrvUSDReceived) {
                            // scrvUSD → crvUSD via redeem
                            if (scrvUSDReceived > 0) {
                                try scrvUSD.redeem(scrvUSDReceived, address(this), address(this)) {} catch {}
                            }
                        } catch {}
                        crvUSDBalance = crvUSD.balanceOf(address(this));
                    }
                }
            }

            if (curveDebt > 0 && crvUSDBalance > 0) {
                uint256 repayAmount = crvUSDBalance < curveDebt ? crvUSDBalance : curveDebt;
                try curveLLAMMA.repay(repayAmount, address(this), type(int256).max) {} catch {}
            }

            // Step 4: Withdraw sreUSD collateral from Curve
            if (curveLLAMMA.loan_exists(address(this))) {
                uint256[4] memory state = curveLLAMMA.user_state(address(this));
                uint256 sreUSDCollateral = state[0];
                curveDebt = curveLLAMMA.debt(address(this));

                if (sreUSDCollateral > 0) {
                    uint256 withdrawableSreUSDShares = sreUSDCollateral;

                    // Must maintain LTV if there's debt (protocol requirement)
                    // Only skip LTV check when debt is fully repaid
                    if (curveDebt > 0) {
                        uint256 sreUSDCollateralValue = sreUSD.convertToAssets(sreUSDCollateral);
                        uint256 safeCurveLTV = 9000;
                        uint256 minSreUSDCollateralValue = (curveDebt * BASIS_POINTS) / safeCurveLTV;

                        if (sreUSDCollateralValue > minSreUSDCollateralValue) {
                            uint256 withdrawableSreUSDValue = sreUSDCollateralValue - minSreUSDCollateralValue;
                            withdrawableSreUSDShares = sreUSD.convertToShares(withdrawableSreUSDValue);
                        } else {
                            withdrawableSreUSDShares = 0;
                        }
                    }
                    // If no debt, withdraw everything

                    if (withdrawableSreUSDShares > 0) {
                        try curveLLAMMA.remove_collateral(withdrawableSreUSDShares) {} catch {}
                    }
                }
            }

            // Step 5: Redeem sreUSD → reUSD
            uint256 sreUSDBalance = sreUSD.balanceOf(address(this));
            if (sreUSDBalance > 0) {
                try sreUSD.redeem(sreUSDBalance, address(this), address(this)) {} catch {}
            }

            // Step 6: If we still have crvUSD, swap it to reUSD
            crvUSDBalance = crvUSD.balanceOf(address(this));
            if (crvUSDBalance > 0 && address(scrvUSDReUSDPool) != address(0)) {
                uint256 scrvUSDShares = scrvUSD.deposit(crvUSDBalance, address(this));
                if (scrvUSDShares > 0) {
                    try scrvUSDReUSDPool.exchange(1, 0, scrvUSDShares, 0) {} catch {}
                }
            }

            // Check if we made progress this iteration
            uint256 newReUSDBalance = reUSD.balanceOf(address(this));
            uint256 newCurveDebt = curveLLAMMA.loan_exists(address(this))
                ? curveLLAMMA.debt(address(this))
                : 0;

            // Any positive progress counts - no minimum threshold for deleveraging
            bool reUSDProgress = newReUSDBalance > reUSDBalanceAtLoopStart;
            bool curveDebtProgress = curveDebtAtLoopStart > 0 && newCurveDebt < curveDebtAtLoopStart;

            if (!reUSDProgress && !curveDebtProgress) {
                break;
            }
        }

        // Verify user receives their fair share - revert if significantly short
        // This prevents silent partial withdrawals that lose user funds
        // Note: We check against userReceives (what user expects), not targetTotal (which includes buffer)
        // The buffer is nice-to-have for future withdrawals, but user's share is critical
        uint256 finalBalance = reUSD.balanceOf(address(this));
        if (finalBalance < userReceives) {
            uint256 shortfall = userReceives - finalBalance;
            // Allow up to 1% slippage due to cumulative swap fees across deleverage iterations
            uint256 maxSlippage = userReceives / 100;
            require(shortfall <= maxSlippage, "Deleverage failed: insufficient funds freed");
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
        // 0. Claim and sell rewards for crvUSD, then swap to reUSD
        uint256 crvUSDFromRewards = _claimAndSellRewards();
        if (crvUSDFromRewards > minLoopAmount && address(scrvUSDReUSDPool) != address(0)) {
            // Swap crvUSD → scrvUSD → reUSD
            // Step 1: Deposit crvUSD to scrvUSD vault
            uint256 scrvUSDShares = scrvUSD.deposit(crvUSDFromRewards, address(this));

            // Step 2: Swap scrvUSD → reUSD via Curve pool (index 1 → 0)
            if (scrvUSDShares > 0) {
                try scrvUSDReUSDPool.exchange(1, 0, scrvUSDShares, 0) {} catch {}
            }
        }

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

    /**
     * @notice Calculate total assets: idle + collateral value - debt
     * @param idle Current idle reUSD balance
     * @return Total assets in reUSD terms
     */
    function _calculateTotalAssets(uint256 idle) internal view returns (uint256) {
        // Get sreUSD collateral from Curve LLAMMA
        uint256 sreUSDCollateral = 0;
        if (curveLLAMMA.loan_exists(address(this))) {
            uint256[4] memory state = curveLLAMMA.user_state(address(this));
            sreUSDCollateral = state[0];
        }

        // Convert sreUSD to reUSD value
        uint256 sreUSDValueInReUSD = sreUSD.convertToAssets(sreUSDCollateral);

        // Get reUSD debt from Resupply
        uint256 reUSDDebt = 0;
        uint256 borrowShares = resupplyPair.userBorrowShares(address(this));
        if (borrowShares > 0) {
            reUSDDebt = resupplyPair.toBorrowAmount(borrowShares, true, false);
        }

        // Total = Idle + Collateral Value - Debt
        uint256 total = idle + sreUSDValueInReUSD;
        if (total > reUSDDebt) {
            return total - reUSDDebt;
        }
        return 0;
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
                        REWARD HANDLING
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Claim rewards from Resupply and sell for crvUSD
     * @return crvUSDReceived Amount of crvUSD received from selling rewards
     */
    function _claimAndSellRewards() internal returns (uint256 crvUSDReceived) {
        // Measure crvUSD balance before selling (handles intermediate tokens like WETH)
        uint256 crvUSDBefore = crvUSD.balanceOf(address(this));

        // Claim all pending rewards from Resupply
        try resupplyPair.getReward(address(this)) {} catch {}

        // Sell each reward token for crvUSD (or intermediate token)
        for (uint256 i = 0; i < rewardTokens.length; i++) {
            address token = rewardTokens[i];
            SwapRoute memory route = rewardRoutes[token];

            if (!route.enabled) continue;

            uint256 balance = ERC20(token).balanceOf(address(this));
            if (balance < minSellAmount) continue;

            _swap(token, balance, route);
        }

        // Return actual crvUSD gained (works correctly with intermediate tokens)
        return crvUSD.balanceOf(address(this)) - crvUSDBefore;
    }

    /**
     * @notice Swap reward token to crvUSD using configured route
     * @param _token Token to swap
     * @param _amount Amount to swap
     * @param _route Swap route configuration
     * @return amountOut Amount of crvUSD received
     */
    function _swap(
        address _token,
        uint256 _amount,
        SwapRoute memory _route
    ) internal returns (uint256 amountOut) {
        if (_route.dexType == 0) {
            // Curve swap (legacy pools with int128 indices)
            // path is encoded as (int128 i, int128 j)
            (int128 i, int128 j) = abi.decode(_route.path, (int128, int128));
            amountOut = ICurvePool(_route.router).exchange(i, j, _amount, 0);
        } else if (_route.dexType == 2) {
            // Curve tricrypto swap (newer pools with uint256 indices)
            // path is encoded as (uint256 i, uint256 j)
            (uint256 i, uint256 j) = abi.decode(_route.path, (uint256, uint256));
            amountOut = ICurveTricrypto(_route.router).exchange(i, j, _amount, 0);
        } else if (_route.dexType == 1) {
            // Uniswap V3 swap
            // path is the encoded swap path (token0, fee, token1, fee, token2, ...)
            IUniswapV3Router.ExactInputParams memory params = IUniswapV3Router.ExactInputParams({
                path: _route.path,
                recipient: address(this),
                deadline: block.timestamp,
                amountIn: _amount,
                amountOutMinimum: 0
            });
            amountOut = IUniswapV3Router(_route.router).exactInput(params);
        }

        return amountOut;
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
        require(_resupplyLTV <= PROTOCOL_MAX_RESUPPLY_LTV, "Resupply LTV too high");
        require(_curveLTV <= PROTOCOL_MAX_CURVE_LTV, "Curve LTV too high");

        targetResupplyLTV = _resupplyLTV;
        targetCurveLTV = _curveLTV;
    }

    /**
     * @notice Update loop parameters
     * @param _maxIterations New maximum iterations
     * @param _minLoopAmount New minimum loop amount (for leverage operations)
     * @param _minBufferAmount Minimum idle buffer to maintain for withdrawals
     * @param _idleBufferBps Percentage of idle reUSD to keep as buffer (basis points, e.g., 500 = 5%)
     */
    function setLoopParameters(
        uint256 _maxIterations,
        uint256 _minLoopAmount,
        uint256 _minBufferAmount,
        uint256 _idleBufferBps
    ) external onlyManagement {
        require(_maxIterations > 0 && _maxIterations <= 50, "Invalid max iterations");
        require(_minLoopAmount > 0, "Invalid min loop amount");
        require(_minBufferAmount > 0, "Invalid min buffer amount");
        require(_idleBufferBps <= 2000, "Buffer too high"); // Max 20%

        maxIterations = _maxIterations;
        minLoopAmount = _minLoopAmount;
        minBufferAmount = _minBufferAmount;
        idleBufferBps = _idleBufferBps;
    }

    /**
     * @notice Add a reward token with its swap route
     * @param _token Address of the reward token
     * @param _router DEX router/pool address
     * @param _path Encoded swap path
     * @param _dexType 0 = Curve, 1 = Uniswap V3
     */
    function addRewardToken(
        address _token,
        address _router,
        bytes calldata _path,
        uint8 _dexType
    ) external onlyManagement {
        require(_token != address(0), "Invalid token");
        require(_router != address(0), "Invalid router");

        // Add to reward tokens list if not already present
        bool exists = false;
        for (uint256 i = 0; i < rewardTokens.length; i++) {
            if (rewardTokens[i] == _token) {
                exists = true;
                break;
            }
        }
        if (!exists) {
            rewardTokens.push(_token);
        }

        // Set the swap route
        rewardRoutes[_token] = SwapRoute({
            router: _router,
            path: _path,
            dexType: _dexType,
            enabled: true
        });

        // Approve token for router
        ERC20(_token).safeApprove(_router, type(uint256).max);
    }

    /**
     * @notice Update swap route for an existing reward token
     * @param _token Address of the reward token
     * @param _router DEX router/pool address
     * @param _path Encoded swap path
     * @param _dexType 0 = Curve, 1 = Uniswap V3
     */
    function updateRewardRoute(
        address _token,
        address _router,
        bytes calldata _path,
        uint8 _dexType
    ) external onlyManagement {
        require(rewardRoutes[_token].router != address(0), "Token not added");

        // Revoke old approval if router changed
        if (rewardRoutes[_token].router != _router) {
            ERC20(_token).safeApprove(rewardRoutes[_token].router, 0);
            ERC20(_token).safeApprove(_router, type(uint256).max);
        }

        rewardRoutes[_token] = SwapRoute({
            router: _router,
            path: _path,
            dexType: _dexType,
            enabled: true
        });
    }

    /**
     * @notice Enable or disable a reward token
     * @param _token Address of the reward token
     * @param _enabled Whether to enable or disable
     */
    function setRewardTokenEnabled(address _token, bool _enabled) external onlyManagement {
        require(rewardRoutes[_token].router != address(0), "Token not added");
        rewardRoutes[_token].enabled = _enabled;
    }

    /**
     * @notice Update minimum sell amount for rewards
     * @param _minSellAmount New minimum amount
     */
    function setMinSellAmount(uint256 _minSellAmount) external onlyManagement {
        minSellAmount = _minSellAmount;
    }

    /**
     * @notice Set the scrvUSD/reUSD pool for swapping reward crvUSD to reUSD
     * @param _scrvUSD Address of scrvUSD vault (ERC4626 wrapper for crvUSD)
     * @param _pool Address of scrvUSD/reUSD Curve pool
     * @dev Pool must have reUSD at index 0 and scrvUSD at index 1
     */
    function setRewardSwapPool(address _scrvUSD, address _pool) external onlyManagement {
        scrvUSD = IERC4626(_scrvUSD);
        scrvUSDReUSDPool = ICurvePool(_pool);

        // Approve scrvUSD for the pool (for scrvUSD → reUSD swaps)
        ERC20(_scrvUSD).safeApprove(_pool, type(uint256).max);
        // Approve reUSD for the pool (for reUSD → scrvUSD swaps in dust cleanup)
        reUSD.safeApprove(_pool, type(uint256).max);
        // Approve crvUSD for scrvUSD vault
        crvUSD.safeApprove(_scrvUSD, type(uint256).max);
    }

    /**
     * @notice Get list of reward tokens
     * @return Array of reward token addresses
     */
    function getRewardTokens() external view returns (address[] memory) {
        return rewardTokens;
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
