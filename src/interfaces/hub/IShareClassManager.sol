// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.28;

/// @title IShareClassManager - Share Class & Pricing Interface
/// @author Riyzo Protocol
/// @notice Interface for managing share classes, their pricing, and issuance tracking.
///         Think of share classes as different "flavors" of pool ownership (Senior, Junior).
/// @dev Each pool can have multiple share classes with different risk/return profiles.
///      This contract tracks pricing and how many shares exist across all networks.
///
/// KEY CONCEPTS:
/// - Share Class: A type of ownership in the pool (e.g., Senior Tranche, Junior Tranche)
/// - Price: Value of one share in pool currency (e.g., 1 share = $1.05)
/// - Issuance: How many shares have been created/destroyed on each network
/// - Total Supply: Sum of all issuances minus revocations across all networks
///
/// SENIOR VS JUNIOR TRANCHES:
/// - Senior: Gets paid first, lower risk, lower return
/// - Junior: Gets paid last, higher risk, higher return
/// - This manager tracks both, waterfall logic is in TrancheWaterfall.sol
///
/// EXAMPLE:
/// - Pool has 2 share classes: Senior (scId: 0x01) and Junior (scId: 0x02)
/// - Senior price: $1.02 per share (2% gain)
/// - Junior price: $1.10 per share (10% gain, but takes losses first)
/// - Ethereum network has 1000 Senior shares, 500 Junior shares
/// - Base network has 2000 Senior shares, 800 Junior shares
interface IShareClassManager {
    // ============================================================
    // STRUCTS
    // ============================================================

    /// @notice Metadata for a share class
    /// @dev Stored for UI display and deterministic deployment on spoke chains
    struct ShareClassMetadata {
        /// @notice Human-readable name (e.g., "Senior Tranche")
        string name;
        /// @notice Token symbol (e.g., "RIYZO-SR")
        string symbol;
        /// @notice Salt for deterministic CREATE2 deployment on spokes
        bytes32 salt;
    }

    /// @notice Price information for a share class
    /// @dev Price represents value of 1 share in pool currency
    struct Price {
        /// @notice Price per share (18 decimals)
        /// Example: $1.05 per share = 1050000000000000000
        uint128 price;
        /// @notice When this price was calculated
        /// Used for staleness checks
        uint64 computedAt;
    }

    /// @notice Tracks share issuance/revocation per network
    /// @dev Each spoke chain tracks its own issuance. Hub aggregates.
    struct IssuancePerNetwork {
        /// @notice Total shares ever issued on this network
        uint128 issuances;
        /// @notice Total shares ever revoked (burned) on this network
        uint128 revocations;
    }

    // ============================================================
    // EVENTS
    // ============================================================

    /// @notice Emitted when a new share class is created
    event ShareClassAdded(uint64 indexed poolId, bytes16 indexed scId, string name, string symbol);

    /// @notice Emitted when share class metadata is updated
    event ShareClassMetadataUpdated(uint64 indexed poolId, bytes16 indexed scId, string name, string symbol);

    /// @notice Emitted when share price is updated
    event SharePriceUpdated(uint64 indexed poolId, bytes16 indexed scId, uint128 price, uint64 computedAt);

    /// @notice Emitted when issuance tracking is updated
    event SharesUpdated(
        uint64 indexed poolId, bytes16 indexed scId, uint16 indexed centrifugeId, uint128 issuances, uint128 revocations
    );

    // ============================================================
    // ERRORS
    // ============================================================

    /// @notice Thrown when share class doesn't exist
    error ShareClassNotFound(uint64 poolId, bytes16 scId);

    /// @notice Thrown when share class already exists
    error ShareClassAlreadyExists(uint64 poolId, bytes16 scId);

    /// @notice Thrown when price timestamp is in the future
    error FuturePriceTimestamp(uint64 computedAt, uint64 currentTime);

    /// @notice Thrown when price would go backwards in time
    error StalePrice(uint64 newComputedAt, uint64 existingComputedAt);

    // ============================================================
    // STATE-CHANGING FUNCTIONS
    // ============================================================

    /// @notice Create a new share class for a pool
    /// @dev Share class IDs are derived from pool ID and an auto-incrementing index.
    ///
    /// WHAT THIS DOES:
    /// - Generates a unique share class ID
    /// - Stores metadata (name, symbol, salt)
    /// - Initializes price to 0 (must be set via updateSharePrice)
    ///
    /// @param poolId Which pool to add the share class to
    /// @param name Human-readable name (e.g., "Senior Tranche")
    /// @param symbol Token symbol (e.g., "RIYZO-SR")
    /// @param salt Deployment salt for deterministic addresses on spokes
    /// @return scId The generated share class ID
    function addShareClass(uint64 poolId, string calldata name, string calldata symbol, bytes32 salt)
        external
        returns (bytes16 scId);

