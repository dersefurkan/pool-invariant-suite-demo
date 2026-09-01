// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "../../src/IPool.sol";
import {MockAsset} from "../../src/MockAsset.sol";
import {LendingPool} from "../../src/LendingPool.sol";
import {ShareVault} from "../../src/ShareVault.sol";

/// @notice Property contract shared by echidna and medusa — the same
/// properties the Foundry invariant suite checks, driven by different
/// engines. `echidna_*` functions are echidna properties, `property_*`
/// functions are medusa properties; both read the same state.
///
/// Only the HARDENED contracts are deployed here: every property must hold.
///
/// echidna:  echidna test/echidna/PoolProperties.sol --contract PoolProperties --config echidna.yaml
/// medusa:   medusa fuzz --config medusa.json
contract PoolProperties {
    address internal constant TREASURY = address(0x7EA5);

    MockAsset internal asset;
    LendingPool internal pool;
    ShareVault internal vault;

    uint256 internal poolIn;
    uint256 internal poolOut;
    uint256 internal vaultIn;
    uint256 internal vaultOut;
    uint256 internal yieldIn;
    uint256 internal feesAccrued;
    uint256 internal roundingBudget;

    constructor() {
        asset = new MockAsset();
        pool = new LendingPool(IERC20(address(asset)), 1e9); // ~3%/yr
        vault = new ShareVault(IERC20(address(asset)), TREASURY, 1_000); // 10% fee
        asset.mint(address(this), 1e30);
        asset.mint(address(pool.reserve()), 1e27);
        asset.mint(address(vault.reserve()), 1e27);
        asset.approve(address(pool), type(uint256).max);
        asset.approve(address(vault), type(uint256).max);
    }

    /// @dev Floor rounding makes the vault keep dust: a user op loses less
    /// than one unit of share price, so the principal bound is rate-relative,
    /// not a flat wei constant.
    function _chargeDust() internal {
        roundingBudget += vault.exchangeRate() / 1e18 + 2;
    }

    // --- pool actions --------------------------------------------------------

    function pool_deposit(uint96 amount) public {
        amount = uint96(1 + amount % 100 ether);
        poolIn += amount;
        pool.deposit(amount);
    }

    function pool_withdraw(uint256 shares) public {
        uint256 owned = pool.shareOf(address(this));
        if (owned == 0) return;
        shares = 1 + shares % owned;
        poolOut += pool.withdraw(shares);
    }

    /// The donation: a plain transfer that must not move the share price.
    function pool_donate(uint96 amount) public {
        amount = uint96(amount % 1_000 ether);
        asset.transfer(address(pool), amount);
    }

    /// Book interest. Echidna and medusa randomize block timestamps between
    /// calls, so accrual windows vary on their own.
    function pool_accrue() public {
        pool.accrue();
    }

    // --- vault actions -------------------------------------------------------

    function vault_deposit(uint96 amount) public {
        amount = uint96(1 + amount % 100 ether);
        _chargeDust();
        vaultIn += amount;
        vault.deposit(amount);
    }

    function vault_withdraw(uint256 shares) public {
        uint256 owned = vault.shareOf(address(this));
        if (owned == 0) return;
        shares = 1 + shares % owned;
        _chargeDust();
        vaultOut += vault.withdraw(shares);
    }

    /// Fund a bounded gain and book the fee, valuing the mint exactly at the
    /// pre-mint, post-gain price (owner of the vault is this contract).
    function vault_harvest(uint96 gain) public {
        gain = uint96(gain % 1 ether);
        uint256 feeShares = vault.harvest(gain);
        if (feeShares > 0) {
            feesAccrued += feeShares * (vault.totalAssets() + 1) / (vault.totalShares() - feeShares + 1);
        }
        yieldIn += gain;
    }

    // --- properties ------------------------------------------------------------

    function _poolSolvent() internal view returns (bool) {
        return pool.convertToAssets(pool.totalShares()) <= asset.balanceOf(address(pool)) + 2;
    }

    function _vaultSolvent() internal view returns (bool) {
        return vault.convertToAssets(vault.totalShares()) <= asset.balanceOf(address(vault)) + 2;
    }

    function _feesBounded() internal view returns (bool) {
        return feesAccrued <= yieldIn * vault.feeBps() / 10_000 + 64;
    }

    function _principalBacked() internal view returns (bool) {
        uint256 claim = vault.convertToAssets(vault.shareOf(address(this)));
        return claim + vaultOut + roundingBudget >= vaultIn;
    }

    function echidna_pool_solvency() public view returns (bool) {
        return _poolSolvent();
    }

    function echidna_vault_solvency() public view returns (bool) {
        return _vaultSolvent();
    }

    function echidna_vault_fees_bounded_by_yield() public view returns (bool) {
        return _feesBounded();
    }

    function echidna_vault_principal_backed() public view returns (bool) {
        return _principalBacked();
    }

    function property_pool_solvency() public view returns (bool) {
        return _poolSolvent();
    }

    function property_vault_solvency() public view returns (bool) {
        return _vaultSolvent();
    }

    function property_vault_fees_bounded_by_yield() public view returns (bool) {
        return _feesBounded();
    }

    function property_vault_principal_backed() public view returns (bool) {
        return _principalBacked();
    }
}
