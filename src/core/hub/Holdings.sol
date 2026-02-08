// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.28;

import {Auth} from "src/core/Auth.sol";
import {IHoldings} from "src/interfaces/hub/IHoldings.sol";
import {IValuation} from "src/interfaces/hub/IValuation.sol";
import {IAccounting} from "src/interfaces/hub/IAccounting.sol";
import {MathLib} from "src/core/libraries/MathLib.sol";

/// @title Holdings - Pool Holdings Tracker
/// @author Riyzo Protocol
/// @notice This contract tracks all assets and liabilities held by each pool.
///         Think of it as a "warehouse inventory" for the pool's investments.
/// @dev Implements double-entry linkage with Accounting.sol for financial integrity.
///      Each holding tracks both quantity (how many tokens) and value (worth in currency).
///
/// ============================================================
/// KEY CONCEPTS FOR EVERYONE
/// ============================================================
///
/// WHAT IS A "HOLDING"?
/// A holding represents ownership of something. For example:
/// - "Pool #1 holds 10,000 USDC" is one holding
/// - "Pool #1 holds 5 WETH" is another holding
/// - "Pool #1 owes 1,000 DAI" is a liability holding
///
/// WHY TRACK BOTH AMOUNT AND VALUE?
/// Amount = How many tokens you have (doesn't change unless you buy/sell)
/// Value = What those tokens are worth in dollars (changes with market prices)
///
/// EXAMPLE:
/// Day 1: Buy 1 ETH for $2,000
///   - amount = 1 ETH
///   - value = $2,000
///
/// Day 2: ETH price rises to $2,500
///   - amount = 1 ETH (unchanged - you still have 1 ETH)
///   - value = $2,500 (updated - it's now worth more)
///   - You made $500 unrealized gain!
///
/// WHAT IS A "VALUATION"?
/// A valuation is a contract that tells us the current price of an asset.
/// Different assets use different valuation methods:
/// - Oracle-based: Gets price from Chainlink/Pyth
/// - Manual: Admin sets the price (for illiquid assets)
/// - Formula: Calculates price from other prices
///
/// WHAT IS A "SNAPSHOT"?
/// A snapshot tracks whether the hub (Arbitrum) and spoke (Ethereum/Base)
/// are in sync. This prevents pricing errors when chains are out of sync.
///
/// ============================================================
/// HOW HOLDINGS CONNECT TO ACCOUNTING
/// ============================================================
///
/// Every holding is linked to accounting accounts for double-entry:
///
/// ASSET HOLDINGS (things we own):
/// - Asset Account: Tracks the value of the asset
/// - Equity Account: Tracks investor's stake
/// - Gain Account: Tracks unrealized profits
/// - Loss Account: Tracks unrealized losses
///
/// LIABILITY HOLDINGS (things we owe):
/// - Expense Account: Tracks cost of the liability
/// - Liability Account: Tracks the obligation
///
/// When you call increase() or decrease(), this contract automatically
/// triggers the corresponding accounting entries via the linked accounts.
///
/// ============================================================
/// TYPICAL FLOW: User Deposits 1000 USDC
/// ============================================================
///
/// 1. User deposits 1000 USDC on Ethereum (spoke chain)
/// 2. Cross-chain message arrives on Arbitrum (hub chain)
/// 3. Hub calls holdings.increase(poolId, scId, USDC_ID, 1000e6, 1000e18)
///    - amount = 1000e6 (USDC has 6 decimals)
///    - value = 1000e18 (values always use 18 decimals)
/// 4. Holdings updates internal state AND triggers accounting:
///    - accounting.debit(assetAccount, 1000e18)  // Asset up
///    - accounting.credit(equityAccount, 1000e18) // Equity up
/// 5. NAV increases by $1000
///
/// ============================================================
/// TYPICAL FLOW: ETH Price Goes Up $500
/// ============================================================
///
/// 1. Oracle reports new ETH price: $2,500
/// 2. Admin calls holdings.update(poolId, scId, ETH_ID)
/// 3. Holdings queries valuation: newValue = 1 ETH * $2,500 = $2,500
/// 4. Holdings calculates diff: $2,500 - $2,000 = $500 gain
/// 5. Holdings triggers accounting:
///    - accounting.debit(assetAccount, 500e18)   // Asset value up
///    - accounting.credit(gainAccount, 500e18)   // Record the gain
/// 6. NAV increases by $500
///
contract Holdings is Auth, IHoldings {
    using MathLib for uint256;

    // ============================================================
    // STORAGE
    // ============================================================

    /// @notice Reference to the Accounting contract for double-entry
    IAccounting public accounting;

    /// @notice Multi-dimensional mapping for holdings
    /// @dev holdings[poolId][shareClassId][assetId] => Holding
    ///
    /// Example access:
    /// - holdings[1][0x01][100] = Pool 1, Senior Class, USDC holding
    /// - holdings[1][0x02][200] = Pool 1, Junior Class, WETH holding
    mapping(uint64 => mapping(bytes16 => mapping(uint128 => Holding))) internal _holdings;

    /// @notice Tracks which holdings have been initialized
    /// @dev Separate from Holding struct to save gas on reads
    mapping(uint64 => mapping(bytes16 => mapping(uint128 => bool))) internal _initialized;

    /// @notice Linked accounting accounts for each holding
    /// @dev accounts[poolId][shareClassId][assetId] => HoldingAccount[]
    mapping(uint64 => mapping(bytes16 => mapping(uint128 => HoldingAccount[]))) internal _holdingAccounts;

    /// @notice Snapshot state for hub-spoke synchronization
    /// @dev snapshots[poolId][shareClassId][networkId] => Snapshot
    mapping(uint64 => mapping(bytes16 => mapping(uint16 => Snapshot))) internal _snapshots;

    // ============================================================
    // CONSTANTS
    // ============================================================

    /// @dev Index for asset account in HoldingAccount array (for assets)
    uint8 internal constant ASSET_ACCOUNT_IDX = 0;

    /// @dev Index for equity account in HoldingAccount array (for assets)
    uint8 internal constant EQUITY_ACCOUNT_IDX = 1;

    /// @dev Index for gain account in HoldingAccount array (for assets)
    uint8 internal constant GAIN_ACCOUNT_IDX = 2;

    /// @dev Index for loss account in HoldingAccount array (for assets)
    uint8 internal constant LOSS_ACCOUNT_IDX = 3;

    /// @dev Index for expense account in HoldingAccount array (for liabilities)
    uint8 internal constant EXPENSE_ACCOUNT_IDX = 0;

    /// @dev Index for liability account in HoldingAccount array (for liabilities)
    uint8 internal constant LIABILITY_ACCOUNT_IDX = 1;

    // ============================================================
    // CONSTRUCTOR
    // ============================================================

    /// @notice Initialize the Holdings contract
    /// @param initialWard Address that will have admin rights
    /// @param accounting_ Address of the Accounting contract
    constructor(address initialWard, IAccounting accounting_) Auth(initialWard) {
        accounting = accounting_;
    }

    // ============================================================
    // ADMIN FUNCTIONS
    // ============================================================

    /// @notice Update contract dependencies
    /// @dev Standard "file" pattern used across the protocol
    /// @param what Parameter name to update
    /// @param data New value
    function file(bytes32 what, address data) external auth {
        if (what == "accounting") {
            accounting = IAccounting(data);
        } else {
            revert("Holdings/file-unrecognized-param");
        }
        emit File(what, data);
    }

    /// @dev Event for file() function
    event File(bytes32 indexed what, address data);

    // ============================================================
    // INITIALIZATION
    // ============================================================

    /// @inheritdoc IHoldings
    /// @dev Initializes a new holding with:
    /// 1. Zero amount and value
    /// 2. Valuation contract for pricing
    /// 3. Linked accounting accounts
    ///
    /// IMPORTANT: Must be called before increase/decrease!
    ///
    /// For ASSET holdings, accounts array should contain 4 accounts:
    /// [0] = Asset account (tracks asset value)
    /// [1] = Equity account (tracks investor stake)
    /// [2] = Gain account (tracks unrealized profits)
    /// [3] = Loss account (tracks unrealized losses)
    ///
    /// For LIABILITY holdings, accounts array should contain 2 accounts:
    /// [0] = Expense account (tracks cost)
    /// [1] = Liability account (tracks obligation)
    function initialize(
        uint64 poolId,
        bytes16 scId,
        uint128 assetId,
        IValuation valuation,
        bool isLiability,
        HoldingAccount[] calldata accounts
    ) external auth {
        // ============================================================
        // STEP 1: Verify holding doesn't already exist
        // ============================================================
        if (_initialized[poolId][scId][assetId]) {
            revert HoldingAlreadyExists(poolId, scId, assetId);
        }

        // ============================================================
        // STEP 2: Validate valuation contract
        // ============================================================
        // Valuation can be address(0) for manually-priced assets,
        // but if provided, it should be a valid contract
        if (address(valuation) != address(0)) {
            // Basic validation - check it's a contract
            uint256 codeSize;
            assembly {
                codeSize := extcodesize(valuation)
            }
            if (codeSize == 0) revert InvalidValuation(address(valuation));
        }

        // ============================================================
        // STEP 3: Validate accounts array length
        // ============================================================
        // Assets need 4 accounts, liabilities need 2
        uint256 expectedAccounts = isLiability ? 2 : 4;
        require(accounts.length == expectedAccounts, "Holdings/invalid-accounts-length");

        // ============================================================
        // STEP 4: Initialize the holding struct
        // ============================================================
        Holding storage holding = _holdings[poolId][scId][assetId];
        holding.assetAmount = 0;
        holding.assetAmountValue = 0;
        holding.valuation = valuation;
        holding.isLiability = isLiability;

        // ============================================================
        // STEP 5: Store linked accounts
        // ============================================================
        // Copy accounts to storage
        for (uint256 i = 0; i < accounts.length; i++) {
            _holdingAccounts[poolId][scId][assetId].push(accounts[i]);
        }

        // ============================================================
        // STEP 6: Mark as initialized
        // ============================================================
        _initialized[poolId][scId][assetId] = true;

        emit HoldingInitialized(poolId, scId, assetId, address(valuation), isLiability);
    }

    // ============================================================
    // HOLDING OPERATIONS
    // ============================================================

    /// @inheritdoc IHoldings
    /// @dev Increases a holding's amount and value.
    ///
    /// WHAT HAPPENS:
    /// 1. Updates internal amount/value tracking
    /// 2. Triggers accounting entries:
    ///    - For assets: debit(assetAccount), credit(equityAccount)
    ///    - For liabilities: debit(expenseAccount), credit(liabilityAccount)
    ///
    /// EXAMPLE - Deposit 1000 USDC:
    /// increase(poolId, scId, USDC_ID, 1000e6, 1000e18)
    /// - amount = 1000e6 (USDC decimals)
    /// - value = 1000e18 (standard 18 decimals for values)
    function increase(uint64 poolId, bytes16 scId, uint128 assetId, uint128 amount, uint128 value) external auth {
        // ============================================================
        // STEP 1: Verify holding is initialized
        // ============================================================
        if (!_initialized[poolId][scId][assetId]) {
            revert HoldingNotInitialized(poolId, scId, assetId);
        }

        // ============================================================
        // STEP 2: Update holding state
        // ============================================================
        Holding storage holding = _holdings[poolId][scId][assetId];
        holding.assetAmount += amount;
        holding.assetAmountValue += value;

        // ============================================================
        // STEP 3: Trigger accounting entries
        // ============================================================
        // This creates the double-entry bookkeeping records
        _recordIncrease(poolId, scId, assetId, value, holding.isLiability);

        emit HoldingIncreased(poolId, scId, assetId, amount, value);
    }

    /// @inheritdoc IHoldings
    /// @dev Decreases a holding's amount and value.
    ///
    /// WHAT HAPPENS:
    /// 1. Validates we have enough to decrease
    /// 2. Updates internal amount/value tracking
    /// 3. Triggers accounting entries (reverse of increase)
    ///
    /// EXAMPLE - Withdraw 500 USDC:
    /// decrease(poolId, scId, USDC_ID, 500e6, 500e18)
    function decrease(uint64 poolId, bytes16 scId, uint128 assetId, uint128 amount, uint128 value) external auth {
        // ============================================================
        // STEP 1: Verify holding is initialized
        // ============================================================
        if (!_initialized[poolId][scId][assetId]) {
            revert HoldingNotInitialized(poolId, scId, assetId);
        }

        // ============================================================
        // STEP 2: Verify sufficient holdings
        // ============================================================
        Holding storage holding = _holdings[poolId][scId][assetId];
        if (holding.assetAmount < amount) {
            revert InsufficientHolding(amount, holding.assetAmount);
        }

        // ============================================================
        // STEP 3: Update holding state
        // ============================================================
        holding.assetAmount -= amount;
        holding.assetAmountValue -= value;

        // ============================================================
        // STEP 4: Trigger accounting entries
        // ============================================================
        _recordDecrease(poolId, scId, assetId, value, holding.isLiability);

        emit HoldingDecreased(poolId, scId, assetId, amount, value);
    }

    /// @inheritdoc IHoldings
    /// @dev Revalues a holding based on current market price.
    ///
    /// WHAT HAPPENS:
    /// 1. Queries valuation contract for current price
    /// 2. Calculates new value: amount * price
    /// 3. Calculates difference from old value
    /// 4. Records gain or loss in accounting
    ///
    /// EXAMPLE - ETH price went up:
    /// - Old: 1 ETH worth $2,000
    /// - New: 1 ETH worth $2,500
    /// - Gain of $500 recorded
    ///
    /// @return isPositive True if value increased (gain)
    /// @return diff Absolute value of the change
    function update(uint64 poolId, bytes16 scId, uint128 assetId)
        external
        auth
        returns (bool isPositive, uint128 diff)
    {
        // ============================================================
        // STEP 1: Verify holding is initialized
        // ============================================================
        if (!_initialized[poolId][scId][assetId]) {
            revert HoldingNotInitialized(poolId, scId, assetId);
        }

        Holding storage holding = _holdings[poolId][scId][assetId];

        // ============================================================
        // STEP 2: Skip if no valuation contract
        // ============================================================
        // Some holdings are manually valued and don't have a valuation contract
        if (address(holding.valuation) == address(0)) {
            return (true, 0);
        }

        // ============================================================
        // STEP 3: Calculate new value from valuation
        // ============================================================
        // Query the valuation contract: "What is X amount of this asset worth?"
        uint128 newValue = holding.valuation.getQuote(poolId, scId, assetId, holding.assetAmount);

        // ============================================================
        // STEP 4: Calculate difference
        // ============================================================
        uint128 oldValue = holding.assetAmountValue;

        if (newValue >= oldValue) {
            // ============================================================
            // CASE A: Value increased (GAIN)
            // ============================================================
            // Asset is now worth more - unrealized profit!
            isPositive = true;
            diff = newValue - oldValue;

            if (diff > 0) {
                holding.assetAmountValue = newValue;
                _recordGain(poolId, scId, assetId, diff, holding.isLiability);
            }
        } else {
            // ============================================================
            // CASE B: Value decreased (LOSS)
            // ============================================================
            // Asset is now worth less - unrealized loss
            isPositive = false;
            diff = oldValue - newValue;

            holding.assetAmountValue = newValue;
            _recordLoss(poolId, scId, assetId, diff, holding.isLiability);
        }

        emit HoldingUpdated(poolId, scId, assetId, isPositive, diff);
    }

    /// @inheritdoc IHoldings
    /// @dev Sets snapshot state for hub-spoke synchronization.
    ///
    /// WHAT IS A SNAPSHOT?
    /// When the hub and spoke are "in sync", we set isSnapshot = true.
    /// This tells the system it's safe to use prices for this share class.
    ///
    /// The nonce increments each time sync completes, preventing replay attacks.
    function setSnapshot(uint64 poolId, bytes16 scId, uint16 centrifugeId, bool isSnapshot, uint64 nonce)
        external
        auth
    {
        Snapshot storage snapshot = _snapshots[poolId][scId][centrifugeId];
        snapshot.isSnapshot = isSnapshot;
        snapshot.nonce = nonce;

        emit SnapshotSet(poolId, scId, centrifugeId, isSnapshot, nonce);
    }

    /// @inheritdoc IHoldings
    /// @dev Updates the valuation contract for a holding.
    /// Used when switching price oracles or valuation strategies.
    function updateValuation(uint64 poolId, bytes16 scId, uint128 assetId, IValuation newValuation) external auth {
        if (!_initialized[poolId][scId][assetId]) {
            revert HoldingNotInitialized(poolId, scId, assetId);
        }

        // Validate new valuation if not zero address
        if (address(newValuation) != address(0)) {
            uint256 codeSize;
            assembly {
                codeSize := extcodesize(newValuation)
            }
            if (codeSize == 0) revert InvalidValuation(address(newValuation));
        }

        _holdings[poolId][scId][assetId].valuation = newValuation;

        emit ValuationUpdated(poolId, scId, assetId, address(newValuation));
    }

    // ============================================================
    // INTERNAL ACCOUNTING HELPERS
    // ============================================================

    /// @dev Records accounting entries for an increase (deposit/acquisition)
    ///
    /// For ASSETS:
    ///   Debit Asset Account (asset value goes up)
    ///   Credit Equity Account (investor stake goes up)
    ///
    /// For LIABILITIES:
    ///   Debit Expense Account (cost goes up)
    ///   Credit Liability Account (obligation goes up)
    function _recordIncrease(uint64 poolId, bytes16 scId, uint128 assetId, uint128 value, bool isLiability) internal {
        HoldingAccount[] storage accounts = _holdingAccounts[poolId][scId][assetId];

        if (isLiability) {
            // Liability: Debit Expense, Credit Liability
            accounting.debit(accounts[EXPENSE_ACCOUNT_IDX].accountId, value);
            accounting.credit(accounts[LIABILITY_ACCOUNT_IDX].accountId, value);
        } else {
            // Asset: Debit Asset, Credit Equity
            accounting.debit(accounts[ASSET_ACCOUNT_IDX].accountId, value);
            accounting.credit(accounts[EQUITY_ACCOUNT_IDX].accountId, value);
        }
    }

    /// @dev Records accounting entries for a decrease (withdrawal/disposal)
    ///
    /// For ASSETS:
    ///   Debit Equity Account (investor stake goes down)
    ///   Credit Asset Account (asset value goes down)
    ///
    /// For LIABILITIES:
    ///   Debit Liability Account (obligation goes down)
    ///   Credit Expense Account (cost goes down)
    function _recordDecrease(uint64 poolId, bytes16 scId, uint128 assetId, uint128 value, bool isLiability) internal {
        HoldingAccount[] storage accounts = _holdingAccounts[poolId][scId][assetId];

        if (isLiability) {
            // Liability: Debit Liability, Credit Expense
            accounting.debit(accounts[LIABILITY_ACCOUNT_IDX].accountId, value);
            accounting.credit(accounts[EXPENSE_ACCOUNT_IDX].accountId, value);
        } else {
            // Asset: Debit Equity, Credit Asset
            accounting.debit(accounts[EQUITY_ACCOUNT_IDX].accountId, value);
            accounting.credit(accounts[ASSET_ACCOUNT_IDX].accountId, value);
        }
    }

    /// @dev Records accounting entries for a gain (value increase)
    ///
    /// For ASSETS:
    ///   Debit Asset Account (asset worth more)
    ///   Credit Gain Account (record the profit)
    ///
    /// For LIABILITIES:
    ///   This is actually bad - liability costs more
    ///   Debit Expense Account (cost increased)
    ///   Credit Liability Account (we owe more)
    function _recordGain(uint64 poolId, bytes16 scId, uint128 assetId, uint128 value, bool isLiability) internal {
        HoldingAccount[] storage accounts = _holdingAccounts[poolId][scId][assetId];

        if (isLiability) {
            // Liability value went UP = bad (we owe more)
            // Treat as expense increase
            accounting.debit(accounts[EXPENSE_ACCOUNT_IDX].accountId, value);
            accounting.credit(accounts[LIABILITY_ACCOUNT_IDX].accountId, value);
        } else {
            // Asset value went UP = good (unrealized gain)
            accounting.debit(accounts[ASSET_ACCOUNT_IDX].accountId, value);
            accounting.credit(accounts[GAIN_ACCOUNT_IDX].accountId, value);
        }
    }

    /// @dev Records accounting entries for a loss (value decrease)
    ///
    /// For ASSETS:
    ///   Debit Loss Account (record the loss)
    ///   Credit Asset Account (asset worth less)
    ///
    /// For LIABILITIES:
    ///   This is actually good - liability costs less
    ///   Debit Liability Account (we owe less)
    ///   Credit Expense Account (cost decreased)
    function _recordLoss(uint64 poolId, bytes16 scId, uint128 assetId, uint128 value, bool isLiability) internal {
        HoldingAccount[] storage accounts = _holdingAccounts[poolId][scId][assetId];

        if (isLiability) {
            // Liability value went DOWN = good (we owe less)
            // Treat as expense decrease
            accounting.debit(accounts[LIABILITY_ACCOUNT_IDX].accountId, value);
            accounting.credit(accounts[EXPENSE_ACCOUNT_IDX].accountId, value);
        } else {
            // Asset value went DOWN = bad (unrealized loss)
            accounting.debit(accounts[LOSS_ACCOUNT_IDX].accountId, value);
            accounting.credit(accounts[ASSET_ACCOUNT_IDX].accountId, value);
        }
    }

    // ============================================================
    // VIEW FUNCTIONS
    // ============================================================

    /// @inheritdoc IHoldings
    function getHolding(uint64 poolId, bytes16 scId, uint128 assetId) external view returns (Holding memory holding) {
        if (!_initialized[poolId][scId][assetId]) {
            revert HoldingNotInitialized(poolId, scId, assetId);
        }
        return _holdings[poolId][scId][assetId];
    }

    /// @inheritdoc IHoldings
    function getAmountAndValue(uint64 poolId, bytes16 scId, uint128 assetId)
        external
        view
        returns (uint128 amount, uint128 value)
    {
        if (!_initialized[poolId][scId][assetId]) {
            revert HoldingNotInitialized(poolId, scId, assetId);
        }
        Holding storage holding = _holdings[poolId][scId][assetId];
        return (holding.assetAmount, holding.assetAmountValue);
    }

    /// @inheritdoc IHoldings
    function getSnapshot(uint64 poolId, bytes16 scId, uint16 centrifugeId)
        external
        view
        returns (Snapshot memory snapshot)
    {
        return _snapshots[poolId][scId][centrifugeId];
    }

    /// @inheritdoc IHoldings
    function isInitialized(uint64 poolId, bytes16 scId, uint128 assetId) external view returns (bool initialized) {
        return _initialized[poolId][scId][assetId];
    }

    /// @inheritdoc IHoldings
    function getAccounts(uint64 poolId, bytes16 scId, uint128 assetId)
        external
        view
        returns (HoldingAccount[] memory accounts)
    {
        if (!_initialized[poolId][scId][assetId]) {
            revert HoldingNotInitialized(poolId, scId, assetId);
        }
        return _holdingAccounts[poolId][scId][assetId];
    }
}
