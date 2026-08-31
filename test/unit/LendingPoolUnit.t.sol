// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "../../src/IPool.sol";
import {MockAsset} from "../../src/MockAsset.sol";
import {LendingPool} from "../../src/LendingPool.sol";

/// Small deterministic checks around the rate cap and accrual math.
contract LendingPoolUnit is Test {
    MockAsset internal asset;
    LendingPool internal pool;
    address internal alice = address(0xA1);

    function setUp() public {
        asset = new MockAsset();
        pool = new LendingPool(IERC20(address(asset)), 1e9);
        asset.mint(address(pool.reserve()), 1_000_000 ether);
        asset.mint(alice, 100 ether);
        vm.prank(alice);
        asset.approve(address(pool), type(uint256).max);
    }

    function test_constructor_rejects_rate_above_cap() public {
        uint256 cap = pool.MAX_RATE_PER_SECOND();
        vm.expectRevert(bytes("RATE_CAP"));
        new LendingPool(IERC20(address(asset)), cap + 1);
    }

    function test_set_rate_rejects_rate_above_cap() public {
        uint256 cap = pool.MAX_RATE_PER_SECOND();
        vm.expectRevert(bytes("RATE_CAP"));
        pool.setRatePerSecond(cap + 1);
    }

    function test_set_rate_only_owner() public {
        vm.prank(alice);
        vm.expectRevert(bytes("NOT_OWNER"));
        pool.setRatePerSecond(1e9);
    }

    function test_accrual_matches_linear_rate_math() public {
        vm.prank(alice);
        pool.deposit(100 ether);
        vm.warp(block.timestamp + 1_000);
        pool.accrue();
        uint256 expected = 100 ether + (100 ether * 1e9 * 1_000 / 1e18);
        assertEq(pool.totalAssets(), expected);
    }

    function test_deposit_zero_reverts() public {
        vm.prank(alice);
        vm.expectRevert(bytes("ZERO"));
        pool.deposit(0);
    }

    function test_withdraw_more_than_owned_reverts() public {
        vm.prank(alice);
        uint256 shares = pool.deposit(10 ether);
        vm.prank(alice);
        vm.expectRevert(bytes("SHARES"));
        pool.withdraw(shares + 1);
    }
}
