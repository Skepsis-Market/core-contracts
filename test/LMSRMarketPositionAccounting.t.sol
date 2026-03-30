// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {LMSRMarket} from "../src/LMSRMarket.sol";
import {PositionNFT} from "../src/PositionNFT.sol";
import {MockUSDC} from "../src/mocks/MockUSDC.sol";

contract LMSRMarketPositionAccountingTest is Test {
    LMSRMarket market;
    PositionNFT positionNFT;
    MockUSDC usdc;

    uint256 internal constant MARKET_ID = 1;
    address internal creator = address(0x1);
    address internal buyer = address(0x123);
    address internal attacker = address(0xBEEF);

    function _defaultMetadata() internal pure returns (LMSRMarket.MarketMetadata memory) {
        return LMSRMarket.MarketMetadata({
            name: "",
            description: "",
            resolutionCriteria: "",
            valueUnit: "",
            resolver: address(0),
            biddingDeadline: 0,
            scheduledResolutionTime: 0,
            minBetSize: 0
        });
    }

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
        positionNFT = new PositionNFT(address(this));

        (uint256[] memory seedIds, uint256[] memory seedShares) = _uniformSeeds(4, 1000_000000);

        market = new LMSRMarket(
            MARKET_ID,
            creator,
            address(this),
            address(usdc),
            address(positionNFT),
            500_000000,
            1000_000000,
            25,        // bucketWidth
            3,         // maxBucketId
            seedIds,
            seedShares,
            50,
            2000,
            _defaultMetadata(),
            address(0xFEE)
        );

        positionNFT.authorizeMarket(address(market), MARKET_ID);
        usdc.mint(address(market), 1000_000000);
    }

    function _buyBucket(uint256 bucketId, uint256 amount, uint256 minShares) internal returns (uint256) {
        uint256 lower = bucketId * market.bucketWidth();
        return market.buySharesRange(lower, lower + market.bucketWidth(), amount, minShares, 0, address(0));
    }

    function _sellBucket(uint256 bucketId, uint256 shares, uint256 minPayout) internal returns (uint256) {
        uint256 lower = bucketId * market.bucketWidth();
        return market.sellSharesRange(lower, lower + market.bucketWidth(), shares, minPayout, address(0));
    }

    function _claimBucket(uint256 bucketId) internal returns (uint256) {
        uint256 tokenId = (uint256(uint128(market.marketId())) << 128) | (uint256(uint64(bucketId)) << 64) | uint256(uint64(bucketId));
        return market.claim(tokenId, address(0));
    }

    function test_buyShares_mintsPositionTokens() public {
        usdc.mint(buyer, 100_000000);

        vm.startPrank(buyer);
        usdc.approve(address(market), 100_000000);
        uint256 shares = _buyBucket(0, 10_000000, 0);
        vm.stopPrank();

        uint256 tokenId = (uint256(uint128(MARKET_ID)) << 128) | (uint256(uint64(0)) << 64) | uint256(uint64(0));
        assertEq(positionNFT.balanceOf(buyer, tokenId), shares);
    }

    function test_sellShares_revertsWithoutPositionOwnership() public {
        usdc.mint(buyer, 100_000000);

        vm.startPrank(buyer);
        usdc.approve(address(market), 100_000000);
        uint256 shares = _buyBucket(0, 10_000000, 0);
        vm.stopPrank();

        uint256 lower = 0;
        uint256 width = market.bucketWidth();
        vm.prank(attacker);
        vm.expectRevert(LMSRMarket.InsufficientBalance.selector);
        market.sellSharesRange(lower, lower + width, shares, 0, address(0));
    }

    function test_claim_revertsWithoutWinningTokens() public {
        usdc.mint(buyer, 100_000000);

        vm.startPrank(buyer);
        usdc.approve(address(market), 100_000000);
        _buyBucket(0, 10_000000, 0);
        vm.stopPrank();

        vm.prank(creator);
        market.resolveMarket(0);

        uint256 tokenId = (uint256(uint128(MARKET_ID)) << 128) | (uint256(uint64(0)) << 64) | uint256(uint64(0));
        vm.prank(attacker);
        vm.expectRevert(LMSRMarket.InsufficientBalance.selector);
        market.claim(tokenId, address(0));
    }
}
