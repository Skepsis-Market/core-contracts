// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {LMSRMarket} from "../src/LMSRMarket.sol";
import {MockUSDC} from "../src/mocks/MockUSDC.sol";

contract LMSRMarketAlphaDecayTest is Test {
    LMSRMarket market;
    MockUSDC usdc;

    address factory = address(0xFACE);
    address creator = address(0x1);
    address positionNFT = address(0x2);
    address trader = address(0x123);

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

    uint256 marketId = 1;
    uint256 alphaParam = 500_000000;
    uint256 poolBalance = 1000_000000;
    uint256 feeBps = 50;
    uint256 protocolFeeBps = 2000;

    function setUp() public {
        usdc = new MockUSDC();

        (uint256[] memory seedIds, uint256[] memory seedShares) = _uniformSeeds(4, poolBalance);

        market = new LMSRMarket(LMSRMarket.InitParams({
                marketId: marketId,
                creator: creator,
                factory: factory,
                usdcToken: address(usdc),
                positionNFT: positionNFT,
                alpha: alphaParam,
                poolBalance: poolBalance,
                bucketWidth: 25,
                maxBucketId: // bucketWidth
            3,
                seededBucketIds: // maxBucketId
            seedIds,
                seededShares: seedShares,
                feeBps: feeBps,
                protocolFeeBps: protocolFeeBps,
                metadata: _defaultMetadata(),
                protocolFeeCollector: address(0xFEE)
            }));

        usdc.mint(address(market), poolBalance);
    }

    function _buyBucket(uint256 bucketId, uint256 amount, uint256 minShares) internal returns (uint256) {
        uint256 lower = bucketId * market.bucketWidth();
        return market.buySharesRange(lower, lower + market.bucketWidth(), amount, minShares, 0, address(0));
    }

    function test_decayDisabledByDefault() public view {
        assertFalse(market.decayDuration() > 0 && market.alphaFinal() < market.alphaInitial());
        assertEq(market.alphaInitial(), market.alpha());
        assertEq(market.alphaFinal(), market.alpha());
    }

    function test_configureAlphaDecay_setsParameters() public {
        uint256 initialAlpha = market.alphaInitial();
        uint256 finalAlpha = (initialAlpha * 30) / 100;
        uint256 start = block.timestamp + 1 hours;
        uint256 duration = 7 days;

        vm.prank(creator);
        market.configureAlphaDecay(finalAlpha, start, duration);

        assertTrue(market.decayDuration() > 0 && market.alphaFinal() < market.alphaInitial());
        assertEq(market.alphaFinal(), finalAlpha);
        assertEq(market.decayStartTime(), start);
        assertEq(market.decayDuration(), duration);
    }

    function test_configureAlphaDecay_revertsIfFloorTooLow() public {
        uint256 initialAlpha = market.alphaInitial();
        uint256 belowMinFloor = (initialAlpha * 9) / 100; // below 10%

        vm.prank(creator);
        vm.expectRevert(LMSRMarket.InvalidParameters.selector);
        market.configureAlphaDecay(belowMinFloor, block.timestamp, 1 days);
    }

    function test_syncAlpha_updatesOnlyAfterEpochBoundary() public {
        uint256 initialAlpha = market.alphaInitial();
        uint256 finalAlpha = (initialAlpha * 20) / 100;

        vm.prank(creator);
        market.configureAlphaDecay(finalAlpha, block.timestamp, 10 days);

        // Before epoch passes, sync should be a no-op
        market.syncAlpha();
        assertEq(market.alpha(), initialAlpha);

        vm.warp(block.timestamp + market.ALPHA_EPOCH_LENGTH() + 1);
        market.syncAlpha();

        assertLt(market.alpha(), initialAlpha);
        assertGt(market.alpha(), finalAlpha);
    }

    function test_syncAlpha_reachesFloorAfterDuration() public {
        uint256 initialAlpha = market.alphaInitial();
        uint256 finalAlpha = (initialAlpha * 25) / 100;

        vm.prank(creator);
        market.configureAlphaDecay(finalAlpha, block.timestamp, 2 days);

        vm.warp(block.timestamp + 2 days + market.ALPHA_EPOCH_LENGTH() + 1);
        market.syncAlpha();

        assertEq(market.alpha(), finalAlpha);
    }

    function test_tradeTriggersSyncAlpha() public {
        uint256 initialAlpha = market.alphaInitial();
        uint256 finalAlpha = (initialAlpha * 40) / 100;

        vm.prank(creator);
        market.configureAlphaDecay(finalAlpha, block.timestamp, 10 days);

        usdc.mint(trader, 100_000000);
        vm.prank(trader);
        usdc.approve(address(market), 100_000000);

        vm.warp(block.timestamp + market.ALPHA_EPOCH_LENGTH() + 1);

        vm.startPrank(trader);
        _buyBucket(0, 10_000000, 0);
        vm.stopPrank();

        assertLt(market.alpha(), initialAlpha);
    }
}
