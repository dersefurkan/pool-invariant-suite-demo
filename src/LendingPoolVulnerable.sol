// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20, IPool} from "./IPool.sol";
import {YieldReserve} from "./YieldReserve.sol";

/// @notice INTENTIONALLY VULNERABLE pool. Do not ship this.
///
/// Same API and same interest mechanism as `LendingPool`, with one difference:
/// the share price is computed from the live token balance
/// (`totalAssets() == asset.balanceOf(this)`) instead of an internal ledger,
/// and there is no virtual offset in the conversion math.
///
/// That is the classic first-depositor inflation setup: deposit 1 wei for
/// 1 share, donate to inflate the price, and every later deposit mints
/// rounding-down shares — including zero — that the first share then claims.
/// `test/killed/` proves the invariant suite catches it.
contract LendingPoolVulnerable is IPool {
    IERC20 public immutable asset;
    YieldReserve public immutable reserve;
    address public immutable owner;

    uint256 public totalShares;
    mapping(address => uint256) public shareOf;

    uint256 public ratePerSecond;
    uint256 public constant MAX_RATE_PER_SECOND = 3_170_979_198; // ~10%/yr linear
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

    /// @dev The bug: the ledger is the live balance, so a plain transfer moves
    /// the share price.
    function totalAssets() public view returns (uint256) {
        return asset.balanceOf(address(this));
    }

    function exchangeRate() external view returns (uint256) {
        uint256 s = totalShares;
        if (s == 0) return 1e18;
        return totalAssets() * 1e18 / s;
    }

    function convertToAssets(uint256 shares) public view returns (uint256) {
        uint256 s = totalShares;
        if (s == 0) return shares;
        return shares * totalAssets() / s;
    }

    function setRatePerSecond(uint256 ratePerSecond_) external {
        require(msg.sender == owner, "NOT_OWNER");
        require(ratePerSecond_ <= MAX_RATE_PER_SECOND, "RATE_CAP");
        accrue();
        ratePerSecond = ratePerSecond_;
    }

    function accrue() public {
        uint256 elapsed = block.timestamp - lastAccrual;
        if (elapsed == 0) return;
        lastAccrual = block.timestamp;
        uint256 base = totalAssets();
        if (base == 0 || ratePerSecond == 0) return;
        uint256 gain = base * ratePerSecond * elapsed / 1e18;
        if (gain > 0) reserve.fund(address(asset), gain);
    }

    function deposit(uint256 amount) external returns (uint256 shares) {
        require(amount > 0, "ZERO");
        accrue();
        uint256 before = totalAssets();
        asset.transferFrom(msg.sender, address(this), amount);
        uint256 received = totalAssets() - before;
        require(received > 0, "DUST");
        uint256 s = totalShares;
        shares = s == 0 ? received : received * s / before;
        // Missing: require(shares > 0). A deposit can mint zero shares and hand
        // its assets to existing shareholders. That is the kill.
        shareOf[msg.sender] += shares;
        totalShares = s + shares;
    }

    function withdraw(uint256 shares) external returns (uint256 assets) {
        require(shares > 0, "ZERO");
        require(shareOf[msg.sender] >= shares, "SHARES");
        accrue();
        assets = convertToAssets(shares);
        shareOf[msg.sender] -= shares;
        totalShares -= shares;
        asset.transfer(msg.sender, assets);
    }
}
