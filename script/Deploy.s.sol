// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {PositionNFT} from "../src/PositionNFT.sol";
import {MarketFactory} from "../src/MarketFactory.sol";
import {Vault} from "../src/Vault.sol";
import {MockUSDC} from "../src/mocks/MockUSDC.sol";

/// @notice Deployment script for Arbitrum Sepolia testnet
/// @dev Run with: forge script script/Deploy.s.sol:DeployScript --rpc-url $ARBITRUM_SEPOLIA_RPC --broadcast --verify
contract DeployScript is Script {
    // Configuration parameters
    uint256 constant DEFAULT_FEE_BPS = 200; // 2% total fee
    uint256 constant PROTOCOL_FEE_BPS = 2000; // 20% of fees go to protocol (0.4% of volume)
    uint256 constant MIN_POOL_BALANCE = 100_000000; // $100 USDC minimum
    uint256 constant MAX_POOL_BALANCE = 1_000_000_000000; // $1M USDC maximum
    uint256 constant MAX_BUCKETS = 100;
    
    // Deployment addresses (will be set during deployment)
    address public deployer;
    address public admin;
    MockUSDC public usdc;
    PositionNFT public positionNFT;
    MarketFactory public factory;
    Vault public vault;
    
    function setUp() public {
        deployer = vm.envAddress("DEPLOYER_ADDRESS");
        admin = vm.envOr("ADMIN_ADDRESS", deployer); // Default to deployer if not set
    }
    
    function run() public {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        
        vm.startBroadcast(deployerPrivateKey);
        
        console.log("=== Deploying to Arbitrum Sepolia ===");
        console.log("Deployer:", deployer);
        console.log("Admin:", admin);
        
        // Step 1: Deploy MockUSDC for testnet
        console.log("\n1. Deploying MockUSDC...");
        usdc = new MockUSDC();
        console.log("MockUSDC deployed at:", address(usdc));
        
        // Mint initial test USDC to deployer (10M USDC)
        usdc.mint(deployer, 10_000_000_000000);
        console.log("Minted 10M USDC to deployer");
        
        // Step 2: Predict MarketFactory address for PositionNFT constructor
        console.log("\n2. Computing MarketFactory address...");
        address predictedFactory = vm.computeCreateAddress(deployer, vm.getNonce(deployer) + 1);
        console.log("Predicted factory address:", predictedFactory);
        
        // Deploy PositionNFT with predicted factory address
        console.log("\n3. Deploying PositionNFT...");
        positionNFT = new PositionNFT(predictedFactory);
        console.log("PositionNFT deployed at:", address(positionNFT));
        
        // Step 4: Deploy MarketFactory
        console.log("\n4. Deploying MarketFactory...");
        factory = new MarketFactory(
            address(usdc),
            address(positionNFT),
            MIN_POOL_BALANCE,
            MAX_BUCKETS,
            DEFAULT_FEE_BPS,
            PROTOCOL_FEE_BPS
        );
        console.log("MarketFactory deployed at:", address(factory));
        
        // Verify predicted address matches actual
        if (address(factory) != predictedFactory) {
            console.log("WARNING: Predicted address mismatch!");
            console.log("Predicted:", predictedFactory);
            console.log("Actual:", address(factory));
        }

        // Step 4b: Deploy Vault and wire up
        console.log("\n4b. Deploying Vault...");
        vault = new Vault(address(usdc), "Vault", "sVLT", deployer);
        factory.setVault(address(vault));
        vault.setFactory(address(factory));
        console.log("Vault deployed at:", address(vault));

        // Fund vault with deployer's USDC as initial LP
        usdc.approve(address(vault), 100_000_000000); // $100k
        vault.deposit(100_000_000000, deployer);
        console.log("Deposited $100k to vault as initial LP");
        
        // Step 5: Create a test market (Bitcoin price on Feb 1, 2026)
        console.log("\n5. Creating test market: Bitcoin price on Feb 1, 2026...");
        
        // Bitcoin price range: $40k to $140k, 10 buckets (using Sui-parity params)
        uint256 minValue = 40_000;
        uint256 maxValue = 140_000;
        uint256 bucketCount = 10;
        
        uint256 poolBalance = 10_000_000000; // $10,000 USDC

        // Whitelist deployer as a market creator
        factory.setCreatorAllowance(deployer, 10);

        MarketFactory.MarketParams memory p;
        p.alpha          = poolBalance / 3; // sqrt(10) = 3
        p.seedAmount     = poolBalance;
        p.minValue       = minValue;
        p.maxValue       = maxValue;
        p.bucketCount    = bucketCount;
        p.feeBps         = DEFAULT_FEE_BPS;
        p.protocolFeeBps = PROTOCOL_FEE_BPS;

        address testMarket = factory.createMarket(p);
        console.log("Test market created at:", testMarket);
        console.log("Market ID: 0");
        
        vm.stopBroadcast();
        
        // Step 6: Log deployment summary
        console.log("\n=== Deployment Summary ===");
        console.log("MockUSDC:", address(usdc));
        console.log("PositionNFT:", address(positionNFT));
        console.log("MarketFactory:", address(factory));
        console.log("Test Market:", testMarket);
        console.log("\nAdmin:", admin);
        console.log("Default Fee (bps):", DEFAULT_FEE_BPS);
        console.log("Protocol Fee Share (bps):", PROTOCOL_FEE_BPS);
        
        // Generate deployments.json data
        console.log("\n=== Add to deployments.json ===");
        console.log("{");
        console.log('  "network": "arbitrum-sepolia",');
        console.log('  "chainId": 421614,');
        console.log('  "deployer": "', deployer, '",');
        console.log('  "admin": "', admin, '",');
        console.log('  "contracts": {');
        console.log('    "MockUSDC": "', address(usdc), '",');
        console.log('    "PositionNFT": "', address(positionNFT), '",');
        console.log('    "MarketFactory": "', address(factory), '",');
        console.log('    "TestMarket": "', testMarket, '"');
        console.log('  },');
        console.log('  "config": {');
        console.log('    "defaultFeeBps":', DEFAULT_FEE_BPS, ',');
        console.log('    "protocolFeeBps":', PROTOCOL_FEE_BPS, ',');
        console.log('    "minPoolBalance":', MIN_POOL_BALANCE, ',');
        console.log('    "maxPoolBalance":', MAX_POOL_BALANCE, ',');
        console.log('    "maxBuckets":', MAX_BUCKETS);
        console.log('  }');
        console.log('}');
    }
}

/// @notice Script to verify all deployed contracts
/// @dev Run after deployment with: forge script script/Deploy.s.sol:VerifyScript --rpc-url $ARBITRUM_SEPOLIA_RPC
contract VerifyScript is Script {
    function run() public view {
        address usdcAddress = vm.envAddress("USDC_ADDRESS");
        address positionNFTAddress = vm.envAddress("POSITION_NFT_ADDRESS");
        address factoryAddress = vm.envAddress("FACTORY_ADDRESS");
        
        console.log("=== Contract Verification ===");
        console.log("\nVerify on Arbiscan with:");
        console.log("\n1. MockUSDC:");
        console.log("forge verify-contract", usdcAddress, "src/mocks/MockUSDC.sol:MockUSDC --chain-id 421614 --watch");
        
        console.log("\n2. PositionNFT:");
        console.log("forge verify-contract", positionNFTAddress, "src/PositionNFT.sol:PositionNFT --chain-id 421614 --watch");
        
        console.log("\n3. MarketFactory:");
        console.log("forge verify-contract", factoryAddress, "src/MarketFactory.sol:MarketFactory --chain-id 421614 --watch");
    }
}
