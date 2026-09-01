// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "../../src/IPool.sol";
import {IVault} from "../../src/IVault.sol";
import {MockAsset} from "../../src/MockAsset.sol";
import {ShareVault} from "../../src/ShareVault.sol";

/// Deterministic checks plus fuzz around fee math, conversion rounding and
/// donation neutrality on the hardened vault.
contract ShareVaultUnit is Test {
    uint256 internal constant BPS = 10_000;

    MockAsset internal asset;
    ShareVault internal vault;
    address internal treasury = address(0x7EA5);
    address internal alice = address(0xA1);
    address internal bob = address(0xB0B);

    function setUp() public {
        asset = new MockAsset();
        vault = new ShareVault(IERC20(address(asset)), treasury, 1_000); // 10% performance fee
        asset.mint(address(vault.reserve()), 1_000_000 ether);
        asset.mint(alice, 1_000 ether);
        asset.mint(bob, 1_000 ether);
        vm.prank(alice);
        asset.approve(address(vault), type(uint256).max);
        vm.prank(bob);
        asset.approve(address(vault), type(uint256).max);
    }

    function test_constructor_rejects_fee_above_cap() public {
        uint256 cap = vault.MAX_FEE_BPS();
        vm.expectRevert(bytes("FEE_CAP"));
        new ShareVault(IERC20(address(asset)), treasury, cap + 1);
    }

    function test_set_fee_only_owner() public {
        vm.prank(alice);
        vm.expectRevert(bytes("NOT_OWNER"));
        vault.setFeeBps(500);
    }

    function test_set_fee_rejects_above_cap() public {
        uint256 cap = vault.MAX_FEE_BPS();
        vm.expectRevert(bytes("FEE_CAP"));
        vault.setFeeBps(cap + 1);
    }

    function test_harvest_only_owner() public {
        vm.prank(alice);
        vm.expectRevert(bytes("NOT_OWNER"));
        vault.harvest(1 ether);
    }

    /// Zero funded gain means zero fee: a dry cron tick must not move
    /// anything. This is the property the vulnerable variant breaks.
    function test_harvest_zero_gain_mints_no_fee() public {
        vm.prank(alice);
        vault.deposit(100 ether);
        uint256 rateBefore = vault.exchangeRate();
        uint256 assetsBefore = vault.totalAssets();

        uint256 feeShares = vault.harvest(0);

        assertEq(feeShares, 0);
        assertEq(vault.shareOf(treasury), 0);
        assertEq(vault.totalAssets(), assetsBefore);
        assertEq(vault.exchangeRate(), rateBefore);
    }

    /// Fee is exactly feeBps of the funded gain, taken as shares at the
    /// post-gain price; the treasury's claim never exceeds the nominal fee.
    function test_harvest_fee_math_exact() public {
        vm.prank(alice);
        vault.deposit(1_000 ether);

        vault.harvest(100 ether);

        uint256 treasuryClaim = vault.convertToAssets(vault.shareOf(treasury));
        assertApproxEqAbs(treasuryClaim, 10 ether, 1e17, "treasury holds ~10% of the gain");
        assertEq(vault.totalAssets(), 1_100 ether);
        assertGt(vault.exchangeRate(), 1e18, "share price rose on funded yield");
    }

    function test_deposit_zero_reverts() public {
        vm.prank(alice);
        vm.expectRevert(bytes("ZERO"));
        vault.deposit(0);
    }

    function test_withdraw_more_than_owned_reverts() public {
        vm.prank(alice);
        uint256 shares = vault.deposit(10 ether);
        vm.prank(alice);
        vm.expectRevert(bytes("SHARES"));
        vault.withdraw(shares + 1);
    }

    /// Fuzz: deposit then immediately withdraw everything — the user loses at
    /// most 2 wei of rounding dust and can never gain.
    function testFuzz_round_trip_bounded_loss(uint96 amount) public {
        amount = uint96(bound(amount, 1, 100 ether));
        vm.startPrank(alice);
        uint256 before = asset.balanceOf(alice);
        uint256 shares = vault.deposit(amount);
        uint256 out_ = vault.withdraw(shares);
        vm.stopPrank();

        assertEq(asset.balanceOf(alice), before - amount + out_);
        assertLe(out_, amount, "round trip never gains");
        assertGe(out_ + 2, amount, "round trip loses at most 2 wei");
    }

    /// Fuzz: share/asset conversion round trip is consistent modulo rounding.
    function testFuzz_convert_consistency(uint96 amount) public {
        vm.prank(alice);
        vault.deposit(100 ether); // non-trivial totals so rounding is real

        amount = uint96(bound(amount, 1, 100 ether));
        uint256 shares = vault.convertToShares(amount);
        uint256 back = vault.convertToAssets(shares);
        assertLe(back, amount, "conversion never rounds in the user's favor");
        assertApproxEqAbs(back, amount, 3, "conversion dust is bounded");
        assertLe(vault.convertToShares(back), shares, "asset->share round trip never gains");
    }

    /// A plain transfer must not move the share price or the ledger.
    function test_donation_does_not_move_price() public {
        vm.prank(alice);
        vault.deposit(100 ether);
        uint256 rateBefore = vault.exchangeRate();
        uint256 assetsBefore = vault.totalAssets();

        asset.mint(address(this), 50 ether);
        asset.transfer(address(vault), 50 ether);

        assertEq(vault.exchangeRate(), rateBefore);
        assertEq(vault.totalAssets(), assetsBefore);
        assertEq(asset.balanceOf(address(vault)), assetsBefore + 50 ether);
    }

    /// Fuzz: full cycle with yield — depositor principal is preserved and the
    /// treasury never takes more than its fee share of the funded gain.
    function testFuzz_full_cycle_with_yield(uint96 aliceAmt, uint96 bobAmt, uint96 gain) public {
        aliceAmt = uint96(bound(aliceAmt, 1, 100 ether));
        bobAmt = uint96(bound(bobAmt, 1, 100 ether));
        gain = uint96(bound(gain, 0, 100 ether));

        vm.prank(alice);
        uint256 aliceShares = vault.deposit(aliceAmt);
        vm.prank(bob);
        vault.deposit(bobAmt);

        vault.harvest(gain);

        uint256 feeBound = uint256(gain) * vault.feeBps() / BPS;
        assertLe(vault.convertToAssets(vault.shareOf(treasury)), feeBound + 2);

        vm.prank(alice);
        uint256 out_ = vault.withdraw(aliceShares);
        assertGe(out_ + 2, aliceAmt, "principal preserved through yield cycle");
    }
}
