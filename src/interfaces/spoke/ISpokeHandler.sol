// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.28;

/// @title ISpokeHandler - Incoming Message Handler Interface
/// @author Riyzo Protocol
/// @notice Interface for processing incoming messages from the hub chain.
///         Routes messages to appropriate spoke components based on message type.
/// @dev SpokeHandler is the spoke-side counterpart to HubHandler.
///      It receives messages from Gateway and dispatches to:
///      - RiyzoSpoke (pool/tranche registration)
///      - BalanceSheet (share issuance/revocation)
///      - PoolEscrow (asset movements)
///      - AsyncRequestManager (request state updates)
///
/// MESSAGE TYPES HANDLED:
/// | Type | ID | Action |
/// |------|-----|--------|
/// | AddPool | 10 | Register pool on spoke |
/// | AddTranche | 11 | Register share class, deploy token |
/// | UpdateTranchePrice | 14 | Update share class price |
/// | UpdateRestriction | 19 | Update transfer restrictions |
/// | FulfilledDepositRequest | 22 | Issue shares to user |
/// | FulfilledRedeemRequest | 23 | Release assets to user |
/// | FulfilledCancelDepositRequest | 26 | Return deposit to user |
/// | FulfilledCancelRedeemRequest | 27 | Return shares to user |
interface ISpokeHandler {
    // ============================================================
    // EVENTS
    // ============================================================

    /// @notice Emitted when a message is handled
    event MessageHandled(bytes32 indexed messageHash, uint8 indexed messageType, bool success);

    /// @notice Emitted when AddPool is processed
    event PoolAdded(uint64 indexed poolId, address currency);

    /// @notice Emitted when AddTranche is processed
    event TrancheAdded(uint64 indexed poolId, bytes16 indexed scId, address shareToken);

    /// @notice Emitted when UpdateTranchePrice is processed
    event PriceUpdated(uint64 indexed poolId, bytes16 indexed scId, uint128 price);

    /// @notice Emitted when FulfilledDepositRequest is processed
    event DepositFulfilled(
        uint64 indexed poolId, bytes16 indexed scId, address indexed user, uint128 assetAmount, uint128 shareAmount
    );

    /// @notice Emitted when FulfilledRedeemRequest is processed
    event RedeemFulfilled(
        uint64 indexed poolId, bytes16 indexed scId, address indexed user, uint128 shareAmount, uint128 assetAmount
    );

    /// @notice Emitted when FulfilledCancelDepositRequest is processed
    event CancelDepositFulfilled(uint64 indexed poolId, bytes16 indexed scId, address indexed user, uint128 amount);

    /// @notice Emitted when FulfilledCancelRedeemRequest is processed
    event CancelRedeemFulfilled(uint64 indexed poolId, bytes16 indexed scId, address indexed user, uint128 shares);

    /// @notice Emitted when UpdateRestriction is processed
    event RestrictionUpdated(uint64 indexed poolId, bytes16 indexed scId, address indexed shareToken);

    // ============================================================
    // ERRORS
    // ============================================================

    /// @notice Thrown when message type is unknown
    error UnknownMessageType(uint8 messageType);

    /// @notice Thrown when message is malformed
    error MalformedMessage(bytes message);

    /// @notice Thrown when caller is not Gateway
    error NotGateway(address caller);

    /// @notice Thrown when pool doesn't exist (for non-AddPool messages)
    error PoolNotFound(uint64 poolId);

    /// @notice Thrown when share class doesn't exist
    error ShareClassNotFound(uint64 poolId, bytes16 scId);

    /// @notice Thrown when message processing fails
    error MessageProcessingFailed(uint8 messageType, bytes reason);

    // ============================================================
    // MESSAGE HANDLING
    // ============================================================

    /// @notice Handle an incoming message from hub
    /// @dev Called by Gateway after message is validated by adapter quorum.
    ///      Routes to appropriate internal handler based on message type.
    ///
    /// @param message Encoded message data (first byte is message type)
    function handle(bytes calldata message) external;

    // ============================================================
    // VIEW FUNCTIONS
    // ============================================================

    /// @notice Get the Gateway contract address
    /// @return gateway Gateway address
    function gateway() external view returns (address gateway);

    /// @notice Get the RiyzoSpoke contract address
    /// @return spoke RiyzoSpoke address
    function spoke() external view returns (address spoke);

    /// @notice Get the BalanceSheet contract address
    /// @return balanceSheet BalanceSheet address
    function balanceSheet() external view returns (address balanceSheet);

    /// @notice Get the PoolEscrow contract address
    /// @return poolEscrow PoolEscrow address
    function poolEscrow() external view returns (address poolEscrow);

    /// @notice Get the AsyncRequestManager contract address
    /// @return requestManager AsyncRequestManager address
    function asyncRequestManager() external view returns (address requestManager);

    /// @notice Get the SpokeInvestmentManager contract address
    /// @return investmentManager SpokeInvestmentManager address
    function spokeInvestmentManager() external view returns (address investmentManager);

    /// @notice Get the RestrictionManager contract address
    /// @return manager RestrictionManager address
    function restrictionManager() external view returns (address manager);

    /// @notice Check if a message type is supported
    /// @param messageType Message type ID
    /// @return supported True if message type is handled
    function supportsMessageType(uint8 messageType) external view returns (bool supported);
}
