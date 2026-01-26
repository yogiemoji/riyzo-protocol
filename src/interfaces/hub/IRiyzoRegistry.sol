// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.28;

/// @title IRiyzoRegistry - Pool & Asset Registry Interface
/// @author Riyzo Protocol
/// @notice Interface for the central registry that tracks pools and assets.
///         Think of this as the "phone book" for the protocol.
/// @dev Stores pool configurations, asset registrations, and manager permissions.
///      This is the source of truth for what pools exist and who can manage them.
///
/// KEY CONCEPTS:
/// - Pool: A collection of assets managed together (e.g., "Real Estate Fund #1")
/// - Asset: A token that can be deposited/held (e.g., USDC, WETH)
/// - Manager: An address authorized to perform actions on a pool
/// - Currency: The base asset a pool is denominated in (e.g., USDC)
///
/// POOL ID FORMAT:
/// - 64-bit identifier
/// - Upper 16 bits: Chain ID (42161 for Arbitrum)
/// - Lower 48 bits: Sequential pool counter
/// - Example: 0xA4B1_000000000001 = First pool on Arbitrum
///
/// EXAMPLE:
/// - Create pool with USDC as currency
/// - Register admin as manager
/// - Pool can now accept USDC deposits
/// - Manager can create share classes, execute epochs, etc.
interface IRiyzoRegistry {
    // ============================================================
    // EVENTS
    // ============================================================

    /// @notice Emitted when a new pool is registered
    event PoolRegistered(uint64 indexed poolId, uint128 indexed currency, address indexed admin);

    /// @notice Emitted when pool metadata is updated
    event PoolMetadataUpdated(uint64 indexed poolId, bytes metadata);

    /// @notice Emitted when a manager is added or removed
    event ManagerUpdated(uint64 indexed poolId, address indexed manager, bool isManager);

    /// @notice Emitted when a new asset is registered
    event AssetRegistered(uint128 indexed assetId, address indexed asset, uint8 decimals);

    /// @notice Emitted when a hub request manager is set for a network
    event HubRequestManagerSet(uint64 indexed poolId, uint16 indexed centrifugeId, address manager);

    // ============================================================
    // ERRORS
    // ============================================================

    /// @notice Thrown when pool doesn't exist
    error PoolNotFound(uint64 poolId);

    /// @notice Thrown when pool already exists
    error PoolAlreadyExists(uint64 poolId);

    /// @notice Thrown when asset isn't registered
    error AssetNotRegistered(uint128 assetId);

    /// @notice Thrown when asset is already registered
    error AssetAlreadyRegistered(uint128 assetId);

    /// @notice Thrown when caller isn't a manager
    error NotManager(uint64 poolId, address caller);

    /// @notice Thrown when asset address is zero
    error InvalidAssetAddress();

    /// @notice Thrown when currency isn't registered
    error CurrencyNotRegistered(uint128 assetId);

    // ============================================================
    // STATE-CHANGING FUNCTIONS
    // ============================================================

    /// @notice Register a new pool
    /// @dev Creates a pool with the specified base currency and initial admin.
    ///      Pool ID is auto-generated using chain ID + sequential counter.
    ///
    /// WHAT THIS DOES:
    /// - Generates unique pool ID with chain prefix
    /// - Sets the pool's base currency (must be pre-registered asset)
    /// - Grants manager role to the admin address
    /// - Emits PoolRegistered event
    ///
    /// POOL ID GENERATION:
    /// - Upper 16 bits: block.chainid (42161 for Arbitrum = 0xA4B1)
    /// - Lower 48 bits: incrementing counter
    /// - Result: 0xA4B1_000000000001 for first pool
    ///
    /// @param currency Asset ID of the pool's base currency (e.g., USDC)
    /// @param admin Address that will manage the pool initially
    /// @return poolId The generated pool identifier
    function registerPool(uint128 currency, address admin) external returns (uint64 poolId);

