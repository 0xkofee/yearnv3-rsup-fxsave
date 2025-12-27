// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.18;

import "forge-std/console.sol";
import {Test} from "forge-std/Test.sol";

import {SreUSDCrvUSDLoopStrategy} from "../SreUSDCrvUSDLoopStrategy.sol";
import {IStrategy} from "../interfaces/IStrategy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

interface IResupplyCollateral {
    function collateral() external view returns (address);
}

interface IResupplySwapper {
    function registry() external view returns (address);
    function encode(bytes calldata route, address tokenIn, address tokenOut) external pure returns (address[] memory);
    function decode(address[] calldata path) external view returns (bytes memory);
}

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
    address public constant RESUPPLY = 0xD42535Cda82a4569BA7209857446222ABd14A82c; // Resupply Pair (CurveLend: crvUSD/fxSAVE)

    // TODO: Fill in these addresses with real deployed contracts

    // Deleverage parameters (real mainnet addresses from actual transactions)
    address public constant SWAPPER = 0x3Ae884D1a67650501278001FDa40DCa975D9194D; // Real Resupply whitelisted swapper
    address public constant CURVE_ZAP = 0xC5898606BdB494a994578453B92e7910a90aA873; // Real Curve LLAMMA callbacker/zap

    // Test accounts
    address public management = address(this);
    address public keeper;
    address public emergencyAdmin;
    address public performanceFeeRecipient;
    address public user;
    bool public hasUserSwapPath;

    // reUSD holder for testing
    address public constant reUSDHolder = 0x47628677D8Aa6f5E11e37779576852e0209D6aE7;

    uint256 public constant INITIAL_DEPOSIT = 10000 ether; // Increased to ensure above minimum borrow threshold
    uint256 public constant BASIS_POINTS = 10000;
    uint256 public mainnetFork;
    uint256 public constant DEFAULT_FORK_BLOCK = 24100306; // Known block with required deployments (matches local anvil)

    function setUp() public {
        // Prefer anvil (local fork) if provided.
        string memory rpcUrl = vm.envOr("ANVIL_RPC_URL", string(""));
        if (bytes(rpcUrl).length == 0) {
            rpcUrl = "http://localhost:8545";
        }
        uint256 forkBlock = vm.envOr("MAINNET_FORK_BLOCK", DEFAULT_FORK_BLOCK);
        mainnetFork = vm.createSelectFork(rpcUrl, forkBlock);
        if (!_requiredContractsPresent()) {
            console.log("Required contracts not deployed at fork block, retrying at latest block.");
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
            RESUPPLY,
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

        // Set up deleverage parameters
        address collateral = IResupplyCollateral(RESUPPLY).collateral();
        address[] memory swapPath = vm.envOr("RESUPPLY_SWAP_PATH", ",", new address[](0));
        bytes memory route = vm.envOr("RESUPPLY_SWAP_ROUTE", bytes(""));
        hasUserSwapPath = swapPath.length > 0 || route.length > 0;
        if (swapPath.length == 0) {
            swapPath = _defaultSwapPath();
            if (swapPath.length > 0) {
                hasUserSwapPath = true;
            }
            if (swapPath.length == 0) {
                if (route.length > 0) {
                    swapPath = IResupplySwapper(SWAPPER).encode(route, collateral, REUSD);
                } else {
                    swapPath = _resolveSwapPath(collateral, REUSD);
                }
            }
        }
        require(swapPath.length >= 2, "Swap path not found (set RESUPPLY_SWAP_PATH or RESUPPLY_SWAP_ROUTE)");

        loopStrategy.setDeleverageParameters(SWAPPER, swapPath, CURVE_ZAP);
        // Ensure the swapper can transfer reUSD to Resupply during repayWithCollateral.
        vm.prank(SWAPPER);
        IERC20(REUSD).approve(RESUPPLY, type(uint256).max);

        // Fund user with reUSD; prefer cheatcode to avoid holder balance drift across forks
        deal(REUSD, user, 20000 ether, true);

        // Verify user has reUSD
        uint256 userBalance = IERC20(REUSD).balanceOf(user);
        assertGe(userBalance, INITIAL_DEPOSIT, "User didn't receive enough reUSD");

        // Pre-warm contract states to avoid NotActivated errors in nested calls
        // This forces Foundry to load the bytecode into EVM state
        RESUPPLY.call(abi.encodeWithSignature("name()"));

        // Also warm the Resupply Registry
        address registry = 0x10101010E0C3171D894B71B3400668aF311e7D94;
        registry.call(abi.encodeWithSignature("name()"));

        // Label addresses for better trace output
        vm.label(address(loopStrategy), "Strategy");
        vm.label(REUSD, "reUSD");
        vm.label(SREUSD, "sreUSD");
        vm.label(CRVUSD, "crvUSD");
        vm.label(CURVE_LLAMMA, "Curve LLAMMA");
        vm.label(RESUPPLY, "Resupply");
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
        console.log("Initial assets:", initialAssets);

        // Advance time to accrue real yield on sreUSD
        // sreUSD typically accrues ~18% APY
        skip(30 days);

        console.log("=== After 30 days ==.");
        _logPositions();

        // Report to update accounting with real yield
        vm.prank(keeper);
        strategyVault.report();

        uint256 finalAssets = strategyVault.totalAssets();
        console.log("Final assets:", finalAssets);

        // Should have gained from sreUSD yield (at least some positive yield)
        assertGt(finalAssets, initialAssets, "No yield captured from real protocols");

        uint256 profit = finalAssets - initialAssets;
        uint256 profitBps = (profit * BASIS_POINTS) / initialAssets;
        console.log("Profit:", profit);
        console.log("Profit %:", profitBps, "bps");
    }

    function testFork_PartialWithdrawal() public {
        if (!hasUserSwapPath) {
            console.log("Skipping withdrawal test: set RESUPPLY_SWAP_PATH or RESUPPLY_SWAP_ROUTE.");
            return;
        }
        // Setup position
        vm.startPrank(user);
        IERC20(REUSD).approve(address(loopStrategy), INITIAL_DEPOSIT);
        strategyVault.deposit(INITIAL_DEPOSIT, user);
        vm.stopPrank();

        console.log("=== Before Withdrawal ==.");
        _logPositions();

        // Withdraw 30%
        uint256 sharesToWithdraw = (strategyVault.balanceOf(user) * 30) / 100;

        vm.prank(user);
        uint256 assetsWithdrawn = strategyVault.redeem(sharesToWithdraw, user, user);

        console.log("\\n=== After Withdrawal ==.");
        console.log("Assets withdrawn:", assetsWithdrawn);
        _logPositions();

        // Should receive roughly 30% of deposit
        assertApproxEqRel(
            assetsWithdrawn,
            (INITIAL_DEPOSIT * 30) / 100,
            0.05e18,
            "Incorrect withdrawal amount"
        );

        // User should have received reUSD
        uint256 userReUSD = IERC20(REUSD).balanceOf(user);
        assertGt(userReUSD, 0, "User didn't receive reUSD");
    }

    function testFork_FullWithdrawal() public {
        if (!hasUserSwapPath) {
            console.log("Skipping withdrawal test: set RESUPPLY_SWAP_PATH or RESUPPLY_SWAP_ROUTE.");
            return;
        }
        // Setup position
        vm.startPrank(user);
        IERC20(REUSD).approve(address(loopStrategy), INITIAL_DEPOSIT);
        strategyVault.deposit(INITIAL_DEPOSIT, user);
        vm.stopPrank();

        console.log("=== Before Full Withdrawal ==.");
        _logPositions();

        // Withdraw everything
        uint256 shares = strategyVault.balanceOf(user);

        vm.prank(user);
        uint256 assetsWithdrawn = strategyVault.redeem(shares, user, user);

        console.log("\\n=== After Full Withdrawal ==.");
        console.log("Assets withdrawn:", assetsWithdrawn);
        _logPositions();

        // Should get back close to initial deposit
        assertApproxEqRel(
            assetsWithdrawn,
            INITIAL_DEPOSIT,
            0.05e18,
            "Incorrect full withdrawal"
        );

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
        console.log("sreUSD exchange rate:", exchangeRate);
        assertGt(exchangeRate, 0, "Invalid sreUSD exchange rate");

        // Check crvUSD exists
        uint256 crvUSDSupply = IERC20(CRVUSD).totalSupply();
        assertGt(crvUSDSupply, 0, "crvUSD not found");

        console.log("Real protocol checks passed");
    }

    /*//////////////////////////////////////////////////////////////
                            HELPER FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function _logPositions() internal view {
        console.log("\\n--- Strategy Positions (Real Protocols) ---");

        // Idle balances
        console.log("Idle reUSD:", IERC20(REUSD).balanceOf(address(loopStrategy)));
        console.log("Idle crvUSD:", IERC20(CRVUSD).balanceOf(address(loopStrategy)));
        console.log("Idle sreUSD:", IERC20(SREUSD).balanceOf(address(loopStrategy)));

        // Note: Actual position data will depend on real protocol interfaces
        // This is a simplified version - expand based on actual protocol ABIs

        console.log("-------------------------\\n");
    }

    function _requiredContractsPresent() internal view returns (bool) {
        return REUSD.code.length > 0
            && SREUSD.code.length > 0
            && CRVUSD.code.length > 0
            && CURVE_LLAMMA.code.length > 0
            && RESUPPLY.code.length > 0;
    }

    function _resolveSwapRoute(address tokenIn, address tokenOut) internal view returns (bytes memory route) {
        address registry = IResupplySwapper(SWAPPER).registry();
        bytes4[] memory selectors = new bytes4[](4);
        selectors[0] = bytes4(keccak256("getRoute(address,address)"));
        selectors[1] = bytes4(keccak256("route(address,address)"));
        selectors[2] = bytes4(keccak256("getPath(address,address)"));
        selectors[3] = bytes4(keccak256("path(address,address)"));

        for (uint256 i = 0; i < selectors.length; i++) {
            (bool ok, bytes memory data) = registry.staticcall(
                abi.encodeWithSelector(selectors[i], tokenIn, tokenOut)
            );
            if (!ok || data.length < 64) continue;
            bytes memory decoded = _decodeBytesReturn(data);
            if (decoded.length > 0) {
                return decoded;
            }
        }
    }

    function _resolveSwapPath(address tokenIn, address tokenOut) internal view returns (address[] memory) {
        bytes memory route = _resolveSwapRoute(tokenIn, tokenOut);
        if (route.length > 0) {
            try IResupplySwapper(SWAPPER).encode(route, tokenIn, tokenOut) returns (address[] memory encoded) {
                return encoded;
            } catch {}
        }

        address[] memory direct = new address[](2);
        direct[0] = tokenIn;
        direct[1] = tokenOut;
        if (_canDecodePath(direct)) {
            return direct;
        }

        address[] memory viaCrvUSD = new address[](3);
        viaCrvUSD[0] = tokenIn;
        viaCrvUSD[1] = CRVUSD;
        viaCrvUSD[2] = tokenOut;
        if (_canDecodePath(viaCrvUSD)) {
            return viaCrvUSD;
        }

        return new address[](0);
    }

    function _canDecodePath(address[] memory path) internal view returns (bool) {
        try IResupplySwapper(SWAPPER).decode(path) returns (bytes memory) {
            return true;
        } catch {
            return false;
        }
    }

    function _defaultSwapPath() internal pure returns (address[] memory path) {
        // Odos route for full withdrawal with 10,000 reUSD deposit at block 24100306.
        path = new address[](40);
        path[0] = address(uint160(0x007430f11eeb64a4ce50c8f92177485d34c48da72c));
        path[1] = address(uint160(0x0000000000000000000000000000000000000002dd));
        path[2] = address(uint160(0x0083bd37f900017430f11eeb64a4ce50c8f9217748));
        path[3] = address(uint160(0x005d34c48da72c000157ab1e0003f623289cd798b1));
        path[4] = address(uint160(0x00824be09a793e4bec0b2875298f9954daf2b0c7bf));
        path[5] = address(uint160(0x000a0abb4dae5d60d3000000028f5c0001365084b0));
        path[6] = address(uint160(0x005fa7d5028346bd21d842ed0601bab5b800000001));
        path[7] = address(uint160(0x00d42535cda82a4569ba7209857446222abd14a82c));
        path[8] = address(uint160(0x000000000013050516004601000102030003384969));
        path[9] = address(uint160(0x00e2000003abfe0d50460200040305010267030001));
        path[10] = address(uint160(0x000603010005e4a667230001046704000107050100));
        path[11] = address(uint160(0x000600020067030901090301000200000846010b0b));
        path[12] = address(uint160(0x000c0d010467040f010f1001000667021200081200));
        path[13] = address(uint160(0x000102670301000a0d010004670301001113010000));
        path[14] = address(uint160(0x00670301011405010008670301000e150100ff0000));
        path[15] = address(uint160(0x000000000000000000000000000000000000000000));
        path[16] = address(uint160(0x0000000000007430f11eeb64a4ce50c8f92177485d));
        path[17] = address(uint160(0x0034c48da72c7430f11eeb64a4ce50c8f92177485d));
        path[18] = address(uint160(0x0034c48da72cf939e0a03fb07f59a73314e73794be));
        path[19] = address(uint160(0x000e57ac1b4e0655977feb2f289a4ab78af67bab0d));
        path[20] = address(uint160(0x0017aab843670655977feb2f289a4ab78af67bab0d));
        path[21] = address(uint160(0x0017aab8436713e12bb0e6a2f1a3d6901a59a9d585));
        path[22] = address(uint160(0x00e89a6243e1ff17dab22f1e61078aba2623c89ce6));
        path[23] = address(uint160(0x00110e878b3c74345504eaea3d9408fc69ae7eb2d1));
        path[24] = address(uint160(0x004095643c5b635ef0056a597d13863b73825cca29));
        path[25] = address(uint160(0x00723657859548d670d189b4b48757992d36897bca));
        path[26] = address(uint160(0x006e3f889040b45ad160634c528cc3d2926d980710));
        path[27] = address(uint160(0x004fa3157305865377367054516e17014ccded1e7d));
        path[28] = address(uint160(0x00814edc9ce4b45ad160634c528cc3d2926d980710));
        path[29] = address(uint160(0x004fa3157305ed785af60bed688baa8990cd5c4166));
        path[30] = address(uint160(0x00221599a441f292eb6c5dcb693eaaf392d0562a01));
        path[31] = address(uint160(0x00c3710e5978cacd6fd266af91b8aed52accc382b4));
        path[32] = address(uint160(0x00e165586e29b0ef04ace97d350e24efa5139d2590));
        path[33] = address(uint160(0x00d26a61a8dc40d16fc0246ad3160ccc09b8d0d3a2));
        path[34] = address(uint160(0x00cd28ae6c2f085780639cc2cacd35e474e71f4d00));
        path[35] = address(uint160(0x000e2405d8f6c522a6606bba746d7960404f22a3db));
        path[36] = address(uint160(0x00936b6f4f50cf62f905562626cfcdd2261162a51f));
        path[37] = address(uint160(0x00d02fc9c5b6000000000000000000000000000000));
        path[38] = address(uint160(0x000000000000000000000000000000000000000000));
        path[39] = address(uint160(0x0057ab1e0003f623289cd798b1824be09a793e4bec));
    }

    function _decodeBytesReturn(bytes memory data) internal pure returns (bytes memory decoded) {
        uint256 offset;
        uint256 length;
        assembly {
            offset := mload(add(data, 0x20))
        }
        if (offset != 0x20 || data.length < 0x40) {
            return new bytes(0);
        }
        assembly {
            length := mload(add(data, 0x40))
        }
        if (data.length < 0x40 + length) {
            return new bytes(0);
        }
        decoded = new bytes(length);
        for (uint256 i = 0; i < length; i++) {
            decoded[i] = data[0x60 + i];
        }
    }
}
