// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.28;

import {MockERC20} from "./MockERC20.sol";

/// @title MockEscrow - Escrow mock for testing
/// @dev Simplified mock that holds tokens and allows approved transfers
contract MockEscrow {
    mapping(address => mapping(address => uint256)) public approvals;

    function approveMax(address token, address spender) external {
        approvals[token][spender] = type(uint256).max;
        MockERC20(token).approve(spender, type(uint256).max);
    }

    function unapprove(address token, address spender) external {
        approvals[token][spender] = 0;
        MockERC20(token).approve(spender, 0);
    }

    function isApproved(address token, address spender) external view returns (bool) {
        return approvals[token][spender] > 0;
    }
}
