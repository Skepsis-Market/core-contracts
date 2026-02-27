// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test, console} from "forge-std/Test.sol";
import {LMSRMarket} from "../src/LMSRMarket.sol";
import {MockUSDC} from "../src/mocks/MockUSDC.sol";
import {FixedPointMath} from "../src/FixedPointMath.sol";

contract DebugBuySharesTest is Test {
    using FixedPointMath for uint256;
    
    MockUSDC usdc;
    LMSRMarket market;
    
    address factory = address(0x1);
    address creator = address(0x2);
    address positionNFT = address(0x3);
    address trader = address(0x4);
    
    uint256 constant POOL_BALANCE = 10000_000000; // $10,000
    uint256 constant WAD = 1e18;
    
    function setUp() public {
        usdc = new MockUSDC();
        
        uint256[] memory bucketRanges = new uint256[](101);
        for (uint256 i = 0; i <= 100; i++) {
            bucketRanges[i] = 110000 + (i * 100);
        }
        
        market = new LMSRMarket(
            1,
            creator,
            factory,
            address(usdc),
            positionNFT,
            1_000_000000,
            POOL_BALANCE,
            bucketRanges,
            50,
            2000
        );
        
        usdc.mint(address(market), POOL_BALANCE);
        usdc.mint(trader, 100_000000);
    }
    
    function test_debug_exp_values() public view {
        uint256 alpha = market.alpha();
        uint256 initialShares = POOL_BALANCE / 100; // 100_000_000 (100 USDC)
        
        console.log("=== DEBUGGING EXP() INPUTS ===");
        console.log("alpha (6 dec):", alpha);
        console.log("initialShares (6 dec):", initialShares);
        console.log("");
        
        // Calculate ratio as we do it
        uint256 q = initialShares + 1; // Add phantom shares
        uint256 ratio = (q * WAD) / alpha;
        console.log("q (shares + phantom):", q);
        console.log("ratio (WAD scale):", ratio);
        console.log("ratio / 1e16 (for readability):", ratio / 1e16); // Should be ~99.47
        console.log("");
        
        // Calculate exp
        uint256 expValue = ratio.exp();
        console.log("exp(ratio) in WAD:", expValue);
        console.log("exp(ratio) / 1e16:", expValue / 1e16); // Should be ~110.47
    }
}
