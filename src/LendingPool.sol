// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20, IPool} from "./IPool.sol";
import {YieldReserve} from "./YieldReserve.sol";

/// @notice Share-accounted lending pool — the hardened version.
///
/// Defenses on purpose:
///  - Internal `totalAssets` ledger: raw donations do not move the share price.
///  - Virtual offset (+1 share / +1 asset) in the conversion math: the classic
///    first-depositor inflation attack nets at most a couple of wei of rounding.
///  - Deposit credits the balance delta, so fee-on-transfer tokens cannot
///    desynchronize the ledger.
///  - Interest is funded by a real token reserve at accrual time, and the
///    rate is hard-capped, so claims never outrun backing.
contract LendingPool is IPool {
    IERC20 public immutable asset;
    YieldReserve public immutable reserve;
    address public immutable owner;

    uint256 public totalShares;
    uint256 public totalAssets; // internal ledger — excludes raw donations
    mapping(address => uint256) public shareOf;

    /// @dev Interest rate scaled by 1e18. Capped at ~10%/yr (linear).
    uint256 public ratePerSecond;
    /// @dev ~10%/yr linear: floor(1e18 / 31_536_000 / 10).
    uint256 public constant MAX_RATE_PER_SECOND = 3_170_979_198;
    uint256 public lastAccrual;

    constructor(IERC20 asset_, uint256 ratePerSecond_) {
        require(ratePerSecond_ <= MAX_RATE_PER_SECOND, "RATE_CAP");
        asset = asset_;
        reserve = new YieldReserve();
        owner = msg.sender;
        ratePerSecond = ratePerSecond_;
        lastAccrual = block.timestamp;
    }

    function maxRatePerSecond() external pure returns (uint256) {
        return MAX_RATE_PER_SECOND;
    }

    /// @notice Assets per share, scaled by 1e18.
    function exchangeRate() external view returns (uint256) {
        return (totalAssets + 1) * 1e18 / (totalShares + 1);
    }

    function convertToShares(uint256 assets) public view returns (uint256) {
        return assets * (totalShares + 1) / (totalAssets + 1);
    }

    function convertToAssets(uint256 shares) public view returns (uint256) {
        return shares * (totalAssets + 1) / (totalShares + 1);
    }

    function setRatePerSecond(uint256 ratePerSecond_) external {
        require(msg.sender == owner, "NOT_OWNER");
        require(ratePerSecond_ <= MAX_RATE_PER_SECOND, "RATE_CAP");
        accrue();
        ratePerSecond = ratePerSecond_;
    }

    /// @notice Book interest since the last accrual, backed by the reserve.
    /// If the reserve is short, only the funded part is booked.
    function accrue() public {
        uint256 elapsed = block.timestamp - lastAccrual;
        if (elapsed == 0) return;
        lastAccrual = block.timestamp;
        if (totalAssets == 0 || ratePerSecond == 0) return;
        uint256 gain = totalAssets * ratePerSecond * elapsed / 1e18;
        if (gain == 0) return;
        totalAssets += reserve.fund(address(asset), gain);
    }

    function deposit(uint256 amount) external returns (uint256 shares) {
        require(amount > 0, "ZERO");
        accrue();
        uint256 before = asset.balanceOf(address(this));
        asset.transferFrom(msg.sender, address(this), amount);
        uint256 received = asset.balanceOf(address(this)) - before; // fee-on-transfer safe
        require(received > 0, "DUST");
        shares = convertToShares(received);
        require(shares > 0, "ZERO_SHARES");
        shareOf[msg.sender] += shares;
        totalShares += shares;
        totalAssets += received;
    }

    function withdraw(uint256 shares) external returns (uint256 assets) {
        require(shares > 0, "ZERO");
        require(shareOf[msg.sender] >= shares, "SHARES");
        accrue();
        assets = convertToAssets(shares);
        shareOf[msg.sender] -= shares;
        totalShares -= shares;
        totalAssets -= assets;
        asset.transfer(msg.sender, assets);
    }
}
