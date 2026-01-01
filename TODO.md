# TODO

## Features
- [ ] Add emergency withdrawal function
- [ ] Add rebalancing logic when LTV drifts from target
- [ ] Add events for position changes (leverage up/down)
- [ ] Keeper automation for calling report() - options:
  - Self-hosted bot (cron + cast send)
  - Gelato Network (managed automation)
  - OpenZeppelin Defender (free tier available)
  - On-chain harvest bounty (% of profits to caller)

## Security
- [x] Can idle funds be drained by small redeems? **FIXED** - Strategy keeps `minLoopAmount` reUSD as idle buffer
- [x] Can tokens get stuck on last withdraw? **FIXED** - Deleverage loop improvements:
  - `_deployFunds` keeps `minLoopAmount` (1100 reUSD) as idle buffer for withdrawals
  - Step 0: Extract excess Resupply collateral before loop to repay Curve
  - Bootstrap: Convert crvUSD→reUSD via scrvUSD pool when needed
  - Progress tracking: Continue loop while reducing Curve debt (not just reUSD balance)
- [x] Maintain minimum reUSD balance in `_freeFunds` - **FIXED** by keeping buffer in `_deployFunds`

## Testing
- [ ] Integration tests for edge cases (underwater positions, oracle failures)
- [ ] Test behavior at Resupply $1000 minimum borrow threshold
- [x] Test small redeems draining idle funds - **DONE** via `testWithdraw_WithOnlyCrvUSDDust()`
- [x] Unify logs in tests (console.log vs emit log)

## Optimization
- [ ] Gas optimization for leverage/deleverage loops
