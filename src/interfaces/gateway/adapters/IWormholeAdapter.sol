// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.28;

import {IAdapter} from "src/interfaces/gateway/IAdapter.sol";

// --- Wormhole Types (inline to avoid external dependencies) ---

/// @title  IWormholeRelayer
/// @notice Minimal Wormhole automatic relayer interface for EVM-to-EVM messaging
interface IWormholeRelayer {
    /// @notice Send a payload to an EVM target chain via Wormhole automatic relaying
    /// @param  targetChain    Wormhole chain ID of the destination
    /// @param  targetAddress  Address of the receiver contract on the destination chain
    /// @param  payload        Encoded message payload
    /// @param  receiverValue  Amount of native tokens to send to the receiver (in target chain wei)
    /// @param  gasLimit       Gas limit for the delivery transaction on the target chain
    /// @param  refundChain    Wormhole chain ID for gas refunds
    /// @param  refundAddress  Address to receive gas refunds
    /// @return sequence       Wormhole sequence number for this delivery
    function sendPayloadToEvm(
        uint16 targetChain,
        address targetAddress,
        bytes memory payload,
        uint256 receiverValue,
        uint256 gasLimit,
        uint16 refundChain,
        address refundAddress
    ) external payable returns (uint64 sequence);

    /// @notice Quote the delivery price for an EVM target chain
    /// @param  targetChain    Wormhole chain ID of the destination
    /// @param  receiverValue  Amount of native tokens to send to the receiver
    /// @param  gasLimit       Gas limit for the delivery transaction
    /// @return nativePriceQuote              Cost in source chain native tokens
    /// @return targetChainRefundPerGasUnused Refund rate for unused gas
    function quoteEVMDeliveryPrice(uint16 targetChain, uint256 receiverValue, uint256 gasLimit)
        external
        view
        returns (uint256 nativePriceQuote, uint256 targetChainRefundPerGasUnused);
}

/// @title  IWormholeReceiver
/// @notice Interface that must be implemented to receive Wormhole automatic relayer messages
interface IWormholeReceiver {
    /// @notice Called by the Wormhole relayer when a message arrives
    /// @param  payload        The original message payload
    /// @param  additionalVaas Additional VAAs (unused in our case)
    /// @param  sourceAddress  Sender address encoded as bytes32 (left-padded)
    /// @param  sourceChain    Wormhole chain ID of the source
    /// @param  deliveryHash   Unique hash for this delivery
    function receiveWormholeMessages(
        bytes memory payload,
        bytes[] memory additionalVaas,
        bytes32 sourceAddress,
        uint16 sourceChain,
        bytes32 deliveryHash
    ) external payable;
}

/// @title  IWormholeAdapter
/// @notice Adapter interface for Wormhole automatic relayer bridge integration
interface IWormholeAdapter is IAdapter, IWormholeReceiver {
    event File(bytes32 indexed what, uint256 value);

    /// @notice The Wormhole automatic relayer address
    function relayer() external view returns (IWormholeRelayer);
}
