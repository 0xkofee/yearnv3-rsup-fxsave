#!/usr/bin/env python3
"""
Multiplier Calculator for Flash Loan Deleverage

This script explores the relationship between leverage and the multiplier
needed for partial withdrawals from the two-layer leveraged position.

Key Insight: Equity doesn't sit in one place - it's embedded in the debt gap.

Formula: multiplier = equity / (curveDebt - resupplyDebt)
"""

def calculate_position(equity: float, curve_ltv: float = 0.95, resupply_ltv: float = 0.92, iterations: int = 30):
    """
    Simulate building a leveraged position through looping.

    Returns the final curveDebt, resupplyDebt, and effective leverage.
    """
    curve_debt = 0
    resupply_debt = 0
    amount_to_loop = equity

    for i in range(iterations):
        if amount_to_loop < 1100:  # minLoopAmount
            break

        # Deposit reUSD -> sreUSD -> Curve collateral
        # Borrow crvUSD at curve_ltv
        new_curve_debt = amount_to_loop * curve_ltv
        curve_debt += new_curve_debt

        # Deposit crvUSD to Resupply -> borrow reUSD at resupply_ltv
        new_resupply_debt = new_curve_debt * resupply_ltv
        resupply_debt += new_resupply_debt

        # Loop with borrowed reUSD
        amount_to_loop = new_resupply_debt

    l_curve = curve_debt / equity
    return curve_debt, resupply_debt, l_curve


def calculate_multiplier(equity: float, curve_debt: float, resupply_debt: float) -> float:
    """Calculate the exact multiplier from position state."""
    debt_gap = curve_debt - resupply_debt
    return equity / debt_gap


def calculate_multiplier_simplified(l_curve: float, resupply_ltv: float = 0.92) -> float:
    """Calculate multiplier using simplified formula."""
    return 1 / (l_curve * (1 - resupply_ltv))


def simulate_withdrawal(equity: float, curve_debt: float, resupply_debt: float,
                        withdrawal_fraction: float, multiplier: float):
    """
    Simulate a partial withdrawal and show what user receives.
    """
    user_wants = withdrawal_fraction * equity
    fraction_to_close = withdrawal_fraction * multiplier

    # Cap at 100%
    if fraction_to_close > 1.0:
        fraction_to_close = 1.0

    # Trace the funds
    reusd_from_curve = fraction_to_close * curve_debt  # sreUSD redemption
    reusd_to_resupply = fraction_to_close * resupply_debt  # repay debt
    user_receives = reusd_from_curve - reusd_to_resupply

    return {
        'user_wants': user_wants,
        'fraction_closed': fraction_to_close,
        'user_receives': user_receives,
        'efficiency': user_receives / user_wants * 100 if user_wants > 0 else 0
    }


def main():
    print("=" * 60)
    print("MULTIPLIER CALCULATOR FOR FLASH LOAN DELEVERAGE")
    print("=" * 60)

    # Test with different deposit sizes
    deposits = [10_000, 50_000, 100_000, 500_000]

    print("\n### Position Analysis by Deposit Size ###\n")
    print(f"{'Deposit':>12} {'Iterations':>10} {'L_curve':>10} {'Multiplier':>12} {'Simplified':>12}")
    print("-" * 60)

    for deposit in deposits:
        curve_debt, resupply_debt, l_curve = calculate_position(deposit)
        multiplier = calculate_multiplier(deposit, curve_debt, resupply_debt)
        simplified = calculate_multiplier_simplified(l_curve)

        # Count iterations
        iterations = 0
        amt = deposit
        while amt >= 1100 and iterations < 30:
            amt *= 0.95 * 0.92
            iterations += 1

        print(f"{deposit:>12,.0f} {iterations:>10} {l_curve:>10.2f}x {multiplier:>12.2f}x {simplified:>12.2f}x")

    print("\n" + "=" * 60)
    print("### Withdrawal Simulation (10k deposit, 25% withdrawal) ###")
    print("=" * 60)

    equity = 10_000
    curve_debt, resupply_debt, l_curve = calculate_position(equity)
    exact_multiplier = calculate_multiplier(equity, curve_debt, resupply_debt)

    print(f"\nPosition State:")
    print(f"  Equity:       {equity:,.0f} reUSD")
    print(f"  Curve Debt:   {curve_debt:,.0f} crvUSD")
    print(f"  Resupply Debt:{resupply_debt:,.0f} reUSD")
    print(f"  Debt Gap:     {curve_debt - resupply_debt:,.0f}")
    print(f"  L_curve:      {l_curve:.2f}x")
    print(f"  Exact Mult:   {exact_multiplier:.2f}x")

    print(f"\n{'Multiplier':>12} {'Fraction':>12} {'Receives':>12} {'Efficiency':>12}")
    print("-" * 52)

    for mult in [1.0, 1.5, 2.0, exact_multiplier, 2.5, 3.0]:
        result = simulate_withdrawal(equity, curve_debt, resupply_debt, 0.25, mult)
        print(f"{mult:>12.2f}x {result['fraction_closed']*100:>11.1f}% {result['user_receives']:>12,.0f} {result['efficiency']:>11.1f}%")

    print("\n" + "=" * 60)
    print("### The Key Insight ###")
    print("=" * 60)

    print("""
When you build a leveraged position, your equity doesn't sit in
one place - it's embedded in the DEBT GAP:

  debt gap = curveDebt - resupplyDebt

This gap represents the "net value" of your position because:

  1. Curve side: You have sreUSD collateral worth curveDebt
     (at 1:1 after redemption to reUSD)
  2. Resupply side: You owe resupplyDebt in reUSD

The difference is what you'd have left after unwinding - that's
your equity.
""")

    print("=" * 60)
    print("### Why the Multiplier Works ###")
    print("=" * 60)

    print("""
When closing fraction x of the position:
  - You get x × curveDebt reUSD (from sreUSD redemption)
  - You repay x × resupplyDebt reUSD (to Resupply)
  - Net to user: x × (curveDebt - resupplyDebt) = x × debtGap

The crvUSD? It loops back to repay the flash loan - nets to zero.

So to receive f × equity (say 25% of your 10,000 = 2,500 reUSD):

  x × debtGap = f × equity
  x = f × (equity / debtGap)

The term equity / debtGap is the multiplier - it tells you HOW MUCH
of the position to close to extract a given fraction of equity.

Therefore:

  multiplier = equity / (curveDebt - resupplyDebt)

The multiplier exists because equity is larger than the debt gap.
Higher leverage = smaller debt gap = larger multiplier needed.
""")

    print("=" * 60)
    print("### Impact of Resupply LTV on Multiplier ###")
    print("=" * 60)

    print(f"\n{'Resupply LTV':>12} {'Debt Gap %':>12} {'Multiplier @ 6x':>15}")
    print("-" * 42)

    for ltv in [0.85, 0.88, 0.90, 0.92, 0.95]:
        gap_pct = (1 - ltv) * 100
        mult = 1 / (6.0 * (1 - ltv))
        print(f"{ltv*100:>11.0f}% {gap_pct:>11.0f}% {mult:>15.2f}x")


if __name__ == "__main__":
    main()
