// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.18;

import "forge-std/Test.sol";
import {SreUSDCrvUSDLoopStrategy} from "../SreUSDCrvUSDLoopStrategy.sol";

interface IResupply {
    function borrow(uint256 _borrowAmount, uint256 _underlyingAmount, address _receiver) external returns (uint256);
    function repay(uint256 _shares, address _borrower) external returns (uint256 _amountRepaid);
    function removeCollateral(uint256 _collateralAmount, address _receiver) external;
    function toBorrowAmount(uint256 _shares, bool _roundUp, bool _previewInterest) external view returns (uint256);
    function userBorrowShares(address _account) external view returns (uint256);
    function userCollateralBalance(address _account) external view returns (uint256);
    function collateral() external view returns (address);
}

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function symbol() external view returns (string memory);
    function approve(address, uint256) external returns (bool);
    function transfer(address, uint256) external returns (bool);
}

interface ICurvePool {
    function exchange(int128 i, int128 j, uint256 dx, uint256 min_dy) external returns (uint256);
    function get_dy(int128 i, int128 j, uint256 dx) external view returns (uint256);
    function coins(uint256 i) external view returns (address);
}

interface ICurveRouter {
    function exchange(
        address[11] calldata _route,
        uint256[5][5] calldata _swap_params,
        uint256 _amount,
        uint256 _expected
    ) external returns (uint256);

    function get_dy(
        address[11] calldata _route,
        uint256[5][5] calldata _swap_params,
        uint256 _amount
    ) external view returns (uint256);
}

interface IStrategy {
    function deposit(uint256 assets, address receiver) external returns (uint256);
    function report() external returns (uint256, uint256);
    function totalAssets() external view returns (uint256);
}

interface ITokenizedStrategy {
    function setKeeper(address _keeper) external;
}


interface IERC4626 {
    function deposit(uint256 assets, address receiver) external returns (uint256);
    function asset() external view returns (address);
    function convertToAssets(uint256 shares) external view returns (uint256);
    function convertToShares(uint256 assets) external view returns (uint256);
}

