// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.28;

import {Auth} from "src/core/Auth.sol";
import {IVaultRegistry} from "src/interfaces/spoke/IVaultRegistry.sol";
import {IERC7540VaultFactory} from "src/interfaces/factories/IERC7540VaultFactory.sol";
import {ITrancheFactory} from "src/interfaces/factories/ITrancheFactory.sol";

/// @title VaultRegistry - Vault Lifecycle Management
/// @author Riyzo Protocol
/// @notice Manages vault deployment and lifecycle on spoke chains.
///         Tracks all vaults and their relationships to pools, share classes, and assets.
/// @dev VaultRegistry is responsible for:
/// - Deploying vaults via ERC7540VaultFactory (CREATE2 for deterministic addresses)
/// - Deploying share tokens via TrancheFactory
/// - Tracking vault metadata and state
/// - Managing vault activation/deactivation
///
/// DEPLOYMENT FLOW:
/// 1. Hub sends AddTranche -> VaultRegistry.deployShareToken()
/// 2. Hub sends AllowAsset -> VaultRegistry.deployVault()
/// 3. Vault is activated when ready for user deposits
contract VaultRegistry is Auth, IVaultRegistry {
    // ============================================================
    // STATE
    // ============================================================

    /// @notice Vault factory for deploying ERC7540Vaults
    address public vaultFactory;

    /// @notice Tranche factory for deploying ShareTokens
    address public trancheFactory;

    /// @notice Root contract address (for vault admin setup)
    address public immutable root;

    /// @notice Escrow contract address (for vault setup)
    address public immutable escrow;

    /// @notice Investment manager address (for vault setup)
    address public investmentManager;

    /// @notice Vault metadata by vault address
    mapping(address => VaultMetadata) internal _vaultInfo;

    /// @notice Vault address by vaultId (keccak256(poolId, scId, asset))
    mapping(bytes32 => address) internal _vaultAddress;

    /// @notice Share token by pool/shareClass
    mapping(uint64 => mapping(bytes16 => address)) internal _shareTokens;

    /// @notice All vaults for a pool
    mapping(uint64 => address[]) internal _poolVaults;

    /// @notice All vaults for a pool/shareClass
    mapping(uint64 => mapping(bytes16 => address[])) internal _shareClassVaults;

    /// @notice Total vault count
    uint256 internal _vaultCount;

    // ============================================================
    // CONSTRUCTOR
    // ============================================================

    /// @param deployer Initial ward address
    /// @param root_ Root contract address
    /// @param escrow_ Escrow contract address
    constructor(address deployer, address root_, address escrow_) Auth(deployer) {
        require(root_ != address(0), "VaultRegistry/zero-root");
        require(escrow_ != address(0), "VaultRegistry/zero-escrow");
        root = root_;
        escrow = escrow_;
    }

    // ============================================================
    // CONFIGURATION
    // ============================================================

    /// @notice Set configuration values
    /// @param what Configuration key
    /// @param data Address value
    function file(bytes32 what, address data) external auth {
        if (what == "vaultFactory") {
            vaultFactory = data;
            emit VaultFactorySet(vaultFactory, data);
        } else if (what == "trancheFactory") {
            trancheFactory = data;
            emit TrancheFactorySet(trancheFactory, data);
        } else if (what == "investmentManager") {
            investmentManager = data;
        } else {
            revert("VaultRegistry/file-unrecognized-param");
        }
    }

    // ============================================================
    // VAULT DEPLOYMENT
    // ============================================================

    /// @inheritdoc IVaultRegistry
    function deployVault(
        uint64 poolId,
        bytes16 scId,
        address asset,
        address shareToken
    ) external auth returns (address vault) {
        if (vaultFactory == address(0)) revert FactoryNotSet("vaultFactory");

        bytes32 vaultId = _computeVaultId(poolId, scId, asset);
        if (_vaultAddress[vaultId] != address(0)) revert VaultAlreadyExists(vaultId);

        // Build wards array for vault
        address[] memory wards = new address[](1);
        wards[0] = address(this);

        vault = IERC7540VaultFactory(vaultFactory).newVault(
            poolId,
            scId,
            asset,
            shareToken,
            escrow,
            investmentManager,
            wards
        );

        // Store metadata
        _vaultInfo[vault] = VaultMetadata({
            poolId: poolId,
            scId: scId,
            asset: asset,
            shareToken: shareToken,
            isActive: false,
            deployedAt: uint64(block.timestamp)
        });

        _vaultAddress[vaultId] = vault;
        _poolVaults[poolId].push(vault);
        _shareClassVaults[poolId][scId].push(vault);
        _vaultCount++;

        emit VaultDeployed(vault, poolId, scId, asset, shareToken);
    }

    /// @inheritdoc IVaultRegistry
    function computeVaultAddress(
        uint64 poolId,
        bytes16 scId,
        address asset
    ) external view returns (address) {
        bytes32 vaultId = _computeVaultId(poolId, scId, asset);
        return _vaultAddress[vaultId];
    }

    // ============================================================
    // SHARE TOKEN DEPLOYMENT
    // ============================================================

    /// @inheritdoc IVaultRegistry
    function deployShareToken(
        uint64 poolId,
        bytes16 scId,
        string calldata name,
        string calldata symbol,
        address hook
    ) external auth returns (address shareToken) {
        if (trancheFactory == address(0)) revert FactoryNotSet("trancheFactory");
        if (_shareTokens[poolId][scId] != address(0)) revert ShareTokenAlreadyExists(poolId, scId);

        // Build wards array including hook if provided
        address[] memory wards;
        if (hook != address(0)) {
            wards = new address[](2);
            wards[0] = address(this);
            wards[1] = hook;
        } else {
            wards = new address[](1);
            wards[0] = address(this);
        }

        // Deploy with 18 decimals (standard for share tokens)
        shareToken = ITrancheFactory(trancheFactory).newTranche(poolId, scId, name, symbol, 18, wards);

        _shareTokens[poolId][scId] = shareToken;

        emit ShareTokenDeployed(shareToken, poolId, scId, name, symbol);
    }

    // ============================================================
    // VAULT LIFECYCLE
    // ============================================================

    /// @inheritdoc IVaultRegistry
    function activateVault(address vault) external auth {
        VaultMetadata storage info = _vaultInfo[vault];
        if (info.deployedAt == 0) revert VaultNotFound(vault);
        if (info.isActive) revert VaultAlreadyActive(vault);

        info.isActive = true;
        emit VaultActivated(vault);
    }

    /// @inheritdoc IVaultRegistry
    function deactivateVault(address vault) external auth {
        VaultMetadata storage info = _vaultInfo[vault];
        if (info.deployedAt == 0) revert VaultNotFound(vault);
        if (!info.isActive) revert VaultNotActive(vault);

        info.isActive = false;
        emit VaultDeactivated(vault);
    }

    /// @inheritdoc IVaultRegistry
    function unlinkVault(address vault) external auth {
        VaultMetadata storage info = _vaultInfo[vault];
        if (info.deployedAt == 0) revert VaultNotFound(vault);

        bytes32 vaultId = _computeVaultId(info.poolId, info.scId, info.asset);
        delete _vaultAddress[vaultId];
        delete _vaultInfo[vault];

        // Note: We don't remove from arrays to avoid gas-expensive operations
        // The isActive check should be used to determine if vault is usable

        emit VaultUnlinked(vault);
    }

    // ============================================================
    // VIEW FUNCTIONS
    // ============================================================

    /// @inheritdoc IVaultRegistry
    function isActiveVault(address vault) external view returns (bool) {
        return _vaultInfo[vault].isActive;
    }

    /// @inheritdoc IVaultRegistry
    function getVaultInfo(address vault) external view returns (VaultMetadata memory) {
        return _vaultInfo[vault];
    }

    /// @inheritdoc IVaultRegistry
    function getVault(
        uint64 poolId,
        bytes16 scId,
        address asset
    ) external view returns (address) {
        bytes32 vaultId = _computeVaultId(poolId, scId, asset);
        return _vaultAddress[vaultId];
    }

    /// @inheritdoc IVaultRegistry
    function getVaultsByPool(uint64 poolId) external view returns (address[] memory) {
        return _poolVaults[poolId];
    }

    /// @inheritdoc IVaultRegistry
    function getVaultsByShareClass(
        uint64 poolId,
        bytes16 scId
    ) external view returns (address[] memory) {
        return _shareClassVaults[poolId][scId];
    }

    /// @inheritdoc IVaultRegistry
    function getShareToken(
        uint64 poolId,
        bytes16 scId
    ) external view returns (address) {
        return _shareTokens[poolId][scId];
    }

    /// @inheritdoc IVaultRegistry
    function vaultCount() external view returns (uint256) {
        return _vaultCount;
    }

    // ============================================================
    // INTERNAL
    // ============================================================

    /// @dev Compute deterministic vault ID
    function _computeVaultId(uint64 poolId, bytes16 scId, address asset) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(poolId, scId, asset));
    }
}
