# Skepsis Core Contracts

LMSR prediction market protocol on EVM. Bettors buy outcome shares; an ERC-4626 vault acts as the LP and seeds new markets.

## Architecture

| Contract | Role |
|---|---|
| `LMSRMarket` | One market per clone. Holds outcome buckets, LMSR pricing, fee routing. |
| `MarketFactory` | Deploys EIP-1167 clones of LMSRMarket. Enforces pool/fee limits. |
| `PositionNFT` | ERC-1155 tokens representing outcome shares. |
| `Vault` | ERC-4626 LP vault. Seeds markets, harvests resolved capital. |
| `FixedPointMath` | External library for `exp()`/`ln()` (deployed once via CREATE2). |

**Contract sizes (post-optimization):** LMSRMarket 19,444B · MarketFactory 4,615B · both under the 24,576B EVM limit.

---

## Local Anvil Testing

### 1. Prerequisites

```sh
# Foundry installed
curl -L https://foundry.paradigm.xyz | bash && foundryup

# Dependencies
forge install
```

### 2. Configure environment

Create `core-contracts/.env.local` — **never commit this file**:

```dotenv
# Anvil default account 0
PRIVATE_KEY=0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80
DEPLOYER_ADDRESS=0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266
ADMIN_ADDRESS=0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266
LOCAL_RPC_URL=http://127.0.0.1:8545

# Fill in after deployment (or copy from deploy output)
USDC_ADDRESS=        # MockUSDC address
FACTORY_ADDRESS=
VAULT_ADDRESS=
MARKET_ADDRESS=   # sample market or any created market
```

> **Important:** Forge auto-loads `.env` on every run. If your `.env` has real Fuji keys/addresses, always pass overrides as inline env vars (see commands below) rather than sourcing `.env.local`.

### 3. Start Anvil

Run in a dedicated terminal — keep it running for the whole session:

```sh
cd core-contracts
anvil --chain-id 43113 --state ./anvil-state.json --block-time 2
```

- `--chain-id 43113` mirrors Avalanche Fuji so scripts need no changes
- `--state` persists chain state across restarts
- `--block-time 2` auto-mines every 2 s

Default funded accounts (10,000 ETH each):
```
Account 0: 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266
Key:       0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80
```

### 4. Deploy MockUSDC

Before deploying core contracts you need a USDC token. Deploy from `../usdc-test/` (see its README), then note the address — pass it as `USDC_ADDRESS` in the next step.

If you already have a MockUSDC on anvil, skip this.

### 5. Deploy all core contracts

```sh
cd core-contracts

PRIVATE_KEY=0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80 \
DEPLOYER_ADDRESS=0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266 \
USDC_ADDRESS=<MockUSDC address from step 4> \
forge script script/Deploy.s.sol:DeployScript \
  --rpc-url http://127.0.0.1:8545 --broadcast --chain-id 43113
```

This deploys in order: FixedPointMath (CREATE2) → LMSRMarket impl → PositionNFT → MarketFactory → Vault → seeds vault with $500k → creates one sample AVAX/USD market.

The deploy script prints all addresses at the end. Copy them into `.env.local`.

### 6. Run the test suite

```sh
forge test -vv
# or with gas report:
forge test --gas-report
```

217 tests across unit, integration, invariant, and gas suites.

---

## Full Market Lifecycle (Scripts)

All lifecycle scripts read addresses from env vars. Pass them inline to override `.env`.

> **Tip:** set `MADDR` once to avoid repetition:
> ```sh
> MADDR=<your market address>
> ```

### Buy shares

```sh
PRIVATE_KEY=0xac... \
DEPLOYER_ADDRESS=0xf39... \
MARKET_ADDRESS=$MADDR \
forge script script/Trade.s.sol:BuyScript \
  --rpc-url http://127.0.0.1:8545 --broadcast --chain-id 43113
```

### Sell shares

```sh
PRIVATE_KEY=0xac... \
DEPLOYER_ADDRESS=0xf39... \
MARKET_ADDRESS=$MADDR \
forge script script/Trade.s.sol:SellScript \
  --rpc-url http://127.0.0.1:8545 --broadcast --chain-id 43113
```

### Resolve (dry run first, then with value)

```sh
# Dry run — prints bucket distribution, no tx:
PRIVATE_KEY=0xac... DEPLOYER_ADDRESS=0xf39... MARKET_ADDRESS=$MADDR \
forge script script/Resolve.s.sol:ResolveScript \
  --rpc-url http://127.0.0.1:8545 --chain-id 43113

# Resolve for real (RESOLUTION_VALUE must be within [marketMin, marketMax]):
PRIVATE_KEY=0xac... DEPLOYER_ADDRESS=0xf39... MARKET_ADDRESS=$MADDR \
RESOLUTION_VALUE=105 \
forge script script/Resolve.s.sol:ResolveScript \
  --rpc-url http://127.0.0.1:8545 --broadcast --chain-id 43113
```

### Claim winnings

```sh
PRIVATE_KEY=0xac... DEPLOYER_ADDRESS=0xf39... MARKET_ADDRESS=$MADDR \
forge script script/Claim.s.sol:ClaimScript \
  --rpc-url http://127.0.0.1:8545 --broadcast --chain-id 43113
```

### Harvest LP capital back to vault

```sh
PRIVATE_KEY=0xac... \
DEPLOYER_ADDRESS=0xf39... \
VAULT_ADDRESS=<vault> \
MARKET_ADDRESS=$MADDR \
forge script script/Claim.s.sol:HarvestLPScript \
  --rpc-url http://127.0.0.1:8545 --broadcast --chain-id 43113
```

### Create an additional market

```sh
PRIVATE_KEY=0xac... \
DEPLOYER_ADDRESS=0xf39... \
FACTORY_ADDRESS=<factory> \
VAULT_ADDRESS=<vault> \
forge script script/CreateMarket.s.sol:CreateMarketScript \
  --rpc-url http://127.0.0.1:8545 --broadcast --chain-id 43113
```

---

## Economics Summary

LMSR pricing means:
- The LP takes the opposite side of every trade.
- If the winning bucket had the **most shares bought**, LP takes maximum loss (popular outcome).
- If the winning bucket had **few/no shares**, LP profits (all losing bettor capital stays in pool).
- Fees (default 2% per trade, 20% of fees → protocol) provide a spread that accrues to the LP over time.
- Over many markets with informed bettors + uninformed bettors, LP profit depends on the ratio of noise traders to sharp traders and the alpha (liquidity) setting.

---

## Fuji Deployment

See `deployments/arbitrum-sepolia.json` for the latest testnet addresses.

```sh
forge script script/Deploy.s.sol:DeployScript \
  --rpc-url $FUJI_RPC_URL \
  --broadcast --verify --chain-id 43113
```

Verify contracts after broadcast:
```sh
forge script script/Deploy.s.sol:VerifyScript --rpc-url $FUJI_RPC_URL
```
