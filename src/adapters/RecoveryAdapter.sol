// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.28;

import {Auth} from "src/core/Auth.sol";
import {IRecoveryAdapter} from "src/interfaces/gateway/adapters/IRecoveryAdapter.sol";
import {IMultiAdapter} from "src/interfaces/gateway/IMultiAdapter.sol";

/// @title  RecoveryAdapter
/// @notice Minimal adapter that allows authorized governance to manually inject messages
///         into the MultiAdapter voting system. Used to recover stuck cross-chain messages
///         when a bridge adapter fails. The recovery adapter is registered in MultiAdapter's
///         adapter array and its vote counts toward the threshold like any other adapter.
///         send() and estimate() are no-ops since this adapter only handles injected messages.
contract RecoveryAdapter is Auth, IRecoveryAdapter {
    IMultiAdapter public immutable entrypoint;

    constructor(address entrypoint_) Auth(msg.sender) {
        entrypoint = IMultiAdapter(entrypoint_);
    }

    // --- Recovery ---

    /// @inheritdoc IRecoveryAdapter
    function recover(uint16 chainId, bytes calldata message) external auth {
        entrypoint.handle(chainId, message);
    }

    // --- No-op IAdapter implementations ---

    function send(uint16, bytes calldata, uint256, address) external payable {
        // No-op: recovery adapter only handles incoming (injected) messages
    }

    function estimate(uint16, bytes calldata, uint256) external pure returns (uint256) {
        return 0;
    }

    function wire(uint16, bytes calldata) external {
        // No-op: recovery adapter doesn't need chain wiring
    }

    function isWired(uint16) external pure returns (bool) {
        return true; // Always "wired" since it doesn't use bridges
    }
}
