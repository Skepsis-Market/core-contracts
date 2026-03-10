# Skepsis Market

A prediction market protocol for continuous value ranges, built on EVM (Avalanche Fuji). Users bet on where a value will land — not just up or down, but a specific range — and the protocol prices every outcome automatically using LMSR (Logarithmic Market Scoring Rule).

> **Hackathon submission.** 

---

## How It Works

Traditional prediction markets ask binary questions. Skepsis asks: **"Where exactly will the price be?"**

A market divides a value range into buckets. Users select a range of buckets they believe the outcome will fall in, and buy shares. If the resolution value lands in any of their buckets, they receive $1 USDC per share.

The LMSR market maker prices every outcome automatically — when demand increases for one range, its price rises and all other ranges get cheaper. No orderbook, no counterparty, no liquidity fragmentation.

---

## Repository Structure

```
skepsis_market/
├── core-contracts/          # Solidity contracts (Foundry)
│   ├── src/                 # Production contracts
│   │   ├── LMSRMarket.sol       # Core market — pricing, trading, resolution
│   │   ├── BucketTree.sol        # Sparse lazy segment tree for O(log N) range trades
│   │   ├── LMSRCost.sol          # Pure LMSR cost function math
│   │   ├── FixedPointMath.sol    # exp/ln operations (PRBMath wrapper)
│   │   ├── Vault.sol             # ERC-4626 LP vault — seeds markets, harvests profits
│   │   ├── MarketFactory.sol     # EIP-1167 clone factory for cheap market deployment
│   │   └── PositionNFT.sol       # ERC-1155 position tokens
│   ├── test/                # 296 tests — unit, integration, invariant, gas benchmarks
│   ├── script/              # Deployment and lifecycle scripts
│   └── ts-integration/      # TypeScript integration tests (viem)
├── docs/                    # Hackathon documentation
└── usdc-test/               # MockUSDC for local testing
```

---

## Key Design Decisions

**LMSR over AMM/orderbook** — Uniswap-style AMMs don't scale to 100+ discrete outcomes. LMSR was designed for exactly this: many outcomes, automatic pricing, bounded LP risk.

**Range betting** — Users select a price range, not a single point. The correlated LMSR prices the entire range as one trade. One transaction, one position, O(log N) gas via the segment tree.

**Segment tree (BucketTree)** — A range trade across 50 buckets normally requires 50 exp() calls. The lazy segment tree collapses this to ~7 operations regardless of range width. This is the difference between a $2 and a $15 trade.

**EIP-1167 minimal proxies** — Each market is its own contract, but deployed as a ~45 byte proxy clone. Creating a market costs ~100K gas instead of ~4.5M.

**ERC-4626 vault** — Shared LP pool that seeds new markets and harvests resolved capital. LPs deposit USDC and earn yield from market-making across all markets. Includes a withdrawal queue for fair exits when capital is deployed.

**Alpha decay** — Markets launch with wide spreads (high alpha) to prevent early sniping, then tighten over time as the market finds fair prices.

**ERC-1155 positions** — Positions are standard tokens in your wallet. Composable with other DeFi protocols — a range position on "BTC stays above $60K" is parametric insurance that could back a loan or be bundled into structured products.

---

## Architecture

```
┌─────────────┐     creates clones      ┌──────────────┐
│ MarketFactory├────────────────────────►│  LMSRMarket  │
└─────────────┘                         │  (per market) │
                                        └──────┬───────┘
                                               │ uses
                                        ┌──────┴───────┐
                                        │  BucketTree  │  segment tree
                                        │  LMSRCost    │  pricing math
                                        │  FixedPointMath  exp/ln
                                        └──────────────┘

┌─────────────┐    seeds / harvests     ┌──────────────┐
│    Vault     ├───────────────────────►│  LMSRMarket  │
│  (ERC-4626)  │◄───────────────────────┤              │
└─────────────┘    surplus returns      └──────────────┘

┌─────────────┐    mint / burn          ┌──────────────┐
│ PositionNFT ├◄───────────────────────│  LMSRMarket  │
│  (ERC-1155)  │                        └──────────────┘
└─────────────┘
```

---

## Tech Stack

| Layer | Technology |
|-------|-----------|
| Smart contracts | Solidity 0.8.24, Foundry |
| Chain | Avalanche Fuji Testnet |
| Settlement token | USDC (6 decimals) |
| Backend | TypeScript, Node.js, viem |
| Database | PostgreSQL via Prisma |
| Frontend | Next.js, TypeScript |
| Wallet / auth | Privy (email + browser wallets) |
| Contract interaction | viem + wagmi |

---

## Getting Started

### Prerequisites

```sh
# Install Foundry
curl -L https://foundry.paradigm.xyz | bash && foundryup
```

### Build and Test

```sh
cd core-contracts
forge install
forge build
forge test -vv          # 296 tests
```

### Local Deployment (Anvil)

```sh
# Terminal 1: start local chain
cd core-contracts
anvil --chain-id 43113 --block-time 2

# Terminal 2: deploy
cd core-contracts
USDC_ADDRESS=0x0000000000000000000000000000000000000000 \
forge script script/Deploy.s.sol:DeployScript \
  --rpc-url http://127.0.0.1:8545 --broadcast --chain-id 43113
```

This deploys: FixedPointMath -> LMSRMarket implementation -> PositionNFT -> MarketFactory -> Vault -> seeds vault with $500K USDC -> creates a sample market.



---

## Test Coverage

296 passing tests across:

- **Unit tests** — LMSR math, fixed-point arithmetic, position accounting, fee routing
- **Range trade tests** — multi-bucket buys/sells, segment tree correctness
- **Integration tests** — full market lifecycle (create -> trade -> resolve -> claim)
- **Invariant tests** — solvency (pool always covers max payout), position accounting consistency
- **Gas benchmarks** — range trade costs across different bucket counts and tree depths
- **Alpha decay tests** — spread tightening over time, LP loss bounds
- **Expansion tests** — dynamic range activation for markets that outgrow initial bounds

---

## Market Lifecycle

1. **Create** — Factory deploys a proxy clone with configured range, bucket count, alpha, and fees
2. **Seed** — Vault deploys USDC as initial liquidity
3. **Trade** — Users buy/sell range positions; LMSR prices adjust automatically
4. **Resolve** — Resolver submits the actual outcome value; contract maps it to a winning bucket
5. **Claim** — Winners redeem shares at $1 USDC each
6. **Harvest** — Vault reclaims remaining pool balance as LP profit

---

## Contract Addresses

```
USDC_ADDRESS=0x281092FAF10e2D78C21DC0930834369bA45EA03C
LMSR_IMPL_ADDRESS=0x4f2342A85ab5221012A14F0094e17D6DF745178D
POSITION_NFT_ADDRESS=0xf9e67aAe3f0B7fAF38f86cE6d183272Aa641b8DC
MARKET_FACTORY_ADDRESS=0xa7DEc744e7F65846AA724bD8342c4736DC05581F
VAULT_ADDRESS=0x6cb65ddB60cA86c5D130f71bb18daAAc2Baf3948
SAMPLE_MARKET_ADDRESS=0xDBF2db7D4382b9d8F8f4364f0243818E5980b8aA
```
---



## License

"Copyright (c) 2026 Utpal Pal. All rights reserved. No part of this software may be used, distributed, or modified without the express written permission of the author."
