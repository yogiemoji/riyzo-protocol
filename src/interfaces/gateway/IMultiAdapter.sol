// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.28;

uint8 constant MAX_ADAPTER_COUNT = 8;

/// @title  IMultiAdapter
/// @notice Quorum coordinator that manages per-chain adapter sets with threshold voting.
///         Receives incoming messages from adapters, counts votes, and forwards to Gateway
///         when the configured threshold is met. For outgoing messages, distributes to all
///         registered adapters for a chain.
interface IMultiAdapter {
    /// @dev Packed adapter metadata. ID starts at 1; id=0 means not registered.
    struct Adapter {
        /// @notice 1-based adapter ID, maps to index (id - 1) in the adapters array
        uint8 id;
        /// @notice Number of adapter confirmations required to execute a message
        uint8 threshold;
        /// @notice Index of the recovery adapter in the adapter array (0 = no recovery adapter)
        uint8 recoveryIndex;
        /// @notice Incremented on adapter reconfiguration to invalidate pending votes
        uint64 activeSessionId;
    }

    /// @dev Per-message vote tracking. Uses int16 to support recovery adapter vote adjustment.
    struct Inbound {
        /// @notice Vote counts per adapter slot. Can go negative after threshold-based decrement.
        int16[MAX_ADAPTER_COUNT] votes;
        /// @notice Session ID at the time votes were cast (mismatched = stale, must reset)
        uint64 sessionId;
        /// @notice Stored message body when the primary adapter delivers before threshold is met
        bytes pendingMessage;
    }

    // --- Events ---
    event SetAdapters(uint16 indexed chainId, address[] adapters, uint8 threshold, uint8 recoveryIndex);
    event HandleMessage(uint16 indexed chainId, bytes payload, address adapter);
    event ExecuteMessage(uint16 indexed chainId, bytes payload);
    event SendMessage(uint16 indexed chainId, bytes payload);
    event File(bytes32 indexed what, address instance);

    // --- Administration ---
    /// @notice Configure the adapter set for a specific chain.
    /// @param  chainId        Riyzo chain ID to configure
    /// @param  adapters_      Ordered array of adapter addresses
    /// @param  threshold      Number of confirmations required (must be <= adapters_.length)
    /// @param  recoveryIndex  1-based index of the recovery adapter (0 = none).
    ///                        The recovery adapter slot is skipped during vote decrement.
    function setAdapters(uint16 chainId, address[] calldata adapters_, uint8 threshold, uint8 recoveryIndex) external;

    /// @notice Update a contract address parameter.
    /// @param  what Accepts "gateway"
    /// @param  data The new address
    function file(bytes32 what, address data) external;

    // --- Incoming ---
    /// @notice Called by adapters when they receive a cross-chain message.
    ///         Validates the caller is a registered adapter, increments its vote,
    ///         and forwards to Gateway when the threshold is met.
    /// @param  chainId Riyzo chain ID of the source chain
    /// @param  payload The incoming message
    function handle(uint16 chainId, bytes calldata payload) external;

    // --- Outgoing ---
    /// @notice Send a message to a destination chain through all registered adapters.
    /// @param  chainId  Riyzo chain ID of the destination
    /// @param  payload  The encoded message to send
    /// @param  gasLimit Gas limit for execution on the destination chain
    /// @param  refund   Address to receive any gas refund
    function send(uint16 chainId, bytes calldata payload, uint256 gasLimit, address refund) external payable;

    /// @notice Estimate the total cost across all adapters for sending a message.
    /// @param  chainId  Riyzo chain ID of the destination
    /// @param  payload  The encoded message to estimate for
    /// @param  gasLimit Gas limit for execution on the destination chain
    /// @return total    Total cost in native tokens (wei)
    function estimate(uint16 chainId, bytes calldata payload, uint256 gasLimit) external view returns (uint256 total);

    // --- View ---
    /// @notice The address of the Gateway that receives forwarded messages
    function gateway() external view returns (address);

    /// @notice This chain's Riyzo chain ID
    function localChainId() external view returns (uint16);

    /// @notice Get the adapter addresses configured for a chain
    /// @param  chainId Riyzo chain ID
    /// @return Array of adapter addresses
    function getAdapters(uint16 chainId) external view returns (address[] memory);

    /// @notice Get the current global session ID
    function globalSessionId() external view returns (uint64);
}
