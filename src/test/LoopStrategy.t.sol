// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.18;

import "forge-std/console.sol";
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
    MockResupply public resupply;

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
        resupply = new MockResupply(address(crvUSD), address(reUSD), swapper);

        // Deploy the loop strategy
        loopStrategy = new SreUSDCrvUSDLoopStrategy(
            address(reUSD),
            address(sreUSD),
            address(crvUSD),
            address(curveLLAMMA),
            address(resupply),
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
        vm.label(address(resupply), "Resupply");
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

        console.log("=== After Deposit ===");
        _logPositions();

        // Strategy should have leveraged position
        assertTrue(curveLLAMMA.loan_exists(address(loopStrategy)), "No Curve loan created");

        // Check we have debt on both protocols
        uint256 curveDebt = curveLLAMMA.debt(address(loopStrategy));
        uint256 resupplyShares = resupply.userBorrowShares(address(loopStrategy));

        console.log("Curve debt (crvUSD):", curveDebt);
        console.log("Resupply borrow shares:", resupplyShares);

        assertGt(curveDebt, 0, "No crvUSD debt");
        assertGt(resupplyShares, 0, "No reUSD debt");

        // Check LTV is within target
        uint256[4] memory state = curveLLAMMA.user_state(address(loopStrategy));
        uint256 sreUSDCollateral = state[0];
        uint256 curveDebtCheck = state[1];

        console.log("sreUSD collateral:", sreUSDCollateral);
        console.log("Curve debt:", curveDebtCheck);

        // LTV should be close to target (95%)
        uint256 curveLTV = (curveDebtCheck * BASIS_POINTS) / sreUSDCollateral;
        console.log("Curve LTV:", curveLTV, "basis points");

        assertGe(curveLTV, 9000, "LTV too low"); // At least 90%
        assertLe(curveLTV, 9600, "LTV too high"); // Max 96%
    }

    function testHarvestAndReport_CorrectAccounting() public {
        // Deposit and create position
        vm.startPrank(user);
        reUSD.approve(address(loopStrategy), INITIAL_DEPOSIT);
        strategyVault.deposit(INITIAL_DEPOSIT, user);
        vm.stopPrank();

        console.log("=== Initial Position ===");
        _logPositions();

        // Call report (this calls _harvestAndReport internally)
        vm.prank(keeper);
        strategyVault.report();

        uint256 totalAssets = strategyVault.totalAssets();
        console.log("Total assets reported:", totalAssets);

        // Total assets should equal initial deposit (no yield yet)
        // Allow for small rounding errors
        assertApproxEqRel(totalAssets, INITIAL_DEPOSIT, 0.01e18, "Incorrect total assets");

        // Now simulate yield accrual on sreUSD
        sreUSD.accrueYield(); // Adds 1% yield

        console.log("\n=== After sreUSD Yield ===");
        _logPositions();

        vm.prank(keeper);
        strategyVault.report();

        uint256 totalAssetsAfterYield = strategyVault.totalAssets();
        console.log("Total assets after yield:", totalAssetsAfterYield);

        // Should have gained from sreUSD appreciation
        assertGt(totalAssetsAfterYield, totalAssets, "No yield captured");

        // Calculate expected profit (roughly 1% on the leveraged collateral)
        uint256[4] memory stateAfter = curveLLAMMA.user_state(address(loopStrategy));
        uint256 sreUSDValue = sreUSD.convertToAssets(stateAfter[0]);

        console.log("sreUSD collateral value:", sreUSDValue);
        console.log("Profit:", totalAssetsAfterYield - totalAssets);
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

    function _logPositions() internal view {
        console.log("\n--- Strategy Positions ---");

        // Idle balances
        console.log("Idle reUSD:", reUSD.balanceOf(address(loopStrategy)));
        console.log("Idle crvUSD:", crvUSD.balanceOf(address(loopStrategy)));
        console.log("Idle sreUSD:", sreUSD.balanceOf(address(loopStrategy)));

        // Curve position
        if (curveLLAMMA.loan_exists(address(loopStrategy))) {
            uint256[4] memory curveState = curveLLAMMA.user_state(address(loopStrategy));
            console.log("\nCurve LLAMMA:");
            console.log("  sreUSD collateral:", curveState[0]);
            console.log("  crvUSD debt:", curveState[1]);
            if (curveState[0] > 0) {
                uint256 ltv = (curveState[1] * BASIS_POINTS) / curveState[0];
                console.log("  LTV:", ltv, "bps");
            }
        }

        // Resupply position
        uint256 resupplyCollateral = resupply.userCollateralBalance(address(loopStrategy));
        uint256 resupplyShares = resupply.userBorrowShares(address(loopStrategy));
        uint256 resupplyDebt = resupply.toBorrowAmount(resupplyShares, false, false);

        console.log("\nResupply:");
        console.log("  crvUSD collateral:", resupplyCollateral);
        console.log("  reUSD borrow shares:", resupplyShares);
        console.log("  reUSD debt:", resupplyDebt);
        if (resupplyCollateral > 0 && resupplyDebt > 0) {
            uint256 ltv = (resupplyDebt * BASIS_POINTS) / resupplyCollateral;
            console.log("  LTV:", ltv, "bps");
        }

        // sreUSD exchange rate
        uint256 rate = sreUSD.exchangeRate();
        console.log("\nsreUSD exchange rate:", rate);

        console.log("-------------------------\n");
    }
}
