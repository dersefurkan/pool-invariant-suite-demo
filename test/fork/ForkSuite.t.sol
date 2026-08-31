// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "../../src/IPool.sol";
import {MockAsset, MockFeeOnTransferToken} from "../../src/MockAsset.sol";
import {LendingPool} from "../../src/LendingPool.sol";

/// Fork tests against Ethereum mainnet state. The synthetic pool is pointed
/// at real mainnet WETH/USDC so the accounting is exercised against real
/// token semantics instead of a friendly mock.
///
/// These are network-dependent and opt-in: they skip unless ETH_RPC_URL is
/// set. Run with:
///   ETH_RPC_URL=https://eth.drpc.org forge test --match-path 'test/fork/**' -vv
contract ForkSuite is Test {
    address internal constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address internal constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;

    address internal alice = address(0xA1);

    function setUp() public {
        string memory rpc = vm.envOr("ETH_RPC_URL", string(""));
        vm.skip(bytes(rpc).length == 0, "fork tests are opt-in: set ETH_RPC_URL");
        vm.createSelectFork(rpc);
    }

    /// WETH: deposit -> withdraw round trip against real mainnet semantics.
    function test_fork_weth_round_trip() public {
        LendingPool pool = new LendingPool(IERC20(WETH), 1e9);
        deal(WETH, address(pool.reserve()), 1_000 ether);
        deal(WETH, alice, 10 ether);

        vm.startPrank(alice);
        IERC20(WETH).approve(address(pool), type(uint256).max);
        uint256 shares = pool.deposit(5 ether);
        uint256 out = pool.withdraw(shares);
        vm.stopPrank();

        assertLe(out, 5 ether, "round trip cannot create value");
        assertGe(out + 2, 5 ether, "round trip loses at most rounding dust");
    }

    /// USDC: same round trip with 6 decimals.
    function test_fork_usdc_round_trip() public {
        LendingPool pool = new LendingPool(IERC20(USDC), 1e9);
        deal(USDC, address(pool.reserve()), 1_000_000e6);
        deal(USDC, alice, 10_000e6);

        vm.startPrank(alice);
        IERC20(USDC).approve(address(pool), type(uint256).max);
        uint256 shares = pool.deposit(5_000e6);
        uint256 out = pool.withdraw(shares);
        vm.stopPrank();

        assertLe(out, 5_000e6, "round trip cannot create value");
        assertGe(out + 2, 5_000e6, "round trip loses at most rounding dust");
    }

    /// WETH: interest accrual is funded, rate-capped, and claimable.
    function test_fork_weth_yield_accrual() public {
        LendingPool pool = new LendingPool(IERC20(WETH), 1e9); // ~3%/yr
        deal(WETH, address(pool.reserve()), 1_000 ether);
        deal(WETH, alice, 10 ether);

        vm.startPrank(alice);
        IERC20(WETH).approve(address(pool), type(uint256).max);
        uint256 shares = pool.deposit(5 ether);

        vm.warp(block.timestamp + 30 days);
        pool.accrue();

        uint256 out = pool.withdraw(shares);
        vm.stopPrank();

        uint256 maxGain = 5 ether * pool.MAX_RATE_PER_SECOND() * 30 days / 1e18;
        assertGt(out, 5 ether, "yield was paid");
        assertLe(out - 5 ether, maxGain + 1, "yield stays under the cap");
    }

    /// Fee-on-transfer: the pool must book what it received, not what the
    /// caller asked for. Deposit 100 with a 1% transfer fee -> 99 credited;
    /// ledger and balance stay consistent and the position unwinds cleanly.
    function test_fork_fee_on_transfer_accounting() public {
        MockFeeOnTransferToken fee = new MockFeeOnTransferToken();
        LendingPool pool = new LendingPool(IERC20(address(fee)), 0);
        fee.mint(address(pool.reserve()), 100 ether);
        fee.mint(alice, 100 ether);

        vm.startPrank(alice);
        fee.approve(address(pool), type(uint256).max);
        uint256 shares = pool.deposit(100 ether);

        assertEq(pool.totalAssets(), 99 ether, "ledger books the received amount");
        assertEq(fee.balanceOf(address(pool)), 99 ether, "balance matches ledger");

        uint256 out = pool.withdraw(shares);
        vm.stopPrank();

        assertEq(pool.totalAssets(), 0, "no stranded accounting");
        assertEq(out, 99 ether, "pool pays out the booked amount");
        // 1% fee on the way in and on the way out: 100 -> 99 -> 98.01
        assertEq(fee.balanceOf(alice), 98.01 ether, "alice receives payout minus fee");
    }
}
