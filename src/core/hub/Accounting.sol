// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.28;

import {Auth} from "src/core/Auth.sol";
import {IAccounting} from "src/interfaces/hub/IAccounting.sol";
import {TransientStorage} from "src/core/libraries/TransientStorage.sol";

/// @title Accounting - Double-Entry Bookkeeping System
/// @author Riyzo Protocol
/// @notice This contract implements a double-entry bookkeeping system for pool accounting.
///         Think of it as the "ledger" that ensures every financial transaction is balanced.
/// @dev Uses EIP-1153 transient storage for the lock/unlock pattern to enforce that
///      total debits equal total credits within each transaction.
///
/// ============================================================
/// KEY CONCEPTS FOR NON-ACCOUNTANTS
/// ============================================================
///
/// DOUBLE-ENTRY BOOKKEEPING:
/// Every financial transaction affects at least two accounts. When you receive
/// $100, your "Cash" account goes up AND your "Equity" account goes up.
/// This ensures the books always balance: Assets = Liabilities + Equity
///
/// DEBITS AND CREDITS:
/// - Debit: Left side of the equation. Increases assets/expenses.
/// - Credit: Right side of the equation. Increases liabilities/equity/revenue.
/// - Every transaction must have equal debits and credits.
///
/// ACCOUNT TYPES:
/// 1. Asset (debit-normal): Things you OWN - cash, tokens, receivables
///    - Debits INCREASE the balance
///    - Credits DECREASE the balance
///
/// 2. Expense (debit-normal): Costs incurred - fees, interest paid
///    - Debits INCREASE the balance
///    - Credits DECREASE the balance
///
/// 3. Equity (credit-normal): Owner's stake in the pool
///    - Credits INCREASE the balance
///    - Debits DECREASE the balance
///
/// 4. Liability (credit-normal): Things you OWE - debts, obligations
///    - Credits INCREASE the balance
///    - Debits DECREASE the balance
///
/// 5. Gain (credit-normal): Unrealized profits from price appreciation
///    - Credits INCREASE the balance
///    - Debits DECREASE the balance
///
/// 6. Loss (credit-normal): Unrealized losses from price depreciation
///    - Credits INCREASE the balance
///    - Debits DECREASE the balance
///
/// ============================================================
/// LOCK/UNLOCK PATTERN
/// ============================================================
///
/// To ensure double-entry integrity, we use a "transaction" pattern:
///
/// 1. unlock(poolId) - Start recording entries
///    - Initializes transient accumulators for debits/credits
///    - Returns a journalId for this batch
///
/// 2. debit()/credit() - Record entries
///    - Each call updates persistent storage AND transient accumulators
///    - Transient storage tracks totals for validation
///
/// 3. lock() - Validate and commit
///    - Checks: totalDebits == totalCredits
///    - If not equal: REVERTS (no state changes saved)
///    - If equal: Clears transient storage, tx succeeds
///
/// This pattern prevents partial/unbalanced updates since the entire
/// transaction reverts if the entries don't balance.
///
/// ============================================================
/// EXAMPLE: Recording a $1000 Deposit
/// ============================================================
///
/// When a user deposits 1000 USDC:
///
/// uint256 journalId = accounting.unlock(poolId);
///
/// // Asset increases (we received USDC)
/// accounting.debit(assetAccountId, 1000e18);
///
/// // Equity increases (user's stake in pool)
/// accounting.credit(equityAccountId, 1000e18);
///
/// accounting.lock(); // Validates 1000 == 1000, commits
///
/// ============================================================
/// EXAMPLE: Recording Unrealized Gain
/// ============================================================
///
/// When ETH price goes up $500:
///
/// uint256 journalId = accounting.unlock(poolId);
///
/// // Asset value increases
/// accounting.debit(assetAccountId, 500e18);
///
/// // Gain account records the appreciation
/// accounting.credit(gainAccountId, 500e18);
///
/// accounting.lock(); // Validates 500 == 500, commits
///
contract Accounting is Auth, IAccounting {
    using TransientStorage for bytes32;

    // ============================================================
    // CONSTANTS - Transient Storage Slots
    // ============================================================
    // These are unique keys for EIP-1153 transient storage.
    // Transient storage is cleared at the end of each transaction,
    // making it perfect for tracking within-transaction state.

    /// @dev Slot for tracking which pool is currently unlocked
    bytes32 private constant UNLOCKED_POOL_SLOT = keccak256("accounting.unlockedPool");

    /// @dev Slot for tracking total debits in current batch
    bytes32 private constant TOTAL_DEBITS_SLOT = keccak256("accounting.totalDebits");

    /// @dev Slot for tracking total credits in current batch
    bytes32 private constant TOTAL_CREDITS_SLOT = keccak256("accounting.totalCredits");

    /// @dev Slot for tracking current journal ID
    bytes32 private constant CURRENT_JOURNAL_SLOT = keccak256("accounting.currentJournal");

    // ============================================================
    // STORAGE
    // ============================================================

    /// @notice Stores account data per pool per account
    /// @dev accountData[poolId][accountId] => Account struct
    ///
    /// Account stores:
    /// - totalDebit: Sum of all debits ever made to this account
    /// - totalCredit: Sum of all credits ever made to this account
    /// - isDebitNormal: True for Asset/Expense accounts
    /// - lastUpdated: Timestamp of last modification
    /// - exists: Whether account has been created
    struct Account {
        uint128 totalDebit;
        uint128 totalCredit;
        bool isDebitNormal;
        uint64 lastUpdated;
        bool exists;
        AccountType accountType;
    }

    mapping(uint64 poolId => mapping(bytes32 accountId => Account)) internal _accounts;

    /// @notice Journal ID counter per pool
    /// @dev Increments each time unlock() is called
    mapping(uint64 poolId => uint256) internal _journalIdCounter;

    // ============================================================
    // CONSTRUCTOR
    // ============================================================

    /// @notice Initialize the Accounting contract
    /// @param initialWard Address that will have admin rights
    constructor(address initialWard) Auth(initialWard) {}

    // ============================================================
    // MODIFIERS
    // ============================================================

    /// @dev Ensures the pool is currently unlocked for accounting
    modifier whenUnlocked(uint64 poolId) {
        uint256 unlockedPool = UNLOCKED_POOL_SLOT.tloadUint256();
        if (unlockedPool != uint256(poolId)) revert NotUnlocked();
        _;
    }

    // ============================================================
    // STATE-CHANGING FUNCTIONS
    // ============================================================

    /// @inheritdoc IAccounting
    /// @dev Implementation details:
    /// 1. Checks no pool is currently unlocked (can't nest unlocks)
    /// 2. Stores poolId in transient storage
    /// 3. Initializes debit/credit accumulators to 0
    /// 4. Increments and returns journal ID
    function unlock(uint64 poolId) external auth returns (uint256 journalId) {
        // ============================================================
        // STEP 1: Verify no pool is currently unlocked
        // ============================================================
        // We use 0 as "no pool unlocked" since pool IDs are chain-prefixed
        // and will never be 0 in practice (Arbitrum chainId = 42161)
        uint256 currentlyUnlocked = UNLOCKED_POOL_SLOT.tloadUint256();
        if (currentlyUnlocked != 0) revert NotUnlocked();

        // ============================================================
        // STEP 2: Mark this pool as unlocked in transient storage
        // ============================================================
        // This will be cleared automatically at end of transaction,
        // but we also clear it explicitly in lock()
        UNLOCKED_POOL_SLOT.tstore(uint256(poolId));

        // ============================================================
        // STEP 3: Initialize accumulators to zero
        // ============================================================
        // These track total debits/credits for validation in lock()
        TOTAL_DEBITS_SLOT.tstore(uint256(0));
        TOTAL_CREDITS_SLOT.tstore(uint256(0));

        // ============================================================
        // STEP 4: Generate and store journal ID
        // ============================================================
        // Journal ID is a sequential number that identifies this batch
        // of entries for auditing purposes
        journalId = ++_journalIdCounter[poolId];
        CURRENT_JOURNAL_SLOT.tstore(journalId);

        return journalId;
    }

    /// @inheritdoc IAccounting
    /// @dev Implementation details:
    /// 1. Verifies a pool is unlocked
    /// 2. Compares total debits vs total credits
    /// 3. Reverts if not equal (entire transaction rolls back)
    /// 4. Clears transient storage
    /// 5. Emits JournalCommitted event
    function lock() external auth {
        // ============================================================
        // STEP 1: Get current unlock state
        // ============================================================
        uint256 unlockedPool = UNLOCKED_POOL_SLOT.tloadUint256();
        if (unlockedPool == 0) revert NotUnlocked();

        // Casting to uint64 is safe because we only ever store uint64 values in this slot
        // via unlock(), which casts from uint64 poolId
        // forge-lint: disable-next-line(unsafe-typecast)
        uint64 poolId = uint64(unlockedPool);

        // ============================================================
        // STEP 2: Load accumulated totals from transient storage
        // ============================================================
        uint128 totalDebits = uint128(TOTAL_DEBITS_SLOT.tloadUint256());
        uint128 totalCredits = uint128(TOTAL_CREDITS_SLOT.tloadUint256());

        // ============================================================
        // STEP 3: THE CRITICAL CHECK - Debits must equal credits!
        // ============================================================
        // This is the fundamental rule of double-entry bookkeeping.
        // If this check fails, the entire transaction reverts and
        // no state changes (including the debit/credit calls) are saved.
        if (totalDebits != totalCredits) {
            revert UnbalancedEntries(totalDebits, totalCredits);
        }

        // ============================================================
        // STEP 4: Get journal ID for event
        // ============================================================
        uint256 journalId = CURRENT_JOURNAL_SLOT.tloadUint256();

        // ============================================================
        // STEP 5: Clear transient storage (explicit cleanup)
        // ============================================================
        // While transient storage auto-clears at tx end, we clear
        // explicitly to allow multiple unlock/lock cycles in one tx
        UNLOCKED_POOL_SLOT.tstore(uint256(0));
        TOTAL_DEBITS_SLOT.tstore(uint256(0));
        TOTAL_CREDITS_SLOT.tstore(uint256(0));
        CURRENT_JOURNAL_SLOT.tstore(uint256(0));

        // ============================================================
        // STEP 6: Emit event for auditing
        // ============================================================
        emit JournalCommitted(poolId, journalId, totalDebits, totalCredits);
    }

    /// @inheritdoc IAccounting
    /// @dev Implementation details:
    /// 1. Verifies pool is unlocked
    /// 2. Verifies account exists
    /// 3. Adds to account's totalDebit
    /// 4. Adds to transient debit accumulator
    /// 5. Updates lastUpdated timestamp
    /// 6. Emits JournalEntryPosted event
    function debit(bytes32 accountId, uint128 value) external auth {
        // ============================================================
        // STEP 1: Get unlocked pool from transient storage
        // ============================================================
        uint256 unlockedPool = UNLOCKED_POOL_SLOT.tloadUint256();
        if (unlockedPool == 0) revert NotUnlocked();
        // Casting to uint64 is safe because we only store uint64 values via unlock()
        // forge-lint: disable-next-line(unsafe-typecast)
        uint64 poolId = uint64(unlockedPool);

        // ============================================================
        // STEP 2: Verify account exists
        // ============================================================
        Account storage account = _accounts[poolId][accountId];
        if (!account.exists) revert AccountNotFound(accountId);

        // ============================================================
        // STEP 3: Update persistent storage
        // ============================================================
        // Add to the account's cumulative debit total
        account.totalDebit += value;
        account.lastUpdated = uint64(block.timestamp);

        // ============================================================
        // STEP 4: Update transient accumulator
        // ============================================================
        // This tracks total debits for validation in lock()
        uint256 currentDebits = TOTAL_DEBITS_SLOT.tloadUint256();
        TOTAL_DEBITS_SLOT.tstore(currentDebits + value);

        // ============================================================
        // STEP 5: Emit event for auditing
        // ============================================================
        uint256 journalId = CURRENT_JOURNAL_SLOT.tloadUint256();
        emit JournalEntryPosted(poolId, journalId, accountId, true, value);
    }

    /// @inheritdoc IAccounting
    /// @dev Implementation mirrors debit() but for credit side
    function credit(bytes32 accountId, uint128 value) external auth {
        // ============================================================
        // STEP 1: Get unlocked pool from transient storage
        // ============================================================
        uint256 unlockedPool = UNLOCKED_POOL_SLOT.tloadUint256();
        if (unlockedPool == 0) revert NotUnlocked();
        // Casting to uint64 is safe because we only store uint64 values via unlock()
        // forge-lint: disable-next-line(unsafe-typecast)
        uint64 poolId = uint64(unlockedPool);

        // ============================================================
        // STEP 2: Verify account exists
        // ============================================================
        Account storage account = _accounts[poolId][accountId];
        if (!account.exists) revert AccountNotFound(accountId);

        // ============================================================
        // STEP 3: Update persistent storage
        // ============================================================
        // Add to the account's cumulative credit total
        account.totalCredit += value;
        account.lastUpdated = uint64(block.timestamp);

        // ============================================================
        // STEP 4: Update transient accumulator
        // ============================================================
        // This tracks total credits for validation in lock()
        uint256 currentCredits = TOTAL_CREDITS_SLOT.tloadUint256();
        TOTAL_CREDITS_SLOT.tstore(currentCredits + value);

        // ============================================================
        // STEP 5: Emit event for auditing
        // ============================================================
        uint256 journalId = CURRENT_JOURNAL_SLOT.tloadUint256();
        emit JournalEntryPosted(poolId, journalId, accountId, false, value);
    }

    /// @inheritdoc IAccounting
    /// @dev Creates a new account in the chart of accounts.
    /// Each account must have a unique ID within the pool.
    function createAccount(uint64 poolId, bytes32 accountId, AccountType accountType) external auth {
        // ============================================================
        // STEP 1: Check account doesn't already exist
        // ============================================================
        Account storage account = _accounts[poolId][accountId];
        if (account.exists) revert AccountAlreadyExists(accountId);

        // ============================================================
        // STEP 2: Determine if account is debit-normal
        // ============================================================
        // Debit-normal accounts: Assets, Expenses
        // Credit-normal accounts: Equity, Liability, Gain, Loss
        bool isDebitNormal = (accountType == AccountType.Asset || accountType == AccountType.Expense);

        // ============================================================
        // STEP 3: Initialize account
        // ============================================================
        account.totalDebit = 0;
        account.totalCredit = 0;
        account.isDebitNormal = isDebitNormal;
        account.lastUpdated = uint64(block.timestamp);
        account.exists = true;
        account.accountType = accountType;

        // ============================================================
        // STEP 4: Emit event
        // ============================================================
        emit AccountCreated(poolId, accountId, accountType);
    }

    // ============================================================
    // VIEW FUNCTIONS
    // ============================================================

    /// @inheritdoc IAccounting
    /// @dev Calculates the "balance" of an account based on its normal side.
    ///
    /// For DEBIT-NORMAL accounts (Asset, Expense):
    ///   value = totalDebit - totalCredit
    ///   isPositive = totalDebit >= totalCredit
    ///
    /// For CREDIT-NORMAL accounts (Equity, Liability, Gain, Loss):
    ///   value = totalCredit - totalDebit
    ///   isPositive = totalCredit >= totalDebit
    ///
    /// EXAMPLE - Asset Account:
    ///   totalDebit = 5000, totalCredit = 2000
    ///   Since debit-normal: value = 5000 - 2000 = 3000
    ///   isPositive = true, value = 3000
    ///   Meaning: We have $3000 worth of this asset
    ///
    /// EXAMPLE - Equity Account:
    ///   totalDebit = 1000, totalCredit = 5000
    ///   Since credit-normal: value = 5000 - 1000 = 4000
    ///   isPositive = true, value = 4000
    ///   Meaning: Equity is $4000
    function accountValue(uint64 poolId, bytes32 accountId) external view returns (bool isPositive, uint128 value) {
        Account storage account = _accounts[poolId][accountId];
        if (!account.exists) revert AccountNotFound(accountId);

        if (account.isDebitNormal) {
            // ============================================================
            // DEBIT-NORMAL: Asset, Expense
            // ============================================================
            // These accounts increase with debits, decrease with credits.
            // A positive balance means debits > credits.
            if (account.totalDebit >= account.totalCredit) {
                isPositive = true;
                value = account.totalDebit - account.totalCredit;
            } else {
                // Unusual case: credit > debit for a debit-normal account
                // This would mean negative assets (shouldn't normally happen)
                isPositive = false;
                value = account.totalCredit - account.totalDebit;
            }
        } else {
            // ============================================================
            // CREDIT-NORMAL: Equity, Liability, Gain, Loss
            // ============================================================
            // These accounts increase with credits, decrease with debits.
            // A positive balance means credits > debits.
            if (account.totalCredit >= account.totalDebit) {
                isPositive = true;
                value = account.totalCredit - account.totalDebit;
            } else {
                // Unusual case: debit > credit for a credit-normal account
                // This would mean negative equity (could happen if losses exceed capital)
                isPositive = false;
                value = account.totalDebit - account.totalCredit;
            }
        }
    }

    /// @inheritdoc IAccounting
    function accountTotals(uint64 poolId, bytes32 accountId)
        external
        view
        returns (uint128 totalDebit, uint128 totalCredit)
    {
        Account storage account = _accounts[poolId][accountId];
        if (!account.exists) revert AccountNotFound(accountId);
        return (account.totalDebit, account.totalCredit);
    }

    /// @inheritdoc IAccounting
    function accountExists(uint64 poolId, bytes32 accountId) external view returns (bool exists) {
        return _accounts[poolId][accountId].exists;
    }

    /// @inheritdoc IAccounting
    function getAccountType(uint64 poolId, bytes32 accountId) external view returns (AccountType accountType) {
        Account storage account = _accounts[poolId][accountId];
        if (!account.exists) revert AccountNotFound(accountId);
        return account.accountType;
    }

    /// @inheritdoc IAccounting
    function currentJournalId(uint64 poolId) external view returns (uint256 journalId) {
        return _journalIdCounter[poolId];
    }

    /// @inheritdoc IAccounting
    function isUnlocked(uint64 poolId) external view returns (bool unlocked) {
        uint256 unlockedPool = UNLOCKED_POOL_SLOT.tloadUint256();
        return unlockedPool == uint256(poolId);
    }
}
