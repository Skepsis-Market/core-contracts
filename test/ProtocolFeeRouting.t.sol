// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

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

    function setUp() public {
        usdc = new MockUSDC();

        uint256[] memory bucketRanges = new uint256[](5);
        bucketRanges[0] = 0;
        bucketRanges[1] = 25;
        bucketRanges[2] = 50;
        bucketRanges[3] = 75;
        bucketRanges[4] = 100;

        market = new LMSRMarket(
            1,
            creator,
            address(0xFACE),
            address(usdc),
            address(0),
            500_000000,
            1000_000000,
            bucketRanges,
            50,
            2000,
            _defaultMetadata()
        );

        usdc.mint(address(market), 1000_000000);
        usdc.mint(buyer, 100_000000);
    }

    function test_protocolCollector_receivesFeeOnBuy() public {
        address collector = market.PROTOCOL_FEE_COLLECTOR();
        uint256 collectorBefore = usdc.balanceOf(collector);

        vm.startPrank(buyer);
        usdc.approve(address(market), 100_000000);
        market.buyShares(0, 10_000000, 0);
        vm.stopPrank();

        uint256 collectorAfter = usdc.balanceOf(collector);
        assertGt(collectorAfter, collectorBefore, "Collector should receive protocol fee");
    }
}
