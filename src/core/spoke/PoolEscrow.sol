// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.28;

import {Auth} from "src/core/Auth.sol";
import {IPoolEscrow} from "src/interfaces/spoke/IPoolEscrow.sol";
import {SafeTransferLib} from "src/core/libraries/SafeTransferLib.sol";

/// @title PoolEscrow - Per-Pool Asset Custody Accounting
/// @author Riyzo Protocol
/// @notice Tracks deposited assets per pool/share class on spoke chains.
///         Maintains accounting separation while assets are held in global Escrow.
/// @dev PoolEscrow handles accounting only - actual token custody is in the global Escrow.
///      This separation allows:
///      - Per-pool balance tracking without individual escrow contracts
///      - Cross-pool isolation (Pool A cannot access Pool B's funds)
///      - Clear state for pending vs confirmed deposits/redemptions
///
/// ACCOUNTING MODEL:
/// - balance: Confirmed deposits (hub has acknowledged)
/// - pendingDeposits: Awaiting hub epoch execution
/// - pendingRedeems: Reserved for user claims after hub fulfillment
///
/// INVARIANT: escrow.balanceOf(asset) >= sum(all pool accounts for asset)
contract PoolEscrow is Auth, IPoolEscrow {
    // ============================================================
    // STATE
    // ============================================================

    /// @notice Global escrow contract that holds actual tokens
    address public immutable escrow;

    /// @notice Escrow accounting per pool/shareClass/asset
    /// @dev poolId => scId => asset => EscrowAccount
    mapping(uint64 => mapping(bytes16 => mapping(address => EscrowAccount))) internal _accounts;

    // ============================================================
    // CONSTRUCTOR
    // ============================================================

    /// @param deployer Initial ward address
    /// @param escrow_ Global escrow contract address
    constructor(address deployer, address escrow_) Auth(deployer) {
        require(escrow_ != address(0), "PoolEscrow/zero-escrow");
        escrow = escrow_;
    }

    // ============================================================
    // DEPOSIT FLOW
    // ============================================================

    /// @inheritdoc IPoolEscrow
    function recordDeposit(uint64 poolId, bytes16 scId, address asset, uint128 amount) external auth {
        if (amount == 0) revert ZeroAmount();

        EscrowAccount storage account = _accounts[poolId][scId][asset];
        account.pendingDeposits += amount;

        emit DepositRecorded(poolId, scId, asset, amount);
    }

    /// @inheritdoc IPoolEscrow
    function confirmDeposit(uint64 poolId, bytes16 scId, address asset, uint128 amount) external auth {
        if (amount == 0) revert ZeroAmount();

        EscrowAccount storage account = _accounts[poolId][scId][asset];

        if (account.pendingDeposits < amount) {
            revert InsufficientPendingDeposits(poolId, scId, asset, amount, account.pendingDeposits);
        }

        unchecked {
            account.pendingDeposits -= amount;
        }
        account.balance += amount;

        emit DepositConfirmed(poolId, scId, asset, amount);
    }

    // ============================================================
    // REDEEM FLOW
    // ============================================================

    /// @inheritdoc IPoolEscrow
    function reserveForRedeem(uint64 poolId, bytes16 scId, address asset, uint128 amount) external auth {
        if (amount == 0) revert ZeroAmount();

        EscrowAccount storage account = _accounts[poolId][scId][asset];

        if (account.balance < amount) {
            revert InsufficientBalance(poolId, scId, asset, amount, account.balance);
        }

        unchecked {
            account.balance -= amount;
        }
        account.pendingRedeems += amount;

        emit RedeemReserved(poolId, scId, asset, amount);
    }

    /// @inheritdoc IPoolEscrow
    function releaseToUser(
        uint64 poolId,
        bytes16 scId,
        address asset,
        address user,
        uint128 amount
    ) external auth {
        if (amount == 0) revert ZeroAmount();
        if (user == address(0)) revert ZeroAddress();

        EscrowAccount storage account = _accounts[poolId][scId][asset];

        if (account.pendingRedeems < amount) {
            revert InsufficientPendingRedeems(poolId, scId, asset, amount, account.pendingRedeems);
        }

        unchecked {
            account.pendingRedeems -= amount;
        }

        // Transfer from global escrow to user
        SafeTransferLib.safeTransferFrom(asset, escrow, user, amount);

        emit ReleasedToUser(poolId, scId, asset, user, amount);
    }

    // ============================================================
    // CANCELLATION FLOW
    // ============================================================

    /// @inheritdoc IPoolEscrow
    function releaseDepositReservation(
        uint64 poolId,
        bytes16 scId,
        address asset,
        uint128 amount
    ) external auth {
        if (amount == 0) revert ZeroAmount();

        EscrowAccount storage account = _accounts[poolId][scId][asset];

        if (account.pendingDeposits < amount) {
            revert InsufficientPendingDeposits(poolId, scId, asset, amount, account.pendingDeposits);
        }

        unchecked {
            account.pendingDeposits -= amount;
        }

        emit DepositReservationReleased(poolId, scId, asset, amount);
    }

    /// @inheritdoc IPoolEscrow
    function releaseRedeemReservation(
        uint64 poolId,
        bytes16 scId,
        address asset,
        uint128 amount
    ) external auth {
        if (amount == 0) revert ZeroAmount();

        EscrowAccount storage account = _accounts[poolId][scId][asset];

        if (account.pendingRedeems < amount) {
            revert InsufficientPendingRedeems(poolId, scId, asset, amount, account.pendingRedeems);
        }

        unchecked {
            account.pendingRedeems -= amount;
        }
        account.balance += amount;

        emit RedeemReservationReleased(poolId, scId, asset, amount);
    }

    // ============================================================
    // EMERGENCY
    // ============================================================

    /// @inheritdoc IPoolEscrow
    function emergencyWithdraw(
        uint64 poolId,
        bytes16 scId,
        address asset,
        address to,
        uint128 amount
    ) external auth {
        if (amount == 0) revert ZeroAmount();
        if (to == address(0)) revert ZeroAddress();

        EscrowAccount storage account = _accounts[poolId][scId][asset];
        uint128 total = account.balance + account.pendingDeposits + account.pendingRedeems;

        if (total < amount) {
            revert InsufficientBalance(poolId, scId, asset, amount, total);
        }

        // Deduct from balance first, then pendingDeposits, then pendingRedeems
        uint128 remaining = amount;

        if (account.balance >= remaining) {
            account.balance -= remaining;
            remaining = 0;
        } else {
            remaining -= account.balance;
            account.balance = 0;
        }

        if (remaining > 0) {
            if (account.pendingDeposits >= remaining) {
                account.pendingDeposits -= remaining;
                remaining = 0;
            } else {
                remaining -= account.pendingDeposits;
                account.pendingDeposits = 0;
            }
        }

        if (remaining > 0) {
            account.pendingRedeems -= remaining;
        }

        // Transfer from global escrow to recipient
        SafeTransferLib.safeTransferFrom(asset, escrow, to, amount);

        emit EmergencyWithdraw(poolId, scId, asset, to, amount);
    }

    // ============================================================
    // VIEW FUNCTIONS
    // ============================================================

    /// @inheritdoc IPoolEscrow
    function availableBalance(
        uint64 poolId,
        bytes16 scId,
        address asset
    ) external view returns (uint128) {
        return _accounts[poolId][scId][asset].balance;
    }

    /// @inheritdoc IPoolEscrow
    function pendingDepositBalance(
        uint64 poolId,
        bytes16 scId,
        address asset
    ) external view returns (uint128) {
        return _accounts[poolId][scId][asset].pendingDeposits;
    }

    /// @inheritdoc IPoolEscrow
    function pendingRedeemBalance(
        uint64 poolId,
        bytes16 scId,
        address asset
    ) external view returns (uint128) {
        return _accounts[poolId][scId][asset].pendingRedeems;
    }

    /// @inheritdoc IPoolEscrow
    function getAccount(
        uint64 poolId,
        bytes16 scId,
        address asset
    ) external view returns (EscrowAccount memory) {
        return _accounts[poolId][scId][asset];
    }

    /// @inheritdoc IPoolEscrow
    function totalAccountedBalance(
        uint64 poolId,
        bytes16 scId,
        address asset
    ) external view returns (uint128) {
        EscrowAccount storage account = _accounts[poolId][scId][asset];
        return account.balance + account.pendingDeposits + account.pendingRedeems;
    }
}
