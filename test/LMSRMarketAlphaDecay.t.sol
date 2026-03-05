// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

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

    uint256 marketId = 1;
    uint256 alphaParam = 500_000000;
    uint256 poolBalance = 1000_000000;
    uint256 feeBps = 50;
    uint256 protocolFeeBps = 2000;

    function setUp() public {
        usdc = new MockUSDC();

        uint256[] memory bucketRanges = new uint256[](5);
        bucketRanges[0] = 0;
        bucketRanges[1] = 25;
        bucketRanges[2] = 50;
        bucketRanges[3] = 75;
        bucketRanges[4] = 100;

        market = new LMSRMarket(
            marketId,
            creator,
            factory,
            address(usdc),
            positionNFT,
            alphaParam,
            poolBalance,
            bucketRanges,
            feeBps,
            protocolFeeBps,
            _defaultMetadata(),
            address(0xFEE)
        );

        usdc.mint(address(market), poolBalance);
    }

    function test_decayDisabledByDefault() public view {
        assertFalse(market.isAlphaDecayConfigured());
        assertFalse(market.needsAlphaSync());
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

        assertTrue(market.isAlphaDecayConfigured());
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

        vm.prank(trader);
        market.buyShares(0, 10_000000, 0);

        assertLt(market.alpha(), initialAlpha);
    }
}
