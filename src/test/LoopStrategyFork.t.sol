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
        loopStrategy.setLoopParameters(loopStrategy.maxIterations(), type(uint256).max, loopStrategy.minBufferAmount(), loopStrategy.idleBufferBps());

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

        assertGt(IERC20(REUSD).balanceOf(address(loopStrategy)), 0, "Should have idle buffer");

        // User1 withdraws (partial - should NOT emit FullWithdrawal)
        vm.recordLogs();
        vm.prank(user1);
        uint256 assets1 = IStrategyWithRedeem(address(loopStrategy)).redeem(shares1, user1, user1);
        assertFullWithdrawalNotEmitted(vm.getRecordedLogs());
        assertGt(assets1, 9500e18, "User1 should receive most of deposit");
        assertEq(IERC20(address(loopStrategy)).balanceOf(user1), 0, "User1 should have no shares");

        // User2 withdraws (partial - should NOT emit FullWithdrawal)
        vm.recordLogs();
        vm.prank(user2);
        uint256 assets2 = IStrategyWithRedeem(address(loopStrategy)).redeem(shares2, user2, user2);
        assertFullWithdrawalNotEmitted(vm.getRecordedLogs());
        assertGt(assets2, 4750e18, "User2 should receive most of deposit");
        assertEq(IERC20(address(loopStrategy)).balanceOf(user2), 0, "User2 should have no shares");

        // User3 withdraws (last user - SHOULD emit FullWithdrawal)
        vm.recordLogs();
        vm.prank(user3);
        uint256 assets3 = IStrategyWithRedeem(address(loopStrategy)).redeem(shares3, user3, user3);
        assertFullWithdrawalEmitted(vm.getRecordedLogs());
        assertGt(assets3, 2850e18, "User3 should receive most of deposit");
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

    /// @notice Test: Insufficient iterations now REVERTS instead of silent partial withdrawal
    /// @dev After fix, when maxIterations is too low, withdrawal reverts protecting user funds
    function testFork_WithdrawalStuck_MaxIterationsReached() public {
        // Setup: User deposits
        vm.startPrank(user);
        IERC20(REUSD).approve(address(loopStrategy), INITIAL_DEPOSIT);
        uint256 shares = strategyVault.deposit(INITIAL_DEPOSIT, user);
        vm.stopPrank();

        uint256 userReUSDBefore = IERC20(REUSD).balanceOf(user);

        // Reduce maxIterations to very low value
        vm.prank(management);
        loopStrategy.setLoopParameters(
            3, // Only 3 iterations - not enough to fully deleverage
            loopStrategy.minLoopAmount(),
            loopStrategy.minBufferAmount(),
            loopStrategy.idleBufferBps()
        );

        // Try full withdrawal with limited iterations - should REVERT now
        vm.prank(user);
        vm.expectRevert("Deleverage failed: insufficient funds freed");
        IStrategyWithRedeem(address(loopStrategy)).redeem(shares, user, user);

        // User should still have their shares (withdrawal failed)
        uint256 userSharesAfter = IERC20(address(loopStrategy)).balanceOf(user);
        assertEq(userSharesAfter, shares, "User should still have shares after failed withdrawal");

        // User's reUSD balance should be unchanged
        uint256 userReUSDAfter = IERC20(REUSD).balanceOf(user);
        assertEq(userReUSDAfter, userReUSDBefore, "User reUSD should be unchanged");

        emit log("FIX CONFIRMED: Withdrawal reverts instead of silently losing funds");
    }

    /// @notice Test: Progress check - does minimal progress prevent exit?
    /// @dev The no-progress check allows even 1 wei progress to continue
    function testFork_WithdrawalStuck_MinimalProgress() public {
        // This test checks if the progress detection is too lenient

        vm.startPrank(user);
        IERC20(REUSD).approve(address(loopStrategy), INITIAL_DEPOSIT);
        uint256 shares = strategyVault.deposit(INITIAL_DEPOSIT, user);
        vm.stopPrank();

        // Get position info before withdrawal
        uint256 curveDebtBefore = ICurveLLAMMA(CURVE_LLAMMA).debt(address(loopStrategy));
        uint256 resupplySharesBefore = IResupply(RESUPPLY_PAIR).userBorrowShares(address(loopStrategy));

        emit log_named_decimal_uint("Curve debt before", curveDebtBefore, 18);
        emit log_named_decimal_uint("Resupply shares before", resupplySharesBefore, 18);

        // Withdraw 95% - leaves small remainder that may be hard to unwind
        uint256 withdrawShares = (shares * 95) / 100;

        uint256 gasBefore = gasleft();
        vm.prank(user);
        uint256 assets = IStrategyWithRedeem(address(loopStrategy)).redeem(withdrawShares, user, user);
        uint256 gasUsed = gasBefore - gasleft();

        emit log_named_decimal_uint("Withdrawal received", assets, 18);
        emit log_named_uint("Gas used", gasUsed);

        // High gas usage might indicate many iterations (minimal progress per iteration)
        // Normal deleverage: ~5-10 iterations
        // Stuck/slow deleverage: 20-30 iterations
        if (gasUsed > 5_000_000) {
            emit log("WARNING: High gas usage suggests many iterations (potential stuck scenario)");
        }

        uint256 curveDebtAfter = ICurveLLAMMA(CURVE_LLAMMA).debt(address(loopStrategy));
        uint256 resupplySharesAfter = IResupply(RESUPPLY_PAIR).userBorrowShares(address(loopStrategy));

        emit log_named_decimal_uint("Curve debt after", curveDebtAfter, 18);
        emit log_named_decimal_uint("Resupply shares after", resupplySharesAfter, 18);
    }

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

    /// @notice Test: Show leverage vs deleverage asymmetry
    /// @dev Demonstrates why deposits are fast but withdrawals are slow
    function testFork_LeverageVsDeleverageAsymmetry() public {
        uint256 depositAmount = 10_000 ether;

        emit log("=== Leverage vs Deleverage Asymmetry ===");
        emit log("");
        emit log("LEVERAGE: Each iteration reinvests ~87% of previous (0.95 * 0.92)");
        emit log("DELEVERAGE: Each iteration frees only excess above min LTV");
        emit log("");

        // Create fresh strategy
        SreUSDCrvUSDLoopStrategy testStrategy = new SreUSDCrvUSDLoopStrategy(
            REUSD, SREUSD, CRVUSD, CURVE_LLAMMA, RESUPPLY_PAIR, "Test Strategy"
        );
        IStrategy(address(testStrategy)).setKeeper(address(this));
        testStrategy.setRewardSwapPool(SCRVUSD, SCRVUSD_REUSD_POOL);

        deal(REUSD, user, depositAmount);

        // Record leverage events
        vm.recordLogs();

        vm.startPrank(user);
        IERC20(REUSD).approve(address(testStrategy), depositAmount);
        uint256 shares = IStrategy(address(testStrategy)).deposit(depositAmount, user);
        vm.stopPrank();

        // Extract leverage iterations
        Vm.Log[] memory leverageLogs = vm.getRecordedLogs();
        bytes32 leverageSelector = keccak256("LeverageIteration(uint256,uint256)");

        emit log("=== LEVERAGE (Deposit) ===");
        for (uint256 i = 0; i < leverageLogs.length; i++) {
            if (leverageLogs[i].topics[0] == leverageSelector) {
                (uint256 iteration, uint256 reUSDToLoop) =
                    abi.decode(leverageLogs[i].data, (uint256, uint256));
                emit log_named_uint("Iteration", iteration);
                emit log_named_decimal_uint("  reUSD looped", reUSDToLoop, 18);
            }
        }

        emit log("");
        emit log("=== DELEVERAGE (Withdraw) ===");

        // Record deleverage events
        vm.recordLogs();

        vm.prank(user);
        uint256 assets = IStrategyWithRedeem(address(testStrategy)).redeem(shares, user, user);

        // Extract deleverage iterations
        Vm.Log[] memory deleverageLogs = vm.getRecordedLogs();
        bytes32 deleverageSelector = keccak256("DeleverageIteration(uint256,uint256,uint256,uint256,uint256)");

        uint256 leverageCount = 0;
        uint256 deleverageCount = 0;

        for (uint256 i = 0; i < leverageLogs.length; i++) {
            if (leverageLogs[i].topics[0] == leverageSelector) leverageCount++;
        }

        for (uint256 i = 0; i < deleverageLogs.length; i++) {
            if (deleverageLogs[i].topics[0] == deleverageSelector) {
                deleverageCount++;
                (uint256 iteration, uint256 reUSDBalance, uint256 targetTotal, , ) =
                    abi.decode(deleverageLogs[i].data, (uint256, uint256, uint256, uint256, uint256));
                emit log_named_uint("Iteration", iteration);
                emit log_named_decimal_uint("  reUSD freed so far", reUSDBalance, 18);
                if (reUSDBalance < targetTotal) {
                    emit log_named_decimal_uint("  Still need", targetTotal - reUSDBalance, 18);
                }
            }
        }

        emit log("");
        emit log("=== SUMMARY ===");
        emit log_named_decimal_uint("Deposited", depositAmount, 18);
        emit log_named_decimal_uint("Received", assets, 18);
        emit log_named_uint("Leverage iterations", leverageCount);
        emit log_named_uint("Deleverage iterations", deleverageCount);
        emit log("");
        emit log("Deleverage needs MORE iterations because:");
        emit log("- LTV constraints limit how much collateral we can withdraw each step");
        emit log("- Must repay debt first, but need collateral to get funds to repay");
        emit log("- Each step only frees the EXCESS above minimum safe LTV");
    }

    /*//////////////////////////////////////////////////////////////
                        REWARD HARVEST TESTS
    //////////////////////////////////////////////////////////////*/

    function testFork_Harvest_SellsAllRewardTokens() public {
        SreUSDCrvUSDLoopStrategy strategy = new SreUSDCrvUSDLoopStrategy(
            REUSD, SREUSD, CRVUSD, CURVE_LLAMMA, RESUPPLY_PAIR, "Test Strategy"
        );
        IStrategy(address(strategy)).setKeeper(address(this));

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

    function testFork_SreUSD_Appreciation() public {
        uint256 shareAmount = 1000e18;
        uint256 assetValue = IERC4626(SREUSD).convertToAssets(shareAmount);

        if (assetValue > shareAmount) {
            uint256 wrongLTV = (950e18 * 10000) / shareAmount;
            uint256 correctLTV = (950e18 * 10000) / assetValue;
            assertGt(wrongLTV, correctLTV, "Wrong LTV should be higher");
        }
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
}
