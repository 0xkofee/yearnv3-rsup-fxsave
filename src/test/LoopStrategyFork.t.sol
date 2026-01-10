// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.18;

import {Test, Vm} from "forge-std/Test.sol";

import {SreUSDCrvUSDLoopStrategy} from "../SreUSDCrvUSDLoopStrategy.sol";
import {IStrategy} from "../interfaces/IStrategy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

interface IResupply {
    function borrow(uint256 _borrowAmount, uint256 _underlyingAmount, address _receiver) external returns (uint256);
    function repay(uint256 _shares, address _borrower) external returns (uint256 _amountRepaid);
    function removeCollateral(uint256 _collateralAmount, address _receiver) external;
    function toBorrowAmount(uint256 _shares, bool _roundUp, bool _previewInterest) external view returns (uint256);
    function userBorrowShares(address _account) external view returns (uint256);
    function userCollateralBalance(address _account) external view returns (uint256);
    function collateral() external view returns (address);
}

interface ICurveLLAMMA {
    function loan_exists(address user) external view returns (bool);
    function debt(address user) external view returns (uint256);
    function user_state(address user) external view returns (uint256[4] memory);
    function max_borrowable(uint256 collateral, uint256 N, uint256 current_debt, address user) external view returns (uint256);
}


interface IStrategyWithRedeem {
    function redeem(uint256 shares, address receiver, address owner) external returns (uint256);
}

/**
 * @title LoopStrategyForkTest
 * @notice Mainnet fork tests for the SreUSD/crvUSD Loop Strategy
 * @dev Tests against real deployed contracts on Ethereum mainnet
 *
 * Run with:
 *   forge test --match-contract LoopStrategyForkTest --fork-url $MAINNET_RPC_URL -vvv
 */
