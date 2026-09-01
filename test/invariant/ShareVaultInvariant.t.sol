// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "../../src/IPool.sol";
import {IVault} from "../../src/IVault.sol";
import {MockAsset} from "../../src/MockAsset.sol";
import {ShareVault} from "../../src/ShareVault.sol";
import {ShareVaultVulnerable} from "../../src/ShareVaultVulnerable.sol";
import {VaultHandler} from "./VaultHandler.sol";

/// @notice The fee-accounting invariant suite. Abstract so it never runs by
/// itself; subclasses only provide the vault under test. Inherited invariants
/// run against whichever vault the subclass deploys.
abstract contract VaultInvariantBase is Test {
    IVault internal vault;
    VaultHandler internal handler;

    /// Per-run rounding dust, in wei: up to `depth` calls, each losing at most
    /// a couple of wei to floor rounding.
    uint256 internal constant ROUNDING_SLACK = 64;
    uint256 internal constant BPS = 10_000;

    function _deployVault() internal virtual returns (IVault);

    /// @dev Subclasses can gate the whole suite behind an env flag (used to
    /// keep the killed-bug variant out of default runs).
    function _gatedEnv() internal pure virtual returns (string memory) {
        return "";
    }

    function setUp() public {
        string memory gate = _gatedEnv();
        if (bytes(gate).length != 0) {
            vm.skip(!vm.envOr(gate, false), "gated: set env flag to run");
        }
        vault = _deployVault();
        handler = new VaultHandler(vault);
        targetContract(address(handler));
    }

    /// (a) Solvency: the vault's balance covers every outstanding share claim,
    /// modulo bounded rounding. Holds on the vulnerable vault too — the bug is
    /// how the price moves, not whether claims are backed.
    function invariant_solvency_total_claims_backed() public view {
        uint256 claims = vault.convertToAssets(vault.totalShares());
        uint256 backing = IERC20(vault.asset()).balanceOf(address(vault));
        assertLe(claims, backing + 2);
    }

    /// (b) Fees come out of yield: the cumulative value of treasury fee mints
    /// (each valued at the pre-mint, post-gain price) never exceeds the
    /// performance-fee share of funded gain, plus per-harvest floor-rounding
    /// dust bounded by the call depth.
    function invariant_fees_bounded_by_yield() public view {
        uint256 feeBound = handler.yieldIn() * vault.feeBps() / BPS;
        assertLe(handler.feesAccrued(), feeBound + ROUNDING_SLACK);
    }

    /// (c) Depositor principal is preserved: the crowd's current claim plus
    /// what it already withdrew covers everything it put in, modulo the
    /// per-op rounding dust budget the handler tracks.
    function invariant_crowd_principal_backed() public view {
        uint256 claim = vault.convertToAssets(vault.shareOf(address(handler)));
        assertGe(claim + handler.crowdOut() + handler.roundingBudget(), handler.crowdIn());
    }

    /// (d) Share price never decreases (modulo rounding): a harvest can only
    /// move the rate up, because the fee is bounded by the gain.
    function invariant_rate_monotonic() public view {
        assertGe(vault.exchangeRate() + 2, handler.rateAtCallStart());
    }

    /// (e) Round trip: deposit followed immediately by a full withdraw loses
    /// less than one unit of share price (rounding dust scales with the
    /// exchange rate) — no hidden entry/exit fee.
    function invariant_round_trip_bounded_loss() public view {
        assertLe(handler.worstRoundTripLoss(), handler.maxRate() / 1e18 + 2);
    }
}

/// The hardened vault. Every invariant above must hold. This contract is what
/// default CI runs.
contract ShareVaultInvariant is VaultInvariantBase {
    function _deployVault() internal override returns (IVault) {
        return IVault(address(new ShareVault(IERC20(address(new MockAsset())), address(0x7EA5), 1_000))); // 10% fee
    }
}

/// The intentionally vulnerable vault. Same invariants, same handler — the
/// suite is expected to FAIL here. Gated behind DEMO_RUN_KILLED so default
/// runs stay green; see README for the red run.
contract VulnerableVaultInvariant is VaultInvariantBase {
    function _gatedEnv() internal pure override returns (string memory) {
        return "DEMO_RUN_KILLED";
    }

    function _deployVault() internal override returns (IVault) {
        return IVault(address(new ShareVaultVulnerable(IERC20(address(new MockAsset())), address(0x7EA5), 1_000)));
    }
}
