// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test, console} from "forge-std/Test.sol";
import {MarketFactory} from "../../src/MarketFactory.sol";
import {LMSRMarket} from "../../src/LMSRMarket.sol";
import {PositionNFT} from "../../src/PositionNFT.sol";
import {MockUSDC} from "../../src/mocks/MockUSDC.sol";
import {Vault} from "../../src/Vault.sol";

/// @notice Gas benchmarking tests for LMSR market operations
/// @dev Run with: forge test --match-contract GasBenchmarkTest --gas-report
contract GasBenchmarkTest is Test {
    MarketFactory public factory;
    PositionNFT public positionNFT;
    MockUSDC public usdc;
    Vault public vault;
    
    address admin = address(0x1);
    address creator = address(0x2);
    address trader = address(0x3);
    
    uint256 constant POOL_BALANCE = 10000_000000; // $10,000
    
    function setUp() public {
        vm.startPrank(admin);
        
        // Deploy USDC
        usdc = new MockUSDC();

        // Deploy LMSRMarket implementation (EIP-1167 clone source)
        {
            uint256[] memory implSeedIds = new uint256[](2);
            uint256[] memory implSeedShares = new uint256[](2);
            implSeedIds[0] = 0; implSeedIds[1] = 1;
            implSeedShares[0] = 1; implSeedShares[1] = 1;
            LMSRMarket.MarketMetadata memory implMeta;
            address lmsrImpl = address(new LMSRMarket(LMSRMarket.InitParams({
                    marketId: 0,
                    creator: address(0),
                    factory: address(0),
                    usdcToken: address(usdc),
                    positionNFT: address(0),
                    alpha: 1,
                    poolBalance: 2,
                    bucketWidth: 1,
                    maxBucketId: 1,
                    seededBucketIds: implSeedIds,
                    seededShares: implSeedShares,
                    feeBps: 0,
                    protocolFeeBps: 0,
                    metadata: implMeta,
                    protocolFeeCollector: address(0xFEE)
                })));

            // nonce 0: usdc, nonce 1: impl, nonce 2: positionNFT -> factory at nonce 3
            address predictedFactory = vm.computeCreateAddress(admin, 3);

            // Deploy PositionNFT
            positionNFT = new PositionNFT(predictedFactory);

            // Deploy factory
            factory = new MarketFactory(
                lmsrImpl,
                address(usdc),
                address(positionNFT),
                1000_000000, // minPoolBalance
                100, // maxBuckets
                50, // defaultFeeBps
                2000, // defaultProtocolFeeBps
                address(0xFEE)
            );
        }
        
        // Whitelist the market creator
        factory.setCreatorAllowance(creator, 100);

        // Deploy vault and wire up
        vault = new Vault(address(usdc), "Vault", "sVLT", admin);
        vault.setDepositsEnabled(true);
        factory.setVault(address(vault));
        vault.setFactory(address(factory));

        vm.stopPrank();

        // Fund vault via LP deposit
        address lp = address(0x4);
        usdc.mint(lp, 10_000_000_000000);
        vm.startPrank(lp);
        usdc.approve(address(vault), 10_000_000_000000);
        vault.deposit(10_000_000_000000, lp);
        vm.stopPrank();

        // Mint USDC for trader
        usdc.mint(trader, 100000_000000);
    }
    
    // ── Helper ──────────────────────────────────────────────────────────────

    function _params(
        uint256 seedAmount,
        uint256 minValue,
        uint256 maxValue,
        uint256 bucketCount,
        uint256 feeBps,
        uint256 protoBps
    ) internal pure returns (MarketFactory.MarketParams memory p) {
        uint256 bw = (maxValue - minValue) / bucketCount;
        uint256 startBucket = (minValue == 0) ? 0 : minValue / bw;
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

    /// @notice Benchmark: Create market with 10 buckets
    function testGas_createMarket_10buckets() public {
        vm.prank(creator);
        factory.createMarket(_params(POOL_BALANCE, 0, 100, 10, 50, 2000));
    }

    /// @notice Benchmark: Create market with 50 buckets
    function testGas_createMarket_50buckets() public {
        vm.prank(creator);
        factory.createMarket(_params(POOL_BALANCE, 0, 100, 50, 50, 2000));
    }

    /// @notice Benchmark: Create market with 100 buckets
    function testGas_createMarket_100buckets() public {
        vm.prank(creator);
        factory.createMarket(_params(POOL_BALANCE, 0, 100, 100, 50, 2000));
    }
    
    function _buyBucket(LMSRMarket market, uint256 bucketId, uint256 amount, uint256 minShares) internal returns (uint256) {
        uint256 lower = bucketId * market.bucketWidth();
        return market.buySharesRange(lower, lower + market.bucketWidth(), amount, minShares, 0, address(0));
    }
    function _sellBucket(LMSRMarket market, uint256 bucketId, uint256 shares, uint256 minPayout) internal returns (uint256) {
        uint256 lower = bucketId * market.bucketWidth();
        return market.sellSharesRange(lower, lower + market.bucketWidth(), shares, minPayout, address(0));
    }
    function _claimBucket(LMSRMarket market, uint256 bucketId) internal returns (uint256) {
        uint256 tokenId = (uint256(uint128(market.marketId())) << 128) | (uint256(uint64(bucketId)) << 64) | uint256(uint64(bucketId));
        return market.claim(tokenId, address(0));
    }

    /// @notice Benchmark: Buy shares in 10-bucket market
    function testGas_buyShares_10buckets() public {
        LMSRMarket market = _createMarket(10);

        vm.startPrank(trader);
        usdc.approve(address(market), 100_000000);
        _buyBucket(market, 5, 100_000000, 0);
        vm.stopPrank();
    }

    /// @notice Benchmark: Buy shares in 50-bucket market
    function testGas_buyShares_50buckets() public {
        LMSRMarket market = _createMarket(50);

        vm.startPrank(trader);
        usdc.approve(address(market), 100_000000);
        _buyBucket(market, 25, 100_000000, 0);
        vm.stopPrank();
    }

    /// @notice Benchmark: Buy shares in 100-bucket market
    function testGas_buyShares_100buckets() public {
        LMSRMarket market = _createMarket(100);

        vm.startPrank(trader);
        usdc.approve(address(market), 100_000000);
        _buyBucket(market, 50, 100_000000, 0);
        vm.stopPrank();
    }

    /// @notice Benchmark: Sell shares in 10-bucket market
    function testGas_sellShares_10buckets() public {
        LMSRMarket market = _createMarket(10);

        // First buy
        vm.startPrank(trader);
        usdc.approve(address(market), 100_000000);
        uint256 sharesBought = _buyBucket(market, 5, 100_000000, 0);

        // Then sell
        _sellBucket(market, 5, sharesBought / 2, 0);
        vm.stopPrank();
    }

    /// @notice Benchmark: Sell shares in 50-bucket market
    function testGas_sellShares_50buckets() public {
        LMSRMarket market = _createMarket(50);

        vm.startPrank(trader);
        usdc.approve(address(market), 100_000000);
        uint256 sharesBought = _buyBucket(market, 25, 100_000000, 0);

        _sellBucket(market, 25, sharesBought / 2, 0);
        vm.stopPrank();
    }

    /// @notice Benchmark: Sell shares in 100-bucket market
    function testGas_sellShares_100buckets() public {
        LMSRMarket market = _createMarket(100);

        vm.startPrank(trader);
        usdc.approve(address(market), 100_000000);
        uint256 sharesBought = _buyBucket(market, 50, 100_000000, 0);

        _sellBucket(market, 50, sharesBought / 2, 0);
        vm.stopPrank();
    }

    /// @notice Benchmark: Claim winnings from 10-bucket market
    function testGas_claimWinnings_10buckets() public {
        LMSRMarket market = _createMarket(10);

        // Buy shares
        vm.startPrank(trader);
        usdc.approve(address(market), 100_000000);
        _buyBucket(market, 5, 100_000000, 0);
        vm.stopPrank();

        // Resolve with value 5 (bucket 5 in 10-bucket market, width=1)
        vm.prank(creator);
        market.resolveMarket(5);

        // Claim
        vm.startPrank(trader);
        _claimBucket(market, 5);
        vm.stopPrank();
    }

    /// @notice Benchmark: Claim winnings from 50-bucket market
    function testGas_claimWinnings_50buckets() public {
        LMSRMarket market = _createMarket(50);

        vm.startPrank(trader);
        usdc.approve(address(market), 100_000000);
        _buyBucket(market, 25, 100_000000, 0);
        vm.stopPrank();

        vm.prank(creator);
        market.resolveMarket(25); // value 25 = bucket 25 (width 1)

        vm.startPrank(trader);
        _claimBucket(market, 25);
        vm.stopPrank();
    }

    /// @notice Benchmark: Claim winnings from 100-bucket market
    function testGas_claimWinnings_100buckets() public {
        LMSRMarket market = _createMarket(100);

        vm.startPrank(trader);
        usdc.approve(address(market), 100_000000);
        _buyBucket(market, 50, 100_000000, 0);
        vm.stopPrank();

        vm.prank(creator);
        market.resolveMarket(50); // value 50 = bucket 50 (width 1)

        vm.startPrank(trader);
        _claimBucket(market, 50);
        vm.stopPrank();
    }

    /// @notice Benchmark: LP withdrawal from 10-bucket market
    function testGas_withdrawLP_10buckets() public {
        LMSRMarket market = _createMarket(10);

        // Some trading activity
        vm.startPrank(trader);
        usdc.approve(address(market), 100_000000);
        _buyBucket(market, 5, 100_000000, 0);
        vm.stopPrank();

        // Resolve with value 3 (bucket 3 in 10-bucket market, width=1)
        vm.prank(creator);
        market.resolveMarket(3);

        // LP withdrawal
        vm.prank(creator);
        market.withdrawLP();
    }

    /// @notice Benchmark: Resolve market
    function testGas_resolveMarket() public {
        LMSRMarket market = _createMarket(10);

        vm.prank(creator);
        market.resolveMarket(5); // value 5 = bucket 5 (width 1)
    }

    /// @notice Benchmark: Sequential trades (realistic scenario)
    function testGas_sequentialTrades_10buckets() public {
        LMSRMarket market = _createMarket(10);

        vm.startPrank(trader);
        usdc.approve(address(market), 500_000000);

        // Multiple sequential trades
        _buyBucket(market, 3, 100_000000, 0);
        _buyBucket(market, 5, 100_000000, 0);
        _buyBucket(market, 7, 100_000000, 0);

        vm.stopPrank();
    }

    /// @notice Benchmark: Calculate shares for cost (view function)
    function testGas_calculateSharesForCost() public {
        LMSRMarket market = _createMarket(10);
        market.calculateSharesForCost(5, 100_000000);
    }

    /// @notice Benchmark: Calculate return for shares (view function)
    function testGas_calculateReturnForShares() public {
        LMSRMarket market = _createMarket(10);

        vm.startPrank(trader);
        usdc.approve(address(market), 100_000000);
        _buyBucket(market, 5, 100_000000, 0);
        vm.stopPrank();

        (uint256 shares,,,) = market.buckets(5);
        market.calculateReturnForShares(5, shares / 2);
    }
    
    /// @notice Helper: Create market with N buckets
    function _createMarket(uint256 numBuckets) internal returns (LMSRMarket) {
        // maxValue = numBuckets ensures each bucket is width 1 (evenly divisible)
        vm.prank(creator);
        address marketAddress = factory.createMarket(_params(POOL_BALANCE, 0, numBuckets, numBuckets, 50, 2000));

        return LMSRMarket(marketAddress);
    }
}