    /// @notice Update the metadata for a share class
    /// @dev Used to rename or rebrand share classes
    ///
    /// @param poolId Pool identifier
    /// @param scId Share class identifier
    /// @param name New name
    /// @param symbol New symbol
    function updateMetadata(uint64 poolId, bytes16 scId, string calldata name, string calldata symbol) external;

    /// @notice Update the price per share
    /// @dev Called after NAV calculation to set new share prices.
    ///      Price = NAV / Total Supply for this share class.
    ///
    /// WHAT THIS DOES:
    /// - Validates timestamp is not in the future
    /// - Validates timestamp is not older than existing price
    /// - Stores new price and timestamp
    ///
    /// EXAMPLE:
    /// - Pool NAV for Senior class: $102,000
    /// - Total Senior shares: 100,000
    /// - New price: $1.02 per share (102000/100000)
    ///
    /// @param poolId Pool identifier
    /// @param scId Share class identifier
    /// @param price New price per share (18 decimals)
    /// @param computedAt Timestamp when price was calculated
    function updateSharePrice(uint64 poolId, bytes16 scId, uint128 price, uint64 computedAt) external;

    /// @notice Update issuance tracking for a network
    /// @dev Called when hub receives share mint/burn updates from spokes.
    ///      Tracks cumulative issuances and revocations separately.
    ///
    /// WHAT THIS DOES:
    /// - Adds to cumulative issuance count
    /// - Adds to cumulative revocation count
    /// - Net supply = issuances - revocations
    ///
    /// @param poolId Pool identifier
    /// @param scId Share class identifier
    /// @param centrifugeId Network identifier (e.g., 1 for Ethereum mainnet)
    /// @param issuances Additional shares issued on this network
    /// @param revocations Additional shares revoked on this network
    function updateShares(uint64 poolId, bytes16 scId, uint16 centrifugeId, uint128 issuances, uint128 revocations)
        external;

    // ============================================================
    // VIEW FUNCTIONS
    // ============================================================

    /// @notice Get metadata for a share class
    /// @param poolId Pool identifier
    /// @param scId Share class identifier
    /// @return metadata The ShareClassMetadata struct
    function getMetadata(uint64 poolId, bytes16 scId) external view returns (ShareClassMetadata memory metadata);

    /// @notice Get the current price for a share class
    /// @param poolId Pool identifier
    /// @param scId Share class identifier
    /// @return price The Price struct with price and computedAt
    function getPrice(uint64 poolId, bytes16 scId) external view returns (Price memory price);

    /// @notice Get just the price value (gas-efficient)
    /// @param poolId Pool identifier
    /// @param scId Share class identifier
    /// @return price Price per share (18 decimals)
    /// @return computedAt Timestamp of price calculation
    function pricePerShare(uint64 poolId, bytes16 scId) external view returns (uint128 price, uint64 computedAt);

    /// @notice Get issuance data for a specific network
    /// @param poolId Pool identifier
    /// @param scId Share class identifier
    /// @param centrifugeId Network identifier
    /// @return issuanceData The IssuancePerNetwork struct
    function getIssuancePerNetwork(uint64 poolId, bytes16 scId, uint16 centrifugeId)
        external
        view
        returns (IssuancePerNetwork memory issuanceData);

    /// @notice Get net issuance for a network (issuances - revocations)
    /// @dev This is the current supply on that specific network
    /// @param poolId Pool identifier
    /// @param scId Share class identifier
    /// @param centrifugeId Network identifier
    /// @return netIssuance Current supply on this network
    function issuance(uint64 poolId, bytes16 scId, uint16 centrifugeId) external view returns (uint128 netIssuance);

    /// @notice Get total supply across all networks
    /// @dev Sums net issuance from all registered networks
    /// @param poolId Pool identifier
    /// @param scId Share class identifier
    /// @return totalSupply Sum of all network issuances minus revocations
    function totalIssuance(uint64 poolId, bytes16 scId) external view returns (uint128 totalSupply);

    /// @notice Check if a share class exists
    /// @param poolId Pool identifier
    /// @param scId Share class identifier
    /// @return exists True if share class has been added
    function shareClassExists(uint64 poolId, bytes16 scId) external view returns (bool exists);

    /// @notice Get the number of share classes for a pool
    /// @param poolId Pool identifier
    /// @return count Number of share classes
    function shareClassCount(uint64 poolId) external view returns (uint256 count);

    /// @notice Get all share class IDs for a pool
    /// @param poolId Pool identifier
    /// @return scIds Array of share class IDs
    function getShareClassIds(uint64 poolId) external view returns (bytes16[] memory scIds);

    /// @notice Get list of networks that have issuance for a share class
    /// @dev Useful for iterating over all networks with shares
    /// @param poolId Pool identifier
    /// @param scId Share class identifier
    /// @return networks Array of network IDs (centrifugeIds)
    function getActiveNetworks(uint64 poolId, bytes16 scId) external view returns (uint16[] memory networks);
}