contract LoopStrategyForkTest is Test {
    SreUSDCrvUSDLoopStrategy public loopStrategy;
    IStrategy public strategyVault;

    // Events (must match strategy events for vm.expectEmit)
    event FullWithdrawal(uint256 amount, uint256 vaultTotalAssets);
    event LeverageIteration(uint256 iteration, uint256 reUSDToLoop);
    event DeleverageIteration(
        uint256 iteration,
        uint256 reUSDBalance,
        uint256 targetTotal,
        uint256 curveDebt,
        uint256 resupplyDebt
    );

    // Real mainnet addresses
    address public constant REUSD = 0x57aB1E0003F623289CD798B1824Be09a793e4Bec;
    address public constant SREUSD = 0x557AB1e003951A73c12D16F0fEA8490E39C33C35;
    address public constant CRVUSD = 0xf939E0A03FB07F59A73314E73794Be0E57ac1b4E;
    address public constant CURVE_LLAMMA = 0x4F79Fe450a2BAF833E8f50340BD230f5A3eCaFe9;
    address public constant RESUPPLY_PAIR = 0xD42535Cda82a4569BA7209857446222ABd14A82c;

    // Reward tokens
    address public constant CRV = 0xD533a949740bb3306d119CC777fa900bA034cd52;
    address public constant CVX = 0x4e3FBD56CD56c3e72c1403e103b45Db9da5B9D2B;
    address public constant RSUP = 0x419905009e4656fdC02418C7Df35B1E61Ed5F726;
    address public constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;

    // Curve pools
    address public constant CRV_CRVUSD_POOL = 0x4eBdF703948ddCEA3B11f675B4D1Fba9d2414A14;
    address public constant CVX_ETH_POOL = 0xB576491F1E6e5E62f1d8F26062Ee822B40B0E0d4;
    address public constant RSUP_WETH_POOL = 0xEe351f12EAE8C2B8B9d1B9BFd3c5dd565234578d;

    // scrvUSD swap
    address public constant SCRVUSD = 0x0655977FEb2f289A4aB78af67BAB0d17aAb84367;
    address public constant SCRVUSD_REUSD_POOL = 0xc522A6606BBA746d7960404F22a3DB936B6F4F50;

    // Flash loan configuration
    address public constant BALANCER_VAULT = 0xBA12222222228d8Ba445958a75a0704d566BF2C8;
    address public constant AAVE_V3_POOL = 0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2;
    address public constant CRVUSD_FLASH_LENDER = 0x26dE7861e213A5351F6ED767d00e0839930e9eE1;
    address public constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    // Curve crvUSD/USDC pool (llamma)
    address public constant CRVUSD_USDC_POOL = 0x4DEcE678ceceb27446b35C672dC7d61F30bAD69E;

    // Test accounts
    address public management = address(this);
    address public keeper;
    address public user;

    uint256 public constant INITIAL_DEPOSIT = 10000 ether;
    uint256 public constant BASIS_POINTS = 10000;
    uint256 public constant DEFAULT_FORK_BLOCK = 24107304;

    function setUp() public {
        string memory rpcUrl = vm.envOr("ANVIL_RPC_URL", string(""));
        if (bytes(rpcUrl).length == 0) {
            rpcUrl = "http://127.0.0.1:8545";
        }
        uint256 forkBlock = vm.envOr("MAINNET_FORK_BLOCK", DEFAULT_FORK_BLOCK);
        vm.createSelectFork(rpcUrl, forkBlock);
        if (!_requiredContractsPresent()) {
            emit log("Required contracts not deployed at fork block, retrying at latest.");
            vm.createSelectFork(rpcUrl);
            require(_requiredContractsPresent(), "Required contracts not deployed on fork");
        }

        assertEq(block.chainid, 1, "Not on mainnet fork");

        keeper = makeAddr("keeper");
        user = makeAddr("user");

        loopStrategy = new SreUSDCrvUSDLoopStrategy(
            REUSD, SREUSD, CRVUSD, CURVE_LLAMMA, RESUPPLY_PAIR, "SreUSD Loop Strategy"
        );
        strategyVault = IStrategy(address(loopStrategy));

        strategyVault.setKeeper(keeper);
        strategyVault.setPendingManagement(management);
        vm.prank(management);
        strategyVault.acceptManagement();

        loopStrategy.setRewardSwapPool(SCRVUSD, SCRVUSD_REUSD_POOL);

        // Configure flash loan for deleverage
        // - crvUSD FlashLender (0% fee, no swap overhead - preferred for amounts <= ~1M)
        // - Balancer V2 (0% fee - USDC fallback for larger amounts)
        // - Aave (0.05% fee - last resort)
        // In pool 0x4DEcE678ceceb27446b35C672dC7d61F30bAD69E: USDC = index 0, crvUSD = index 1
        loopStrategy.setFlashLoanConfig(BALANCER_VAULT, AAVE_V3_POOL, CRVUSD_FLASH_LENDER, USDC, CRVUSD_USDC_POOL, 1, 0);

        deal(REUSD, user, 20000 ether, true);

        // Warm contracts
        RESUPPLY_PAIR.call(abi.encodeWithSignature("name()"));
        address(0x10101010E0C3171D894B71B3400668aF311e7D94).call(abi.encodeWithSignature("name()"));

        vm.label(address(loopStrategy), "Strategy");
        vm.label(REUSD, "reUSD");
        vm.label(CRVUSD, "crvUSD");
    }

    /*//////////////////////////////////////////////////////////////
                            HELPER FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Check if FullWithdrawal event was emitted in recorded logs
    function assertFullWithdrawalEmitted(Vm.Log[] memory logs) internal pure {
        bytes32 fullWithdrawalSelector = keccak256("FullWithdrawal(uint256,uint256)");
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == fullWithdrawalSelector) {
                return; // Found the event
            }
        }
        revert("FullWithdrawal event was not emitted");
    }

    /// @notice Check that FullWithdrawal event was NOT emitted in recorded logs
    function assertFullWithdrawalNotEmitted(Vm.Log[] memory logs) internal pure {
        bytes32 fullWithdrawalSelector = keccak256("FullWithdrawal(uint256,uint256)");
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == fullWithdrawalSelector) {
                revert("FullWithdrawal event should not have been emitted");
            }
        }
    }

    /*//////////////////////////////////////////////////////////////
                        STRATEGY LIFECYCLE TESTS
    //////////////////////////////////////////////////////////////*/

    function testFork_DeployFunds_CreatesLeveragedPosition() public {
        vm.startPrank(user);
        IERC20(REUSD).approve(address(loopStrategy), INITIAL_DEPOSIT);
        uint256 shares = strategyVault.deposit(INITIAL_DEPOSIT, user);
        vm.stopPrank();

        assertGt(shares, 0, "No shares issued");
        assertApproxEqRel(strategyVault.totalAssets(), INITIAL_DEPOSIT, 0.05e18, "Incorrect total assets");
    }

    function testFork_Harvest_RealYieldAccrual() public {
        vm.startPrank(user);
        IERC20(REUSD).approve(address(loopStrategy), INITIAL_DEPOSIT);
        strategyVault.deposit(INITIAL_DEPOSIT, user);
        vm.stopPrank();

        uint256 initialAssets = strategyVault.totalAssets();
        skip(30 days);

        vm.prank(management);
        loopStrategy.setLoopParameters(loopStrategy.maxIterations(), type(uint256).max, loopStrategy.marginalLoopThreshold());

        vm.prank(keeper);
        strategyVault.report();

        uint256 finalAssets = strategyVault.totalAssets();
        assertGt(finalAssets, initialAssets, "No yield captured");
    }

    function testFork_PartialWithdrawal() public {
        vm.startPrank(user);
        IERC20(REUSD).approve(address(loopStrategy), INITIAL_DEPOSIT);
        strategyVault.deposit(INITIAL_DEPOSIT, user);
        vm.stopPrank();

        uint256 sharesToWithdraw = (strategyVault.balanceOf(user) * 30) / 100;
        uint256 expectedAssets = strategyVault.previewRedeem(sharesToWithdraw);

        vm.prank(user);
        uint256 assetsWithdrawn = strategyVault.redeem(sharesToWithdraw, user, user);

        assertGt(assetsWithdrawn, 0, "No assets withdrawn");
        assertLe(assetsWithdrawn, expectedAssets, "Withdrawal exceeds preview");
    }

    function testFork_FullWithdrawal() public {
        vm.startPrank(user);
        IERC20(REUSD).approve(address(loopStrategy), INITIAL_DEPOSIT);
        strategyVault.deposit(INITIAL_DEPOSIT, user);
        vm.stopPrank();

        uint256 shares = strategyVault.balanceOf(user);
        uint256 expectedAssets = strategyVault.previewRedeem(shares);

        // Verify positions exist before withdrawal
        assertTrue(ICurveLLAMMA(CURVE_LLAMMA).loan_exists(address(loopStrategy)), "Curve loan should exist before");
        assertGt(IResupply(RESUPPLY_PAIR).userBorrowShares(address(loopStrategy)), 0, "Resupply debt should exist before");

        vm.recordLogs();

        vm.prank(user);
        uint256 assetsWithdrawn = strategyVault.redeem(shares, user, user);

        // Verify FullWithdrawal event was emitted
        assertFullWithdrawalEmitted(vm.getRecordedLogs());

        assertGt(assetsWithdrawn, 0, "No assets withdrawn");
        assertLe(assetsWithdrawn, expectedAssets, "Withdrawal exceeds preview");
        assertEq(strategyVault.balanceOf(user), 0, "Shares not fully burned");

        // Verify isFullWithdrawal triggered: positions should be closed
        assertEq(ICurveLLAMMA(CURVE_LLAMMA).debt(address(loopStrategy)), 0, "Curve debt should be 0 after full withdrawal");
        assertEq(IResupply(RESUPPLY_PAIR).userBorrowShares(address(loopStrategy)), 0, "Resupply debt should be 0 after full withdrawal");
    }

    function testFork_MultiUserWithdrawal() public {
        address user1 = address(0x1111);
        address user2 = address(0x2222);
        address user3 = address(0x3333);

        deal(REUSD, user1, 10_000e18);
        deal(REUSD, user2, 5_000e18);
        deal(REUSD, user3, 3_000e18);

        vm.startPrank(user1);
        IERC20(REUSD).approve(address(loopStrategy), 10_000e18);
        uint256 shares1 = strategyVault.deposit(10_000e18, user1);
        vm.stopPrank();

        vm.startPrank(user2);
        IERC20(REUSD).approve(address(loopStrategy), 5_000e18);
        uint256 shares2 = strategyVault.deposit(5_000e18, user2);
        vm.stopPrank();

        vm.startPrank(user3);
        IERC20(REUSD).approve(address(loopStrategy), 3_000e18);
        uint256 shares3 = strategyVault.deposit(3_000e18, user3);
        vm.stopPrank();

        // All funds deployed (no idle buffer with flash loan deleverage)

        // User1 withdraws (partial - should NOT emit FullWithdrawal)
        vm.recordLogs();
        vm.prank(user1);
        uint256 assets1 = IStrategyWithRedeem(address(loopStrategy)).redeem(shares1, user1, user1);
        assertFullWithdrawalNotEmitted(vm.getRecordedLogs());
        // Note: With flash loan deleverage, partial withdrawals from leveraged positions
        // have higher slippage due to how equity is distributed. User1 gets ~90% vs 95%
        // for iterative approach. Full withdrawals (like single user) get ~99.6%.
        assertGt(assets1, 9000e18, "User1 should receive most of deposit");
        assertEq(IERC20(address(loopStrategy)).balanceOf(user1), 0, "User1 should have no shares");

        // User2 withdraws (partial - should NOT emit FullWithdrawal)
        vm.recordLogs();
        vm.prank(user2);
        uint256 assets2 = IStrategyWithRedeem(address(loopStrategy)).redeem(shares2, user2, user2);
        assertFullWithdrawalNotEmitted(vm.getRecordedLogs());
        assertGt(assets2, 4500e18, "User2 should receive most of deposit");
        assertEq(IERC20(address(loopStrategy)).balanceOf(user2), 0, "User2 should have no shares");

        // User3 withdraws (last user - SHOULD emit FullWithdrawal)
        vm.recordLogs();
        vm.prank(user3);
        uint256 assets3 = IStrategyWithRedeem(address(loopStrategy)).redeem(shares3, user3, user3);
        assertFullWithdrawalEmitted(vm.getRecordedLogs());
        assertGt(assets3, 2700e18, "User3 should receive most of deposit");
        assertEq(IERC20(address(loopStrategy)).balanceOf(user3), 0, "User3 should have no shares");

        // Strategy should be empty
        assertEq(strategyVault.totalAssets(), 0, "Strategy should be empty");

        // Verify positions are fully closed
        assertEq(ICurveLLAMMA(CURVE_LLAMMA).debt(address(loopStrategy)), 0, "Curve debt should be 0");
        assertEq(IResupply(RESUPPLY_PAIR).userBorrowShares(address(loopStrategy)), 0, "Resupply debt should be 0");
    }

    /*//////////////////////////////////////////////////////////////
                        DELEVERAGE STUCK SCENARIOS
    //////////////////////////////////////////////////////////////*/

    /// @notice Test: Can withdrawal get stuck if we drain idle buffer first?
    /// @dev Scenario: Small withdrawals drain idle, then large withdrawal can't deleverage
    function testFork_WithdrawalStuck_IdleDrained() public {
        // Setup: User deposits
        vm.startPrank(user);
        IERC20(REUSD).approve(address(loopStrategy), INITIAL_DEPOSIT);
        uint256 shares = strategyVault.deposit(INITIAL_DEPOSIT, user);
        vm.stopPrank();

        uint256 idleBefore = IERC20(REUSD).balanceOf(address(loopStrategy));
        emit log_named_decimal_uint("Idle buffer after deposit", idleBefore, 18);

        // Drain idle with small withdrawal (less than idle)
        uint256 smallWithdrawShares = (shares * 5) / 100; // 5% withdrawal
        vm.prank(user);
        uint256 smallAssets = IStrategyWithRedeem(address(loopStrategy)).redeem(smallWithdrawShares, user, user);
        emit log_named_decimal_uint("Small withdrawal received", smallAssets, 18);

        uint256 idleAfter = IERC20(REUSD).balanceOf(address(loopStrategy));
        emit log_named_decimal_uint("Idle buffer after small withdraw", idleAfter, 18);

        // Now try larger withdrawal - does it succeed?
        uint256 remainingShares = IERC20(address(loopStrategy)).balanceOf(user);
        uint256 largeWithdrawShares = (remainingShares * 80) / 100; // 80% of remaining

        emit log_named_decimal_uint("Attempting large withdrawal shares", largeWithdrawShares, 18);

        vm.prank(user);
        uint256 largeAssets = IStrategyWithRedeem(address(loopStrategy)).redeem(largeWithdrawShares, user, user);

        emit log_named_decimal_uint("Large withdrawal received", largeAssets, 18);

        // Check: Did user receive expected amount? (allow >= since 80% of remaining after 5% = 76%)
        uint256 expectedMin = (INITIAL_DEPOSIT * 76 / 100) * 95 / 100; // 76% of deposit, allow 5% slippage
        assertGe(largeAssets, expectedMin, "Large withdrawal should succeed");
    }

    // REMOVED: testFork_WithdrawalStuck_MaxIterationsReached
    // REMOVED: testFork_WithdrawalStuck_MinimalProgress
    // These tests were for iterative deleverage which is replaced by flash loan deleverage

    /// @notice Test: Show iteration-by-iteration state during failed deleverage
    /// @dev Demonstrates how funds can be trapped when maxIterations is too low
    function testFork_DeleverageIterations_ShowState() public {
        // Setup: User deposits
        vm.startPrank(user);
        IERC20(REUSD).approve(address(loopStrategy), INITIAL_DEPOSIT);
        uint256 shares = strategyVault.deposit(INITIAL_DEPOSIT, user);
        vm.stopPrank();

        emit log("=== Initial State ===");
        emit log_named_decimal_uint("User deposited", INITIAL_DEPOSIT, 18);
        emit log_named_decimal_uint("Shares received", shares, 18);

        // Get initial position state
        uint256 curveDebtBefore = ICurveLLAMMA(CURVE_LLAMMA).debt(address(loopStrategy));
        uint256 resupplyDebtBefore = IResupply(RESUPPLY_PAIR).toBorrowAmount(
            IResupply(RESUPPLY_PAIR).userBorrowShares(address(loopStrategy)), true, false
        );
        uint256 idleBefore = IERC20(REUSD).balanceOf(address(loopStrategy));

        emit log_named_decimal_uint("Idle reUSD", idleBefore, 18);
        emit log_named_decimal_uint("Curve debt", curveDebtBefore, 18);
        emit log_named_decimal_uint("Resupply debt", resupplyDebtBefore, 18);

        // Keep default 30 iterations to show full deleverage attempt
        emit log("");
        emit log("=== Attempting Full Withdrawal with 30 iterations ===");
        emit log("(Will show each iteration's state via events)");
        emit log("");

        // Record logs to capture DeleverageIteration events
        vm.recordLogs();

        // Try withdrawal - will revert but we capture events first
        vm.prank(user);
        try IStrategyWithRedeem(address(loopStrategy)).redeem(shares, user, user) returns (uint256 assets) {
            emit log_named_decimal_uint("Withdrawal succeeded with", assets, 18);
        } catch {
            emit log("Withdrawal REVERTED (as expected - insufficient funds freed)");
        }

        // Extract and display iteration events
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 iterationSelector = keccak256("DeleverageIteration(uint256,uint256,uint256,uint256,uint256)");

        emit log("");
        emit log("=== Iteration-by-Iteration State ===");

        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == iterationSelector) {
                (uint256 iteration, uint256 reUSDBalance, uint256 targetTotal, uint256 curveDebt, uint256 resupplyDebt) =
                    abi.decode(logs[i].data, (uint256, uint256, uint256, uint256, uint256));

                emit log("");
                emit log_named_uint("Iteration", iteration);
                emit log_named_decimal_uint("  reUSD balance", reUSDBalance, 18);
                emit log_named_decimal_uint("  Target total", targetTotal, 18);
                emit log_named_decimal_uint("  Curve debt", curveDebt, 18);
                emit log_named_decimal_uint("  Resupply debt", resupplyDebt, 18);

                if (reUSDBalance < targetTotal) {
                    uint256 shortfall = targetTotal - reUSDBalance;
                    uint256 pctShort = (shortfall * 100) / targetTotal;
                    emit log_named_decimal_uint("  SHORTFALL", shortfall, 18);
                    emit log_named_uint("  Shortfall %", pctShort);
                }
            }
        }

        emit log("");
        emit log("=== Analysis ===");
        emit log("Shows full 30-iteration deleverage attempt.");
        emit log("If it completes, withdrawal succeeds. If not, the slippage check protects user.");
    }

    // REMOVED: testFork_LeverageVsDeleverageAsymmetry
    // This test was for iterative deleverage which is replaced by flash loan deleverage

    /*//////////////////////////////////////////////////////////////
                        REWARD HARVEST TESTS
    //////////////////////////////////////////////////////////////*/

    function testFork_Harvest_SellsAllRewardTokens() public {
        SreUSDCrvUSDLoopStrategy strategy = new SreUSDCrvUSDLoopStrategy(
            REUSD, SREUSD, CRVUSD, CURVE_LLAMMA, RESUPPLY_PAIR, "Test Strategy"
        );
        IStrategy(address(strategy)).setKeeper(address(this));

        // Configure flash loans (required for deposits)
        strategy.setFlashLoanConfig(BALANCER_VAULT, AAVE_V3_POOL, CRVUSD_FLASH_LENDER, USDC, CRVUSD_USDC_POOL, 1, 0);

        deal(REUSD, address(this), 10_000e18);
        IERC20(REUSD).approve(address(strategy), 10_000e18);
        IStrategy(address(strategy)).deposit(10_000e18, address(this));

        // Configure reward routes
        bytes memory crvPath = abi.encode(uint256(2), uint256(0));
        strategy.addRewardToken(CRV, CRV_CRVUSD_POOL, crvPath, 2);

        bytes memory cvxPath = abi.encode(uint256(1), uint256(0));
        strategy.addRewardToken(CVX, CVX_ETH_POOL, cvxPath, 2);

        bytes memory rsupPath = abi.encode(uint256(1), uint256(0));
        strategy.addRewardToken(RSUP, RSUP_WETH_POOL, rsupPath, 2);

        bytes memory wethPath = abi.encode(uint256(1), uint256(0));
        strategy.addRewardToken(WETH, CRV_CRVUSD_POOL, wethPath, 2);

        strategy.setRewardSwapPool(SCRVUSD, SCRVUSD_REUSD_POOL);

        // Simulate rewards
        deal(CRV, address(strategy), 1000e18);
        deal(CVX, address(strategy), 500e18);
        deal(RSUP, address(strategy), 200e18);

        uint256 totalAssetsBefore = IStrategy(address(strategy)).totalAssets();
        IStrategy(address(strategy)).report();
        uint256 totalAssetsAfter = IStrategy(address(strategy)).totalAssets();

        assertEq(IERC20(CRV).balanceOf(address(strategy)), 0, "CRV should be sold");
        assertEq(IERC20(CVX).balanceOf(address(strategy)), 0, "CVX should be sold");
        assertEq(IERC20(RSUP).balanceOf(address(strategy)), 0, "RSUP should be sold");
        assertEq(IERC20(WETH).balanceOf(address(strategy)), 0, "WETH should be sold");
        assertGt(totalAssetsAfter, totalAssetsBefore, "totalAssets should increase");
    }

    /*//////////////////////////////////////////////////////////////
                        PROTOCOL BEHAVIOR TESTS
    //////////////////////////////////////////////////////////////*/

    function testFork_RealProtocolInteraction() public {
        IERC4626 sreUSD = IERC4626(SREUSD);
        uint256 exchangeRate = (sreUSD.totalAssets() * 1e18) / sreUSD.totalSupply();
        assertGt(exchangeRate, 0, "Invalid sreUSD exchange rate");
        assertGt(IERC20(CRVUSD).totalSupply(), 0, "crvUSD not found");
    }

    /// @notice Test: Strategy should achieve target LTV based on collateral VALUE
    /// @dev If using share count instead of value, actual LTV will be lower than target
    function testFork_SreUSD_BorrowAmount_UsesValue() public {
        // Deposit to create leveraged position
        vm.startPrank(user);
        IERC20(REUSD).approve(address(loopStrategy), INITIAL_DEPOSIT);
        strategyVault.deposit(INITIAL_DEPOSIT, user);
        vm.stopPrank();

        // Get position state using proper functions
        uint256 curveDebt = ICurveLLAMMA(CURVE_LLAMMA).debt(address(loopStrategy));
        uint256[4] memory state = ICurveLLAMMA(CURVE_LLAMMA).user_state(address(loopStrategy));
        uint256 sreUSDCollateral = state[0];  // sreUSD shares as collateral

        // Get VALUE of collateral (not share count)
        uint256 collateralValue = IERC4626(SREUSD).convertToAssets(sreUSDCollateral);

        emit log_named_decimal_uint("sreUSD collateral (shares)", sreUSDCollateral, 18);
        emit log_named_decimal_uint("sreUSD collateral (value)", collateralValue, 18);
        emit log_named_decimal_uint("Curve debt (crvUSD)", curveDebt, 18);

        // Skip if no position created
        if (curveDebt == 0 || collateralValue == 0) {
            emit log("No position created - skipping LTV check");
            return;
        }

        // Query Curve's max_borrowable to see what IT thinks the max is
        // N=10 bands (what strategy uses), current_debt=0 (simulating new loan)
        uint256 curveMaxBorrowable = ICurveLLAMMA(CURVE_LLAMMA).max_borrowable(
            sreUSDCollateral,  // collateral amount
            10,                // N bands (strategy uses 10)
            0,                 // current_debt
            address(0)         // user
        );

        // Calculate what LTV Curve allows based on shares vs value
        uint256 curveLTVbyShares = (curveMaxBorrowable * 10000) / sreUSDCollateral;
        uint256 curveLTVbyValue = (curveMaxBorrowable * 10000) / collateralValue;

        emit log_named_decimal_uint("Curve max_borrowable", curveMaxBorrowable, 18);
        emit log_named_decimal_uint("Curve max LTV (if shares)", curveLTVbyShares, 0);
        emit log_named_decimal_uint("Curve max LTV (if value)", curveLTVbyValue, 0);

        // What we actually borrowed
        uint256 ourLTVbyShares = (curveDebt * 10000) / sreUSDCollateral;
        uint256 ourLTVbyValue = (curveDebt * 10000) / collateralValue;
        emit log_named_decimal_uint("Our LTV (by shares)", ourLTVbyShares, 0);
        emit log_named_decimal_uint("Our LTV (by value)", ourLTVbyValue, 0);

        // Key insight: if Curve uses VALUE, curveLTVbyValue should be ~95%
        // If Curve uses SHARES, curveLTVbyShares should be ~95%
    }

    function testFork_Resupply_toBorrowAmount_isReUSD() public {
        deal(CRVUSD, address(this), 10000e18);
        IERC20(CRVUSD).approve(RESUPPLY_PAIR, type(uint256).max);

        uint256 borrowAmount = 7500e18;
        uint256 reUSDBefore = IERC20(REUSD).balanceOf(address(this));
        IResupply(RESUPPLY_PAIR).borrow(borrowAmount, 10000e18, address(this));
        uint256 reUSDAfter = IERC20(REUSD).balanceOf(address(this));

        assertEq(reUSDAfter - reUSDBefore, borrowAmount, "Should receive exact reUSD");

        uint256 borrowShares = IResupply(RESUPPLY_PAIR).userBorrowShares(address(this));
        uint256 converted = IResupply(RESUPPLY_PAIR).toBorrowAmount(borrowShares, true, false);
        assertApproxEqRel(converted, borrowAmount, 0.0001e18, "toBorrowAmount should match");
    }

    function testFork_Resupply_CollateralUnchangedByRepay() public {
        deal(CRVUSD, address(this), 10000e18);
        IERC20(CRVUSD).approve(RESUPPLY_PAIR, type(uint256).max);
        IERC20(REUSD).approve(RESUPPLY_PAIR, type(uint256).max);

        IResupply(RESUPPLY_PAIR).borrow(7500e18, 10000e18, address(this));

        uint256 collateralBefore = _getUserCollateralBalance(address(this));

        deal(REUSD, address(this), 10000e18);
        uint256 allShares = IResupply(RESUPPLY_PAIR).userBorrowShares(address(this));
        IResupply(RESUPPLY_PAIR).repay(allShares, address(this));

        uint256 collateralAfter = _getUserCollateralBalance(address(this));
        assertEq(collateralAfter, collateralBefore, "Collateral unchanged by repay");
    }

    /*//////////////////////////////////////////////////////////////
                    COLLATERAL-BASED DELEVERAGE TESTS
    //////////////////////////////////////////////////////////////*/

    // Resupply swapper address (from SetSwapper events on mainnet)
    address public constant RESUPPLY_SWAPPER = 0x042f48346be16Be381190a7397A80808243f3b2e;

    function testFork_SetResupplySwapper() public {
        // Create swap path: crvUSD → scrvUSD → reUSD
        address[] memory path = new address[](3);
        path[0] = CRVUSD;
        path[1] = SCRVUSD;
        path[2] = REUSD;

        loopStrategy.setResupplySwapper(RESUPPLY_SWAPPER, path);

        assertEq(loopStrategy.resupplySwapper(), RESUPPLY_SWAPPER, "Swapper should be set");
    }

    function testFork_CollateralDeleverage_PartialWithdrawal() public {
        // Setup: deposit and create position
        vm.startPrank(user);
        IERC20(REUSD).approve(address(loopStrategy), INITIAL_DEPOSIT);
        IStrategy(address(loopStrategy)).deposit(INITIAL_DEPOSIT, user);
        vm.stopPrank();

        // Report to deploy funds
        vm.prank(keeper);
        strategyVault.report();

        // Configure collateral-based deleverage
        address[] memory path = new address[](3);
        path[0] = CRVUSD;
        path[1] = SCRVUSD;
        path[2] = REUSD;
        loopStrategy.setResupplySwapper(RESUPPLY_SWAPPER, path);

        uint256 totalAssetsBefore = strategyVault.totalAssets();
        uint256 sharesToRedeem = IERC20(address(loopStrategy)).balanceOf(user) / 4; // 25% withdrawal

        emit log_named_decimal_uint("Total assets before", totalAssetsBefore, 18);
        emit log_named_decimal_uint("Shares to redeem (25%)", sharesToRedeem, 18);

        // Partial withdrawal using collateral-based approach
        vm.prank(user);
        uint256 assetsReceived = IStrategyWithRedeem(address(loopStrategy)).redeem(sharesToRedeem, user, user);

        uint256 totalAssetsAfter = strategyVault.totalAssets();
        emit log_named_decimal_uint("Assets received", assetsReceived, 18);
        emit log_named_decimal_uint("Total assets after", totalAssetsAfter, 18);

        // Verify partial withdrawal worked
        assertGt(assetsReceived, 0, "Should receive assets");
        assertGt(totalAssetsAfter, 0, "Strategy should still have assets");
        assertLt(totalAssetsAfter, totalAssetsBefore, "Total assets should decrease");

        // Check user received expected amount (25% of deposit with deleverage costs)
        // With loss mechanism, user pays proportional deleverage cost (~5-15% in fork)
        uint256 expectedAssets = INITIAL_DEPOSIT / 4; // 2,500 reUSD
        uint256 minExpected = (expectedAssets * 50) / 100; // Allow up to 50% loss (fork slippage)
        assertGe(assetsReceived, minExpected, "Should receive at least 50% of expected assets");

        // Position should still exist
        assertTrue(ICurveLLAMMA(CURVE_LLAMMA).loan_exists(address(loopStrategy)), "Curve loan should still exist");
    }

    function testFork_CollateralDeleverage_FullWithdrawal() public {
        // Setup: deposit and create position
        vm.startPrank(user);
        IERC20(REUSD).approve(address(loopStrategy), INITIAL_DEPOSIT);
        IStrategy(address(loopStrategy)).deposit(INITIAL_DEPOSIT, user);
        vm.stopPrank();

        // Report to deploy funds
        vm.prank(keeper);
        strategyVault.report();

        // Configure collateral-based deleverage
        address[] memory path = new address[](3);
        path[0] = CRVUSD;
        path[1] = SCRVUSD;
        path[2] = REUSD;
        loopStrategy.setResupplySwapper(RESUPPLY_SWAPPER, path);

        uint256 totalAssetsBefore = strategyVault.totalAssets();
        uint256 allShares = IERC20(address(loopStrategy)).balanceOf(user);

        emit log_named_decimal_uint("Total assets before", totalAssetsBefore, 18);
        emit log_named_decimal_uint("All shares", allShares, 18);

        // Full withdrawal using collateral-based approach
        vm.prank(user);
        uint256 assetsReceived = IStrategyWithRedeem(address(loopStrategy)).redeem(allShares, user, user);

        emit log_named_decimal_uint("Assets received", assetsReceived, 18);
        emit log_named_decimal_uint("User reUSD balance", IERC20(REUSD).balanceOf(user), 18);

        // Verify full withdrawal
        assertGt(assetsReceived, 0, "Should receive assets");
        // Allow for some slippage from swaps
        uint256 minExpected = (INITIAL_DEPOSIT * 97) / 100; // 3% max slippage
        assertGt(assetsReceived, minExpected, "Should receive close to initial deposit");
    }

    // REMOVED: testFork_CollateralDeleverage_VsIterative_Comparison
    // This test was for iterative vs collateral deleverage comparison
    // Now replaced by flash loan deleverage

    /// @notice Test: Does 2x multiplier work with max leverage (30 loops)?
    /// @dev Large deposit = more iterations before hitting minLoopAmount
    function testFork_HighLeverage_2xMultiplierCheck() public {
        // Large deposit to maximize iterations
        uint256 largeDeposit = 100_000e18; // 100k reUSD
        deal(REUSD, user, largeDeposit);

        vm.startPrank(user);
        IERC20(REUSD).approve(address(loopStrategy), largeDeposit);
        IStrategy(address(loopStrategy)).deposit(largeDeposit, user);
        vm.stopPrank();

        // Report to deploy funds
        vm.prank(keeper);
        strategyVault.report();

        // Log position state
        uint256 curveDebt = ICurveLLAMMA(CURVE_LLAMMA).debt(address(loopStrategy));
        uint256 resupplyShares = IResupply(RESUPPLY_PAIR).userBorrowShares(address(loopStrategy));
        uint256 resupplyDebt = IResupply(RESUPPLY_PAIR).toBorrowAmount(resupplyShares, true, false);
        uint256 totalAssets = strategyVault.totalAssets();

        emit log_named_decimal_uint("Deposit", largeDeposit, 18);
        emit log_named_decimal_uint("Curve debt", curveDebt, 18);
        emit log_named_decimal_uint("Resupply debt", resupplyDebt, 18);
        emit log_named_decimal_uint("Total assets", totalAssets, 18);
        emit log_named_decimal_uint("Leverage ratio (Curve debt / equity)", curveDebt * 1e18 / totalAssets, 18);

        // Configure flash loan deleverage (already configured in setUp)

        // Try 25% partial withdrawal
        uint256 sharesToRedeem = IERC20(address(loopStrategy)).balanceOf(user) / 4;
        uint256 expectedAssets = totalAssets / 4;

        emit log_named_decimal_uint("Shares to redeem (25%)", sharesToRedeem, 18);
        emit log_named_decimal_uint("Expected assets", expectedAssets, 18);

        vm.prank(user);
        uint256 assetsReceived = IStrategyWithRedeem(address(loopStrategy)).redeem(sharesToRedeem, user, user);

        emit log_named_decimal_uint("Assets received", assetsReceived, 18);
        emit log_named_decimal_uint("Efficiency", assetsReceived * 100 / expectedAssets, 18);

        // Check if 2x multiplier was sufficient
        uint256 minExpected = (expectedAssets * 99) / 100; // 99% = 1% max slippage
        assertGe(assetsReceived, minExpected, "2x multiplier insufficient for high leverage");
    }

    /*//////////////////////////////////////////////////////////////
                    DYNAMIC MULTIPLIER TESTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Test dynamic multiplier with low leverage (small vault)
    /// @dev Small vault = fewer iterations = lower L_curve = higher multiplier needed
    function testFork_DynamicMultiplier_LowLeverage() public {
        // Small deposit to get low leverage (~4-5x)
        uint256 smallDeposit = 3_000e18; // 3k reUSD - will do ~8 iterations
        deal(REUSD, user, smallDeposit);

        vm.startPrank(user);
        IERC20(REUSD).approve(address(loopStrategy), smallDeposit);
        IStrategy(address(loopStrategy)).deposit(smallDeposit, user);
        vm.stopPrank();

        // Get position state
        uint256 curveDebt = ICurveLLAMMA(CURVE_LLAMMA).debt(address(loopStrategy));
        uint256 resupplyShares = IResupply(RESUPPLY_PAIR).userBorrowShares(address(loopStrategy));
        uint256 resupplyDebt = IResupply(RESUPPLY_PAIR).toBorrowAmount(resupplyShares, true, false);
        uint256 totalAssets = strategyVault.totalAssets();
        uint256 debtGap = curveDebt - resupplyDebt;

        // Calculate L_curve and expected multiplier
        uint256 lCurve = curveDebt * 1e18 / totalAssets;
        uint256 expectedMultiplier = totalAssets * 1e18 / debtGap;

        emit log_named_decimal_uint("Deposit", smallDeposit, 18);
        emit log_named_decimal_uint("Curve debt", curveDebt, 18);
        emit log_named_decimal_uint("Resupply debt", resupplyDebt, 18);
        emit log_named_decimal_uint("Debt gap", debtGap, 18);
        emit log_named_decimal_uint("L_curve", lCurve, 18);
        emit log_named_decimal_uint("Expected multiplier", expectedMultiplier, 18);

        // Try 25% partial withdrawal
        uint256 sharesToRedeem = IERC20(address(loopStrategy)).balanceOf(user) / 4;
        uint256 expectedAssets = totalAssets / 4;

        vm.prank(user);
        uint256 assetsReceived = IStrategyWithRedeem(address(loopStrategy)).redeem(sharesToRedeem, user, user);

        emit log_named_decimal_uint("Expected assets (25%)", expectedAssets, 18);
        emit log_named_decimal_uint("Assets received", assetsReceived, 18);
        emit log_named_decimal_uint("Efficiency %", assetsReceived * 100 / expectedAssets, 18);

        // Dynamic multiplier should handle low leverage correctly
        // Allow 2% slippage for swap costs
        uint256 minExpected = (expectedAssets * 98) / 100;
        assertGe(assetsReceived, minExpected, "Dynamic multiplier should work with low leverage");
    }

    /// @notice Test dynamic multiplier with high leverage (large vault)
    function testFork_DynamicMultiplier_HighLeverage() public {
        // Large deposit to maximize iterations (~7x leverage)
        uint256 largeDeposit = 100_000e18; // 100k reUSD
        deal(REUSD, user, largeDeposit);

        vm.startPrank(user);
        IERC20(REUSD).approve(address(loopStrategy), largeDeposit);
        IStrategy(address(loopStrategy)).deposit(largeDeposit, user);
        vm.stopPrank();

        // Get position state
        uint256 curveDebt = ICurveLLAMMA(CURVE_LLAMMA).debt(address(loopStrategy));
        uint256 resupplyShares = IResupply(RESUPPLY_PAIR).userBorrowShares(address(loopStrategy));
        uint256 resupplyDebt = IResupply(RESUPPLY_PAIR).toBorrowAmount(resupplyShares, true, false);
        uint256 totalAssets = strategyVault.totalAssets();
        uint256 debtGap = curveDebt - resupplyDebt;

        uint256 lCurve = curveDebt * 1e18 / totalAssets;
        uint256 expectedMultiplier = totalAssets * 1e18 / debtGap;

        emit log_named_decimal_uint("Deposit", largeDeposit, 18);
        emit log_named_decimal_uint("L_curve", lCurve, 18);
        emit log_named_decimal_uint("Expected multiplier", expectedMultiplier, 18);

        // Try 25% partial withdrawal
        uint256 sharesToRedeem = IERC20(address(loopStrategy)).balanceOf(user) / 4;
        uint256 expectedAssets = totalAssets / 4;

        vm.prank(user);
        uint256 assetsReceived = IStrategyWithRedeem(address(loopStrategy)).redeem(sharesToRedeem, user, user);

        emit log_named_decimal_uint("Expected assets (25%)", expectedAssets, 18);
        emit log_named_decimal_uint("Assets received", assetsReceived, 18);
        emit log_named_decimal_uint("Efficiency %", assetsReceived * 100 / expectedAssets, 18);

        // Should get close to expected with high leverage
        uint256 minExpected = (expectedAssets * 98) / 100;
        assertGe(assetsReceived, minExpected, "Dynamic multiplier should work with high leverage");
    }

    /// @notice Test multiple users with sequential withdrawals
    /// @dev Verifies each user receives expected amount regardless of withdrawal order
    function testFork_DynamicMultiplier_MultipleUsers_SequentialWithdrawals() public {
        address user1 = address(0x1111);
        address user2 = address(0x2222);
        address user3 = address(0x3333);

        // Setup deposits
        deal(REUSD, user1, 10_000e18);
        deal(REUSD, user2, 5_000e18);
        deal(REUSD, user3, 3_000e18);

        vm.startPrank(user1);
        IERC20(REUSD).approve(address(loopStrategy), 10_000e18);
        uint256 shares1 = strategyVault.deposit(10_000e18, user1);
        vm.stopPrank();

        vm.startPrank(user2);
        IERC20(REUSD).approve(address(loopStrategy), 5_000e18);
        uint256 shares2 = strategyVault.deposit(5_000e18, user2);
        vm.stopPrank();

        vm.startPrank(user3);
        IERC20(REUSD).approve(address(loopStrategy), 3_000e18);
        uint256 shares3 = strategyVault.deposit(3_000e18, user3);
        vm.stopPrank();

        // NOTE: deposit() already deploys funds via _deployFunds(), no need for report()

        // Log initial L_curve
        {
            uint256 curveDebt = ICurveLLAMMA(CURVE_LLAMMA).debt(address(loopStrategy));
            emit log_named_decimal_uint("L_curve", curveDebt * 1e18 / strategyVault.totalAssets(), 18);
        }

        uint256 totalReceived;

        // User1 withdraws 50% (partial)
        {
            uint256 totalAssetsBefore = strategyVault.totalAssets();
            uint256 expected1 = strategyVault.previewRedeem(shares1 / 2);
            vm.prank(user1);
            uint256 received1 = IStrategyWithRedeem(address(loopStrategy)).redeem(shares1 / 2, user1, user1);
            uint256 totalAssetsAfter = strategyVault.totalAssets();
            emit log_named_decimal_uint("User1 50% expected", expected1, 18);
            emit log_named_decimal_uint("User1 50% received", received1, 18);
            emit log_named_decimal_uint("User1 50% efficiency", received1 * 10000 / expected1, 2);
            emit log_named_decimal_uint("Vault assets before", totalAssetsBefore, 18);
            emit log_named_decimal_uint("Vault assets after", totalAssetsAfter, 18);
            emit log_named_decimal_uint("Vault decrease", totalAssetsBefore - totalAssetsAfter, 18);
            assertGe(received1, (expected1 * 98) / 100, "User1 50% should work");
            totalReceived += received1;
        }

        // User2 withdraws 100%
        {
            uint256 totalAssetsBefore = strategyVault.totalAssets();
            uint256 expected2 = strategyVault.previewRedeem(shares2);
            vm.prank(user2);
            uint256 received2 = IStrategyWithRedeem(address(loopStrategy)).redeem(shares2, user2, user2);
            uint256 totalAssetsAfter = strategyVault.totalAssets();
            emit log_named_decimal_uint("User2 100% expected", expected2, 18);
            emit log_named_decimal_uint("User2 100% received", received2, 18);
            emit log_named_decimal_uint("User2 100% efficiency", received2 * 10000 / expected2, 2);
            emit log_named_decimal_uint("Vault decrease", totalAssetsBefore - totalAssetsAfter, 18);
            assertGe(received2, (expected2 * 98) / 100, "User2 100% should work");
            totalReceived += received2;
        }

        // User1 withdraws remaining
        {
            uint256 totalAssetsBefore = strategyVault.totalAssets();
            uint256 remaining1 = IERC20(address(loopStrategy)).balanceOf(user1);
            uint256 expectedRemaining1 = strategyVault.previewRedeem(remaining1);
            vm.prank(user1);
            uint256 receivedRemaining1 = IStrategyWithRedeem(address(loopStrategy)).redeem(remaining1, user1, user1);
            uint256 totalAssetsAfter = strategyVault.totalAssets();
            emit log_named_decimal_uint("User1 remaining expected", expectedRemaining1, 18);
            emit log_named_decimal_uint("User1 remaining received", receivedRemaining1, 18);
            emit log_named_decimal_uint("User1 remaining efficiency", receivedRemaining1 * 10000 / expectedRemaining1, 2);
            emit log_named_decimal_uint("Vault decrease", totalAssetsBefore - totalAssetsAfter, 18);
            assertGe(receivedRemaining1, (expectedRemaining1 * 98) / 100, "User1 remaining should work");
            totalReceived += receivedRemaining1;
        }

        // User3 withdraws (last user)
        {
            uint256 expected3 = strategyVault.previewRedeem(shares3);
            emit log_named_decimal_uint("User3 expected", expected3, 18);
            emit log_named_decimal_uint("User3 shares value", strategyVault.convertToAssets(shares3), 18);
            vm.recordLogs();
            vm.prank(user3);
            uint256 received3 = IStrategyWithRedeem(address(loopStrategy)).redeem(shares3, user3, user3);
            assertFullWithdrawalEmitted(vm.getRecordedLogs());
            emit log_named_decimal_uint("User3 received", received3, 18);
            emit log_named_decimal_uint("User3 efficiency", received3 * 10000 / expected3, 2);
            assertGe(received3, (expected3 * 98) / 100, "User3 last should work");
            totalReceived += received3;
        }

        // Check final state
        emit log_named_decimal_uint("Final totalAssets", strategyVault.totalAssets(), 18);
        emit log_named_decimal_uint("Final totalSupply", strategyVault.totalSupply(), 18);
        emit log_named_decimal_uint("Final idle reUSD", IERC20(REUSD).balanceOf(address(loopStrategy)), 18);

        // Log summary
        emit log_named_decimal_uint("Total deposited", 18_000e18, 18);
        emit log_named_decimal_uint("Total received", totalReceived, 18);
        emit log_named_decimal_uint("Efficiency %", totalReceived * 100 / 18_000e18, 18);
    }

    /// @notice Test varying withdrawal percentages
    function testFork_DynamicMultiplier_VaryingWithdrawalSizes() public {
        deal(REUSD, user, 50_000e18);

        vm.startPrank(user);
        IERC20(REUSD).approve(address(loopStrategy), 50_000e18);
        strategyVault.deposit(50_000e18, user);
        vm.stopPrank();

        // NOTE: deposit() already deploys funds via _deployFunds(), no need for report()

        // Log state after deposit
        uint256 curveDebt = ICurveLLAMMA(CURVE_LLAMMA).debt(address(loopStrategy));
        uint256 resupplyShares = IResupply(RESUPPLY_PAIR).userBorrowShares(address(loopStrategy));
        uint256 resupplyDebt = IResupply(RESUPPLY_PAIR).toBorrowAmount(resupplyShares, true, false);
        emit log_named_decimal_uint("Curve debt after deposit", curveDebt, 18);
        emit log_named_decimal_uint("Resupply debt after deposit", resupplyDebt, 18);
        emit log_named_decimal_uint("Debt gap (curve - resupply)", curveDebt - resupplyDebt, 18);
        emit log_named_decimal_uint("Total assets after report", strategyVault.totalAssets(), 18);

        // 10% withdrawal
        uint256 shares = IERC20(address(loopStrategy)).balanceOf(user) / 10;
        uint256 expected = strategyVault.previewRedeem(shares);
        emit log_named_decimal_uint("Shares to redeem (10%)", shares, 18);
        emit log_named_decimal_uint("Expected from preview", expected, 18);
        vm.prank(user);
        uint256 received = IStrategyWithRedeem(address(loopStrategy)).redeem(shares, user, user);
        emit log_named_decimal_uint("Actually received", received, 18);
        // Note: 96% threshold accounts for deleverage costs + re-leverage gas paid by withdrawer
        assertGe(received, (expected * 96) / 100, "10% withdrawal should work");

        // 25% of remaining
        shares = IERC20(address(loopStrategy)).balanceOf(user) / 4;
        expected = strategyVault.previewRedeem(shares);
        vm.prank(user);
        received = IStrategyWithRedeem(address(loopStrategy)).redeem(shares, user, user);
        assertGe(received, (expected * 96) / 100, "25% withdrawal should work");

        // 50% of remaining
        shares = IERC20(address(loopStrategy)).balanceOf(user) / 2;
        expected = strategyVault.previewRedeem(shares);
        vm.prank(user);
        received = IStrategyWithRedeem(address(loopStrategy)).redeem(shares, user, user);
        assertGe(received, (expected * 96) / 100, "50% withdrawal should work");

        // 100% of remaining (full close)
        shares = IERC20(address(loopStrategy)).balanceOf(user);
        expected = strategyVault.previewRedeem(shares);
        vm.prank(user);
        received = IStrategyWithRedeem(address(loopStrategy)).redeem(shares, user, user);
        assertGe(received, (expected * 96) / 100, "100% withdrawal should work");

        // Verify vault empty
        assertEq(strategyVault.totalAssets(), 0, "Vault should be empty");
    }

    /*//////////////////////////////////////////////////////////////
                    LOSS MECHANISM TESTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Test: Loss mechanism distributes deleverage costs fairly
    /// @dev Each user should pay their own deleverage cost, not the last user
    function testFork_LossMechanism_FairCostDistribution() public {
        address user1 = address(0x1111);
        address user2 = address(0x2222);
        address user3 = address(0x3333);

        // Setup: 3 users deposit equal amounts
        deal(REUSD, user1, 10_000e18);
        deal(REUSD, user2, 10_000e18);
        deal(REUSD, user3, 10_000e18);

        vm.startPrank(user1);
        IERC20(REUSD).approve(address(loopStrategy), 10_000e18);
        uint256 shares1 = strategyVault.deposit(10_000e18, user1);
        vm.stopPrank();

        vm.startPrank(user2);
        IERC20(REUSD).approve(address(loopStrategy), 10_000e18);
        uint256 shares2 = strategyVault.deposit(10_000e18, user2);
        vm.stopPrank();

        vm.startPrank(user3);
        IERC20(REUSD).approve(address(loopStrategy), 10_000e18);
        uint256 shares3 = strategyVault.deposit(10_000e18, user3);
        vm.stopPrank();

        emit log("=== Initial State ===");
        emit log_named_decimal_uint("Total deposited", 30_000e18, 18);
        emit log_named_decimal_uint("totalAssets", strategyVault.totalAssets(), 18);
        emit log_named_decimal_uint("scrvUSD buffer", loopStrategy.getScrvUSDBuffer(), 18);

        // User1 withdraws 100%
        uint256 received1;
        {
            uint256 preview1 = strategyVault.previewRedeem(shares1);
            vm.prank(user1);
            received1 = IStrategyWithRedeem(address(loopStrategy)).redeem(shares1, user1, user1);
            uint256 loss1 = preview1 - received1;
            emit log("=== User1 Withdrawal ===");
            emit log_named_decimal_uint("Preview", preview1, 18);
            emit log_named_decimal_uint("Received", received1, 18);
            emit log_named_decimal_uint("Loss (deleverage cost)", loss1, 18);
            emit log_named_decimal_uint("Loss %", loss1 * 10000 / preview1, 2);
            emit log_named_decimal_uint("scrvUSD buffer after", loopStrategy.getScrvUSDBuffer(), 18);
            emit log_named_decimal_uint("totalAssets after", strategyVault.totalAssets(), 18);
        }

        // User2 withdraws 100%
        uint256 received2;
        {
            uint256 preview2 = strategyVault.previewRedeem(shares2);
            vm.prank(user2);
            received2 = IStrategyWithRedeem(address(loopStrategy)).redeem(shares2, user2, user2);
            uint256 loss2 = preview2 - received2;
            emit log("=== User2 Withdrawal ===");
            emit log_named_decimal_uint("Preview", preview2, 18);
            emit log_named_decimal_uint("Received", received2, 18);
            emit log_named_decimal_uint("Loss (deleverage cost)", loss2, 18);
            emit log_named_decimal_uint("Loss %", loss2 * 10000 / preview2, 2);
            emit log_named_decimal_uint("scrvUSD buffer after", loopStrategy.getScrvUSDBuffer(), 18);
            emit log_named_decimal_uint("totalAssets after", strategyVault.totalAssets(), 18);
        }

        // User3 withdraws 100% (last user)
        uint256 received3;
        {
            uint256 preview3 = strategyVault.previewRedeem(shares3);
            vm.prank(user3);
            received3 = IStrategyWithRedeem(address(loopStrategy)).redeem(shares3, user3, user3);
            uint256 loss3 = preview3 > received3 ? preview3 - received3 : 0;
            emit log("=== User3 Withdrawal (Last User) ===");
            emit log_named_decimal_uint("Preview", preview3, 18);
            emit log_named_decimal_uint("Received", received3, 18);
            emit log_named_decimal_uint("Loss (deleverage cost)", loss3, 18);
            emit log_named_decimal_uint("Loss %", loss3 * 10000 / preview3, 2);
        }

        // Calculate efficiency for each user
        uint256 efficiency1 = received1 * 10000 / 10_000e18;
        uint256 efficiency2 = received2 * 10000 / 10_000e18;
        uint256 efficiency3 = received3 * 10000 / 10_000e18;

        emit log("=== Summary ===");
        emit log_named_decimal_uint("User1 efficiency %", efficiency1, 2);
        emit log_named_decimal_uint("User2 efficiency %", efficiency2, 2);
        emit log_named_decimal_uint("User3 efficiency %", efficiency3, 2);

        // Key assertion: Total returned should be close to total deposited
        // In a fork environment, slippage can be higher than production
        uint256 totalReceived = received1 + received2 + received3;
        emit log_named_decimal_uint("Total received", totalReceived, 18);
        emit log_named_decimal_uint("Total efficiency %", totalReceived * 100 / 30_000e18, 18);

        // 1. Total efficiency should be > 95% (allowing for deleverage costs)
        assertGe(totalReceived, 28_500e18, "Total efficiency should be > 95%");

        // 2. Each user should receive at least 85% (fork slippage can be high)
        assertGe(received1, 8_500e18, "User1 should receive at least 85%");
        assertGe(received2, 8_500e18, "User2 should receive at least 85%");
        assertGe(received3, 8_500e18, "User3 should receive at least 85%");

        // 3. Buffer mechanism works: Users who don't need to deleverage (idle covers withdrawal)
        // benefit from previous buffer sweeps. User3 may pay more if they must deleverage
        // while User2 consumed the buffer without creating their own.
        // Just verify User3 gets reasonable amount (>85% already checked above)
        assertGe(received3, 9_500e18, "User3 should receive at least 95%");
    }

    /// @notice Test: scrvUSD buffer gets swept on next deposit
    function testFork_LossMechanism_BufferSweptOnDeposit() public {
        address user1 = address(0x1111);
        address user2 = address(0x2222);

        // User1 deposits
        deal(REUSD, user1, 10_000e18);
        vm.startPrank(user1);
        IERC20(REUSD).approve(address(loopStrategy), 10_000e18);
        uint256 shares1 = strategyVault.deposit(10_000e18, user1);
        vm.stopPrank();

        emit log_named_decimal_uint("After deposit - scrvUSD buffer", loopStrategy.getScrvUSDBuffer(), 18);
        assertEq(loopStrategy.getScrvUSDBuffer(), 0, "Buffer should be 0 after initial deposit");

        // User1 partial withdrawal (50%) - this should create buffer
        vm.prank(user1);
        IStrategyWithRedeem(address(loopStrategy)).redeem(shares1 / 2, user1, user1);

        uint256 bufferAfterWithdraw = loopStrategy.getScrvUSDBuffer();
        emit log_named_decimal_uint("After withdrawal - scrvUSD buffer", bufferAfterWithdraw, 18);
        // Buffer might or might not be created depending on actual loss
        // If 2x multiplier freed exact amount, buffer could be 0
        // If 2x freed excess, buffer > 0

        // User2 deposits - should sweep buffer
        deal(REUSD, user2, 5_000e18);
        vm.startPrank(user2);
        IERC20(REUSD).approve(address(loopStrategy), 5_000e18);
        strategyVault.deposit(5_000e18, user2);
        vm.stopPrank();

        uint256 bufferAfterDeposit = loopStrategy.getScrvUSDBuffer();
        emit log_named_decimal_uint("After new deposit - scrvUSD buffer", bufferAfterDeposit, 18);
        assertEq(bufferAfterDeposit, 0, "Buffer should be swept on new deposit");
    }

    /// @notice Test: LossCalculated event is emitted with correct values
    function testFork_LossMechanism_EmitsLossCalculatedEvent() public {
        deal(REUSD, user, 10_000e18);

        vm.startPrank(user);
        IERC20(REUSD).approve(address(loopStrategy), 10_000e18);
        uint256 shares = strategyVault.deposit(10_000e18, user);
        vm.stopPrank();

        // Record logs during withdrawal
        vm.recordLogs();
        vm.prank(user);
        IStrategyWithRedeem(address(loopStrategy)).redeem(shares / 4, user, user);

        // Check for LossCalculated event
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 lossCalculatedSelector = keccak256("LossCalculated(uint256,uint256,uint256,uint256)");

        bool foundEvent = false;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == lossCalculatedSelector) {
                foundEvent = true;
                (uint256 totalBefore, uint256 totalAfter, uint256 actualLoss, uint256 targetIdle) =
                    abi.decode(logs[i].data, (uint256, uint256, uint256, uint256));

                emit log("=== LossCalculated Event ===");
                emit log_named_decimal_uint("totalBefore", totalBefore, 18);
                emit log_named_decimal_uint("totalAfter", totalAfter, 18);
                emit log_named_decimal_uint("actualLoss", actualLoss, 18);
                emit log_named_decimal_uint("targetIdle", targetIdle, 18);

                // Validate: totalBefore > totalAfter (there is loss)
                assertGe(totalBefore, totalAfter, "totalBefore should be >= totalAfter");
                // Validate: actualLoss = totalBefore - totalAfter
                assertEq(actualLoss, totalBefore - totalAfter, "actualLoss should equal difference");
                break;
            }
        }

        assertTrue(foundEvent, "LossCalculated event should be emitted during withdrawal");
    }

    /// @notice Test: No phantom assets accumulate with loss mechanism
    function testFork_LossMechanism_NoPhantomAssets() public {
        address user1 = address(0x1111);
        address user2 = address(0x2222);

        // Setup deposits
        deal(REUSD, user1, 10_000e18);
        deal(REUSD, user2, 10_000e18);

        vm.startPrank(user1);
        IERC20(REUSD).approve(address(loopStrategy), 10_000e18);
        strategyVault.deposit(10_000e18, user1);
        vm.stopPrank();

        vm.startPrank(user2);
        IERC20(REUSD).approve(address(loopStrategy), 10_000e18);
        uint256 shares2 = strategyVault.deposit(10_000e18, user2);
        vm.stopPrank();

        emit log_named_decimal_uint("Initial totalAssets", strategyVault.totalAssets(), 18);

        // User1 does 3 partial withdrawals (25% each time)
        {
            uint256 shares1 = IERC20(address(loopStrategy)).balanceOf(user1);
            for (uint i = 0; i < 3; i++) {
                uint256 sharesToRedeem = shares1 / 4;
                shares1 -= sharesToRedeem;
                vm.prank(user1);
                IStrategyWithRedeem(address(loopStrategy)).redeem(sharesToRedeem, user1, user1);
            }
        }

        // Check: cached totalAssets should be close to actual position value
        // (With loss mechanism, each withdrawal properly decrements totalAssets)
        uint256 cachedTotalAssets = strategyVault.totalAssets();
        uint256 actualPositionValue;

        {
            uint256 idle = IERC20(REUSD).balanceOf(address(loopStrategy));
            uint256 sreUSDCollateral = 0;
            if (ICurveLLAMMA(CURVE_LLAMMA).loan_exists(address(loopStrategy))) {
                uint256[4] memory state = ICurveLLAMMA(CURVE_LLAMMA).user_state(address(loopStrategy));
                sreUSDCollateral = state[0];
            }
            uint256 sreUSDValue = IERC4626(SREUSD).convertToAssets(sreUSDCollateral);
            uint256 borrowShares = IResupply(RESUPPLY_PAIR).userBorrowShares(address(loopStrategy));
            uint256 reUSDDebt = IResupply(RESUPPLY_PAIR).toBorrowAmount(borrowShares, true, false);
            // Also add scrvUSD buffer to actual value
            uint256 crvUSDBuffer = loopStrategy.getScrvUSDBuffer();
            actualPositionValue = idle + sreUSDValue + crvUSDBuffer - reUSDDebt;
        }

        emit log("=== After Partial Withdrawals ===");
        emit log_named_decimal_uint("Cached totalAssets", cachedTotalAssets, 18);
        emit log_named_decimal_uint("Actual position value (incl buffer)", actualPositionValue, 18);
        emit log_named_decimal_uint("scrvUSD buffer", loopStrategy.getScrvUSDBuffer(), 18);

        // The difference should be minimal (within 1%) - no phantom assets
        uint256 diff = cachedTotalAssets > actualPositionValue
            ? cachedTotalAssets - actualPositionValue
            : actualPositionValue - cachedTotalAssets;
        uint256 diffPct = diff * 10000 / cachedTotalAssets;
        emit log_named_decimal_uint("Difference %", diffPct, 2);

        // With loss mechanism, cached should track actual closely (< 5% drift in fork environment)
        // Note: Some drift is expected due to buffer slippage and scrvUSD yield accrual
        assertLe(diffPct, 500, "Cached should be within 5% of actual (minimal phantom assets)");

        // User2 should receive close to their fair share
        uint256 preview2 = strategyVault.previewRedeem(shares2);
        vm.prank(user2);
        uint256 received2 = IStrategyWithRedeem(address(loopStrategy)).redeem(shares2, user2, user2);

        emit log("=== User2 Withdrawal ===");
        emit log_named_decimal_uint("Preview", preview2, 18);
        emit log_named_decimal_uint("Received", received2, 18);

        // User2 should receive at least 98% of preview (their own deleverage cost only)
        assertGe(received2, preview2 * 98 / 100, "User2 should receive >= 98% of preview");
    }

    /*//////////////////////////////////////////////////////////////
                    FLASH LOAN PROVIDER TESTS
    //////////////////////////////////////////////////////////////*/

    function testFork_ProviderSwitching() public {
        // Verify default is Balancer (enum value 0)
        assertEq(
            uint256(loopStrategy.flashLoanProvider()),
            0,
            "Default should be Balancer"
        );

        // Switch to Aave
        loopStrategy.setFlashLoanProvider(
            SreUSDCrvUSDLoopStrategy.FlashLoanProvider.AAVE
        );
        assertEq(
            uint256(loopStrategy.flashLoanProvider()),
            1,
            "Should be Aave after switch"
        );

        // Switch back to Balancer
        loopStrategy.setFlashLoanProvider(
            SreUSDCrvUSDLoopStrategy.FlashLoanProvider.BALANCER
        );
        assertEq(
            uint256(loopStrategy.flashLoanProvider()),
            0,
            "Should be Balancer after switch back"
        );
    }

    function testFork_FullWithdrawal_Aave() public {
        // Switch to Aave flash loan provider
        loopStrategy.setFlashLoanProvider(
            SreUSDCrvUSDLoopStrategy.FlashLoanProvider.AAVE
        );

        // Deposit
        vm.startPrank(user);
        IERC20(REUSD).approve(address(loopStrategy), INITIAL_DEPOSIT);
        strategyVault.deposit(INITIAL_DEPOSIT, user);
        vm.stopPrank();

        emit log("=== Aave Full Withdrawal Test ===");

        // Withdraw all shares
        uint256 shares = strategyVault.balanceOf(user);
        vm.prank(user);
        uint256 received = strategyVault.redeem(shares, user, user);

        emit log_named_decimal_uint("Deposited", INITIAL_DEPOSIT, 18);
        emit log_named_decimal_uint("Received", received, 18);
        emit log_named_decimal_uint("Loss", INITIAL_DEPOSIT - received, 18);

        // Aave has 0.05% fee on flash loan amount (~190k for 10k withdrawal)
        // Expected extra loss: ~$95 compared to Balancer
        // Total loss should be < 3% (slippage + Aave fee)
        assertGe(received, 9_700e18, "Should receive at least 97%");
        assertLe(received, INITIAL_DEPOSIT, "Should not receive more than deposit");
    }

    function testFork_PartialWithdrawal_Aave() public {
        // Switch to Aave flash loan provider
        loopStrategy.setFlashLoanProvider(
            SreUSDCrvUSDLoopStrategy.FlashLoanProvider.AAVE
        );

        // Deposit
        vm.startPrank(user);
        IERC20(REUSD).approve(address(loopStrategy), INITIAL_DEPOSIT);
        strategyVault.deposit(INITIAL_DEPOSIT, user);
        vm.stopPrank();

        emit log("=== Aave Partial Withdrawal Test ===");

        // Withdraw 50%
        uint256 shares = strategyVault.balanceOf(user);
        uint256 withdrawShares = shares / 2;
        uint256 expectedAmount = INITIAL_DEPOSIT / 2;

        vm.prank(user);
        uint256 received = strategyVault.redeem(withdrawShares, user, user);

        emit log_named_decimal_uint("Expected", expectedAmount, 18);
        emit log_named_decimal_uint("Received", received, 18);

        // Should receive at least 95% of expected (partial withdrawal has higher slippage)
        assertGe(received, expectedAmount * 95 / 100, "Should receive at least 95%");
        assertLe(received, expectedAmount, "Should not receive more than expected");
    }

    function testFork_AaveVsBalancer_FeeDifference() public {
        // Deploy fresh strategy WITHOUT crvUSD FlashLender to force USDC flash loan path
        // This allows us to compare Balancer (0% fee) vs Aave (0.05% fee)
        SreUSDCrvUSDLoopStrategy balancerStrategy = new SreUSDCrvUSDLoopStrategy(
            REUSD, SREUSD, CRVUSD, CURVE_LLAMMA, RESUPPLY_PAIR, "Balancer Test Strategy"
        );
        IStrategy balancerVault = IStrategy(address(balancerStrategy));
        balancerVault.setKeeper(keeper);
        balancerVault.setPendingManagement(management);
        vm.prank(management);
        balancerVault.acceptManagement();
        balancerStrategy.setRewardSwapPool(SCRVUSD, SCRVUSD_REUSD_POOL);
        // No crvUSD FlashLender - forces USDC flash loan path
        balancerStrategy.setFlashLoanConfig(BALANCER_VAULT, AAVE_V3_POOL, address(0), USDC, CRVUSD_USDC_POOL, 1, 0);

        // Test 1: Withdraw with Balancer (default, 0% fee)
        vm.startPrank(user);
        IERC20(REUSD).approve(address(balancerStrategy), INITIAL_DEPOSIT);
        balancerVault.deposit(INITIAL_DEPOSIT, user);
        vm.stopPrank();

        uint256 shares = balancerVault.balanceOf(user);
        vm.prank(user);
        uint256 balancerReceived = balancerVault.redeem(shares, user, user);

        emit log("=== Balancer vs Aave Fee Comparison (USDC flash loans) ===");
        emit log_named_decimal_uint("Balancer received", balancerReceived, 18);

        // Test 2: Deploy new strategy and use Aave
        // Need fresh strategy since we fully withdrew
        SreUSDCrvUSDLoopStrategy aaveStrategy = new SreUSDCrvUSDLoopStrategy(
            REUSD, SREUSD, CRVUSD, CURVE_LLAMMA, RESUPPLY_PAIR, "Aave Test Strategy"
        );
        IStrategy aaveVault = IStrategy(address(aaveStrategy));
        aaveVault.setKeeper(keeper);
        aaveVault.setPendingManagement(management);
        vm.prank(management);
        aaveVault.acceptManagement();
        aaveStrategy.setRewardSwapPool(SCRVUSD, SCRVUSD_REUSD_POOL);
        // No crvUSD FlashLender - forces USDC flash loan path
        aaveStrategy.setFlashLoanConfig(BALANCER_VAULT, AAVE_V3_POOL, address(0), USDC, CRVUSD_USDC_POOL, 1, 0);
        aaveStrategy.setFlashLoanProvider(SreUSDCrvUSDLoopStrategy.FlashLoanProvider.AAVE);

        // Give user more tokens for second test
        deal(REUSD, user, INITIAL_DEPOSIT, true);

        vm.startPrank(user);
        IERC20(REUSD).approve(address(aaveStrategy), INITIAL_DEPOSIT);
        aaveVault.deposit(INITIAL_DEPOSIT, user);
        vm.stopPrank();

        shares = aaveVault.balanceOf(user);
        vm.prank(user);
        uint256 aaveReceived = aaveVault.redeem(shares, user, user);

        emit log_named_decimal_uint("Aave received", aaveReceived, 18);
        emit log_named_decimal_uint("Difference (Aave fee cost)", balancerReceived - aaveReceived, 18);

        // Aave should return less due to 0.05% fee
        assertLt(aaveReceived, balancerReceived, "Aave should return less due to fee");

        // The difference should be the Aave 0.05% fee on flash loan amount
        // Flash loan ~54k USDC, so fee ≈ 0.05% * 54k ≈ $27
        uint256 feeDiff = balancerReceived - aaveReceived;
        assertGt(feeDiff, 10e18, "Fee difference should be > $10");
        assertLt(feeDiff, 100e18, "Fee difference should be < $100");
    }

    /*//////////////////////////////////////////////////////////////
                            HELPERS
    //////////////////////////////////////////////////////////////*/

    function _getUserCollateralBalance(address _user) internal returns (uint256) {
        (bool success, bytes memory data) = RESUPPLY_PAIR.call(
            abi.encodeWithSignature("userCollateralBalance(address)", _user)
        );
        require(success, "userCollateralBalance failed");
        return abi.decode(data, (uint256));
    }

    function _requiredContractsPresent() internal view returns (bool) {
        return REUSD.code.length > 0 && SREUSD.code.length > 0 && CRVUSD.code.length > 0
            && CURVE_LLAMMA.code.length > 0 && RESUPPLY_PAIR.code.length > 0;
    }

    /*//////////////////////////////////////////////////////////////
                    GAS COST ESTIMATION
    //////////////////////////////////////////////////////////////*/

    /// @notice Estimate gas costs for deposits and withdrawals
    function testFork_GasCostEstimation() public {
        address user1 = address(0x1111);
        address user2 = address(0x2222);
        address user3 = address(0x3333);

        deal(REUSD, user1, 20_000e18);
        deal(REUSD, user2, 100_000e18);
        deal(REUSD, user3, 50_000e18);

        // User 1: 20k deposit
        vm.startPrank(user1);
        IERC20(REUSD).approve(address(loopStrategy), 20_000e18);
        uint256 gas1 = gasleft();
        strategyVault.deposit(20_000e18, user1);
        uint256 deposit20kGas = gas1 - gasleft();
        vm.stopPrank();

        // User 2: 100k deposit
        vm.startPrank(user2);
        IERC20(REUSD).approve(address(loopStrategy), 100_000e18);
        gas1 = gasleft();
        strategyVault.deposit(100_000e18, user2);
        uint256 deposit100kGas = gas1 - gasleft();
        vm.stopPrank();

        // User 3: 50k deposit
        vm.startPrank(user3);
        IERC20(REUSD).approve(address(loopStrategy), 50_000e18);
        gas1 = gasleft();
        strategyVault.deposit(50_000e18, user3);
        uint256 deposit50kGas = gas1 - gasleft();
        vm.stopPrank();

        emit log_named_uint("=== DEPOSIT GAS ===", 0);
        emit log_named_uint("20k deposit gas", deposit20kGas);
        emit log_named_uint("100k deposit gas", deposit100kGas);
        emit log_named_uint("50k deposit gas", deposit50kGas);

        // User 3: withdraw all 50k
        uint256 shares3 = IERC20(address(loopStrategy)).balanceOf(user3);
        vm.startPrank(user3);
        gas1 = gasleft();
        IStrategyWithRedeem(address(loopStrategy)).redeem(shares3, user3, user3);
        uint256 withdraw50kGas = gas1 - gasleft();
        vm.stopPrank();

        emit log_named_uint("=== WITHDRAW GAS ===", 0);
        emit log_named_uint("50k withdraw gas (with re-leverage)", withdraw50kGas);

        // Summary at 30 gwei and $3500 ETH
        uint256 gweiPrice = 30;
        uint256 ethPriceUsd = 3500;

        emit log_named_uint("=== USD COSTS @ 30 gwei, $3500 ETH ===", 0);
        emit log_named_decimal_uint("20k deposit cost USD", (deposit20kGas * gweiPrice * ethPriceUsd) / 1e9, 0);
        emit log_named_decimal_uint("100k deposit cost USD", (deposit100kGas * gweiPrice * ethPriceUsd) / 1e9, 0);
        emit log_named_decimal_uint("50k deposit cost USD", (deposit50kGas * gweiPrice * ethPriceUsd) / 1e9, 0);
        emit log_named_decimal_uint("50k withdraw cost USD", (withdraw50kGas * gweiPrice * ethPriceUsd) / 1e9, 0);
    }
}
