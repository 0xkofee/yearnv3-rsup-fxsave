// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.18;

import "forge-std/Test.sol";

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
}

interface IERC4626 {
    function deposit(uint256 assets, address receiver) external returns (uint256);
    function asset() external view returns (address);
    function convertToAssets(uint256 shares) external view returns (uint256);
    function convertToShares(uint256 assets) external view returns (uint256);
}

contract LooperIntegrationTest is Test {
    address constant RESUPPLY_PAIR = 0xD42535Cda82a4569BA7209857446222ABd14A82c;
    address constant REUSD = 0x57aB1E0003F623289CD798B1824Be09a793e4Bec;
    address constant CRVUSD = 0xf939E0A03FB07F59A73314E73794Be0E57ac1b4E;
    
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
}
