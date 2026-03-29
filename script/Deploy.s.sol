// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {PositionNFT} from "../src/PositionNFT.sol";
import {MarketFactory} from "../src/MarketFactory.sol";
import {Vault} from "../src/Vault.sol";
import {LMSRMarket} from "../src/LMSRMarket.sol";
import {MockUSDC} from "../src/mocks/MockUSDC.sol";

/// @notice Full deployment + setup script for Avalanche Fuji testnet.
///
/// DEPLOYMENT ORDER (order matters — each step depends on the previous)
/// ════════════════════════════════════════════════════════════════════
///  1. MockUSDC        — testnet USDC, mint to deployer
///  2. PositionNFT     — ERC-1155; needs factory address at construction
///                       so we predict the factory address first
///  3. MarketFactory   — deploys LMSRMarket instances; whitelist deployer
///  4. Vault           — ERC-4626 LP vault; wire vault↔factory so they
///                       can call each other (fundNewMarket / setVault)
///  5. Seed Vault      — deployer deposits initial LP capital
///  6. Create Market   — factory.createMarket() pulls seed from vault
///                       automatically via fundNewMarket; alpha decay set
///
/// RUN
/// ════════════════════════════════════════════════════════════════════
///   cp .env.example .env   # fill PRIVATE_KEY, DEPLOYER_ADDRESS
///
///   forge script script/Deploy.s.sol:DeployScript \
///     --rpc-url $FUJI_RPC_URL \
///     --broadcast --verify \
///     --chain-id 43113
contract DeployScript is Script {

    // ─── Protocol config ─────────────────────────────────────────────────────
    uint256 constant DEFAULT_FEE_BPS  = 200;         // 2% total fee per trade
    uint256 constant PROTOCOL_FEE_BPS = 2000;        // 20% of fees → protocol (= 0.4% of volume)
    uint256 constant MIN_POOL_BALANCE = 100_000000;  // $100 min seed per market
    uint256 constant MAX_BUCKETS      = 100;

    // ─── Vault initial LP seed ────────────────────────────────────────────────
    uint256 constant VAULT_SEED_USDC  = 500_000_000000; // $500k

    // ─── Sample market: AVAX/USD on Apr 1 2026 ───────────────────────────────
    // 19 buckets of $10 wide covering $10–$200
    uint256 constant MARKET_MIN       = 10;
    uint256 constant MARKET_MAX       = 200;
    uint256 constant MARKET_BUCKETS   = 19;
    uint256 constant MARKET_POOL      = 10_000_000000;  // $10k from vault
    // Alpha decay: linearly decay to 30% of initial alpha over 30 days
    // Protects against late snipers as resolution approaches
    uint256 constant DECAY_FINAL_BPS  = 3000;           // 30% of alphaInitial
    uint256 constant DECAY_DURATION   = 30 days;
    // Dynamic range expansion: 0 = disabled
    uint256 constant EXPANDED_MIN     = 0;              // 0 = no expansion below
    uint256 constant EXPANDED_MAX     = 0;              // 0 = no expansion above

    // ─── Runtime ─────────────────────────────────────────────────────────────
    address public deployer;
    MockUSDC public usdc;          // Pre-deployed — read from USDC_ADDRESS env var
    address public lmsrImpl;       // LMSRMarket implementation contract (EIP-1167 clone source)
    PositionNFT public positionNFT;
    MarketFactory public factory;
    Vault public vault;

    function setUp() public {
        deployer = vm.envAddress("DEPLOYER_ADDRESS");
    }

    function run() public {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(pk);

        console.log("=================================================");
        console.log("  Deploying Skepsis Protocol");
        console.log("  Chain ID:", block.chainid);
        console.log("==================================================");
        console.log("Deployer:", deployer);

        // ── 1. USDC ───────────────────────────────────────────────────────────
        // Fuji:  reads existing MockUSDC from USDC_ADDRESS env var (public mint).
        // Local: USDC_ADDRESS is blank → deploys a fresh MockUSDC.
        address usdcEnv = vm.envOr("USDC_ADDRESS", address(0));
        if (usdcEnv != address(0)) {
            console.log("\n[1/6] Using existing MockUSDC...");
            usdc = MockUSDC(usdcEnv);
        } else {
            console.log("\n[1/6] Deploying fresh MockUSDC (local chain)...");
            usdc = new MockUSDC();
        }
        usdc.mint(deployer, VAULT_SEED_USDC + 100_000_000000); // vault seed + $100k trading buffer
        console.log("  MockUSDC:    ", address(usdc));
        console.log("  Deployer balance:", usdc.balanceOf(deployer) / 1e6, "USDC");

        // ── 2. PositionNFT ────────────────────────────────────────────────────
        // Must be constructed with the factory address it will trust.
        // Predict factory address (next deployment after positionNFT).
        console.log("\n[2/6] Deploying LMSRMarket implementation (clone source)...");
        // Deploys a locked LMSRMarket template. MarketFactory Clones.clone()s it for every
        // new market, removing 43k of LMSRMarket initcode from MarketFactory's bytecode.
        {
            uint256[] memory implRanges = new uint256[](2);
            implRanges[0] = 0;
            implRanges[1] = 1;
            LMSRMarket.MarketMetadata memory implMeta;
            lmsrImpl = address(new LMSRMarket(
                0, address(0), address(0), address(usdc), address(0),
                1, 1, implRanges, new uint256[](0), 0, 0, implMeta, address(0xFEE)
            ));
        }
        console.log("  LMSRMarket impl:", lmsrImpl);

        console.log("\n[3/6] Deploying PositionNFT...");
        address predictedFactory = vm.computeCreateAddress(deployer, vm.getNonce(deployer) + 1);
        positionNFT = new PositionNFT(predictedFactory);
        console.log("  PositionNFT: ", address(positionNFT));
        console.log("  Trusts factory (predicted):", predictedFactory);

        // ── 3. MarketFactory ──────────────────────────────────────────────────
        // Deploys LMSRMarket clones, enforces pool size limits and fee params.
        // setCreatorAllowance gives the deployer permission to create markets.
        console.log("\n[4/6] Deploying MarketFactory...");
        factory = new MarketFactory(
            lmsrImpl,
            address(usdc),
            address(positionNFT),
            MIN_POOL_BALANCE,
            MAX_BUCKETS,
            DEFAULT_FEE_BPS,
            PROTOCOL_FEE_BPS,
            address(0xFEE)
        );
        require(address(factory) == predictedFactory, "Factory address prediction mismatch");
        factory.setCreatorAllowance(deployer, 10);
        console.log("  MarketFactory:", address(factory));
        console.log("  Creator allowance: 10 markets for deployer");

        // ── 4. Vault + wiring ─────────────────────────────────────────────────
        // Vault is ERC-4626.  Two-way wiring is needed:
        //   vault.setFactory(factory) → only factory can call vault.fundNewMarket()
        //   factory.setVault(vault)   → factory pulls seed capital from vault on createMarket()
        console.log("\n[5/6] Deploying Vault + wiring...");
        vault = new Vault(address(usdc), "Skepsis Vault", "sVLT", deployer);
        vault.setFactory(address(factory));
        factory.setVault(address(vault));
        console.log("  Vault:        ", address(vault));
        console.log("  vault->factory wired");
        console.log("  factory->vault wired");

        // ── 5. Seed Vault + Create Market ─────────────────────────────────────
        // Deployer becomes the first LP.  Any subsequent createMarket() call will
        // pull from this pool (up to 20% of NAV per market, min 20% buffer kept).
        console.log("\n[6/6] Seeding Vault and creating sample market...");
        usdc.approve(address(vault), VAULT_SEED_USDC);
        vault.deposit(VAULT_SEED_USDC, deployer);
        console.log("  Deposited:    ", VAULT_SEED_USDC / 1e6, "USDC");
        console.log("  LP shares:    ", vault.balanceOf(deployer));
        console.log("  Vault NAV:    ", vault.totalAssets() / 1e6, "USDC");
        console.log("  Deployable:   ", vault.deployableCapital() / 1e6, "USDC");

        // factory.createMarket() internally calls vault.fundNewMarket(market, seedAmount)
        // which transfers USDC from vault to the new LMSRMarket and registers it.
        // Alpha decay is configured atomically by the factory using p.alphaFinal and
        // p.decayDuration if both are non-zero.
        console.log("\n  Creating sample market: AVAX/USD (Apr 1 2026)...");
        console.log("  Range: $10 - $200 | Buckets: 19");

        uint256 alphaInitial = MARKET_POOL / 3;

        MarketFactory.MarketParams memory p;
        p.alpha          = alphaInitial;
        p.seedAmount     = MARKET_POOL;
        p.minValue       = MARKET_MIN;
        p.maxValue       = MARKET_MAX;
        p.bucketCount    = MARKET_BUCKETS;
        p.alphaFinal     = (alphaInitial * DECAY_FINAL_BPS) / 10000;
        p.decayDuration  = DECAY_DURATION;
        p.expandedMinValue = EXPANDED_MIN;
        p.expandedMaxValue = EXPANDED_MAX;

        address marketAddr = factory.createMarket(p);
        LMSRMarket market  = LMSRMarket(marketAddr);

        console.log("  Market:       ", marketAddr);
        console.log("  Market ID:    ", market.marketId());
        console.log("  poolBalance:  ", market.poolBalance() / 1e6, "USDC");
        console.log("  alpha:        ", market.alpha());
        console.log("  alphaFinal:   ", market.alphaFinal());
        console.log("  decayDays:    ", market.decayDuration() / 1 days);
        console.log("  lpVault:      ", market.lpVault());
        console.log("  Vault deployable remaining:", vault.deployableCapital() / 1e6, "USDC");

        vm.stopBroadcast();

        // ── Summary ───────────────────────────────────────────────────────────
        console.log("\n=================================================");
        console.log("  DEPLOYMENT COMPLETE");
        console.log("=================================================");
        console.log("MockUSDC:     ", address(usdc), " (pre-deployed)");
        console.log("LMSRImpl:     ", lmsrImpl, " (clone source)");
        console.log("PositionNFT:  ", address(positionNFT));
        console.log("MarketFactory:", address(factory));
        console.log("Vault:        ", address(vault));
        console.log("SampleMarket: ", marketAddr);

        console.log("\n--- deployments/fuji.json ---");
        console.log(string.concat('{ "network":"fuji","chainId":43113,'));
        console.log(string.concat('  "MockUSDC":"',        vm.toString(address(usdc)),        '",'));
        console.log(string.concat('  "LMSRImpl":"',        vm.toString(lmsrImpl),             '",'));
        console.log(string.concat('  "PositionNFT":"',     vm.toString(address(positionNFT)), '",'));
        console.log(string.concat('  "MarketFactory":"',   vm.toString(address(factory)),     '",'));
        console.log(string.concat('  "Vault":"',           vm.toString(address(vault)),       '",'));
        console.log(string.concat('  "SampleMarket":"',    vm.toString(marketAddr),           '" }'));

        console.log("\n--- .env additions ---");
        console.log(string.concat("USDC_ADDRESS=",          vm.toString(address(usdc))));
        console.log(string.concat("LMSR_IMPL_ADDRESS=",     vm.toString(lmsrImpl)));
        console.log(string.concat("POSITION_NFT_ADDRESS=",  vm.toString(address(positionNFT))));
        console.log(string.concat("FACTORY_ADDRESS=",       vm.toString(address(factory))));
        console.log(string.concat("VAULT_ADDRESS=",         vm.toString(address(vault))));
        console.log(string.concat("SAMPLE_MARKET_ADDRESS=", vm.toString(marketAddr)));
    }
}

