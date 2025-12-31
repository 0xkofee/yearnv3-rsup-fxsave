# TODO

## Features
- [ ] Add emergency withdrawal function
- [ ] Add rebalancing logic when LTV drifts from target
- [ ] Add events for position changes (leverage up/down)

## Security
- [ ] Can idle funds be drained by small redeems? If idle hits zero, deleverage loop can't start (needs idle reUSD to repay Resupply first)
- [ ] Can tokens get stuck on last withdraw? Potential sources of dust:
  - Rounding in sreUSD share/asset conversions
  - `minLoopAmount` threshold preventing small withdrawals
  - Unsold reward tokens (CRV, CVX, RSUP)
  - crvUSD dust from incomplete swaps
  - sreUSD dust in Curve if position can't fully close
  - Resupply collateral dust below withdrawal minimum
- [ ] Maintain minimum reUSD balance in `_freeFunds` - ensure deleverage loop always has reUSD to start repaying Resupply debt. Consider:
  - Keep `minLoopAmount` (1100 reUSD) as idle buffer after withdrawals
  - Or redeem some sreUSD first before starting the deleverage loop
  - Or use a separate "bootstrap" step to get initial reUSD for repayment

## Testing
- [ ] Integration tests for edge cases (underwater positions, oracle failures)
- [ ] Test behavior at Resupply $1000 minimum borrow threshold
- [ ] Test small redeems draining idle funds
- [x] Unify logs in tests (console.log vs emit log)

## Optimization
- [ ] Gas optimization for leverage/deleverage loops
