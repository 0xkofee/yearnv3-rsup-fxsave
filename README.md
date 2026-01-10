
# Yearn Tokenized Strategy

This repository contains the base code for the Yearn V3 "Tokenized Strategy" implementation. The V3 strategy implementation utilizes an immutable proxy pattern to allow anyone to easily create their own single strategy 4626 vault. All Tokenized Strategies will use the logic held within the `TokenizedStrategy` for their redundant and high risk code. The implementation holds all ERC-20, ERC-4626, profit locking and reporting functionality to make any strategy that uses it a fully permissionless vault without holding any of this logic itself. 

The implementation address that calls are delegated to is pre-set to a constant and can never be changed post deployment. The implementation contract itself is ownerless and can never be updated in any way.

NOTE: The master branch has these pre-set addresses set based on the deterministic address that testing on a local device will render. These contracts should NOT be used in production and any live versions should use an official [release](https://github.com/yearn/tokenized-strategy/releases).

A Strategy contract can become a fully ERC-4626 compliant vault by inheriting the `BaseStrategy` contract, that uses the fallback function to delegateCall the previously deployed version of `TokenizedStrategy`. A strategist then only needs to override three simple functions in their specific strategy.

[TokenizedStrategy](https://github.com/yearn/tokenized-strategy/blob/master/src/TokenizedStrategy.sol) - The implementation contract that holds all logic for every strategy.

[BaseStrategy](https://github.com/yearn/tokenized-strategy/blob/master/src/BaseStrategy.sol) - Abstract contract to inherit that communicates with the `TokenizedStrategy`.

Full tech spech can be found [here](https://github.com/yearn/tokenized-strategy/blob/master/SPECIFICATION.md)

## Installation and Setup

1. First you will need to install [Foundry](https://book.getfoundry.sh/getting-started/installation).
NOTE: If you are on a windows machine it is recommended to use [WSL](https://learn.microsoft.com/en-us/windows/wsl/install)

2. Fork this repository (easier) or create a new repository using it as template. [Create from template](https://docs.github.com/en/repositories/creating-and-managing-repositories/creating-a-repository-from-a-template)

3. Clone your newly created repository recursively to include modules.

```sh
git clone --recursive https://github.com/myuser/tokenized-strategy

cd tokenized-strategy
```

NOTE: if you create from template you may need to run the following command to fetch the git sub modules (.gitmodules for exact releases) `git submodule init && git submodule update`

4. Build the project.

```sh
make build
```
To print the size of each contract
```sh
make size
```

5. Run tests
NOTE: Tests will take a significant period of time since the fuzzer is set to 10,000 runs.
```sh
make test
```

## Testing

Run all tests run on a local chain

```sh
make test
```
Run all tests with traces (very useful)

```sh
make trace
```
Run all tests with gas outputs

```sh
make gas
```
Run specific test contract with traces (e.g. `test/StrategyOperation.t.sol`)

```sh
make trace-contract contract=StrategyOperationsTest
```
Run specific test with traces (e.g. `test/StrategyOperation.t.sol::testStrategy`)

```sh
make trace-test test=testStrategy
```

See here for some tips on testing [`Testing Tips`](https://book.getfoundry.sh/forge/tests.html)

## Storage Layout

To print out the storage layout of any contract (e.g 'test/MockStrategy.sol')

```sh
make inspect contract=MockStrategy
```

## Deployment

Deployments of the TokenizedStrategy are done using create2 to be at a deterministic address on any EVM chain.

Check the [docs](https://docs.yearn.fi/developers/v3/overview) for the most updated deployment address.

Deployments on new chains can be done permissionlessly by anyone using the included script. First follow the steps to deploy the vault factory from the [Vaults V3](https://github.com/yearn/yearn-vaults-v3/) repo.

You can then deploy the TokenizedStrategy using the provided script.

```
forge script script/Deploy.s.sol:Deploy --account ACCOUNT_NAME --rpc-url YOUR_RPC_URL --broadcast
```

If the deployments do not end at the same address you can also manually send the calldata used in the previous deployments on other chains.

### To make contributions please follow the [Contribution Guidelines](https://github.com/yearn/tokenized-strategy/blob/master/CONTRIBUTING.md)

# Resources

- [Getting help on Foundry](https://github.com/gakonst/foundry#getting-help)
- [Forge Standard Lib](https://github.com/brockelmore/forge-std)
- [Awesome Foundry](https://github.com/crisgarner/awesome-foundry)
- [Foundry Book](https://book.getfoundry.sh/)
- [Learn Foundry Tutorial](https://www.youtube.com/watch?v=Rp_V7bYiTCM)

---

# SreUSD/crvUSD Loop Strategy

## Maximum Leverage

### The Formula

Maximum leverage is determined by the combined LTV of both protocols:

```
Combined LTV = Curve LTV × Resupply LTV
             = 0.95 × 0.92
             = 0.874 (87.4%)

Max Leverage = 1 / (1 - Combined LTV)
             = 1 / (1 - 0.874)
             = 1 / 0.126
             ≈ 7.94x
```

### Why This Limit?

Each loop iteration, you can only borrow 87.4% of what you deposited:

```
Start:     100 reUSD
Loop 1:    +87.4 reUSD (borrow 95% from Curve, then 92% from Resupply)
Loop 2:    +76.4 reUSD (87.4% of 87.4)
Loop 3:    +66.8 reUSD
...
Loop ∞:    Total = 100 / (1 - 0.874) = 794 reUSD position
```

**794 reUSD position from 100 reUSD equity = 7.94x leverage**

## Flash Loan Leverage for Deposits

The strategy uses flash loans to build leveraged positions in a single transaction.

### The Math

Given:
- User deposits **X** reUSD
- Flash loan **F** crvUSD
- Curve safe LTV: **94%** (safeCurveLTV)
- Resupply LTV: **92%** (targetResupplyLTV)

**The Flow:**
```
1. Flash F crvUSD
2. Deposit F crvUSD to Resupply → borrow 0.92F reUSD
3. Total reUSD = X + 0.92F → deposit to sreUSD → supply to Curve
4. Borrow from Curve = 0.94 × (X + 0.92F) crvUSD
5. Use Curve borrow to repay flash loan F
```

**The Constraint:**

For the flash loan to be repayable, Curve borrow must cover F:

```
0.94 × (X + 0.92F) ≥ F
0.94X + 0.8648F ≥ F
0.94X ≥ F - 0.8648F
0.94X ≥ 0.1352F
F ≤ 0.94X / 0.1352
F ≤ 6.95X
```

**Maximum flash loan = ~6.95x the deposit amount**

### The General Formula

```
Max flash multiplier = safeCurveLTV / (1 - safeCurveLTV × targetResupplyLTV)
                     = 0.94 / (1 - 0.94 × 0.92)
                     = 0.94 / (1 - 0.8648)
                     = 0.94 / 0.1352
                     = 6.95x
```

### Why Exceeding the Max Multiplier Fails

If you try to flash more than 6.95x, you can't repay the loan. Example with **8x**:

```
Deposit: X = 1000 reUSD
Flash:   F = 8000 crvUSD (8x)

Step 1: Deposit 8000 crvUSD to Resupply
Step 2: Borrow 0.92 × 8000 = 7360 reUSD
Step 3: Total reUSD = 1000 + 7360 = 8360 → deposit as sreUSD → supply to Curve
Step 4: Borrow from Curve = 0.94 × 8360 = 7858 crvUSD
Step 5: Need to repay 8000 crvUSD, but only have 7858

Shortfall: 8000 - 7858 = 142 crvUSD ❌
```

At exactly 6.95x, the math balances:
```
Flash:   F = 6950 crvUSD (6.95x)
Borrow from Resupply: 0.92 × 6950 = 6394 reUSD
Total sreUSD value: 1000 + 6394 = 7394
Borrow from Curve: 0.94 × 7394 = 6950 crvUSD ✓
```

### Dynamic Safety Buffers

The strategy calculates the flash multiplier dynamically using `_calculateSafeLeverageMultiplier()`:

```
maxMultiplier = safeCurveLTV / (1 - safeCurveLTV × targetResupplyLTV)
```

Safety buffers are applied based on the flash loan path:

| Path | Buffer | Effective Multiplier | Reason |
|------|--------|---------------------|--------|
| crvUSD | 93% of max | ~6.47x | No swap overhead |
| USDC | 90% of max | ~6.26x | Round-trip slippage + potential Aave fee |

The USDC path needs a larger buffer because:
- ~0.04% round-trip slippage (crvUSD↔USDC swaps)
- 0.05% Aave fee (when using Aave as fallback)

### Flash Loan Provider Priority

1. **crvUSD flash** (0% fee) - Always tried first if configured and has sufficient liquidity
2. **USDC flash** - Falls back to the configured `flashLoanProvider`:
   - `BALANCER` (default): 0% fee
   - `AAVE`: 0.05% fee

If crvUSD flash has insufficient liquidity and the USDC provider isn't configured, the transaction reverts.

## Partial Withdrawal Math: Why We Use a 2x Multiplier

When a user makes a partial withdrawal from a leveraged position, the naive approach of closing a proportional fraction doesn't work due to **LTV constraints**. Here's a complete walkthrough.

### Step 1: Building the Leveraged Position

User deposits **100 reUSD**. The strategy uses a flash loan to build leverage in one transaction:

```
1. Flash loan 650 crvUSD (~6.5x deposit)
2. Deposit 650 crvUSD to Resupply → borrow 598 reUSD (92% LTV)
3. Total reUSD: 100 + 598 = 698 → deposit as sreUSD → supply to Curve
4. Borrow 656 crvUSD from Curve (94% LTV)
5. Repay flash loan with borrowed crvUSD
```

**Final Position:**
```
Curve LLAMMA:
  - Collateral: 698 sreUSD (worth 698 reUSD)
  - Debt: 656 crvUSD
  - LTV: 656/698 = 94%

Resupply:
  - Collateral: 650 crvUSD
  - Debt: 598 reUSD
  - LTV: 598/650 = 92%

User Equity: 698 - 598 = 100 reUSD
```

### Step 2: User Requests 50% Withdrawal

User wants to withdraw **50 reUSD** (50% of their 100 reUSD equity).

```
baseFraction = 50 / 100 = 50%
```

### Step 3: Naive Approach (No Multiplier)

With `fractionBps = 50%`:

```
Step 1: Flash loan 328 crvUSD (50% of 656 debt)

Step 2: Repay Curve debt
        - Repay: 328 crvUSD
        - Remaining debt: 328 crvUSD

Step 3: Withdraw sreUSD from Curve ← HERE'S THE PROBLEM
        - Total collateral: 698 sreUSD
        - Remaining debt: 328 crvUSD
        - At 94% safe LTV, min collateral required: 328 / 0.94 = 349 sreUSD
        - Withdrawable: 698 - 349 = 349 sreUSD
        - Expected (proportional): 50% × 698 = 349 sreUSD
        - Just barely works in this example, but at higher LTVs it fails!

Step 4: Redeem sreUSD → reUSD
        - 349 sreUSD → 349 reUSD

Step 5: Repay Resupply debt (proportional to fractionBps)
        - Repay: 50% × 598 = 299 reUSD
        - Remaining reUSD: 349 - 299 = 50 reUSD ← USER GETS THIS

Step 6: Withdraw crvUSD from Resupply
        - Remaining debt: 299 reUSD
        - Collateral: 650 crvUSD
        - At 92% safe LTV, min collateral: 299 / 0.92 = 325 crvUSD
        - Withdrawable: 650 - 325 = 325 crvUSD

Step 7: Repay flash loan
        - Owe: 328 crvUSD
        - Have: 325 crvUSD
        - SHORTFALL: 3 crvUSD ❌
```

**Result:**
```
Flash loan repayment fails - not enough crvUSD withdrawn from Resupply!
```

### Step 4: Why The Failure Occurs

The failure comes from **LTV constraints on both protocols**.

When you repay X% of debt, you **cannot** withdraw X% of collateral. You can only withdraw the **excess above minimum collateral** required for the remaining debt:

```
withdrawable = totalCollateral - (remainingDebt / safeLTV)
```

The gap compounds across both Curve and Resupply, leaving insufficient crvUSD to repay the flash loan.

### Step 5: The 2x Multiplier Solution

By closing **2x** the proportional fraction, we ensure enough collateral is freed:

```solidity
fractionBps = baseFraction * 2;
```

**With 2x Multiplier (fractionBps = 100%):**

```
Step 1: Flash loan 656 crvUSD (100% of Curve debt)

Step 2: Repay ALL Curve debt
        - Remaining debt: 0 crvUSD

Step 3: Withdraw sreUSD from Curve
        - No LTV constraint (debt = 0)!
        - Withdraw ALL 698 sreUSD ✓

Step 4: Redeem sreUSD → reUSD
        - 698 sreUSD → 698 reUSD

Step 5: Repay Resupply debt (capped at 100%)
        - Repay: 598 reUSD
        - Remaining reUSD: 698 - 598 = 100 reUSD

Step 6: Withdraw crvUSD from Resupply
        - No debt remaining → withdraw ALL 650 crvUSD

Step 7: Repay flash loan
        - Owe: 656 crvUSD
        - Have: 650 crvUSD
        - Shortfall: 6 crvUSD → covered by swapping some reUSD equity
```

**Result:**
```
User receives: ~100 reUSD (entire equity freed, minus swap for shortfall)
User wanted: 50 reUSD
Excess: ~50 reUSD → parked as scrvUSD buffer for next user
```

The 2x multiplier overshoots, but the excess is parked and recovered on the next deposit/withdrawal.

TODO: explain why 2x specifically

## Yearn V3 Loss Mechanism: Fair Cost Distribution

### The Problem: Phantom Assets

When users withdraw from a leveraged strategy, deleverage costs are incurred:
- Flash loan fees (~0.05%)
- Swap slippage (~0.1-0.2%)

Without proper handling, these costs accumulate as "phantom assets" - the strategy's cached `totalAssets` remains high while actual position value decreases. The last user to withdraw absorbs ALL accumulated losses.

**Example of the problem:**
```
Initial: 3 users, 10,000 reUSD each = 30,000 totalAssets

User 1 withdraws 10,000:
  - Deleverage costs ~50 reUSD
  - User receives: 10,000 reUSD
  - Cached totalAssets: 20,000 (unchanged pro-rata)
  - Actual position value: 19,950 reUSD

User 2 withdraws 10,000:
  - Deleverage costs ~50 reUSD
  - User receives: 10,000 reUSD
  - Cached totalAssets: 10,000
  - Actual position value: 9,900 reUSD

User 3 withdraws (last user):
  - Receives only 9,900 reUSD (actual position)
  - Absorbs 100 reUSD in losses (1%)
  - Lost 1% while others paid 0%!
```

### The Solution: Yearn V3's Built-in Loss Handling

Yearn V3's `TokenizedStrategy._withdraw()` has built-in loss detection:

```solidity
// TokenizedStrategy.sol - _withdraw function
function _withdraw(address receiver, address owner, uint256 assets, uint256 maxLoss)
    internal returns (uint256)
{
    // Check idle balance BEFORE freeFunds
    uint256 idle = _asset.balanceOf(address(this));
    uint256 loss;

    if (idle < assets) {
        // Need to free funds from strategy
        IBaseStrategy(address(this)).freeFunds(assets - idle);

        // Check idle balance AFTER freeFunds
        idle = _asset.balanceOf(address(this));

        // If idle < assets, the difference is a LOSS
        if (idle < assets) {
            loss = assets - idle;
            require(loss <= (assets * maxLoss) / MAX_BPS, "too much loss");
            assets = idle;  // User receives what's available
        }
    }

    // Accounting: deduct BOTH assets sent AND loss
    S.totalAssets -= (assets + loss);

    _asset.safeTransfer(receiver, assets);
    return assets;
}
```

**Key insight**: If `_freeFunds` leaves less reUSD than requested, TokenizedStrategy:
1. Detects the shortfall as `loss`
2. Validates against user's `maxLoss` tolerance
3. Sends user only `idle` amount
4. Deducts `assets + loss` from `totalAssets` (proper accounting!)

### How We Utilize This Mechanism

To ensure each user pays their own deleverage costs, we measure the actual loss and control the idle balance visible after `_freeFunds` returns.

**Strategy:**
1. Sweep any existing scrvUSD buffer from previous withdrawals
2. Snapshot `totalAssets` before deleverage
3. Use 2x multiplier to free excess funds
4. Recalculate `totalAssets` after deleverage
5. Actual loss = `snapshotBefore - snapshotAfter`
6. Calculate user's proportional loss based on freed amount
7. Park excess reUSD as scrvUSD (buffer - earns yield while parked!)
8. Leave exactly `_amount - userLoss` as idle reUSD
9. TokenizedStrategy sees shortfall, passes cost to user

**Why scrvUSD instead of crvUSD?**
- **Fewer swaps**: reUSD → scrvUSD (1 swap) vs reUSD → scrvUSD → crvUSD (2 swaps)
- **Less slippage**: Half the swaps = half the slippage losses
- **Earns yield**: scrvUSD is a yield-bearing wrapper for crvUSD

**Code flow:**
```solidity
function _freeFunds(uint256 _amount) internal override {
    // 1. Sweep any existing buffer from previous withdrawals
    if (scrvUSDBuffer > 0) {
        _sweepScrvUSDBuffer();
    }

    // 2. Snapshot total assets before deleverage
    uint256 idleBefore = reUSD.balanceOf(address(this));
    uint256 totalBefore = _calculateTotalAssets(idleBefore);

    // 3. Deleverage with 2x multiplier - frees ~2x requested amount
    _freeFundsWithFlashLoan(_amount);

    // 4. Recalculate total assets after deleverage
    uint256 idleAfter = reUSD.balanceOf(address(this));
    uint256 totalAfter = _calculateTotalAssets(idleAfter);

    // 5. Calculate actual loss and user's proportional share
    uint256 actualLoss = totalBefore > totalAfter ? totalBefore - totalAfter : 0;
    uint256 userLoss = (actualLoss * _amount) / totalBefore;

    // 6. Calculate target idle = requested - user's loss
    uint256 targetIdle = _amount - userLoss;

    // 7. Park excess as scrvUSD
    if (idleAfter > targetIdle) {
        uint256 excess = idleAfter - targetIdle;
        _parkExcessAsScrvUSD(excess);
    }
    // Now idle ≈ targetIdle, TokenizedStrategy sees loss ≈ userLoss
}

function _deployFunds(uint256 _amount) internal override {
    // First, sweep any parked scrvUSD back to reUSD
    _sweepScrvUSDBuffer();

    // Then deploy new funds normally
    // ...
}
```

### Result: Fair Cost Distribution

```
Initial: 3 users, 10,000 reUSD each = 30,000 totalAssets

User 1 withdraws 10,000:
  - Sweeps any existing buffer (none on first withdrawal)
  - Deleverage 66% of position (2x multiplier)
  - Total freed: ~20,000 reUSD, actual loss: ~1,000
  - User's proportional loss: 1000 * (10000/20000) = 500
  - Parks excess as scrvUSD, leaves idle = 9,500
  - User receives: 9,500 reUSD (pays ~5% deleverage cost)

User 2 withdraws 10,000:
  - Sweeps scrvUSD buffer first (~10,000 → reUSD)
  - Deleverage remaining position
  - User's loss is proportional to their withdrawal
  - User receives: ~9,950 reUSD

User 3 withdraws 10,000:
  - Sweeps scrvUSD buffer (position may be empty)
  - If buffer covers request, no deleverage needed
  - User receives: ~10,000 reUSD (buffer + scrvUSD yield!)
```

### Edge Cases

1. **Full withdrawal (100%)**: No parking needed - return everything
2. **Last user exits**: scrvUSD buffer swept, may receive more than expected (yield!)
3. **Buffer accumulates**: Gets swept on next withdrawal/deposit
4. **Loss exceeds request**: Reverts on `maxLoss` check (safe default)

