// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test, console} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {LMSRMarket} from "../../src/LMSRMarket.sol";
import {MockUSDC} from "../../src/mocks/MockUSDC.sol";
import {FixedPointMath} from "../../src/FixedPointMath.sol";

/// @notice Handler contract for stateful fuzzing of LMSR market
/// @dev Performs random buy/sell operations to test solvency invariant
contract SolvencyHandler is Test {
    using FixedPointMath for uint256;
    
    LMSRMarket public market;
    MockUSDC public usdc;
    
    address[] public traders;
    uint256 public tradeCount;
    uint256 public totalBuys;
    uint256 public totalSells;
    
    // Track ghost variables for debugging
    uint256 public maxSharesEverSeen;
    uint256 public minPoolBalanceEverSeen;
    
    constructor(LMSRMarket _market, MockUSDC _usdc, address[] memory _traders) {
        market = _market;
        usdc = _usdc;
        traders = _traders;
        minPoolBalanceEverSeen = type(uint256).max;
    }
    
    /// @notice Randomly buy shares in a random bucket
    /// @param traderIndex Index of trader to execute the buy (bounded by traders.length)
    /// @param bucketId Bucket to buy from (bounded by bucketCount)
    /// @param amountUSDC Amount to spend (bounded to reasonable range)
    function buyShares(uint256 traderIndex, uint256 bucketId, uint256 amountUSDC) public {
        // Bound inputs
        traderIndex = bound(traderIndex, 0, traders.length - 1);
        bucketId = bound(bucketId, 0, market.bucketCount() - 1);
        amountUSDC = bound(amountUSDC, 10_000000, 10000_000000); // $10 to $10,000

        address trader = traders[traderIndex];

        // Mint USDC if needed
        if (usdc.balanceOf(trader) < amountUSDC) {
            usdc.mint(trader, amountUSDC * 2);
        }

        uint256 lower = market.marketMin() + (bucketId * market.bucketWidth());
        uint256 upper = lower + market.bucketWidth();

        // Try to buy (may revert due to slippage, which is OK)
        vm.startPrank(trader);
        usdc.approve(address(market), amountUSDC);

        try market.buySharesRange(lower, upper, amountUSDC, 0, 0, address(0)) {
            totalBuys++;
            tradeCount++;
        } catch {
            // Trade reverted (e.g., solvency violation, slippage), that's fine
        }

        vm.stopPrank();

        // Update ghost variables
        _updateGhostVariables();
    }

    /// @notice Randomly sell shares from a random bucket
    /// @param traderIndex Index of trader to execute the sell
    /// @param bucketId Bucket to sell from
    /// @param sharePercent Percentage of bucket shares to sell (0-100)
    function sellShares(uint256 traderIndex, uint256 bucketId, uint256 sharePercent) public {
        // Bound inputs
        traderIndex = bound(traderIndex, 0, traders.length - 1);
        bucketId = bound(bucketId, 0, market.bucketCount() - 1);
        sharePercent = bound(sharePercent, 1, 100);

        // Get bucket shares
        (uint256 bucketShares,,,) = market.buckets(bucketId);
        if (bucketShares == 0) return; // Nothing to sell

        // Calculate shares to sell (percentage of bucket shares)
        uint256 sharesToSell = (bucketShares * sharePercent) / 100;
        if (sharesToSell == 0) return;

        uint256 lower = market.marketMin() + (bucketId * market.bucketWidth());
        uint256 upper = lower + market.bucketWidth();

        address trader = traders[traderIndex];

        // Try to sell (may revert, which is OK)
        vm.prank(trader);
        try market.sellSharesRange(lower, upper, sharesToSell, 0, address(0)) {
            totalSells++;
            tradeCount++;
        } catch {
            // Trade reverted, that's fine
        }

        // Update ghost variables
        _updateGhostVariables();
    }
    
    /// @notice Update ghost variables for debugging
    function _updateGhostVariables() internal {
        uint256 poolBalance = market.poolBalance();
        if (poolBalance < minPoolBalanceEverSeen) {
            minPoolBalanceEverSeen = poolBalance;
        }
        
        // Check max shares across all buckets
        for (uint256 i = 0; i < market.bucketCount(); i++) {
            (uint256 shares,,,) = market.buckets(i);
            uint256 sharesUSDC = shares.fromWad();
            if (sharesUSDC > maxSharesEverSeen) {
                maxSharesEverSeen = sharesUSDC;
            }
        }
    }
}

