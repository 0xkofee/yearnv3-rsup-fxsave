# Flash Loan Multiplier Math

This document explains why partial withdrawals from a leveraged position require careful calculation of flash loan amounts.

## Starting Position

After depositing 100 reUSD and looping ~14 times:

```
Curve LLAMMA:
  - Collateral: 769 sreUSD (worth 769 reUSD)
  - Debt: 730 crvUSD
  - LTV: 730/769 = 95%

Resupply:
  - Collateral: 730 crvUSD
  - Debt: 672 reUSD
  - LTV: 672/730 = 92%

User Equity: 769 - 672 = 97 reUSD
```

**User wants to withdraw: 50 reUSD**

---

## The Circular Flow

When we deleverage with a flash loan, the crvUSD flows in a circle:

```
Flash crvUSD ──► Repay Curve ──► Free sreUSD ──► Convert to reUSD
     ▲                                                  │
     │                                                  ▼
     │                                          Repay Resupply
     │                                                  │
     │                                                  ▼
     └─────────────────── Free crvUSD ◄─────────────────┘
```

- The crvUSD loops back to repay itself
- User keeps: `(freed reUSD) - (Resupply repayment)`

---

## The Two LTV Constraints

### Curve Constraint

To withdraw sreUSD, remaining Curve debt needs collateral at 94% safe LTV:

```
Example: Repay 400 crvUSD to Curve

  Remaining debt = 730 - 400 = 330 crvUSD
  Min collateral = 330 / 0.94 = 351 sreUSD (buffer for remaining debt)
  Can withdraw   = 769 - 351 = 418 sreUSD
```

### Resupply Constraint

To withdraw crvUSD, remaining Resupply debt needs collateral at 92% safe LTV:

```
Example: Repay 350 reUSD to Resupply

  Remaining debt = 672 - 350 = 322 reUSD
  Min collateral = 322 / 0.92 = 350 crvUSD (buffer for remaining debt)
  Can withdraw   = 730 - 350 = 380 crvUSD
```

### The Critical Link

**The crvUSD we free from Resupply MUST equal the flash loan amount!**

If we can't free enough crvUSD, we can't repay the flash loan.

---

## Example 1: Flash 400 crvUSD

| Step | Action | Calculation | Result |
|------|--------|-------------|--------|
| 1 | Flash loan crvUSD | - | 400 |
| 2 | Repay Curve debt | 730 - 400 | 330 remaining |
| 3 | Curve min collateral | 330 / 0.94 | 351 sreUSD |
| 4 | Free sreUSD | 769 - 351 | **418 sreUSD** |
| 5 | Convert to reUSD | - | 418 reUSD |
| 6 | Need to repay Resupply to free 400 crvUSD | solve | ~350 reUSD |
| 7 | Resupply remaining debt | 672 - 350 | 322 reUSD |
| 8 | Resupply min collateral | 322 / 0.92 | 350 crvUSD |
| 9 | Free crvUSD | 730 - 350 | **380 crvUSD** |
| 10 | Can we repay flash? | 380 vs 400 | **NO! Short 20** |

**Result: FAILS** - Can't free enough crvUSD to repay flash loan.

---

## Example 2: Flash 500 crvUSD

| Step | Action | Calculation | Result |
|------|--------|-------------|--------|
| 1 | Flash loan crvUSD | - | 500 |
| 2 | Repay Curve debt | 730 - 500 | 230 remaining |
| 3 | Curve min collateral | 230 / 0.94 | 245 sreUSD |
| 4 | Free sreUSD | 769 - 245 | **524 sreUSD** |
| 5 | Convert to reUSD | - | 524 reUSD |
| 6 | Need to repay Resupply to free 500 crvUSD | solve | ~434 reUSD |
| 7 | Resupply remaining debt | 672 - 434 | 238 reUSD |
| 8 | Resupply min collateral | 238 / 0.92 | 259 crvUSD |
| 9 | Free crvUSD | 730 - 259 | **471 crvUSD** |
| 10 | Can we repay flash? | 471 vs 500 | **NO! Short 29** |

**Result: FAILS** - Still can't free enough crvUSD.

---

## Example 3: Flash 730 crvUSD (100% - The 2x Approach)

| Step | Action | Calculation | Result |
|------|--------|-------------|--------|
| 1 | Flash loan crvUSD | - | 730 |
| 2 | Repay ALL Curve debt | 730 - 730 | **0 remaining** |
| 3 | Curve min collateral | 0 / 0.94 | **0 sreUSD** |
| 4 | Free ALL sreUSD | 769 - 0 | **769 sreUSD** |
| 5 | Convert to reUSD | - | 769 reUSD |
| 6 | Repay ALL Resupply debt | - | 672 reUSD |
| 7 | Resupply remaining debt | 672 - 672 | **0 reUSD** |
| 8 | Resupply min collateral | 0 / 0.92 | **0 crvUSD** |
| 9 | Free ALL crvUSD | 730 - 0 | **730 crvUSD** |
| 10 | Can we repay flash? | 730 vs 730 | **YES!** |
| 11 | User receives | 769 - 672 | **97 reUSD** |

**Result: SUCCESS!**

But user wanted 50 reUSD, received 97 reUSD. The excess 47 reUSD is parked as scrvUSD buffer.

---

## Why Partial Flash Amounts Fail

The problem is the **compounding LTV buffers**:

1. Flash X crvUSD
2. Curve needs buffer for (730-X) remaining debt → can't free proportional sreUSD
3. Get less reUSD than expected
4. Repay less to Resupply → more remaining debt
5. Resupply needs buffer for remaining debt → can't free X crvUSD
6. **Can't repay flash loan!**

The buffers compound. Each protocol "traps" some collateral for the remaining debt.

---

## The 2x Multiplier Solution

When `fractionBps = baseFraction * 2`:

- For a 50% withdrawal: 50% × 2 = 100%
- We repay 100% of all debt
- **Zero remaining debt = Zero buffers needed**
- All collateral is free to withdraw
- Flash loan repayment guaranteed

**Trade-off:** We always close the entire position, even for small withdrawals. Excess is parked and recovered later.

---

## Could We Be Smarter?

Yes! We could solve for the exact flash amount where:

```
freed_crvUSD = flash_amount
```

The formula (derived from LTV constraints):

```
flash_amount = (target_reUSD + K) / M

Where:
  K = equity_offset ≈ 8 (depends on position)
  M = LTV_differential = 1/0.94 - 0.92 = 0.144
```

For 50 reUSD: `flash = (50 + 8) / 0.144 ≈ 403 crvUSD` (55% of debt)

| Approach | Flash Amount | % of Position |
|----------|--------------|---------------|
| 2x multiplier | 730 crvUSD | 100% |
| Optimal calculation | 403 crvUSD | 55% |

The 2x approach over-flashes by ~80% but is simpler and always works.

---

## Summary

| Concept | Explanation |
|---------|-------------|
| **Why flash loans?** | Break the circular dependency: need crvUSD to free sreUSD, need sreUSD to get reUSD to free crvUSD |
| **Why not proportional?** | LTV buffers trap collateral when debt remains |
| **Why 2x?** | Guarantees 100% close → zero remaining debt → zero buffers → all collateral free |
| **Why it's wasteful** | Always closes entire position even for small withdrawals |
| **Better approach** | Calculate exact flash amount from LTV constraint equations |