    /// @notice Register a new asset
    /// @dev Assets must be registered before they can be used in pools.
    ///      This maps an on-chain token address to a protocol-wide asset ID.
    ///
    /// WHAT THIS DOES:
    /// - Assigns the next available asset ID
    /// - Stores the token address and decimals
    /// - Makes the asset available for use in all pools
    ///
    /// @param asset The ERC20 token address
    /// @param assetDecimals Token decimals (usually 6 for USDC, 18 for most tokens)
    /// @return assetId The assigned asset identifier
    function registerAsset(address asset, uint8 assetDecimals) external returns (uint128 assetId);

    /// @notice Add or remove a manager for a pool
    /// @dev Managers can perform administrative actions on the pool.
    ///
    /// WHAT MANAGERS CAN DO:
    /// - Create share classes
    /// - Start/execute epochs
    /// - Update holdings
    /// - Broadcast prices
    ///
    /// @param poolId Pool to update
    /// @param manager Address to grant/revoke
    /// @param isManager True to grant, false to revoke
    function updateManager(uint64 poolId, address manager, bool isManager) external;

    /// @notice Set pool metadata
    /// @dev Arbitrary bytes that can store JSON or other structured data.
    ///      Used by frontends to display pool information.
    ///
    /// @param poolId Pool to update
    /// @param metadata Arbitrary bytes (typically JSON-encoded)
    function setPoolMetadata(uint64 poolId, bytes calldata metadata) external;

    /// @notice Set the hub request manager for a specific network
    /// @dev Each spoke network has its own request manager for handling
    ///      incoming deposit/redeem requests.
    ///
    /// @param poolId Pool to configure
    /// @param centrifugeId Network identifier (e.g., 1 for Ethereum)
    /// @param manager Address of the request manager for that network
    function setHubRequestManager(uint64 poolId, uint16 centrifugeId, address manager) external;

    // ============================================================
    // VIEW FUNCTIONS
    // ============================================================

    /// @notice Check if a pool exists
    /// @param poolId Pool identifier
    /// @return exists True if pool has been registered
    function exists(uint64 poolId) external view returns (bool exists);

    /// @notice Check if an address is a manager for a pool
    /// @param poolId Pool identifier
    /// @param manager Address to check
    /// @return isManager True if address has manager role
    function isManager(uint64 poolId, address manager) external view returns (bool isManager);

    /// @notice Get the base currency for a pool
    /// @param poolId Pool identifier
    /// @return assetId Asset ID of the pool's currency
    function currency(uint64 poolId) external view returns (uint128 assetId);

    /// @notice Get the pool metadata
    /// @param poolId Pool identifier
    /// @return metadata The stored metadata bytes
    function getPoolMetadata(uint64 poolId) external view returns (bytes memory metadata);

    /// @notice Get decimals for an asset
    /// @param assetId Asset identifier
    /// @return assetDecimals Number of decimals
    function decimals(uint128 assetId) external view returns (uint8 assetDecimals);

    /// @notice Get the token address for an asset ID
    /// @param assetId Asset identifier
    /// @return asset The ERC20 token address
    function getAssetAddress(uint128 assetId) external view returns (address asset);

    /// @notice Get the asset ID for a token address
    /// @param asset The ERC20 token address
    /// @return assetId The asset identifier (0 if not registered)
    function getAssetId(address asset) external view returns (uint128 assetId);

    /// @notice Check if an asset is registered
    /// @param assetId Asset identifier
    /// @return registered True if asset exists
    function isRegistered(uint128 assetId) external view returns (bool registered);

    /// @notice Get the hub request manager for a pool and network
    /// @param poolId Pool identifier
    /// @param centrifugeId Network identifier
    /// @return manager The request manager address
    function getHubRequestManager(uint64 poolId, uint16 centrifugeId) external view returns (address manager);

    /// @notice Get the current pool counter (for predicting next pool ID)
    /// @return counter Current counter value
    function poolCounter() external view returns (uint48 counter);

    /// @notice Get the current asset counter
    /// @return counter Current counter value
    function assetCounter() external view returns (uint128 counter);
}
