// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.28;

import {MockShareToken} from "./MockShareToken.sol";

/// @title MockTrancheFactory - TrancheFactory mock for testing
contract MockTrancheFactory {
    uint256 public deployCount;
    address public lastDeployedToken;

    // Track deployments
    address[] public deployedTokens;

    event TokenDeployed(address token, uint64 poolId, bytes16 trancheId, string name, string symbol);

    function newTranche(
        uint64 poolId,
        bytes16 trancheId,
        string memory name,
        string memory symbol,
        uint8, /* decimals */
        address[] calldata /* wards */
    ) external returns (address) {
        // Deploy actual mock token so it can be used
        MockShareToken token = new MockShareToken(name, symbol);

        deployedTokens.push(address(token));
        lastDeployedToken = address(token);
        deployCount++;

        emit TokenDeployed(address(token), poolId, trancheId, name, symbol);
        return address(token);
    }

    function getDeployedToken(uint256 index) external view returns (address) {
        return deployedTokens[index];
    }
}