/// @notice Reads deployed addresses from .env and prints forge verify commands for Fuji.
///
/// RUN AFTER BROADCAST
///   forge script script/Deploy.s.sol:VerifyScript --rpc-url $FUJI_RPC_URL
contract VerifyScript is Script {
    function run() public view {
        address usdcAddr    = vm.envAddress("USDC_ADDRESS");
        address nftAddr     = vm.envAddress("POSITION_NFT_ADDRESS");
        address factoryAddr = vm.envAddress("FACTORY_ADDRESS");
        address vaultAddr   = vm.envAddress("VAULT_ADDRESS");

        string memory flags = "--chain-id 43113 --watch";

        console.log("=================================================");
        console.log("  Fuji Verification (Routescan/Snowscan)");
        console.log("=================================================");

        console.log("\n1. MockUSDC:");
        console.log(string.concat(
            "forge verify-contract ", vm.toString(usdcAddr),
            " src/mocks/MockUSDC.sol:MockUSDC ", flags
        ));

        console.log("\n2. PositionNFT:");
        console.log(string.concat(
            "forge verify-contract ", vm.toString(nftAddr),
            " src/PositionNFT.sol:PositionNFT",
            " --constructor-args $(cast abi-encode 'constructor(address)' ",
            vm.toString(factoryAddr), ") ", flags
        ));

        console.log("\n3. MarketFactory:");
        console.log(string.concat(
            "forge verify-contract ", vm.toString(factoryAddr),
            " src/MarketFactory.sol:MarketFactory ", flags
        ));

        console.log("\n4. Vault:");
        console.log(string.concat(
            "forge verify-contract ", vm.toString(vaultAddr),
            " src/Vault.sol:Vault ", flags
        ));
    }
}
