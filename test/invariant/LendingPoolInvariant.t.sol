// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20, IPool} from "../../src/IPool.sol";
import {MockAsset} from "../../src/MockAsset.sol";
import {LendingPool} from "../../src/LendingPool.sol";
import {LendingPoolVulnerable} from "../../src/LendingPoolVulnerable.sol";
import {PoolHandler} from "./PoolHandler.sol";

/// @notice The invariant suite. Abstract so it never runs by itself;
/// subclasses only provide the pool under test. Inherited invariants run
/// against whichever pool the subclass deploys.
abstract contract PoolInvariantBase is Test {
    IPool internal pool;
    PoolHandler internal handler;

    /// Rounding slack, in wei, tolerated by the share-accounting invariants.
    uint256 internal constant ROUNDING_SLACK = 2;

    function _deployPool() internal virtual returns (IPool);

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
        pool = _deployPool();
        handler = new PoolHandler(pool);
        targetContract(address(handler));
    }

    /// (a) Solvency: the pool's balance covers every outstanding share claim,
    /// modulo bounded rounding.
    function invariant_solvency_total_claims_backed() public view {
        uint256 claims = pool.convertToAssets(pool.totalShares());
        uint256 backing = IERC20(pool.asset()).balanceOf(address(pool));
        assertLe(claims, backing + ROUNDING_SLACK);
    }

    /// (b) Manipulation resistance: after any sequence of attacker deposits,
    /// donations and withdrawals, the attacker cannot hold more than they put
    /// in — plus their legitimate, rate-capped share of reserve-funded yield.
    function invariant_attacker_cannot_extract() public view {
        uint256 attackerIn = handler.attackerIn();
        uint256 yieldBound =
            attackerIn * 2 * pool.maxRatePerSecond() * handler.totalElapsed() / 1e18;
        assertLe(handler.attackerOut(), attackerIn + yieldBound + ROUNDING_SLACK);
    }

    /// (c1) Interest: the exchange rate never decreases (modulo rounding).
    function invariant_rate_monotonic() public view {
        assertGe(pool.exchangeRate() + ROUNDING_SLACK, handler.rateAtCallStart());
    }

    /// (c2) Interest: every accrual is bounded by the hard rate cap.
    function invariant_accrual_bounded_by_cap() public view {
        uint256 maxGain =
            handler.lastAccrualBase() * pool.maxRatePerSecond() * handler.lastAccrualElapsed() / 1e18;
        assertLe(handler.lastAccrualGain(), maxGain + 1);
    }

    /// (d) Round trip: deposit followed immediately by a full withdraw loses
    /// at most bounded rounding dust — no silent fees, no share traps.
    function invariant_round_trip_bounded_loss() public view {
        assertLe(handler.worstRoundTripLoss(), ROUNDING_SLACK);
    }
}

/// The hardened pool. Every invariant above must hold. This contract is what
/// default CI runs.
contract LendingPoolInvariant is PoolInvariantBase {
    function _deployPool() internal override returns (IPool) {
        return IPool(address(new LendingPool(IERC20(address(new MockAsset())), 1e9))); // ~3%/yr
    }
}

/// The intentionally vulnerable pool. Same invariants, same handler — the
/// suite is expected to FAIL here. Gated behind DEMO_RUN_KILLED so default
/// runs stay green; see README for the red run.
contract VulnerablePoolInvariant is PoolInvariantBase {
    function _gatedEnv() internal pure override returns (string memory) {
        return "DEMO_RUN_KILLED";
    }

    function _deployPool() internal override returns (IPool) {
        return IPool(address(new LendingPoolVulnerable(IERC20(address(new MockAsset())), 1e9)));
    }
}
