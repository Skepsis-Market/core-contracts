// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {LMSRMarket} from "../../src/LMSRMarket.sol";
import {PositionNFT} from "../../src/PositionNFT.sol";
import {MockUSDC} from "../../src/mocks/MockUSDC.sol";

contract PositionHandler is Test {
    LMSRMarket public market;
    PositionNFT public positionNFT;
    MockUSDC public usdc;
    address[] public traders;

    constructor(LMSRMarket _market, PositionNFT _positionNFT, MockUSDC _usdc, address[] memory _traders) {
        market = _market;
        positionNFT = _positionNFT;
        usdc = _usdc;
        traders = _traders;
    }

    function buy(uint256 traderIndex, uint256 bucketId, uint256 amountUSDC) public {
        traderIndex = bound(traderIndex, 0, traders.length - 1);
        bucketId = bound(bucketId, 0, market.bucketCount() - 1);
        amountUSDC = bound(amountUSDC, 1_000000, 200_000000);

        address trader = traders[traderIndex];
        if (usdc.balanceOf(trader) < amountUSDC) {
            usdc.mint(trader, amountUSDC * 2);
        }

        uint256 lower = market.marketMin() + (bucketId * market.bucketWidth());
        uint256 upper = lower + market.bucketWidth();

        vm.startPrank(trader);
        usdc.approve(address(market), amountUSDC);
        try market.buySharesRange(lower, upper, amountUSDC, 0, 0, address(0)) {} catch {}
        vm.stopPrank();
    }

    function sell(uint256 traderIndex, uint256 bucketId, uint256 percentBps) public {
        traderIndex = bound(traderIndex, 0, traders.length - 1);
        bucketId = bound(bucketId, 0, market.bucketCount() - 1);
        percentBps = bound(percentBps, 1, 10000);

        address trader = traders[traderIndex];
        uint256 tokenId = (uint256(uint128(market.marketId())) << 128) | (uint256(uint64(bucketId)) << 64) | uint256(uint64(bucketId));
        uint256 balance = positionNFT.balanceOf(trader, tokenId);
        if (balance == 0) return;

        uint256 sharesToSell = (balance * percentBps) / 10000;
        if (sharesToSell == 0) sharesToSell = 1;

        uint256 lower = market.marketMin() + (bucketId * market.bucketWidth());
        uint256 upper = lower + market.bucketWidth();

        vm.prank(trader);
        try market.sellSharesRange(lower, upper, sharesToSell, 0, address(0)) {} catch {}
    }
}

contract PositionAccountingInvariantTest is StdInvariant, Test {
    LMSRMarket market;
    PositionNFT positionNFT;
    MockUSDC usdc;
    PositionHandler handler;

    address creator = address(0x1);
    address[] traders;

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

        uint256[] memory bucketRanges = new uint256[](6);
        for (uint256 i = 0; i < 6; i++) {
            bucketRanges[i] = i * 20;
        }

        market = new LMSRMarket(
            1,
            creator,
            address(this),
            address(usdc),
            address(positionNFT),
            5_000_000000,
            10000_000000,
            bucketRanges,
            50,
            2000,
            _defaultMetadata(),
            address(0xFEE)
        );

        positionNFT.authorizeMarket(address(market), 1);
        usdc.mint(address(market), 10000_000000);

        for (uint256 i = 0; i < 5; i++) {
            traders.push(address(uint160(0x2000 + i)));
        }

        handler = new PositionHandler(market, positionNFT, usdc, traders);

        targetContract(address(handler));
        bytes4[] memory selectors = new bytes4[](2);
        selectors[0] = handler.buy.selector;
        selectors[1] = handler.sell.selector;

        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    /// @notice Sum of user position tokens for a bucket must not exceed bucket shares liability.
    function invariant_userTokenSupplyNeverExceedsBucketShares() public view {
        for (uint256 bucketId = 0; bucketId < market.bucketCount(); bucketId++) {
            uint256 tokenId = (uint256(uint128(market.marketId())) << 128) | (uint256(uint64(bucketId)) << 64) | uint256(uint64(bucketId));
            uint256 userTokenSum = 0;

            for (uint256 i = 0; i < traders.length; i++) {
                userTokenSum += positionNFT.balanceOf(traders[i], tokenId);
            }

            (uint256 bucketShares,,) = market.buckets(bucketId);
            assertLe(userTokenSum, bucketShares, "User token balances exceed bucket shares");
        }
    }
}
