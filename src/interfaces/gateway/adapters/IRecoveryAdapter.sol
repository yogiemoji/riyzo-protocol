// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.28;

import {IAdapter} from "src/interfaces/gateway/IAdapter.sol";

/// @title  IRecoveryAdapter
/// @notice Minimal adapter that allows authorized governance to manually inject messages
///         into the MultiAdapter voting system. Used to recover stuck cross-chain messages
///         when a bridge adapter fails. send() and estimate() are no-ops since this adapter
///         only handles incoming (injected) messages.
interface IRecoveryAdapter is IAdapter {
    /// @notice Inject a message into the MultiAdapter as if it arrived from the given chain.
    ///         Only callable by authorized addresses (governance/admin).
    /// @param  chainId Riyzo chain ID the message originated from
    /// @param  message The message to inject
    function recover(uint16 chainId, bytes calldata message) external;
}
