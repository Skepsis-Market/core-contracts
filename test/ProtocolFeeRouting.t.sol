// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {LMSRMarket} from "../src/LMSRMarket.sol";
import {MockUSDC} from "../src/mocks/MockUSDC.sol";

contract ProtocolFeeRoutingTest is Test {
    LMSRMarket market;
    MockUSDC usdc;

    address creator = address(0x1);
    address buyer = address(0x2);

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

        (uint256[] memory seedIds, uint256[] memory seedShares) = _uniformSeeds(4, 1000_000000);

        market = new LMSRMarket(LMSRMarket.InitParams({
                marketId: 1,
                creator: creator,
                factory: address(0xFACE),
                usdcToken: address(usdc),
                positionNFT: address(0),
                alpha: 500_000000,
                poolBalance: 1000_000000,
                bucketWidth: 25,
                maxBucketId: // bucketWidth
            3,
                seededBucketIds: // maxBucketId
            seedIds,
                seededShares: seedShares,
                feeBps: 50,
                protocolFeeBps: 2000,
                metadata: _defaultMetadata(),
                protocolFeeCollector: address(0xFEE)
            }));

        usdc.mint(address(market), 1000_000000);
        usdc.mint(buyer, 100_000000);
    }

    function _buyBucket(uint256 bucketId, uint256 amount, uint256 minShares) internal returns (uint256) {
        uint256 lower = bucketId * market.bucketWidth();
        return market.buySharesRange(lower, lower + market.bucketWidth(), amount, minShares, 0, address(0));
    }

    function test_protocolCollector_receivesFeeOnBuy() public {
        address collector = market.protocolFeeCollector();
        uint256 collectorBefore = usdc.balanceOf(collector);

        vm.startPrank(buyer);
        usdc.approve(address(market), 100_000000);
        _buyBucket(0, 10_000000, 0);
        vm.stopPrank();

        uint256 collectorAfter = usdc.balanceOf(collector);
        assertGt(collectorAfter, collectorBefore, "Collector should receive protocol fee");
    }
}
