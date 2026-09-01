// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "../../src/IPool.sol";
import {IVault} from "../../src/IVault.sol";
import {MockAsset} from "../../src/MockAsset.sol";

/// @notice Handler that drives random sequences at the vault. The crowd (this
/// contract) deposits and withdraws; the owner harvests bounded yield, which
/// is the only action that books fees — so fee growth can be checked against
/// funded gain in isolation.
///
/// Ghost variables (read by the invariant functions):
///  - crowdIn / crowdOut   — crowd's assets in vs. out
///  - yieldIn              — total gain funded through harvest()
///  - feesAccrued          — growth of the treasury's claim across harvests
///  - rateAtCallStart      — exchange rate before the current call
///  - worstRoundTripLoss   — worst deposit->withdraw loss seen
contract VaultHandler is Test {
    IVault public vault;
    IERC20 public asset;

    uint256 public crowdIn;
    uint256 public crowdOut;
    uint256 public yieldIn;
    uint256 public feesAccrued;
    uint256 public rateAtCallStart;
    uint256 public maxRate;
    uint256 public roundingBudget;
    uint256 public worstRoundTripLoss;

    constructor(IVault vault_) {
        vault = vault_;
        asset = vault_.asset();
        MockAsset(address(asset)).mint(address(this), type(uint128).max);
        MockAsset(address(asset)).mint(address(vault_.reserve()), 1e30); // fund the yield reserve
        asset.approve(address(vault), type(uint256).max);
        rateAtCallStart = vault.exchangeRate();
        maxRate = rateAtCallStart;
    }

    /// @dev Floor rounding makes the VAULT keep dust; a user op loses less
    /// than one unit of share price. With a +1 wei virtual offset the price
    /// granularity is (totalAssets + 1)/(totalShares + 1) wei, so the honest
    /// bound is rate-relative, not a flat wei constant.
    function _snapshotRate() internal {
        rateAtCallStart = vault.exchangeRate();
        if (rateAtCallStart > maxRate) maxRate = rateAtCallStart;
    }

    function _chargeDust() internal {
        roundingBudget += rateAtCallStart / 1e18 + 2;
    }

    // --- crowd actions -----------------------------------------------------

    function deposit(uint96 amount) external {
        _snapshotRate();
        amount = uint96(bound(amount, 1, 100 ether));
        // Keep the crowd's principal >= 1e6 wei: no deposit can mint zero
        // shares at the price granularities this harness reaches.
        vm.assume(asset.balanceOf(address(this)) >= 1e6);
        _chargeDust();
        vault.deposit(amount);
        crowdIn += amount;
    }

    function withdraw(uint256 shares) external {
        _snapshotRate();
        uint256 owned = vault.shareOf(address(this));
        if (owned == 0) return;
        shares = bound(shares, 1, owned);
        _chargeDust();
        crowdOut += vault.withdraw(shares);
    }

    /// Deposit then immediately withdraw every share received. Records the
    /// worst-case loss across the whole campaign.
    function roundTrip(uint96 amount) external {
        _snapshotRate();
        amount = uint96(bound(amount, 1, 100 ether));
        vm.assume(asset.balanceOf(address(this)) >= 1e6 + amount);
        _chargeDust();
        _chargeDust(); // two user ops: deposit + withdraw
        uint256 before = asset.balanceOf(address(this));
        uint256 shares = vault.deposit(amount);
        crowdIn += amount;
        crowdOut += vault.withdraw(shares);
        uint256 after_ = asset.balanceOf(address(this));
        if (before > after_ && before - after_ > worstRoundTripLoss) {
            worstRoundTripLoss = before - after_;
        }
    }

    // --- yield -------------------------------------------------------------

    /// Fund a bounded gain and book the fee. The treasury's claim growth per
    /// harvest is recorded exactly, so the fee bound can be checked per call
    /// instead of assuming a compounding model.
    function harvest(uint96 gain) external {
        _snapshotRate();
        gain = uint96(bound(gain, 0, 1 ether));
        vm.prank(vault.owner());
        uint256 feeShares = vault.harvest(gain);
        if (feeShares > 0) {
            // Invert the vault's own convertToShares: value the mint at the
            // pre-mint, post-gain price (the +1 offsets included), so the
            // ghost is exact modulo one floor rounding per harvest.
            feesAccrued += feeShares * (vault.totalAssets() + 1) / (vault.totalShares() - feeShares + 1);
        }
        yieldIn += gain;
    }
}
