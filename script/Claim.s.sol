// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {LMSRMarket} from "../src/LMSRMarket.sol";
import {IERC20} from "@openzeppelin/token/ERC20/IERC20.sol";
import {IPositionNFT} from "../src/interfaces/IPositionNFT.sol";
import {Vault} from "../src/Vault.sol";

/// @notice Two scripts for post-resolution flows:
///
///   ClaimScript     — bettor redeems winning shares for USDC (1 share = $1)
///   HarvestLPScript — permissionless; routes LP residual from the market back
///                     to the vault so capital can be recycled into new markets
///
/// CLAIM WINNINGS (bettor)
///   forge script script/Claim.s.sol:ClaimScript \
///     --rpc-url $FUJI_RPC_URL --broadcast --chain-id 43113
///
/// HARVEST LP CAPITAL (vault operator / anyone)
///   forge script script/Claim.s.sol:HarvestLPScript \
///     --rpc-url $FUJI_RPC_URL --broadcast --chain-id 43113
///
/// PREREQUISITES
/// ─────────────
///   .env must have: MARKET_ADDRESS, VAULT_ADDRESS, USDC_ADDRESS,
///                   PRIVATE_KEY, DEPLOYER_ADDRESS
///   Market must be RESOLVED (run Resolve.s.sol first)
///
/// HOW WINNING SHARES WORK
/// ───────────────────────
///   Each bucket is an ERC-1155 token held in PositionNFT.
///   After resolution, only the winning bucket redeems: 1 share → $1 USDC.
///   Losing bucket holders receive nothing.

// ─── helpers ─────────────────────────────────────────────────────────────────

/// @dev Mirrors LMSRMarket._tokenIdForBucket
function tokenIdForBucket(uint256 marketId, uint256 bucketId) pure returns (uint256) {
    return (uint256(uint128(marketId)) << 128)
        | (uint256(uint64(bucketId)) << 64)
        | uint256(uint64(bucketId));
}

// ─── Claim Winnings ───────────────────────────────────────────────────────────

contract ClaimScript is Script {

    // ─── Configure ──────────────────────────────────────────────────────────
    // SHARES_TO_CLAIM: how many winning shares to redeem.
    // Set to 0 to automatically claim the full balance held by DEPLOYER_ADDRESS.
    uint256 constant SHARES_TO_CLAIM = 0;   // 0 = claim all
    // ────────────────────────────────────────────────────────────────────────

    function run() public {
        address claimer = vm.envAddress("DEPLOYER_ADDRESS");
        uint256 pk      = vm.envUint("PRIVATE_KEY");

        LMSRMarket   market = LMSRMarket(vm.envAddress("MARKET_ADDRESS"));
        IERC20       usdc   = IERC20(address(market.usdcToken()));
        IPositionNFT nft    = IPositionNFT(market.positionNFT());

        require(
            market.status() == LMSRMarket.MarketStatus.RESOLVED,
            "Market not resolved -- run Resolve.s.sol first"
        );

        uint256 mid       = market.marketId();
        uint256 winBucket = market.winningBucket();
        uint256 tokenId   = tokenIdForBucket(mid, winBucket);
        uint256 nftBal    = nft.balanceOf(claimer, tokenId);

        // If SHARES_TO_CLAIM == 0 claim everything the caller holds
        uint256 sharesToClaim = (SHARES_TO_CLAIM == 0) ? nftBal : SHARES_TO_CLAIM;

        (uint256 wbShares,, uint256 wbLower, uint256 wbUpper) = market.buckets(winBucket);

        console.log("=================================================");
        console.log("  Claim Winnings");
        console.log("=================================================");
        console.log("Market:            ", address(market));
        console.log("Market ID:         ", mid);
        console.log("Claimer:           ", claimer);
        console.log("Resolution value:  ", market.resolutionValue(), market.valueUnit());
        console.log("Winning bucket:    ", winBucket);
        console.log("  range:           ", wbLower, "-", wbUpper);
        console.log("  total shares:    ", wbShares);
        console.log("Claimer NFT bal:   ", nftBal);
        console.log("Claiming:          ", sharesToClaim);
        console.log("Expected payout:   ", sharesToClaim / 1e6, "USDC");
        console.log("USDC before:       ", usdc.balanceOf(claimer) / 1e6, "USDC");
        console.log("Pool before:       ", market.poolBalance() / 1e6, "USDC");

        if (sharesToClaim == 0) {
            console.log("\n  No winning shares to claim -- balance is 0.");
            console.log("  (Did you hold the winning bucket?  Did someone else already claim?)");
            return;
        }

        require(nftBal >= sharesToClaim, "SHARES_TO_CLAIM exceeds NFT balance");

        vm.startBroadcast(pk);
        market.claim(tokenId, claimer);
        vm.stopBroadcast();

        console.log("\n  Claimed!");
        console.log("  USDC received:  ", sharesToClaim / 1e6, "USDC");
        console.log("  USDC after:     ", usdc.balanceOf(claimer) / 1e6, "USDC");
        console.log("  NFT bal after:  ", nft.balanceOf(claimer, tokenId));
        console.log("  Pool remaining: ", market.poolBalance() / 1e6, "USDC");
        (uint256 remainingShares,,,) = market.buckets(winBucket);
        console.log("\n  Unclaimed winning shares:", remainingShares);
        console.log("  (Other winners must claim before LP capital can be fully harvested)");
    }
}

