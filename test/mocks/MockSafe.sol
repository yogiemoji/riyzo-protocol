// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.28;

/// @title MockSafe - Minimal Safe mock for guardian testing
contract MockSafe {
    mapping(address => bool) public isOwner;

    function setOwner(address owner, bool status) external {
        isOwner[owner] = status;
    }
}
