// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {LMSRMarket} from "../src/LMSRMarket.sol";
import {MarketFactory} from "../src/MarketFactory.sol";
import {Vault} from "../src/Vault.sol";
import {MockUSDC} from "../src/mocks/MockUSDC.sol";

/// @notice Upgrade LMSRMarket impl + redeploy MarketFactory, wire to existing infra.
///
/// Keeps: MockUSDC, PositionNFT, Vault, TradeRouter
/// Redeploys: LMSRMarket (impl), MarketFactory
///
/// RUN:
///   forge script script/UpgradeImpl.s.sol:UpgradeImplScript \
///     --rpc-url arb_sepolia --broadcast --verify --slow
contract UpgradeImplScript is Script {
    // ─── Existing addresses (keep) ───────────────────────────────────────
    address constant USDC         = 0x82dB8786B5630F19D8e6C86A697a6d92e6363732;
    address constant POSITION_NFT = 0x840B9Ed262fA8cE6644D03BA0723595cf98EC9Bf;
    address constant VAULT        = 0x4bacFbC3f6638dA8950A691ec5e45b910e93e6c9;
    address constant ROUTER       = 0xA43ee2eBd7198790e8472D656C602C7Fc4ADb238;

    // ─── Protocol config (same as original deploy) ───────────────────────
    uint256 constant DEFAULT_FEE_BPS  = 200;
    uint256 constant PROTOCOL_FEE_BPS = 2000;
    uint256 constant MIN_POOL_BALANCE = 100_000000;
    uint256 constant MAX_BUCKETS      = 1000;

    function run() public {
        address deployer = vm.envAddress("DEPLOYER_ADDRESS");
        uint256 pk = vm.envUint("PRIVATE_KEY");

        vm.startBroadcast(pk);

        console.log("=================================================");
        console.log("  Upgrading LMSRMarket impl + MarketFactory");
        console.log("=================================================");

        // ── 1. Deploy new LMSRMarket implementation ──────────────────────
        console.log("\n[1/4] Deploying new LMSRMarket implementation...");
        uint256[] memory implSeedIds = new uint256[](2);
        uint256[] memory implSeedShares = new uint256[](2);
        implSeedIds[0] = 0; implSeedIds[1] = 1;
        implSeedShares[0] = 1; implSeedShares[1] = 1;
        LMSRMarket.MarketMetadata memory implMeta;

        address newImpl = address(new LMSRMarket(LMSRMarket.InitParams({
            marketId: 0,
            creator: address(0),
            factory: address(0),
            usdcToken: USDC,
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
        console.log("  New LMSRMarket impl:", newImpl);

        // ── 2. Deploy new MarketFactory ──────────────────────────────────
        console.log("\n[2/4] Deploying new MarketFactory...");
        MarketFactory newFactory = new MarketFactory(
            newImpl,
            USDC,
            POSITION_NFT,
            MIN_POOL_BALANCE,
            MAX_BUCKETS,
            DEFAULT_FEE_BPS,
            PROTOCOL_FEE_BPS,
            address(0xFEE)
        );
        console.log("  New MarketFactory:", address(newFactory));

        // ── 3. Wire factory ↔ vault ↔ router ────────────────────────────
        console.log("\n[3/4] Wiring...");

        // Factory → Vault
        newFactory.setVault(VAULT);
        console.log("  factory.setVault done");

        // Factory → Router
        newFactory.setRouter(ROUTER);
        console.log("  factory.setRouter done");

        // Vault → Factory (vault accepts new factory for fundNewMarket)
        Vault(VAULT).setFactory(address(newFactory));
        console.log("  vault.setFactory done");

        // Give deployer creator allowance
        newFactory.setCreatorAllowance(deployer, 100);
        console.log("  deployer: 100 market slots");

        // Give dev creator allowance
        newFactory.setCreatorAllowance(0x0DFaa72FB12FaE26E7145A6B7A44DFA41d6DC4BB, 100);
        console.log("  dev: 100 market slots");

        vm.stopBroadcast();

        // ── 4. Summary ──────────────────────────────────────────────────
        console.log("\n=================================================");
        console.log("  UPGRADE COMPLETE");
        console.log("=================================================");
        console.log("New LMSRMarket impl:", newImpl);
        console.log("New MarketFactory:  ", address(newFactory));
        console.log("Vault (kept):       ", VAULT);
        console.log("Router (kept):      ", ROUTER);
        console.log("PositionNFT (kept): ", POSITION_NFT);
        console.log("USDC (kept):        ", USDC);
        console.log("\n--- .env updates ---");
        console.log(string.concat("LMSR_IMPL_ADDRESS=", vm.toString(newImpl)));
        console.log(string.concat("FACTORY_ADDRESS=", vm.toString(address(newFactory))));
    }
}
