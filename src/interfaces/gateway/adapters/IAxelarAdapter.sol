// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.28;

import {IAdapter} from "src/interfaces/gateway/IAdapter.sol";

/// @title  IAxelarGateway
/// @notice Minimal Axelar Gateway interface for cross-chain messaging
interface IAxelarGateway {
    function callContract(string calldata destinationChain, string calldata contractAddress, bytes calldata payload)
        external;

    function validateContractCall(
        bytes32 commandId,
        string calldata sourceChain,
        string calldata sourceAddress,
        bytes32 payloadHash
    ) external returns (bool);
}

/// @title  IAxelarGasService
/// @notice Minimal Axelar Gas Service interface for gas payment
interface IAxelarGasService {
    function payNativeGasForContractCall(
        address sender,
        string calldata destinationChain,
        string calldata destinationAddress,
        bytes calldata payload,
        address refundAddress
    ) external payable;
}

/// @title  IAxelarAdapter
/// @notice Adapter interface for Axelar bridge integration with multi-chain routing
interface IAxelarAdapter is IAdapter {
    event File(bytes32 indexed what, uint256 value);

    /// @dev Cost estimate in ETH (wei) for Axelar bridge fees
    function axelarCost() external view returns (uint256);

    /// @notice Updates a contract parameter
    /// @param what Accepts "axelarCost"
    function file(bytes32 what, uint256 value) external;

    /// @notice Execute an incoming message from Axelar
    function execute(
        bytes32 commandId,
        string calldata sourceChain,
        string calldata sourceAddress,
        bytes calldata payload
    ) external;
}
