// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.28;

/// @title IAsyncRequestManager - Request State Management Interface
/// @author Riyzo Protocol
/// @notice Interface for tracking deposit/redeem request states per user per vault.
///         Implements the async request pattern required by ERC-7540.
/// @dev AsyncRequestManager tracks the lifecycle of each request:
/// - Pending: Request submitted, awaiting hub epoch execution
/// - Claimable: Hub confirmed fulfillment, user can claim
/// - Claimed: User has claimed the result
/// - Cancelled: Request was cancelled
///
/// REQUEST LIFECYCLE:
/// 1. User calls vault.requestDeposit() -> state = Pending
/// 2. Hub executes epoch, sends FulfilledDepositRequest -> state = Claimable
/// 3. User calls vault.claimDeposit() -> state = Claimed
///
/// INVARIANTS:
/// - Each user has at most one pending deposit per vault
/// - Each user has at most one pending redeem per vault
/// - State transitions are one-way (Pending -> Claimable -> Claimed)
interface IAsyncRequestManager {
    // ============================================================
    // ENUMS
    // ============================================================

    /// @notice Possible states for a request
    enum RequestState {
        /// @notice No request exists
        None,
        /// @notice Request submitted, awaiting epoch execution
        Pending,
        /// @notice Epoch executed, user can claim result
        Claimable,
        /// @notice User has claimed the result
        Claimed,
        /// @notice Request was cancelled
        Cancelled
    }

    // ============================================================
    // STRUCTS
    // ============================================================

    /// @notice Deposit request state
    struct DepositRequest {
        /// @notice Amount of assets deposited
        uint128 assets;
        /// @notice Shares to receive (set after fulfillment)
        uint128 shares;
        /// @notice Epoch when request was submitted
        uint64 epochId;
        /// @notice Current request state
        RequestState state;
    }

    /// @notice Redeem request state
    struct RedeemRequest {
        /// @notice Number of shares submitted for redemption
        uint128 shares;
        /// @notice Assets to receive (set after fulfillment)
        uint128 assets;
        /// @notice Epoch when request was submitted
        uint64 epochId;
        /// @notice Current request state
        RequestState state;
    }

    // ============================================================
    // EVENTS
    // ============================================================

    /// @notice Emitted when a deposit request is created
    event DepositRequestCreated(address indexed vault, address indexed user, uint128 assets, uint64 epochId);

    /// @notice Emitted when a redeem request is created
    event RedeemRequestCreated(address indexed vault, address indexed user, uint128 shares, uint64 epochId);

    /// @notice Emitted when a deposit is fulfilled
    event DepositFulfilled(address indexed vault, address indexed user, uint128 shares);

    /// @notice Emitted when a redeem is fulfilled
    event RedeemFulfilled(address indexed vault, address indexed user, uint128 assets);

    /// @notice Emitted when a deposit is claimed
    event DepositClaimed(address indexed vault, address indexed user, uint128 shares);

    /// @notice Emitted when a redeem is claimed
    event RedeemClaimed(address indexed vault, address indexed user, uint128 assets);

    /// @notice Emitted when a deposit request is cancelled
    event DepositRequestCancelled(address indexed vault, address indexed user, uint128 assets);

    /// @notice Emitted when a redeem request is cancelled
    event RedeemRequestCancelled(address indexed vault, address indexed user, uint128 shares);

    // ============================================================
    // ERRORS
    // ============================================================

    /// @notice Thrown when request doesn't exist
    error RequestNotFound(address vault, address user);

    /// @notice Thrown when request is in wrong state
    error InvalidRequestState(address vault, address user, RequestState current, RequestState expected);

    /// @notice Thrown when user already has pending request
    error RequestAlreadyPending(address vault, address user);

    /// @notice Thrown when caller is not authorized
    error Unauthorized(address caller);

    /// @notice Thrown when amount is zero
    error ZeroAmount();

    // ============================================================
    // REQUEST SUBMISSION
    // ============================================================

    /// @notice Create a new deposit request
    /// @dev Called by vault when user requests deposit.
    ///
    /// @param vault Vault address
    /// @param user User making the request
    /// @param assets Amount of assets being deposited
    /// @param epochId Current epoch identifier
    function createDepositRequest(address vault, address user, uint128 assets, uint64 epochId) external;

