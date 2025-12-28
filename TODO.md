# TODO

## Features
- [ ] Add emergency withdrawal function
- [ ] Add rebalancing logic when LTV drifts from target
- [ ] Add events for position changes (leverage up/down)

## Security
- [ ] Can idle funds be drained by small redeems? If idle hits zero, deleverage loop can't start (needs idle reUSD to repay Resupply first)

## Testing
- [ ] Integration tests for edge cases (underwater positions, oracle failures)
- [ ] Test behavior at Resupply $1000 minimum borrow threshold
- [ ] Test small redeems draining idle funds
- [x] Unify logs in tests (console.log vs emit log)

## Optimization
- [ ] Gas optimization for leverage/deleverage loops
