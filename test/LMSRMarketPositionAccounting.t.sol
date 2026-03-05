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

    function setUp() public {
        usdc = new MockUSDC();
        positionNFT = new PositionNFT(address(this));

        uint256[] memory bucketRanges = new uint256[](5);
        bucketRanges[0] = 0;
        bucketRanges[1] = 25;
        bucketRanges[2] = 50;
        bucketRanges[3] = 75;
        bucketRanges[4] = 100;

        market = new LMSRMarket(
            MARKET_ID,
            creator,
            address(this),
            address(usdc),
            address(positionNFT),
            500_000000,
            1000_000000,
            bucketRanges,
            50,
            2000,
            _defaultMetadata(),
            address(0xFEE)
        );

        positionNFT.authorizeMarket(address(market), MARKET_ID);
        usdc.mint(address(market), 1000_000000);
    }

    function test_buyShares_mintsPositionTokens() public {
        usdc.mint(buyer, 100_000000);

        vm.startPrank(buyer);
        usdc.approve(address(market), 100_000000);
        uint256 shares = market.buyShares(0, 10_000000, 0);
        vm.stopPrank();

        uint256 tokenId = (uint256(uint128(MARKET_ID)) << 128) | uint256(uint128(0));
        assertEq(positionNFT.balanceOf(buyer, tokenId), shares);
    }

    function test_sellShares_revertsWithoutPositionOwnership() public {
        usdc.mint(buyer, 100_000000);

        vm.startPrank(buyer);
        usdc.approve(address(market), 100_000000);
        uint256 shares = market.buyShares(0, 10_000000, 0);
        vm.stopPrank();

        vm.prank(attacker);
        vm.expectRevert(LMSRMarket.InsufficientBalance.selector);
        market.sellShares(0, shares, 0);
    }

    function test_claimWinnings_revertsWithoutWinningTokens() public {
        usdc.mint(buyer, 100_000000);

        vm.startPrank(buyer);
        usdc.approve(address(market), 100_000000);
        uint256 shares = market.buyShares(0, 10_000000, 0);
        vm.stopPrank();

        vm.prank(creator);
        market.resolveMarket(0);

        vm.prank(attacker);
        vm.expectRevert(LMSRMarket.InsufficientBalance.selector);
        market.claimWinnings(0, shares);
    }
}
