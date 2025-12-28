// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.18;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/ERC20Mock.sol";

/**
 * @title MockSreUSD
 * @notice Mock ERC-4626 vault representing sreUSD (yield-bearing reUSD)
 * @dev Simulates appreciation over time (~18% APY)
 */
contract MockSreUSD is ERC4626 {
    uint256 public yieldAccrued; // Tracks total yield generated
    uint256 public constant YIELD_PER_CALL = 1e16; // 1% yield per manual accrual

    constructor(IERC20 _reUSD) ERC4626(_reUSD) ERC20("Mock sreUSD", "msreUSD") {}

    /**
     * @notice Manually accrue yield to simulate time passing
     * @dev In reality, sreUSD accrues ~18% APY continuously
     */
    function accrueYield() external {
        // Add 1% to total assets (simulates yield accumulation)
        uint256 currentAssets = totalAssets();
        uint256 yield = (currentAssets * YIELD_PER_CALL) / 1e18;

        if (yield > 0) {
            // Mint yield directly to the vault
            ERC20Mock(asset()).mint(address(this), yield);
            yieldAccrued += yield;
        }
    }

    /**
     * @notice Get current exchange rate
     * @return Rate of sreUSD to reUSD (scaled by 1e18)
     */
    function exchangeRate() external view returns (uint256) {
        uint256 supply = totalSupply();
        if (supply == 0) return 1e18;
        return (totalAssets() * 1e18) / supply;
    }
}

/**
 * @title MockCurveLLAMMA
 * @notice Mock Curve lending market for testing
 * @dev Simplified implementation tracking collateral and debt per user
 */
