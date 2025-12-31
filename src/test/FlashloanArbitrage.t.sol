// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.18;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

// Balancer Flashloan interface
interface IBalancerVault {
    function flashLoan(
        address recipient,
        address[] memory tokens,
        uint256[] memory amounts,
        bytes memory userData
    ) external;
}

// Curve pool interface for swaps
interface ICurvePool {
    function exchange(int128 i, int128 j, uint256 dx, uint256 min_dy) external returns (uint256);
    function get_dy(int128 i, int128 j, uint256 dx) external view returns (uint256);
}

// Curve LLAMMA AMM interface (for crvUSD <> sreUSD)
interface ILLAMMAAMU {
    function exchange(uint256 i, uint256 j, uint256 in_amount, uint256 min_amount) external returns (uint256);
    function get_dy(uint256 i, uint256 j, uint256 in_amount) external view returns (uint256);
    function coins(uint256 i) external view returns (address);
}

/**
 * @title FlashloanArbitrageTest
 * @notice Test flashloan arbitrage: USDC -> crvUSD -> sreUSD -> reUSD -> USDC
 * @dev Run with: forge test --match-contract FlashloanArbitrageTest -vvv
 */
contract FlashloanArbitrageTest is Test {
    // Mainnet addresses
    address public constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address public constant CRVUSD = 0xf939E0A03FB07F59A73314E73794Be0E57ac1b4E;
    address public constant SREUSD = 0x557AB1e003951A73c12D16F0fEA8490E39C33C35;
    address public constant REUSD = 0x57aB1E0003F623289CD798B1824Be09a793e4Bec;
    address public constant FXUSD = 0x085780639CC2cACd35E474e71f4d000e2405d8f6;

    // Balancer vault for flashloans
    address public constant BALANCER_VAULT = 0xBA12222222228d8Ba445958a75a0704d566BF2C8;

    // Curve pools
    address public constant USDC_CRVUSD_POOL = 0x4DEcE678ceceb27446b35C672dC7d61F30bAD69E; // Curve USDC/crvUSD
    address public constant LLAMMA_AMM = 0x437722a015eEFB96A6A2a882F3b27cAf3C2BC41C; // LLAMMA AMM for sreUSD/crvUSD (from controller.amm())

    // reUSD/fxUSD Curve pool
    address public constant REUSD_FXUSD_POOL = 0xb0ef04ACE97d350E24Efa5139d2590D26a61A8Dc;

    // fxUSD/USDC pool
    address public constant FXUSD_USDC_POOL = 0x5018BE882DccE5E3F2f3B0913AE2096B9b3fB61f;

    uint256 public constant FLASH_AMOUNT = 100_000 * 1e6; // 100k USDC
    uint256 public constant DEFAULT_FORK_BLOCK = 24107304;

    bool internal inFlashloan;
    uint256 internal flashloanAmount;

    function setUp() public {
        string memory rpcUrl = vm.envOr("ANVIL_RPC_URL", string("http://127.0.0.1:8545"));
        uint256 forkBlock = vm.envOr("MAINNET_FORK_BLOCK", DEFAULT_FORK_BLOCK);
        vm.createSelectFork(rpcUrl, forkBlock);

        // Labels
        vm.label(USDC, "USDC");
        vm.label(CRVUSD, "crvUSD");
        vm.label(SREUSD, "sreUSD");
        vm.label(REUSD, "reUSD");
        vm.label(FXUSD, "fxUSD");
        vm.label(BALANCER_VAULT, "Balancer");
    }

    function testFlashloanArbitrage() public {
        emit log_named_decimal_uint("Flash amount (USDC)", FLASH_AMOUNT, 6);

        uint256 usdcBefore = IERC20(USDC).balanceOf(address(this));

        // Execute flashloan
        _executeFlashloan(FLASH_AMOUNT);

        uint256 usdcAfter = IERC20(USDC).balanceOf(address(this));

        emit log("=== Results ===");
        emit log_named_decimal_uint("USDC before", usdcBefore, 6);
        emit log_named_decimal_uint("USDC after", usdcAfter, 6);

        if (usdcAfter > usdcBefore) {
            uint256 profit = usdcAfter - usdcBefore;
            emit log_named_decimal_uint("PROFIT", profit, 6);
        } else {
            uint256 loss = usdcBefore - usdcAfter;
            emit log_named_decimal_uint("LOSS", loss, 6);
        }
    }

    function testQuoteArbitragePath() public {
        // Just quote the path without executing
        uint256 usdcAmount = FLASH_AMOUNT;

        emit log("=== Quoting Arbitrage Path ===");
        emit log_named_decimal_uint("Start: USDC", usdcAmount, 6);

        // 1. USDC -> crvUSD
        uint256 crvUSDOut = _quoteCrvUSD(usdcAmount);
        emit log_named_decimal_uint("After USDC->crvUSD", crvUSDOut, 18);

        // 2. crvUSD -> sreUSD (via LLAMMA AMM)
        uint256 sreUSDOut = _quoteSreUSD(crvUSDOut);
        emit log_named_decimal_uint("After crvUSD->sreUSD", sreUSDOut, 18);

        // 3. sreUSD -> reUSD (redeem from vault)
        uint256 reUSDOut = IERC4626(SREUSD).previewRedeem(sreUSDOut);
        emit log_named_decimal_uint("After sreUSD->reUSD", reUSDOut, 18);

        // 4. reUSD -> fxUSD
        uint256 fxUSDOut = _quoteReUSDToFxUSD(reUSDOut);
        emit log_named_decimal_uint("After reUSD->fxUSD", fxUSDOut, 18);

        // 5. fxUSD -> USDC
        uint256 finalUSDC = _quoteFxUSDToUSDC(fxUSDOut);
        emit log_named_decimal_uint("Final USDC", finalUSDC, 6);

        emit log("=== Summary ===");
        if (finalUSDC > usdcAmount) {
            emit log_named_decimal_uint("PROFIT", finalUSDC - usdcAmount, 6);
        } else {
            emit log_named_decimal_uint("LOSS", usdcAmount - finalUSDC, 6);
        }
    }

    function _quoteReUSDToFxUSD(uint256 reUSDAmount) internal view returns (uint256) {
        // reUSD=0, fxUSD=1
        try ICurvePool(REUSD_FXUSD_POOL).get_dy(0, 1, reUSDAmount) returns (uint256 out) {
            return out;
        } catch {
            return 0;
        }
    }

    function _quoteFxUSDToUSDC(uint256 fxUSDAmount) internal view returns (uint256) {
        // fxUSD=1, USDC=0
        try ICurvePool(FXUSD_USDC_POOL).get_dy(1, 0, fxUSDAmount) returns (uint256 out) {
            return out;
        } catch {
            return 0;
        }
    }

    function _executeFlashloan(uint256 amount) internal {
        flashloanAmount = amount;
        inFlashloan = true;

        address[] memory tokens = new address[](1);
        tokens[0] = USDC;

        uint256[] memory amounts = new uint256[](1);
        amounts[0] = amount;

        IBalancerVault(BALANCER_VAULT).flashLoan(
            address(this),
            tokens,
            amounts,
            ""
        );

        inFlashloan = false;
    }

    // Balancer flashloan callback
    function receiveFlashLoan(
        address[] memory tokens,
        uint256[] memory amounts,
        uint256[] memory feeAmounts,
        bytes memory /* userData */
    ) external {
        require(msg.sender == BALANCER_VAULT, "Not Balancer");
        require(inFlashloan, "Not in flashloan");

        uint256 usdcReceived = amounts[0];
        uint256 fee = feeAmounts[0];
        uint256 amountOwed = usdcReceived + fee;

        emit log_named_decimal_uint("Flashloan received (USDC)", usdcReceived, 6);
        emit log_named_decimal_uint("Flashloan fee", fee, 6);

        // Execute arbitrage
        uint256 usdcOut = _executeArbitrage(usdcReceived);

        emit log_named_decimal_uint("USDC after arb", usdcOut, 6);
        emit log_named_decimal_uint("Amount owed", amountOwed, 6);

        // Repay flashloan
        IERC20(USDC).transfer(BALANCER_VAULT, amountOwed);
    }

    function _executeArbitrage(uint256 usdcAmount) internal returns (uint256) {
        // 1. USDC -> crvUSD
        IERC20(USDC).approve(USDC_CRVUSD_POOL, usdcAmount);
        uint256 crvUSDOut = ICurvePool(USDC_CRVUSD_POOL).exchange(
            0, // USDC index
            1, // crvUSD index
            usdcAmount,
            0  // min out (set to 0 for testing, use slippage protection in prod)
        );
        emit log_named_decimal_uint("Got crvUSD", crvUSDOut, 18);

        // 2. crvUSD -> sreUSD (via LLAMMA AMM)
        IERC20(CRVUSD).approve(LLAMMA_AMM, crvUSDOut);
        uint256 sreUSDOut = ILLAMMAAMU(LLAMMA_AMM).exchange(
            0, // crvUSD index (need to verify)
            1, // sreUSD index
            crvUSDOut,
            0  // min out
        );
        emit log_named_decimal_uint("Got sreUSD", sreUSDOut, 18);

        // 3. sreUSD -> reUSD (redeem from ERC4626 vault)
        uint256 reUSDOut = IERC4626(SREUSD).redeem(sreUSDOut, address(this), address(this));
        emit log_named_decimal_uint("Got reUSD", reUSDOut, 18);

        // 4. reUSD -> USDC
        // TODO: Find the right pool/route for this
        // For now, try a direct curve pool if it exists
        uint256 usdcOut = _swapReUSDToUSDC(reUSDOut);

        return usdcOut;
    }

    function _swapReUSDToUSDC(uint256 reUSDAmount) internal returns (uint256) {
        // Route: reUSD -> fxUSD -> USDC

        // Step 1: reUSD -> fxUSD (reUSD=0, fxUSD=1)
        IERC20(REUSD).approve(REUSD_FXUSD_POOL, reUSDAmount);
        uint256 fxUSDOut = ICurvePool(REUSD_FXUSD_POOL).exchange(
            0, // reUSD index
            1, // fxUSD index
            reUSDAmount,
            0  // min out
        );
        emit log_named_decimal_uint("Got fxUSD (from reUSD)", fxUSDOut, 18);

        // Step 2: fxUSD -> USDC (fxUSD=1, USDC=0)
        IERC20(FXUSD).approve(FXUSD_USDC_POOL, fxUSDOut);
        uint256 usdcOut = ICurvePool(FXUSD_USDC_POOL).exchange(
            1, // fxUSD index
            0, // USDC index
            fxUSDOut,
            0  // min out
        );
        emit log_named_decimal_uint("Got USDC (final)", usdcOut, 6);

        return usdcOut;
    }

    function _quoteCrvUSD(uint256 usdcAmount) internal view returns (uint256) {
        try ICurvePool(USDC_CRVUSD_POOL).get_dy(0, 1, usdcAmount) returns (uint256 out) {
            return out;
        } catch {
            return 0;
        }
    }

    function _quoteSreUSD(uint256 crvUSDAmount) internal view returns (uint256) {
        try ILLAMMAAMU(LLAMMA_AMM).get_dy(0, 1, crvUSDAmount) returns (uint256 out) {
            return out;
        } catch {
            return 0;
        }
    }
}
