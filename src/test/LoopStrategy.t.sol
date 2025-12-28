// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.18;

import {Setup} from "./utils/Setup.sol";

import {SreUSDCrvUSDLoopStrategy} from "../SreUSDCrvUSDLoopStrategy.sol";
import {MockSreUSD, MockCurveLLAMMA, MockResupply} from "./mocks/MockLoopProtocols.sol";
import {IStrategy} from "../interfaces/IStrategy.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/ERC20Mock.sol";

contract LoopStrategyTest is Setup {
    SreUSDCrvUSDLoopStrategy public loopStrategy; // For strategy-specific functions
    IStrategy public strategyVault; // For vault operations (deposit, withdraw, etc.)

    ERC20Mock public reUSD;
    ERC20Mock public crvUSD;
    MockSreUSD public sreUSD;
    MockCurveLLAMMA public curveLLAMMA;
    MockResupply public resupplyPair;

    address public swapper = address(100); // Mock swapper for Resupply
    address public curveZap = address(101); // Mock Zap for Curve

    uint256 public constant INITIAL_DEPOSIT = 100 ether;
    uint256 public constant BASIS_POINTS = 10000;

    function setUp() public override {
        // Call parent setUp to deploy factory + tokenizedStrategy
        super.setUp();

        // Deploy mock tokens for our specific strategy
        reUSD = new ERC20Mock();
        crvUSD = new ERC20Mock();

        // Deploy sreUSD (ERC-4626 vault for reUSD)
        sreUSD = new MockSreUSD(reUSD);

        // Deploy mock protocols
        curveLLAMMA = new MockCurveLLAMMA(address(sreUSD), address(crvUSD));
        resupplyPair = new MockResupply(address(crvUSD), address(reUSD), swapper);

        // Deploy the loop strategy
        loopStrategy = new SreUSDCrvUSDLoopStrategy(
            address(reUSD),
            address(sreUSD),
            address(crvUSD),
            address(curveLLAMMA),
            address(resupplyPair),
            "SreUSD Loop Strategy"
        );

        // Wrap in IStrategy interface for vault operations and role management
        strategyVault = IStrategy(address(loopStrategy));

        // Set up roles (using inherited variables from Setup)
        strategyVault.setKeeper(keeper);
        strategyVault.setEmergencyAdmin(emergencyAdmin);
        strategyVault.setPerformanceFeeRecipient(performanceFeeRecipient);
        strategyVault.setPendingManagement(management);

        vm.prank(management);
        strategyVault.acceptManagement();

        // Mint reUSD to user
        reUSD.mint(user, 1000 ether);

        // Label addresses for better trace output
        vm.label(address(loopStrategy), "Strategy");
        vm.label(address(reUSD), "reUSD");
        vm.label(address(crvUSD), "crvUSD");
        vm.label(address(sreUSD), "sreUSD");
        vm.label(address(curveLLAMMA), "Curve LLAMMA");
        vm.label(address(resupplyPair), "Resupply Pair");
        vm.label(user, "User");
        vm.label(management, "Management");
    }

    /*//////////////////////////////////////////////////////////////
                        BASIC LEVERAGE TESTS
    //////////////////////////////////////////////////////////////*/

    function testDeployFunds_CreatesLeveragedPosition() public {
        // User deposits reUSD to strategy
        vm.startPrank(user);
        reUSD.approve(address(loopStrategy), INITIAL_DEPOSIT);
        strategyVault.deposit(INITIAL_DEPOSIT, user);
        vm.stopPrank();

        emit log("=== After Deposit ===");
        _logPositions();

        // Strategy should have leveraged position
        assertTrue(curveLLAMMA.loan_exists(address(loopStrategy)), "No Curve loan created");

        // Check we have debt on both protocols
        uint256 curveDebt = curveLLAMMA.debt(address(loopStrategy));
        uint256 resupplyShares = resupplyPair.userBorrowShares(address(loopStrategy));

        emit log_named_decimal_uint("Curve debt (crvUSD)", curveDebt, 18);
        emit log_named_decimal_uint("Resupply borrow shares", resupplyShares, 18);

        assertGt(curveDebt, 0, "No crvUSD debt");
        assertGt(resupplyShares, 0, "No reUSD debt");

        // Check LTV is within target
        uint256[4] memory state = curveLLAMMA.user_state(address(loopStrategy));
        uint256 sreUSDCollateral = state[0];
        uint256 curveDebtCheck = state[1];

        emit log_named_decimal_uint("sreUSD collateral", sreUSDCollateral, 18);
        emit log_named_decimal_uint("Curve debt", curveDebtCheck, 18);

        // LTV should be close to target (95%)
        uint256 curveLTV = (curveDebtCheck * BASIS_POINTS) / sreUSDCollateral;
        emit log_named_uint("Curve LTV (bps)", curveLTV);

        assertGe(curveLTV, 9000, "LTV too low"); // At least 90%
        assertLe(curveLTV, 9600, "LTV too high"); // Max 96%
    }

    function testHarvestAndReport_CorrectAccounting() public {
        // Deposit and create position
        vm.startPrank(user);
        reUSD.approve(address(loopStrategy), INITIAL_DEPOSIT);
        strategyVault.deposit(INITIAL_DEPOSIT, user);
        vm.stopPrank();

        emit log("=== Initial Position ===");
        _logPositions();

        // Call report (this calls _harvestAndReport internally)
        vm.prank(keeper);
        strategyVault.report();

        uint256 totalAssets = strategyVault.totalAssets();
        emit log_named_decimal_uint("Total assets reported", totalAssets, 18);

        // Total assets should equal initial deposit (no yield yet)
        // Allow for small rounding errors
        assertApproxEqRel(totalAssets, INITIAL_DEPOSIT, 0.01e18, "Incorrect total assets");

        // Now simulate yield accrual on sreUSD
        sreUSD.accrueYield(); // Adds 1% yield

        emit log("=== After sreUSD Yield ===");
        _logPositions();

        vm.prank(keeper);
        strategyVault.report();

        uint256 totalAssetsAfterYield = strategyVault.totalAssets();
        emit log_named_decimal_uint("Total assets after yield", totalAssetsAfterYield, 18);

        // Should have gained from sreUSD appreciation
        assertGt(totalAssetsAfterYield, totalAssets, "No yield captured");

        // Calculate expected profit (roughly 1% on the leveraged collateral)
        uint256[4] memory stateAfter = curveLLAMMA.user_state(address(loopStrategy));
        uint256 sreUSDValue = sreUSD.convertToAssets(stateAfter[0]);

        emit log_named_decimal_uint("sreUSD collateral value", sreUSDValue, 18);
        emit log_named_decimal_uint("Profit", totalAssetsAfterYield - totalAssets, 18);
    }

    // NOTE: Partial and full withdrawal tests are in LoopStrategyFork.t.sol
    // Mock-based tests don't accurately simulate the complex exchange rates
    // and vault mechanics of real protocols (sreUSD, cvcrvUSD vaults).
    // Use fork tests for withdrawal integration testing.

    // NOTE: Yield profit and multi-user tests are in LoopStrategyFork.t.sol
    // Mock-based tests don't accurately simulate real protocol behavior.

    /*//////////////////////////////////////////////////////////////
                        EDGE CASE TESTS
    //////////////////////////////////////////////////////////////*/

    function testCannotExceedMaxLTV() public {
        // Try to set LTV above max
        vm.prank(management);
        vm.expectRevert("Curve LTV too high");
        loopStrategy.setTargetLTVs(9200, 9700); // 97% > 96% max

        vm.prank(management);
        vm.expectRevert("Resupply LTV too high");
        loopStrategy.setTargetLTVs(9600, 9500); // 96% > 95% max
    }

    /*//////////////////////////////////////////////////////////////
                            HELPER FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function _logPositions() internal {
        emit log("--- Strategy Positions ---");

        // Idle balances
        emit log_named_decimal_uint("Idle reUSD", reUSD.balanceOf(address(loopStrategy)), 18);
        emit log_named_decimal_uint("Idle crvUSD", crvUSD.balanceOf(address(loopStrategy)), 18);
        emit log_named_decimal_uint("Idle sreUSD", sreUSD.balanceOf(address(loopStrategy)), 18);

        // Curve position
        if (curveLLAMMA.loan_exists(address(loopStrategy))) {
            uint256[4] memory curveState = curveLLAMMA.user_state(address(loopStrategy));
            emit log("Curve LLAMMA:");
            emit log_named_decimal_uint("  sreUSD collateral", curveState[0], 18);
            emit log_named_decimal_uint("  crvUSD debt", curveState[1], 18);
            if (curveState[0] > 0) {
                uint256 ltv = (curveState[1] * BASIS_POINTS) / curveState[0];
                emit log_named_uint("  LTV (bps)", ltv);
            }
        }

        // Resupply position
        uint256 resupplyCollateral = resupplyPair.userCollateralBalance(address(loopStrategy));
        uint256 resupplyShares = resupplyPair.userBorrowShares(address(loopStrategy));
        uint256 resupplyDebt = resupplyPair.toBorrowAmount(resupplyShares, false, false);

        emit log("Resupply:");
        emit log_named_decimal_uint("  crvUSD collateral", resupplyCollateral, 18);
        emit log_named_decimal_uint("  reUSD borrow shares", resupplyShares, 18);
        emit log_named_decimal_uint("  reUSD debt", resupplyDebt, 18);
        if (resupplyCollateral > 0 && resupplyDebt > 0) {
            uint256 ltv = (resupplyDebt * BASIS_POINTS) / resupplyCollateral;
            emit log_named_uint("  LTV (bps)", ltv);
        }

        // sreUSD exchange rate
        uint256 rate = sreUSD.exchangeRate();
        emit log_named_decimal_uint("sreUSD exchange rate", rate, 18);

        emit log("-------------------------");
    }
}
