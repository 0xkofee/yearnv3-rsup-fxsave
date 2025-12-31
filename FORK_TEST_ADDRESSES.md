# Mainnet Fork Test Contract Addresses

This document tracks the real contract addresses needed for mainnet fork testing.

## How to Run Fork Tests

1. Set your RPC URL:
   ```bash
   export MAINNET_RPC_URL="https://eth-mainnet.g.alchemy.com/v2/YOUR_API_KEY"
   ```

2. Run the fork tests:
   ```bash
   forge test --match-contract LoopStrategyForkTest --fork-url $MAINNET_RPC_URL -vvv
   ```

   Or use the configured endpoint:
   ```bash
   forge test --match-contract LoopStrategyForkTest --rpc-url mainnet -vvv
   ```

## Required Contract Addresses

### ✅ Confirmed Addresses

| Contract | Address | Chain | Notes |
|----------|---------|-------|-------|
| reUSD | `0x57aB1E0003F623289CD798B1824Be09a793e4Bec` | Ethereum | Resolv USD stablecoin |
| sreUSD | `0x557AB1e003951A73c12D16F0fEA8490E39C33C35` | Ethereum | ERC4626 vault for reUSD (~18% APY) |
| crvUSD | `0xf939E0A03FB07F59A73314E73794Be0E57ac1b4E` | Ethereum | Curve USD stablecoin |
| Curve LLAMMA | `0x4F79Fe450a2BAF833E8f50340BD230f5A3eCaFe9` | Ethereum | Curve LLAMMA controller (sreUSD-long market) |
| Resupply Pair | `0xD42535Cda82a4569BA7209857446222ABd14A82c` | Ethereum | Resupply Pair (CurveLend: crvUSD/fxSAVE) |
| reUSD Holder | `0x47628677D8Aa6f5E11e37779576852e0209D6aE7` | Ethereum | Address with reUSD balance (or use `deal()` if insufficient) |

### ❌ Addresses Needed (Optional - for deleverage tests)

| Contract | Address | Chain | Notes |
|----------|---------|-------|-------|
| DEX Swapper | `TODO` | Ethereum | DEX router for crvUSD → reUSD swaps (e.g., Uniswap V3 Router) |
| Curve Zap | `TODO` | Ethereum | Curve Zap contract for sreUSD → crvUSD swaps |

## Finding Addresses

### sreUSD (ERC4626 Vault)
- Check Resolv documentation or website
- Search for "sreUSD" on Etherscan
- Look for ERC4626 vaults that accept reUSD

### crvUSD
- Well-known Curve stablecoin
- Check Curve documentation: https://docs.curve.fi/
- Etherscan: Search for "crvUSD" token

### Curve LLAMMA Market
- Check Curve lending markets for sreUSD collateral
- Look at crvusd.curve.fi for available markets
- May need to search Curve factory contracts

### Resupply Protocol
- Check https://github.com/resupplyfi/resupply
- Look for deployed contract addresses in their docs or README
- May be listed on their website

### Finding a Whale
Once you have the reUSD address, you can find whales:
```bash
# Use Etherscan API or Dune Analytics to find top holders
# Or check the reUSD token page on Etherscan and look at "Holders" tab
```

## Updating Fork Tests

Once you have the addresses, update them in:
`src/test/LoopStrategyFork.t.sol`

```solidity
address public constant SREUSD = 0x...;
address public constant CRVUSD = 0x...;
address public constant CURVE_LLAMMA = 0x...;
address public constant RESUPPLY = 0x...;
address public constant SWAPPER = 0x...;
address public constant CURVE_ZAP = 0x...;
address public reUSDWhale = 0x...;
```
