// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.28;

/// @title IRiyzoSpoke - Spoke Chain Coordinator Interface
/// @author Riyzo Protocol
/// @notice Interface for the main spoke contract that coordinates all operations on a single spoke chain.
///         This is the spoke-side counterpart to RiyzoHub on the hub chain.
/// @dev RiyzoSpoke serves as the central coordinator on each spoke chain (Ethereum, Base).
///      It manages pool state, routes messages, and coordinates with vaults.
///
/// KEY RESPONSIBILITIES:
/// - Pool and share class registration (from hub messages)
/// - Price updates from hub
/// - Request forwarding to hub
/// - Vault coordination
///
/// MESSAGE FLOW:
/// - INCOMING (from hub): Pool registration, price updates, fulfillment confirmations
/// - OUTGOING (to hub): Deposit requests, redeem requests, cancellations
interface IRiyzoSpoke {
    // ============================================================
    // STRUCTS
    // ============================================================

    /// @notice State for a pool on this spoke chain
    struct PoolState {
        /// @notice Whether the pool exists on this spoke
        bool exists;
        /// @notice The pool's unique identifier
        uint64 poolId;
        /// @notice Pool's base currency address on this chain
        address currency;
        /// @notice Whether the pool is currently active
        bool isActive;
    }

    /// @notice State for a share class within a pool
    struct ShareClassState {
        /// @notice Whether the share class exists
        bool exists;
        /// @notice Share class identifier
        bytes16 scId;
        /// @notice Deployed ShareToken address on this chain
        address shareToken;
        /// @notice Latest price from hub (18 decimals)
        uint128 latestPrice;
        /// @notice Timestamp when price was last updated
        uint64 priceTimestamp;
    }

    // ============================================================
    // EVENTS
    // ============================================================

    /// @notice Emitted when a pool is registered on this spoke
    event PoolRegistered(uint64 indexed poolId, address indexed currency);

    /// @notice Emitted when a share class is registered
    event ShareClassRegistered(uint64 indexed poolId, bytes16 indexed scId, address shareToken);

    /// @notice Emitted when a vault is linked to a share class
    event VaultLinked(uint64 indexed poolId, bytes16 indexed scId, address indexed asset, address vault);

    /// @notice Emitted when a price update is received from hub
    event PriceUpdated(uint64 indexed poolId, bytes16 indexed scId, uint128 price, uint64 timestamp);

    /// @notice Emitted when a deposit request is queued
    event DepositRequestQueued(uint64 indexed poolId, bytes16 indexed scId, address indexed user, uint128 amount);

    /// @notice Emitted when a redeem request is queued
    event RedeemRequestQueued(uint64 indexed poolId, bytes16 indexed scId, address indexed user, uint128 shares);

    /// @notice Emitted when a message is sent to hub
    event MessageSentToHub(bytes32 indexed messageHash, uint8 messageType);

    /// @notice Emitted when a message is received from hub
    event MessageReceivedFromHub(bytes32 indexed messageHash, uint8 messageType);

    // ============================================================
    // ERRORS
    // ============================================================

    /// @notice Thrown when pool doesn't exist on this spoke
    error PoolNotFound(uint64 poolId);

    /// @notice Thrown when share class doesn't exist
    error ShareClassNotFound(uint64 poolId, bytes16 scId);

    /// @notice Thrown when vault doesn't exist for asset
    error VaultNotFound(uint64 poolId, bytes16 scId, address asset);

    /// @notice Thrown when pool is not active
    error PoolNotActive(uint64 poolId);

    /// @notice Thrown when caller is not authorized
    error Unauthorized(address caller);

    /// @notice Thrown when pool already exists
    error PoolAlreadyExists(uint64 poolId);

    /// @notice Thrown when share class already exists
    error ShareClassAlreadyExists(uint64 poolId, bytes16 scId);

    /// @notice Thrown when price is stale
    error StalePrice(uint64 poolId, bytes16 scId, uint64 priceAge, uint64 maxAge);

    // ============================================================
    // POOL REGISTRATION (from hub messages)
    // ============================================================

    /// @notice Register a new pool on this spoke chain
    /// @dev Called by SpokeHandler when AddPool message received from hub.
    ///
    /// @param poolId Pool identifier from hub
    /// @param currency Base currency address on this chain
    function registerPool(uint64 poolId, address currency) external;

    /// @notice Register a share class for a pool
    /// @dev Called by SpokeHandler when AddTranche message received from hub.
    ///      Deploys ShareToken via TrancheFactory.
    ///
    /// @param poolId Pool identifier
    /// @param scId Share class identifier
    /// @param name Human-readable name for the share token
    /// @param symbol Token symbol
    /// @return shareToken Address of deployed ShareToken
    function registerShareClass(
        uint64 poolId,
        bytes16 scId,
        string calldata name,
        string calldata symbol
    ) external returns (address shareToken);

