// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "../../src/IPool.sol";
import {MockAsset} from "../../src/MockAsset.sol";
import {ShareVault} from "../../src/ShareVault.sol";

/// Symbolic checks for halmos (https://github.com/a16z/halmos). No cheatcode
/// library needed: every `check_*` parameter is a symbolic input. These do not
/// run under `forge test` (the prefix is `check_`, not `test_`).
///
/// The checks are deliberately linear — symbolic division/mulDiv-style share
/// pricing is where SMT solvers time out, so the heavy pricing properties are
/// covered by the fuzz + invariant lanes instead. Run:
///   halmos --match-contract ShareVaultSymbolic
contract ShareVaultSymbolic is Test {
    address internal treasury = address(0x7EA5);

    /// Any deposit size on a fresh vault: the ledger and the share supply
    /// track the deposit exactly (the virtual offset is conversion-only).
    function check_deposit_totals_consistent(uint96 amount) public {
        vm.assume(amount > 0 && amount <= 100 ether);
        MockAsset asset = new MockAsset();
        ShareVault vault = new ShareVault(IERC20(address(asset)), treasury, 1_000);
        asset.mint(address(this), amount);
        asset.approve(address(vault), amount);

        uint256 shares = vault.deposit(amount);

        assertEq(vault.totalAssets(), amount);
        assertEq(shares, amount); // fresh vault converts 1:1
        assertEq(asset.balanceOf(address(vault)), amount);
    }

    /// Any funded gain: totalAssets books exactly the funded amount — the fee
    /// is paid in shares, never skimmed off the ledger.
    function check_harvest_books_exact_gain(uint96 gain) public {
        vm.assume(gain > 0 && gain <= 100 ether);
        MockAsset asset = new MockAsset();
        ShareVault vault = new ShareVault(IERC20(address(asset)), treasury, 1_000);
        asset.mint(address(vault.reserve()), 1_000 ether);
        asset.mint(address(this), 100 ether);
        asset.approve(address(vault), 100 ether);
        vault.deposit(100 ether);

        vault.harvest(gain);

        assertEq(vault.totalAssets(), 100 ether + uint256(gain));
    }

    /// Any donation size: a plain transfer moves neither the ledger nor the
    /// share price.
    function check_donation_neutral(uint96 donation) public {
        MockAsset asset = new MockAsset();
        ShareVault vault = new ShareVault(IERC20(address(asset)), treasury, 1_000);
        asset.mint(address(this), 100 ether + uint256(donation));
        asset.approve(address(vault), 100 ether);
        vault.deposit(100 ether);
        uint256 rateBefore = vault.exchangeRate();
        uint256 assetsBefore = vault.totalAssets();

        asset.transfer(address(vault), donation);

        assertEq(vault.exchangeRate(), rateBefore);
        assertEq(vault.totalAssets(), assetsBefore);
    }
}
