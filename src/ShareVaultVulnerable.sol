// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "./IPool.sol";
import {YieldReserve} from "./YieldReserve.sol";
import {IVault} from "./IVault.sol";

/// @notice INTENTIONALLY VULNERABLE vault. Do not ship this.
///
/// Same API and same share math as `ShareVault`, with one difference: the
/// performance fee base is the WHOLE ledger (`totalAssets`), not the funded
/// gain. Every harvest moves `feeBps` of the vault — including depositors'
/// principal — to the treasury, even when no yield was funded at all. A
/// routine keeper cron quietly bleeds the vault dry.
///
/// That is the fee-creep class: the ledger stays solvent, claims still equal
/// the balance, but the PRICE drifts from depositors to the treasury.
/// `test/killed/PrincipalFeeCreep.t.sol` proves the invariant suite catches it.
contract ShareVaultVulnerable is IVault {
    uint256 internal constant BPS = 10_000;

    IERC20 public immutable asset;
    YieldReserve public immutable reserve;
    address public immutable owner;
    address public immutable treasury;

    uint256 public totalShares;
    uint256 public totalAssets;
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

    /// @dev The bug: the fee base is the whole ledger, so a no-yield harvest
    /// still mints treasury shares against depositors' principal.
    function harvest(uint256 gain) external returns (uint256 feeShares) {
        require(msg.sender == owner, "NOT_OWNER");
        uint256 funded = reserve.fund(address(asset), gain);
        totalAssets += funded;
        uint256 fee = totalAssets * feeBps / BPS; // fee on principal, every harvest
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
        uint256 received = asset.balanceOf(address(this)) - before;
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
