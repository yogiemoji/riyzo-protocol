// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.28;

/// @title IAccounting - Double-Entry Bookkeeping Interface
/// @author Riyzo Protocol
/// @notice Interface for the accounting system that ensures financial integrity.
///         Think of this as the "ledger" that tracks all money movements.
/// @dev Implements double-entry bookkeeping where every transaction must have
///      equal debits and credits. Uses a lock/unlock pattern with EIP-1153
///      transient storage to enforce this within a single transaction.
///
/// KEY CONCEPTS:
/// - Account: A named bucket that tracks a type of value (e.g., "Assets", "Equity")
/// - Debit: Left side of the accounting equation (increases assets/expenses)
/// - Credit: Right side of the accounting equation (increases liabilities/equity)
/// - Journal Entry: A single debit or credit to an account
///
/// ACCOUNT TYPES:
/// - Asset (debit-normal): Things we OWN - increases with debits
/// - Expense (debit-normal): Costs incurred - increases with debits
/// - Equity (credit-normal): Owner's stake - increases with credits
/// - Liability (credit-normal): Things we OWE - increases with credits
/// - Gain (credit-normal): Unrealized profits - increases with credits
/// - Loss (credit-normal): Unrealized losses - increases with credits
///
/// EXAMPLE FLOW:
/// 1. unlock(poolId) - Start a transaction batch
/// 2. debit(assetAccount, 1000) - Record asset increase
/// 3. credit(equityAccount, 1000) - Record equity increase
/// 4. lock() - Validate debits == credits, save to storage
///
/// If lock() is called and debits != credits, the transaction reverts.
interface IAccounting {
    // ============================================================
    // ENUMS
    // ============================================================

    /// @notice Types of accounts in the chart of accounts
    /// @dev Each type has a "normal balance" - the side that increases it
    enum AccountType {
        Asset, // Debit-normal: Cash, tokens, receivables
        Equity, // Credit-normal: Owner's stake, retained earnings
        Gain, // Credit-normal: Unrealized appreciation
        Loss, // Credit-normal: Unrealized depreciation (stored as positive)
        Expense, // Debit-normal: Operating costs, fees paid
        Liability // Credit-normal: Debts, obligations
    }

    // ============================================================
    // EVENTS
    // ============================================================

    /// @notice Emitted when an account is created
    /// @param poolId The pool this account belongs to
    /// @param accountId The unique identifier for the account
    /// @param accountType The type of account (Asset, Equity, etc.)
    event AccountCreated(uint64 indexed poolId, bytes32 indexed accountId, AccountType accountType);

    /// @notice Emitted when a journal entry is posted
    /// @param poolId The pool context
    /// @param journalId The batch identifier for this set of entries
    /// @param accountId The account being modified
    /// @param isDebit True if this is a debit, false if credit
    /// @param value The amount of the entry
    event JournalEntryPosted(
        uint64 indexed poolId, uint256 indexed journalId, bytes32 indexed accountId, bool isDebit, uint128 value
    );

    /// @notice Emitted when a transaction batch is committed
    /// @param poolId The pool context
    /// @param journalId The batch identifier
    /// @param totalDebits Sum of all debits in this batch
    /// @param totalCredits Sum of all credits in this batch
    event JournalCommitted(uint64 indexed poolId, uint256 indexed journalId, uint128 totalDebits, uint128 totalCredits);

    // ============================================================
    // ERRORS
    // ============================================================

    /// @notice Thrown when trying to lock without a matching unlock
    error NotUnlocked();

    /// @notice Thrown when debits don't equal credits at lock time
    /// @param debits Total debits in the current batch
    /// @param credits Total credits in the current batch
    error UnbalancedEntries(uint128 debits, uint128 credits);

    /// @notice Thrown when trying to operate on a non-existent account
    /// @param accountId The account that doesn't exist
    error AccountNotFound(bytes32 accountId);

    /// @notice Thrown when trying to create a duplicate account
    /// @param accountId The account that already exists
    error AccountAlreadyExists(bytes32 accountId);

    // ============================================================
    // STATE-CHANGING FUNCTIONS
    // ============================================================

