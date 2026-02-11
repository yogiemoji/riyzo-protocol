// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.28;

/// @title MockRiyzoRegistry - Minimal registry mock for valuation testing
/// @dev Implements decimals(assetId) and isManager(poolId, addr)
contract MockRiyzoRegistry {
    mapping(uint128 => uint8) public decimals;
    mapping(uint64 => mapping(address => bool)) public isManager;

    function setDecimals(uint128 assetId, uint8 dec) external {
        decimals[assetId] = dec;
    }

    function setManager(uint64 poolId, address manager, bool status) external {
        isManager[poolId][manager] = status;
    }
}
