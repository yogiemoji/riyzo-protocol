// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.28;

/// @title IQueueManager - Auto-Sync Queue Interface
/// @author Riyzo Protocol
/// @notice Interface for managing automatic cross-chain synchronization of requests.
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
interface IQueueManager {
    // ============================================================
    // STRUCTS
    // ============================================================

    /// @notice Configuration for a pool/shareClass queue
    struct QueueConfig {
        /// @notice Minimum accumulated value to trigger sync (in asset decimals)
        uint128 minBatchSize;
        /// @notice Maximum time before forced sync (seconds)
        uint64 maxDelay;
        /// @notice Gas limit for cross-chain message
        uint128 gasLimit;
        /// @notice Whether automatic sync is enabled
        bool autoSyncEnabled;
    }

    /// @notice Current state of a queue
    struct QueueState {
        /// @notice Accumulated deposit assets awaiting sync
        uint128 pendingAssets;
        /// @notice Accumulated redeem shares awaiting sync
        uint128 pendingShares;
        /// @notice Timestamp of last sync
        uint64 lastSyncTimestamp;
        /// @notice Epoch ID of last sync
        uint64 lastSyncEpoch;
    }

    // ============================================================
    // EVENTS
    // ============================================================

    /// @notice Emitted when queue config is updated
    event QueueConfigSet(
        uint64 indexed poolId,
        bytes16 indexed scId,
        uint128 minBatchSize,
        uint64 maxDelay,
        uint128 gasLimit,
        bool autoSyncEnabled
    );

    /// @notice Emitted when auto-sync is enabled
    event AutoSyncEnabled(uint64 indexed poolId, bytes16 indexed scId);

    /// @notice Emitted when auto-sync is disabled
    event AutoSyncDisabled(uint64 indexed poolId, bytes16 indexed scId);

    /// @notice Emitted when deposits are added to queue
    event DepositsQueued(uint64 indexed poolId, bytes16 indexed scId, uint128 amount, uint128 newTotal);

    /// @notice Emitted when redeems are added to queue
    event RedeemsQueued(uint64 indexed poolId, bytes16 indexed scId, uint128 shares, uint128 newTotal);

    /// @notice Emitted when a sync is performed
    event Synced(uint64 indexed poolId, bytes16 indexed scId, uint128 assets, uint128 shares, uint64 timestamp);

    /// @notice Emitted when force sync is triggered by admin
    event ForceSynced(uint64 indexed poolId, bytes16 indexed scId, address indexed triggeredBy);

    // ============================================================
    // ERRORS
    // ============================================================

    /// @notice Thrown when queue doesn't exist
    error QueueNotFound(uint64 poolId, bytes16 scId);

    /// @notice Thrown when auto-sync is disabled for queue
    error AutoSyncNotEnabled(uint64 poolId, bytes16 scId);

    /// @notice Thrown when sync conditions not met
    error SyncConditionsNotMet(uint64 poolId, bytes16 scId);

    /// @notice Thrown when caller is not authorized
    error Unauthorized(address caller);

    /// @notice Thrown when config values are invalid
    error InvalidConfig(string reason);

    // ============================================================
    // CONFIGURATION
    // ============================================================

    /// @notice Set queue configuration for a pool/shareClass
    /// @dev Only callable by admin.
    ///
    /// @param poolId Pool identifier
    /// @param scId Share class identifier
    /// @param config New configuration
    function setQueueConfig(uint64 poolId, bytes16 scId, QueueConfig calldata config) external;

    /// @notice Enable automatic sync for a queue
    /// @param poolId Pool identifier
    /// @param scId Share class identifier
    function enableAutoSync(uint64 poolId, bytes16 scId) external;

    /// @notice Disable automatic sync for a queue
    /// @param poolId Pool identifier
    /// @param scId Share class identifier
    function disableAutoSync(uint64 poolId, bytes16 scId) external;

