// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.28;

/// @title IBalanceSheet - Share Issuance/Revocation Interface
/// @author Riyzo Protocol
/// @notice Interface for managing share token issuance and revocation on spoke chains.
///         This contract is the only authorized minter/burner of ShareTokens.
/// @dev BalanceSheet handles the actual minting and burning of share tokens based on
///      confirmations from the hub chain. It maintains queues for batch processing.
///
/// KEY RESPONSIBILITIES:
/// - Issue shares when hub confirms deposit fulfillment
/// - Revoke shares when hub confirms redeem fulfillment
/// - Queue operations for gas-efficient batch processing
/// - Track nonces for hub synchronization
///
/// FLOW:
/// 1. Hub executes epoch, sends FulfilledDepositRequest to spoke
/// 2. SpokeHandler calls BalanceSheet.issueShares()
/// 3. BalanceSheet mints shares to user (or queues for batch)
/// 4. User can claim shares via vault
interface IBalanceSheet {
    // ============================================================
    // STRUCTS
    // ============================================================

    /// @notice Pending share issuance queued for batch processing
    struct PendingIssuance {
        /// @notice User to receive shares
        address user;
        /// @notice Number of shares to mint
        uint128 shares;
        /// @notice Epoch when deposit was fulfilled
        uint64 epochId;
    }

    /// @notice Pending share revocation queued for batch processing
    struct PendingRevocation {
        /// @notice User whose shares are being burned
        address user;
        /// @notice Number of shares to burn
        uint128 shares;
        /// @notice Epoch when redeem was fulfilled
        uint64 epochId;
    }

    // ============================================================
    // EVENTS
    // ============================================================

    /// @notice Emitted when shares are issued to a user
    event SharesIssued(
        uint64 indexed poolId,
        bytes16 indexed scId,
        address indexed user,
        uint128 shares,
        uint64 epochId
    );

    /// @notice Emitted when shares are revoked from a user
    event SharesRevoked(
        uint64 indexed poolId,
        bytes16 indexed scId,
        address indexed user,
        uint128 shares,
        uint64 epochId
    );

    /// @notice Emitted when issuance is queued for batch processing
    event IssuanceQueued(
        uint64 indexed poolId,
        bytes16 indexed scId,
        address indexed user,
        uint128 shares,
        uint64 epochId
    );

    /// @notice Emitted when revocation is queued for batch processing
    event RevocationQueued(
        uint64 indexed poolId,
        bytes16 indexed scId,
        address indexed user,
        uint128 shares,
        uint64 epochId
    );

    /// @notice Emitted when a batch of issuances is processed
    event BatchIssued(uint64 indexed poolId, bytes16 indexed scId, uint256 count, uint128 totalShares);

    /// @notice Emitted when a batch of revocations is processed
    event BatchRevoked(uint64 indexed poolId, bytes16 indexed scId, uint256 count, uint128 totalShares);

    // ============================================================
    // ERRORS
    // ============================================================

    /// @notice Thrown when share token doesn't exist for share class
    error ShareTokenNotFound(uint64 poolId, bytes16 scId);

    /// @notice Thrown when trying to issue zero shares
    error ZeroShares();

    /// @notice Thrown when caller is not authorized
    error Unauthorized(address caller);

    /// @notice Thrown when queue is empty
    error QueueEmpty(uint64 poolId, bytes16 scId);

    /// @notice Thrown when array lengths don't match
    error ArrayLengthMismatch(uint256 usersLength, uint256 sharesLength);

    // ============================================================
    // CONFIGURATION
    // ============================================================

    /// @notice Register a share token for a pool/shareClass
    /// @dev Must be called before any issuance/revocation operations.
    /// @param poolId Pool identifier
    /// @param scId Share class identifier
    /// @param shareToken Address of the ShareToken contract
    function setShareToken(uint64 poolId, bytes16 scId, address shareToken) external;

    // ============================================================
    // SHARE ISSUANCE (from hub confirmations)
    // ============================================================

    /// @notice Issue shares to a user after deposit fulfillment
    /// @dev Called by SpokeHandler when FulfilledDepositRequest message received.
    ///      Mints shares directly to user.
    ///
    /// @param poolId Pool identifier
    /// @param scId Share class identifier
    /// @param user User to receive shares
    /// @param shares Number of shares to mint
    function issueShares(uint64 poolId, bytes16 scId, address user, uint128 shares) external;

