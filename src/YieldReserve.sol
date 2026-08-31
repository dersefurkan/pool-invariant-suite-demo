// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "./IPool.sol";

/// @notice Holds the tokens that back interest payments. The pool pulls from
/// here when it accrues; if the reserve cannot cover the full gain the pool
/// books only what was actually funded, so the ledger never outruns backing.
contract YieldReserve {
    address public immutable pool;

    constructor() {
        pool = msg.sender;
    }

    /// @dev Called by the pool during accrual. Funds `min(amount, balance)`.
    function fund(address token, uint256 amount) external returns (uint256 funded) {
        require(msg.sender == pool, "NOT_POOL");
        uint256 available = IERC20(token).balanceOf(address(this));
        funded = amount > available ? available : amount;
        if (funded > 0) {
            IERC20(token).transfer(pool, funded);
        }
    }
}