contract MockCurveLLAMMA {
    struct UserLoan {
        uint256 collateral; // sreUSD collateral
        uint256 debt;       // crvUSD debt
        int256 n1;          // Upper band
        int256 n2;          // Lower band
        bool exists;
    }

    mapping(address => UserLoan) public loans;

    ERC20 public immutable collateralToken; // sreUSD (can be MockSreUSD or ERC20Mock)
    ERC20Mock public immutable borrowedToken;   // crvUSD

    uint256 public constant MAX_LTV = 9600; // 96%
    uint256 public constant BASIS_POINTS = 10000;

    constructor(address _collateral, address _borrowed) {
        collateralToken = ERC20(_collateral);
        borrowedToken = ERC20Mock(_borrowed);
    }

    function create_loan(uint256 collateral, uint256 _debt, uint256 N) external {
        require(!loans[msg.sender].exists, "Loan exists");
        require(_debt <= (collateral * MAX_LTV) / BASIS_POINTS, "LTV too high");

        // Transfer collateral from caller
        collateralToken.transferFrom(msg.sender, address(this), collateral);

        // Mint and send borrowed tokens
        borrowedToken.mint(msg.sender, _debt);

        loans[msg.sender] = UserLoan({
            collateral: collateral,
            debt: _debt,
            n1: int256(N),
            n2: int256(N) - 10,
            exists: true
        });
    }

    function borrow_more(uint256 collateral, uint256 _debt) external {
        require(loans[msg.sender].exists, "No loan");

        // Transfer additional collateral
        if (collateral > 0) {
            collateralToken.transferFrom(msg.sender, address(this), collateral);
            loans[msg.sender].collateral += collateral;
        }

        // Borrow more
        if (_debt > 0) {
            uint256 newTotalDebt = loans[msg.sender].debt + _debt;
            require(
                newTotalDebt <= (loans[msg.sender].collateral * MAX_LTV) / BASIS_POINTS,
                "LTV too high"
            );

            borrowedToken.mint(msg.sender, _debt);
            loans[msg.sender].debt = newTotalDebt;
        }
    }

    function repay(uint256 _d_debt, address _for, int256 /* max_active_band */) external {
        require(loans[_for].exists, "No loan");

        // Normal repay: user sends crvUSD directly
        borrowedToken.transferFrom(msg.sender, address(this), _d_debt);
        borrowedToken.burn(address(this), _d_debt);
        loans[_for].debt -= _d_debt;
    }

    function add_collateral(uint256 collateral) external {
        require(loans[msg.sender].exists, "No loan");
        collateralToken.transferFrom(msg.sender, address(this), collateral);
        loans[msg.sender].collateral += collateral;
    }

    function remove_collateral(uint256 collateral) external {
        require(loans[msg.sender].exists, "No loan");
        require(loans[msg.sender].collateral >= collateral, "Insufficient collateral");

        loans[msg.sender].collateral -= collateral;

        // Check LTV after removal
        if (loans[msg.sender].debt > 0) {
            require(
                loans[msg.sender].debt <= (loans[msg.sender].collateral * MAX_LTV) / BASIS_POINTS,
                "LTV too high after removal"
            );
        }

        collateralToken.transfer(msg.sender, collateral);
    }

    // View functions
    function debt(address user) external view returns (uint256) {
        return loans[user].debt;
    }

    function loan_exists(address user) external view returns (bool) {
        return loans[user].exists;
    }

    function health(address user, bool full) external view returns (int256) {
        if (!loans[user].exists) return type(int256).max;
        if (loans[user].debt == 0) return type(int256).max;

        // Health = (collateral - debt) / debt (simplified)
        // Positive = healthy, negative = liquidatable
        uint256 collateralValue = loans[user].collateral; // Assume 1:1
        uint256 debtValue = loans[user].debt;

        if (collateralValue > debtValue) {
            return int256(collateralValue - debtValue);
        } else {
            return -int256(debtValue - collateralValue);
        }
    }

    function max_borrowable(uint256 collateral, uint256 N, uint256 current_debt, address user) external pure returns (uint256) {
        return (collateral * MAX_LTV) / BASIS_POINTS;
    }

    function user_state(address user) external view returns (uint256[4] memory) {
        UserLoan memory loan = loans[user];
        return [loan.collateral, loan.debt, uint256(loan.n1), uint256(loan.n2)];
    }

    function collateral_token() external view returns (address) {
        return address(collateralToken);
    }

    function borrowed_token() external view returns (address) {
        return address(borrowedToken);
    }

    function loan_discount() external pure returns (uint256) {
        // 2% discount = 98% max LTV (matches mainnet)
        return 2e16;
    }
}

/**
 * @title MockResupply
 * @notice Mock Resupply lending protocol for testing
 * @dev Users deposit crvUSD collateral to borrow reUSD
 */
