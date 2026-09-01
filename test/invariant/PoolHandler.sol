// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20, IPool} from "../../src/IPool.sol";
import {MockAsset} from "../../src/MockAsset.sol";

/// @notice Handler that drives random sequences at the pool. The crowd
/// (this contract) deposits and withdraws; a separate attacker address gets
/// its own deposit / donate / withdraw actions so the harness can track
/// exactly how much the attacker put in and took out.
///
/// Ghost variables (read by the invariant functions):
///  - attackerIn / attackerOut   — attacker's assets in vs. out
///  - totalElapsed               — seconds warped, bounds legitimate yield
///  - rateAtCallStart            — exchange rate before the current call
///  - lastAccrual{Gain,Base,Elapsed} — last warpAndAccrue, for the rate cap
///  - worstRoundTripLoss         — worst deposit->withdraw loss seen
contract PoolHandler is Test {
    IPool public pool;
    IERC20 public asset;
    address public constant ATTACKER = address(0xA11CE);

    uint256 public attackerIn;
    uint256 public attackerOut;
    uint256 public totalElapsed;
    uint256 public rateAtCallStart;
    uint256 public lastAccrualGain;
    uint256 public lastAccrualBase;
    uint256 public lastAccrualElapsed;
    uint256 public worstRoundTripLoss;
    /// @dev Highest exchange rate seen at any call start. Floor rounding makes
    /// the POOL keep dust: a deposit->withdraw round trip loses less than two
    /// units of share price, so the honest wei bound is rate-relative.
    uint256 public maxRate;

    constructor(IPool pool_) {
        pool = pool_;
        asset = IERC20(pool_.asset());
        MockAsset(address(asset)).mint(address(this), type(uint128).max);
        MockAsset(address(asset)).mint(ATTACKER, type(uint128).max);
        MockAsset(address(asset)).mint(address(pool_.reserve()), 1e27); // fund the yield reserve
        asset.approve(address(pool), type(uint256).max);
        vm.prank(ATTACKER);
        asset.approve(address(pool), type(uint256).max);
        rateAtCallStart = pool.exchangeRate();
    }

    function _snapshotRate() internal {
        rateAtCallStart = pool.exchangeRate();
        if (rateAtCallStart > maxRate) maxRate = rateAtCallStart;
    }

    // --- crowd actions -----------------------------------------------------

    function deposit(uint96 amount) external {
        _snapshotRate();
        amount = uint96(bound(amount, 1, 100 ether));
        pool.deposit(amount);
    }

    function withdraw(uint256 shares) external {
        _snapshotRate();
        uint256 owned = pool.shareOf(address(this));
        if (owned == 0) return;
        shares = bound(shares, 1, owned);
        pool.withdraw(shares);
    }

    /// Deposit then immediately withdraw every share received. Records the
    /// worst-case loss across the whole campaign.
    function roundTrip(uint96 amount) external {
        _snapshotRate();
        amount = uint96(bound(amount, 1, 100 ether));
        uint256 before = asset.balanceOf(address(this));
        uint256 shares = pool.deposit(amount);
        pool.withdraw(shares);
        uint256 after_ = asset.balanceOf(address(this));
        if (before > after_ && before - after_ > worstRoundTripLoss) {
            worstRoundTripLoss = before - after_;
        }
    }

    // --- attacker actions --------------------------------------------------

    function attackerDeposit(uint96 amount) external {
        _snapshotRate();
        amount = uint96(bound(amount, 1, 1 ether));
        vm.prank(ATTACKER);
        pool.deposit(amount);
        attackerIn += amount;
    }

    /// The donation: a plain transfer that must not move the share price.
    function attackerDonate(uint96 amount) external {
        _snapshotRate();
        amount = uint96(bound(amount, 1, 1_000 ether));
        vm.prank(ATTACKER);
        asset.transfer(address(pool), amount);
        attackerIn += amount;
    }

    function attackerWithdraw(uint256 shares) external {
        _snapshotRate();
        uint256 owned = pool.shareOf(ATTACKER);
        if (owned == 0) return;
        shares = bound(shares, 1, owned);
        vm.prank(ATTACKER);
        attackerOut += pool.withdraw(shares);
    }

    /// Full exit — the payoff step of an inflation sweep.
    function attackerWithdrawAll() external {
        _snapshotRate();
        uint256 owned = pool.shareOf(ATTACKER);
        if (owned == 0) return;
        vm.prank(ATTACKER);
        attackerOut += pool.withdraw(owned);
    }

    // --- time --------------------------------------------------------------

    /// The only action that moves time, so interest gain per accrual can be
    /// checked against the rate cap in isolation.
    function warpAndAccrue(uint32 seconds_) external {
        _snapshotRate();
        uint256 elapsed = bound(seconds_, 1, 7 days);
        uint256 base = pool.totalAssets();
        vm.warp(block.timestamp + elapsed);
        pool.accrue();
        totalElapsed += elapsed;
        lastAccrualGain = pool.totalAssets() - base;
        lastAccrualBase = base;
        lastAccrualElapsed = elapsed;
    }
}
