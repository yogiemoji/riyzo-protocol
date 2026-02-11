// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.28;

import {Auth} from "src/core/Auth.sol";
import {ArrayLib} from "src/core/libraries/ArrayLib.sol";
import {IMultiAdapter, MAX_ADAPTER_COUNT} from "src/interfaces/gateway/IMultiAdapter.sol";
import {IAdapter} from "src/interfaces/gateway/IAdapter.sol";
import {IMessageHandler} from "src/interfaces/gateway/IGateway.sol";

/// @title  MultiAdapter
/// @notice Quorum coordinator that manages per-chain adapter sets with threshold voting.
///         Receives incoming messages from bridge adapters, counts votes per message hash,
///         and forwards to Gateway when the configured threshold is met.
///         For outgoing messages, distributes the payload to all registered adapters.
contract MultiAdapter is Auth, IMultiAdapter {
    using ArrayLib for int16[MAX_ADAPTER_COUNT];

    /// @inheritdoc IMultiAdapter
    uint16 public immutable localChainId;

    /// @inheritdoc IMultiAdapter
    address public gateway;

    /// @inheritdoc IMultiAdapter
    uint64 public globalSessionId;

    /// @dev Per-chain adapter address arrays
    mapping(uint16 chainId => address[]) internal _adapters;

    /// @dev Per-chain, per-message vote tracking
    mapping(uint16 chainId => mapping(bytes32 messageHash => Inbound)) internal _inbound;

    /// @dev Per-chain, per-adapter metadata
    mapping(uint16 chainId => mapping(address adapter => Adapter)) internal _adapterDetails;

    constructor(uint16 localChainId_) Auth(msg.sender) {
        localChainId = localChainId_;
    }

    // --- Administration ---

    /// @inheritdoc IMultiAdapter
    function file(bytes32 what, address data) external auth {
        if (what == "gateway") gateway = data;
        else revert("MultiAdapter/file-unrecognized-param");
        emit File(what, data);
    }

    /// @inheritdoc IMultiAdapter
    function setAdapters(uint16 chainId, address[] calldata adapters_, uint8 threshold, uint8 recoveryIndex)
        external
        auth
    {
        uint256 count = adapters_.length;
        require(count > 0, "MultiAdapter/empty-adapter-set");
        require(count <= MAX_ADAPTER_COUNT, "MultiAdapter/exceeds-max");
        require(threshold > 0 && threshold <= count, "MultiAdapter/invalid-threshold");
        require(recoveryIndex == 0 || recoveryIndex <= count, "MultiAdapter/invalid-recovery-index");

        // Increment session to invalidate all pending votes across all chains
        uint64 newSessionId = ++globalSessionId;

        // Clear old adapter details for this chain
        address[] storage oldAdapters = _adapters[chainId];
        uint256 oldCount = oldAdapters.length;
        for (uint256 i; i < oldCount; i++) {
            delete _adapterDetails[chainId][oldAdapters[i]];
        }

        // Set new adapter details
        for (uint256 j; j < count; j++) {
            require(_adapterDetails[chainId][adapters_[j]].id == 0, "MultiAdapter/no-duplicates");
            _adapterDetails[chainId][adapters_[j]] = Adapter({
                id: uint8(j + 1), // 1-based
                threshold: threshold,
                recoveryIndex: recoveryIndex,
                activeSessionId: newSessionId
            });
        }

        _adapters[chainId] = adapters_;

        emit SetAdapters(chainId, adapters_, threshold, recoveryIndex);
    }

    // --- Incoming ---

    /// @inheritdoc IMultiAdapter
    function handle(uint16 chainId, bytes calldata payload) external {
        Adapter memory adapter = _adapterDetails[chainId][msg.sender];
        require(adapter.id != 0, "MultiAdapter/invalid-adapter");

        emit HandleMessage(chainId, payload, msg.sender);

        // Special case: threshold of 1 skips vote tracking for gas efficiency
        if (adapter.threshold == 1) {
            IMessageHandler(gateway).handle(payload);
            emit ExecuteMessage(chainId, payload);
            return;
        }

        bytes32 messageHash = keccak256(payload);
        Inbound storage state = _inbound[chainId][messageHash];

        // Reset votes if session has changed (adapters were reconfigured)
        if (adapter.activeSessionId != state.sessionId) {
            delete state.votes;
            delete state.pendingMessage;
            state.sessionId = adapter.activeSessionId;
        }

        // Increment vote for this adapter
        state.votes[adapter.id - 1]++;

        // Check if threshold is met
        if (state.votes.countPositiveValues() >= adapter.threshold) {
            // Use stored pending message if available, otherwise use current payload
            bytes memory message;
            if (state.pendingMessage.length > 0) {
                message = state.pendingMessage;
            } else {
                message = payload;
            }

            // Forward to Gateway
            IMessageHandler(gateway).handle(message);
            emit ExecuteMessage(chainId, message);

            // Decrease votes by threshold count. All adapter votes are consumed equally,
            // including the recovery adapter. No skipping needed for correct behavior.
            state.votes.decreaseFirstNValues(adapter.threshold, type(uint8).max);

            // Clear pending message if no more positive votes remain
            if (state.votes.isNonPositive()) {
                delete state.pendingMessage;
            }
        } else if (state.pendingMessage.length == 0) {
            // Store the message body for later execution when threshold is met
            state.pendingMessage = payload;
        }
    }

    // --- Outgoing ---

    /// @inheritdoc IMultiAdapter
    function send(uint16 chainId, bytes calldata payload, uint256 gasLimit, address refund) external payable auth {
        address[] storage chainAdapters = _adapters[chainId];
        uint256 numAdapters = chainAdapters.length;
        require(numAdapters > 0, "MultiAdapter/no-adapters");

        uint256 remaining = msg.value;
        for (uint256 i; i < numAdapters; i++) {
            IAdapter currentAdapter = IAdapter(chainAdapters[i]);
            uint256 cost = currentAdapter.estimate(chainId, payload, gasLimit);

            // Last adapter gets all remaining funds to avoid dust
            uint256 payment = (i == numAdapters - 1) ? remaining : cost;
            if (payment > remaining) payment = remaining;
            remaining -= payment;

            currentAdapter.send{value: payment}(chainId, payload, gasLimit, refund);
        }

        emit SendMessage(chainId, payload);
    }

    /// @inheritdoc IMultiAdapter
    function estimate(uint16 chainId, bytes calldata payload, uint256 gasLimit) external view returns (uint256 total) {
        address[] storage chainAdapters = _adapters[chainId];
        uint256 numAdapters = chainAdapters.length;
        for (uint256 i; i < numAdapters; i++) {
            total += IAdapter(chainAdapters[i]).estimate(chainId, payload, gasLimit);
        }
    }

    // --- View ---

    /// @inheritdoc IMultiAdapter
    function getAdapters(uint16 chainId) external view returns (address[] memory) {
        return _adapters[chainId];
    }
}
