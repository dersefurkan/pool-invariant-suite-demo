// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "./IPool.sol";
import {YieldReserve} from "./YieldReserve.sol";
import {IVault} from "./IVault.sol";

/// @notice Share-accounted yield vault with a performance fee — the hardened
/// version.
///
/// Defenses on purpose:
///  - Internal `totalAssets` ledger: raw donations do not move the share price.
///  - Virtual offset (+1 share / +1 asset) in the conversion math: deposit
///    rounding dust is bounded to a couple of wei.
///  - The performance fee is charged on FUNDED GAIN ONLY, never on principal,
///    and minted as shares at the post-gain price. With fee <= gain a harvest
///    cannot push the share price down.
///  - `feeBps` is hard-capped at 30%.
contract ShareVault is IVault {
    uint256 internal constant BPS = 10_000;

    IERC20 public immutable asset;
    YieldReserve public immutable reserve;
    address public immutable owner;
    address public immutable treasury;

    uint256 public totalShares;
    uint256 public totalAssets; // internal ledger — excludes raw donations
    mapping(address => uint256) public shareOf;

    uint256 public feeBps;
    uint256 public constant MAX_FEE_BPS = 3_000; // 30%

    constructor(IERC20 asset_, address treasury_, uint256 feeBps_) {
        require(feeBps_ <= MAX_FEE_BPS, "FEE_CAP");
        asset = asset_;
        treasury = treasury_;
        owner = msg.sender;
        reserve = new YieldReserve();
        feeBps = feeBps_;
    }

    function exchangeRate() public view returns (uint256) {
        return (totalAssets + 1) * 1e18 / (totalShares + 1);
    }

    function convertToShares(uint256 assets_) public view returns (uint256) {
        return assets_ * (totalShares + 1) / (totalAssets + 1);
    }

    function convertToAssets(uint256 shares_) public view returns (uint256) {
        return shares_ * (totalAssets + 1) / (totalShares + 1);
    }

    function setFeeBps(uint256 feeBps_) external {
        require(msg.sender == owner, "NOT_OWNER");
        require(feeBps_ <= MAX_FEE_BPS, "FEE_CAP");
        feeBps = feeBps_;
    }

    /// @notice Fund yield from the reserve and take the performance fee out of
    /// the gain. The fee is minted as shares at the post-gain price, so with
    /// fee <= gain the share price never decreases on a harvest.
    function harvest(uint256 gain) external returns (uint256 feeShares) {
        require(msg.sender == owner, "NOT_OWNER");
        uint256 funded = reserve.fund(address(asset), gain);
        if (funded == 0) return 0;
        totalAssets += funded;
        uint256 fee = funded * feeBps / BPS;
        if (fee == 0) return 0;
        feeShares = convertToShares(fee);
        if (feeShares == 0) return 0;
        shareOf[treasury] += feeShares;
        totalShares += feeShares;
    }

    function deposit(uint256 amount) external returns (uint256 shares) {
        require(amount > 0, "ZERO");
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
        assets = convertToAssets(shares);
        shareOf[msg.sender] -= shares;
        totalShares -= shares;
        totalAssets -= assets;
        asset.transfer(msg.sender, assets);
    }
}
