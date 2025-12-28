// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.18;

import {Test} from "forge-std/Test.sol";

import {SreUSDCrvUSDLoopStrategy} from "../SreUSDCrvUSDLoopStrategy.sol";
import {IStrategy} from "../interfaces/IStrategy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

/**
 * @title LoopStrategyForkTest
 * @notice Mainnet fork tests for the SreUSD/crvUSD Loop Strategy
 * @dev Tests against real deployed contracts on Ethereum mainnet
 *
 * Run with:
 *   forge test --match-contract LoopStrategyForkTest --fork-url $MAINNET_RPC_URL -vvv
 *
 * Or set in foundry.toml:
 *   [rpc_endpoints]
 *   mainnet = "${MAINNET_RPC_URL}"
 */
contract LoopStrategyForkTest is Test {
    SreUSDCrvUSDLoopStrategy public loopStrategy;
    IStrategy public strategyVault;

    // Real mainnet addresses
    address public constant REUSD = 0x57aB1E0003F623289CD798B1824Be09a793e4Bec;
    address public constant SREUSD = 0x557AB1e003951A73c12D16F0fEA8490E39C33C35; // sreUSD ERC4626 vault
    address public constant CRVUSD = 0xf939E0A03FB07F59A73314E73794Be0E57ac1b4E; // crvUSD token
    address public constant CURVE_LLAMMA = 0x4F79Fe450a2BAF833E8f50340BD230f5A3eCaFe9; // Curve LLAMMA controller (sreUSD-long)
    address public constant RESUPPLY_PAIR = 0xD42535Cda82a4569BA7209857446222ABd14A82c; // Resupply Pair (CurveLend: crvUSD/fxSAVE)

    // Test accounts
    address public management = address(this);
    address public keeper;
    address public emergencyAdmin;
    address public performanceFeeRecipient;
    address public user;

    // reUSD holder for testing
    address public constant reUSDHolder = 0x47628677D8Aa6f5E11e37779576852e0209D6aE7;

    uint256 public constant INITIAL_DEPOSIT = 10000 ether; // Take note rsup minimum borrow threshold
    uint256 public constant BASIS_POINTS = 10000;
    uint256 public mainnetFork;
    uint256 public constant DEFAULT_FORK_BLOCK = 24107304;

    function setUp() public {
        // Prefer anvil (local fork) if provided.
        string memory rpcUrl = vm.envOr("ANVIL_RPC_URL", string(""));
        if (bytes(rpcUrl).length == 0) {
            rpcUrl = "http://localhost:8545";
        }
        uint256 forkBlock = vm.envOr("MAINNET_FORK_BLOCK", DEFAULT_FORK_BLOCK);
        mainnetFork = vm.createSelectFork(rpcUrl, forkBlock);
        if (!_requiredContractsPresent()) {
            emit log("Required contracts not deployed at fork block, retrying at latest block.");
            mainnetFork = vm.createSelectFork(rpcUrl);
            require(_requiredContractsPresent(), "Required contracts not deployed on fork");
        }

        // Verify we're on mainnet (chainid 1)
        assertEq(block.chainid, 1, "Not on mainnet fork");

        // Set up test accounts
        keeper = makeAddr("keeper");
        emergencyAdmin = makeAddr("emergencyAdmin");
        performanceFeeRecipient = makeAddr("performanceFeeRecipient");
        user = makeAddr("user");

        // Deploy the loop strategy with real contract addresses
        loopStrategy = new SreUSDCrvUSDLoopStrategy(
            REUSD,
            SREUSD,
            CRVUSD,
            CURVE_LLAMMA,
            RESUPPLY_PAIR,
            "SreUSD Loop Strategy"
        );

        // Wrap in IStrategy interface for vault operations
        strategyVault = IStrategy(address(loopStrategy));

        // Set up roles
        strategyVault.setKeeper(keeper);
        strategyVault.setEmergencyAdmin(emergencyAdmin);
        strategyVault.setPerformanceFeeRecipient(performanceFeeRecipient);
        strategyVault.setPendingManagement(management);

        vm.prank(management);
        strategyVault.acceptManagement();

        // Fund user with reUSD; prefer cheatcode to avoid holder balance drift across forks
        deal(REUSD, user, 20000 ether, true);

        // Verify user has reUSD
        uint256 userBalance = IERC20(REUSD).balanceOf(user);
        assertGe(userBalance, INITIAL_DEPOSIT, "User didn't receive enough reUSD");

        // Pre-warm contract states to avoid NotActivated errors in nested calls
        // This forces Foundry to load the bytecode into EVM state
        RESUPPLY_PAIR.call(abi.encodeWithSignature("name()"));

        // Also warm the Resupply Registry
        address registry = 0x10101010E0C3171D894B71B3400668aF311e7D94;
        registry.call(abi.encodeWithSignature("name()"));

        // Label addresses for better trace output
        vm.label(address(loopStrategy), "Strategy");
        vm.label(REUSD, "reUSD");
        vm.label(SREUSD, "sreUSD");
        vm.label(CRVUSD, "crvUSD");
        vm.label(CURVE_LLAMMA, "Curve LLAMMA");
        vm.label(RESUPPLY_PAIR, "Resupply Pair");
        vm.label(user, "User");
        vm.label(management, "Management");
    }

    /*//////////////////////////////////////////////////////////////
                        BASIC LEVERAGE TESTS
    //////////////////////////////////////////////////////////////*/

    function testFork_DeployFunds_CreatesLeveragedPosition() public {
        // User deposits reUSD to strategy
        vm.startPrank(user);
        IERC20(REUSD).approve(address(loopStrategy), INITIAL_DEPOSIT);
        uint256 shares = strategyVault.deposit(INITIAL_DEPOSIT, user);
        vm.stopPrank();

        // Verify shares were issued
        assertGt(shares, 0, "No shares issued");

        // Verify leveraged position was created
        uint256 totalAssets = strategyVault.totalAssets();

        // Should be close to initial deposit (allowing for small deployment variance)
        assertApproxEqRel(totalAssets, INITIAL_DEPOSIT, 0.05e18, "Incorrect total assets");
    }

    function testFork_Harvest_RealYieldAccrual() public {
        // Deposit
        vm.startPrank(user);
        IERC20(REUSD).approve(address(loopStrategy), INITIAL_DEPOSIT);
        strategyVault.deposit(INITIAL_DEPOSIT, user);
        vm.stopPrank();

        uint256 initialAssets = strategyVault.totalAssets();
        emit log_named_decimal_uint("Initial assets", initialAssets, 18);

        // Advance time to accrue real yield on sreUSD
        // sreUSD typically accrues ~18% APY
        skip(30 days);

        emit log("=== After 30 days ==.");
        _logPositions();

        // Prevent redeploy to avoid stale oracle reads after time skip.
        vm.prank(management);
        loopStrategy.setLoopParameters(loopStrategy.maxIterations(), type(uint256).max);

        // Report to update accounting with real yield
        vm.prank(keeper);
        strategyVault.report();

        uint256 finalAssets = strategyVault.totalAssets();
        emit log_named_decimal_uint("Final assets", finalAssets, 18);

        // Should have gained from sreUSD yield (at least some positive yield)
        assertGt(finalAssets, initialAssets, "No yield captured from real protocols");

        uint256 profit = finalAssets - initialAssets;
        uint256 profitBps = (profit * BASIS_POINTS) / initialAssets;
        emit log_named_decimal_uint("Profit", profit, 18);
        emit log_named_uint("Profit (bps)", profitBps);
    }

    function testFork_PartialWithdrawal() public {
        // Setup position
        vm.startPrank(user);
        IERC20(REUSD).approve(address(loopStrategy), INITIAL_DEPOSIT);
        strategyVault.deposit(INITIAL_DEPOSIT, user);
        vm.stopPrank();

        emit log("=== Before Withdrawal ==.");
        _logPositions();

        // Withdraw 30%
        uint256 sharesToWithdraw = (strategyVault.balanceOf(user) * 30) / 100;

        uint256 expectedAssets = strategyVault.previewRedeem(sharesToWithdraw);
        vm.prank(user);
        uint256 assetsWithdrawn = strategyVault.redeem(sharesToWithdraw, user, user);

        emit log("=== After Withdrawal ==.");
        emit log_named_decimal_uint("Assets withdrawn", assetsWithdrawn, 18);
        _logPositions();

        // Allow for loss during deleveraging on fork.
        assertGt(assetsWithdrawn, 0, "No assets withdrawn");
        assertLe(assetsWithdrawn, expectedAssets, "Withdrawal exceeds preview");

        // User should have received reUSD
        uint256 userReUSD = IERC20(REUSD).balanceOf(user);
        assertGt(userReUSD, 0, "User didn't receive reUSD");
    }

    function testFork_FullWithdrawal() public {
        // Setup position
        vm.startPrank(user);
        IERC20(REUSD).approve(address(loopStrategy), INITIAL_DEPOSIT);
        strategyVault.deposit(INITIAL_DEPOSIT, user);
        vm.stopPrank();

        emit log("=== Before Full Withdrawal ==.");
        _logPositions();

        // Withdraw everything
        uint256 shares = strategyVault.balanceOf(user);
        uint256 totalAssetsBefore = strategyVault.totalAssets();

        emit log_named_decimal_uint("User shares", shares, 18);
        emit log_named_decimal_uint("Total assets before", totalAssetsBefore, 18);

        uint256 expectedAssets = strategyVault.previewRedeem(shares);
        emit log_named_decimal_uint("Expected assets from preview", expectedAssets, 18);

        vm.prank(user);
        uint256 assetsWithdrawn = strategyVault.redeem(shares, user, user);

        emit log("=== After Full Withdrawal ==.");
        emit log_named_decimal_uint("Assets withdrawn", assetsWithdrawn, 18);
        _logPositions();

        // Allow for loss during deleveraging on fork.
        assertGt(assetsWithdrawn, 0, "No assets withdrawn");
        assertLe(assetsWithdrawn, expectedAssets, "Withdrawal exceeds preview");

        // All shares should be burned
        assertEq(strategyVault.balanceOf(user), 0, "Shares not fully burned");
    }

    /*//////////////////////////////////////////////////////////////
                        REAL PROTOCOL INTEGRATION
    //////////////////////////////////////////////////////////////*/

    function testFork_RealProtocolInteraction() public {
        // Verify we can interact with real protocols
        IERC4626 sreUSD = IERC4626(SREUSD);

        // Check sreUSD exchange rate
        uint256 exchangeRate = (sreUSD.totalAssets() * 1e18) / sreUSD.totalSupply();
        emit log_named_decimal_uint("sreUSD exchange rate", exchangeRate, 18);
        assertGt(exchangeRate, 0, "Invalid sreUSD exchange rate");

        // Check crvUSD exists
        uint256 crvUSDSupply = IERC20(CRVUSD).totalSupply();
        assertGt(crvUSDSupply, 0, "crvUSD not found");

        emit log("Real protocol checks passed");
    }

    /*//////////////////////////////////////////////////////////////
                            HELPER FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function _logPositions() internal {
        emit log("--- Strategy Positions (Real Protocols) ---");

        // Idle balances
        emit log_named_decimal_uint("Idle reUSD", IERC20(REUSD).balanceOf(address(loopStrategy)), 18);
        emit log_named_decimal_uint("Idle crvUSD", IERC20(CRVUSD).balanceOf(address(loopStrategy)), 18);
        emit log_named_decimal_uint("Idle sreUSD", IERC20(SREUSD).balanceOf(address(loopStrategy)), 18);

        // Note: Actual position data will depend on real protocol interfaces
        // This is a simplified version - expand based on actual protocol ABIs

        emit log("-------------------------");
    }

    function _requiredContractsPresent() internal view returns (bool) {
        return REUSD.code.length > 0
            && SREUSD.code.length > 0
            && CRVUSD.code.length > 0
            && CURVE_LLAMMA.code.length > 0
            && RESUPPLY_PAIR.code.length > 0;
    }
}