contract LooperIntegrationTest is Test {
    // Core protocol addresses
    address constant RESUPPLY_PAIR = 0xD42535Cda82a4569BA7209857446222ABd14A82c;
    address constant REUSD = 0x57aB1E0003F623289CD798B1824Be09a793e4Bec;
    address constant CRVUSD = 0xf939E0A03FB07F59A73314E73794Be0E57ac1b4E;

    // Reward token addresses
    address constant CRV = 0xD533a949740bb3306d119CC777fa900bA034cd52;
    address constant CVX = 0x4e3FBD56CD56c3e72c1403e103b45Db9da5B9D2B;
    address constant RSUP = 0x419905009e4656fdC02418C7Df35B1E61Ed5F726; // Resupply token

    // Curve pools
    address constant CRV_CRVUSD_POOL = 0x4eBdF703948ddCEA3B11f675B4D1Fba9d2414A14; // CRV/crvUSD
    address constant CVX_ETH_POOL = 0xB576491F1E6e5E62f1d8F26062Ee822B40B0E0d4;    // CVX/ETH
    address constant RSUP_WETH_POOL = 0xEe351f12EAE8C2B8B9d1B9BFd3c5dd565234578d;  // RSUP/WETH (Curve)
    address constant TRICRV_POOL = 0x4eBdF703948ddCEA3B11f675B4D1Fba9d2414A14;     // ETH/crvUSD (tricrypto)

    // Uniswap V3
    address constant UNISWAP_V3_ROUTER = 0xE592427A0AEce92De3Edee1F18E0157C05861564;
    address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;

    // scrvUSD (ERC4626 vault for crvUSD) and swap pool
    address constant SCRVUSD = 0x0655977FEb2f289A4aB78af67BAB0d17aAb84367;
    address constant SCRVUSD_REUSD_POOL = 0xc522A6606BBA746d7960404F22a3DB936B6F4F50;

    function setUp() public {
        vm.createSelectFork("http://127.0.0.1:8545");
    }
    
    function testResupply_toBorrowAmount_isReUSD() public {
        // Get collateral vault info
        address collateralVault = IResupply(RESUPPLY_PAIR).collateral();
        emit log_named_address("Collateral vault", collateralVault);
        emit log_named_string("Collateral symbol", IERC20(collateralVault).symbol());

        address underlying = IERC4626(collateralVault).asset();
        emit log_named_address("Underlying of collateral vault", underlying);
        emit log_named_string("Underlying symbol", IERC20(underlying).symbol());

        // Setup: give ourselves crvUSD (raw, not wrapped)
        deal(CRVUSD, address(this), 10000e18);
        emit log_named_uint("crvUSD balance", IERC20(CRVUSD).balanceOf(address(this)));

        // Approve crvUSD to Resupply (it deposits internally to cvcrvUSD)
        IERC20(CRVUSD).approve(RESUPPLY_PAIR, type(uint256).max);

        uint256 reUSDBefore = IERC20(REUSD).balanceOf(address(this));
        emit log_named_uint("reUSD before borrow", reUSDBefore);

        // Borrow 7,531.456789 reUSD against 10,000 crvUSD collateral
        uint256 borrowAmount = 7531456789000000000000; // 7531.456789e18
        IResupply(RESUPPLY_PAIR).borrow(borrowAmount, 10000e18, address(this));

        uint256 reUSDAfter = IERC20(REUSD).balanceOf(address(this));
        emit log_named_uint("reUSD after borrow", reUSDAfter);
        emit log_named_uint("reUSD received", reUSDAfter - reUSDBefore);

        // Check borrow shares and convert back
        uint256 borrowShares = IResupply(RESUPPLY_PAIR).userBorrowShares(address(this));
        uint256 convertedAmount = IResupply(RESUPPLY_PAIR).toBorrowAmount(borrowShares, true, false);
        emit log_named_uint("Borrow shares", borrowShares);
        emit log_named_uint("toBorrowAmount (should be ~7531.456789e18 reUSD)", convertedAmount);

        // Confirm: we borrowed reUSD and toBorrowAmount returns reUSD
        assertEq(reUSDAfter - reUSDBefore, borrowAmount, "Should have received exact reUSD");
        assertApproxEqRel(convertedAmount, borrowAmount, 0.0001e18, "toBorrowAmount should match borrowed reUSD");
    }

    function testResupply_partialWithdraw_maintainsSolvency() public {
        // Setup: borrow at ~75% LTV (safe margin)
        deal(CRVUSD, address(this), 10000e18);
        IERC20(CRVUSD).approve(RESUPPLY_PAIR, type(uint256).max);
        IERC20(REUSD).approve(RESUPPLY_PAIR, type(uint256).max);

        IResupply(RESUPPLY_PAIR).borrow(7500e18, 10000e18, address(this));

        address collateralVault = IResupply(RESUPPLY_PAIR).collateral();

        // userCollateralBalance modifies state (claims rewards), use low-level call
        uint256 collateralShares = _getUserCollateralBalance(address(this));
        uint256 initialCollateralUnderlying = IERC4626(collateralVault).convertToAssets(collateralShares);

        emit log("=== Initial Position ===");
        emit log_named_uint("Collateral shares", collateralShares);
        emit log_named_uint("Collateral underlying (crvUSD)", initialCollateralUnderlying);

        // Repay 50% of debt
        uint256 repayShares = IResupply(RESUPPLY_PAIR).userBorrowShares(address(this)) / 2;
        deal(REUSD, address(this), 10000e18);
        IResupply(RESUPPLY_PAIR).repay(repayShares, address(this));

        emit log("=== After Partial Repay (50%) ===");

        // Calculate max withdrawable collateral while maintaining 95% LTV
        uint256 debtAmount = IResupply(RESUPPLY_PAIR).toBorrowAmount(
            IResupply(RESUPPLY_PAIR).userBorrowShares(address(this)), true, false
        );
        emit log_named_uint("Remaining debt (reUSD)", debtAmount);

        uint256 minCollateralUnderlying = (debtAmount * 10000) / 9500;
        uint256 maxWithdrawableUnderlying = initialCollateralUnderlying - minCollateralUnderlying;
        uint256 maxWithdrawableShares = IERC4626(collateralVault).convertToShares(maxWithdrawableUnderlying);

        emit log_named_uint("Min collateral needed (crvUSD)", minCollateralUnderlying);
        emit log_named_uint("Max withdrawable (shares)", maxWithdrawableShares);

        // Try to withdraw too much - should revert
        vm.expectRevert();
        IResupply(RESUPPLY_PAIR).removeCollateral(maxWithdrawableShares + maxWithdrawableShares / 10, address(this));
        emit log("Correctly reverted when trying to withdraw too much");

        // Withdraw safe amount (95% of max)
        IResupply(RESUPPLY_PAIR).removeCollateral(maxWithdrawableShares * 95 / 100, address(this));

        emit log("=== After Safe Withdrawal ===");
        uint256 finalCollateralShares = _getUserCollateralBalance(address(this));
        uint256 finalCollateralUnderlying = IERC4626(collateralVault).convertToAssets(finalCollateralShares);
        uint256 finalLTV = (debtAmount * 10000) / finalCollateralUnderlying;

        emit log_named_uint("Remaining collateral (crvUSD)", finalCollateralUnderlying);
        emit log_named_uint("Final LTV (bps)", finalLTV);

        // Verify LTV is still safe
        assertLe(finalLTV, 9500, "LTV should be at or below 95%");
        assertGt(finalLTV, 0, "Should still have some LTV");
    }

    function testResupply_userCollateralBalance_unchangedByDebtRepay() public {
        // Setup: borrow at ~75% LTV
        deal(CRVUSD, address(this), 10000e18);
        IERC20(CRVUSD).approve(RESUPPLY_PAIR, type(uint256).max);
        IERC20(REUSD).approve(RESUPPLY_PAIR, type(uint256).max);

        IResupply(RESUPPLY_PAIR).borrow(7500e18, 10000e18, address(this));

        // Check collateral BEFORE repaying debt
        uint256 collateralBefore = _getUserCollateralBalance(address(this));
        uint256 debtBefore = IResupply(RESUPPLY_PAIR).toBorrowAmount(
            IResupply(RESUPPLY_PAIR).userBorrowShares(address(this)), true, false
        );

        emit log("=== Before Debt Repay ===");
        emit log_named_uint("Collateral shares", collateralBefore);
        emit log_named_uint("Debt (reUSD)", debtBefore);

        // Repay ALL debt
        deal(REUSD, address(this), debtBefore + 1000e18); // Extra to cover any interest
        uint256 allShares = IResupply(RESUPPLY_PAIR).userBorrowShares(address(this));
        IResupply(RESUPPLY_PAIR).repay(allShares, address(this));

        // Check collateral AFTER repaying debt
        uint256 collateralAfter = _getUserCollateralBalance(address(this));
        uint256 debtAfter = IResupply(RESUPPLY_PAIR).toBorrowAmount(
            IResupply(RESUPPLY_PAIR).userBorrowShares(address(this)), true, false
        );

        emit log("=== After Full Debt Repay ===");
        emit log_named_uint("Collateral shares", collateralAfter);
        emit log_named_uint("Debt (reUSD)", debtAfter);

        // Collateral should be UNCHANGED by debt repayment
        assertEq(collateralAfter, collateralBefore, "Collateral should not change when repaying debt");
        assertEq(debtAfter, 0, "Debt should be zero after full repay");

        emit log("CONFIRMED: userCollateralBalance is NOT affected by debt repayment");
    }

    // userCollateralBalance modifies state (claims rewards), need low-level call
    function _getUserCollateralBalance(address user) internal returns (uint256) {
        (bool success, bytes memory data) = RESUPPLY_PAIR.call(
            abi.encodeWithSignature("userCollateralBalance(address)", user)
        );
        require(success, "userCollateralBalance failed");
        return abi.decode(data, (uint256));
    }

    /// @notice Confirms that sreUSD shares != underlying value when exchange rate > 1
    /// This test demonstrates why we must use convertToAssets() for accurate LTV calculations
    function testSreUSD_sharesNotEqualToValue_whenAppreciated() public {
        // sreUSD ERC4626 vault (mainnet address)
        address sreUSD = 0x557AB1e003951A73c12D16F0fEA8490E39C33C35;
        emit log_named_address("sreUSD address", sreUSD);

        // Get current exchange rate
        uint256 shareAmount = 1000e18; // 1000 shares
        uint256 assetValue = IERC4626(sreUSD).convertToAssets(shareAmount);

        emit log("=== sreUSD Exchange Rate Test ===");
        emit log_named_uint("Shares", shareAmount);
        emit log_named_uint("Underlying value (reUSD)", assetValue);
        emit log_named_uint("Exchange rate (scaled by 1e18)", (assetValue * 1e18) / shareAmount);

        // If sreUSD has appreciated, 1000 shares > 1000 reUSD
        if (assetValue > shareAmount) {
            emit log("sreUSD HAS appreciated: shares < underlying value");
            emit log_named_uint("Extra value per 1000 shares (reUSD)", assetValue - shareAmount);

            // Demonstrate the LTV calculation error
            uint256 debt = 950e18; // Assume 950 crvUSD debt

            // WRONG: Using shares directly (old buggy code)
            uint256 wrongLTV = (debt * 10000) / shareAmount;

            // CORRECT: Using converted value
            uint256 correctLTV = (debt * 10000) / assetValue;

            emit log("=== LTV Calculation Comparison ===");
            emit log_named_uint("Debt (crvUSD)", debt);
            emit log_named_uint("WRONG LTV (using shares directly)", wrongLTV);
            emit log_named_uint("CORRECT LTV (using convertToAssets)", correctLTV);
            emit log_named_uint("LTV difference (bps)", wrongLTV - correctLTV);

            // The wrong calculation overstates LTV, which would cause:
            // 1. Incorrect withdrawable amount calculations
            // 2. Potentially leaving money on the table during withdrawals
            assertGt(wrongLTV, correctLTV, "Wrong LTV should be higher (overstated risk)");
        } else {
            emit log("sreUSD has NOT appreciated yet (rate = 1:1)");
            assertEq(assetValue, shareAmount, "At 1:1, shares should equal value");
        }
    }

    /*//////////////////////////////////////////////////////////////
                        HARVEST INTEGRATION TEST
    //////////////////////////////////////////////////////////////*/

    /// @notice Full end-to-end harvest test selling all 3 reward tokens (CRV, CVX, RSUP)
    function testHarvest_SellsAllRewardTokens() public {
        // Deploy strategy with real mainnet addresses
        address SREUSD = 0x557AB1e003951A73c12D16F0fEA8490E39C33C35;
        address CURVE_LLAMMA = 0x4F79Fe450a2BAF833E8f50340BD230f5A3eCaFe9;

        SreUSDCrvUSDLoopStrategy strategy = new SreUSDCrvUSDLoopStrategy(
            REUSD,
            SREUSD,
            CRVUSD,
            CURVE_LLAMMA,
            RESUPPLY_PAIR,
            "Test Loop Strategy"
        );

        address strategyAddr = address(strategy);
        emit log_named_address("Strategy deployed", strategyAddr);

        // Setup roles
        ITokenizedStrategy(strategyAddr).setKeeper(address(this));

        // Give ourselves reUSD and deposit
        uint256 depositAmount = 10_000e18;
        deal(REUSD, address(this), depositAmount);
        IERC20(REUSD).approve(strategyAddr, depositAmount);
        IStrategy(strategyAddr).deposit(depositAmount, address(this));
        emit log_named_decimal_uint("Deposited reUSD", depositAmount, 18);

        // === Configure reward tokens ===

        // 1. CRV -> crvUSD via tricrypto pool (direct swap)
        // Tricrypto pool: coin0=crvUSD, coin1=WETH, coin2=CRV
        bytes memory crvPath = abi.encode(uint256(2), uint256(0)); // CRV -> crvUSD
        strategy.addRewardToken(CRV, CRV_CRVUSD_POOL, crvPath, 2); // dexType 2 = Curve tricrypto
        emit log("Configured CRV -> crvUSD (Curve tricrypto)");

        // 2. CVX -> WETH via Curve CVX/ETH pool
        // CVX/ETH pool (0xB576491F1E6e5E62f1d8F26062Ee822B40B0E0d4): coin0=WETH, coin1=CVX
        bytes memory cvxPath = abi.encode(uint256(1), uint256(0)); // CVX -> WETH
        strategy.addRewardToken(CVX, CVX_ETH_POOL, cvxPath, 2); // dexType 2 = Curve tricrypto
        emit log("Configured CVX -> WETH (Curve)");

        // 3. RSUP -> WETH via Curve RSUP/WETH pool
        // RSUP/WETH pool: coin0=WETH, coin1=RSUP
        bytes memory rsupPath = abi.encode(uint256(1), uint256(0)); // RSUP -> WETH
        strategy.addRewardToken(RSUP, RSUP_WETH_POOL, rsupPath, 2); // dexType 2 = Curve tricrypto
        emit log("Configured RSUP -> WETH (Curve)");

        // 4. WETH -> crvUSD via tricrypto (MUST be last since CVX and RSUP produce WETH)
        // Tricrypto pool: coin0=crvUSD, coin1=WETH
        bytes memory wethPath = abi.encode(uint256(1), uint256(0)); // WETH -> crvUSD
        strategy.addRewardToken(WETH, CRV_CRVUSD_POOL, wethPath, 2); // dexType 2 = Curve tricrypto
        emit log("Configured WETH -> crvUSD (Curve tricrypto)");

        // Configure crvUSD -> reUSD swap (via scrvUSD)
        // scrvUSD = 0x0655977FEb2f289A4aB78af67BAB0d17aAb84367 (ERC4626 vault for crvUSD)
        // Pool = 0xc522A6606BBA746d7960404F22a3DB936B6F4F50 (scrvUSD/reUSD, index 1 -> 0)
        strategy.setRewardSwapPool(SCRVUSD, SCRVUSD_REUSD_POOL);
        emit log("Configured crvUSD -> scrvUSD -> reUSD swap");

        // === Simulate rewards ===
        uint256 crvReward = 1000e18;
        uint256 cvxReward = 500e18;
        uint256 rsupReward = 200e18;

        deal(CRV, strategyAddr, crvReward);
        deal(CVX, strategyAddr, cvxReward);
        deal(RSUP, strategyAddr, rsupReward);

        emit log("=== Before Harvest ===");
        uint256 totalAssetsBefore = IStrategy(strategyAddr).totalAssets();
        emit log_named_decimal_uint("totalAssets BEFORE", totalAssetsBefore, 18);
        emit log_named_decimal_uint("CRV in strategy", IERC20(CRV).balanceOf(strategyAddr), 18);
        emit log_named_decimal_uint("CVX in strategy", IERC20(CVX).balanceOf(strategyAddr), 18);
        emit log_named_decimal_uint("RSUP in strategy", IERC20(RSUP).balanceOf(strategyAddr), 18);
        emit log_named_decimal_uint("crvUSD in strategy", IERC20(CRVUSD).balanceOf(strategyAddr), 18);
        emit log_named_decimal_uint("reUSD in strategy", IERC20(REUSD).balanceOf(strategyAddr), 18);

        // === Harvest ===
        IStrategy(strategyAddr).report();

        emit log("=== After Harvest ===");
        uint256 totalAssetsAfter = IStrategy(strategyAddr).totalAssets();
        emit log_named_decimal_uint("totalAssets AFTER", totalAssetsAfter, 18);
        if (totalAssetsAfter >= totalAssetsBefore) {
            emit log_named_decimal_uint("Profit from rewards", totalAssetsAfter - totalAssetsBefore, 18);
        } else {
            emit log_named_decimal_uint("LOSS (unexpected!)", totalAssetsBefore - totalAssetsAfter, 18);
        }

        // Log remaining balances
        emit log_named_decimal_uint("CRV remaining", IERC20(CRV).balanceOf(strategyAddr), 18);
        emit log_named_decimal_uint("CVX remaining", IERC20(CVX).balanceOf(strategyAddr), 18);
        emit log_named_decimal_uint("RSUP remaining", IERC20(RSUP).balanceOf(strategyAddr), 18);
        emit log_named_decimal_uint("WETH remaining", IERC20(WETH).balanceOf(strategyAddr), 18);
        emit log_named_decimal_uint("crvUSD remaining", IERC20(CRVUSD).balanceOf(strategyAddr), 18);
        emit log_named_decimal_uint("scrvUSD remaining", IERC20(SCRVUSD).balanceOf(strategyAddr), 18);
        emit log_named_decimal_uint("reUSD remaining (idle)", IERC20(REUSD).balanceOf(strategyAddr), 18);

        // === Verify all reward tokens sold ===
        assertEq(IERC20(CRV).balanceOf(strategyAddr), 0, "CRV should be fully sold");
        assertEq(IERC20(CVX).balanceOf(strategyAddr), 0, "CVX should be fully sold");
        assertEq(IERC20(RSUP).balanceOf(strategyAddr), 0, "RSUP should be fully sold");
        assertEq(IERC20(WETH).balanceOf(strategyAddr), 0, "WETH should be fully sold");

        // Some crvUSD dust is expected from the last loop iteration (below minLoopAmount)
        // The important thing is that rewards increased totalAssets
        uint256 crvUSDRemaining = IERC20(CRVUSD).balanceOf(strategyAddr);
        assertLt(crvUSDRemaining, 1200e18, "crvUSD dust should be below minLoopAmount");

        // Verify profit was captured
        assertGt(totalAssetsAfter, totalAssetsBefore, "totalAssets should increase from rewards");
    }
}

