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

    // Repay via callback - allows deleveraging by swapping collateral to crvUSD
    // callbacker: Contract that receives collateral and returns crvUSD
    // callback_args: [factory_id, controller_id, user_collateral, user_borrowed]
    // callback_bytes: Additional data for callback
    // _for: Address to repay for
    function repay_extended(
        address callbacker,
        uint256[] calldata callback_args,
        bytes calldata callback_bytes,
        address _for
    ) external;

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

    // Repay reUSD debt using crvUSD collateral via swap
    // _swapperAddress: Whitelisted swapper contract
    // _collateralToSwap: Amount of crvUSD collateral to swap for reUSD
    // _amountOutMin: Minimum reUSD to receive (slippage protection)
    // _path: Swap path [crvUSD, ..., reUSD]
    function repayWithCollateral(
        address _swapperAddress,
        uint256 _collateralToSwap,
        uint256 _amountOutMin,
        address[] calldata _path
    ) external returns (uint256 _amountOut);

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

// Balancer V2 Vault Interface for Flash Loans (0% fee)
interface IBalancerVault {
    function flashLoan(
        address recipient,
        address[] memory tokens,
        uint256[] memory amounts,
        bytes memory userData
    ) external;
}

// Aave V3 Pool Interface for Flash Loans (0.05% fee - fallback)
interface IAavePool {
    function flashLoanSimple(
        address receiverAddress,
        address asset,
        uint256 amount,
        bytes calldata params,
        uint16 referralCode
    ) external;
}

// ERC-3156 Flash Lender Interface (for crvUSD flash loans - 0% fee)
interface IERC3156FlashLender {
    function maxFlashLoan(address token) external view returns (uint256);
    function flashLoan(
        address receiver,
        address token,
        uint256 amount,
        bytes calldata data
    ) external returns (bool);
}

// Curve crvUSD/USDC Pool Interface (StableSwap uses int128 indices)
interface ICrvUSDPool {
    function exchange(int128 i, int128 j, uint256 dx, uint256 min_dy) external returns (uint256);
    function get_dy(int128 i, int128 j, uint256 dx) external view returns (uint256);
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
    // Curve LTV is calculated dynamically: (100% - loan_discount - curveLTVBuffer)
    uint256 public curveLTVBuffer;      // Buffer below max LTV (default: 600 = 6%)
    uint256 public curveLoanBands;      // Number of bands for Curve loans (default: 5)

    // Protocol maximum LTVs (used to validate setter inputs)
    uint256 public constant PROTOCOL_MAX_RESUPPLY_LTV = 9500;  // 95% - Resupply protocol max
    uint256 public constant BASIS_POINTS = 10000;

    /*//////////////////////////////////////////////////////////////
                                EVENTS
    //////////////////////////////////////////////////////////////*/

    event FullWithdrawal(uint256 amount, uint256 vaultTotalAssets);
    event BufferParked(uint256 reUSDAmount, uint256 scrvUSDReceived);
    event BufferSwept(uint256 scrvUSDAmount, uint256 reUSDReceived);
    event LossCalculated(uint256 totalBefore, uint256 totalAfter, uint256 actualLoss, uint256 targetIdle);
    event USDCShortfallCovered(uint256 shortfall, uint256 reUSDUsed);

    // Loop parameters
    uint256 public maxIterations;       // Maximum loop iterations to prevent gas issues
    uint256 public minLoopAmount;       // Minimum amount to continue looping (leverage dust threshold)
    uint256 public marginalLoopThreshold; // Stop when iteration adds < X% of original (in bps, 1000 = 10%)

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

    // Deleverage with collateral configuration
    // Resupply: uses whitelisted swapper to swap crvUSD collateral → reUSD
    address public resupplySwapper;                     // Whitelisted swapper for Resupply repayWithCollateral
    address[] public resupplySwapPath;                  // Swap path: [crvUSD, ..., reUSD]

    // Curve: uses repay_extended with callback to swap sreUSD collateral → crvUSD
    // The strategy itself acts as the callbacker, implementing callback_repay
    // sreUSD/reUSD pool is used for sreUSD → reUSD conversion in callback

    // Flash loan deleverage configuration
    enum FlashLoanProvider { BALANCER, AAVE }
    FlashLoanProvider public flashLoanProvider;         // Default: BALANCER (0) - 0% fee
    IBalancerVault public balancerVault;                // Balancer V2 Vault for flash loans (0% fee)
    IAavePool public aavePool;                          // Aave V3 Pool for flash loans (0.05% fee - fallback)
    IERC3156FlashLender public crvUSDFlashLender;       // crvUSD FlashLender (0% fee, preferred for small amounts)
    ERC20 public usdc;                                  // USDC token for flash loans
    ICrvUSDPool public crvUSDUSDCPool;                  // Curve pool for USDC <-> crvUSD swaps
    int128 public crvUSDIndexInPool;                    // Index of crvUSD in the swap pool (0)
    int128 public usdcIndexInPool;                      // Index of USDC in the swap pool (1)

    // scrvUSD buffer for loss mechanism
    // When freeing funds, excess reUSD is parked as scrvUSD to hide it from idle balance
    // This ensures each user pays their own deleverage costs via Yearn V3's loss mechanism
    // Using scrvUSD instead of crvUSD: fewer swaps (less slippage) + earns yield while parked
    uint256 public scrvUSDBuffer;                       // Amount of scrvUSD parked as buffer

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

        // Set default target LTVs
        targetResupplyLTV = 9200;  // 92% for Resupply
        curveLTVBuffer = 600;      // 6% buffer below Curve's max (accounts for bands + safety)
        curveLoanBands = 5;        // 5 bands for Curve loans