    /// @notice Start a new accounting transaction batch
    /// @dev Must be called before any debit/credit operations.
    ///      Uses transient storage to track debits/credits until lock().
    ///
    /// WHAT THIS DOES:
    /// - Marks the pool as "unlocked" for accounting operations
    /// - Initializes transient accumulators for debits and credits
    /// - Generates a new journal ID for this batch
    ///
    /// @param poolId The pool to start accounting for
    /// @return journalId Unique identifier for this transaction batch
    function unlock(uint64 poolId) external returns (uint256 journalId);

    /// @notice Commit the current transaction batch
    /// @dev Validates that total debits equal total credits, then persists.
    ///      Reverts with UnbalancedEntries if they don't match.
    ///
    /// WHAT THIS DOES:
    /// - Checks: debits == credits (fundamental accounting equation)
    /// - Persists all journal entries to storage
    /// - Clears transient storage
    /// - Emits JournalCommitted event
    ///
    /// REVERTS IF:
    /// - Not currently unlocked
    /// - Debits != Credits
    function lock() external;

    /// @notice Record a debit (left-side entry)
    /// @dev Increases the account's debit total. For debit-normal accounts
    ///      (Asset, Expense), this increases the account value.
    ///
    /// EXAMPLE:
    /// - Receiving 1000 USDC deposit
    /// - debit(assetAccount, 1000e18) - Asset increases
    ///
    /// @param accountId The account to debit
    /// @param value The amount to debit (18 decimals)
    function debit(bytes32 accountId, uint128 value) external;

    /// @notice Record a credit (right-side entry)
    /// @dev Increases the account's credit total. For credit-normal accounts
    ///      (Equity, Liability, Gain, Loss), this increases the account value.
    ///
    /// EXAMPLE:
    /// - Receiving 1000 USDC deposit
    /// - credit(equityAccount, 1000e18) - Equity increases
    ///
    /// @param accountId The account to credit
    /// @param value The amount to credit (18 decimals)
    function credit(bytes32 accountId, uint128 value) external;

    /// @notice Create a new account in the chart of accounts
    /// @dev Each account must have a unique ID within the pool.
    ///
    /// @param poolId The pool to create the account in
    /// @param accountId Unique identifier (typically derived from asset/network + type)
    /// @param accountType The type of account (determines normal balance side)
    function createAccount(uint64 poolId, bytes32 accountId, AccountType accountType) external;

    // ============================================================
    // VIEW FUNCTIONS
    // ============================================================

    /// @notice Get the current value of an account
    /// @dev Calculates: debitTotal - creditTotal (for debit-normal)
    ///      or creditTotal - debitTotal (for credit-normal)
    ///
    /// EXAMPLE:
    /// - Asset account with 5000 debits, 2000 credits
    /// - Returns (true, 3000) - positive value of 3000
    ///
    /// @param poolId The pool context
    /// @param accountId The account to query
    /// @return isPositive True if the value is positive (or zero)
    /// @return value The absolute value of the account balance
    function accountValue(uint64 poolId, bytes32 accountId) external view returns (bool isPositive, uint128 value);

    /// @notice Get the raw debit and credit totals for an account
    /// @param poolId The pool context
    /// @param accountId The account to query
    /// @return totalDebit Sum of all debits to this account
    /// @return totalCredit Sum of all credits to this account
    function accountTotals(uint64 poolId, bytes32 accountId)
        external
        view
        returns (uint128 totalDebit, uint128 totalCredit);

    /// @notice Check if an account exists
    /// @param poolId The pool context
    /// @param accountId The account to check
    /// @return exists True if the account has been created
    function accountExists(uint64 poolId, bytes32 accountId) external view returns (bool exists);

    /// @notice Get the type of an account
    /// @param poolId The pool context
    /// @param accountId The account to query
    /// @return accountType The account type (Asset, Equity, etc.)
    function getAccountType(uint64 poolId, bytes32 accountId) external view returns (AccountType accountType);

    /// @notice Get the current journal ID counter for a pool
    /// @param poolId The pool to query
    /// @return journalId The next journal ID that will be assigned
    function currentJournalId(uint64 poolId) external view returns (uint256 journalId);

    /// @notice Check if the pool is currently unlocked for accounting
    /// @param poolId The pool to check
    /// @return unlocked True if unlock() has been called without lock()
    function isUnlocked(uint64 poolId) external view returns (bool unlocked);
}
