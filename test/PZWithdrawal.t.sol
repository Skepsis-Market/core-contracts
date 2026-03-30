// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {LMSRMarket} from "../src/LMSRMarket.sol";
import {MockUSDC} from "../src/mocks/MockUSDC.sol";

contract PZWithdrawalTest is Test {
    LMSRMarket market;
    MockUSDC usdc;

    address factory = address(0xFACE);
    address creator = address(0x1);
    address positionNFT = address(0x2);
    address attacker = address(0xBEEF);
    address vault = address(0xA11CE);

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

        market = new LMSRMarket(
            1,
            creator,
            factory,
            address(usdc),
            positionNFT,
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

        usdc.mint(address(market), 1000_000000);
    }

    function test_withdrawableSurplus_zeroAtInit() public view {
        assertEq(market.getWithdrawableSurplus(), 0);
    }

    function test_addLiquidity_canCreateSurplus() public {
        uint256 amount = 1000_000000;
        usdc.mint(creator, amount);

        vm.startPrank(creator);
        usdc.approve(address(market), amount);
        market.addLiquidity(amount);
        vm.stopPrank();

        assertGt(market.getWithdrawableSurplus(), 0);
    }

    function test_withdrawSurplus_revertsWhenNoSurplus() public {
        vm.prank(creator);
        vm.expectRevert(LMSRMarket.NoSurplusAvailable.selector);
        market.withdrawSurplus(creator, 1);
    }

    function test_withdrawSurplus_transfersAndUpdatesPool() public {
        uint256 amount = 1000_000000;
        usdc.mint(creator, amount);

        vm.startPrank(creator);
        usdc.approve(address(market), amount);
        market.addLiquidity(amount);

        uint256 withdrawable = market.getWithdrawableSurplus();
        uint256 balanceBefore = usdc.balanceOf(creator);

        market.withdrawSurplus(creator, withdrawable / 2);
        vm.stopPrank();

        uint256 balanceAfter = usdc.balanceOf(creator);
        assertEq(balanceAfter - balanceBefore, withdrawable / 2);
    }

    function test_addLiquidity_revertsForUnauthorized() public {
        usdc.mint(attacker, 100_000000);

        vm.startPrank(attacker);
        usdc.approve(address(market), 100_000000);
        vm.expectRevert(LMSRMarket.Unauthorized.selector);
        market.addLiquidity(100_000000);
        vm.stopPrank();
    }

    function test_withdrawSurplus_revertsForUnauthorized() public {
        vm.prank(attacker);
        vm.expectRevert(LMSRMarket.Unauthorized.selector);
        market.withdrawSurplus(attacker, 1);
    }

    function test_lpVault_authorizedForLiquidityOps() public {
        vm.prank(creator);
        market.setLPVault(vault);

        usdc.mint(vault, 1000_000000);

        vm.startPrank(vault);
        usdc.approve(address(market), 1000_000000);
        market.addLiquidity(1000_000000);

        uint256 withdrawable = market.getWithdrawableSurplus();
        assertGt(withdrawable, 0);

        market.withdrawSurplus(vault, withdrawable / 3);
        vm.stopPrank();

        assertGt(usdc.balanceOf(vault), 0);
    }
}