    /// @notice Link a vault to a share class for a specific asset
    /// @dev Called when vault is deployed for this pool/shareClass/asset combo.
    ///
    /// @param poolId Pool identifier
    /// @param scId Share class identifier
    /// @param asset Asset address (e.g., USDC)
    /// @param vault Deployed vault address
    function linkVault(uint64 poolId, bytes16 scId, address asset, address vault) external;

    // ============================================================
    // PRICE UPDATES (from hub)
    // ============================================================

    /// @notice Update the price for a share class
    /// @dev Called by SpokeHandler when UpdateTranchePrice message received from hub.
    ///
    /// @param poolId Pool identifier
    /// @param scId Share class identifier
    /// @param price New price (18 decimals)
    /// @param timestamp When price was calculated on hub
    function updatePrice(uint64 poolId, bytes16 scId, uint128 price, uint64 timestamp) external;

    // ============================================================
    // REQUEST FORWARDING (from vaults)
    // ============================================================

    /// @notice Queue a deposit request to be sent to hub
    /// @dev Called by ERC7540Vault when user requests deposit.
    ///
    /// @param poolId Pool identifier
    /// @param scId Share class identifier
    /// @param user User making the deposit
    /// @param amount Amount of assets being deposited
    function queueDepositRequest(uint64 poolId, bytes16 scId, address user, uint128 amount) external;

    /// @notice Queue a redeem request to be sent to hub
    /// @dev Called by ERC7540Vault when user requests redemption.
    ///
    /// @param poolId Pool identifier
    /// @param scId Share class identifier
    /// @param user User making the redemption
    /// @param shares Number of shares to redeem
    function queueRedeemRequest(uint64 poolId, bytes16 scId, address user, uint128 shares) external;

    /// @notice Queue a deposit cancellation request
    /// @dev Called when user wants to cancel pending deposit.
    ///
    /// @param poolId Pool identifier
    /// @param scId Share class identifier
    /// @param user User cancelling the deposit
    function queueCancelDeposit(uint64 poolId, bytes16 scId, address user) external;

    /// @notice Queue a redeem cancellation request
    /// @dev Called when user wants to cancel pending redemption.
    ///
    /// @param poolId Pool identifier
    /// @param scId Share class identifier
    /// @param user User cancelling the redemption
    function queueCancelRedeem(uint64 poolId, bytes16 scId, address user) external;

    // ============================================================
    // CROSS-CHAIN MESSAGING
    // ============================================================

    /// @notice Send a message to the hub chain
    /// @dev Routes through Gateway to cross-chain adapters.
    ///
    /// @param message Encoded message data
    function sendToHub(bytes memory message) external;

    /// @notice Handle incoming message from hub
    /// @dev Called by Gateway when message arrives from hub via adapters.
    ///
    /// @param message Encoded message data from hub
    function handleFromHub(bytes calldata message) external;

    // ============================================================
    // VIEW FUNCTIONS
    // ============================================================

    /// @notice Get pool state
    /// @param poolId Pool identifier
    /// @return state The PoolState struct
    function getPool(uint64 poolId) external view returns (PoolState memory state);

    /// @notice Get share class state
    /// @param poolId Pool identifier
    /// @param scId Share class identifier
    /// @return state The ShareClassState struct
    function getShareClass(uint64 poolId, bytes16 scId) external view returns (ShareClassState memory state);

    /// @notice Get vault address for a pool/shareClass/asset combination
    /// @param poolId Pool identifier
    /// @param scId Share class identifier
    /// @param asset Asset address
    /// @return vault The vault address (zero if not linked)
    function getVault(uint64 poolId, bytes16 scId, address asset) external view returns (address vault);

    /// @notice Get the current price for a share class
    /// @param poolId Pool identifier
    /// @param scId Share class identifier
    /// @return price Current price (18 decimals)
    /// @return timestamp When price was last updated
    function getPrice(uint64 poolId, bytes16 scId) external view returns (uint128 price, uint64 timestamp);

    /// @notice Check if a vault is valid for this spoke
    /// @param vault Vault address to check
    /// @return valid True if vault is registered and active
    function isValidVault(address vault) external view returns (bool valid);

    // ============================================================
    // COMPONENT ACCESSORS
    // ============================================================

    /// @notice Get the Gateway contract address
    function gateway() external view returns (address);

    /// @notice Get the BalanceSheet contract address
    function balanceSheet() external view returns (address);

    /// @notice Get the VaultRegistry contract address
    function vaultRegistry() external view returns (address);

    /// @notice Get the PoolEscrow contract address
    function poolEscrow() external view returns (address);

    /// @notice Get the SpokeHandler contract address
    function spokeHandler() external view returns (address);
}
