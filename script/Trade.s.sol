// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {LMSRMarket} from "../src/LMSRMarket.sol";
import {MockUSDC} from "../src/mocks/MockUSDC.sol";
import {IPositionNFT} from "../src/interfaces/IPositionNFT.sol";

/// @notice Buy or sell shares on a deployed LMSRMarket.
///
/// Two contracts in this file — pick via --target-contract:
///
///   BuyScript  — spend USDC, receive position NFT shares
///   SellScript — return position NFT shares, receive USDC back
///
/// BUY
///   forge script script/Trade.s.sol:BuyScript \
///     --rpc-url $FUJI_RPC_URL --broadcast --chain-id 43113
///
/// SELL
///   forge script script/Trade.s.sol:SellScript \
///     --rpc-url $FUJI_RPC_URL --broadcast --chain-id 43113
///
/// PREREQUISITES
/// ─────────────
///   .env must have: MARKET_ADDRESS, USDC_ADDRESS, PRIVATE_KEY, DEPLOYER_ADDRESS
///   Market must be ACTIVE (not resolved or cancelled)
///
/// TOKEN IDs
/// ─────────
///   Each (market, bucket) pair has a unique ERC-1155 token ID:
///   tokenId = (marketId << 128) | (bucketId << 64) | bucketId
///   These are minted on buy and burned on sell / claim.
///
/// NOTE: MockUSDC.mint() is called automatically in BuyScript for testnet convenience.
///       Remove/replace with a USDC transfer for a real USDC token.

// ─── helpers ─────────────────────────────────────────────────────────────────

/// @dev Mirrors LMSRMarket._tokenIdForBucket
function tokenIdForBucket(uint256 marketId, uint256 bucketId) pure returns (uint256) {
    return (uint256(uint128(marketId)) << 128)
        | (uint256(uint64(bucketId)) << 64)
        | uint256(uint64(bucketId));
}

// ─── Buy ──────────────────────────────────────────────────────────────────────

contract BuyScript is Script {

    // ─── Configure ──────────────────────────────────────────────────────────
    uint256 constant BUCKET_ID   = 9;             // Which bucket to buy into (0-indexed)
    uint256 constant AMOUNT_USDC = 100_000000;    // $100 USDC to spend (6 decimals)

    // Slippage protection: minimum shares you are willing to receive.
    // 0 = no protection (fine for testnet; always set in production).
    // To compute a safe value: run a dry-run first and take 99% of the quoted shares.
    uint256 constant MIN_SHARES  = 0;
    // ────────────────────────────────────────────────────────────────────────

    function run() public {
        address trader = vm.envAddress("DEPLOYER_ADDRESS");
        uint256 pk     = vm.envUint("PRIVATE_KEY");

        LMSRMarket market = LMSRMarket(vm.envAddress("MARKET_ADDRESS"));
        MockUSDC   usdc   = MockUSDC(vm.envAddress("USDC_ADDRESS"));
        IPositionNFT nft  = IPositionNFT(market.positionNFT());

        uint256 mid     = market.marketId();
        uint256 tokenId = tokenIdForBucket(mid, BUCKET_ID);

        (uint256 bShares,, uint256 bLower, uint256 bUpper) = market.buckets(BUCKET_ID);

        console.log("=================================================");
        console.log("  Buy Shares");
        console.log("=================================================");
        console.log("Market:          ", address(market));
        console.log("Market ID:       ", mid);
        console.log("Market status:   ", uint256(market.status()));
        console.log("Trader:          ", trader);
        console.log("Bucket:          ", BUCKET_ID);
        console.log("  range:         ", bLower, "-", bUpper);
        console.log("  value unit:    ", market.valueUnit());
        console.log("  shares before: ", bShares);
        console.log("Spending:        ", AMOUNT_USDC / 1e6, "USDC");
        console.log("Trader USDC bal: ", usdc.balanceOf(trader) / 1e6, "USDC");
        console.log("Trader NFT bal:  ", nft.balanceOf(trader, tokenId));
        console.log("Pool before:     ", market.poolBalance() / 1e6, "USDC");

        require(market.status() == LMSRMarket.MarketStatus.ACTIVE, "Market not active");

        vm.startBroadcast(pk);

        // Testnet only: mint USDC to fund the trade.
        usdc.mint(trader, AMOUNT_USDC);
        usdc.approve(address(market), AMOUNT_USDC);

        uint256 lower = market.marketMin() + (BUCKET_ID * market.bucketWidth());
        uint256 sharesMinted = market.buySharesRange(lower, lower + market.bucketWidth(), AMOUNT_USDC, MIN_SHARES, 0, address(0));

        vm.stopBroadcast();

        console.log("\n  Trade executed!");
        console.log("  Shares minted:  ", sharesMinted);
        console.log("  NFT bal after:  ", nft.balanceOf(trader, tokenId));
        console.log("  Pool after:     ", market.poolBalance() / 1e6, "USDC");
        console.log("  Trader USDC:    ", usdc.balanceOf(trader) / 1e6, "USDC");

        console.log("\n  Token ID for this position:");
        console.log("  ", tokenId);
    }
}