contract MockResupply {
    struct UserPosition {
        uint256 collateralBalance; // crvUSD deposited
        uint256 borrowShares;      // reUSD borrow shares
    }

    mapping(address => UserPosition) public positions;

    uint256 public totalBorrowShares;
    uint256 public totalBorrowAmount;

    ERC20Mock public immutable underlying; // crvUSD (collateral)
    ERC20Mock public immutable borrowToken; // reUSD (borrow)

    address public swapper; // Whitelisted swapper for repayWithCollateral

    uint256 public constant MAX_LTV = 9500; // 95%
    uint256 public constant BASIS_POINTS = 10000;

    constructor(address _underlying, address _borrowToken, address _swapper) {
        underlying = ERC20Mock(_underlying);
        borrowToken = ERC20Mock(_borrowToken);
        swapper = _swapper;
    }

    // Returns the collateral token address
    function collateral() external view returns (address) {
        return address(underlying);
    }

    function borrow(
        uint256 _borrowAmount,
        uint256 _underlyingAmount,
        address _receiver
    ) external returns (uint256 _shares) {
        // Deposit collateral
        if (_underlyingAmount > 0) {
            underlying.transferFrom(msg.sender, address(this), _underlyingAmount);
            positions[msg.sender].collateralBalance += _underlyingAmount;
        }

        // Check LTV
        require(
            _borrowAmount <= (positions[msg.sender].collateralBalance * MAX_LTV) / BASIS_POINTS,
            "LTV too high"
        );

        // Calculate shares (using simple share calculation)
        if (totalBorrowShares == 0) {
            _shares = _borrowAmount;
        } else {
            _shares = (_borrowAmount * totalBorrowShares) / totalBorrowAmount;
        }

        positions[msg.sender].borrowShares += _shares;
        totalBorrowShares += _shares;
        totalBorrowAmount += _borrowAmount;

        // Mint and send borrowed reUSD
        borrowToken.mint(_receiver, _borrowAmount);

        return _shares;
    }

    function repayWithCollateral(
        address _swapperAddress,
        uint256 _collateralToSwap,
        uint256 _amountOutMin,
        address[] calldata _path
    ) external returns (uint256 _amountOut) {
        require(_swapperAddress == swapper, "Invalid swapper");
        require(positions[msg.sender].collateralBalance >= _collateralToSwap, "Insufficient collateral");

        // Simulate swap: crvUSD → reUSD (assume 1:1 with 1% slippage)
        uint256 reUSDAmount = (_collateralToSwap * 99) / 100;
        require(reUSDAmount >= _amountOutMin, "Slippage too high");

        // Remove collateral
        positions[msg.sender].collateralBalance -= _collateralToSwap;

        // Repay debt
        uint256 sharesToRepay = positions[msg.sender].borrowShares;
        uint256 currentDebt = toBorrowAmount(sharesToRepay, false, false);

        uint256 amountToRepay = reUSDAmount > currentDebt ? currentDebt : reUSDAmount;
        uint256 sharesReduced = (amountToRepay * totalBorrowShares) / totalBorrowAmount;

        positions[msg.sender].borrowShares -= sharesReduced;
        totalBorrowShares -= sharesReduced;
        totalBorrowAmount -= amountToRepay;

        // Return leftover reUSD to user (over-collateralization)
        uint256 leftover = reUSDAmount - amountToRepay;
        if (leftover > 0) {
            borrowToken.mint(msg.sender, leftover);
        }

        return amountToRepay;
    }

    function repay(uint256 _shares, address _borrower) external returns (uint256 _amountToRepay) {
        require(positions[_borrower].borrowShares >= _shares, "Insufficient shares");

        _amountToRepay = toBorrowAmount(_shares, false, false);

        // Transfer reUSD from caller
        borrowToken.transferFrom(msg.sender, address(this), _amountToRepay);
        borrowToken.burn(address(this), _amountToRepay);

        // Reduce shares
        positions[_borrower].borrowShares -= _shares;
        totalBorrowShares -= _shares;
        totalBorrowAmount -= _amountToRepay;

        return _amountToRepay;
    }

    function removeCollateral(uint256 _collateralAmount, address _receiver) external {
        require(positions[msg.sender].collateralBalance >= _collateralAmount, "Insufficient collateral");

        positions[msg.sender].collateralBalance -= _collateralAmount;

        // Check LTV after removal
        uint256 debt = toBorrowAmount(positions[msg.sender].borrowShares, false, false);
        if (debt > 0) {
            require(
                debt <= (positions[msg.sender].collateralBalance * MAX_LTV) / BASIS_POINTS,
                "LTV too high after removal"
            );
        }

        underlying.transfer(_receiver, _collateralAmount);
    }

    // View functions
    function userBorrowShares(address _account) external view returns (uint256) {
        return positions[_account].borrowShares;
    }

    function userCollateralBalance(address _account) external view returns (uint256) {
        return positions[_account].collateralBalance;
    }

    function toBorrowAmount(uint256 _shares, bool _roundUp, bool _previewInterest) public view returns (uint256) {
        if (totalBorrowShares == 0) return 0;

        uint256 amount = (_shares * totalBorrowAmount) / totalBorrowShares;

        if (_roundUp && (_shares * totalBorrowAmount) % totalBorrowShares != 0) {
            amount += 1;
        }

        return amount;
    }
}