    // ============================================================
    // QUEUE ACCUMULATION
    // ============================================================

    /// @notice Add deposit amount to pending queue
    /// @dev Called by RiyzoSpoke when deposit request is received.
    ///
    /// @param poolId Pool identifier
    /// @param scId Share class identifier
    /// @param amount Asset amount to add
    function addToPendingDeposits(uint64 poolId, bytes16 scId, uint128 amount) external;

    /// @notice Add redeem shares to pending queue
    /// @dev Called by RiyzoSpoke when redeem request is received.
    ///
    /// @param poolId Pool identifier
    /// @param scId Share class identifier
    /// @param shares Share amount to add
    function addToPendingRedeems(uint64 poolId, bytes16 scId, uint128 shares) external;

    // ============================================================
    // SYNC TRIGGERS
    // ============================================================

    /// @notice Check and sync if conditions are met
    /// @dev Automatically called or triggered by keeper.
    ///      Syncs if batch size OR time threshold exceeded.
    ///
    /// @param poolId Pool identifier
    /// @param scId Share class identifier
    /// @return synced True if sync was performed
    function checkAndSync(uint64 poolId, bytes16 scId) external returns (bool synced);

    /// @notice Force immediate sync regardless of conditions
    /// @dev Only callable by admin. Useful for urgent situations.
    ///
    /// @param poolId Pool identifier
    /// @param scId Share class identifier
    function forceSync(uint64 poolId, bytes16 scId) external;

    // ============================================================
    // KEEPER INTERFACE
    // ============================================================

    /// @notice Check if sync should be performed (keeper-compatible)
    /// @dev Returns true if any sync condition is met.
    ///
    /// @param poolId Pool identifier
    /// @param scId Share class identifier
    /// @return should True if sync should be performed
    function shouldSync(uint64 poolId, bytes16 scId) external view returns (bool should);

    /// @notice Perform sync (keeper-compatible)
    /// @dev Reverts if sync conditions not met.
    ///
    /// @param poolId Pool identifier
    /// @param scId Share class identifier
    function performSync(uint64 poolId, bytes16 scId) external;

    /// @notice Check multiple queues for sync needs
    /// @dev Batch check for keepers monitoring multiple queues.
    ///
    /// @param poolIds Array of pool identifiers
    /// @param scIds Array of share class identifiers
    /// @return results Array of booleans indicating sync needs
    function shouldSyncBatch(uint64[] calldata poolIds, bytes16[] calldata scIds)
        external
        view
        returns (bool[] memory results);

    // ============================================================
    // VIEW FUNCTIONS
    // ============================================================

    /// @notice Get queue configuration
    /// @param poolId Pool identifier
    /// @param scId Share class identifier
    /// @return config The QueueConfig struct
    function getQueueConfig(uint64 poolId, bytes16 scId) external view returns (QueueConfig memory config);

    /// @notice Get current queue state
    /// @param poolId Pool identifier
    /// @param scId Share class identifier
    /// @return state The QueueState struct
    function getQueueState(uint64 poolId, bytes16 scId) external view returns (QueueState memory state);

    /// @notice Get time since last sync
    /// @param poolId Pool identifier
    /// @param scId Share class identifier
    /// @return elapsed Seconds since last sync
    function timeSinceLastSync(uint64 poolId, bytes16 scId) external view returns (uint64 elapsed);

    /// @notice Check if batch size threshold is met
    /// @param poolId Pool identifier
    /// @param scId Share class identifier
    /// @return met True if pending >= minBatchSize
    function isBatchThresholdMet(uint64 poolId, bytes16 scId) external view returns (bool met);

    /// @notice Check if time threshold is met
    /// @param poolId Pool identifier
    /// @param scId Share class identifier
    /// @return met True if elapsed >= maxDelay
    function isTimeThresholdMet(uint64 poolId, bytes16 scId) external view returns (bool met);
}