// ─── Sell ─────────────────────────────────────────────────────────────────────

contract SellScript is Script {

    // ─── Configure ──────────────────────────────────────────────────────────
    uint256 constant BUCKET_ID      = 9;            // Bucket to sell from (must match held position)

    // Shares to sell (6 decimals — same unit as USDC).
    // Check your current balance first:
    //   cast call $POSITION_NFT_ADDRESS "balanceOf(address,uint256)(uint256)" $DEPLOYER <tokenId>
    // Use 0 here and the script will print your balance, then set the real value.
    uint256 constant SHARES_TO_SELL = 0;            // 0 = dry run: prints balance only, no tx

    // Slippage protection: minimum USDC to accept.
    // 0 = no protection (fine for testnet).
    uint256 constant MIN_PAYOUT     = 0;
    // ────────────────────────────────────────────────────────────────────────

    function run() public {
        address trader = vm.envAddress("DEPLOYER_ADDRESS");
        uint256 pk     = vm.envUint("PRIVATE_KEY");

        LMSRMarket   market = LMSRMarket(vm.envAddress("MARKET_ADDRESS"));
        MockUSDC     usdc   = MockUSDC(vm.envAddress("USDC_ADDRESS"));
        IPositionNFT nft    = IPositionNFT(market.positionNFT());

        uint256 mid     = market.marketId();
        uint256 tokenId = tokenIdForBucket(mid, BUCKET_ID);
        uint256 nftBal  = nft.balanceOf(trader, tokenId);

        (uint256 bShares,, uint256 bLower, uint256 bUpper) = market.buckets(BUCKET_ID);

        console.log("=================================================");
        console.log("  Sell Shares");
        console.log("=================================================");
        console.log("Market:          ", address(market));
        console.log("Market ID:       ", mid);
        console.log("Trader:          ", trader);
        console.log("Bucket:          ", BUCKET_ID);
        console.log("  range:         ", bLower, "-", bUpper);
        console.log("  value unit:    ", market.valueUnit());
        console.log("  bucket shares: ", bShares);
        console.log("Trader NFT bal:  ", nftBal);
        console.log("Shares to sell:  ", SHARES_TO_SELL);
        console.log("Trader USDC bal: ", usdc.balanceOf(trader) / 1e6, "USDC");
        console.log("Pool before:     ", market.poolBalance() / 1e6, "USDC");

        if (SHARES_TO_SELL == 0) {
            console.log("\n  SHARES_TO_SELL is 0 -- dry run only (no tx broadcast).");
            console.log("  Set SHARES_TO_SELL to your NFT balance above and rerun.");
            return;
        }

        require(nftBal >= SHARES_TO_SELL, "Insufficient position NFT balance");
        require(market.status() == LMSRMarket.MarketStatus.ACTIVE, "Market not active");

        vm.startBroadcast(pk);

        uint256 lower = market.marketMin() + (BUCKET_ID * market.bucketWidth());
        uint256 payout = market.sellSharesRange(lower, lower + market.bucketWidth(), SHARES_TO_SELL, MIN_PAYOUT, address(0));

        vm.stopBroadcast();

        console.log("\n  Trade executed!");
        console.log("  Payout (USDC):  ", payout / 1e6, "USDC");
        console.log("  NFT bal after:  ", nft.balanceOf(trader, tokenId));
        console.log("  Trader USDC:    ", usdc.balanceOf(trader) / 1e6, "USDC");
        console.log("  Pool after:     ", market.poolBalance() / 1e6, "USDC");
    }
}
