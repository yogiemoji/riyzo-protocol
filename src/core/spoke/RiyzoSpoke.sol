// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.28;

import {Auth} from "src/core/Auth.sol";
import {IRiyzoSpoke} from "src/interfaces/spoke/IRiyzoSpoke.sol";
import {IBalanceSheet} from "src/interfaces/spoke/IBalanceSheet.sol";
import {IVaultRegistry} from "src/interfaces/spoke/IVaultRegistry.sol";
import {IPoolEscrow} from "src/interfaces/spoke/IPoolEscrow.sol";
import {IQueueManager} from "src/interfaces/spoke/IQueueManager.sol";
import {IGateway} from "src/interfaces/gateway/IGateway.sol";
import {MessagesLib} from "src/core/libraries/MessagesLib.sol";

/// @title RiyzoSpoke - Spoke Chain Coordinator
/// @author Riyzo Protocol
/// @notice Central coordinator for all spoke operations on a single chain (Ethereum, Base).
///         This is the spoke-side counterpart to RiyzoHub on the Arbitrum hub.
/// @dev RiyzoSpoke serves as the main entry point on each spoke chain:
///
/// RESPONSIBILITIES:
/// - Pool and share class state management
/// - Price tracking (from hub updates)
/// - Request forwarding (deposits, redeems, cancellations)
/// - Component coordination (BalanceSheet, VaultRegistry, PoolEscrow, etc.)
///
/// MESSAGE FLOW:
/// - INCOMING: Gateway calls handleFromHub() with decoded messages
/// - OUTGOING: Vaults call queue functions, spoke batches and sends via sendToHub()
///
/// COORDINATION:
/// - Coordinates with BalanceSheet for share issuance/revocation
/// - Coordinates with VaultRegistry for vault deployment
/// - Coordinates with PoolEscrow for asset custody
/// - Coordinates with AsyncRequestManager for request tracking
/// - Coordinates with QueueManager for auto-sync
contract RiyzoSpoke is Auth, IRiyzoSpoke {
    // ============================================================
    // STATE
    // ============================================================

    /// @notice Gateway for cross-chain messaging
    address public gateway;

    /// @notice BalanceSheet for share management
    address public balanceSheet;

    /// @notice VaultRegistry for vault lifecycle
    address public vaultRegistry;

    /// @notice PoolEscrow for asset custody accounting
    address public poolEscrow;

    /// @notice SpokeHandler for message processing
    address public spokeHandler;

    /// @notice AsyncRequestManager for request tracking
    address public asyncRequestManager;

    /// @notice QueueManager for auto-sync
    address public queueManager;

    /// @notice Pool state by poolId
    mapping(uint64 => PoolState) internal _pools;

    /// @notice Share class state by poolId => scId
    mapping(uint64 => mapping(bytes16 => ShareClassState)) internal _shareClasses;

    /// @notice Vault address by poolId => scId => asset
    mapping(uint64 => mapping(bytes16 => mapping(address => address))) internal _vaults;

    /// @notice Maximum allowed price age before considered stale (seconds)
    uint64 public maxPriceAge = 1 days;

    // ============================================================
    // CONSTRUCTOR
    // ============================================================

    /// @param deployer Initial ward address
    constructor(address deployer) Auth(deployer) {}

    // ============================================================
    // CONFIGURATION
    // ============================================================

    /// @notice Set configuration values
    /// @param what Configuration key
    /// @param data Address value
    function file(bytes32 what, address data) external auth {
        if (what == "gateway") gateway = data;
        else if (what == "balanceSheet") balanceSheet = data;
        else if (what == "vaultRegistry") vaultRegistry = data;
        else if (what == "poolEscrow") poolEscrow = data;
        else if (what == "spokeHandler") spokeHandler = data;
        else if (what == "asyncRequestManager") asyncRequestManager = data;
        else if (what == "queueManager") queueManager = data;
        else revert("RiyzoSpoke/file-unrecognized-param");
    }

    /// @notice Set configuration values (uint64)
    /// @param what Configuration key
    /// @param data Uint64 value
    function file(bytes32 what, uint64 data) external auth {
        if (what == "maxPriceAge") maxPriceAge = data;
        else revert("RiyzoSpoke/file-unrecognized-param");
    }

    // ============================================================
    // POOL REGISTRATION (from hub messages)
    // ============================================================

    /// @inheritdoc IRiyzoSpoke
    function registerPool(uint64 poolId, address currency) external auth {
        if (_pools[poolId].exists) revert PoolAlreadyExists(poolId);

        _pools[poolId] = PoolState({exists: true, poolId: poolId, currency: currency, isActive: true});

        emit PoolRegistered(poolId, currency);
    }

    /// @inheritdoc IRiyzoSpoke
    function registerShareClass(uint64 poolId, bytes16 scId, string calldata name, string calldata symbol)
        external
        auth
        returns (address shareToken)
    {
        if (!_pools[poolId].exists) revert PoolNotFound(poolId);
        if (_shareClasses[poolId][scId].exists) revert ShareClassAlreadyExists(poolId, scId);

        // Deploy share token via VaultRegistry
        shareToken = IVaultRegistry(vaultRegistry).deployShareToken(poolId, scId, name, symbol, address(0));

        // Register in BalanceSheet
        IBalanceSheet(balanceSheet).setShareToken(poolId, scId, shareToken);

        _shareClasses[poolId][scId] =
            ShareClassState({exists: true, scId: scId, shareToken: shareToken, latestPrice: 0, priceTimestamp: 0});

        emit ShareClassRegistered(poolId, scId, shareToken);
    }

    /// @inheritdoc IRiyzoSpoke
    function linkVault(uint64 poolId, bytes16 scId, address asset, address vault) external auth {
        if (!_pools[poolId].exists) revert PoolNotFound(poolId);
        if (!_shareClasses[poolId][scId].exists) revert ShareClassNotFound(poolId, scId);

        _vaults[poolId][scId][asset] = vault;

        emit VaultLinked(poolId, scId, asset, vault);
    }

    // ============================================================
    // PRICE UPDATES (from hub)
    // ============================================================

    /// @inheritdoc IRiyzoSpoke
    function updatePrice(uint64 poolId, bytes16 scId, uint128 price, uint64 timestamp) external auth {
        if (!_pools[poolId].exists) revert PoolNotFound(poolId);
        if (!_shareClasses[poolId][scId].exists) revert ShareClassNotFound(poolId, scId);

        ShareClassState storage sc = _shareClasses[poolId][scId];
        sc.latestPrice = price;
        sc.priceTimestamp = timestamp;

        emit PriceUpdated(poolId, scId, price, timestamp);
    }

    // ============================================================
    // REQUEST FORWARDING (from vaults)
    // ============================================================

    /// @inheritdoc IRiyzoSpoke
    function queueDepositRequest(uint64 poolId, bytes16 scId, address user, uint128 amount) external {
        address vault = _vaults[poolId][scId][msg.sender];
        if (vault == address(0) && msg.sender != _vaults[poolId][scId][msg.sender]) {
            // Caller must be a registered vault for this pool/shareClass
            // Allow direct calls from vaults where msg.sender matches stored vault
            address expectedVault = _vaults[poolId][scId][_getAssetFromVault(msg.sender)];
            if (expectedVault != msg.sender) revert Unauthorized(msg.sender);
        }

        if (!_pools[poolId].isActive) revert PoolNotActive(poolId);

        // Record in escrow
        IPoolEscrow(poolEscrow).recordDeposit(poolId, scId, _pools[poolId].currency, amount);

        // Add to queue
        if (queueManager != address(0)) {
            IQueueManager(queueManager).addToPendingDeposits(poolId, scId, amount);
        }

        emit DepositRequestQueued(poolId, scId, user, amount);

        // Build and send message to hub
        bytes memory message = abi.encodePacked(
            uint8(MessagesLib.Call.DepositRequest),
            poolId,
            scId,
            _addressToBytes32(user),
            uint128(0), // assetId - to be resolved
            amount
        );
        _sendToHub(message);
    }

    /// @inheritdoc IRiyzoSpoke
    function queueRedeemRequest(uint64 poolId, bytes16 scId, address user, uint128 shares) external {
        if (!_pools[poolId].isActive) revert PoolNotActive(poolId);

        // Add to queue
        if (queueManager != address(0)) {
            IQueueManager(queueManager).addToPendingRedeems(poolId, scId, shares);
        }

        emit RedeemRequestQueued(poolId, scId, user, shares);

        // Build and send message to hub
        bytes memory message =
            abi.encodePacked(uint8(MessagesLib.Call.RedeemRequest), poolId, scId, _addressToBytes32(user), shares);
        _sendToHub(message);
    }

    /// @inheritdoc IRiyzoSpoke
    function queueCancelDeposit(uint64 poolId, bytes16 scId, address user) external {
        bytes memory message =
            abi.encodePacked(uint8(MessagesLib.Call.CancelDepositRequest), poolId, scId, _addressToBytes32(user));
        _sendToHub(message);
    }

    /// @inheritdoc IRiyzoSpoke
    function queueCancelRedeem(uint64 poolId, bytes16 scId, address user) external {
        bytes memory message =
            abi.encodePacked(uint8(MessagesLib.Call.CancelRedeemRequest), poolId, scId, _addressToBytes32(user));
        _sendToHub(message);
    }

    // ============================================================
    // CROSS-CHAIN MESSAGING
    // ============================================================

    /// @inheritdoc IRiyzoSpoke
    function sendToHub(bytes memory message) external auth {
        _sendToHub(message);
    }

    /// @inheritdoc IRiyzoSpoke
    function handleFromHub(bytes calldata message) external auth {
        bytes32 messageHash = keccak256(message);
        uint8 messageType = uint8(message[0]);

        emit MessageReceivedFromHub(messageHash, messageType);

        // Forward to SpokeHandler for processing
        // SpokeHandler will call back into RiyzoSpoke for state updates
        (bool success, bytes memory returnData) = spokeHandler.call(abi.encodeWithSignature("handle(bytes)", message));
        require(success, string(returnData));
    }

    // ============================================================
    // VIEW FUNCTIONS
    // ============================================================

    /// @inheritdoc IRiyzoSpoke
    function getPool(uint64 poolId) external view returns (PoolState memory) {
        return _pools[poolId];
    }

    /// @inheritdoc IRiyzoSpoke
    function getShareClass(uint64 poolId, bytes16 scId) external view returns (ShareClassState memory) {
        return _shareClasses[poolId][scId];
    }

    /// @inheritdoc IRiyzoSpoke
    function getVault(uint64 poolId, bytes16 scId, address asset) external view returns (address) {
        return _vaults[poolId][scId][asset];
    }

    /// @inheritdoc IRiyzoSpoke
    function getPrice(uint64 poolId, bytes16 scId) external view returns (uint128 price, uint64 timestamp) {
        ShareClassState storage sc = _shareClasses[poolId][scId];
        return (sc.latestPrice, sc.priceTimestamp);
    }

    /// @inheritdoc IRiyzoSpoke
    function isValidVault(address vault) external view returns (bool) {
        return IVaultRegistry(vaultRegistry).isActiveVault(vault);
    }

    // ============================================================
    // INTERNAL
    // ============================================================

    /// @dev Send message to hub via Gateway
    function _sendToHub(bytes memory message) internal {
        bytes32 messageHash = keccak256(message);
        uint8 messageType = uint8(message[0]);

        emit MessageSentToHub(messageHash, messageType);

        IGateway(gateway).send(message, address(this));
    }

    /// @dev Convert address to bytes32 (right-padded)
    function _addressToBytes32(address addr) internal pure returns (bytes32) {
        return bytes32(uint256(uint160(addr)));
    }

    /// @dev Get asset address from vault (placeholder - actual implementation depends on vault interface)
    function _getAssetFromVault(
        address /* vault */
    )
        internal
        pure
        returns (address)
    {
        // This would typically call vault.asset() but we simplify for now
        return address(0);
    }
}
