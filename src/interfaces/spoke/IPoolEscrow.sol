// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.28;

/// @title IPoolEscrow - Asset Custody Interface
/// @author Riyzo Protocol
/// @notice Interface for tracking deposited assets per pool/share class on spoke chains.
///         Maintains accounting separation between pools while assets are held in global Escrow.
/// @dev PoolEscrow tracks:
/// - Confirmed deposits (assets available for investment)
/// - Pending deposits (awaiting hub confirmation)
/// - Reserved for redemptions (awaiting user claim)
///
/// CUSTODY MODEL:
/// - Global Escrow contract holds all ERC20 tokens
/// - PoolEscrow maintains per-pool/per-asset accounting
/// - Prevents cross-pool asset mixing
///
/// INVARIANTS:
/// - globalEscrow.balance >= sum(all pool balances)
/// - balance + pendingDeposits + pendingRedeems = total accounted for this pool
interface IPoolEscrow {
    // ============================================================
    // STRUCTS
    // ============================================================

    /// @notice Escrow account state for a pool/shareClass/asset combination
    struct EscrowAccount {
        /// @notice Confirmed balance (deposits confirmed by hub)
        uint128 balance;
        /// @notice Pending deposits (awaiting hub confirmation)
        uint128 pendingDeposits;
        /// @notice Reserved for pending redemptions (awaiting user claim)
        uint128 pendingRedeems;
    }

    // ============================================================
    // EVENTS
    // ============================================================

    /// @notice Emitted when a deposit is recorded (pending confirmation)
    event DepositRecorded(
        uint64 indexed poolId,
        bytes16 indexed scId,
        address indexed asset,
        uint128 amount
    );

    /// @notice Emitted when a deposit is confirmed by hub
    event DepositConfirmed(
        uint64 indexed poolId,
        bytes16 indexed scId,
        address indexed asset,
        uint128 amount
    );

    /// @notice Emitted when assets are reserved for redemption
    event RedeemReserved(
        uint64 indexed poolId,
        bytes16 indexed scId,
        address indexed asset,
        uint128 amount
    );

    /// @notice Emitted when assets are released to user
    event ReleasedToUser(
        uint64 indexed poolId,
        bytes16 indexed scId,
        address indexed asset,
        address user,
        uint128 amount
    );

    /// @notice Emitted when deposit reservation is released (cancelled)
    event DepositReservationReleased(
        uint64 indexed poolId,
        bytes16 indexed scId,
        address indexed asset,
        uint128 amount
    );

    /// @notice Emitted when redeem reservation is released (cancelled)
    event RedeemReservationReleased(
        uint64 indexed poolId,
        bytes16 indexed scId,
        address indexed asset,
        uint128 amount
    );

    /// @notice Emitted on emergency withdrawal
    event EmergencyWithdraw(
        uint64 indexed poolId,
        bytes16 indexed scId,
        address indexed asset,
        address to,
        uint128 amount
    );

    // ============================================================
    // ERRORS
    // ============================================================

    /// @notice Thrown when insufficient balance for operation
    error InsufficientBalance(uint64 poolId, bytes16 scId, address asset, uint128 required, uint128 available);

    /// @notice Thrown when insufficient pending deposits
    error InsufficientPendingDeposits(uint64 poolId, bytes16 scId, address asset, uint128 required, uint128 available);

    /// @notice Thrown when insufficient pending redeems
    error InsufficientPendingRedeems(uint64 poolId, bytes16 scId, address asset, uint128 required, uint128 available);

    /// @notice Thrown when caller is not authorized
    error Unauthorized(address caller);

    /// @notice Thrown when amount is zero
    error ZeroAmount();

    /// @notice Thrown when recipient is zero address
    error ZeroAddress();

    // ============================================================
    // DEPOSIT FLOW
    // ============================================================

    /// @notice Record a new deposit (pending hub confirmation)
    /// @dev Called when user deposits assets into vault.
    ///      Assets are transferred to global Escrow, tracked here as pending.
    ///
    /// @param poolId Pool identifier
    /// @param scId Share class identifier
    /// @param asset Asset address
    /// @param amount Amount deposited
    function recordDeposit(uint64 poolId, bytes16 scId, address asset, uint128 amount) external;

    /// @notice Confirm a deposit after hub fulfillment
    /// @dev Called when FulfilledDepositRequest received from hub.
    ///      Moves amount from pendingDeposits to balance.
    ///
    /// @param poolId Pool identifier
    /// @param scId Share class identifier
    /// @param asset Asset address
    /// @param amount Amount confirmed
    function confirmDeposit(uint64 poolId, bytes16 scId, address asset, uint128 amount) external;

