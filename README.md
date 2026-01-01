
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

3. **Partial Deleverage:**
   - For partial withdrawals, calculate proportional debt to repay
   - Flash loan only the needed amount
   - Leave remaining position intact

4. **Fallback:**
   - Keep iterative deleverage as fallback if flash loan fails
   - Useful for small withdrawals where flash loan overhead isn't worth it
