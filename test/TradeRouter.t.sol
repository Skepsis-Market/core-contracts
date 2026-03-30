// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test, console} from "forge-std/Test.sol";
import {TradeRouter} from "../src/TradeRouter.sol";
import {LMSRMarket} from "../src/LMSRMarket.sol";
import {PositionNFT} from "../src/PositionNFT.sol";
import {MockUSDC} from "../src/mocks/MockUSDC.sol";
import {Ownable} from "@openzeppelin/access/Ownable.sol";

/// @dev Minimal mock factory that validates markets
contract MockFactory {
    mapping(address => bool) public isValidMarket;
    function setValid(address market) external { isValidMarket[market] = true; }
}

contract TradeRouterTest is Test {
    TradeRouter router;
    LMSRMarket market;
    PositionNFT posNFT;
    MockUSDC usdc;
    MockFactory mockFactory;

    address factory;
    address creator = address(0x1);
    address trader = address(0x456);

    uint256 marketId = 1;
    uint256 poolBalance = 1000_000000;

    function _uniformSeeds(uint256 numBuckets, uint256 pool)
        internal pure returns (uint256[] memory ids, uint256[] memory shares)
    {
        ids = new uint256[](numBuckets);
        shares = new uint256[](numBuckets);
        uint256 per = pool / numBuckets;
        for (uint256 i = 0; i < numBuckets; i++) {
            ids[i] = i;
            shares[i] = per;
        }
        shares[numBuckets - 1] += pool - (per * numBuckets);
    }

    function setUp() public {
        usdc = new MockUSDC();
        factory = address(this);
        posNFT = new PositionNFT(factory);
        mockFactory = new MockFactory();
        router = new TradeRouter(address(usdc), address(posNFT), address(mockFactory));

        (uint256[] memory seedIds, uint256[] memory seedShares) = _uniformSeeds(4, poolBalance);

        market = new LMSRMarket(
            marketId, creator, factory, address(usdc), address(posNFT),
            500_000000, poolBalance, 25, 3, seedIds, seedShares, 50, 2000,
            LMSRMarket.MarketMetadata("", "", "", "", creator, 0, 0, 0),
            address(0xFEE)
        );

        posNFT.authorizeMarket(address(market), marketId);
        mockFactory.setValid(address(market));
        usdc.mint(address(market), poolBalance);

        // Fund trader — two one-time approvals
        usdc.mint(trader, 1000_000000);
        vm.startPrank(trader);
        usdc.approve(address(router), type(uint256).max);
        posNFT.setApprovalForAll(address(router), true);
        vm.stopPrank();
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                              BUY
    // ═══════════════════════════════════════════════════════════════════════

    function test_buy_mintsNFTToUser() public {
        vm.prank(trader);
        uint256 shares = router.buy(market, 0, 25, 50_000000, 0, 0);

        assertGt(shares, 0);

        uint256 tokenId = _tokenId(0, 0);
        assertEq(posNFT.balanceOf(trader, tokenId), shares, "NFT in trader wallet");
        assertEq(posNFT.balanceOf(address(router), tokenId), 0, "Router holds no NFTs");
    }

    function test_buy_pullsUSDCFromUser() public {
        uint256 balBefore = usdc.balanceOf(trader);
        vm.prank(trader);
        router.buy(market, 0, 25, 50_000000, 0, 0);
        assertEq(usdc.balanceOf(trader), balBefore - 50_000000);
    }

    function test_buy_routerHoldsNoFunds() public {
        vm.prank(trader);
        router.buy(market, 0, 25, 50_000000, 0, 0);
        assertEq(usdc.balanceOf(address(router)), 0);
    }

    function test_buy_multipleBuysOneApproval() public {
        vm.startPrank(trader);
        uint256 s1 = router.buy(market, 0, 25, 20_000000, 0, 0);
        uint256 s2 = router.buy(market, 25, 50, 20_000000, 0, 0);
        uint256 s3 = router.buy(market, 50, 75, 20_000000, 0, 0);
        vm.stopPrank();

        assertGt(s1, 0);
        assertGt(s2, 0);
        assertGt(s3, 0);
    }

    function test_buy_revertsOnZeroAmount() public {
        vm.prank(trader);
        vm.expectRevert(TradeRouter.ZeroAmount.selector);
        router.buy(market, 0, 25, 0, 0, 0);
    }

    function test_buy_respectsSlippage() public {
        vm.prank(trader);
        vm.expectRevert(LMSRMarket.InvalidParameters.selector);
        router.buy(market, 0, 25, 10_000000, type(uint256).max, 0);
    }

    function test_buy_rejectsInvalidMarket() public {
        LMSRMarket fakeMarket = LMSRMarket(address(0xDEAD));
        vm.prank(trader);
        vm.expectRevert(TradeRouter.InvalidMarket.selector);
        router.buy(fakeMarket, 0, 25, 10_000000, 0, 0);
    }

    function test_buy_enforcesMaxBuyAmount() public {
        // Set $5 cap
        router.setMaxBuyAmount(5_000000);

        // $5 buy works
        vm.prank(trader);
        uint256 shares = router.buy(market, 0, 25, 5_000000, 0, 0);
        assertGt(shares, 0);

        // $6 buy reverts
        vm.prank(trader);
        vm.expectRevert(TradeRouter.BuyExceedsLimit.selector);
        router.buy(market, 0, 25, 6_000000, 0, 0);
    }

    function test_buy_noLimitWhenZero() public {
        // Default is 0 = no limit
        assertEq(router.maxBuyAmount(), 0);

        vm.prank(trader);
        uint256 shares = router.buy(market, 0, 25, 100_000000, 0, 0);
        assertGt(shares, 0);
    }

    function test_setMaxBuyAmount_onlyOwner() public {
        vm.prank(trader);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, trader));
        router.setMaxBuyAmount(5_000000);
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                              SELL
    // ═══════════════════════════════════════════════════════════════════════

    function test_sell_returnsUSDCToUser() public {
        // Buy via router
        vm.prank(trader);
        uint256 shares = router.buy(market, 0, 25, 50_000000, 0, 0);

        // Sell via router
        uint256 balBefore = usdc.balanceOf(trader);
        vm.prank(trader);
        uint256 payout = router.sell(market, 0, 25, shares, 0);

        assertGt(payout, 0, "Should receive payout");
        assertEq(usdc.balanceOf(trader), balBefore + payout, "USDC to trader");
        assertEq(usdc.balanceOf(address(router)), 0, "Router holds no USDC");
    }

    function test_sell_partialSell() public {
        vm.prank(trader);
        uint256 shares = router.buy(market, 0, 25, 50_000000, 0, 0);

        // Sell half
        vm.prank(trader);
        router.sell(market, 0, 25, shares / 2, 0);

        // Trader still has remaining shares
        uint256 tokenId = _tokenId(0, 0);
        assertGt(posNFT.balanceOf(trader, tokenId), 0, "Should have remaining shares");
        assertEq(posNFT.balanceOf(address(router), tokenId), 0, "Router holds nothing");
    }

    function test_sell_routerHoldsNoNFTs() public {
        vm.prank(trader);
        uint256 shares = router.buy(market, 0, 25, 50_000000, 0, 0);

        vm.prank(trader);
        router.sell(market, 0, 25, shares, 0);

        uint256 tokenId = _tokenId(0, 0);
        assertEq(posNFT.balanceOf(address(router), tokenId), 0);
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                              CLAIM
    // ═══════════════════════════════════════════════════════════════════════

    function test_claim_paysUserAfterResolution() public {
        // Buy bucket 2 (value 50-75)
        vm.prank(trader);
        uint256 shares = router.buy(market, 50, 75, 50_000000, 0, 0);

        // Resolve to bucket 2
        vm.prank(creator);
        market.resolveMarket(50);

        // Claim via router
        uint256 tokenId = _tokenId(2, 2);
        uint256 balBefore = usdc.balanceOf(trader);
        vm.prank(trader);
        uint256 payout = router.claim(market, tokenId);

        assertEq(payout, shares, "Payout = shares ($1 each)");
        assertEq(usdc.balanceOf(trader), balBefore + payout, "USDC to trader");
        assertEq(posNFT.balanceOf(trader, tokenId), 0, "NFTs burned");
        assertEq(posNFT.balanceOf(address(router), tokenId), 0, "Router holds nothing");
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                           FULL LIFECYCLE
    // ═══════════════════════════════════════════════════════════════════════

    function test_fullLifecycle_buyThenSellViaRouter() public {
        vm.startPrank(trader);

        uint256 balStart = usdc.balanceOf(trader);

        // Buy
        uint256 shares = router.buy(market, 25, 50, 100_000000, 0, 0);
        assertGt(shares, 0);

        // Sell all back
        uint256 payout = router.sell(market, 25, 50, shares, 0);
        assertGt(payout, 0);

        vm.stopPrank();

        // Trader lost some to fees, but has no positions
        uint256 balEnd = usdc.balanceOf(trader);
        assertLt(balEnd, balStart, "Lost fees");
        assertEq(posNFT.balanceOf(trader, _tokenId(1, 1)), 0, "No positions left");
    }

    function test_fullLifecycle_buyClaimViaRouter() public {
        vm.prank(trader);
        uint256 shares = router.buy(market, 0, 25, 100_000000, 0, 0);

        vm.prank(creator);
        market.resolveMarket(0);

        uint256 tokenId = _tokenId(0, 0);
        uint256 balBefore = usdc.balanceOf(trader);
        vm.prank(trader);
        router.claim(market, tokenId);

        assertEq(usdc.balanceOf(trader), balBefore + shares);
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                              HELPERS
    // ═══════════════════════════════════════════════════════════════════════

    function _tokenId(uint256 lo, uint256 hi) internal view returns (uint256) {
        return (uint256(uint128(market.marketId())) << 128)
            | (uint256(uint64(lo)) << 64)
            | uint256(uint64(hi));
    }
}
