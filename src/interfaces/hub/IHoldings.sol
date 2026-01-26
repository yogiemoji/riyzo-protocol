// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.28;

import {IValuation} from "src/interfaces/hub/IValuation.sol";

/// @title IHoldings - Pool Holdings Tracker Interface
/// @author Riyzo Protocol
/// @notice Interface for tracking all assets and liabilities held by each pool.
///         Think of it as a "warehouse inventory" for the pool's investments.
/// @dev Implements double-entry linkage with Accounting.sol for financial integrity.
///      Each holding tracks both quantity (how many tokens) and value (worth in currency).
///
/// KEY CONCEPTS:
/// - Holding: A single asset position (e.g., "Pool #1 holds 1000 USDC")
/// - Valuation: How we price the asset (oracle, manual, formula)
/// - Snapshot: Sync checkpoint between hub and spoke chains
/// - HoldingAccount: Links a holding to its accounting entries
///
/// WHY TRACK BOTH AMOUNT AND VALUE?
/// - Amount: Physical tokens we hold (doesn't change unless deposit/withdraw)
/// - Value: What those tokens are worth (changes when prices change)
/// - Example: Hold 1 ETH, bought at $2000, now worth $2500
///   - amount = 1e18 (unchanged)
///   - value = 2500e18 (updated via update())
///
/// EXAMPLE FLOW:
/// 1. User deposits 1000 USDC on Ethereum (spoke)
/// 2. Message arrives here on Arbitrum (hub)
/// 3. We call increase() to add 1000 USDC to pool holdings
/// 4. Accounting.sol records matching debit/credit entries
/// 5. Later, update() revalues holdings if prices changed
interface IHoldings {
    // ============================================================
    // STRUCTS
    // ============================================================

    /// @notice Represents a single asset holding in a pool
    /// @dev Used to track both quantity and value separately.
    ///      We track value separately because prices change over time.
    ///
    /// EXAMPLE:
    /// - Pool buys 1 ETH at $2000 -> amount=1e18, value=2000e18
    /// - ETH price rises to $2500 -> amount=1e18, value=2500e18 (after update)
    struct Holding {
        /// @notice How many tokens we hold (in token's native decimals)
        /// Example: 1.5 ETH = 1500000000000000000 (1.5e18)
        uint128 assetAmount;
        /// @notice Current value in pool currency (always 18 decimals)
        /// Example: 1.5 ETH worth $3000 = 3000000000000000000000 (3000e18)
        uint128 assetAmountValue;
        /// @notice Contract that tells us current price
        /// Different assets use different valuation methods (oracle, manual, etc.)
        IValuation valuation;
        /// @notice True if this is money we OWE (liability), false if we OWN (asset)
        /// Example: Asset = USDC in vault, Liability = borrowed funds
        bool isLiability;
    }

    /// @notice Tracks synchronization state between hub and spoke chains
    /// @dev Used to prevent stale pricing when chains are out of sync
    struct Snapshot {
        /// @notice True if hub and spoke are in sync for this share class + network
        bool isSnapshot;
        /// @notice Version number - increments each time sync completes
        uint64 nonce;
    }

    /// @notice Links a holding to its accounting accounts
    /// @dev Each holding needs multiple accounts for proper double-entry:
    ///      - Asset holdings: asset, equity, gain, loss accounts
    ///      - Liability holdings: expense, liability accounts
    struct HoldingAccount {
        /// @notice The account ID in the Accounting contract
        bytes32 accountId;
        /// @notice What type of account this is (for validation)
        uint8 accountType;
    }

    // ============================================================
    // EVENTS
    // ============================================================

    /// @notice Emitted when a new holding is initialized
    event HoldingInitialized(
        uint64 indexed poolId, bytes16 indexed scId, uint128 indexed assetId, address valuation, bool isLiability
    );

    /// @notice Emitted when holding amount/value increases
    event HoldingIncreased(
        uint64 indexed poolId, bytes16 indexed scId, uint128 indexed assetId, uint128 amount, uint128 value
    );

    /// @notice Emitted when holding amount/value decreases
    event HoldingDecreased(
        uint64 indexed poolId, bytes16 indexed scId, uint128 indexed assetId, uint128 amount, uint128 value
    );

    /// @notice Emitted when holding is revalued (price change)
    event HoldingUpdated(
        uint64 indexed poolId, bytes16 indexed scId, uint128 indexed assetId, bool isPositive, uint128 valueDiff
    );

    /// @notice Emitted when snapshot state changes
    event SnapshotSet(uint64 indexed poolId, bytes16 indexed scId, uint16 indexed centrifugeId, bool isSnapshot, uint64 nonce);

    /// @notice Emitted when valuation method is changed
    event ValuationUpdated(uint64 indexed poolId, bytes16 indexed scId, uint128 indexed assetId, address newValuation);

    // ============================================================
    // ERRORS
    // ============================================================

    /// @notice Thrown when trying to operate on uninitialized holding
    error HoldingNotInitialized(uint64 poolId, bytes16 scId, uint128 assetId);

    /// @notice Thrown when trying to initialize an existing holding
    error HoldingAlreadyExists(uint64 poolId, bytes16 scId, uint128 assetId);

    /// @notice Thrown when decrease amount exceeds current holding
    error InsufficientHolding(uint128 requested, uint128 available);

    /// @notice Thrown when valuation address is invalid
    error InvalidValuation(address valuation);

    // ============================================================
    // STATE-CHANGING FUNCTIONS
    // ============================================================

