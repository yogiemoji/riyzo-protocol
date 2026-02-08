// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.28;

import {Auth} from "src/core/Auth.sol";
import {IAsyncRequestManager} from "src/interfaces/spoke/IAsyncRequestManager.sol";

/// @title AsyncRequestManager - Request State Management
/// @author Riyzo Protocol
/// @notice Tracks deposit/redeem request states per user per vault for ERC-7540 compliance.
/// @dev AsyncRequestManager implements the async request pattern:
///
/// REQUEST LIFECYCLE:
/// 1. User calls vault.requestDeposit() -> state = Pending
/// 2. Hub executes epoch, sends fulfillment -> state = Claimable
/// 3. User calls vault.claimDeposit() -> state = Claimed
///
/// INVARIANTS:
/// - Each user has at most one pending deposit per vault
/// - Each user has at most one pending redeem per vault
/// - State transitions are one-way: None -> Pending -> Claimable -> Claimed
///
/// ERC-7540 COMPATIBILITY:
/// - pendingDeposit() returns assets in pending state
/// - claimableDeposit() returns shares in claimable state
/// - pendingRedeem() returns shares in pending state
/// - claimableRedeem() returns assets in claimable state
contract AsyncRequestManager is Auth, IAsyncRequestManager {
    // ============================================================
    // STATE
    // ============================================================

    /// @notice Deposit requests per vault per user
    /// @dev vault => user => DepositRequest
    mapping(address => mapping(address => DepositRequest)) internal _depositRequests;

    /// @notice Redeem requests per vault per user
    /// @dev vault => user => RedeemRequest
    mapping(address => mapping(address => RedeemRequest)) internal _redeemRequests;

    // ============================================================
    // CONSTRUCTOR
    // ============================================================

    /// @param deployer Initial ward address
    constructor(address deployer) Auth(deployer) {}

    // ============================================================
    // REQUEST SUBMISSION
    // ============================================================

    /// @inheritdoc IAsyncRequestManager
    function createDepositRequest(
        address vault,
        address user,
        uint128 assets,
        uint64 epochId
    ) external auth {
        if (assets == 0) revert ZeroAmount();

        DepositRequest storage request = _depositRequests[vault][user];
        if (request.state == RequestState.Pending) {
            revert RequestAlreadyPending(vault, user);
        }

        _depositRequests[vault][user] = DepositRequest({
            assets: assets,
            shares: 0,
            epochId: epochId,
            state: RequestState.Pending
        });

        emit DepositRequestCreated(vault, user, assets, epochId);
    }

    /// @inheritdoc IAsyncRequestManager
    function createRedeemRequest(
        address vault,
        address user,
        uint128 shares,
        uint64 epochId
    ) external auth {
        if (shares == 0) revert ZeroAmount();

        RedeemRequest storage request = _redeemRequests[vault][user];
        if (request.state == RequestState.Pending) {
            revert RequestAlreadyPending(vault, user);
        }

        _redeemRequests[vault][user] = RedeemRequest({
            shares: shares,
            assets: 0,
            epochId: epochId,
            state: RequestState.Pending
        });

        emit RedeemRequestCreated(vault, user, shares, epochId);
    }

    // ============================================================
    // REQUEST FULFILLMENT
    // ============================================================

    /// @inheritdoc IAsyncRequestManager
    function fulfillDeposit(address vault, address user, uint128 shares) external auth {
        DepositRequest storage request = _depositRequests[vault][user];

        if (request.state != RequestState.Pending) {
            revert InvalidRequestState(vault, user, request.state, RequestState.Pending);
        }

        request.shares = shares;
        request.state = RequestState.Claimable;

        emit DepositFulfilled(vault, user, shares);
    }

    /// @inheritdoc IAsyncRequestManager
    function fulfillRedeem(address vault, address user, uint128 assets) external auth {
        RedeemRequest storage request = _redeemRequests[vault][user];

        if (request.state != RequestState.Pending) {
            revert InvalidRequestState(vault, user, request.state, RequestState.Pending);
        }

        request.assets = assets;
        request.state = RequestState.Claimable;

        emit RedeemFulfilled(vault, user, assets);
    }

    // ============================================================
    // USER CLAIMS
    // ============================================================

    /// @inheritdoc IAsyncRequestManager
    function claimDeposit(address vault, address user) external auth returns (uint128 shares) {
        DepositRequest storage request = _depositRequests[vault][user];

        if (request.state != RequestState.Claimable) {
            revert InvalidRequestState(vault, user, request.state, RequestState.Claimable);
        }

        shares = request.shares;
        request.state = RequestState.Claimed;

        emit DepositClaimed(vault, user, shares);
    }

    /// @inheritdoc IAsyncRequestManager
    function claimRedeem(address vault, address user) external auth returns (uint128 assets) {
        RedeemRequest storage request = _redeemRequests[vault][user];

        if (request.state != RequestState.Claimable) {
            revert InvalidRequestState(vault, user, request.state, RequestState.Claimable);
        }

        assets = request.assets;
        request.state = RequestState.Claimed;

        emit RedeemClaimed(vault, user, assets);
    }

    // ============================================================
    // CANCELLATIONS
    // ============================================================

    /// @inheritdoc IAsyncRequestManager
    function cancelDepositRequest(address vault, address user) external auth {
        DepositRequest storage request = _depositRequests[vault][user];

        if (request.state != RequestState.Pending) {
            revert InvalidRequestState(vault, user, request.state, RequestState.Pending);
        }

        uint128 assets = request.assets;
        request.state = RequestState.Cancelled;

        emit DepositRequestCancelled(vault, user, assets);
    }

    /// @inheritdoc IAsyncRequestManager
    function cancelRedeemRequest(address vault, address user) external auth {
        RedeemRequest storage request = _redeemRequests[vault][user];

        if (request.state != RequestState.Pending) {
            revert InvalidRequestState(vault, user, request.state, RequestState.Pending);
        }

        uint128 shares = request.shares;
        request.state = RequestState.Cancelled;

        emit RedeemRequestCancelled(vault, user, shares);
    }

    // ============================================================
    // VIEW FUNCTIONS
    // ============================================================

    /// @inheritdoc IAsyncRequestManager
    function getDepositRequest(
        address vault,
        address user
    ) external view returns (DepositRequest memory) {
        return _depositRequests[vault][user];
    }

    /// @inheritdoc IAsyncRequestManager
    function getRedeemRequest(
        address vault,
        address user
    ) external view returns (RedeemRequest memory) {
        return _redeemRequests[vault][user];
    }

    /// @inheritdoc IAsyncRequestManager
    function pendingDeposit(address vault, address user) external view returns (uint256) {
        DepositRequest storage request = _depositRequests[vault][user];
        if (request.state == RequestState.Pending) {
            return request.assets;
        }
        return 0;
    }

    /// @inheritdoc IAsyncRequestManager
    function claimableDeposit(address vault, address user) external view returns (uint256) {
        DepositRequest storage request = _depositRequests[vault][user];
        if (request.state == RequestState.Claimable) {
            return request.shares;
        }
        return 0;
    }

    /// @inheritdoc IAsyncRequestManager
    function pendingRedeem(address vault, address user) external view returns (uint256) {
        RedeemRequest storage request = _redeemRequests[vault][user];
        if (request.state == RequestState.Pending) {
            return request.shares;
        }
        return 0;
    }

    /// @inheritdoc IAsyncRequestManager
    function claimableRedeem(address vault, address user) external view returns (uint256) {
        RedeemRequest storage request = _redeemRequests[vault][user];
        if (request.state == RequestState.Claimable) {
            return request.assets;
        }
        return 0;
    }

    /// @inheritdoc IAsyncRequestManager
    function hasPendingRequest(address vault, address user) external view returns (bool) {
        return _depositRequests[vault][user].state == RequestState.Pending
            || _redeemRequests[vault][user].state == RequestState.Pending;
    }
}