    /// @notice Create a new redeem request
    /// @dev Called by vault when user requests redemption.
    ///
    /// @param vault Vault address
    /// @param user User making the request
    /// @param shares Number of shares to redeem
    /// @param epochId Current epoch identifier
    function createRedeemRequest(address vault, address user, uint128 shares, uint64 epochId) external;

    // ============================================================
    // REQUEST FULFILLMENT (from SpokeHandler)
    // ============================================================

    /// @notice Mark deposit as fulfilled with share amount
    /// @dev Called by SpokeHandler when FulfilledDepositRequest received.
    ///
    /// @param vault Vault address
    /// @param user User whose deposit was fulfilled
    /// @param shares Number of shares user will receive
    function fulfillDeposit(address vault, address user, uint128 shares) external;

    /// @notice Mark redeem as fulfilled with asset amount
    /// @dev Called by SpokeHandler when FulfilledRedeemRequest received.
    ///
    /// @param vault Vault address
    /// @param user User whose redeem was fulfilled
    /// @param assets Amount of assets user will receive
    function fulfillRedeem(address vault, address user, uint128 assets) external;

    // ============================================================
    // USER CLAIMS
    // ============================================================

    /// @notice Claim fulfilled deposit (receive shares)
    /// @dev Called by vault when user claims deposit result.
    ///      Returns shares amount and marks request as claimed.
    ///
    /// @param vault Vault address
    /// @param user User claiming the deposit
    /// @return shares Number of shares to transfer to user
    function claimDeposit(address vault, address user) external returns (uint128 shares);

    /// @notice Claim fulfilled redeem (receive assets)
    /// @dev Called by vault when user claims redeem result.
    ///      Returns assets amount and marks request as claimed.
    ///
    /// @param vault Vault address
    /// @param user User claiming the redemption
    /// @return assets Amount of assets to transfer to user
    function claimRedeem(address vault, address user) external returns (uint128 assets);

    // ============================================================
    // CANCELLATIONS
    // ============================================================

    /// @notice Cancel a pending deposit request
    /// @dev Called when user cancels or hub confirms cancellation.
    ///
    /// @param vault Vault address
    /// @param user User whose request to cancel
    function cancelDepositRequest(address vault, address user) external;

    /// @notice Cancel a pending redeem request
    /// @dev Called when user cancels or hub confirms cancellation.
    ///
    /// @param vault Vault address
    /// @param user User whose request to cancel
    function cancelRedeemRequest(address vault, address user) external;

    // ============================================================
    // VIEW FUNCTIONS
    // ============================================================

    /// @notice Get deposit request details
    /// @param vault Vault address
    /// @param user User address
    /// @return request The DepositRequest struct
    function getDepositRequest(address vault, address user) external view returns (DepositRequest memory request);

    /// @notice Get redeem request details
    /// @param vault Vault address
    /// @param user User address
    /// @return request The RedeemRequest struct
    function getRedeemRequest(address vault, address user) external view returns (RedeemRequest memory request);

    /// @notice Get pending deposit amount (ERC-7540 compatibility)
    /// @param vault Vault address
    /// @param user User address
    /// @return assets Pending deposit amount (0 if not pending)
    function pendingDeposit(address vault, address user) external view returns (uint256 assets);

    /// @notice Get claimable deposit shares (ERC-7540 compatibility)
    /// @param vault Vault address
    /// @param user User address
    /// @return shares Claimable share amount (0 if not claimable)
    function claimableDeposit(address vault, address user) external view returns (uint256 shares);

    /// @notice Get pending redeem shares (ERC-7540 compatibility)
    /// @param vault Vault address
    /// @param user User address
    /// @return shares Pending redeem shares (0 if not pending)
    function pendingRedeem(address vault, address user) external view returns (uint256 shares);

    /// @notice Get claimable redeem assets (ERC-7540 compatibility)
    /// @param vault Vault address
    /// @param user User address
    /// @return assets Claimable asset amount (0 if not claimable)
    function claimableRedeem(address vault, address user) external view returns (uint256 assets);

    /// @notice Check if user has any pending request for vault
    /// @param vault Vault address
    /// @param user User address
    /// @return hasPending True if user has pending deposit or redeem
    function hasPendingRequest(address vault, address user) external view returns (bool hasPending);
}