/// @notice Invariant test contract for LMSR market solvency
/// @dev Proves that solvency can never be violated through stateful fuzzing
contract SolvencyInvariantTest is StdInvariant, Test {
    using FixedPointMath for uint256;
    
    LMSRMarket public market;
    MockUSDC public usdc;
    SolvencyHandler public handler;
    
    address creator = address(0x1);
    address[] traders;
    
    uint256 constant POOL_BALANCE = 10000_000000; // $10,000
    uint256 constant SOLVENCY_DUST = 1000; // From LMSRMarket

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
        // Deploy USDC
        usdc = new MockUSDC();
        
        // Create 5 traders
        for (uint256 i = 0; i < 5; i++) {
            traders.push(address(uint160(0x1000 + i)));
        }
        
        // Deploy market with 10 buckets
        uint256[] memory bucketRanges = new uint256[](11);
        for (uint256 i = 0; i <= 10; i++) {
            bucketRanges[i] = i * 10; // 0, 10, 20, ..., 100
        }
        
        vm.prank(creator);
        market = new LMSRMarket(
            1, // marketId
            creator,
            address(0xFACE), // factory
            address(usdc),
            address(0x2), // positionNFT
            3_333_333333, // alpha = POOL / sqrt(10)
            POOL_BALANCE,
            bucketRanges,
            new uint256[](0),
            50, // 0.5% fee
            2000, // 20% protocol fee
            _defaultMetadata(),
            address(0xFEE)
        );
        
        // Mint initial pool balance to market
        usdc.mint(address(market), POOL_BALANCE);
        
        // Deploy handler
        handler = new SolvencyHandler(market, usdc, traders);
        
        // Configure invariant testing
        targetContract(address(handler));
        
        // Target only the buy/sell functions
        bytes4[] memory selectors = new bytes4[](2);
        selectors[0] = handler.buyShares.selector;
        selectors[1] = handler.sellShares.selector;
        
        targetSelector(FuzzSelector({
            addr: address(handler),
            selectors: selectors
        }));
    }
    
    /// @notice Invariant: Solvency must always hold
    /// @dev For any bucket, bucket.shares (in USDC) <= poolBalance + SOLVENCY_DUST
    function invariant_solvencyAlwaysHolds() public view {
        uint256 poolBalance = market.poolBalance();
        uint256 bucketCount = market.bucketCount();
        
        for (uint256 i = 0; i < bucketCount; i++) {
            (uint256 shares,,,) = market.buckets(i);
            uint256 sharesUSDC = shares.fromWad();
            
            // CRITICAL INVARIANT: Max payout cannot exceed available funds
            assertLe(
                sharesUSDC,
                poolBalance + SOLVENCY_DUST,
                string(abi.encodePacked(
                    "Solvency violation in bucket ",
                    vm.toString(i),
                    ": shares=",
                    vm.toString(sharesUSDC),
                    " > poolBalance=",
                    vm.toString(poolBalance)
                ))
            );
        }
    }
    
    /// @notice Invariant: Pool balance should never be negative (underflow protection)
    function invariant_poolBalanceNeverNegative() public view {
        uint256 poolBalance = market.poolBalance();
        // If we get here without revert, poolBalance is valid (uint256 can't be negative)
        assertGt(poolBalance, 0, "Pool balance is zero or underflowed");
    }
    
    /// @notice Invariant: Total shares across all buckets should be reasonable
    /// @dev Sum of all shares shouldn't massively exceed initial pool balance
    function invariant_totalSharesReasonable() public view {
        uint256 totalSharesUSDC = 0;
        uint256 bucketCount = market.bucketCount();
        
        for (uint256 i = 0; i < bucketCount; i++) {
            (uint256 shares,,,) = market.buckets(i);
            totalSharesUSDC += shares.fromWad();
        }
        
        uint256 poolBalance = market.poolBalance();
        uint256 initialDeposit = market.initialDeposit();
        
        // Total shares should be within reasonable bounds
        // In LMSR, shares can exceed pool due to leverage, but shouldn't be absurd
        uint256 maxReasonable = poolBalance * 10; // 10x leverage max
        assertLe(
            totalSharesUSDC,
            maxReasonable,
            "Total shares unreasonably high"
        );
    }
    
    /// @notice Helper to log statistics after fuzzing
    function invariant_logStatistics() public view {
        console.log("=== Fuzzing Statistics ===");
        console.log("Total trades:", handler.tradeCount());
        console.log("Total buys:", handler.totalBuys());
        console.log("Total sells:", handler.totalSells());
        console.log("Max shares seen (USDC):", handler.maxSharesEverSeen());
        console.log("Min pool balance seen:", handler.minPoolBalanceEverSeen());
        console.log("Final pool balance:", market.poolBalance());
        console.log("=========================");
    }
}