    /// @notice Revoke shares from a user after redeem fulfillment
    /// @dev Called by SpokeHandler when FulfilledRedeemRequest message received.
    ///      Burns shares that were previously locked.
    ///
    /// @param poolId Pool identifier
    /// @param scId Share class identifier
    /// @param user User whose shares to burn
    /// @param shares Number of shares to burn
    function revokeShares(uint64 poolId, bytes16 scId, address user, uint128 shares) external;

    // ============================================================
    // BATCH OPERATIONS (gas efficiency)
    // ============================================================

    /// @notice Issue shares to multiple users in a single transaction
    /// @dev Used for gas-efficient bulk processing.
    ///
    /// @param poolId Pool identifier
    /// @param scId Share class identifier
    /// @param users Array of users to receive shares
    /// @param shares Array of share amounts (must match users length)
    function batchIssue(
        uint64 poolId,
        bytes16 scId,
        address[] calldata users,
        uint128[] calldata shares
    ) external;

    /// @notice Revoke shares from multiple users in a single transaction
    /// @dev Used for gas-efficient bulk processing.
    ///
    /// @param poolId Pool identifier
    /// @param scId Share class identifier
    /// @param users Array of users whose shares to burn
    /// @param shares Array of share amounts (must match users length)
    function batchRevoke(
        uint64 poolId,
        bytes16 scId,
        address[] calldata users,
        uint128[] calldata shares
    ) external;

    // ============================================================
    // QUEUE MANAGEMENT
    // ============================================================

    /// @notice Queue an issuance for later batch processing
    /// @dev Used when immediate processing is not needed.
    ///
    /// @param poolId Pool identifier
    /// @param scId Share class identifier
    /// @param user User to receive shares
    /// @param shares Number of shares to mint
    /// @param epochId Epoch when fulfilled
    function queueIssuance(
        uint64 poolId,
        bytes16 scId,
        address user,
        uint128 shares,
        uint64 epochId
    ) external;

    /// @notice Queue a revocation for later batch processing
    /// @dev Used when immediate processing is not needed.
    ///
    /// @param poolId Pool identifier
    /// @param scId Share class identifier
    /// @param user User whose shares to burn
    /// @param shares Number of shares to burn
    /// @param epochId Epoch when fulfilled
    function queueRevocation(
        uint64 poolId,
        bytes16 scId,
        address user,
        uint128 shares,
        uint64 epochId
    ) external;

    /// @notice Process queued issuances
    /// @dev Processes up to maxOperations from the issuance queue.
    ///
    /// @param poolId Pool identifier
    /// @param scId Share class identifier
    /// @param maxOperations Maximum number of operations to process
    /// @return processed Number of operations actually processed
    function processIssuanceQueue(
        uint64 poolId,
        bytes16 scId,
        uint256 maxOperations
    ) external returns (uint256 processed);

    /// @notice Process queued revocations
    /// @dev Processes up to maxOperations from the revocation queue.
    ///
    /// @param poolId Pool identifier
    /// @param scId Share class identifier
    /// @param maxOperations Maximum number of operations to process
    /// @return processed Number of operations actually processed
    function processRevocationQueue(
        uint64 poolId,
        bytes16 scId,
        uint256 maxOperations
    ) external returns (uint256 processed);

    // ============================================================
    // VIEW FUNCTIONS
    // ============================================================

    /// @notice Get count of pending issuances in queue
    /// @param poolId Pool identifier
    /// @param scId Share class identifier
    /// @return count Number of pending issuances
    function pendingIssuanceCount(uint64 poolId, bytes16 scId) external view returns (uint256 count);

    /// @notice Get count of pending revocations in queue
    /// @param poolId Pool identifier
    /// @param scId Share class identifier
    /// @return count Number of pending revocations
    function pendingRevocationCount(uint64 poolId, bytes16 scId) external view returns (uint256 count);

    /// @notice Get issuance nonce for hub synchronization
    /// @param poolId Pool identifier
    /// @param scId Share class identifier
    /// @return nonce Current issuance nonce
    function issuanceNonce(uint64 poolId, bytes16 scId) external view returns (uint64 nonce);

    /// @notice Get revocation nonce for hub synchronization
    /// @param poolId Pool identifier
    /// @param scId Share class identifier
    /// @return nonce Current revocation nonce
    function revocationNonce(uint64 poolId, bytes16 scId) external view returns (uint64 nonce);

    /// @notice Get the share token address for a share class
    /// @param poolId Pool identifier
    /// @param scId Share class identifier
    /// @return shareToken Address of the ShareToken contract
    function getShareToken(uint64 poolId, bytes16 scId) external view returns (address shareToken);
}
