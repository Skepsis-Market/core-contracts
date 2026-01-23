// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test, console} from "forge-std/Test.sol";
import {MarketFactory} from "../../src/MarketFactory.sol";
import {LMSRMarket} from "../../src/LMSRMarket.sol";
import {PositionNFT} from "../../src/PositionNFT.sol";
import {MockUSDC} from "../../src/mocks/MockUSDC.sol";

/// @notice Gas benchmarking tests for LMSR market operations
/// @dev Run with: forge test --match-contract GasBenchmarkTest --gas-report
contract GasBenchmarkTest is Test {
    MarketFactory public factory;
    PositionNFT public positionNFT;
    MockUSDC public usdc;
    
    address admin = address(0x1);
    address creator = address(0x2);
    address trader = address(0x3);
    
    uint256 constant POOL_BALANCE = 10000_000000; // $10,000
    
    function setUp() public {
        vm.startPrank(admin);
        
        // Deploy USDC
        usdc = new MockUSDC();
        
        // Predict factory address
        address predictedFactory = vm.computeCreateAddress(admin, 2);
        
        // Deploy PositionNFT
        positionNFT = new PositionNFT(predictedFactory);
        
        // Deploy factory
        factory = new MarketFactory(
            address(usdc),
            address(positionNFT),
            1000_000000, // minPoolBalance
            100, // maxBuckets
            50, // defaultFeeBps
            2000 // defaultProtocolFeeBps
        );
        
        vm.stopPrank();
        
        // Mint USDC
        usdc.mint(creator, 100000_000000);
        usdc.mint(trader, 100000_000000);
    }
    
    /// @notice Benchmark: Create market with 10 buckets
    function testGas_createMarket_10buckets() public {
        uint256[] memory bucketRanges = new uint256[](11);
        for (uint256 i = 0; i <= 10; i++) {
            bucketRanges[i] = i * 10;
        }
        
        vm.startPrank(creator);
        usdc.approve(address(factory), POOL_BALANCE);
        factory.createMarket(POOL_BALANCE, bucketRanges, 50, 2000);
        vm.stopPrank();
    }
    
    /// @notice Benchmark: Create market with 50 buckets
    function testGas_createMarket_50buckets() public {
        uint256[] memory bucketRanges = new uint256[](51);
        for (uint256 i = 0; i <= 50; i++) {
            bucketRanges[i] = i * 2;
        }
        
        vm.startPrank(creator);
        usdc.approve(address(factory), POOL_BALANCE);
        factory.createMarket(POOL_BALANCE, bucketRanges, 50, 2000);
        vm.stopPrank();
    }
    
    /// @notice Benchmark: Create market with 100 buckets
    function testGas_createMarket_100buckets() public {
        uint256[] memory bucketRanges = new uint256[](101);
        for (uint256 i = 0; i <= 100; i++) {
            bucketRanges[i] = i;
        }
        
        vm.startPrank(creator);
        usdc.approve(address(factory), POOL_BALANCE);
        factory.createMarket(POOL_BALANCE, bucketRanges, 50, 2000);
        vm.stopPrank();
    }
    
    /// @notice Benchmark: Buy shares in 10-bucket market
    function testGas_buyShares_10buckets() public {
        LMSRMarket market = _createMarket(10);
        
        vm.startPrank(trader);
        usdc.approve(address(market), 100_000000);
        market.buyShares(5, 100_000000, 0);
        vm.stopPrank();
    }
    
    /// @notice Benchmark: Buy shares in 50-bucket market
    function testGas_buyShares_50buckets() public {
        LMSRMarket market = _createMarket(50);
        
        vm.startPrank(trader);
        usdc.approve(address(market), 100_000000);
        market.buyShares(25, 100_000000, 0);
        vm.stopPrank();
    }
    
    /// @notice Benchmark: Buy shares in 100-bucket market
    function testGas_buyShares_100buckets() public {
        LMSRMarket market = _createMarket(100);
        
        vm.startPrank(trader);
        usdc.approve(address(market), 100_000000);
        market.buyShares(50, 100_000000, 0);
        vm.stopPrank();
    }
    
    /// @notice Benchmark: Sell shares in 10-bucket market
    function testGas_sellShares_10buckets() public {
        LMSRMarket market = _createMarket(10);
        
        // First buy
        vm.startPrank(trader);
        usdc.approve(address(market), 100_000000);
        uint256 sharesBought = market.buyShares(5, 100_000000, 0);
        
        // Then sell
        market.sellShares(5, sharesBought / 2, 0);
        vm.stopPrank();
    }
    
    /// @notice Benchmark: Sell shares in 50-bucket market
    function testGas_sellShares_50buckets() public {
        LMSRMarket market = _createMarket(50);
        
        vm.startPrank(trader);
        usdc.approve(address(market), 100_000000);
        uint256 sharesBought = market.buyShares(25, 100_000000, 0);
        
        market.sellShares(25, sharesBought / 2, 0);
        vm.stopPrank();
    }
    
    /// @notice Benchmark: Sell shares in 100-bucket market
    function testGas_sellShares_100buckets() public {
        LMSRMarket market = _createMarket(100);
        
        vm.startPrank(trader);
        usdc.approve(address(market), 100_000000);
        uint256 sharesBought = market.buyShares(50, 100_000000, 0);
        
        market.sellShares(50, sharesBought / 2, 0);
        vm.stopPrank();
    }
    
    /// @notice Benchmark: Claim winnings from 10-bucket market
    function testGas_claimWinnings_10buckets() public {
        LMSRMarket market = _createMarket(10);
        
        // Buy shares
        vm.startPrank(trader);
        usdc.approve(address(market), 100_000000);
        uint256 sharesBought = market.buyShares(5, 100_000000, 0);
        vm.stopPrank();
        
        // Resolve
        vm.prank(creator);
        market.resolveMarket(5);
        
        // Claim
        vm.prank(trader);
        market.claimWinnings(5, sharesBought);
    }
    
    /// @notice Benchmark: Claim winnings from 50-bucket market
    function testGas_claimWinnings_50buckets() public {
        LMSRMarket market = _createMarket(50);
        
        vm.startPrank(trader);
        usdc.approve(address(market), 100_000000);
        uint256 sharesBought = market.buyShares(25, 100_000000, 0);
        vm.stopPrank();
        
        vm.prank(creator);
        market.resolveMarket(25);
        
        vm.prank(trader);
        market.claimWinnings(25, sharesBought);
    }
    
    /// @notice Benchmark: Claim winnings from 100-bucket market
    function testGas_claimWinnings_100buckets() public {
        LMSRMarket market = _createMarket(100);
        
        vm.startPrank(trader);
        usdc.approve(address(market), 100_000000);
        uint256 sharesBought = market.buyShares(50, 100_000000, 0);
        vm.stopPrank();
        
        vm.prank(creator);
        market.resolveMarket(50);
        
        vm.prank(trader);
        market.claimWinnings(50, sharesBought);
    }
    
    /// @notice Benchmark: LP withdrawal from 10-bucket market
    function testGas_withdrawLP_10buckets() public {
        LMSRMarket market = _createMarket(10);
        
        // Some trading activity
        vm.startPrank(trader);
        usdc.approve(address(market), 100_000000);
        market.buyShares(5, 100_000000, 0);
        vm.stopPrank();
        
        // Resolve
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
        market.resolveMarket(5);
    }
    
    /// @notice Benchmark: Sequential trades (realistic scenario)
    function testGas_sequentialTrades_10buckets() public {
        LMSRMarket market = _createMarket(10);
        
        vm.startPrank(trader);
        usdc.approve(address(market), 500_000000);
        
        // Multiple sequential trades
        market.buyShares(3, 100_000000, 0);
        market.buyShares(5, 100_000000, 0);
        market.buyShares(7, 100_000000, 0);
        
        vm.stopPrank();
    }
    
    /// @notice Benchmark: Buy with permit (gasless approval)
    function testGas_buySharesWithPermit_10buckets() public {
        LMSRMarket market = _createMarket(10);
        
        // Generate permit signature
        uint256 traderKey = 0x1234;
        address traderWithKey = vm.addr(traderKey);
        usdc.mint(traderWithKey, 100_000000);
        
        uint256 amount = 100_000000;
        uint256 deadline = block.timestamp + 1 hours;
        
        bytes32 permitHash = keccak256(
            abi.encodePacked(
                "\x19\x01",
                usdc.DOMAIN_SEPARATOR(),
                keccak256(abi.encode(
                    usdc.PERMIT_TYPEHASH(),
                    traderWithKey,
                    address(market),
                    amount,
                    usdc.nonces(traderWithKey),
                    deadline
                ))
            )
        );
        
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(traderKey, permitHash);
        
        vm.prank(traderWithKey);
        market.buySharesWithPermit(5, amount, 0, deadline, v, r, s);
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
        market.buyShares(5, 100_000000, 0);
        vm.stopPrank();
        
        (uint256 shares,,) = market.buckets(5);
        market.calculateReturnForShares(5, shares / 2);
    }
    
    /// @notice Helper: Create market with N buckets
    function _createMarket(uint256 numBuckets) internal returns (LMSRMarket) {
        uint256[] memory bucketRanges = new uint256[](numBuckets + 1);
        for (uint256 i = 0; i <= numBuckets; i++) {
            bucketRanges[i] = (i * 100) / numBuckets;
        }
        
        vm.startPrank(creator);
        usdc.approve(address(factory), POOL_BALANCE);
        address marketAddress = factory.createMarket(POOL_BALANCE, bucketRanges, 50, 2000);
        vm.stopPrank();
        
        return LMSRMarket(marketAddress);
    }
}
