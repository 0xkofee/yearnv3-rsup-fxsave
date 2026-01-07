
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

### Practical Leverage (with marginalLoopThreshold)

We don't run infinite loops. The `marginalLoopThreshold` stops iterations when returns diminish:

| Threshold | Stops At | Leverage | % of Max | Gas Saved |
|-----------|----------|----------|----------|-----------|
| 5% | ~23 iter | 7.56x | 95.2% | ~5M |
| **10%** (default) | **~18 iter** | **7.20x** | **90.7%** | **~8M** |
| 20% | ~13 iter | 6.53x | 82.3% | ~12M |

### Leverage Accumulation by Iteration

```
Iteration    Cumulative Leverage    Marginal Add
-------------------------------------------------
    1             1.00x               1.00x
    5             4.06x               0.58x
   10             5.85x               0.26x
   15             6.85x               0.14x
   18             7.20x               0.10x  ← 10% threshold stops here
   20             7.37x               0.07x
   25             7.64x               0.04x
   30             7.79x               0.02x
    ∞             7.94x               0.00x
```

The last 12 iterations (18→30) only add 0.59x leverage but cost ~8.6M gas.

### Changing Leverage

To increase leverage, you could:
1. **Lower marginalLoopThreshold** (e.g., 500 = 5%) → more iterations, higher gas
2. **Increase Resupply LTV** (requires protocol changes)
3. **Increase Curve LTV** (riskier, closer to liquidation)

Current defaults prioritize gas efficiency over maximum leverage.

## Leverage vs Deleverage Asymmetry Problem

This strategy builds leveraged positions by looping through Curve LLAMMA and Resupply. A critical issue exists: **leverage is fast, but deleverage is slow**.

### The Problem

**Leverage (Deposit):**
```
Each iteration:
1. Deposit collateral (e.g., 10k sreUSD)
2. Borrow at 95% LTV → get 9.5k crvUSD
3. Deposit crvUSD, borrow at 92% LTV → get 8.7k reUSD
4. Loop with 8.7k (87% of previous)

Pattern: Geometric decay → converges fast in ~14 iterations
```

**Deleverage (Withdraw):**
```
Each iteration:
1. Use available reUSD to repay debt
2. Withdraw collateral - BUT limited by LTV constraints
3. Can only withdraw EXCESS above minimum safe LTV
4. Convert to reUSD, repeat

Pattern: Slow linear climb → needs ~16+ iterations for same position
```

### Why Deleverage is Slower

| Phase | Pattern | Constraint |
|-------|---------|------------|
| Leverage | Borrow 87% of new collateral each step | Only limited by max LTV |
| Deleverage | Free only excess above min LTV each step | Must maintain LTV while unwinding |

**Example:** At 85% LTV with 80% minimum:
- Can only withdraw 5% of position per iteration
- But leverage can borrow 87% per iteration

### Real Test Data

For a 10,000 reUSD deposit:
- **Leverage:** 14 iterations (9k → 7.6k → 6.5k → ... → done)
- **Deleverage:** 16 iterations (1k → 736 → 890 → ... → 10k)

Note iteration 1 of deleverage: balance **dropped** from 1,000 to 736! We spent 1,000 on debt repayment but LTV only allowed 736 of collateral withdrawal.

### Deposit Size Limits

With `maxIterations = 30`:
- 10,000 reUSD: ✓ Works (15 iterations)
- 20,000 reUSD: ✓ Works (30 iterations)
- 21,000 reUSD: ✓ Works (just fits)
- 21,500 reUSD: ✗ Fails (needs 31+ iterations)

**Roughly ~700 reUSD freed per deleverage iteration at current LTV settings.**

### Protection Mechanism

The strategy includes a slippage check at the end of `_freeFunds`:

```solidity
if (finalBalance < userReceives) {
    uint256 shortfall = userReceives - finalBalance;
    uint256 maxSlippage = userReceives / 100; // 1%
    require(shortfall <= maxSlippage, "Deleverage failed: insufficient funds freed");
}
```

This prevents silent partial withdrawals where users would lose funds without any error.

### Potential Solution: Flash Loan Deleverage

The iterative deleverage is slow because we're trapped in a cycle:
- Need to repay debt to withdraw collateral
- Need collateral to get funds to repay debt