    /// @notice Initialize a new holding for a pool
    /// @dev Must be called before increase/decrease. Sets up valuation and
    ///      links to accounting accounts.
    ///
    /// WHAT THIS DOES:
    /// - Creates a new holding entry with zero amount/value
    /// - Associates it with a valuation contract for pricing
    /// - Links it to accounting accounts for double-entry
    ///
    /// @param poolId Which pool to add the holding to
    /// @param scId Which share class (e.g., "Senior" vs "Junior")
    /// @param assetId The asset being held (e.g., USDC = 1)
    /// @param valuation Contract that provides pricing for this asset
    /// @param isLiability True if this is a liability, false if asset
    /// @param accounts Array of linked accounting accounts
    function initialize(
        uint64 poolId,
        bytes16 scId,
        uint128 assetId,
        IValuation valuation,
        bool isLiability,
        HoldingAccount[] calldata accounts
    ) external;

    /// @notice Add assets to a pool's holdings
    /// @dev Called when deposits arrive from spoke chains. Updates both
    ///      the physical quantity AND the value in pool currency.
    ///
    /// WHAT THIS DOES:
    /// - Increases the asset count (e.g., +1000 USDC)
    /// - Increases the value (e.g., +1000 USD worth)
    /// - Triggers accounting entries via linked accounts
    ///
    /// @param poolId Which pool to update
    /// @param scId Share class ID
    /// @param assetId The asset being added
    /// @param amount How many tokens to add (in asset decimals)
    /// @param value What this is worth in pool currency (18 decimals)
    function increase(uint64 poolId, bytes16 scId, uint128 assetId, uint128 amount, uint128 value) external;

    /// @notice Remove assets from a pool's holdings
    /// @dev Called when redemptions are processed. Updates both quantity and value.
    ///
    /// WHAT THIS DOES:
    /// - Decreases the asset count
    /// - Decreases the value proportionally
    /// - Triggers accounting entries via linked accounts
    ///
    /// @param poolId Which pool to update
    /// @param scId Share class ID
    /// @param assetId The asset being removed
    /// @param amount How many tokens to remove
    /// @param value Value being removed (18 decimals)
    function decrease(uint64 poolId, bytes16 scId, uint128 assetId, uint128 amount, uint128 value) external;

    /// @notice Revalue a holding based on current market price
    /// @dev Called periodically to update holding values when prices change.
    ///      Records gain/loss in accounting.
    ///
    /// WHAT THIS DOES:
    /// - Queries valuation contract for current price
    /// - Calculates new value: amount * currentPrice
    /// - Records difference as gain (positive) or loss (negative)
    /// - Updates accounting entries
    ///
    /// EXAMPLE:
    /// - Holding: 1 ETH, old value $2000
    /// - New price: $2500/ETH
    /// - Result: value becomes $2500, gain of $500 recorded
    ///
    /// @param poolId Which pool to update
    /// @param scId Share class ID
    /// @param assetId The asset to revalue
    /// @return isPositive True if value increased (gain), false if decreased (loss)
    /// @return diff The absolute value of the change
    function update(uint64 poolId, bytes16 scId, uint128 assetId) external returns (bool isPositive, uint128 diff);

    /// @notice Set the snapshot state for a share class on a specific network
    /// @dev Used to track hub-spoke synchronization state
    ///
    /// @param poolId Which pool
    /// @param scId Share class ID
    /// @param centrifugeId Network identifier (e.g., 1 for Ethereum)
    /// @param isSnapshot Whether hub and spoke are in sync
    /// @param nonce Version number for this snapshot
    function setSnapshot(uint64 poolId, bytes16 scId, uint16 centrifugeId, bool isSnapshot, uint64 nonce) external;

    /// @notice Update the valuation method for a holding
    /// @dev Used when switching price oracles or valuation strategies
    ///
    /// @param poolId Which pool
    /// @param scId Share class ID
    /// @param assetId The asset to update
    /// @param newValuation New valuation contract address
    function updateValuation(uint64 poolId, bytes16 scId, uint128 assetId, IValuation newValuation) external;

    // ============================================================
    // VIEW FUNCTIONS
    // ============================================================

    /// @notice Get the current holding for a specific asset
    /// @param poolId Pool identifier
    /// @param scId Share class identifier
    /// @param assetId Asset identifier
    /// @return holding The holding struct with amount, value, valuation, isLiability
    function getHolding(uint64 poolId, bytes16 scId, uint128 assetId) external view returns (Holding memory holding);

    /// @notice Get just the amount and value (gas-efficient)
    /// @param poolId Pool identifier
    /// @param scId Share class identifier
    /// @param assetId Asset identifier
    /// @return amount Token quantity
    /// @return value Value in pool currency
    function getAmountAndValue(uint64 poolId, bytes16 scId, uint128 assetId)
        external
        view
        returns (uint128 amount, uint128 value);

    /// @notice Get the snapshot state for a share class on a network
    /// @param poolId Pool identifier
    /// @param scId Share class identifier
    /// @param centrifugeId Network identifier
    /// @return snapshot The snapshot struct with isSnapshot and nonce
    function getSnapshot(uint64 poolId, bytes16 scId, uint16 centrifugeId)
        external
        view
        returns (Snapshot memory snapshot);

    /// @notice Check if a holding has been initialized
    /// @param poolId Pool identifier
    /// @param scId Share class identifier
    /// @param assetId Asset identifier
    /// @return initialized True if initialize() has been called
    function isInitialized(uint64 poolId, bytes16 scId, uint128 assetId) external view returns (bool initialized);

    /// @notice Get the linked accounting accounts for a holding
    /// @param poolId Pool identifier
    /// @param scId Share class identifier
    /// @param assetId Asset identifier
    /// @return accounts Array of linked HoldingAccount structs
    function getAccounts(uint64 poolId, bytes16 scId, uint128 assetId)
        external
        view
        returns (HoldingAccount[] memory accounts);
}