        // Set loop parameters
        maxIterations = 30;          // Maximum 30 loops per operation (need ~20 for 20x leverage)
        minLoopAmount = 1100e18;     // Min 1100 reUSD to continue looping (above Resupply's $1000 minimum borrow)
        marginalLoopThreshold = 1000; // 10% - stop when iteration adds < 10% of original deposit
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
     * @dev Loops to build leverage position, starting with deposited reUSD.
     *      First sweeps any crvUSD buffer from previous withdrawals.
     *      Creates buy pressure on reUSD which helps the peg.
     *      Stops when amount falls below minLoopAmount (dust threshold).
     */
    function _deployFunds(uint256 _amount) internal override {
        if (_amount == 0) return;

        // First, sweep any scrvUSD buffer from previous withdrawals back to reUSD
        // This recovers excess funds that were parked to implement loss mechanism
        _sweepScrvUSDBuffer();

        // Deploy all available funds (including swept buffer)
        uint256 reUSDToLoop = reUSD.balanceOf(address(this));
        uint256 originalAmount = reUSDToLoop; // Track original for marginal threshold check

        // Query Curve's loan_discount to calculate safe LTV
        // loan_discount is in 1e18 scale (e.g., 2e16 = 2%)
        // safeLTV = 100% - loan_discount - curveLTVBuffer
        // curveLTVBuffer accounts for bands effect + safety margin
        uint256 loanDiscount = curveLLAMMA.loan_discount();
        uint256 safeCurveLTV = BASIS_POINTS - (loanDiscount * BASIS_POINTS / 1e18) - curveLTVBuffer;

        // Loop to build leverage, starting with deposited reUSD
        for (uint256 i = 0; i < maxIterations; i++) {
            // Stop if amount becomes too small (dust)
            if (reUSDToLoop < minLoopAmount) break;

            // Stop if marginal contribution is below threshold (e.g., < 10% of original)
            // This saves gas on diminishing returns iterations
            if (reUSDToLoop * BASIS_POINTS < originalAmount * marginalLoopThreshold) break;

            // a. Deposit reUSD → get sreUSD shares
            uint256 sreUSDShares = sreUSD.deposit(reUSDToLoop, address(this));
            if (sreUSDShares == 0) break;

            // b. Calculate how much crvUSD to borrow based on collateral VALUE
            // sreUSD appreciates over time, so use value not share count
            uint256 sreUSDValue = sreUSD.convertToAssets(sreUSDShares);
            uint256 borrowAmount = (sreUSDValue * safeCurveLTV) / BASIS_POINTS;
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
     * @notice External wrapper for re-deploying exact amount to enable try/catch
     * @param _amount Amount of reUSD to deploy (exact, not full balance)
     * @dev Only callable by this contract. Used for re-leverage after withdrawals.
     *      Unlike _deployFunds, this does NOT sweep buffer and deploys ONLY _amount.
     */
    function deployExactExternal(uint256 _amount) external {
        require(msg.sender == address(this), "Only self");
        _deployExactAmount(_amount);
    }

    /**
     * @notice Deploy exact amount of reUSD (no buffer sweep, no full balance deploy)
     * @param _amount Exact amount of reUSD to deploy
     * @dev Used for re-leverage after withdrawals. Does NOT touch scrvUSD buffer
     *      and only deploys the specified amount, leaving other idle funds alone.
     */
    function _deployExactAmount(uint256 _amount) internal {
        if (_amount == 0) return;

        // Use exact amount specified, not full balance
        uint256 reUSDToLoop = _amount;
        uint256 originalAmount = _amount;

        // Query Curve's loan_discount to calculate safe LTV
        uint256 loanDiscount = curveLLAMMA.loan_discount();
        uint256 safeCurveLTV = BASIS_POINTS - (loanDiscount * BASIS_POINTS / 1e18) - curveLTVBuffer;

        // Loop to build leverage
        for (uint256 i = 0; i < maxIterations; i++) {
            if (reUSDToLoop < minLoopAmount) break;
            // Stop when iteration adds < threshold% of original (e.g., 10%) - diminishing returns
            if (reUSDToLoop * BASIS_POINTS < originalAmount * marginalLoopThreshold) break;

            uint256 sreUSDShares = sreUSD.deposit(reUSDToLoop, address(this));
            if (sreUSDShares == 0) break;

            uint256 sreUSDValue = sreUSD.convertToAssets(sreUSDShares);
            uint256 borrowAmount = (sreUSDValue * safeCurveLTV) / BASIS_POINTS;
            if (borrowAmount == 0) break;

            _supplyAndBorrow(sreUSDShares, borrowAmount);

            // Assumes crvUSD ≈ reUSD ≈ $1 (conservative if reUSD depegs)
            uint256 reUSDBorrowAmount = (borrowAmount * targetResupplyLTV) / BASIS_POINTS;

            try resupplyPair.borrow(reUSDBorrowAmount, borrowAmount, address(this)) {
                reUSDToLoop = reUSDBorrowAmount;
            } catch {
                break;
            }
        }
    }

    /**
     * @notice Free funds from the strategy by deleveraging
     * @param _amount Amount of reUSD to free (excludes idle balance)
     * @dev Uses flash loan for atomic deleverage. Withdrawing user pays full deleverage cost.
     *
     *      Loss Mechanism:
     *      1. Sweep any existing buffer (from previous withdrawals)
     *      2. If idle covers withdrawal, return early (no deleverage needed)
     *      3. Snapshot totalAssets before deleverage
     *      4. Execute flash loan deleverage (frees excess with 2x multiplier)
     *      5. Recalculate totalAssets after deleverage
     *      6. Actual loss = before - after (captures flash fees + slippage)
     *      7. User pays FULL deleverage loss (they caused it, they pay it)
     *      8. Park excess reUSD as scrvUSD to leave targetIdle = userWithdrawal - userLoss
     *      9. TokenizedStrategy sees shortfall and passes loss to withdrawing user
     */
    function _freeFunds(uint256 _amount) internal override {
        if (_amount == 0) return;

        // Check if this is a full withdrawal (last user exiting) BEFORE any operations
        // Must use original idle (before buffer sweep) for accurate comparison
        uint256 originalIdle = reUSD.balanceOf(address(this));
        uint256 vaultTotalAssets = TokenizedStrategy.totalAssets();
        // User's expected assets = what they'd get if we free _amount
        // This equals their share value, which TokenizedStrategy calculates as idle + _amount (shortfall)
        // For full withdrawal: after user exits, vault should be empty
        // Note: buffer value is NOT part of vaultTotalAssets (it's hidden as scrvUSD)
        // So we only check: original idle + requested amount >= vault's recorded assets
        bool isFullWithdrawal = (originalIdle + _amount >= vaultTotalAssets);
        if (isFullWithdrawal) {
            emit FullWithdrawal(originalIdle + _amount, vaultTotalAssets);
        }

        // 1. Sweep any existing buffer from previous withdrawals
        // This ensures buffer value is available to current withdrawer
        if (scrvUSDBuffer > 0) {
            _sweepScrvUSDBuffer();
        }

        // 2. Check if idle already covers the withdrawal (after buffer sweep)
        uint256 idlePreDeleverage = reUSD.balanceOf(address(this));
        if (idlePreDeleverage >= _amount) {
            return; // Idle covers withdrawal, no need to deleverage
        }

        // 3. Check if there's a position to deleverage
        uint256 totalPreDeleverage = _calculateTotalAssets(idlePreDeleverage);
        uint256 positionValue = totalPreDeleverage > idlePreDeleverage ? totalPreDeleverage - idlePreDeleverage : 0;

        if (positionValue == 0) {
            return; // No position to deleverage
        }

        // Require flash loan configuration for deleverage
        if (flashLoanProvider == FlashLoanProvider.BALANCER) {
            require(address(balancerVault) != address(0), "Balancer not configured");
        } else {
            require(address(aavePool) != address(0), "Aave not configured");
        }

        // 4. Execute flash loan deleverage (frees ~2x the requested amount)
        _freeFundsWithFlashLoan(_amount);

        // 5. Recalculate total assets after deleverage
        uint256 idlePostDeleverage = reUSD.balanceOf(address(this));
        uint256 totalPostDeleverage = _calculateTotalAssets(idlePostDeleverage);

        // 6. Calculate actual loss from deleverage
        uint256 actualLoss = totalPreDeleverage > totalPostDeleverage ? totalPreDeleverage - totalPostDeleverage : 0;

        // 7. User pays the FULL loss from their deleverage
        // They caused this deleverage, they pay its cost (swaps, flash loan premium, etc.)
        uint256 userLoss = actualLoss;

        // 8. Calculate target idle = user's full withdrawal amount - their loss
        // userWithdrawalAmount = originalIdle (already available) + _amount (freed by deleverage)
        uint256 userWithdrawalAmount = originalIdle + _amount;
        uint256 targetIdle = userWithdrawalAmount > userLoss ? userWithdrawalAmount - userLoss : 0;

        emit LossCalculated(totalPreDeleverage, totalPostDeleverage, actualLoss, targetIdle);

        // 9. Re-deploy excess funds to maintain leverage for remaining depositors
        // Skip if: full withdrawal, shutdown, or no excess
        if (!isFullWithdrawal && !TokenizedStrategy.isShutdown() && idlePostDeleverage > targetIdle) {
            uint256 excess = idlePostDeleverage - targetIdle;
            if (excess > minLoopAmount) {
                // Try to re-deploy, fall back to parking if it fails
                // This ensures withdrawals always succeed even if protocols are down
                try this.deployExactExternal(excess) {
                    // Re-deploy succeeded - remaining depositors are re-leveraged
                } catch {
                    // Re-deploy failed - park as scrvUSD, will be deployed on next report()
                    _parkExcessAsScrvUSD(excess);
                }
            } else if (excess > 0) {
                // Below threshold - park as scrvUSD (will be deployed on next deposit/report)
                _parkExcessAsScrvUSD(excess);
            }
        }
        // Now idle ≈ targetIdle, TokenizedStrategy sees loss ≈ userLoss
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
     * @param idleReUSD Current idle reUSD balance
     * @return Total assets in reUSD terms
     */
    function _calculateTotalAssets(uint256 idleReUSD) internal view returns (uint256) {
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
        uint256 total = idleReUSD + sreUSDValueInReUSD;
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
            // Create new loan with configured number of bands
            curveLLAMMA.create_loan(collateral, debt, curveLoanBands);
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
     * @param _amount Amount to swap
     * @param _route Swap route configuration
     * @return amountOut Amount of crvUSD received
     */
    function _swap(
        address, // _token - not used, router handles token addresses
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
     * @notice Update target LTV for Resupply
     * @param _resupplyLTV New target LTV for Resupply (basis points)
     */
    function setResupplyLTV(uint256 _resupplyLTV) external onlyManagement {
        require(_resupplyLTV <= PROTOCOL_MAX_RESUPPLY_LTV, "Resupply LTV too high");
        targetResupplyLTV = _resupplyLTV;
    }

    /**
     * @notice Update Curve LTV buffer (distance below max LTV)
     * @param _buffer Buffer in basis points (e.g., 600 = 6%)
     * @dev Curve safe LTV = 100% - loan_discount - buffer
     */
    function setCurveLTVBuffer(uint256 _buffer) external onlyManagement {
        require(_buffer <= 2000, "Buffer too high"); // Max 20% buffer
        curveLTVBuffer = _buffer;
    }

    /**
     * @notice Set number of bands for Curve loans
     * @param _bands Number of bands (4-50 typically)
     */
    function setCurveLoanBands(uint256 _bands) external onlyManagement {
        require(_bands >= 4 && _bands <= 50, "Invalid bands");
        curveLoanBands = _bands;
    }

    /**
     * @notice Update loop parameters
     * @param _maxIterations New maximum iterations
     * @param _minLoopAmount New minimum loop amount (for leverage operations)
     * @param _marginalThreshold Stop when iteration adds < X% of original (in bps, 1000 = 10%)
     */
    function setLoopParameters(
        uint256 _maxIterations,
        uint256 _minLoopAmount,
        uint256 _marginalThreshold
    ) external onlyManagement {
        require(_maxIterations > 0 && _maxIterations <= 50, "Invalid max iterations");
        require(_minLoopAmount > 0, "Invalid min loop amount");
        require(_marginalThreshold > 0 && _marginalThreshold <= 5000, "Invalid marginal threshold"); // 0-50%

        maxIterations = _maxIterations;
        minLoopAmount = _minLoopAmount;
        marginalLoopThreshold = _marginalThreshold;
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
     * @notice Configure flash loan parameters for deleverage
     * @param _balancerVault Balancer V2 Vault address for flash loans (0% fee - USDC fallback), or address(0) to skip
     * @param _aavePool Aave V3 Pool address for flash loans (0.05% fee - USDC fallback), or address(0) to skip
     * @param _crvUSDFlashLender crvUSD FlashLender address (0% fee, no swap overhead - preferred), or address(0) to skip
     * @param _usdc USDC token address
     * @param _crvUSDUSDCPool Curve pool for USDC <-> crvUSD swaps
     * @param _crvUSDIndex Index of crvUSD in the pool
     * @param _usdcIndex Index of USDC in the pool
     */
    function setFlashLoanConfig(
        address _balancerVault,
        address _aavePool,
        address _crvUSDFlashLender,
        address _usdc,
        address _crvUSDUSDCPool,
        int128 _crvUSDIndex,
        int128 _usdcIndex
    ) external onlyManagement {
        require(_balancerVault != address(0) || _aavePool != address(0) || _crvUSDFlashLender != address(0), "No flash loan provider");
        require(_usdc != address(0), "Invalid USDC");
        require(_crvUSDUSDCPool != address(0), "Invalid swap pool");

        if (_balancerVault != address(0)) {
            balancerVault = IBalancerVault(_balancerVault);
        }
        if (_aavePool != address(0)) {
            aavePool = IAavePool(_aavePool);
        }
        if (_crvUSDFlashLender != address(0)) {
            crvUSDFlashLender = IERC3156FlashLender(_crvUSDFlashLender);
        }
        usdc = ERC20(_usdc);
        crvUSDUSDCPool = ICrvUSDPool(_crvUSDUSDCPool);
        crvUSDIndexInPool = _crvUSDIndex;
        usdcIndexInPool = _usdcIndex;

        // Approve USDC for swap pool
        usdc.safeApprove(_crvUSDUSDCPool, type(uint256).max);
        // Approve USDC for Aave repayment (Aave pulls via transferFrom)
        if (_aavePool != address(0)) {
            usdc.safeApprove(_aavePool, type(uint256).max);
        }
        // Approve crvUSD for swap pool
        crvUSD.safeApprove(_crvUSDUSDCPool, type(uint256).max);
        // Note: crvUSD approval for FlashLender is done in onFlashLoan callback
    }

    /**
     * @notice Set the flash loan provider
     * @param _provider The provider to use (0 = Balancer, 1 = Aave)
     */
    function setFlashLoanProvider(FlashLoanProvider _provider) external onlyManagement {
        if (_provider == FlashLoanProvider.BALANCER) {
            require(address(balancerVault) != address(0), "Balancer not configured");
        } else {
            require(address(aavePool) != address(0), "Aave not configured");
        }
        flashLoanProvider = _provider;
    }

    /*//////////////////////////////////////////////////////////////
                    SCRVUSD BUFFER MANAGEMENT
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Park excess reUSD as scrvUSD to hide it from idle balance
     * @param _reUSDAmount Amount of reUSD to convert to scrvUSD buffer
     * @dev Converts reUSD → scrvUSD via Curve pool (single swap)
     *      Using scrvUSD instead of crvUSD: fewer swaps + earns yield while parked
     */
    function _parkExcessAsScrvUSD(uint256 _reUSDAmount) internal {
        if (_reUSDAmount == 0 || address(scrvUSDReUSDPool) == address(0)) return;

        // reUSD → scrvUSD via pool (index 0 → 1)
        uint256 scrvUSDReceived = scrvUSDReUSDPool.exchange(0, 1, _reUSDAmount, 0);
        if (scrvUSDReceived == 0) return;

        // Track buffer (scrvUSD earns yield while parked)
        scrvUSDBuffer += scrvUSDReceived;

        emit BufferParked(_reUSDAmount, scrvUSDReceived);
    }

    /**
     * @notice Sweep scrvUSD buffer back to reUSD
     * @dev Converts scrvUSD → reUSD via Curve pool (single swap)
     *      Called at start of _deployFunds and _freeFunds to recover parked funds
     */
    function _sweepScrvUSDBuffer() internal {
        if (scrvUSDBuffer == 0 || address(scrvUSDReUSDPool) == address(0)) return;

        uint256 bufferAmount = scrvUSDBuffer;
        scrvUSDBuffer = 0; // Clear buffer before conversion

        // scrvUSD → reUSD via pool (index 1 → 0)
        uint256 reUSDReceived = scrvUSDReUSDPool.exchange(1, 0, bufferAmount, 0);

        emit BufferSwept(bufferAmount, reUSDReceived);
    }

    /**
     * @notice Get current scrvUSD buffer amount
     * @return Amount of scrvUSD parked in buffer
     */
    function getScrvUSDBuffer() external view returns (uint256) {
        return scrvUSDBuffer;
    }

    /*//////////////////////////////////////////////////////////////
                    DELEVERAGE WITH COLLATERAL
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Configure the Resupply swapper for repayWithCollateral
     * @param _swapper Address of the whitelisted swapper contract
     * @param _path Swap path from crvUSD to reUSD (e.g., [crvUSD, scrvUSD, reUSD] or direct)
     * @dev The swapper must be whitelisted by Resupply protocol
     */
    function setResupplySwapper(address _swapper, address[] calldata _path) external onlyManagement {
        require(_swapper != address(0), "Invalid swapper");
        require(_path.length >= 2, "Path too short");
        require(_path[0] == address(crvUSD), "Path must start with crvUSD");
        require(_path[_path.length - 1] == address(reUSD), "Path must end with reUSD");

        resupplySwapper = _swapper;
        resupplySwapPath = _path;
    }

    /**
     * @notice Deleverage the entire position using repayWithCollateral
     * @param _minCrvUSDOut Minimum crvUSD to receive from Curve deleverage (slippage protection)
     * @param _minReUSDOut Minimum reUSD to receive from Resupply deleverage (slippage protection)
     * @dev This is an alternative to the iterative deleverage in _freeFunds.
     *      It closes positions atomically using collateral swaps instead of
     *      requiring idle funds for debt repayment.
     *
     *      Flow:
     *      1. Close Resupply position: repayWithCollateral swaps crvUSD → reUSD to repay debt
     *      2. Close Curve position: repay_extended with callback swaps sreUSD → crvUSD to repay debt
     *      3. Convert remaining sreUSD → reUSD
     *
     *      This approach is faster (1 tx vs many iterations) but requires:
     *      - Resupply swapper to be configured and whitelisted
     *      - Sufficient liquidity in swap pools
     */
    function deleverageWithCollateral(
        uint256 _minCrvUSDOut,
        uint256 _minReUSDOut
    ) external onlyManagement {
        // Step 1: Close Resupply position using repayWithCollateral
        // This swaps our crvUSD collateral → reUSD to repay the reUSD debt
        _deleverageResupplyWithCollateral(_minReUSDOut);

        // Step 2: Close Curve position using repay_extended
        // This uses a callback to swap sreUSD collateral → crvUSD to repay the crvUSD debt
        _deleverageCurveWithCollateral(_minCrvUSDOut);

        // Step 3: Convert any remaining sreUSD to reUSD
        uint256 sreUSDBalance = sreUSD.balanceOf(address(this));
        if (sreUSDBalance > 0) {
            sreUSD.redeem(sreUSDBalance, address(this), address(this));
        }
    }

    /**
     * @notice Close Resupply position by repaying debt with collateral
     * @param _minReUSDOut Minimum reUSD to receive from swap
     */
    function _deleverageResupplyWithCollateral(uint256 _minReUSDOut) internal {
        uint256 borrowShares = resupplyPair.userBorrowShares(address(this));
        if (borrowShares == 0) return; // No debt to repay

        require(resupplySwapper != address(0), "Resupply swapper not configured");
        require(resupplySwapPath.length >= 2, "Resupply swap path not configured");

        // Get total collateral available
        uint256 collateralBalance = resupplyPair.userCollateralBalance(address(this));
        if (collateralBalance == 0) return;

        // Use all collateral to repay as much debt as possible
        // The function will swap crvUSD → reUSD and apply it to debt
        resupplyPair.repayWithCollateral(
            resupplySwapper,
            collateralBalance,
            _minReUSDOut,
            resupplySwapPath
        );
    }

    /**
     * @notice Close Curve position by repaying debt with collateral via callback
     * @param _minCrvUSDOut Minimum crvUSD to receive from swap
     * @dev Uses repay_extended which calls back to this contract's callback_repay function
     */
    function _deleverageCurveWithCollateral(uint256 _minCrvUSDOut) internal {
        if (!curveLLAMMA.loan_exists(address(this))) return;

        uint256 curveDebt = curveLLAMMA.debt(address(this));
        if (curveDebt == 0) return;

        // Get current collateral
        uint256[4] memory state = curveLLAMMA.user_state(address(this));
        uint256 sreUSDCollateral = state[0];

        // callback_args: [0] = not used, [1] = not used, [2] = collateral to use, [3] = debt to repay
        uint256[] memory callbackArgs = new uint256[](4);
        callbackArgs[2] = sreUSDCollateral;  // Use all collateral
        callbackArgs[3] = curveDebt;         // Repay all debt

        // Encode (fraction, minCrvUSDOut) - fraction = 1e18 for full deleverage
        bytes memory callbackBytes = abi.encode(uint256(1e18), _minCrvUSDOut);

        // Call repay_extended - Curve will call our callback_repay function
        curveLLAMMA.repay_extended(
            address(this),  // This contract is the callbacker
            callbackArgs,
            callbackBytes,
            address(this)   // Repay for this contract
        );
    }

    /**
     * @notice Callback function called by Curve LLAMMA during repay_extended
     * @param user The user being repaid for
     * @param stablecoins Amount of stablecoins (crvUSD) in the position (from soft liquidation)
     * @param callback_bytes Encoded (fraction, minCrvUSDOut) - fraction in 1e18 scale
     * @return [crvUSD returned to repay debt, collateral returned to user]
     * @dev This function receives sreUSD collateral, swaps a portion to crvUSD based on
     *      the fraction parameter, and returns unused collateral to maintain position.
     *      For full deleverage: fraction = 1e18 (100%)
     *      For partial deleverage: fraction < 1e18
     */
    function callback_repay(
        address user,
        uint256 stablecoins,
        uint256, // collateral - we read balance directly
        uint256, // debt - we already know the debt
        uint256[] calldata, // callback_args - not used
        bytes calldata callback_bytes
    ) external returns (uint256[2] memory) {
        require(msg.sender == address(curveLLAMMA), "Only LLAMMA");
        require(user == address(this), "Invalid user");

        return _processCallback(stablecoins, callback_bytes);
    }

    /**
     * @notice Internal callback processing to avoid stack too deep
     */
    function _processCallback(
        uint256 stablecoins,
        bytes calldata callback_bytes
    ) internal returns (uint256[2] memory) {
        // Decode parameters: (fraction in 1e18 scale, minCrvUSDOut)
        (uint256 fraction, uint256 minCrvUSDOut) = callback_bytes.length > 0
            ? abi.decode(callback_bytes, (uint256, uint256))
            : (uint256(1e18), uint256(0));

        // Get total sreUSD and calculate split
        uint256 sreUSDBalance = sreUSD.balanceOf(address(this));
        uint256 toSwap = (sreUSDBalance * fraction) / 1e18;
        uint256 toReturn = sreUSDBalance - toSwap;

        // Convert sreUSD → crvUSD: sreUSD → reUSD → scrvUSD → crvUSD
        uint256 crvUSDReceived = _convertSreUSDToCrvUSD(toSwap);

        // Add stablecoins from soft liquidation and validate
        crvUSDReceived += stablecoins;
        require(crvUSDReceived >= minCrvUSDOut, "Insufficient crvUSD output");

        // Approve crvUSD for Curve to take
        crvUSD.safeApprove(address(curveLLAMMA), crvUSDReceived);

        return [crvUSDReceived, toReturn];
    }

    /**
     * @notice Convert sreUSD to crvUSD via reUSD and scrvUSD
     * @param amount Amount of sreUSD to convert
     * @return crvUSD received
     */
    function _convertSreUSDToCrvUSD(uint256 amount) internal returns (uint256) {
        if (amount == 0) return 0;

        // sreUSD → reUSD
        uint256 reUSDReceived = sreUSD.redeem(amount, address(this), address(this));
        if (reUSDReceived == 0 || address(scrvUSDReUSDPool) == address(0)) return 0;

        // reUSD → scrvUSD via pool (index 0 → 1)
        uint256 scrvUSDReceived = scrvUSDReUSDPool.exchange(0, 1, reUSDReceived, 0);
        if (scrvUSDReceived == 0) return 0;

        // scrvUSD → crvUSD
        return scrvUSD.redeem(scrvUSDReceived, address(this), address(this));
    }

    /**
     * @notice Emergency withdrawal function
     * @param _amount Amount of reUSD to withdraw
     * @dev Called by TokenizedStrategy during emergency shutdown
     *      Uses same iterative logic as _freeFunds
     */
    function _emergencyWithdraw(uint256 _amount) internal override {
        // Same logic as _freeFunds - unwind positions iteratively
        _freeFunds(_amount);
    }

    /*//////////////////////////////////////////////////////////////
                    FLASH LOAN DELEVERAGE
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Free funds using flash loan for atomic deleverage
     * @param _amount Amount of reUSD to free from the leveraged position
     * @dev Uses configured flash loan provider to atomically close positions:
     *      1. Flash loan USDC
     *      2. Swap USDC → crvUSD
     *      3. Repay Curve debt → unlock sreUSD
     *      4. Redeem sreUSD → reUSD
     *      5. Repay Resupply debt → unlock crvUSD
     *      6. Swap crvUSD → USDC
     *      7. Repay flash loan
     */
    function _freeFundsWithFlashLoan(uint256 _amount) internal {
        uint256 currentIdle = reUSD.balanceOf(address(this));
        uint256 freshTotalAssets = _calculateTotalAssets(currentIdle);

        // Calculate position value (total assets minus idle)
        uint256 positionValue = freshTotalAssets > currentIdle ? freshTotalAssets - currentIdle : 0;

        // Check if this is a full withdrawal (last user exiting)
        // Note: FullWithdrawal event is emitted in _freeFunds() to handle all cases
        uint256 userReceives = currentIdle + _amount;
        uint256 vaultTotalAssets = TokenizedStrategy.totalAssets();
        bool isFullWithdrawal = (userReceives >= vaultTotalAssets);

        if (positionValue == 0) return; // No position to unwind (idle covers withdrawal)

        // Calculate fraction of position to close (in basis points)
        uint256 fractionBps;
        if (isFullWithdrawal || _amount >= positionValue) {
            fractionBps = BASIS_POINTS; // 100% - full deleverage
        } else {
            // Base fraction = amount to free / position value
            uint256 baseFraction = (_amount * BASIS_POINTS) / positionValue;

            // 2x multiplier needed due to Curve's LTV constraint on partial withdrawals.
            // When you repay X% of Curve debt, you can only withdraw ~(X-3)% of collateral
            // because remaining debt still requires minimum collateral at safe LTV.
            // This ~3% gap compounds to ~8% shortfall. 2x ensures we always free enough.
            // Excess is parked as scrvUSD buffer and recovered on next operation.
            fractionBps = baseFraction * 2;
            if (fractionBps > BASIS_POINTS) fractionBps = BASIS_POINTS;
        }

        // Calculate crvUSD needed: proportional to Curve debt
        uint256 curveDebtForFlash = curveLLAMMA.loan_exists(address(this)) ? curveLLAMMA.debt(address(this)) : 0;
        uint256 crvUSDNeeded = (curveDebtForFlash * fractionBps) / BASIS_POINTS;
        if (crvUSDNeeded == 0) return;

        // Encode params for callback
        bytes memory userData = abi.encode(fractionBps);

        // Check if crvUSD flash loan can cover the amount (preferred - no swap overhead)
        uint256 crvUSDAvailable = address(crvUSDFlashLender) != address(0)
            ? crvUSDFlashLender.maxFlashLoan(address(crvUSD))
            : 0;

        if (crvUSDAvailable >= crvUSDNeeded) {
            // Use crvUSD flash loan (no USDC swaps needed - ~0.02% slippage savings)
            crvUSDFlashLender.flashLoan(address(this), address(crvUSD), crvUSDNeeded, userData);
        } else {
            // Fall back to USDC flash loan (requires USDC <-> crvUSD swaps)
            // Note: We don't add a buffer here because round-trip slippage (~0.02%) is proportional.
            // Adding X% buffer means we flash X% more but also owe X% more, with same % loss.
            // Shortfall helper handles the gap using position equity instead.
            uint256 usdcToFlash = crvUSDNeeded / 1e12; // Convert 18→6 decimals
            if (usdcToFlash == 0) return;

            if (flashLoanProvider == FlashLoanProvider.BALANCER) {
                address[] memory tokens = new address[](1);
                tokens[0] = address(usdc);
                uint256[] memory amounts = new uint256[](1);
                amounts[0] = usdcToFlash;
                balancerVault.flashLoan(address(this), tokens, amounts, userData);
            } else {
                aavePool.flashLoanSimple(address(this), address(usdc), usdcToFlash, userData, 0);
            }
        }
    }

    /**
     * @notice Balancer V2 flash loan callback
     * @param tokens Array of flash loaned tokens (just USDC)
     * @param amounts Array of flash loaned amounts
     * @param feeAmounts Array of fees (0 for Balancer)
     * @param userData Encoded fractionBps
     */
    function receiveFlashLoan(
        address[] memory tokens,
        uint256[] memory amounts,
        uint256[] memory feeAmounts,
        bytes memory userData
    ) external {
        require(msg.sender == address(balancerVault), "Only Balancer vault");
        require(tokens.length == 1 && tokens[0] == address(usdc), "Wrong token");

        uint256 fractionBps = abi.decode(userData, (uint256));

        // Swap USDC → crvUSD
        uint256 crvUSDReceived = crvUSDUSDCPool.exchange(
            usdcIndexInPool,
            crvUSDIndexInPool,
            amounts[0],
            0 // min_dy - slippage validated at end
        );

        // Core deleverage (operates on crvUSD)
        _executeFlashLoanDeleverage(crvUSDReceived, fractionBps);

        // Swap crvUSD → USDC and cover shortfall for repayment
        uint256 amountOwed = amounts[0] + feeAmounts[0];
        _swapCrvUSDToUSDCAndCoverShortfall(amountOwed);

        // Repay by transferring USDC back to Balancer vault
        usdc.safeTransfer(address(balancerVault), amountOwed);
    }

    /**
     * @notice Aave V3 flash loan callback
     * @param asset The flash loaned asset (USDC)
     * @param amount The flash loaned amount
     * @param premium The flash loan fee (0.05%)
     * @param initiator Who initiated the flash loan
     * @param params Encoded fractionBps
     * @return True if successful
     */
    function executeOperation(
        address asset,
        uint256 amount,
        uint256 premium,
        address initiator,
        bytes calldata params
    ) external returns (bool) {
        require(msg.sender == address(aavePool), "Only Aave pool");
        require(initiator == address(this), "Only self-initiated");
        require(asset == address(usdc), "Wrong asset");

        uint256 fractionBps = abi.decode(params, (uint256));

        // Swap USDC → crvUSD
        uint256 crvUSDReceived = crvUSDUSDCPool.exchange(
            usdcIndexInPool,
            crvUSDIndexInPool,
            amount,
            0 // min_dy - slippage validated at end
        );

        // Core deleverage (operates on crvUSD)
        _executeFlashLoanDeleverage(crvUSDReceived, fractionBps);

        // Swap crvUSD → USDC and cover shortfall for repayment
        uint256 amountOwed = amount + premium;
        _swapCrvUSDToUSDCAndCoverShortfall(amountOwed);

        // Aave pulls repayment via transferFrom (approval already set)
        return true;
    }

    /**
     * @notice crvUSD ERC-3156 flash loan callback
     * @param initiator Who initiated the flash loan
     * @param token The flash loaned token (crvUSD)
     * @param amount The flash loaned amount
     * @param fee The flash loan fee (0 for crvUSD)
     * @param data Encoded fractionBps
     * @return The magic return value per ERC-3156
     * @dev This is the preferred path when amount <= maxFlashLoan(crvUSD)
     *      No USDC swaps needed - directly use crvUSD for deleverage
     */
    function onFlashLoan(
        address initiator,
        address token,
        uint256 amount,
        uint256 fee,
        bytes calldata data
    ) external returns (bytes32) {
        require(msg.sender == address(crvUSDFlashLender), "Only crvUSD FlashLender");
        require(initiator == address(this), "Only self-initiated");
        require(token == address(crvUSD), "Only crvUSD");

        uint256 fractionBps = abi.decode(data, (uint256));

        // Core deleverage (directly operates on crvUSD - no swaps needed!)
        _executeFlashLoanDeleverage(amount, fractionBps);

        // Cover any crvUSD shortfall from position equity
        uint256 crvUSDNeeded = amount + fee;
        _coverCrvUSDShortfall(crvUSDNeeded);

        // Transfer crvUSD back to FlashLender
        // Note: Curve FlashLender checks balance after callback, not via transferFrom
        crvUSD.safeTransfer(msg.sender, crvUSDNeeded);

        return keccak256("ERC3156FlashBorrower.onFlashLoan");
    }

    /**
     * @notice Cover crvUSD shortfall using reUSD equity
     * @param crvUSDNeeded Amount of crvUSD needed
     * @dev Converts reUSD → scrvUSD → crvUSD if we don't have enough crvUSD
     */
    function _coverCrvUSDShortfall(uint256 crvUSDNeeded) internal {
        uint256 crvUSDBalance = crvUSD.balanceOf(address(this));
        if (crvUSDBalance >= crvUSDNeeded) return; // No shortfall

        // Calculate shortfall and convert reUSD to crvUSD
        uint256 shortfall = crvUSDNeeded - crvUSDBalance;

        // Add 2% buffer to cover reUSD→scrvUSD slippage
        // Also ensure minimum swap amount to avoid dust rounding to 0
        uint256 crvUSDToGet = (shortfall * 102) / 100;
        if (crvUSDToGet < 1e15) crvUSDToGet = 1e15; // Min 0.001 crvUSD to avoid dust issues

        uint256 scrvUSDSharesNeeded = scrvUSD.previewWithdraw(crvUSDToGet);
        uint256 reUSDNeeded = scrvUSD.convertToAssets(scrvUSDSharesNeeded); // reUSD ≈ crvUSD value
        if (reUSDNeeded < 1e15) reUSDNeeded = 1e15; // Min 0.001 reUSD to avoid dust swap returning 0

        // Swap path: reUSD → scrvUSD → crvUSD
        if (reUSDNeeded > 0 && address(scrvUSDReUSDPool) != address(0)) {
            uint256 scrvUSDReceived = scrvUSDReUSDPool.exchange(0, 1, reUSDNeeded, 0);
            if (scrvUSDReceived > 0) {
                scrvUSD.redeem(scrvUSDReceived, address(this), address(this));
            }
        }

        // Verify we have enough crvUSD
        crvUSDBalance = crvUSD.balanceOf(address(this));
        require(crvUSDBalance >= crvUSDNeeded, "Insufficient crvUSD for repayment");
    }

    /**
     * @notice Core deleverage execution (operates on crvUSD)
     * @param crvUSDAmount Amount of crvUSD available for deleverage
     * @param fractionBps Fraction of position to close (in basis points)
     * @dev This function only handles the core deleverage steps.
     *      USDC swap logic is handled by each callback before/after calling this.
     *      crvUSD flash loan callback calls this directly (no swaps needed).
     */
    function _executeFlashLoanDeleverage(
        uint256 crvUSDAmount,
        uint256 fractionBps
    ) internal {
        // Step 1: Repay Curve debt (proportional to fraction)
        if (curveLLAMMA.loan_exists(address(this))) {
            uint256 curveDebt = curveLLAMMA.debt(address(this));
            uint256 debtToRepay = (curveDebt * fractionBps) / BASIS_POINTS;
            if (debtToRepay > crvUSDAmount) debtToRepay = crvUSDAmount;
            if (debtToRepay > curveDebt) debtToRepay = curveDebt;

            if (debtToRepay > 0) {
                curveLLAMMA.repay(debtToRepay, address(this), type(int256).max);
            }
        }

        // Step 2: Withdraw sreUSD collateral from Curve
        if (curveLLAMMA.loan_exists(address(this))) {
            uint256[4] memory state = curveLLAMMA.user_state(address(this));
            uint256 sreUSDCollateral = state[0];
            uint256 curveDebtRemaining = curveLLAMMA.debt(address(this));

            uint256 withdrawableSreUSD = sreUSDCollateral;
            if (curveDebtRemaining > 0) {
                // Still have debt - can only withdraw excess above safe LTV
                uint256 sreUSDCollateralValue = sreUSD.convertToAssets(sreUSDCollateral);
                uint256 safeCurveLTV = 9400; // 94% safe LTV (1% buffer below 95% target)
                uint256 minCollateralValue = (curveDebtRemaining * BASIS_POINTS) / safeCurveLTV;

                if (sreUSDCollateralValue > minCollateralValue) {
                    withdrawableSreUSD = sreUSD.convertToShares(sreUSDCollateralValue - minCollateralValue);
                } else {
                    withdrawableSreUSD = 0;
                }
            }
            if (withdrawableSreUSD > 0) {
                curveLLAMMA.remove_collateral(withdrawableSreUSD);
            }
        }

        // Step 3: Redeem sreUSD → reUSD
        uint256 sreUSDBalance = sreUSD.balanceOf(address(this));
        if (sreUSDBalance > 0) {
            sreUSD.redeem(sreUSDBalance, address(this), address(this));
        }

        // Step 4: Repay Resupply debt (proportional to fraction)
        uint256 borrowShares = resupplyPair.userBorrowShares(address(this));
        if (borrowShares > 0) {
            uint256 reUSDBalance = reUSD.balanceOf(address(this));
            uint256 debtAmount = resupplyPair.toBorrowAmount(borrowShares, true, false);
            uint256 debtToRepay = (debtAmount * fractionBps) / BASIS_POINTS;

            // Don't repay more than we have or more than total debt
            if (debtToRepay > reUSDBalance) debtToRepay = reUSDBalance;
            if (debtToRepay > debtAmount) debtToRepay = debtAmount;

            if (debtToRepay > 0) {
                uint256 repayShares = (debtToRepay * borrowShares) / debtAmount;
                if (repayShares > borrowShares) repayShares = borrowShares;
                resupplyPair.repay(repayShares, address(this));
            }
        }

        // Step 5: Withdraw crvUSD collateral from Resupply
        borrowShares = resupplyPair.userBorrowShares(address(this));
        uint256 collateralBalance = resupplyPair.userCollateralBalance(address(this));
        if (collateralBalance > 0) {
            uint256 withdrawable = collateralBalance;
            if (borrowShares > 0) {
                // Still have debt - can only withdraw excess
                uint256 debtAmount = resupplyPair.toBorrowAmount(borrowShares, true, false);
                address collateralToken = resupplyPair.collateral();
                uint256 collateralValue = _toCollateralAssets(collateralToken, collateralBalance);
                uint256 minCollateralValue = (debtAmount * BASIS_POINTS) / targetResupplyLTV;
                if (collateralValue > minCollateralValue) {
                    withdrawable = _toCollateralShares(collateralToken, collateralValue - minCollateralValue);
                } else {
                    withdrawable = 0;
                }
            }
            if (withdrawable > 0) {
                resupplyPair.removeCollateral(withdrawable, address(this));
            }
        }
        // crvUSD balance is now ready for repayment (crvUSD flash) or swap back to USDC (Balancer/Aave)
    }

    /**
     * @notice Swap crvUSD to USDC and cover any shortfall for USDC flash loan repayment
     * @param usdcNeeded Amount of USDC needed for flash loan repayment
     * @dev Used by Balancer and Aave callbacks after core deleverage
     */
    function _swapCrvUSDToUSDCAndCoverShortfall(uint256 usdcNeeded) internal {
        // Swap all crvUSD to USDC
        uint256 crvUSDBalance = crvUSD.balanceOf(address(this));
        if (crvUSDBalance > 0) {
            crvUSDUSDCPool.exchange(
                crvUSDIndexInPool,
                usdcIndexInPool,
                crvUSDBalance,
                0 // min_dy - we need whatever we can get to repay
            );
        }

        // Cover any remaining USDC shortfall using leftover reUSD equity
        // This is ALWAYS needed due to round-trip swap slippage:
        // - USDC → crvUSD swap gains ~0.01% but crvUSD → USDC loses ~0.03%
        // - Net round-trip loss is ~0.02% of flash loan amount (~$10-20 on $50k)
        // - Aave flash loan adds 0.05% fee on top (Balancer is free)
        // The reUSD used here comes from position equity (sreUSD value > Resupply debt)
        uint256 usdcBalance = usdc.balanceOf(address(this));
        if (usdcBalance < usdcNeeded && address(scrvUSDReUSDPool) != address(0)) {
            uint256 shortfall = usdcNeeded - usdcBalance;

            // Calculate reUSD needed using actual conversion rates
            // Add 2% buffer at crvUSD level to cover: crvUSD→USDC slippage + reUSD→scrvUSD slippage
            uint256 crvUSDNeededForShortfall = (shortfall * 1e12 * 102) / 100; // USDC 6 dec → crvUSD 18 dec + 2%
            uint256 scrvUSDSharesNeeded = scrvUSD.previewWithdraw(crvUSDNeededForShortfall);
            uint256 reUSDNeeded = scrvUSD.convertToAssets(scrvUSDSharesNeeded); // reUSD ≈ crvUSD value

            emit USDCShortfallCovered(shortfall, reUSDNeeded);

            // Swap path: reUSD → scrvUSD → crvUSD → USDC
            uint256 scrvUSDReceived = scrvUSDReUSDPool.exchange(0, 1, reUSDNeeded, 0);
            if (scrvUSDReceived > 0) {
                uint256 crvUSDFromSwap = scrvUSD.redeem(scrvUSDReceived, address(this), address(this));
                if (crvUSDFromSwap > 0) {
                    crvUSDUSDCPool.exchange(crvUSDIndexInPool, usdcIndexInPool, crvUSDFromSwap, 0);
                }
            }
        }

        // Verify we have enough USDC for repayment
        usdcBalance = usdc.balanceOf(address(this));
        require(usdcBalance >= usdcNeeded, "Insufficient USDC for repayment");
    }
}