**Flash loans break this cycle.**

#### Current Position Structure

```
User deposits reUSD
    ↓
reUSD → sreUSD (via deposit)
    ↓
sreUSD deposited to Curve LLAMMA as collateral
    ↓
Borrow crvUSD from Curve (debt #1)
    ↓
crvUSD deposited to Resupply as collateral
    ↓
Borrow reUSD from Resupply (debt #2)
    ↓
Loop with borrowed reUSD...
```

#### Flash Loan Deleverage Flow

```
1. Flash loan reUSD (amount = Resupply debt)
2. Repay ALL Resupply reUSD debt → debt #2 = 0
3. Withdraw ALL crvUSD collateral from Resupply (no LTV constraint!)
4. Repay ALL Curve crvUSD debt → debt #1 = 0
5. Withdraw ALL sreUSD collateral from Curve (no LTV constraint!)
6. Redeem sreUSD → reUSD
7. Repay flash loan
8. Return remainder to user
```

#### Comparison

| Metric | Iterative | Flash Loan |
|--------|-----------|------------|
| Iterations | 15-30 | 1 |
| Gas cost | High (~25M gas) | Lower (~5M gas) |
| Deposit limit | ~21k reUSD | Unlimited* |
| Complexity | Simple loops | Callback handling |
| External dependency | None | Flash loan provider |

*Limited only by flash loan liquidity

#### Implementation Considerations

1. **Flash Loan Sources:**
   - Aave V3 (0.05% fee for most assets)
   - Balancer (no fee)
   - Uniswap V3 (0.3% swap fee if using flash swap)
   - Curve (if pool has sufficient liquidity)

2. **Callback Pattern:**
   ```solidity
   function executeOperation(
       address[] calldata assets,
       uint256[] calldata amounts,
       uint256[] calldata premiums,
       address initiator,
       bytes calldata params
   ) external returns (bool) {
       // 1. Repay Resupply debt
       // 2. Withdraw crvUSD collateral
       // 3. Repay Curve debt
       // 4. Withdraw sreUSD collateral
       // 5. Redeem sreUSD → reUSD
       // 6. Approve repayment
       return true;
   }
   ```

3. **Partial Deleverage - The 2x Multiplier:**

   Partial withdrawals from leveraged positions require closing MORE than the proportional fraction. See detailed explanation below.

## Partial Withdrawal Math: Why We Use a 2x Multiplier

When a user makes a partial withdrawal from a leveraged position, the naive approach of closing a proportional fraction doesn't work due to **LTV constraints**. Here's a complete walkthrough.

### Step 1: Building the Leveraged Position

User deposits **100 reUSD**. The strategy loops to build leverage:

```
Iteration 1:
  - 100 reUSD → 100 sreUSD (deposit to sreUSD vault)
  - Deposit 100 sreUSD to Curve LLAMMA as collateral
  - Borrow 95 crvUSD at 95% LTV
  - Deposit 95 crvUSD to Resupply as collateral
  - Borrow 87.4 reUSD at 92% LTV

Iteration 2:
  - 87.4 reUSD → 87.4 sreUSD
  - Add to Curve (total: 187.4 sreUSD), borrow more → total debt: 178 crvUSD
  - Add to Resupply (total: 178 crvUSD), borrow more → total debt: 163.8 reUSD

Iterations 3-14: Continue until amounts < minLoopAmount
```

**Final Position (after ~14 loops):**
```
Curve LLAMMA:
  - Collateral: 769 sreUSD (worth 769 reUSD)
  - Debt: 730 crvUSD
  - LTV: 730/769 = 95%

Resupply:
  - Collateral: 730 crvUSD
  - Debt: 672 reUSD
  - LTV: 672/730 = 92%

User Equity: 769 - 672 = 97 reUSD (~3% loss to rounding across loops)
```

### Step 2: User Requests 50% Withdrawal

User wants to withdraw **50 reUSD** (≈50% of their 97 reUSD equity).

```
baseFraction = 50 / 97 = 51.5%
```

### Step 3: Naive Approach (No Multiplier)

With `fractionBps = 51.5%`:

