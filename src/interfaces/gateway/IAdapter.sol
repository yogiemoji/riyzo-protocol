// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.28;

/// @title  IAdapter
/// @notice Chain-ID-based adapter interface for cross-chain message passing.
///         Each adapter wraps a specific bridge protocol (Axelar, LayerZero, Wormhole)
///         and translates between Riyzo chain IDs and bridge-native chain identifiers.
interface IAdapter {
    // --- Outgoing ---
    /// @notice Send a payload to the target chain via this adapter's bridge protocol.
    /// @param  chainId  Riyzo chain ID of the destination (1=Arbitrum, 2=Ethereum, 3=Base)
    /// @param  payload  The encoded message to send
    /// @param  gasLimit Gas limit for execution on the destination chain
    /// @param  refund   Address to receive any gas refund
    function send(uint16 chainId, bytes calldata payload, uint256 gasLimit, address refund) external payable;

    /// @notice Estimate the cost in native tokens for sending a payload.
    /// @param  chainId  Riyzo chain ID of the destination
    /// @param  payload  The encoded message to estimate for
    /// @param  gasLimit Gas limit for execution on the destination chain
    /// @return cost     Cost in native tokens (wei)
    function estimate(uint16 chainId, bytes calldata payload, uint256 gasLimit) external view returns (uint256 cost);

    // --- Configuration ---
    /// @notice Configure source/destination mappings for a chain.
    ///         Data format is adapter-specific (e.g., Axelar encodes chain name + address string,
    ///         LayerZero encodes EID + adapter address, Wormhole encodes chain ID + adapter address).
    /// @param  chainId Riyzo chain ID to configure
    /// @param  data    Adapter-specific configuration data
    function wire(uint16 chainId, bytes calldata data) external;

    /// @notice Check if this adapter has been configured for a given chain.
    /// @param  chainId Riyzo chain ID to check
    /// @return wired   True if source and destination mappings are configured
    function isWired(uint16 chainId) external view returns (bool wired);
}
