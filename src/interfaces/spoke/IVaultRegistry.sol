// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.28;

/// @title IVaultRegistry - Vault Lifecycle Management Interface
/// @author Riyzo Protocol
/// @notice Interface for managing vault deployment and lifecycle on spoke chains.
///         Tracks all vaults and their relationships to pools, share classes, and assets.
/// @dev VaultRegistry handles:
/// - Vault deployment via factories (deterministic CREATE2 addresses)
/// - Share token deployment
/// - Vault activation/deactivation
/// - Vault-to-pool mapping
///
/// DEPLOYMENT PATTERN:
/// 1. Hub sends AddPool + AddTranche messages
/// 2. RiyzoSpoke calls deployShareToken() for each tranche
/// 3. When asset is allowed, deployVault() creates ERC7540Vault
/// 4. Vault is linked in RiyzoSpoke
interface IVaultRegistry {
    // ============================================================
    // STRUCTS
    // ============================================================

    /// @notice Metadata about a deployed vault
    struct VaultMetadata {
        /// @notice Pool this vault belongs to
        uint64 poolId;
        /// @notice Share class this vault represents
        bytes16 scId;
        /// @notice Deposit asset for this vault
        address asset;
        /// @notice Share token address
        address shareToken;
        /// @notice Whether vault is active for deposits/redeems
        bool isActive;
        /// @notice Block timestamp when vault was deployed
        uint64 deployedAt;
    }

    // ============================================================
    // EVENTS
    // ============================================================

    /// @notice Emitted when a new vault is deployed
    event VaultDeployed(
        address indexed vault,
        uint64 indexed poolId,
        bytes16 indexed scId,
        address asset,
        address shareToken
    );

    /// @notice Emitted when a share token is deployed
    event ShareTokenDeployed(
        address indexed shareToken,
        uint64 indexed poolId,
        bytes16 indexed scId,
        string name,
        string symbol
    );

    /// @notice Emitted when a vault is activated
    event VaultActivated(address indexed vault);

    /// @notice Emitted when a vault is deactivated
    event VaultDeactivated(address indexed vault);

    /// @notice Emitted when a vault is unlinked (removed)
    event VaultUnlinked(address indexed vault);

    /// @notice Emitted when vault factory is updated
    event VaultFactorySet(address indexed oldFactory, address indexed newFactory);

    /// @notice Emitted when tranche factory is updated
    event TrancheFactorySet(address indexed oldFactory, address indexed newFactory);

    // ============================================================
    // ERRORS
    // ============================================================

    /// @notice Thrown when vault doesn't exist
    error VaultNotFound(address vault);

    /// @notice Thrown when vault already exists
    error VaultAlreadyExists(bytes32 vaultId);

    /// @notice Thrown when share token already exists
    error ShareTokenAlreadyExists(uint64 poolId, bytes16 scId);

    /// @notice Thrown when factory is not set
    error FactoryNotSet(string factoryType);

    /// @notice Thrown when caller is not authorized
    error Unauthorized(address caller);

    /// @notice Thrown when vault is not active
    error VaultNotActive(address vault);

    /// @notice Thrown when vault is already active
    error VaultAlreadyActive(address vault);

    // ============================================================
    // VAULT DEPLOYMENT
    // ============================================================

    /// @notice Deploy a new ERC7540Vault
    /// @dev Uses CREATE2 for deterministic addresses.
    ///      VaultId = keccak256(poolId, scId, asset)
    ///
    /// @param poolId Pool identifier
    /// @param scId Share class identifier
    /// @param asset Deposit asset address
    /// @param shareToken Pre-deployed share token address
    /// @return vault Address of deployed vault
    function deployVault(
        uint64 poolId,
        bytes16 scId,
        address asset,
        address shareToken
    ) external returns (address vault);

    /// @notice Compute vault address before deployment
    /// @dev Returns deterministic CREATE2 address.
    ///
    /// @param poolId Pool identifier
    /// @param scId Share class identifier
    /// @param asset Deposit asset address
    /// @return vault Predicted vault address
    function computeVaultAddress(
        uint64 poolId,
        bytes16 scId,
        address asset
    ) external view returns (address vault);

    // ============================================================
    // SHARE TOKEN DEPLOYMENT
    // ============================================================

    /// @notice Deploy a new ShareToken for a share class
    /// @dev One share token per pool/shareClass combination.
    ///
    /// @param poolId Pool identifier
    /// @param scId Share class identifier
    /// @param name Token name (e.g., "Riyzo Senior USDC")
    /// @param symbol Token symbol (e.g., "rzSR-USDC")
    /// @param hook Transfer restriction hook address
    /// @return shareToken Address of deployed ShareToken
    function deployShareToken(
        uint64 poolId,
        bytes16 scId,
        string calldata name,
        string calldata symbol,
        address hook
    ) external returns (address shareToken);

    // ============================================================
    // VAULT LIFECYCLE
    // ============================================================

    /// @notice Activate a vault for deposits and redemptions
    /// @dev Called after vault is fully configured.
    ///
    /// @param vault Vault address to activate
    function activateVault(address vault) external;

    /// @notice Deactivate a vault (emergency pause)
    /// @dev Prevents new deposits/redeems but allows claims.
    ///
    /// @param vault Vault address to deactivate
    function deactivateVault(address vault) external;

    /// @notice Fully remove a vault from the registry
    /// @dev Should only be used when vault is completely settled.
    ///
    /// @param vault Vault address to unlink
    function unlinkVault(address vault) external;

    // ============================================================
    // VIEW FUNCTIONS
    // ============================================================

    /// @notice Check if a vault is active
    /// @param vault Vault address
    /// @return active True if vault is active
    function isActiveVault(address vault) external view returns (bool active);

    /// @notice Get vault metadata
    /// @param vault Vault address
    /// @return metadata The VaultMetadata struct
    function getVaultInfo(address vault) external view returns (VaultMetadata memory metadata);

    /// @notice Get vault by pool/shareClass/asset
    /// @param poolId Pool identifier
    /// @param scId Share class identifier
    /// @param asset Deposit asset address
    /// @return vault Vault address (zero if not deployed)
    function getVault(
        uint64 poolId,
        bytes16 scId,
        address asset
    ) external view returns (address vault);

    /// @notice Get all vaults for a pool
    /// @param poolId Pool identifier
    /// @return vaults Array of vault addresses
    function getVaultsByPool(uint64 poolId) external view returns (address[] memory vaults);

    /// @notice Get all vaults for a share class
    /// @param poolId Pool identifier
    /// @param scId Share class identifier
    /// @return vaults Array of vault addresses
    function getVaultsByShareClass(
        uint64 poolId,
        bytes16 scId
    ) external view returns (address[] memory vaults);

    /// @notice Get share token for a share class
    /// @param poolId Pool identifier
    /// @param scId Share class identifier
    /// @return shareToken Share token address
    function getShareToken(
        uint64 poolId,
        bytes16 scId
    ) external view returns (address shareToken);

    /// @notice Get count of all deployed vaults
    /// @return count Total number of vaults
    function vaultCount() external view returns (uint256 count);

    // ============================================================
    // CONFIGURATION
    // ============================================================

    /// @notice Get the vault factory address
    /// @return factory VaultFactory address
    function vaultFactory() external view returns (address factory);

    /// @notice Get the tranche factory address
    /// @return factory TrancheFactory address
    function trancheFactory() external view returns (address factory);
}
