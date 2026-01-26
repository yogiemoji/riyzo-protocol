// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.28;

import {IValuation} from "src/interfaces/hub/IValuation.sol";

/// @title INAVManager - Net Asset Value Manager Interface
/// @author Riyzo Protocol
/// @notice Interface for calculating and tracking Net Asset Value per pool per network.
///         Think of NAV as the "net worth" of a pool's holdings.
/// @dev NAV is calculated from accounting balances using the formula:
///      NAV = Equity + Gains - Losses - Liabilities
///
/// KEY CONCEPTS:
/// - NAV: Net Asset Value = total assets minus total liabilities
/// - Per-Network NAV: Each spoke chain has its own equity/liability tracking
/// - Account Derivation: Account IDs are computed from asset/network IDs
///
/// WHY PER-NETWORK NAV?
/// - Users on Ethereum deposit in Ethereum pool
/// - Users on Base deposit in Base pool
/// - Each network tracks its own share of the total pool
/// - Allows fair pricing when one network grows faster than others
///
/// ACCOUNT ID DERIVATION:
/// Accounts are deterministically derived to reduce storage:
/// - Asset accounts: (assetId << 16) | AccountType.Asset
/// - Equity accounts: (centrifugeId << 16) | AccountType.Equity
/// - This allows calculating account IDs without storage lookups
///
/// EXAMPLE NAV CALCULATION:
/// - Ethereum network equity: $100,000
/// - Ethereum network gains: $5,000
/// - Ethereum network losses: $1,000
/// - Ethereum network liabilities: $2,000
/// - NAV = 100,000 + 5,000 - 1,000 - 2,000 = $102,000
interface INAVManager {
    // ============================================================
    // EVENTS
    // ============================================================

    /// @notice Emitted when a network is initialized for a pool
    event NetworkInitialized(uint64 indexed poolId, uint16 indexed centrifugeId);

    /// @notice Emitted when a holding is initialized through NAV manager
    event HoldingInitialized(uint64 indexed poolId, bytes16 indexed scId, uint128 indexed assetId);

    /// @notice Emitted when NAV is calculated (for auditing)
    event NAVCalculated(uint64 indexed poolId, uint16 indexed centrifugeId, uint128 nav);

    /// @notice Emitted when gains/losses are closed to equity
    event GainLossClosed(uint64 indexed poolId, uint16 indexed centrifugeId, bool isGain, uint128 amount);

    // ============================================================
    // ERRORS
    // ============================================================

    /// @notice Thrown when network hasn't been initialized
    error NetworkNotInitialized(uint64 poolId, uint16 centrifugeId);

    /// @notice Thrown when network is already initialized
    error NetworkAlreadyInitialized(uint64 poolId, uint16 centrifugeId);

    /// @notice Thrown when holding hasn't been initialized
    error HoldingNotInitialized(uint64 poolId, bytes16 scId, uint128 assetId);

    /// @notice Thrown when NAV would be negative
    error NegativeNAV(uint64 poolId, uint16 centrifugeId);

    // ============================================================
    // STATE-CHANGING FUNCTIONS
    // ============================================================

    /// @notice Initialize NAV tracking for a new network
    /// @dev Creates the per-network accounting accounts (equity, gain, loss, liability).
    ///      Must be called before any deposits from this network can be processed.
    ///
    /// WHAT THIS DOES:
    /// - Creates equity account for this network
    /// - Creates gain account for tracking unrealized profits
    /// - Creates loss account for tracking unrealized losses
    /// - Creates liability account for any debts to this network
    ///
    /// @param poolId Pool to initialize network for
    /// @param centrifugeId Network identifier (e.g., 1 for Ethereum, 8453 for Base)
    function initializeNetwork(uint64 poolId, uint16 centrifugeId) external;

    /// @notice Initialize a holding through NAV manager
    /// @dev Creates both the holding in Holdings.sol and the associated accounts.
    ///      This is the preferred way to add holdings as it ensures proper linkage.
    ///
    /// WHAT THIS DOES:
    /// - Creates asset account for this holding
    /// - Initializes the holding in Holdings.sol
    /// - Links holding to equity/gain/loss accounts
    ///
    /// @param poolId Pool identifier
    /// @param scId Share class identifier
    /// @param assetId Asset identifier
    /// @param valuation Valuation contract for pricing
    function initializeHolding(uint64 poolId, bytes16 scId, uint128 assetId, IValuation valuation) external;

