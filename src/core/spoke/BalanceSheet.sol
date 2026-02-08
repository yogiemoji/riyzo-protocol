// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.28;

import {Auth} from "src/core/Auth.sol";
import {IBalanceSheet} from "src/interfaces/spoke/IBalanceSheet.sol";
import {ITranche} from "src/interfaces/token/ITranche.sol";

/// @title BalanceSheet - Share Token Issuance/Revocation
/// @author Riyzo Protocol
/// @notice Manages share token minting and burning based on hub chain confirmations.
///         This contract is the authorized minter/burner for all ShareTokens on the spoke.
/// @dev BalanceSheet serves as the single source of truth for share issuance.
///      When the hub confirms a deposit fulfillment, SpokeHandler calls issueShares().
///      When the hub confirms a redeem fulfillment, SpokeHandler calls revokeShares().
///
/// BATCH PROCESSING:
/// - Operations can be queued for gas-efficient batch processing
/// - Useful when many users need shares issued in same epoch
/// - Queue is processed FIFO
///
/// REQUIREMENTS:
/// - Must be a ward (admin) on each ShareToken to mint/burn
/// - Share tokens must be registered via setShareToken()
contract BalanceSheet is Auth, IBalanceSheet {
    // ============================================================
    // STATE
    // ============================================================

    /// @notice Share token address per pool/shareClass
    /// @dev poolId => scId => shareToken
    mapping(uint64 => mapping(bytes16 => address)) internal _shareTokens;

    /// @notice Pending issuances queue per pool/shareClass
    /// @dev poolId => scId => queue
    mapping(uint64 => mapping(bytes16 => PendingIssuance[])) internal _issuanceQueue;

    /// @notice Pending revocations queue per pool/shareClass
    /// @dev poolId => scId => queue
    mapping(uint64 => mapping(bytes16 => PendingRevocation[])) internal _revocationQueue;

    /// @notice Issuance nonce for hub synchronization
    /// @dev poolId => scId => nonce
    mapping(uint64 => mapping(bytes16 => uint64)) internal _issuanceNonces;

    /// @notice Revocation nonce for hub synchronization
    /// @dev poolId => scId => nonce
    mapping(uint64 => mapping(bytes16 => uint64)) internal _revocationNonces;

    // ============================================================
    // CONSTRUCTOR
    // ============================================================

    /// @param deployer Initial ward address
    constructor(address deployer) Auth(deployer) {}

    // ============================================================
    // CONFIGURATION
    // ============================================================

    /// @notice Register a share token for a pool/shareClass
    /// @dev Must be called before any issuance/revocation operations.
    /// @param poolId Pool identifier
    /// @param scId Share class identifier
    /// @param shareToken Address of the ShareToken contract
    function setShareToken(uint64 poolId, bytes16 scId, address shareToken) external auth {
        require(shareToken != address(0), "BalanceSheet/zero-address");
        _shareTokens[poolId][scId] = shareToken;
    }

    // ============================================================
    // SHARE ISSUANCE
    // ============================================================

    /// @inheritdoc IBalanceSheet
    function issueShares(uint64 poolId, bytes16 scId, address user, uint128 shares) external auth {
        if (shares == 0) revert ZeroShares();

        address shareToken = _shareTokens[poolId][scId];
        if (shareToken == address(0)) revert ShareTokenNotFound(poolId, scId);

        ITranche(shareToken).mint(user, shares);
        _issuanceNonces[poolId][scId]++;

        emit SharesIssued(poolId, scId, user, shares, 0);
    }

    /// @inheritdoc IBalanceSheet
    function revokeShares(uint64 poolId, bytes16 scId, address user, uint128 shares) external auth {
        if (shares == 0) revert ZeroShares();

        address shareToken = _shareTokens[poolId][scId];
        if (shareToken == address(0)) revert ShareTokenNotFound(poolId, scId);

        ITranche(shareToken).burn(user, shares);
        _revocationNonces[poolId][scId]++;

        emit SharesRevoked(poolId, scId, user, shares, 0);
    }

    // ============================================================
    // BATCH OPERATIONS
    // ============================================================

    /// @inheritdoc IBalanceSheet
    function batchIssue(
        uint64 poolId,
        bytes16 scId,
        address[] calldata users,
        uint128[] calldata shares
    ) external auth {
        if (users.length != shares.length) {
            revert ArrayLengthMismatch(users.length, shares.length);
        }

        address shareToken = _shareTokens[poolId][scId];
        if (shareToken == address(0)) revert ShareTokenNotFound(poolId, scId);

        uint128 totalShares = 0;
        for (uint256 i = 0; i < users.length; i++) {
            if (shares[i] == 0) continue;
            ITranche(shareToken).mint(users[i], shares[i]);
            totalShares += shares[i];
        }

        _issuanceNonces[poolId][scId] += uint64(users.length);
        emit BatchIssued(poolId, scId, users.length, totalShares);
    }

    /// @inheritdoc IBalanceSheet
    function batchRevoke(
        uint64 poolId,
        bytes16 scId,
        address[] calldata users,
        uint128[] calldata shares
    ) external auth {
        if (users.length != shares.length) {
            revert ArrayLengthMismatch(users.length, shares.length);
        }

        address shareToken = _shareTokens[poolId][scId];
        if (shareToken == address(0)) revert ShareTokenNotFound(poolId, scId);

        uint128 totalShares = 0;
        for (uint256 i = 0; i < users.length; i++) {
            if (shares[i] == 0) continue;
            ITranche(shareToken).burn(users[i], shares[i]);
            totalShares += shares[i];
        }

        _revocationNonces[poolId][scId] += uint64(users.length);
        emit BatchRevoked(poolId, scId, users.length, totalShares);
    }

    // ============================================================
    // QUEUE MANAGEMENT
    // ============================================================

    /// @inheritdoc IBalanceSheet
    function queueIssuance(
        uint64 poolId,
        bytes16 scId,
        address user,
        uint128 shares,
        uint64 epochId
    ) external auth {
        if (shares == 0) revert ZeroShares();

        _issuanceQueue[poolId][scId].push(PendingIssuance({user: user, shares: shares, epochId: epochId}));

        emit IssuanceQueued(poolId, scId, user, shares, epochId);
    }

    /// @inheritdoc IBalanceSheet
    function queueRevocation(
        uint64 poolId,
        bytes16 scId,
        address user,
        uint128 shares,
        uint64 epochId
    ) external auth {
        if (shares == 0) revert ZeroShares();

        _revocationQueue[poolId][scId].push(PendingRevocation({user: user, shares: shares, epochId: epochId}));

        emit RevocationQueued(poolId, scId, user, shares, epochId);
    }

    /// @inheritdoc IBalanceSheet
    function processIssuanceQueue(
        uint64 poolId,
        bytes16 scId,
        uint256 maxOperations
    ) external returns (uint256 processed) {
        PendingIssuance[] storage queue = _issuanceQueue[poolId][scId];
        uint256 queueLength = queue.length;
        if (queueLength == 0) revert QueueEmpty(poolId, scId);

        address shareToken = _shareTokens[poolId][scId];
        if (shareToken == address(0)) revert ShareTokenNotFound(poolId, scId);

        uint256 toProcess = maxOperations < queueLength ? maxOperations : queueLength;
        uint128 totalShares = 0;

        for (uint256 i = 0; i < toProcess; i++) {
            PendingIssuance storage pending = queue[i];
            ITranche(shareToken).mint(pending.user, pending.shares);
            totalShares += pending.shares;
            emit SharesIssued(poolId, scId, pending.user, pending.shares, pending.epochId);
        }

        // Remove processed items by shifting remaining items
        if (toProcess < queueLength) {
            for (uint256 i = 0; i < queueLength - toProcess; i++) {
                queue[i] = queue[i + toProcess];
            }
        }
        for (uint256 i = 0; i < toProcess; i++) {
            queue.pop();
        }

        _issuanceNonces[poolId][scId] += uint64(toProcess);
        emit BatchIssued(poolId, scId, toProcess, totalShares);

        return toProcess;
    }

    /// @inheritdoc IBalanceSheet
    function processRevocationQueue(
        uint64 poolId,
        bytes16 scId,
        uint256 maxOperations
    ) external returns (uint256 processed) {
        PendingRevocation[] storage queue = _revocationQueue[poolId][scId];
        uint256 queueLength = queue.length;
        if (queueLength == 0) revert QueueEmpty(poolId, scId);

        address shareToken = _shareTokens[poolId][scId];
        if (shareToken == address(0)) revert ShareTokenNotFound(poolId, scId);

        uint256 toProcess = maxOperations < queueLength ? maxOperations : queueLength;
        uint128 totalShares = 0;

        for (uint256 i = 0; i < toProcess; i++) {
            PendingRevocation storage pending = queue[i];
            ITranche(shareToken).burn(pending.user, pending.shares);
            totalShares += pending.shares;
            emit SharesRevoked(poolId, scId, pending.user, pending.shares, pending.epochId);
        }

        // Remove processed items by shifting remaining items
        if (toProcess < queueLength) {
            for (uint256 i = 0; i < queueLength - toProcess; i++) {
                queue[i] = queue[i + toProcess];
            }
        }
        for (uint256 i = 0; i < toProcess; i++) {
            queue.pop();
        }

        _revocationNonces[poolId][scId] += uint64(toProcess);
        emit BatchRevoked(poolId, scId, toProcess, totalShares);

        return toProcess;
    }

    // ============================================================
    // VIEW FUNCTIONS
    // ============================================================

    /// @inheritdoc IBalanceSheet
    function pendingIssuanceCount(uint64 poolId, bytes16 scId) external view returns (uint256) {
        return _issuanceQueue[poolId][scId].length;
    }

    /// @inheritdoc IBalanceSheet
    function pendingRevocationCount(uint64 poolId, bytes16 scId) external view returns (uint256) {
        return _revocationQueue[poolId][scId].length;
    }

    /// @inheritdoc IBalanceSheet
    function issuanceNonce(uint64 poolId, bytes16 scId) external view returns (uint64) {
        return _issuanceNonces[poolId][scId];
    }

    /// @inheritdoc IBalanceSheet
    function revocationNonce(uint64 poolId, bytes16 scId) external view returns (uint64) {
        return _revocationNonces[poolId][scId];
    }

    /// @inheritdoc IBalanceSheet
    function getShareToken(uint64 poolId, bytes16 scId) external view returns (address) {
        return _shareTokens[poolId][scId];
    }
}
