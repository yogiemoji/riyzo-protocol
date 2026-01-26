// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {Accounting} from "src/core/hub/Accounting.sol";
import {IAccounting} from "src/interfaces/hub/IAccounting.sol";

/// @title AccountingTest - Unit tests for Accounting.sol
/// @notice Tests the double-entry bookkeeping system
contract AccountingTest is Test {
    Accounting public accounting;

    address public admin = address(this);
    address public user1 = address(0x1);

    uint64 public constant POOL_ID = 1;

    // Account IDs for testing
    bytes32 public constant ASSET_ACCOUNT = bytes32(uint256(1));
    bytes32 public constant EQUITY_ACCOUNT = bytes32(uint256(2));
    bytes32 public constant GAIN_ACCOUNT = bytes32(uint256(3));
    bytes32 public constant LOSS_ACCOUNT = bytes32(uint256(4));
    bytes32 public constant LIABILITY_ACCOUNT = bytes32(uint256(5));
    bytes32 public constant EXPENSE_ACCOUNT = bytes32(uint256(6));

    function setUp() public {
        accounting = new Accounting(admin);
    }

    // ============================================================
    // ACCOUNT CREATION TESTS
    // ============================================================

    function test_createAccount_asset() public {
        accounting.createAccount(POOL_ID, ASSET_ACCOUNT, IAccounting.AccountType.Asset);

        assertTrue(accounting.accountExists(POOL_ID, ASSET_ACCOUNT));
        assertEq(uint8(accounting.getAccountType(POOL_ID, ASSET_ACCOUNT)), uint8(IAccounting.AccountType.Asset));
    }

    function test_createAccount_equity() public {
        accounting.createAccount(POOL_ID, EQUITY_ACCOUNT, IAccounting.AccountType.Equity);

        assertTrue(accounting.accountExists(POOL_ID, EQUITY_ACCOUNT));
        assertEq(uint8(accounting.getAccountType(POOL_ID, EQUITY_ACCOUNT)), uint8(IAccounting.AccountType.Equity));
    }

    function test_createAccount_allTypes() public {
        accounting.createAccount(POOL_ID, ASSET_ACCOUNT, IAccounting.AccountType.Asset);
        accounting.createAccount(POOL_ID, EQUITY_ACCOUNT, IAccounting.AccountType.Equity);
        accounting.createAccount(POOL_ID, GAIN_ACCOUNT, IAccounting.AccountType.Gain);
        accounting.createAccount(POOL_ID, LOSS_ACCOUNT, IAccounting.AccountType.Loss);
        accounting.createAccount(POOL_ID, LIABILITY_ACCOUNT, IAccounting.AccountType.Liability);
        accounting.createAccount(POOL_ID, EXPENSE_ACCOUNT, IAccounting.AccountType.Expense);

        assertTrue(accounting.accountExists(POOL_ID, ASSET_ACCOUNT));
        assertTrue(accounting.accountExists(POOL_ID, EQUITY_ACCOUNT));
        assertTrue(accounting.accountExists(POOL_ID, GAIN_ACCOUNT));
        assertTrue(accounting.accountExists(POOL_ID, LOSS_ACCOUNT));
        assertTrue(accounting.accountExists(POOL_ID, LIABILITY_ACCOUNT));
        assertTrue(accounting.accountExists(POOL_ID, EXPENSE_ACCOUNT));
    }

    function test_createAccount_revert_duplicate() public {
        accounting.createAccount(POOL_ID, ASSET_ACCOUNT, IAccounting.AccountType.Asset);

        vm.expectRevert(abi.encodeWithSelector(IAccounting.AccountAlreadyExists.selector, ASSET_ACCOUNT));
        accounting.createAccount(POOL_ID, ASSET_ACCOUNT, IAccounting.AccountType.Asset);
    }

    function test_createAccount_revert_unauthorized() public {
        vm.prank(user1);
        vm.expectRevert("Auth/not-authorized");
        accounting.createAccount(POOL_ID, ASSET_ACCOUNT, IAccounting.AccountType.Asset);
    }

    // ============================================================
    // UNLOCK/LOCK TESTS
    // ============================================================

    function test_unlock_returnsJournalId() public {
        uint256 journalId = accounting.unlock(POOL_ID);
        assertEq(journalId, 1);

        accounting.lock();

        uint256 journalId2 = accounting.unlock(POOL_ID);
        assertEq(journalId2, 2);
    }

    function test_unlock_setsUnlockedState() public {
        assertFalse(accounting.isUnlocked(POOL_ID));

        accounting.unlock(POOL_ID);

        assertTrue(accounting.isUnlocked(POOL_ID));
    }

    function test_lock_clearsUnlockedState() public {
        accounting.unlock(POOL_ID);
        assertTrue(accounting.isUnlocked(POOL_ID));

        accounting.lock();

        assertFalse(accounting.isUnlocked(POOL_ID));
    }

    function test_lock_revert_notUnlocked() public {
        vm.expectRevert(IAccounting.NotUnlocked.selector);
        accounting.lock();
    }

    function test_unlock_revert_alreadyUnlocked() public {
        accounting.unlock(POOL_ID);

        vm.expectRevert(IAccounting.NotUnlocked.selector);
        accounting.unlock(POOL_ID);
    }

    // ============================================================
    // DEBIT/CREDIT TESTS
    // ============================================================

    function test_debitCredit_balanced() public {
        accounting.createAccount(POOL_ID, ASSET_ACCOUNT, IAccounting.AccountType.Asset);
        accounting.createAccount(POOL_ID, EQUITY_ACCOUNT, IAccounting.AccountType.Equity);

        accounting.unlock(POOL_ID);
        accounting.debit(ASSET_ACCOUNT, 1000e18);
        accounting.credit(EQUITY_ACCOUNT, 1000e18);
        accounting.lock();

        // Verify account values
        (bool isPositive, uint128 value) = accounting.accountValue(POOL_ID, ASSET_ACCOUNT);
        assertTrue(isPositive);
        assertEq(value, 1000e18);

        (isPositive, value) = accounting.accountValue(POOL_ID, EQUITY_ACCOUNT);
        assertTrue(isPositive);
        assertEq(value, 1000e18);
    }

    function test_debitCredit_multipleEntries() public {
        accounting.createAccount(POOL_ID, ASSET_ACCOUNT, IAccounting.AccountType.Asset);
        accounting.createAccount(POOL_ID, EQUITY_ACCOUNT, IAccounting.AccountType.Equity);
        accounting.createAccount(POOL_ID, GAIN_ACCOUNT, IAccounting.AccountType.Gain);

        accounting.unlock(POOL_ID);
        accounting.debit(ASSET_ACCOUNT, 1000e18);
        accounting.debit(ASSET_ACCOUNT, 500e18);
        accounting.credit(EQUITY_ACCOUNT, 1000e18);
        accounting.credit(GAIN_ACCOUNT, 500e18);
        accounting.lock();

        // Asset = 1500
        (bool isPositive, uint128 value) = accounting.accountValue(POOL_ID, ASSET_ACCOUNT);
        assertTrue(isPositive);
        assertEq(value, 1500e18);
    }

    function test_lock_revert_unbalanced() public {
        accounting.createAccount(POOL_ID, ASSET_ACCOUNT, IAccounting.AccountType.Asset);
        accounting.createAccount(POOL_ID, EQUITY_ACCOUNT, IAccounting.AccountType.Equity);

        accounting.unlock(POOL_ID);
        accounting.debit(ASSET_ACCOUNT, 1000e18);
        accounting.credit(EQUITY_ACCOUNT, 999e18); // 1 wei difference

        vm.expectRevert(abi.encodeWithSelector(IAccounting.UnbalancedEntries.selector, 1000e18, 999e18));
        accounting.lock();
    }

    function test_debit_revert_accountNotFound() public {
        accounting.unlock(POOL_ID);

        vm.expectRevert(abi.encodeWithSelector(IAccounting.AccountNotFound.selector, ASSET_ACCOUNT));
        accounting.debit(ASSET_ACCOUNT, 1000e18);
    }

    function test_credit_revert_accountNotFound() public {
        accounting.unlock(POOL_ID);

        vm.expectRevert(abi.encodeWithSelector(IAccounting.AccountNotFound.selector, EQUITY_ACCOUNT));
        accounting.credit(EQUITY_ACCOUNT, 1000e18);
    }

    function test_debit_revert_notUnlocked() public {
        accounting.createAccount(POOL_ID, ASSET_ACCOUNT, IAccounting.AccountType.Asset);

        vm.expectRevert(IAccounting.NotUnlocked.selector);
        accounting.debit(ASSET_ACCOUNT, 1000e18);
    }

    // ============================================================
    // ACCOUNT VALUE TESTS
    // ============================================================

    function test_accountValue_debitNormal() public {
        // Asset accounts are debit-normal: debits increase, credits decrease
        accounting.createAccount(POOL_ID, ASSET_ACCOUNT, IAccounting.AccountType.Asset);
        accounting.createAccount(POOL_ID, EQUITY_ACCOUNT, IAccounting.AccountType.Equity);

        // Deposit: debit asset, credit equity
        accounting.unlock(POOL_ID);
        accounting.debit(ASSET_ACCOUNT, 1000e18);
        accounting.credit(EQUITY_ACCOUNT, 1000e18);
        accounting.lock();

        // Withdraw some: debit equity, credit asset
        accounting.unlock(POOL_ID);
        accounting.debit(EQUITY_ACCOUNT, 300e18);
        accounting.credit(ASSET_ACCOUNT, 300e18);
        accounting.lock();

        // Asset should be 1000 - 300 = 700
        (bool isPositive, uint128 value) = accounting.accountValue(POOL_ID, ASSET_ACCOUNT);
        assertTrue(isPositive);
        assertEq(value, 700e18);
    }

    function test_accountValue_creditNormal() public {
        // Equity accounts are credit-normal: credits increase, debits decrease
        accounting.createAccount(POOL_ID, ASSET_ACCOUNT, IAccounting.AccountType.Asset);
        accounting.createAccount(POOL_ID, EQUITY_ACCOUNT, IAccounting.AccountType.Equity);

        // Deposit: debit asset, credit equity
        accounting.unlock(POOL_ID);
        accounting.debit(ASSET_ACCOUNT, 1000e18);
        accounting.credit(EQUITY_ACCOUNT, 1000e18);
        accounting.lock();

        // Equity should be 1000
        (bool isPositive, uint128 value) = accounting.accountValue(POOL_ID, EQUITY_ACCOUNT);
        assertTrue(isPositive);
        assertEq(value, 1000e18);
    }

    function test_accountTotals() public {
        accounting.createAccount(POOL_ID, ASSET_ACCOUNT, IAccounting.AccountType.Asset);
        accounting.createAccount(POOL_ID, EQUITY_ACCOUNT, IAccounting.AccountType.Equity);

        accounting.unlock(POOL_ID);
        accounting.debit(ASSET_ACCOUNT, 1000e18);
        accounting.credit(EQUITY_ACCOUNT, 1000e18);
        accounting.lock();

        accounting.unlock(POOL_ID);
        accounting.debit(EQUITY_ACCOUNT, 200e18);
        accounting.credit(ASSET_ACCOUNT, 200e18);
        accounting.lock();

        (uint128 totalDebit, uint128 totalCredit) = accounting.accountTotals(POOL_ID, ASSET_ACCOUNT);
        assertEq(totalDebit, 1000e18);
        assertEq(totalCredit, 200e18);
    }

    // ============================================================
    // JOURNAL ID TESTS
    // ============================================================

    function test_currentJournalId() public {
        assertEq(accounting.currentJournalId(POOL_ID), 0);

        accounting.unlock(POOL_ID);
        accounting.lock();

        assertEq(accounting.currentJournalId(POOL_ID), 1);

        accounting.unlock(POOL_ID);
        accounting.lock();

        assertEq(accounting.currentJournalId(POOL_ID), 2);
    }

    // ============================================================
    // AUTHORIZATION TESTS
    // ============================================================

    function test_rely_deny() public {
        // Grant user1 access
        accounting.rely(user1);

        // user1 can now create accounts
        vm.prank(user1);
        accounting.createAccount(POOL_ID, ASSET_ACCOUNT, IAccounting.AccountType.Asset);

        // Revoke access
        accounting.deny(user1);

        // user1 can no longer create accounts
        vm.prank(user1);
        vm.expectRevert("Auth/not-authorized");
        accounting.createAccount(POOL_ID, EQUITY_ACCOUNT, IAccounting.AccountType.Equity);
    }

    // ============================================================
    // MULTIPLE POOLS TESTS
    // ============================================================

    function test_multiplePools_independent() public {
        uint64 pool1 = 1;
        uint64 pool2 = 2;

        accounting.createAccount(pool1, ASSET_ACCOUNT, IAccounting.AccountType.Asset);
        accounting.createAccount(pool1, EQUITY_ACCOUNT, IAccounting.AccountType.Equity);

        accounting.createAccount(pool2, ASSET_ACCOUNT, IAccounting.AccountType.Asset);
        accounting.createAccount(pool2, EQUITY_ACCOUNT, IAccounting.AccountType.Equity);

        // Add to pool 1
        accounting.unlock(pool1);
        accounting.debit(ASSET_ACCOUNT, 1000e18);
        accounting.credit(EQUITY_ACCOUNT, 1000e18);
        accounting.lock();

        // Add to pool 2
        accounting.unlock(pool2);
        accounting.debit(ASSET_ACCOUNT, 5000e18);
        accounting.credit(EQUITY_ACCOUNT, 5000e18);
        accounting.lock();

        // Verify independent values
        (, uint128 value1) = accounting.accountValue(pool1, ASSET_ACCOUNT);
        (, uint128 value2) = accounting.accountValue(pool2, ASSET_ACCOUNT);

        assertEq(value1, 1000e18);
        assertEq(value2, 5000e18);
    }

    // ============================================================
    // EVENT TESTS
    // ============================================================

    function test_events_accountCreated() public {
        vm.expectEmit(true, true, false, true);
        emit IAccounting.AccountCreated(POOL_ID, ASSET_ACCOUNT, IAccounting.AccountType.Asset);

        accounting.createAccount(POOL_ID, ASSET_ACCOUNT, IAccounting.AccountType.Asset);
    }

    function test_events_journalEntryPosted() public {
        accounting.createAccount(POOL_ID, ASSET_ACCOUNT, IAccounting.AccountType.Asset);

        accounting.unlock(POOL_ID);

        vm.expectEmit(true, true, true, true);
        emit IAccounting.JournalEntryPosted(POOL_ID, 1, ASSET_ACCOUNT, true, 1000e18);

        accounting.debit(ASSET_ACCOUNT, 1000e18);
    }

    function test_events_journalCommitted() public {
        accounting.createAccount(POOL_ID, ASSET_ACCOUNT, IAccounting.AccountType.Asset);
        accounting.createAccount(POOL_ID, EQUITY_ACCOUNT, IAccounting.AccountType.Equity);

        accounting.unlock(POOL_ID);
        accounting.debit(ASSET_ACCOUNT, 1000e18);
        accounting.credit(EQUITY_ACCOUNT, 1000e18);

        vm.expectEmit(true, true, false, true);
        emit IAccounting.JournalCommitted(POOL_ID, 1, 1000e18, 1000e18);

        accounting.lock();
    }

    // ============================================================
    // FUZZ TESTS
    // ============================================================

    function testFuzz_balancedEntries(uint128 amount) public {
        vm.assume(amount > 0);
        vm.assume(amount < type(uint128).max / 2); // Prevent overflow

        accounting.createAccount(POOL_ID, ASSET_ACCOUNT, IAccounting.AccountType.Asset);
        accounting.createAccount(POOL_ID, EQUITY_ACCOUNT, IAccounting.AccountType.Equity);

        accounting.unlock(POOL_ID);
        accounting.debit(ASSET_ACCOUNT, amount);
        accounting.credit(EQUITY_ACCOUNT, amount);
        accounting.lock();

        (, uint128 value) = accounting.accountValue(POOL_ID, ASSET_ACCOUNT);
        assertEq(value, amount);
    }
}
