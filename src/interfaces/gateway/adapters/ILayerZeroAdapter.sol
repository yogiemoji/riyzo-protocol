// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.28;

import {IAdapter} from "src/interfaces/gateway/IAdapter.sol";

// --- LayerZero V2 Types (inline to avoid external dependencies) ---

/// @dev Origin information for an incoming LayerZero message
struct Origin {
    uint32 srcEid; // Source endpoint ID
    bytes32 sender; // Sender address as bytes32
    uint64 nonce; // Message nonce
}

/// @dev Parameters for sending a LayerZero message
struct MessagingParams {
    uint32 dstEid; // Destination endpoint ID
    bytes32 receiver; // Receiver address as bytes32
    bytes message; // Encoded message payload
    bytes options; // Executor/DVN options
    bool payInLzToken; // Whether to pay in LZ token
}

/// @dev Fee breakdown for a LayerZero message
struct MessagingFee {
    uint256 nativeFee; // Fee in native token
    uint256 lzTokenFee; // Fee in LZ token
}

/// @dev Receipt returned after sending a LayerZero message
struct MessagingReceipt {
    bytes32 guid; // Global unique identifier
    uint64 nonce; // Message nonce
    MessagingFee fee; // Actual fees charged
}

/// @title  ILayerZeroEndpointV2
/// @notice Minimal LayerZero V2 endpoint interface for sending and quoting messages
interface ILayerZeroEndpointV2 {
    /// @notice Send a message through the LayerZero protocol
    function send(MessagingParams calldata params, address refundAddress)
        external
        payable
        returns (MessagingReceipt memory);

    /// @notice Quote the fee for sending a message
    function quote(MessagingParams calldata params, address sender) external view returns (MessagingFee memory);

    /// @notice Set the delegate address for this OApp
    function setDelegate(address delegate) external;
}

/// @title  ILayerZeroReceiver
/// @notice Interface that must be implemented to receive LayerZero V2 messages
interface ILayerZeroReceiver {
    /// @notice Called by the LayerZero endpoint when a message arrives
    function lzReceive(
        Origin calldata origin,
        bytes32 guid,
        bytes calldata message,
        address executor,
        bytes calldata extraData
    ) external payable;
}

/// @title  ILayerZeroAdapter
/// @notice Adapter interface for LayerZero V2 bridge integration
interface ILayerZeroAdapter is IAdapter, ILayerZeroReceiver {
    event File(bytes32 indexed what, uint256 value);

    /// @notice The LayerZero V2 endpoint address
    function endpoint() external view returns (ILayerZeroEndpointV2);
}
