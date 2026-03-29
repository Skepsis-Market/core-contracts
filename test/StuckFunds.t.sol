// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test, console} from "forge-std/Test.sol";
import {LMSRMarket} from "../src/LMSRMarket.sol";
import {PositionNFT} from "../src/PositionNFT.sol";
import {MockUSDC} from "../src/mocks/MockUSDC.sol";

/// @notice Prove that initial LP shares in the winning bucket are stuck
contract StuckFundsTest is Test {
    LMSRMarket market;
    PositionNFT posNFT;
    MockUSDC usdc;

    address factory;
    address creator = address(0x1);
    address trader = address(0x456);

    uint256 poolBalance = 10_000_000000; // $10K
    uint256 bucketCount = 4;

    function setUp() public {
        usdc = new MockUSDC();
        factory = address(this);
        posNFT = new PositionNFT(factory);

        uint256[] memory ranges = new uint256[](5);
        ranges[0] = 0;
        ranges[1] = 25;
        ranges[2] = 50;
        ranges[3] = 75;
        ranges[4] = 100;

        // feeBps=50 (0.5%), protocolFeeBps=0 (all fees to LP, none to protocol)
        market = new LMSRMarket(
            1, creator, factory, address(usdc), address(posNFT),
            500_000000, poolBalance, ranges, new uint256[](0), 50, 0,
            LMSRMarket.MarketMetadata("", "", "", "", creator, 0, 0, 0),
            address(0)
        );

        posNFT.authorizeMarket(address(market), 1);
        usdc.mint(address(market), poolBalance);
        usdc.mint(trader, 100_000_000000);
    }

    function test_stuckFunds_traceEveryDollar() public {
        // === INITIAL STATE ===
        uint256 initialSharesPerBucket = poolBalance / bucketCount; // 2,500 USDC
        console.log("=== INITIAL STATE ===");
        console.log("Pool balance:          ", market.poolBalance() / 1e6, "USDC");
        console.log("Shares per bucket:     ", initialSharesPerBucket / 1e6, "USDC");
        console.log("Buckets:               ", bucketCount);

        // === TRADER BUYS BUCKET 2 ===
        vm.startPrank(trader);
        usdc.approve(address(market), type(uint256).max);
        posNFT.setApprovalForAll(address(market), true);

        uint256 buyAmount = 5_000_000000; // $5K
        uint256 lower = market.marketMin() + (2 * market.bucketWidth());
        uint256 upper = lower + market.bucketWidth();
        uint256 sharesBought = market.buySharesRange(lower, upper, buyAmount, 0, 0, trader);
        vm.stopPrank();

        (uint256 bucket2Shares,,,) = market.buckets(2);
        uint256 traderSharesBought = sharesBought;

        console.log("\n=== AFTER TRADE ===");
        console.log("Trader bought shares:  ", traderSharesBought / 1e6);
        console.log("Bucket 2 total shares: ", bucket2Shares / 1e6);
        console.log("  Initial (LP):        ", initialSharesPerBucket / 1e6);
        console.log("  Trader:              ", traderSharesBought / 1e6);
        console.log("Pool balance:          ", market.poolBalance() / 1e6, "USDC");

        // === RESOLVE: BUCKET 2 WINS ===
        vm.prank(creator);
        market.resolveMarket(50); // value 50 = bucket 2

        console.log("\n=== AFTER RESOLUTION ===");
        console.log("Winning bucket:        ", market.winningBucket());
        (uint256 winShares,,,) = market.buckets(2);
        console.log("Winning bucket shares: ", winShares / 1e6);
        console.log("Pool balance:          ", market.poolBalance() / 1e6, "USDC");

        // === LP WITHDRAWS ===
        uint256 creatorBalBefore = usdc.balanceOf(creator);
        vm.prank(creator);
        market.withdrawLP();
        uint256 lpWithdrawal = usdc.balanceOf(creator) - creatorBalBefore;

        console.log("\n=== AFTER LP WITHDRAWAL ===");
        console.log("LP withdrew:           ", lpWithdrawal / 1e6, "USDC");
        console.log("Pool balance:          ", market.poolBalance() / 1e6, "USDC");
        (uint256 winSharesAfterLP,,,) = market.buckets(2);
        console.log("Winning shares remain: ", winSharesAfterLP / 1e6);

        // === TRADER CLAIMS ===
        uint256 tokenId = (uint256(uint128(1)) << 128) | (uint256(uint64(2)) << 64) | uint256(uint64(2));
        uint256 traderNFTBalance = posNFT.balanceOf(trader, tokenId);
        console.log("\n=== TRADER CLAIM ===");
        console.log("Trader NFT balance:    ", traderNFTBalance / 1e6);

        uint256 traderBalBefore = usdc.balanceOf(trader);
        vm.prank(trader);
        market.claim(tokenId, trader);
        uint256 traderClaimed = usdc.balanceOf(trader) - traderBalBefore;

        console.log("Trader claimed:        ", traderClaimed / 1e6, "USDC");
        console.log("Pool balance:          ", market.poolBalance() / 1e6, "USDC");

        // === FEE ACCOUNTING ===
        console.log("\n=== FEE ACCOUNTING ===");
        console.log("feesCollectedLP:       ", market.feesCollectedLP() / 1e6, "USDC");
        console.log("feesCollectedProtocol: ", market.feesCollectedProtocol() / 1e6, "USDC");
        console.log("lpFeesAccrued:         ", market.lpFeesAccrued() / 1e6, "USDC");
        console.log("totalVolume:           ", market.totalVolume() / 1e6, "USDC");
        console.log("feesCollectedLP raw:   ", market.feesCollectedLP());
        console.log("totalDeposited:        ", market.totalDeposited() / 1e6, "USDC");

        // === FINAL ACCOUNTING ===
        uint256 contractBalance = usdc.balanceOf(address(market));
        console.log("\n=== FINAL STATE ===");
        console.log("USDC stuck in contract:", contractBalance / 1e6, "USDC");
        console.log("Pool balance (state):  ", market.poolBalance() / 1e6, "USDC");

        // The stuck amount should equal the initial shares in the winning bucket
        console.log("\n=== VERDICT ===");
        console.log("Initial shares bucket 2:", initialSharesPerBucket / 1e6, "USDC");
        console.log("USDC stuck:             ", contractBalance / 1e6, "USDC");

        if (contractBalance > 0) {
            console.log(">>> FUNDS ARE STUCK! Nobody can claim them. <<<");
        } else {
            console.log(">>> All funds accounted for. <<<");
        }
    }
}