    /// @notice Initialize a liability holding
    /// @dev Similar to initializeHolding but for liabilities (debts, obligations).
    ///
    /// @param poolId Pool identifier
    /// @param scId Share class identifier
    /// @param assetId Asset/liability identifier
    /// @param valuation Valuation contract for pricing
    function initializeLiability(uint64 poolId, bytes16 scId, uint128 assetId, IValuation valuation) external;

    /// @notice Close gains/losses to equity
    /// @dev Moves unrealized gains/losses to equity, "realizing" them.
    ///      Typically called at end of epoch or when shares are redeemed.
    ///
    /// WHAT THIS DOES:
    /// - If gains > losses: credit equity, debit gain account
    /// - If losses > gains: debit equity, credit loss account
    /// - Zeros out gain/loss accounts
    ///
    /// EXAMPLE:
    /// - Gain account: $5,000
    /// - Loss account: $1,000
    /// - Net gain: $4,000
    /// - Result: Equity increases by $4,000, gain/loss accounts zeroed
    ///
    /// @param poolId Pool identifier
    /// @param centrifugeId Network identifier
    function closeGainLoss(uint64 poolId, uint16 centrifugeId) external;

    // ============================================================
    // VIEW FUNCTIONS
    // ============================================================

    /// @notice Calculate the Net Asset Value for a network
    /// @dev NAV = Equity + Gain - Loss - Liability
    ///      Returns 0 if NAV would be negative.
    ///
    /// CALCULATION:
    /// 1. Get equity account value (credit-normal, so positive = value)
    /// 2. Add gain account value (credit-normal)
    /// 3. Subtract loss account value (credit-normal, stored positive)
    /// 4. Subtract liability account value (credit-normal)
    ///
    /// @param poolId Pool identifier
    /// @param centrifugeId Network identifier
    /// @return nav Net Asset Value for this pool on this network (18 decimals)
    function netAssetValue(uint64 poolId, uint16 centrifugeId) external view returns (uint128 nav);

    /// @notice Get individual account values for debugging/display
    /// @param poolId Pool identifier
    /// @param centrifugeId Network identifier
    /// @return equity Equity account value
    /// @return gain Gain account value
    /// @return loss Loss account value
    /// @return liability Liability account value
    function getAccountValues(uint64 poolId, uint16 centrifugeId)
        external
        view
        returns (uint128 equity, uint128 gain, uint128 loss, uint128 liability);

    /// @notice Check if a network has been initialized
    /// @param poolId Pool identifier
    /// @param centrifugeId Network identifier
    /// @return initialized True if initializeNetwork has been called
    function isNetworkInitialized(uint64 poolId, uint16 centrifugeId) external view returns (bool initialized);

    // ============================================================
    // ACCOUNT ID DERIVATION (Pure Functions)
    // ============================================================

    /// @notice Derive asset account ID from asset ID
    /// @dev Account ID = (assetId << 16) | AccountType.Asset
    /// @param assetId Asset identifier
    /// @return accountId Derived account ID for accounting
    function assetAccount(uint128 assetId) external pure returns (bytes32 accountId);

    /// @notice Derive expense account ID from asset ID
    /// @dev Account ID = (assetId << 16) | AccountType.Expense
    /// @param assetId Asset/liability identifier
    /// @return accountId Derived account ID for accounting
    function expenseAccount(uint128 assetId) external pure returns (bytes32 accountId);

    /// @notice Derive equity account ID from network ID
    /// @dev Account ID = (centrifugeId << 16) | AccountType.Equity
    /// @param centrifugeId Network identifier
    /// @return accountId Derived account ID for accounting
    function equityAccount(uint16 centrifugeId) external pure returns (bytes32 accountId);

    /// @notice Derive gain account ID from network ID
    /// @dev Account ID = (centrifugeId << 16) | AccountType.Gain
    /// @param centrifugeId Network identifier
    /// @return accountId Derived account ID for accounting
    function gainAccount(uint16 centrifugeId) external pure returns (bytes32 accountId);

    /// @notice Derive loss account ID from network ID
    /// @dev Account ID = (centrifugeId << 16) | AccountType.Loss
    /// @param centrifugeId Network identifier
    /// @return accountId Derived account ID for accounting
    function lossAccount(uint16 centrifugeId) external pure returns (bytes32 accountId);

    /// @notice Derive liability account ID from network ID
    /// @dev Account ID = (centrifugeId << 16) | AccountType.Liability
    /// @param centrifugeId Network identifier
    /// @return accountId Derived account ID for accounting
    function liabilityAccount(uint16 centrifugeId) external pure returns (bytes32 accountId);
}