    // ============================================================
    // REDEEM FLOW
    // ============================================================

    /// @notice Reserve assets for redemption
    /// @dev Called when hub confirms redeem, before user claims.
    ///      Moves amount from balance to pendingRedeems.
    ///
    /// @param poolId Pool identifier
    /// @param scId Share class identifier
    /// @param asset Asset address
    /// @param amount Amount to reserve
    function reserveForRedeem(uint64 poolId, bytes16 scId, address asset, uint128 amount) external;

    /// @notice Release reserved assets to user
    /// @dev Called when user claims their redemption.
    ///      Decreases pendingRedeems, transfers from global Escrow to user.
    ///
    /// @param poolId Pool identifier
    /// @param scId Share class identifier
    /// @param asset Asset address
    /// @param user Recipient address
    /// @param amount Amount to release
    function releaseToUser(
        uint64 poolId,
        bytes16 scId,
        address asset,
        address user,
        uint128 amount
    ) external;

    // ============================================================
    // CANCELLATION FLOW
    // ============================================================

    /// @notice Release deposit reservation (on cancel)
    /// @dev Called when deposit is cancelled before hub confirmation.
    ///      Decreases pendingDeposits, returns to user.
    ///
    /// @param poolId Pool identifier
    /// @param scId Share class identifier
    /// @param asset Asset address
    /// @param amount Amount to release
    function releaseDepositReservation(
        uint64 poolId,
        bytes16 scId,
        address asset,
        uint128 amount
    ) external;

    /// @notice Release redeem reservation (on cancel)
    /// @dev Called when redeem is cancelled.
    ///      Decreases pendingRedeems, moves back to balance.
    ///
    /// @param poolId Pool identifier
    /// @param scId Share class identifier
    /// @param asset Asset address
    /// @param amount Amount to release
    function releaseRedeemReservation(
        uint64 poolId,
        bytes16 scId,
        address asset,
        uint128 amount
    ) external;

    // ============================================================
    // EMERGENCY
    // ============================================================

    /// @notice Emergency withdrawal by admin
    /// @dev Only callable by root/admin in emergency situations.
    ///
    /// @param poolId Pool identifier
    /// @param scId Share class identifier
    /// @param asset Asset address
    /// @param to Recipient address
    /// @param amount Amount to withdraw
    function emergencyWithdraw(
        uint64 poolId,
        bytes16 scId,
        address asset,
        address to,
        uint128 amount
    ) external;

    // ============================================================
    // VIEW FUNCTIONS
    // ============================================================

    /// @notice Get available balance (confirmed, not reserved)
    /// @param poolId Pool identifier
    /// @param scId Share class identifier
    /// @param asset Asset address
    /// @return balance Available balance
    function availableBalance(
        uint64 poolId,
        bytes16 scId,
        address asset
    ) external view returns (uint128 balance);

    /// @notice Get pending deposit balance
    /// @param poolId Pool identifier
    /// @param scId Share class identifier
    /// @param asset Asset address
    /// @return balance Pending deposit balance
    function pendingDepositBalance(
        uint64 poolId,
        bytes16 scId,
        address asset
    ) external view returns (uint128 balance);

    /// @notice Get pending redeem balance
    /// @param poolId Pool identifier
    /// @param scId Share class identifier
    /// @param asset Asset address
    /// @return balance Pending redeem balance
    function pendingRedeemBalance(
        uint64 poolId,
        bytes16 scId,
        address asset
    ) external view returns (uint128 balance);

    /// @notice Get full escrow account state
    /// @param poolId Pool identifier
    /// @param scId Share class identifier
    /// @param asset Asset address
    /// @return account The EscrowAccount struct
    function getAccount(
        uint64 poolId,
        bytes16 scId,
        address asset
    ) external view returns (EscrowAccount memory account);

    /// @notice Get total accounted balance (balance + pending)
    /// @param poolId Pool identifier
    /// @param scId Share class identifier
    /// @param asset Asset address
    /// @return total Total accounted balance
    function totalAccountedBalance(
        uint64 poolId,
        bytes16 scId,
        address asset
    ) external view returns (uint128 total);

    /// @notice Get the global escrow contract address
    /// @return escrow Global Escrow address
    function escrow() external view returns (address escrow);
}
