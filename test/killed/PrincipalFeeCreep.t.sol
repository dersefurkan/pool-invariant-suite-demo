// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "../../src/IPool.sol";
import {IVault} from "../../src/IVault.sol";
import {MockAsset} from "../../src/MockAsset.sol";
import {ShareVault} from "../../src/ShareVault.sol";
import {ShareVaultVulnerable} from "../../src/ShareVaultVulnerable.sol";

/// Directed fee-creep PoC — the deterministic version of what the invariant
/// suite finds on its own. This is the 30-second run.
///
/// Sequence (both vaults get the exact same calls):
///   1. alice deposits 100 tokens
///   2. the owner runs the harvest cron 20 times with ZERO yield funded
///   3. alice withdraws everything
///
/// On the vulnerable vault each no-yield harvest still skims 10% of the whole
/// ledger into treasury shares. Twenty routine ticks bleed alice to ~12% of
/// her deposit. The vault stays "solvent" the whole time — claims equal the
/// balance — which is why ledger-only reviews miss the class.
contract PrincipalFeeCreep is Test {
    uint256 internal constant HARVESTS = 20;

    MockAsset internal asset;
    address internal treasury = address(0x7EA5);
    address internal alice = address(0xA1);

    function setUp() public {
        asset = new MockAsset();
        asset.mint(alice, 200 ether);
    }

    function _cron(IVault vault) internal {
        for (uint256 i = 0; i < HARVESTS; i++) {
            vault.harvest(0); // owner == this contract; no yield funded
        }
    }

    function test_fee_creep_drains_vulnerable_vault() public {
        ShareVaultVulnerable vault = new ShareVaultVulnerable(IERC20(address(asset)), treasury, 1_000);

        vm.startPrank(alice);
        asset.approve(address(vault), type(uint256).max);
        uint256 shares = vault.deposit(100 ether);
        vm.stopPrank();

        _cron(IVault(address(vault)));

        vm.prank(alice);
        uint256 out_ = vault.withdraw(shares);
        uint256 treasuryClaim = vault.convertToAssets(vault.shareOf(treasury));

        emit log_named_decimal_uint("alice in       ", 100 ether, 18);
        emit log_named_decimal_uint("alice out      ", out_, 18);
        emit log_named_decimal_uint("treasury claim ", treasuryClaim, 18);

        assertLt(out_, 20 ether, "20 no-yield harvests bleed alice below 20%");
        assertGt(treasuryClaim, 80 ether, "the difference sits in treasury shares");
        // Still "solvent": claims equal the balance. Price moved, not backing.
        assertEq(asset.balanceOf(address(vault)), vault.totalAssets());
    }

    function test_fixed_vault_holds_under_same_cron() public {
        ShareVault vault = new ShareVault(IERC20(address(asset)), treasury, 1_000);

        vm.startPrank(alice);
        asset.approve(address(vault), type(uint256).max);
        uint256 shares = vault.deposit(100 ether);
        vm.stopPrank();

        _cron(IVault(address(vault)));

        vm.prank(alice);
        uint256 out_ = vault.withdraw(shares);

        emit log_named_decimal_uint("alice in       ", 100 ether, 18);
        emit log_named_decimal_uint("alice out      ", out_, 18);

        assertEq(vault.shareOf(treasury), 0, "no yield -> no fee");
        assertApproxEqAbs(out_, 100 ether, 2, "alice keeps her principal");
    }
}
