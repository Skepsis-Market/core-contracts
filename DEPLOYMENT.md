# Deployment Guide

## Prerequisites

1. **Environment Variables**: Create a `.env` file with:
   ```bash
   PRIVATE_KEY=your_private_key_here
   DEPLOYER_ADDRESS=your_deployer_address
   ADMIN_ADDRESS=your_admin_address  # Optional, defaults to deployer
   ARBITRUM_SEPOLIA_RPC=https://sepolia-rollup.arbitrum.io/rpc
   ARBISCAN_API_KEY=your_arbiscan_api_key  # For verification
   ```

2. **Load Environment**:
   ```bash
   source .env
   ```

3. **Testnet ETH**: Get Arbitrum Sepolia ETH from [Arbitrum faucet](https://faucet.quicknode.com/arbitrum/sepolia)

## Deployment Steps

### Step 1: Deploy to Arbitrum Sepolia

```bash
forge script script/Deploy.s.sol:DeployScript \
  --rpc-url $ARBITRUM_SEPOLIA_RPC \
  --broadcast \
  --verify \
  --etherscan-api-key $ARBISCAN_API_KEY \
  -vvvv
```

**Expected Output:**
```
=== Deploying to Arbitrum Sepolia ===
Deployer: 0x...
Admin: 0x...

1. Deploying MockUSDC...
MockUSDC deployed at: 0x...

2. Deploying PositionNFT...
PositionNFT deployed at: 0x...

3. Deploying MarketFactory...
MarketFactory deployed at: 0x...

4. Authorizing factory in PositionNFT...
Factory authorized

5. Creating test market: Bitcoin price on Feb 1, 2026...
Test market created at: 0x...
```

### Step 2: Verify Contracts (if auto-verify failed)

If the `--verify` flag didn't work, manually verify each contract:

```bash
# Verify MockUSDC
forge verify-contract <USDC_ADDRESS> \
  src/mocks/MockUSDC.sol:MockUSDC \
  --chain-id 421614 \
  --etherscan-api-key $ARBISCAN_API_KEY \
  --constructor-args $(cast abi-encode "constructor(string,string)" "USD Coin (Mock)" "USDC") \
  --watch

# Verify PositionNFT
forge verify-contract <POSITION_NFT_ADDRESS> \
  src/PositionNFT.sol:PositionNFT \
  --chain-id 421614 \
  --etherscan-api-key $ARBISCAN_API_KEY \
  --constructor-args $(cast abi-encode "constructor(string,string)" "Skepsis Position" "SKPS-POS") \
  --watch

# Verify MarketFactory
forge verify-contract <FACTORY_ADDRESS> \
  src/MarketFactory.sol:MarketFactory \
  --chain-id 421614 \
  --etherscan-api-key $ARBISCAN_API_KEY \
  --constructor-args $(cast abi-encode "constructor(address,address,address,uint256,uint256,uint256,uint256,uint256)" <USDC> <POSITION_NFT> <ADMIN> 200 2000 100000000 1000000000000 100) \
  --watch
```

### Step 3: Save Deployment Addresses

Create `deployments/arbitrum-sepolia.json`:

```json
{
  "network": "arbitrum-sepolia",
  "chainId": 421614,
  "deployer": "0x...",
  "admin": "0x...",
  "timestamp": "2026-01-24T12:00:00Z",
  "contracts": {
    "MockUSDC": "0x...",
    "PositionNFT": "0x...",
    "MarketFactory": "0x...",
    "TestMarket": "0x..."
  },
  "config": {
    "defaultFeeBps": 200,
    "protocolFeeBps": 2000,
    "minPoolBalance": 100000000,
    "maxPoolBalance": 1000000000000,
    "maxBuckets": 100
  },
  "verification": {
    "MockUSDC": "https://sepolia.arbiscan.io/address/0x...",
    "PositionNFT": "https://sepolia.arbiscan.io/address/0x...",
    "MarketFactory": "https://sepolia.arbiscan.io/address/0x..."
  }
}
```

## Testing Deployed Contracts

### 1. Check Market State

```bash
# Get market info
cast call <MARKET_ADDRESS> "bucketCount()(uint256)" --rpc-url $ARBITRUM_SEPOLIA_RPC
cast call <MARKET_ADDRESS> "poolBalance()(uint256)" --rpc-url $ARBITRUM_SEPOLIA_RPC
cast call <MARKET_ADDRESS> "status()(uint8)" --rpc-url $ARBITRUM_SEPOLIA_RPC  # 0=ACTIVE
```

### 2. Buy Shares (Test Trade)

```bash
# Approve USDC
cast send <USDC_ADDRESS> \
  "approve(address,uint256)" <MARKET_ADDRESS> 1000000000 \
  --rpc-url $ARBITRUM_SEPOLIA_RPC \
  --private-key $PRIVATE_KEY

# Buy shares in bucket 5 ($90k-$100k range)
cast send <MARKET_ADDRESS> \
  "buyShares(uint256,uint256,uint256)" 5 100000000 0 \
  --rpc-url $ARBITRUM_SEPOLIA_RPC \
  --private-key $PRIVATE_KEY
```

### 3. Query Position NFT

```bash
# Get token ID for marketId=0, bucketId=5
# tokenId = (0 << 128) | 5 = 5
cast call <POSITION_NFT_ADDRESS> \
  "balanceOf(address,uint256)" <YOUR_ADDRESS> 5 \
  --rpc-url $ARBITRUM_SEPOLIA_RPC
```

### 4. Check Prices

```bash
# Calculate price for bucket 5
cast call <FACTORY_ADDRESS> \
  "getMarket(uint256)(address)" 0 \
  --rpc-url $ARBITRUM_SEPOLIA_RPC

cast call <MARKET_ADDRESS> \
  "_calculatePrice(uint256)(uint256)" 5 \
  --rpc-url $ARBITRUM_SEPOLIA_RPC
```

## Troubleshooting

### Gas Issues
- Arbitrum Sepolia gas is usually low, but if transactions fail, check gas limits
- Use `--gas-limit 5000000` for complex transactions

### Verification Failed
- Wait a few minutes after deployment
- Try manual verification with exact constructor args
- Check Arbiscan API key is valid

### Transaction Reverted
- Check error message: `cast call <ADDRESS> <FUNCTION> --trace`
- Verify USDC approval before trades
- Ensure pool balance > trade amount

### RPC Issues
- Alternative RPC: `https://arbitrum-sepolia.publicnode.com`
- Check rate limits on public RPCs

## Admin Functions

### Update Fees (Admin Only)

```bash
cast send <FACTORY_ADDRESS> \
  "setDefaultFeeBps(uint256)" 250 \
  --rpc-url $ARBITRUM_SEPOLIA_RPC \
  --private-key $ADMIN_PRIVATE_KEY
```

### Pause Market (Emergency)

```bash
cast send <FACTORY_ADDRESS> \
  "pauseMarket(uint256)" 0 \
  --rpc-url $ARBITRUM_SEPOLIA_RPC \
  --private-key $ADMIN_PRIVATE_KEY
```

## Next Steps

1. ✅ Deploy contracts
2. ✅ Verify on Arbiscan
3. ✅ Create test market
4. 🔄 Execute test trades
5. 🔄 Monitor for 24-48 hours
6. 🔄 Collect feedback
7. 🔄 Prepare for mainnet

## Mainnet Deployment Checklist

Before mainnet:
- [ ] Complete security audit
- [ ] Fix all audit findings
- [ ] Test on Sepolia for 1 week minimum
- [ ] Update USDC address to mainnet: `0xaf88d065e77c8cC2239327C5EDb3A432268e5831`
- [ ] Deploy Gnosis Safe multisig (3/5)
- [ ] Transfer admin to multisig
- [ ] Deploy to Arbitrum One
- [ ] Create 3-5 genesis markets
- [ ] Monitor for 48 hours
- [ ] Public announcement

## Shipping Hardening Checklist (V1)

### Contract Controls

- [ ] For each market, configure alpha decay (`configureAlphaDecay`) with:
  - [ ] `alphaFinal` floor between 20%-40% of `alphaInitial`
  - [ ] `decayDuration` aligned to market timeline
  - [ ] `decayStartTime` not before market opens
- [ ] If using LP vaults, verify `createMarketWithVault` path and confirm:
  - [ ] `vaultByMarket[market]` is set
  - [ ] `LMSRMarket.lpVault()` equals vault address
- [ ] Confirm `getWithdrawableSurplus()` is zero on fresh market (no unsafe early withdrawal)

### Access Boundaries

- [ ] Confirm unauthorized addresses cannot call:
  - [ ] `addLiquidity`
  - [ ] `withdrawSurplus`
  - [ ] `setLPVault`
- [ ] Confirm sell/claim paths require owned position tokens when PositionNFT is configured

### Regression Gates

- [ ] `forge test` passes in full
- [ ] Invariants pass, including position-accounting invariant suite
- [ ] Gas benchmark run recorded (`test/gas/GasBenchmark.t.sol`)

### Emergency Readiness (Contract-Level)

- [ ] Verify `pauseMarket` flow and ownership model
- [ ] Verify resolution and LP withdrawal paths after pause/resume scenarios in testnet rehearsal
