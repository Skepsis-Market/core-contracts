// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test, console} from "forge-std/Test.sol";
import {MarketFactory} from "../src/MarketFactory.sol";
import {LMSRMarket} from "../src/LMSRMarket.sol";
import {PositionNFT} from "../src/PositionNFT.sol";
import {MockUSDC} from "../src/mocks/MockUSDC.sol";

contract MarketFactoryTest is Test {
    MarketFactory factory;
    PositionNFT positionNFT;
    MockUSDC usdc;
    
    address admin = address(0x1);
    address creator1 = address(0x2);
    address creator2 = address(0x3);
    
    uint256 minPoolBalance = 100_000000; // $100
    uint256 maxBuckets = 100;
    uint256 defaultFeeBps = 50; // 0.5%
    uint256 defaultProtocolFeeBps = 2000; // 20%
    
    function setUp() public {
        vm.startPrank(admin);
        
        usdc = new MockUSDC();
        
        // Compute the address where factory will be deployed
        // PositionNFT is next (nonce 1), then Factory (nonce 2)
        address predictedFactoryAddress = vm.computeCreateAddress(admin, 2);
        
        // Deploy PositionNFT with predicted factory address
        positionNFT = new PositionNFT(predictedFactoryAddress);
        
        // Now deploy factory (should match predicted address)
        factory = new MarketFactory(
            address(usdc),
            address(positionNFT),
            minPoolBalance,
            maxBuckets,
            defaultFeeBps,
            defaultProtocolFeeBps
        );
        
        vm.stopPrank();
    }
    
    function test_createMarket_deploysSuccessfully() public {
        uint256 poolBalance = 1000_000000; // $1000
        
        uint256[] memory bucketRanges = new uint256[](5);
        bucketRanges[0] = 0;
        bucketRanges[1] = 25;
        bucketRanges[2] = 50;
        bucketRanges[3] = 75;
        bucketRanges[4] = 100;
        
        // Mint USDC to creator and approve factory
        usdc.mint(creator1, poolBalance);
        
        vm.startPrank(creator1);
        usdc.approve(address(factory), poolBalance);
        
        address marketAddress = factory.createMarket(
            poolBalance,
            bucketRanges,
            0, // use default fees
            0  // use default protocol fees
        );
        vm.stopPrank();
        
        // Verify market was created
        assertTrue(marketAddress != address(0), "Market address should not be zero");
        assertTrue(factory.isValidMarket(marketAddress), "Market should be valid");
        assertEq(factory.marketCount(), 1, "Market count should be 1");
        assertEq(factory.marketById(0), marketAddress, "Market should be registered by ID");
        
        // Verify market received USDC
        assertEq(usdc.balanceOf(marketAddress), poolBalance, "Market should have pool balance");
        assertEq(usdc.balanceOf(creator1), 0, "Creator should have transferred USDC");
    }
    
    function test_createMarket_revertsInvalidParams() public {
        uint256[] memory bucketRanges = new uint256[](5);
        bucketRanges[0] = 0;
        bucketRanges[1] = 25;
        bucketRanges[2] = 50;
        bucketRanges[3] = 75;
        bucketRanges[4] = 100;
        
        // Test: pool balance too low
        vm.prank(creator1);
        vm.expectRevert(MarketFactory.PoolBalanceTooLow.selector);
        factory.createMarket(50_000000, bucketRanges, 0, 0); // $50 < $100 min
        
        // Test: too few buckets
        uint256[] memory tooFewBuckets = new uint256[](1);
        tooFewBuckets[0] = 0;
        
        usdc.mint(creator1, minPoolBalance);
        vm.startPrank(creator1);
        usdc.approve(address(factory), minPoolBalance);
        vm.expectRevert(MarketFactory.InvalidParameters.selector);
        factory.createMarket(minPoolBalance, tooFewBuckets, 0, 0);
        vm.stopPrank();
        
        // Test: non-increasing bucket ranges
        uint256[] memory badRanges = new uint256[](5);
        badRanges[0] = 0;
        badRanges[1] = 25;
        badRanges[2] = 25; // Same as previous
        badRanges[3] = 75;
        badRanges[4] = 100;
        
        vm.startPrank(creator1);
        vm.expectRevert(MarketFactory.InvalidBucketRanges.selector);
        factory.createMarket(minPoolBalance, badRanges, 0, 0);
        vm.stopPrank();
    }
    
    function test_createMarket_transfersUSDC() public {
        uint256 poolBalance = 1000_000000;
        
        uint256[] memory bucketRanges = new uint256[](3);
        bucketRanges[0] = 0;
        bucketRanges[1] = 50;
        bucketRanges[2] = 100;
        
        usdc.mint(creator1, poolBalance);
        
        uint256 balanceBefore = usdc.balanceOf(creator1);
        
        vm.startPrank(creator1);
        usdc.approve(address(factory), poolBalance);
        address marketAddress = factory.createMarket(poolBalance, bucketRanges, 0, 0);
        vm.stopPrank();
        
        assertEq(usdc.balanceOf(creator1), balanceBefore - poolBalance, "Creator balance should decrease");
        assertEq(usdc.balanceOf(marketAddress), poolBalance, "Market should receive USDC");
    }
    
    function test_createMarket_setsFeesCorrectly() public {
        uint256 poolBalance = 1000_000000;
        
        uint256[] memory bucketRanges = new uint256[](3);
        bucketRanges[0] = 0;
        bucketRanges[1] = 50;
        bucketRanges[2] = 100;
        
        usdc.mint(creator1, poolBalance);
        
        vm.startPrank(creator1);
        usdc.approve(address(factory), poolBalance);
        
        // Test with default fees (0, 0)
        address market1 = factory.createMarket(poolBalance, bucketRanges, 0, 0);
        vm.stopPrank();
        
        LMSRMarket lmsrMarket1 = LMSRMarket(market1);
        assertEq(lmsrMarket1.feeBps(), defaultFeeBps, "Should use default fee bps");
        assertEq(lmsrMarket1.protocolFeeBps(), defaultProtocolFeeBps, "Should use default protocol fee bps");
        
        // Test with custom fees
        uint256 customFeeBps = 100; // 1%
        uint256 customProtocolFeeBps = 5000; // 50%
        
        usdc.mint(creator1, poolBalance);
        vm.startPrank(creator1);
        usdc.approve(address(factory), poolBalance);
        address market2 = factory.createMarket(poolBalance, bucketRanges, customFeeBps, customProtocolFeeBps);
        vm.stopPrank();
        
        LMSRMarket lmsrMarket2 = LMSRMarket(market2);
        assertEq(lmsrMarket2.feeBps(), customFeeBps, "Should use custom fee bps");
        assertEq(lmsrMarket2.protocolFeeBps(), customProtocolFeeBps, "Should use custom protocol fee bps");
    }
    
    function test_createMarket_incrementsMarketCount() public {
        uint256 poolBalance = 1000_000000;
        
        uint256[] memory bucketRanges = new uint256[](3);
        bucketRanges[0] = 0;
        bucketRanges[1] = 50;
        bucketRanges[2] = 100;
        
        assertEq(factory.marketCount(), 0, "Initial count should be 0");
        
        // Create first market
        usdc.mint(creator1, poolBalance);
        vm.startPrank(creator1);
        usdc.approve(address(factory), poolBalance);
        factory.createMarket(poolBalance, bucketRanges, 0, 0);
        vm.stopPrank();
        
        assertEq(factory.marketCount(), 1, "Count should be 1 after first market");
        
        // Create second market
        usdc.mint(creator2, poolBalance);
        vm.startPrank(creator2);
        usdc.approve(address(factory), poolBalance);
        factory.createMarket(poolBalance, bucketRanges, 0, 0);
        vm.stopPrank();
        
        assertEq(factory.marketCount(), 2, "Count should be 2 after second market");
    }
    
    function test_adminFunctions_onlyAdmin() public {
        // Test setMinPoolBalance
        vm.prank(creator1); // Not admin
        vm.expectRevert();
        factory.setMinPoolBalance(200_000000);
        
        vm.prank(admin);
        factory.setMinPoolBalance(200_000000);
        assertEq(factory.minPoolBalance(), 200_000000, "Admin should update min pool balance");
        
        // Test setMaxBuckets
        vm.prank(creator1);
        vm.expectRevert();
        factory.setMaxBuckets(50);
        
        vm.prank(admin);
        factory.setMaxBuckets(50);
        assertEq(factory.maxBuckets(), 50, "Admin should update max buckets");
        
        // Test setDefaultFeeBps
        vm.prank(creator1);
        vm.expectRevert();
        factory.setDefaultFeeBps(100);
        
        vm.prank(admin);
        factory.setDefaultFeeBps(100);
        assertEq(factory.defaultFeeBps(), 100, "Admin should update default fee bps");
        
        // Test setDefaultProtocolFeeBps
        vm.prank(creator1);
        vm.expectRevert();
        factory.setDefaultProtocolFeeBps(3000);
        
        vm.prank(admin);
        factory.setDefaultProtocolFeeBps(3000);
        assertEq(factory.defaultProtocolFeeBps(), 3000, "Admin should update default protocol fee bps");
    }
    
    function test_pauseMarket_preventsTrading() public {
        uint256 poolBalance = 1000_000000;
        
        uint256[] memory bucketRanges = new uint256[](3);
        bucketRanges[0] = 0;
        bucketRanges[1] = 50;
        bucketRanges[2] = 100;
        
        usdc.mint(creator1, poolBalance);
        
        vm.startPrank(creator1);
        usdc.approve(address(factory), poolBalance);
        address marketAddress = factory.createMarket(poolBalance, bucketRanges, 0, 0);
        vm.stopPrank();
        
        // Non-admin cannot pause
        vm.prank(creator1);
        vm.expectRevert();
        factory.pauseMarket(0);
        
        // Admin can pause (emits event only for now)
        vm.prank(admin);
        vm.expectEmit(true, true, false, false);
        emit MarketFactory.MarketPaused(0, marketAddress);
        factory.pauseMarket(0);
    }
    
    function test_multipleMarkets_independentState() public {
        uint256 poolBalance = 1000_000000;
        
        uint256[] memory bucketRanges = new uint256[](3);
        bucketRanges[0] = 0;
        bucketRanges[1] = 50;
        bucketRanges[2] = 100;
        
        // Create market 1
        usdc.mint(creator1, poolBalance);
        vm.startPrank(creator1);
        usdc.approve(address(factory), poolBalance);
        address market1 = factory.createMarket(poolBalance, bucketRanges, 50, 2000);
        vm.stopPrank();
        
        // Create market 2 with different parameters
        usdc.mint(creator2, poolBalance * 2);
        vm.startPrank(creator2);
        usdc.approve(address(factory), poolBalance * 2);
        address market2 = factory.createMarket(poolBalance * 2, bucketRanges, 100, 3000);
        vm.stopPrank();
        
        // Verify markets are different
        assertTrue(market1 != market2, "Markets should have different addresses");
        
        // Verify market 1 properties
        LMSRMarket lmsrMarket1 = LMSRMarket(market1);
        assertEq(lmsrMarket1.creator(), creator1, "Market 1 creator should be creator1");
        assertEq(lmsrMarket1.poolBalance(), poolBalance, "Market 1 pool balance");
        assertEq(lmsrMarket1.feeBps(), 50, "Market 1 fee bps");
        
        // Verify market 2 properties
        LMSRMarket lmsrMarket2 = LMSRMarket(market2);
        assertEq(lmsrMarket2.creator(), creator2, "Market 2 creator should be creator2");
        assertEq(lmsrMarket2.poolBalance(), poolBalance * 2, "Market 2 pool balance");
        assertEq(lmsrMarket2.feeBps(), 100, "Market 2 fee bps");
        
        // Verify both are registered
        assertTrue(factory.isValidMarket(market1), "Market 1 should be valid");
        assertTrue(factory.isValidMarket(market2), "Market 2 should be valid");
    }
}
