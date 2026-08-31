// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {YieldReserve} from "./YieldReserve.sol";

/// @notice Minimal ERC-20 interface — everything the pool accounting needs.
interface IERC20 {
    function balanceOf(address account) external view returns (uint256);
    function allowance(address owner, address spender) external view returns (uint256);
    function approve(address spender, uint256 amount) external returns (bool);
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

/// @notice Pool surface the invariant harness drives. Both the hardened pool
/// and the intentionally vulnerable variant implement it, so the same handler
/// and the same invariants run against either one.
interface IPool {
    function asset() external view returns (IERC20);
    function reserve() external view returns (YieldReserve);
    function totalAssets() external view returns (uint256);
    function totalShares() external view returns (uint256);
    function shareOf(address account) external view returns (uint256);
    function maxRatePerSecond() external view returns (uint256);
    function convertToAssets(uint256 shares) external view returns (uint256);
    function exchangeRate() external view returns (uint256);
    function deposit(uint256 amount) external returns (uint256 shares);
    function withdraw(uint256 shares) external returns (uint256 assets);
    function accrue() external;
}
