// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.28;

import {Auth} from "src/core/Auth.sol";
import {IShareClassManager} from "src/interfaces/hub/IShareClassManager.sol";

/// @title ShareClassManager - Share Class & Pricing Manager
/// @author Riyzo Protocol
/// @notice This contract manages share classes, their pricing, and issuance tracking.
///         Think of share classes as different "flavors" of pool ownership.
/// @dev Each pool can have multiple share classes with different risk/return profiles.
///      This contract tracks pricing and how many shares exist across all networks.
///
/// ============================================================
/// KEY CONCEPTS FOR EVERYONE
/// ============================================================
///
/// WHAT IS A SHARE CLASS?
/// A share class represents a type of ownership in a pool. Different share classes
/// have different risk/return profiles. Common examples:
///
/// - SENIOR TRANCHE: Lower risk, lower return
///   - Gets paid FIRST when pool makes money
///   - Takes losses LAST when pool loses money
///   - Like a bond - more predictable returns
///
/// - JUNIOR TRANCHE: Higher risk, higher return
///   - Gets paid LAST when pool makes money
///   - Takes losses FIRST when pool loses money
///   - Like equity - more volatile but higher upside
///
/// EXAMPLE:
/// Pool has $100,000 in assets, two share classes:
/// - Senior: $80,000 (80% of pool) - expects 5% return
/// - Junior: $20,000 (20% of pool) - gets remaining returns
///
/// If pool makes $10,000:
/// - Senior gets $4,000 (5% of $80,000)
/// - Junior gets $6,000 (30% return on $20,000!)
///
/// If pool loses $15,000:
/// - Junior absorbs first $20,000 of losses -> loses everything
/// - Senior is protected (no loss yet)
///
/// ============================================================
/// SHARE CLASS PRICING
/// ============================================================
///
/// Each share class has a PRICE PER SHARE that changes over time.
///
/// PRICE CALCULATION:
/// Price = NAV of Share Class / Total Shares Outstanding
///
/// EXAMPLE:
/// - Share class NAV: $102,000
/// - Total shares: 100,000
/// - Price per share: $1.02
///
/// WHY TRACK PRICE?
/// - Investors need to know what their shares are worth
/// - New deposits convert to shares at current price
/// - Redemptions convert shares back to assets at current price
///
/// ============================================================
/// ISSUANCE TRACKING
/// ============================================================
///
/// Shares exist on multiple networks (Ethereum, Base, etc.).
/// We track issuance per network to:
/// - Know total supply across all chains
/// - Allocate NAV fairly per network
/// - Handle cross-chain transfers correctly
///
/// ISSUANCE vs REVOCATION:
/// - Issuance: Shares created (when someone deposits)
/// - Revocation: Shares destroyed (when someone redeems)
/// - Net Supply = Total Issuances - Total Revocations
///
/// EXAMPLE:
/// Ethereum:
///   - Issuances: 50,000 shares (from deposits)
///   - Revocations: 5,000 shares (from redemptions)
///   - Net: 45,000 shares on Ethereum
///
/// Base:
///   - Issuances: 30,000 shares
///   - Revocations: 2,000 shares
///   - Net: 28,000 shares on Base
///
/// Total Supply: 45,000 + 28,000 = 73,000 shares
///
/// ============================================================
/// SHARE CLASS ID GENERATION
/// ============================================================
///
/// Each share class gets a unique 16-byte (bytes16) identifier.
/// The ID is derived from the pool ID and an incrementing counter.
///
/// This ensures:
/// - IDs are unique within a pool
/// - IDs are deterministic (same inputs = same output)
/// - IDs can be used for CREATE2 deployment on spoke chains
///
contract ShareClassManager is Auth, IShareClassManager {
    // ============================================================
    // STORAGE
    // ============================================================

    /// @notice Metadata for each share class
    /// @dev metadata[poolId][scId] => ShareClassMetadata
    mapping(uint64 => mapping(bytes16 => ShareClassMetadata)) internal _metadata;

    /// @notice Price data for each share class
    /// @dev prices[poolId][scId] => Price
    mapping(uint64 => mapping(bytes16 => Price)) internal _prices;

    /// @notice Issuance tracking per network
    /// @dev issuancePerNetwork[poolId][scId][centrifugeId] => IssuancePerNetwork
    mapping(uint64 => mapping(bytes16 => mapping(uint16 => IssuancePerNetwork))) internal _issuancePerNetwork;

    /// @notice Tracks which share classes exist
    /// @dev exists[poolId][scId] => bool
    mapping(uint64 => mapping(bytes16 => bool)) internal _exists;

    /// @notice Counter for generating share class IDs
    /// @dev shareClassCount[poolId] => count (starts at 0)
    mapping(uint64 => uint256) internal _shareClassCount;

    /// @notice List of share class IDs per pool (for enumeration)
    /// @dev shareClassIds[poolId] => bytes16[]
    mapping(uint64 => bytes16[]) internal _shareClassIds;

    /// @notice List of networks that have issuance for a share class
    /// @dev Used to calculate total issuance across all networks
    mapping(uint64 => mapping(bytes16 => uint16[])) internal _activeNetworks;

    /// @notice Tracks if a network has been added to activeNetworks
    mapping(uint64 => mapping(bytes16 => mapping(uint16 => bool))) internal _networkAdded;

    // ============================================================
    // CONSTRUCTOR
    // ============================================================

    /// @notice Initialize the ShareClassManager contract
    /// @param initialWard Address that will have admin rights
    constructor(address initialWard) Auth(initialWard) {}

    // ============================================================
    // SHARE CLASS MANAGEMENT
    // ============================================================

    /// @inheritdoc IShareClassManager
    /// @dev Creates a new share class for a pool.
    ///
    /// HOW IT WORKS:
    /// 1. Increment the share class counter for this pool
    /// 2. Generate unique ID from pool ID + counter
    /// 3. Store metadata (name, symbol, salt)
    /// 4. Mark as existing
    /// 5. Add to enumeration list
    ///
    /// SHARE CLASS ID GENERATION:
    /// scId = bytes16(keccak256(poolId, counter))
    /// This creates a deterministic, unique identifier.
    function addShareClass(uint64 poolId, string calldata name, string calldata symbol, bytes32 salt)
        external
        auth
        returns (bytes16 scId)
    {
        // ============================================================
        // STEP 1: Generate unique share class ID
        // ============================================================
        // Increment counter first (so first share class uses index 1)
        uint256 index = ++_shareClassCount[poolId];

        // Generate ID by hashing pool ID and index
        // This ensures uniqueness within the pool
        scId = bytes16(keccak256(abi.encodePacked(poolId, index)));

        // ============================================================
        // STEP 2: Verify share class doesn't exist (shouldn't happen, but be safe)
        // ============================================================
        if (_exists[poolId][scId]) {
            revert ShareClassAlreadyExists(poolId, scId);
        }

        // ============================================================
        // STEP 3: Store metadata
        // ============================================================
        _metadata[poolId][scId] = ShareClassMetadata({name: name, symbol: symbol, salt: salt});

        // ============================================================
        // STEP 4: Initialize price to zero
        // ============================================================
        // Price must be set via updateSharePrice before the share class can be used
        _prices[poolId][scId] = Price({price: 0, computedAt: 0});

        // ============================================================
        // STEP 5: Mark as existing and add to enumeration
        // ============================================================
        _exists[poolId][scId] = true;
        _shareClassIds[poolId].push(scId);

        emit ShareClassAdded(poolId, scId, name, symbol);

        return scId;
    }

    /// @inheritdoc IShareClassManager
    /// @dev Updates the name and symbol for a share class.
    /// Used when rebranding or fixing typos.
    function updateMetadata(uint64 poolId, bytes16 scId, string calldata name, string calldata symbol) external auth {
        // ============================================================
        // STEP 1: Verify share class exists
        // ============================================================
        if (!_exists[poolId][scId]) {
            revert ShareClassNotFound(poolId, scId);
        }

        // ============================================================
        // STEP 2: Update metadata (keep existing salt)
        // ============================================================
        ShareClassMetadata storage metadata = _metadata[poolId][scId];
        metadata.name = name;
        metadata.symbol = symbol;
        // Note: salt is NOT updated - it's used for deterministic deployment

        emit ShareClassMetadataUpdated(poolId, scId, name, symbol);
    }

    // ============================================================
    // PRICE MANAGEMENT
    // ============================================================

    /// @inheritdoc IShareClassManager
    /// @dev Updates the price per share for a share class.
    ///
    /// WHEN IS THIS CALLED?
    /// After epoch execution, when new NAV is calculated:
    /// 1. NAVManager calculates new NAV for share class
    /// 2. Divide by total issuance to get price
    /// 3. Call updateSharePrice with new price
    ///
    /// PRICE VALIDATION:
    /// - Timestamp cannot be in the future
    /// - Timestamp cannot be older than existing price
    /// - This prevents stale/manipulated price updates
    ///
    /// EXAMPLE:
    /// - NAV: $102,000
    /// - Total shares: 100,000
    /// - Price: $1.02 = 1020000000000000000 (18 decimals)
    function updateSharePrice(uint64 poolId, bytes16 scId, uint128 price, uint64 computedAt) external auth {
        // ============================================================
        // STEP 1: Verify share class exists
        // ============================================================
        if (!_exists[poolId][scId]) {
            revert ShareClassNotFound(poolId, scId);
        }

        // ============================================================
        // STEP 2: Validate timestamp is not in the future
        // ============================================================
        // Can't have a price computed in the future!
        if (computedAt > block.timestamp) {
            revert FuturePriceTimestamp(computedAt, uint64(block.timestamp));
        }

        // ============================================================
        // STEP 3: Validate timestamp is not stale
        // ============================================================
        // New price must be newer than existing price
        // This prevents replaying old prices
        Price storage currentPrice = _prices[poolId][scId];
        if (computedAt < currentPrice.computedAt) {
            revert StalePrice(computedAt, currentPrice.computedAt);
        }

        // ============================================================
        // STEP 4: Update price
        // ============================================================
        currentPrice.price = price;
        currentPrice.computedAt = computedAt;

        emit SharePriceUpdated(poolId, scId, price, computedAt);
    }

    // ============================================================
    // ISSUANCE TRACKING
    // ============================================================

    /// @inheritdoc IShareClassManager
    /// @dev Updates issuance tracking for a specific network.
    ///
    /// WHEN IS THIS CALLED?
    /// When hub receives share mint/burn updates from spokes:
    /// - User deposits on Ethereum -> spoke mints shares -> hub updates issuance
    /// - User redeems on Base -> spoke burns shares -> hub updates revocations
    ///
    /// WHY CUMULATIVE?
    /// We track cumulative totals (not deltas) because:
    /// - Easier to reconcile across chains
    /// - Can detect missing updates
    /// - Net supply = issuances - revocations
    ///
    /// EXAMPLE:
    /// Network already has: issuances=50000, revocations=5000
    /// New deposit mints 1000 shares
    /// Call: updateShares(poolId, scId, networkId, 1000, 0)
    /// Result: issuances=51000, revocations=5000
    function updateShares(uint64 poolId, bytes16 scId, uint16 centrifugeId, uint128 issuances, uint128 revocations)
        external
        auth
    {
        // ============================================================
        // STEP 1: Verify share class exists
        // ============================================================
        if (!_exists[poolId][scId]) {
            revert ShareClassNotFound(poolId, scId);
        }

        // ============================================================
        // STEP 2: Track active networks (for total supply calculation)
        // ============================================================
        // If this network hasn't been seen before, add to active list
        if (!_networkAdded[poolId][scId][centrifugeId]) {
            _activeNetworks[poolId][scId].push(centrifugeId);
            _networkAdded[poolId][scId][centrifugeId] = true;
        }

        // ============================================================
        // STEP 3: Update issuance tracking
        // ============================================================
        // Add to cumulative totals (not replace)
        IssuancePerNetwork storage networkIssuance = _issuancePerNetwork[poolId][scId][centrifugeId];
        networkIssuance.issuances += issuances;
        networkIssuance.revocations += revocations;

        emit SharesUpdated(poolId, scId, centrifugeId, networkIssuance.issuances, networkIssuance.revocations);
    }

    // ============================================================
    // VIEW FUNCTIONS - METADATA
    // ============================================================

    /// @inheritdoc IShareClassManager
    function getMetadata(uint64 poolId, bytes16 scId) external view returns (ShareClassMetadata memory metadata) {
        if (!_exists[poolId][scId]) {
            revert ShareClassNotFound(poolId, scId);
        }
        return _metadata[poolId][scId];
    }

    // ============================================================
    // VIEW FUNCTIONS - PRICING
    // ============================================================

    /// @inheritdoc IShareClassManager
    function getPrice(uint64 poolId, bytes16 scId) external view returns (Price memory price) {
        if (!_exists[poolId][scId]) {
            revert ShareClassNotFound(poolId, scId);
        }
        return _prices[poolId][scId];
    }

    /// @inheritdoc IShareClassManager
    function pricePerShare(uint64 poolId, bytes16 scId) external view returns (uint128 price, uint64 computedAt) {
        if (!_exists[poolId][scId]) {
            revert ShareClassNotFound(poolId, scId);
        }
        Price storage p = _prices[poolId][scId];
        return (p.price, p.computedAt);
    }

    // ============================================================
    // VIEW FUNCTIONS - ISSUANCE
    // ============================================================

    /// @inheritdoc IShareClassManager
    function getIssuancePerNetwork(uint64 poolId, bytes16 scId, uint16 centrifugeId)
        external
        view
        returns (IssuancePerNetwork memory issuanceData)
    {
        if (!_exists[poolId][scId]) {
            revert ShareClassNotFound(poolId, scId);
        }
        return _issuancePerNetwork[poolId][scId][centrifugeId];
    }

    /// @inheritdoc IShareClassManager
    /// @dev Returns net issuance for a single network.
    /// Net = Issuances - Revocations
    function issuance(uint64 poolId, bytes16 scId, uint16 centrifugeId) external view returns (uint128 netIssuance) {
        if (!_exists[poolId][scId]) {
            revert ShareClassNotFound(poolId, scId);
        }
        IssuancePerNetwork storage networkIssuance = _issuancePerNetwork[poolId][scId][centrifugeId];

        // Net issuance = total issued - total revoked
        // Should never underflow if accounting is correct
        if (networkIssuance.issuances >= networkIssuance.revocations) {
            return networkIssuance.issuances - networkIssuance.revocations;
        }
        return 0; // Safety: return 0 if somehow revocations > issuances
    }

    /// @inheritdoc IShareClassManager
    /// @dev Returns total supply across ALL networks.
    ///
    /// HOW IT WORKS:
    /// 1. Iterate through all networks that have issuance
    /// 2. Sum up (issuances - revocations) for each
    /// 3. Return total
    ///
    /// GAS NOTE:
    /// This loops through all active networks. For pools with many
    /// networks, consider caching the total.
    function totalIssuance(uint64 poolId, bytes16 scId) external view returns (uint128 totalSupply) {
        if (!_exists[poolId][scId]) {
            revert ShareClassNotFound(poolId, scId);
        }

        // ============================================================
        // Sum issuance across all active networks
        // ============================================================
        uint16[] storage networks = _activeNetworks[poolId][scId];
        uint256 len = networks.length;

        for (uint256 i = 0; i < len;) {
            uint16 networkId = networks[i];
            IssuancePerNetwork storage networkIssuance = _issuancePerNetwork[poolId][scId][networkId];

            // Add net issuance from this network
            if (networkIssuance.issuances >= networkIssuance.revocations) {
                totalSupply += networkIssuance.issuances - networkIssuance.revocations;
            }

            unchecked {
                ++i;
            }
        }

        return totalSupply;
    }

    // ============================================================
    // VIEW FUNCTIONS - EXISTENCE & ENUMERATION
    // ============================================================

    /// @inheritdoc IShareClassManager
    function shareClassExists(uint64 poolId, bytes16 scId) external view returns (bool exists) {
        return _exists[poolId][scId];
    }

    /// @inheritdoc IShareClassManager
    function shareClassCount(uint64 poolId) external view returns (uint256 count) {
        return _shareClassCount[poolId];
    }

    /// @inheritdoc IShareClassManager
    function getShareClassIds(uint64 poolId) external view returns (bytes16[] memory scIds) {
        return _shareClassIds[poolId];
    }

    // ============================================================
    // ADDITIONAL VIEW FUNCTIONS
    // ============================================================

    /// @notice Get list of networks that have issuance for a share class
    /// @dev Useful for iterating over all networks with shares
    /// @param poolId Pool identifier
    /// @param scId Share class identifier
    /// @return networks Array of network IDs (centrifugeIds)
    function getActiveNetworks(uint64 poolId, bytes16 scId) external view returns (uint16[] memory networks) {
        if (!_exists[poolId][scId]) {
            revert ShareClassNotFound(poolId, scId);
        }
        return _activeNetworks[poolId][scId];
    }
}
