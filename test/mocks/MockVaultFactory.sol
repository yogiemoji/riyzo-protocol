// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.28;

/// @title MockVaultFactory - VaultFactory mock for testing
contract MockVaultFactory {
    uint256 public deployCount;
    address public lastDeployedVault;

    // Track deployments
    address[] public deployedVaults;

    event VaultDeployed(address vault, uint64 poolId, bytes16 trancheId, address asset, address tranche);

    function newVault(
        uint64 poolId,
        bytes16 trancheId,
        address asset,
        address tranche,
        address, /* escrow */
        address, /* investmentManager */
        address[] calldata /* wards */
    ) external returns (address) {
        // Create a deterministic address based on inputs
        address vault = address(uint160(uint256(keccak256(abi.encodePacked(poolId, trancheId, asset, deployCount)))));

        deployedVaults.push(vault);
        lastDeployedVault = vault;
        deployCount++;

        emit VaultDeployed(vault, poolId, trancheId, asset, tranche);
        return vault;
    }

    function getDeployedVault(uint256 index) external view returns (address) {
        return deployedVaults[index];
    }
}
