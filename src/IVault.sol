// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "./IPool.sol";
import {YieldReserve} from "./YieldReserve.sol";

/// @notice Vault surface the fee-accounting harness drives. Both the hardened
/// vault and the intentionally vulnerable variant implement it, so the same
/// handler and the same invariants run against either one.
interface IVault {
    function asset() external view returns (IERC20);
    function reserve() external view returns (YieldReserve);
    function owner() external view returns (address);
    function treasury() external view returns (address);
    function totalAssets() external view returns (uint256);
    function totalShares() external view returns (uint256);
    function shareOf(address account) external view returns (uint256);
    function feeBps() external view returns (uint256);
    function MAX_FEE_BPS() external view returns (uint256);
    function convertToShares(uint256 assets) external view returns (uint256);
    function convertToAssets(uint256 shares) external view returns (uint256);
    function exchangeRate() external view returns (uint256);
    function deposit(uint256 amount) external returns (uint256 shares);
    function withdraw(uint256 shares) external returns (uint256 assets);
    function harvest(uint256 gain) external returns (uint256 feeShares);
}
