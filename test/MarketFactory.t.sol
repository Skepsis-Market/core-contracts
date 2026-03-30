// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test, console} from "forge-std/Test.sol";
import {MarketFactory} from "../src/MarketFactory.sol";
import {LMSRMarket} from "../src/LMSRMarket.sol";
import {PositionNFT} from "../src/PositionNFT.sol";
import {MockUSDC} from "../src/mocks/MockUSDC.sol";
import {Vault} from "../src/Vault.sol";

contract MarketFactoryTest is Test {
    MarketFactory factory;
    PositionNFT positionNFT;
    MockUSDC usdc;
    Vault vault;

    address admin    = address(0x1);
    address creator1 = address(0x2);
    address creator2 = address(0x3);

    uint256 minPoolBalance       = 100_000000; // $100
    uint256 maxBuckets           = 100;
    uint256 defaultFeeBps        = 50;         // 0.5%
    uint256 defaultProtocolFeeBps = 2000;      // 20%

    function setUp() public {
        vm.startPrank(admin);

        usdc = new MockUSDC();

        // Deploy LMSRMarket implementation (EIP-1167 clone source for all markets)
        uint256[] memory implSeedIds = new uint256[](2);
        uint256[] memory implSeedShares = new uint256[](2);
        implSeedIds[0] = 0; implSeedIds[1] = 1;
        implSeedShares[0] = 1; implSeedShares[1] = 1; // minimal valid
        LMSRMarket.MarketMetadata memory implMeta;
        // Implementation needs valid init — use minimal valid params
        address lmsrImpl = address(new LMSRMarket(
            0, address(0), address(0), address(usdc), address(0),
            1, 2, 1, 1, implSeedIds, implSeedShares, 0, 0, implMeta, address(0xFEE) // alpha=1, pool=2, width=1, maxBid=1
        ));

        // nonce 0: usdc, nonce 1: impl, nonce 2: positionNFT -> factory at nonce 3
        address predictedFactoryAddress = vm.computeCreateAddress(admin, 3);

        // Deploy PositionNFT with predicted factory address
        positionNFT = new PositionNFT(predictedFactoryAddress);

        // Now deploy factory (should match predicted address)
        factory = new MarketFactory(
            lmsrImpl,
            address(usdc),
            address(positionNFT),
            minPoolBalance,
            maxBuckets,
            defaultFeeBps,
            defaultProtocolFeeBps,
            address(0xFEE)
        );

        // Deploy vault and wire up
        vault = new Vault(address(usdc), "Vault", "sVLT", admin);
        factory.setVault(address(vault));
        vault.setFactory(address(factory));

        // Whitelist creators
        factory.setCreatorAllowance(creator1, 10);
        factory.setCreatorAllowance(creator2, 10);

        vm.stopPrank();

        // Fund vault via LP deposit (all market seeds come from vault)
        address lp = address(0x4);
        usdc.mint(lp, 1_000_000_000000);
        vm.startPrank(lp);
        usdc.approve(address(vault), 1_000_000_000000);
        vault.deposit(1_000_000_000000, lp);
        vm.stopPrank();
    }

    // ── Helpers ──────────────────────────────────────────────────────────────

    /// @dev Build a MarketParams struct with absolute bucket indexing
    function _params(
        uint256 seedAmount,
        uint256 minValue,
        uint256 maxValue,
        uint256 bucketCount,
        uint256 feeBps,
        uint256 protoBps
    ) internal pure returns (MarketFactory.MarketParams memory p) {
        uint256 bw = (maxValue - minValue) / bucketCount;
        uint256 startBucket = minValue / bw;
        uint256 maxBid = startBucket + bucketCount - 1;
        
        uint256[] memory seedIds = new uint256[](bucketCount);
        uint256[] memory seedShares = new uint256[](bucketCount);
        uint256 per = seedAmount / bucketCount;
        for (uint256 i = 0; i < bucketCount; i++) {
            seedIds[i] = startBucket + i;
            seedShares[i] = per;
        }
        seedShares[bucketCount - 1] += seedAmount - (per * bucketCount);
        
        p.alpha           = seedAmount / _isqrt(bucketCount);
        p.seedAmount      = seedAmount;
        p.bucketWidth     = bw;
        p.maxBucketId     = maxBid;
        p.seededBucketIds = seedIds;
        p.seededShares    = seedShares;
    }

    function _isqrt(uint256 x) internal pure returns (uint256) {
        if (x == 0) return 0;
        if (x <= 3) return 1;
        uint256 z = (x + 1) / 2;
        uint256 y = x;
        while (z < y) { y = z; z = (x / z + z) / 2; }
        return y;
    }

    /// @dev Convenience wrapper: build params + call createMarket, return market address only
    function _cm(
        uint256 seedAmount,
        uint256 minValue,
        uint256 maxValue,
        uint256 bucketCount,
        uint256 feeBps,
        uint256 protoBps
    ) internal returns (address) {
        return factory.createMarket(_params(seedAmount, minValue, maxValue, bucketCount, feeBps, protoBps));
    }

    // ── Tests ─────────────────────────────────────────────────────────────────

    function test_createMarket_deploysSuccessfully() public {
        uint256 poolBalance = 1000_000000; // $1000

        // 4 buckets from 0-100 (replaces bucketRanges = [0, 25, 50, 75, 100])
        uint256 minValue = 0;
        uint256 maxValue = 100;
        uint256 bucketCount = 4;

        usdc.mint(creator1, poolBalance); // creator no longer pays, but need for approve

        vm.prank(creator1);
        address marketAddress = factory.createMarket(
            _params(poolBalance, minValue, maxValue, bucketCount, 0, 0)
        );

        // Verify market
        assertTrue(marketAddress != address(0), "Market address should not be zero");
        assertTrue(factory.isValidMarket(marketAddress), "Market should be valid");
        assertEq(factory.marketCount(), 1, "Market count should be 1");
        assertEq(factory.marketById(0), marketAddress, "Market should be registered by ID");
        assertEq(usdc.balanceOf(marketAddress), poolBalance, "Market should have seed from vault");
    }

    function test_createMarket_revertsIfNotWhitelisted() public {
        address stranger = address(0x999);
        uint256 poolBalance = 1000_000000;

        usdc.mint(stranger, poolBalance);
        vm.prank(stranger);
        vm.expectRevert(MarketFactory.NotWhitelisted.selector);
        factory.createMarket(_params(poolBalance, 0, 100, 2, 0, 0));
    }

    function test_createMarket_decrementsAllowance() public {
        uint256 poolBalance = 1000_000000;

        assertEq(factory.creatorAllowance(creator1), 10);

        usdc.mint(creator1, poolBalance);
        vm.prank(creator1);
        _cm(poolBalance, 0, 100, 2, 0, 0);

        assertEq(factory.creatorAllowance(creator1), 9, "Allowance should decrement");
    }

    function test_createMarket_revertsWhenAllowanceExhausted() public {
        // Give creator1 exactly 1 slot, use it, then fail
        vm.prank(admin);
        factory.setCreatorAllowance(creator1, 1);

        uint256 poolBalance = 1000_000000;

        usdc.mint(creator1, poolBalance * 2);
        vm.startPrank(creator1);
        _cm(poolBalance, 0, 100, 2, 0, 0); // uses the 1 slot

        vm.expectRevert(MarketFactory.NotWhitelisted.selector);
        factory.createMarket(_params(poolBalance, 0, 100, 2, 0, 0));
        vm.stopPrank();
    }

    function test_createMarket_revertsInvalidParams() public {
        // Pool balance too low
        vm.prank(creator1);
        vm.expectRevert(MarketFactory.PoolBalanceTooLow.selector);
        factory.createMarket(_params(50_000000, 0, 100, 4, 0, 0)); // $50 < $100 min

        // Too few buckets (seededBucketIds.length < 2)
        MarketFactory.MarketParams memory pFew;
        pFew.alpha = 500_000000;
        pFew.seedAmount = minPoolBalance;
        pFew.bucketWidth = 50;
        pFew.maxBucketId = 1;
        pFew.seededBucketIds = new uint256[](1);
        pFew.seededBucketIds[0] = 0;
        pFew.seededShares = new uint256[](1);
        pFew.seededShares[0] = minPoolBalance;

        vm.prank(creator1);
        vm.expectRevert(MarketFactory.InvalidParameters.selector);
        factory.createMarket(pFew);

        // Mismatched seed arrays
        MarketFactory.MarketParams memory pBad;
        pBad.alpha = 500_000000;
        pBad.seedAmount = minPoolBalance;
        pBad.bucketWidth = 50;
        pBad.maxBucketId = 1;
        pBad.seededBucketIds = new uint256[](2);
        pBad.seededBucketIds[0] = 0;
        pBad.seededBucketIds[1] = 1;
        pBad.seededShares = new uint256[](3); // wrong length

        vm.prank(creator1);
        vm.expectRevert(MarketFactory.InvalidBucketRanges.selector);
        factory.createMarket(pBad);
    }

    function test_createMarket_transfersUSDC() public {
        uint256 poolBalance = 1000_000000;

        uint256 vaultBalBefore = usdc.balanceOf(address(vault));

        vm.prank(creator1);
        address marketAddress = _cm(poolBalance, 0, 100, 2, 0, 0);

        assertEq(usdc.balanceOf(address(vault)), vaultBalBefore - poolBalance, "Vault balance should decrease");
        assertEq(usdc.balanceOf(marketAddress), poolBalance, "Market should receive seed from vault");
    }

    function test_createMarket_usesFactoryDefaultFees() public {
        uint256 poolBalance = 1000_000000;

        usdc.mint(creator1, poolBalance);
        vm.prank(creator1);
        address market1 = _cm(poolBalance, 0, 100, 2, 0, 0);

        // Both markets always get factory defaults
        assertEq(LMSRMarket(market1).feeBps(), defaultFeeBps, "Should use default fee bps");
        assertEq(LMSRMarket(market1).protocolFeeBps(), defaultProtocolFeeBps, "Should use default protocol fee bps");
    }

    function test_createMarket_incrementsMarketCount() public {
        uint256 poolBalance = 1000_000000;

        assertEq(factory.marketCount(), 0, "Initial count should be 0");

        usdc.mint(creator1, poolBalance);
        vm.prank(creator1);
        _cm(poolBalance, 0, 100, 2, 0, 0);

        assertEq(factory.marketCount(), 1, "Count should be 1 after first market");

        usdc.mint(creator2, poolBalance);
        vm.prank(creator2);
        _cm(poolBalance, 0, 100, 2, 0, 0);

        assertEq(factory.marketCount(), 2, "Count should be 2 after second market");
    }

    function test_adminFunctions_onlyAdmin() public {
        // setMinPoolBalance
        vm.prank(creator1);
        vm.expectRevert();
        factory.setMinPoolBalance(200_000000);

        vm.prank(admin);
        factory.setMinPoolBalance(200_000000);
        assertEq(factory.minPoolBalance(), 200_000000);

        // setMaxBuckets
        vm.prank(creator1);
        vm.expectRevert();
        factory.setMaxBuckets(50);

        vm.prank(admin);
        factory.setMaxBuckets(50);
        assertEq(factory.maxBuckets(), 50);

        // setDefaultFeeBps
        vm.prank(creator1);
        vm.expectRevert();
        factory.setDefaultFeeBps(100);

        vm.prank(admin);
        factory.setDefaultFeeBps(100);
        assertEq(factory.defaultFeeBps(), 100);

        // setDefaultProtocolFeeBps
        vm.prank(creator1);
        vm.expectRevert();
        factory.setDefaultProtocolFeeBps(3000);

        vm.prank(admin);
        factory.setDefaultProtocolFeeBps(3000);
        assertEq(factory.defaultProtocolFeeBps(), 3000);
    }

    function test_setCreatorAllowance_onlyAdmin() public {
        vm.prank(creator1);
        vm.expectRevert();
        factory.setCreatorAllowance(creator2, 5);

        vm.prank(admin);
        factory.setCreatorAllowance(creator2, 5);
        assertEq(factory.creatorAllowance(creator2), 5);
    }

    function test_addCreatorAllowance_onlyAdmin() public {
        vm.prank(admin);
        factory.setCreatorAllowance(creator1, 3);

        vm.prank(admin);
        factory.addCreatorAllowance(creator1, 7);
        assertEq(factory.creatorAllowance(creator1), 10);
    }

    function test_pauseMarket_preventsTrading() public {
        uint256 poolBalance = 1000_000000;

        usdc.mint(creator1, poolBalance);

        vm.prank(creator1);
        address marketAddress = _cm(poolBalance, 0, 100, 2, 0, 0);

        // Non-admin cannot pause
        vm.prank(creator1);
        vm.expectRevert();
        factory.pauseMarket(0);

        // Admin can pause (emits event)
        vm.prank(admin);
        vm.expectEmit(true, true, false, false);
        emit MarketFactory.MarketPaused(0, marketAddress);
        factory.pauseMarket(0);
    }

    function test_multipleMarkets_independentState() public {
        uint256 poolBalance = 1000_000000;

        usdc.mint(creator1, poolBalance);
        vm.prank(creator1);
        address market1 = _cm(poolBalance, 0, 100, 2, 50, 2000);

        usdc.mint(creator2, poolBalance * 2);
        vm.prank(creator2);
        address market2 = _cm(poolBalance * 2, 0, 100, 2, 100, 3000);

        assertTrue(market1 != market2);

        assertEq(LMSRMarket(market1).creator(), creator1);
        assertEq(LMSRMarket(market1).poolBalance(), poolBalance);
        assertEq(LMSRMarket(market1).feeBps(), defaultFeeBps);

        assertEq(LMSRMarket(market2).creator(), creator2);
        assertEq(LMSRMarket(market2).poolBalance(), poolBalance * 2);
        assertEq(LMSRMarket(market2).feeBps(), defaultFeeBps);

        assertTrue(factory.isValidMarket(market1));
        assertTrue(factory.isValidMarket(market2));
    }

    function test_createMarket_deploysAndRegistersMarket() public {
        uint256 poolBalance = 1000_000000;

        usdc.mint(creator1, poolBalance);
        vm.prank(creator1);

        address marketAddress = factory.createMarket(_params(poolBalance, 0, 100, 2, 0, 0));

        assertTrue(factory.isValidMarket(marketAddress), "Market should be valid");
        assertEq(factory.marketById(0), marketAddress, "Market should be registered by ID");
        assertEq(LMSRMarket(marketAddress).creator(), creator1, "Creator should be set");
    }

    function test_createMarket_withAlphaDecay() public {
        // 2 buckets: sqrt(2)=1, so alphaInitial = poolBalance = 1_000_000000 (6 dec)
        // 10% floor  = 100_000000; use 500_000000 as alphaFinal (50%)
        uint256 poolBalance = 1000_000000;

        // ── Case 1: no decay params → decay not configured ─────────
        vm.prank(creator1);
        address mktNoDecay = factory.createMarket(_params(poolBalance, 0, 100, 2, 0, 0));

        assertFalse(
            LMSRMarket(mktNoDecay).decayDuration() > 0 && LMSRMarket(mktNoDecay).alphaFinal() < LMSRMarket(mktNoDecay).alphaInitial(),
            "No decay params = no decay"
        );

        // ── Case 2: decay params provided → decay configured ────
        MarketFactory.MarketParams memory p = _params(poolBalance, 0, 100, 2, 0, 0);
        p.decayDuration = 7 days;
        p.decayStart    = block.timestamp;
        p.alphaFinal    = 500_000000; // 50% of alphaInitial — safely above 10% floor

        vm.prank(creator1);
        address mktDecay = factory.createMarket(p);

        assertTrue(
            LMSRMarket(mktDecay).decayDuration() > 0 && LMSRMarket(mktDecay).alphaFinal() < LMSRMarket(mktDecay).alphaInitial(),
            "Decay params provided = configured"
        );
        assertEq(LMSRMarket(mktDecay).alphaFinal(), 500_000000, "alphaFinal set correctly");
        assertEq(LMSRMarket(mktDecay).decayDuration(), 7 days, "decayDuration set correctly");
    }
}
