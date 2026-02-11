// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.28;

/// @title MockTranche - Minimal tranche token mock for hook testing
/// @dev Implements hookDataOf and setHookData needed by BaseTransferHook
contract MockTranche {
    mapping(address => bytes16) public hookDataOf;

    function setHookData(address user, bytes16 data) external {
        hookDataOf[user] = data;
    }
}