// ─── Harvest LP Capital ───────────────────────────────────────────────────────

/// @notice Routes the LP residual from a resolved market back to the Vault.
///         Permissionless — anyone can call this; funds always go to the vault.
///         The vault then processes any queued withdrawals from the returned capital.
///
/// When to call:
///   After market resolution and after most bettors have claimed their winnings.
///   The vault will retain exactly enough USDC in the market to cover any remaining
///   unclaimed winning shares; everything else is returned.
///
/// NOTE: This calls vault.harvestResolved(market), NOT market.withdrawLP() directly.
///       The vault route ensures proper accounting (NAV, totalDeployed, queue processing).
///       Calling market.withdrawLP() directly as creator would send funds to the creator
///       wallet instead of the vault — bypassing LP accounting entirely.
contract HarvestLPScript is Script {

    function run() public {
        uint256 pk = vm.envUint("PRIVATE_KEY");

        LMSRMarket market = LMSRMarket(vm.envAddress("MARKET_ADDRESS"));
        Vault      vault  = Vault(vm.envAddress("VAULT_ADDRESS"));
        IERC20     usdc   = IERC20(vault.asset());

        require(
            market.status() == LMSRMarket.MarketStatus.RESOLVED,
            "Market not resolved -- run Resolve.s.sol first"
        );
        require(
            !market.lpWithdrawn(),
            "LP already harvested for this market"
        );

        uint256 winBucket    = market.winningBucket();
        (uint256 winShares,,,) = market.buckets(winBucket);
        uint256 pool         = market.poolBalance();
        uint256 approxForLP  = pool > winShares ? pool - winShares : 0;

        console.log("=================================================");
        console.log("  Harvest LP Capital");
        console.log("=================================================");
        console.log("Market:            ", address(market));
        console.log("Market ID:         ", market.marketId());
        console.log("Vault:             ", address(vault));
        console.log("lpVault on market: ", market.lpVault());
        console.log("Pool balance:      ", pool / 1e6, "USDC");
        console.log("Unclaimed winShares:", winShares / 1e6, "USDC equiv");
        console.log("Approx LP return:  ", approxForLP / 1e6, "USDC");
        console.log("Vault USDC before: ", usdc.balanceOf(address(vault)) / 1e6, "USDC");
        console.log("Vault totalAssets: ", vault.totalAssets() / 1e6, "USDC");
        console.log("Vault deployable:  ", vault.deployableCapital() / 1e6, "USDC");

        vm.startBroadcast(pk);
        // harvestResolved is permissionless — vault calls market.withdrawLP() internally
        // which sends USDC to the vault, updates totalDeployed, and processes withdrawal queue.
        vault.harvestResolved(address(market));
        vm.stopBroadcast();

        console.log("\n  LP harvested!");
        console.log("  Vault USDC after:  ", usdc.balanceOf(address(vault)) / 1e6, "USDC");
        console.log("  Vault totalAssets: ", vault.totalAssets() / 1e6, "USDC");
        console.log("  Vault deployable:  ", vault.deployableCapital() / 1e6, "USDC");
        console.log("  lpWithdrawn:       ", market.lpWithdrawn());
    }
}