```
Step 1: Flash loan 376 crvUSD (51.5% of 730 debt)

Step 2: Repay Curve debt
        - Repay: 376 crvUSD
        - Remaining debt: 354 crvUSD

Step 3: Withdraw sreUSD from Curve ← HERE'S THE PROBLEM
        - Total collateral: 769 sreUSD
        - Remaining debt: 354 crvUSD
        - At 94% safe LTV, min collateral required: 354 / 0.94 = 377 sreUSD
        - Withdrawable: 769 - 377 = 392 sreUSD
        - Expected (proportional): 51.5% × 769 = 396 sreUSD
        - SHORTFALL: 4 sreUSD (can't withdraw proportionally!)

Step 4: Redeem sreUSD → reUSD
        - 392 sreUSD → 392 reUSD

Step 5: Repay Resupply debt (proportional to fractionBps)
        - Repay: 51.5% × 672 = 346 reUSD
        - Remaining reUSD: 392 - 346 = 46 reUSD ← USER GETS THIS

Step 6: Withdraw crvUSD from Resupply
        - Remaining debt: 326 reUSD
        - Collateral: 730 crvUSD
        - At 92% safe LTV, min collateral: 326 / 0.92 = 354 crvUSD
        - Withdrawable: 730 - 354 = 376 crvUSD

Step 7: Repay flash loan
        - Owe: 376 crvUSD
        - Have: 376 crvUSD ✓
```

**Result:**
```
User receives: 46 reUSD
User expected: 50 reUSD
Shortfall: 4 reUSD (8% loss!)
```

### Step 4: Why The Loss Occurs

The loss comes from **Step 3: Curve's LTV constraint**.

When you repay X% of Curve debt, you **cannot** withdraw X% of collateral. You can only withdraw the **excess above minimum collateral** required for the remaining debt:

```
withdrawable = totalCollateral - (remainingDebt / safeLTV)
```

At 95% LTV with 94% safe LTV:
- Repay 51.5% of debt → 48.5% remains
- Min collateral for remaining = 48.5% × debt / 0.94 = 51.6% of original
- Can only withdraw: 100% - 51.6% = 48.4% (not 51.5%!)

The ~3% gap between what we repaid (51.5%) and what we can withdraw (48.4%) means we get less sreUSD → less reUSD → shortfall after Resupply repayment.

### Step 5: The 2x Multiplier Solution

By closing **2x** the proportional fraction, we ensure enough collateral is freed:

```solidity
fractionBps = baseFraction * 2;
```

**With 2x Multiplier (fractionBps = 100%):**

```
Step 1: Flash loan 730 crvUSD (100% of debt)

Step 2: Repay ALL Curve debt
        - Remaining debt: 0 crvUSD

Step 3: Withdraw sreUSD from Curve
        - No LTV constraint (debt = 0)!
        - Withdraw ALL 769 sreUSD ✓

Step 4: Redeem sreUSD → reUSD
        - 769 sreUSD → 769 reUSD

Step 5: Repay Resupply debt (capped at 100%)
        - Repay: 672 reUSD
        - Remaining reUSD: 769 - 672 = 97 reUSD

Step 6: Withdraw crvUSD from Resupply
        - No debt remaining → withdraw ALL 730 crvUSD

Step 7: Repay flash loan
        - Owe: 730 crvUSD
        - Have: 730 crvUSD ✓
```

**Result:**
```
User receives: 97 reUSD (entire equity freed)
User wanted: 50 reUSD
Excess: 47 reUSD → parked as scrvUSD buffer for next user
```

The 2x multiplier overshoots, but the excess is parked and recovered on the next deposit/withdrawal.

### Why 2x Specifically?

The shortfall percentage depends on how close current LTV is to safe LTV:

| Current LTV | Safe LTV | Repay % | Can Withdraw % | Shortfall |
|-------------|----------|---------|----------------|-----------|
| 95% | 94% | 50% | 46.8% | 6.4% |
| 95% | 94% | 75% | 73.4% | 2.1% |
| 90% | 94% | 50% | 52.1% | 0% (excess!) |

At high LTV (near liquidation), the shortfall approaches ~8%. The 2x multiplier ensures we always free enough by closing more position than strictly needed.

### Edge Cases

1. **Full Withdrawal**: `fractionBps` caps at 100% - close entire position
2. **Low LTV Position**: May free more than needed - excess parked as buffer
3. **Multiple Users**: Buffer swept on next operation, fairly distributed

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
