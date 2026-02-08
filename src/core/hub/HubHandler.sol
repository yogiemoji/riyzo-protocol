// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.28;

import {Auth} from "src/core/Auth.sol";
import {IRiyzoRegistry} from "src/interfaces/hub/IRiyzoRegistry.sol";
import {IShareClassManager} from "src/interfaces/hub/IShareClassManager.sol";
import {IAccounting} from "src/interfaces/hub/IAccounting.sol";
import {IHoldings} from "src/interfaces/hub/IHoldings.sol";
import {INAVManager} from "src/interfaces/hub/INAVManager.sol";
import {BytesLib} from "src/core/libraries/BytesLib.sol";

/// @title HubHandler - Cross-Chain Message Handler
/// @author Riyzo Protocol
/// @notice This contract handles incoming messages from spoke chains.
///         Think of it as the "mailroom" that processes incoming requests.
/// @dev Implements message decoding and routing for hub operations.
///
/// ============================================================
/// KEY CONCEPTS FOR EVERYONE
/// ============================================================
///
/// WHAT IS A MESSAGE HANDLER?
/// When users on Ethereum or Base make deposit/redeem requests,
/// those requests are sent as messages across chains. This contract
/// receives and processes those messages on Arbitrum (the hub).
///
/// MESSAGE FLOW:
/// 1. User deposits 1000 USDC on Ethereum (spoke)
/// 2. Spoke chain encodes "DepositRequest" message
/// 3. Message travels via Axelar/LayerZero/Wormhole
/// 4. Gateway on Arbitrum receives message
/// 5. Gateway calls HubHandler.handle()
/// 6. HubHandler decodes and processes the request
///
/// ============================================================
/// MESSAGE TYPES
/// ============================================================
///
/// The protocol uses specific message type IDs:
///
/// INCOMING (from spokes to hub):
/// - 20: DepositRequest - User wants to deposit assets for shares
/// - 21: RedeemRequest - User wants to redeem shares for assets
/// - 24: CancelDepositRequest - User cancels pending deposit
/// - 25: CancelRedeemRequest - User cancels pending redeem
/// - 26: IncreaseDepositRequest - User adds to pending deposit
/// - 27: IncreaseRedeemRequest - User adds to pending redeem
/// - 28: TriggerExecutionAsyncRequest - Request epoch execution
///
/// OUTGOING (from hub to spokes):
/// - 10: UpdateTranchePrice - Broadcast new share price
/// - 11: TransferShares - Transfer shares to user
/// - 12: TransferAssets - Transfer assets to user
/// - 13: UpdateMember - Update tranche membership
///
/// ============================================================
/// MESSAGE ENCODING
/// ============================================================
///
/// Messages are encoded using abi.encodePacked for gas efficiency:
/// - First byte: Message type ID
/// - Remaining bytes: Message-specific data
///
/// EXAMPLE - DepositRequest:
/// [0]    = uint8(20)           // Message type
/// [1-8]  = uint64 poolId       // Pool identifier
/// [9-24] = bytes16 trancheId   // Share class ID
/// [25-40]= bytes32 investor    // Investor address (padded)
/// [41-56]= uint128 currencyId  // Asset being deposited
/// [57-72]= uint128 amount      // Amount to deposit
///
/// ============================================================
/// REQUEST QUEUE
/// ============================================================
///
/// Deposit and redeem requests are queued until epoch execution:
///
/// 1. REQUEST ARRIVES: User submits deposit request
/// 2. QUEUE: Request stored with poolId, investor, amount
/// 3. EPOCH STARTS: No new requests accepted
/// 4. EPOCH EXECUTES: All queued requests processed at epoch price
/// 5. FULFILLMENT: Results sent back to spoke chains
///
/// This batching approach:
/// - Ensures fair pricing (everyone gets same price)
/// - Reduces cross-chain message costs
/// - Simplifies accounting reconciliation
///
contract HubHandler is Auth {
    using BytesLib for bytes;

    // ============================================================
    // MESSAGE TYPE CONSTANTS
    // ============================================================

    // Incoming messages (from spokes)
    uint8 public constant MSG_DEPOSIT_REQUEST = 20;
    uint8 public constant MSG_REDEEM_REQUEST = 21;
    uint8 public constant MSG_CANCEL_DEPOSIT_REQUEST = 24;
    uint8 public constant MSG_CANCEL_REDEEM_REQUEST = 25;
    uint8 public constant MSG_INCREASE_DEPOSIT_REQUEST = 26;
    uint8 public constant MSG_INCREASE_REDEEM_REQUEST = 27;
    uint8 public constant MSG_TRIGGER_EXECUTION = 28;

    // Outgoing messages (to spokes)
    uint8 public constant MSG_UPDATE_TRANCHE_PRICE = 10;
    uint8 public constant MSG_TRANSFER_SHARES = 11;
    uint8 public constant MSG_TRANSFER_ASSETS = 12;
    uint8 public constant MSG_UPDATE_MEMBER = 13;

    // ============================================================
    // STRUCTS
    // ============================================================

    /// @notice Represents a pending deposit request
    /// @dev Stored until epoch execution
    struct DepositRequest {
        uint64 poolId;
        bytes16 scId;
        address investor;
        uint128 assetId;
        uint128 amount;
        uint16 sourceChain;
        uint64 timestamp;
    }

    /// @notice Represents a pending redeem request
    /// @dev Stored until epoch execution
    struct RedeemRequest {
        uint64 poolId;
        bytes16 scId;
        address investor;
        uint128 shares;
        uint16 sourceChain;
        uint64 timestamp;
    }

    // ============================================================
    // EVENTS
    // ============================================================

    /// @notice Emitted when a deposit request is queued
    event DepositRequestQueued(
        uint64 indexed poolId,
        bytes16 indexed scId,
        address indexed investor,
        uint128 assetId,
        uint128 amount,
        uint16 sourceChain
    );

    /// @notice Emitted when a redeem request is queued
    event RedeemRequestQueued(
        uint64 indexed poolId, bytes16 indexed scId, address indexed investor, uint128 shares, uint16 sourceChain
    );

    /// @notice Emitted when a deposit request is cancelled
    event DepositRequestCancelled(uint64 indexed poolId, bytes16 indexed scId, address indexed investor);

    /// @notice Emitted when a redeem request is cancelled
    event RedeemRequestCancelled(uint64 indexed poolId, bytes16 indexed scId, address indexed investor);

    /// @notice Emitted when an unknown message type is received
    event UnknownMessageType(uint8 messageType, uint16 sourceChain);

    // ============================================================
    // ERRORS
    // ============================================================

    /// @notice Thrown when message type is not recognized
    error UnknownMessage(uint8 messageType);

    /// @notice Thrown when message payload is too short
    error MessageTooShort(uint256 expected, uint256 actual);

    /// @notice Thrown when pool doesn't exist
    error PoolNotFound(uint64 poolId);

    /// @notice Thrown when share class doesn't exist
    error ShareClassNotFound(uint64 poolId, bytes16 scId);

    /// @notice Thrown when epoch is not accepting requests
    error EpochClosed(uint64 poolId);

    /// @notice Thrown when investor already has pending request
    error RequestAlreadyPending(uint64 poolId, bytes16 scId, address investor);

    /// @notice Thrown when no pending request exists to cancel
    error NoPendingRequest(uint64 poolId, bytes16 scId, address investor);

    // ============================================================
    // STORAGE
    // ============================================================

    /// @notice Reference to the Registry contract
    IRiyzoRegistry public registry;

    /// @notice Reference to the ShareClassManager contract
    IShareClassManager public shareClassManager;

    /// @notice Reference to the Accounting contract
    IAccounting public accounting;

    /// @notice Reference to the Holdings contract
    IHoldings public holdings;

    /// @notice Reference to the NAVManager contract
    INAVManager public navManager;

    /// @notice Pending deposit requests
    /// @dev requests[poolId][scId][investor] => DepositRequest
    mapping(uint64 => mapping(bytes16 => mapping(address => DepositRequest))) public depositRequests;

    /// @notice Pending redeem requests
    /// @dev requests[poolId][scId][investor] => RedeemRequest
    mapping(uint64 => mapping(bytes16 => mapping(address => RedeemRequest))) public redeemRequests;

    /// @notice Whether epoch is open for requests per pool
    /// @dev epochOpen[poolId] => bool
    mapping(uint64 => bool) public epochOpen;

    /// @notice Total pending deposit amount per pool per share class per asset
    /// @dev pendingDeposits[poolId][scId][assetId] => amount
    mapping(uint64 => mapping(bytes16 => mapping(uint128 => uint128))) public pendingDeposits;

    /// @notice Total pending redeem shares per pool per share class
    /// @dev pendingRedeems[poolId][scId] => shares
    mapping(uint64 => mapping(bytes16 => uint128)) public pendingRedeems;

    // ============================================================
    // CONSTRUCTOR
    // ============================================================

    /// @notice Initialize the HubHandler contract
    /// @param initialWard Address that will have admin rights
    /// @param registry_ Address of RiyzoRegistry
    /// @param shareClassManager_ Address of ShareClassManager
    /// @param accounting_ Address of Accounting
    /// @param holdings_ Address of Holdings
    /// @param navManager_ Address of NAVManager
    constructor(
        address initialWard,
        address registry_,
        address shareClassManager_,
        address accounting_,
        address holdings_,
        address navManager_
    ) Auth(initialWard) {
        registry = IRiyzoRegistry(registry_);
        shareClassManager = IShareClassManager(shareClassManager_);
        accounting = IAccounting(accounting_);
        holdings = IHoldings(holdings_);
        navManager = INAVManager(navManager_);
    }

    // ============================================================
    // ADMIN FUNCTIONS
    // ============================================================

    /// @notice Update contract dependencies
    function file(bytes32 what, address data) external auth {
        if (what == "registry") {
            registry = IRiyzoRegistry(data);
        } else if (what == "shareClassManager") {
            shareClassManager = IShareClassManager(data);
        } else if (what == "accounting") {
            accounting = IAccounting(data);
        } else if (what == "holdings") {
            holdings = IHoldings(data);
        } else if (what == "navManager") {
            navManager = INAVManager(data);
        } else {
            revert("HubHandler/file-unrecognized-param");
        }
        emit File(what, data);
    }

    event File(bytes32 indexed what, address data);

    /// @notice Set epoch open/closed for a pool
    /// @dev Called by RiyzoHub when starting/ending epochs
    function setEpochOpen(uint64 poolId, bool isOpen) external auth {
        epochOpen[poolId] = isOpen;
        emit EpochOpenSet(poolId, isOpen);
    }

    event EpochOpenSet(uint64 indexed poolId, bool isOpen);

    // ============================================================
    // MESSAGE HANDLING
    // ============================================================

    /// @notice Handle an incoming message from a spoke chain
    /// @dev Decodes message type and routes to appropriate handler
    /// @param sourceChain The originating chain ID
    /// @param payload The encoded message data
    function handle(uint16 sourceChain, bytes calldata payload) external auth {
        // ============================================================
        // STEP 1: Validate message has at least type byte
        // ============================================================
        if (payload.length < 1) {
            revert MessageTooShort(1, payload.length);
        }

        // ============================================================
        // STEP 2: Extract message type (first byte)
        // ============================================================
        uint8 messageType = uint8(payload[0]);

        // ============================================================
        // STEP 3: Route to appropriate handler
        // ============================================================
        if (messageType == MSG_DEPOSIT_REQUEST) {
            _handleDepositRequest(sourceChain, payload);
        } else if (messageType == MSG_REDEEM_REQUEST) {
            _handleRedeemRequest(sourceChain, payload);
        } else if (messageType == MSG_CANCEL_DEPOSIT_REQUEST) {
            _handleCancelDepositRequest(sourceChain, payload);
        } else if (messageType == MSG_CANCEL_REDEEM_REQUEST) {
            _handleCancelRedeemRequest(sourceChain, payload);
        } else if (messageType == MSG_INCREASE_DEPOSIT_REQUEST) {
            _handleIncreaseDepositRequest(sourceChain, payload);
        } else if (messageType == MSG_INCREASE_REDEEM_REQUEST) {
            _handleIncreaseRedeemRequest(sourceChain, payload);
        } else {
            // Unknown message type - emit event but don't revert
            // This allows protocol upgrades without breaking existing messages
            emit UnknownMessageType(messageType, sourceChain);
        }
    }

    // ============================================================
    // INTERNAL MESSAGE HANDLERS
    // ============================================================

    /// @dev Handle a deposit request message
    /// Message format:
    /// [0]     = uint8 messageType (20)
    /// [1-8]   = uint64 poolId
    /// [9-24]  = bytes16 scId
    /// [25-44] = address investor (20 bytes)
    /// [45-60] = uint128 assetId
    /// [61-76] = uint128 amount
    function _handleDepositRequest(uint16 sourceChain, bytes calldata payload) internal {
        // Minimum length: 1 + 8 + 16 + 20 + 16 + 16 = 77 bytes
        if (payload.length < 77) {
            revert MessageTooShort(77, payload.length);
        }

        // Decode message
        uint64 poolId = payload.toUint64(1);
        bytes16 scId = bytes16(payload[9:25]);
        address investor = payload.toAddress(25);
        uint128 assetId = payload.toUint128(45);
        uint128 amount = payload.toUint128(61);

        // Validate pool exists
        if (!registry.exists(poolId)) {
            revert PoolNotFound(poolId);
        }

        // Validate share class exists
        if (!shareClassManager.shareClassExists(poolId, scId)) {
            revert ShareClassNotFound(poolId, scId);
        }

        // Check epoch is open
        if (!epochOpen[poolId]) {
            revert EpochClosed(poolId);
        }

        // Check no existing request (for simplicity - could allow updates)
        if (depositRequests[poolId][scId][investor].amount > 0) {
            revert RequestAlreadyPending(poolId, scId, investor);
        }

        // Store request
        depositRequests[poolId][scId][investor] = DepositRequest({
            poolId: poolId,
            scId: scId,
            investor: investor,
            assetId: assetId,
            amount: amount,
            sourceChain: sourceChain,
            timestamp: uint64(block.timestamp)
        });

        // Update pending totals
        pendingDeposits[poolId][scId][assetId] += amount;

        emit DepositRequestQueued(poolId, scId, investor, assetId, amount, sourceChain);
    }

    /// @dev Handle a redeem request message
    /// Message format:
    /// [0]     = uint8 messageType (21)
    /// [1-8]   = uint64 poolId
    /// [9-24]  = bytes16 scId
    /// [25-44] = address investor (20 bytes)
    /// [45-60] = uint128 shares
    function _handleRedeemRequest(uint16 sourceChain, bytes calldata payload) internal {
        // Minimum length: 1 + 8 + 16 + 20 + 16 = 61 bytes
        if (payload.length < 61) {
            revert MessageTooShort(61, payload.length);
        }

        // Decode message
        uint64 poolId = payload.toUint64(1);
        bytes16 scId = bytes16(payload[9:25]);
        address investor = payload.toAddress(25);
        uint128 shares = payload.toUint128(45);

        // Validate pool exists
        if (!registry.exists(poolId)) {
            revert PoolNotFound(poolId);
        }

        // Validate share class exists
        if (!shareClassManager.shareClassExists(poolId, scId)) {
            revert ShareClassNotFound(poolId, scId);
        }

        // Check epoch is open
        if (!epochOpen[poolId]) {
            revert EpochClosed(poolId);
        }

        // Check no existing request
        if (redeemRequests[poolId][scId][investor].shares > 0) {
            revert RequestAlreadyPending(poolId, scId, investor);
        }

        // Store request
        redeemRequests[poolId][scId][investor] = RedeemRequest({
            poolId: poolId,
            scId: scId,
            investor: investor,
            shares: shares,
            sourceChain: sourceChain,
            timestamp: uint64(block.timestamp)
        });

        // Update pending totals
        pendingRedeems[poolId][scId] += shares;

        emit RedeemRequestQueued(poolId, scId, investor, shares, sourceChain);
    }

    /// @dev Handle a cancel deposit request message
    function _handleCancelDepositRequest(uint16 sourceChain, bytes calldata payload) internal {
        // sourceChain is used for validation (not implemented yet)
        (sourceChain);

        // Minimum length: 1 + 8 + 16 + 20 = 45 bytes
        if (payload.length < 45) {
            revert MessageTooShort(45, payload.length);
        }

        // Decode message
        uint64 poolId = payload.toUint64(1);
        bytes16 scId = bytes16(payload[9:25]);
        address investor = payload.toAddress(25);

        // Get existing request
        DepositRequest storage request = depositRequests[poolId][scId][investor];
        if (request.amount == 0) {
            revert NoPendingRequest(poolId, scId, investor);
        }

        // Update pending totals
        pendingDeposits[poolId][scId][request.assetId] -= request.amount;

        // Delete request
        delete depositRequests[poolId][scId][investor];

        emit DepositRequestCancelled(poolId, scId, investor);
    }

    /// @dev Handle a cancel redeem request message
    function _handleCancelRedeemRequest(uint16 sourceChain, bytes calldata payload) internal {
        // sourceChain is used for validation (not implemented yet)
        (sourceChain);

        // Minimum length: 1 + 8 + 16 + 20 = 45 bytes
        if (payload.length < 45) {
            revert MessageTooShort(45, payload.length);
        }

        // Decode message
        uint64 poolId = payload.toUint64(1);
        bytes16 scId = bytes16(payload[9:25]);
        address investor = payload.toAddress(25);

        // Get existing request
        RedeemRequest storage request = redeemRequests[poolId][scId][investor];
        if (request.shares == 0) {
            revert NoPendingRequest(poolId, scId, investor);
        }

        // Update pending totals
        pendingRedeems[poolId][scId] -= request.shares;

        // Delete request
        delete redeemRequests[poolId][scId][investor];

        emit RedeemRequestCancelled(poolId, scId, investor);
    }

    /// @dev Handle an increase deposit request message
    function _handleIncreaseDepositRequest(uint16 sourceChain, bytes calldata payload) internal {
        // sourceChain is used for validation (not implemented yet)
        (sourceChain);

        // Minimum length: 1 + 8 + 16 + 20 + 16 = 61 bytes
        if (payload.length < 61) {
            revert MessageTooShort(61, payload.length);
        }

        // Decode message
        uint64 poolId = payload.toUint64(1);
        bytes16 scId = bytes16(payload[9:25]);
        address investor = payload.toAddress(25);
        uint128 additionalAmount = payload.toUint128(45);

        // Get existing request
        DepositRequest storage request = depositRequests[poolId][scId][investor];
        if (request.amount == 0) {
            revert NoPendingRequest(poolId, scId, investor);
        }

        // Check epoch is open
        if (!epochOpen[poolId]) {
            revert EpochClosed(poolId);
        }

        // Update request amount
        request.amount += additionalAmount;

        // Update pending totals
        pendingDeposits[poolId][scId][request.assetId] += additionalAmount;

        emit DepositRequestQueued(poolId, scId, investor, request.assetId, request.amount, sourceChain);
    }

    /// @dev Handle an increase redeem request message
    function _handleIncreaseRedeemRequest(uint16 sourceChain, bytes calldata payload) internal {
        // sourceChain is used for validation (not implemented yet)
        (sourceChain);

        // Minimum length: 1 + 8 + 16 + 20 + 16 = 61 bytes
        if (payload.length < 61) {
            revert MessageTooShort(61, payload.length);
        }

        // Decode message
        uint64 poolId = payload.toUint64(1);
        bytes16 scId = bytes16(payload[9:25]);
        address investor = payload.toAddress(25);
        uint128 additionalShares = payload.toUint128(45);

        // Get existing request
        RedeemRequest storage request = redeemRequests[poolId][scId][investor];
        if (request.shares == 0) {
            revert NoPendingRequest(poolId, scId, investor);
        }

        // Check epoch is open
        if (!epochOpen[poolId]) {
            revert EpochClosed(poolId);
        }

        // Update request shares
        request.shares += additionalShares;

        // Update pending totals
        pendingRedeems[poolId][scId] += additionalShares;

        emit RedeemRequestQueued(poolId, scId, investor, request.shares, sourceChain);
    }

    // ============================================================
    // VIEW FUNCTIONS
    // ============================================================

    /// @notice Get a pending deposit request
    function getDepositRequest(uint64 poolId, bytes16 scId, address investor)
        external
        view
        returns (DepositRequest memory)
    {
        return depositRequests[poolId][scId][investor];
    }

    /// @notice Get a pending redeem request
    function getRedeemRequest(uint64 poolId, bytes16 scId, address investor)
        external
        view
        returns (RedeemRequest memory)
    {
        return redeemRequests[poolId][scId][investor];
    }

    /// @notice Get total pending deposits for a share class and asset
    function getPendingDeposits(uint64 poolId, bytes16 scId, uint128 assetId) external view returns (uint128) {
        return pendingDeposits[poolId][scId][assetId];
    }

    /// @notice Get total pending redeems for a share class
    function getPendingRedeems(uint64 poolId, bytes16 scId) external view returns (uint128) {
        return pendingRedeems[poolId][scId];
    }

    /// @notice Check if epoch is open for a pool
    function isEpochOpen(uint64 poolId) external view returns (bool) {
        return epochOpen[poolId];
    }
}
