// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.28;

import {Auth} from "src/core/Auth.sol";
import {IQueueManager} from "src/interfaces/spoke/IQueueManager.sol";

/// @title QueueManager - Auto-Sync Queue Manager
/// @author Riyzo Protocol
/// @notice Manages automatic cross-chain synchronization of requests.
///         Batches requests and triggers sync when thresholds are met.
/// @dev QueueManager provides:
/// - Batching of deposit/redeem requests for gas efficiency
/// - Automatic triggering when batch size or time threshold reached
/// - Keeper-compatible interface for external automation
/// - Manual force-sync for admin control
///
/// SYNC TRIGGERS:
/// 1. Batch size reached (e.g., 1000 USDC accumulated)
/// 2. Time elapsed (e.g., 1 hour since last sync)
/// 3. Manual force by admin
///
/// KEEPER INTEGRATION:
/// - shouldSync() returns true when sync needed
/// - performSync() executes the sync
/// - Compatible with Chainlink Keepers, Gelato, etc.
contract QueueManager is Auth, IQueueManager {
    // ============================================================
    // STATE
    // ============================================================

    /// @notice RiyzoSpoke contract address
    address public spoke;

    /// @notice Queue configuration per pool/shareClass
    mapping(uint64 => mapping(bytes16 => QueueConfig)) internal _configs;

    /// @notice Queue state per pool/shareClass
    mapping(uint64 => mapping(bytes16 => QueueState)) internal _states;

    // ============================================================
    // CONSTRUCTOR
    // ============================================================

    /// @param deployer Initial ward address
    constructor(address deployer) Auth(deployer) {}

    // ============================================================
    // CONFIGURATION
    // ============================================================

    /// @notice Set spoke contract address
    /// @param what Configuration key
    /// @param data Address value
    function file(bytes32 what, address data) external auth {
        if (what == "spoke") spoke = data;
        else revert("QueueManager/file-unrecognized-param");
    }

    /// @inheritdoc IQueueManager
    function setQueueConfig(uint64 poolId, bytes16 scId, QueueConfig calldata config) external auth {
        if (config.maxDelay == 0) revert InvalidConfig("maxDelay cannot be zero");

        _configs[poolId][scId] = config;

        emit QueueConfigSet(poolId, scId, config.minBatchSize, config.maxDelay, config.gasLimit, config.autoSyncEnabled);
    }

    /// @inheritdoc IQueueManager
    function enableAutoSync(uint64 poolId, bytes16 scId) external auth {
        _configs[poolId][scId].autoSyncEnabled = true;
        emit AutoSyncEnabled(poolId, scId);
    }

    /// @inheritdoc IQueueManager
    function disableAutoSync(uint64 poolId, bytes16 scId) external auth {
        _configs[poolId][scId].autoSyncEnabled = false;
        emit AutoSyncDisabled(poolId, scId);
    }

    // ============================================================
    // QUEUE ACCUMULATION
    // ============================================================

    /// @inheritdoc IQueueManager
    function addToPendingDeposits(uint64 poolId, bytes16 scId, uint128 amount) external auth {
        QueueState storage state = _states[poolId][scId];
        state.pendingAssets += amount;

        emit DepositsQueued(poolId, scId, amount, state.pendingAssets);
    }

    /// @inheritdoc IQueueManager
    function addToPendingRedeems(uint64 poolId, bytes16 scId, uint128 shares) external auth {
        QueueState storage state = _states[poolId][scId];
        state.pendingShares += shares;

        emit RedeemsQueued(poolId, scId, shares, state.pendingShares);
    }

    // ============================================================
    // SYNC TRIGGERS
    // ============================================================

    /// @inheritdoc IQueueManager
    function checkAndSync(uint64 poolId, bytes16 scId) external returns (bool synced) {
        if (!_shouldSync(poolId, scId)) {
            return false;
        }

        _performSync(poolId, scId);
        return true;
    }

    /// @inheritdoc IQueueManager
    function forceSync(uint64 poolId, bytes16 scId) external auth {
        _performSync(poolId, scId);
        emit ForceSynced(poolId, scId, msg.sender);
    }

    // ============================================================
    // KEEPER INTERFACE
    // ============================================================

    /// @inheritdoc IQueueManager
    function shouldSync(uint64 poolId, bytes16 scId) external view returns (bool) {
        return _shouldSync(poolId, scId);
    }

    /// @inheritdoc IQueueManager
    function performSync(uint64 poolId, bytes16 scId) external {
        if (!_shouldSync(poolId, scId)) {
            revert SyncConditionsNotMet(poolId, scId);
        }

        _performSync(poolId, scId);
    }

    /// @inheritdoc IQueueManager
    function shouldSyncBatch(uint64[] calldata poolIds, bytes16[] calldata scIds)
        external
        view
        returns (bool[] memory results)
    {
        require(poolIds.length == scIds.length, "QueueManager/length-mismatch");

        results = new bool[](poolIds.length);
        for (uint256 i = 0; i < poolIds.length; i++) {
            results[i] = _shouldSync(poolIds[i], scIds[i]);
        }
    }

    // ============================================================
    // VIEW FUNCTIONS
    // ============================================================

    /// @inheritdoc IQueueManager
    function getQueueConfig(uint64 poolId, bytes16 scId) external view returns (QueueConfig memory) {
        return _configs[poolId][scId];
    }

    /// @inheritdoc IQueueManager
    function getQueueState(uint64 poolId, bytes16 scId) external view returns (QueueState memory) {
        return _states[poolId][scId];
    }

    /// @inheritdoc IQueueManager
    function timeSinceLastSync(uint64 poolId, bytes16 scId) external view returns (uint64) {
        QueueState storage state = _states[poolId][scId];
        if (state.lastSyncTimestamp == 0) {
            return type(uint64).max; // Never synced
        }
        return uint64(block.timestamp) - state.lastSyncTimestamp;
    }

    /// @inheritdoc IQueueManager
    function isBatchThresholdMet(uint64 poolId, bytes16 scId) external view returns (bool) {
        return _isBatchThresholdMet(poolId, scId);
    }

    /// @inheritdoc IQueueManager
    function isTimeThresholdMet(uint64 poolId, bytes16 scId) external view returns (bool) {
        return _isTimeThresholdMet(poolId, scId);
    }

    // ============================================================
    // INTERNAL
    // ============================================================

    /// @dev Check if sync should be performed
    function _shouldSync(uint64 poolId, bytes16 scId) internal view returns (bool) {
        QueueConfig storage config = _configs[poolId][scId];
        QueueState storage state = _states[poolId][scId];

        // Must have auto-sync enabled
        if (!config.autoSyncEnabled) {
            return false;
        }

        // Must have something to sync
        if (state.pendingAssets == 0 && state.pendingShares == 0) {
            return false;
        }

        // Check batch threshold OR time threshold
        return _isBatchThresholdMet(poolId, scId) || _isTimeThresholdMet(poolId, scId);
    }

    /// @dev Check if batch size threshold is met
    function _isBatchThresholdMet(uint64 poolId, bytes16 scId) internal view returns (bool) {
        QueueConfig storage config = _configs[poolId][scId];
        QueueState storage state = _states[poolId][scId];

        // Either deposits or redeems exceed threshold
        return state.pendingAssets >= config.minBatchSize || state.pendingShares >= config.minBatchSize;
    }

    /// @dev Check if time threshold is met
    function _isTimeThresholdMet(uint64 poolId, bytes16 scId) internal view returns (bool) {
        QueueConfig storage config = _configs[poolId][scId];
        QueueState storage state = _states[poolId][scId];

        // No max delay configured means time threshold is never met
        if (config.maxDelay == 0) {
            return false;
        }

        // Never synced - check if we have pending items and maxDelay has passed since queue started
        if (state.lastSyncTimestamp == 0) {
            return (state.pendingAssets > 0 || state.pendingShares > 0);
        }

        // Check if max delay has elapsed
        return uint64(block.timestamp) >= state.lastSyncTimestamp + config.maxDelay;
    }

    /// @dev Perform the actual sync
    function _performSync(uint64 poolId, bytes16 scId) internal {
        QueueState storage state = _states[poolId][scId];

        uint128 assets = state.pendingAssets;
        uint128 shares = state.pendingShares;

        // Reset pending amounts
        state.pendingAssets = 0;
        state.pendingShares = 0;
        state.lastSyncTimestamp = uint64(block.timestamp);
        state.lastSyncEpoch++;

        emit Synced(poolId, scId, assets, shares, uint64(block.timestamp));

        // Note: Actual message sending is handled by RiyzoSpoke
        // This contract just tracks queue state and determines when to sync
    }
}
