// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {BalanceSheet} from "src/core/spoke/BalanceSheet.sol";
import {IBalanceSheet} from "src/interfaces/spoke/IBalanceSheet.sol";
import {MockShareToken} from "test/mocks/MockShareToken.sol";

/// @title BalanceSheetTest - Unit tests for BalanceSheet.sol
contract BalanceSheetTest is Test {
    BalanceSheet public balanceSheet;
    MockShareToken public shareToken;

    address public admin = address(this);
    address public user1 = address(0x1);
    address public user2 = address(0x2);
    address public user3 = address(0x3);
    address public unauthorized = address(0x999);

    uint64 public constant POOL_ID = 1;
    bytes16 public constant SC_ID = bytes16(uint128(1));

    function setUp() public {
        // Deploy contracts
        balanceSheet = new BalanceSheet(admin);
        shareToken = new MockShareToken("Share Token", "ST");

        // Register share token
        balanceSheet.setShareToken(POOL_ID, SC_ID, address(shareToken));
    }

    // ============================================================
    // CONFIGURATION TESTS
    // ============================================================

    function test_setShareToken() public {
        MockShareToken newToken = new MockShareToken("New Token", "NT");
        uint64 newPoolId = 2;
        bytes16 newScId = bytes16(uint128(2));

        balanceSheet.setShareToken(newPoolId, newScId, address(newToken));

        assertEq(balanceSheet.getShareToken(newPoolId, newScId), address(newToken));
    }

    function test_setShareToken_revert_zeroAddress() public {
        vm.expectRevert("BalanceSheet/zero-address");
        balanceSheet.setShareToken(POOL_ID, SC_ID, address(0));
    }

    function test_setShareToken_revert_unauthorized() public {
        vm.prank(unauthorized);
        vm.expectRevert("Auth/not-authorized");
        balanceSheet.setShareToken(POOL_ID, SC_ID, address(shareToken));
    }

    // ============================================================
    // SHARE ISSUANCE TESTS
    // ============================================================

    function test_issueShares() public {
        balanceSheet.issueShares(POOL_ID, SC_ID, user1, 1000e18);

        assertEq(shareToken.balanceOf(user1), 1000e18);
        assertEq(balanceSheet.issuanceNonce(POOL_ID, SC_ID), 1);
    }

    function test_issueShares_multiple() public {
        balanceSheet.issueShares(POOL_ID, SC_ID, user1, 1000e18);
        balanceSheet.issueShares(POOL_ID, SC_ID, user2, 500e18);

        assertEq(shareToken.balanceOf(user1), 1000e18);
        assertEq(shareToken.balanceOf(user2), 500e18);
        assertEq(balanceSheet.issuanceNonce(POOL_ID, SC_ID), 2);
    }

    function test_issueShares_revert_zeroShares() public {
        vm.expectRevert(IBalanceSheet.ZeroShares.selector);
        balanceSheet.issueShares(POOL_ID, SC_ID, user1, 0);
    }

    function test_issueShares_revert_tokenNotFound() public {
        uint64 unknownPool = 999;
        vm.expectRevert(abi.encodeWithSelector(IBalanceSheet.ShareTokenNotFound.selector, unknownPool, SC_ID));
        balanceSheet.issueShares(unknownPool, SC_ID, user1, 1000e18);
    }

    function test_issueShares_revert_unauthorized() public {
        vm.prank(unauthorized);
        vm.expectRevert("Auth/not-authorized");
        balanceSheet.issueShares(POOL_ID, SC_ID, user1, 1000e18);
    }

    // ============================================================
    // SHARE REVOCATION TESTS
    // ============================================================

    function test_revokeShares() public {
        // First issue shares
        balanceSheet.issueShares(POOL_ID, SC_ID, user1, 1000e18);

        // Then revoke
        balanceSheet.revokeShares(POOL_ID, SC_ID, user1, 400e18);

        assertEq(shareToken.balanceOf(user1), 600e18);
        assertEq(balanceSheet.revocationNonce(POOL_ID, SC_ID), 1);
    }

    function test_revokeShares_revert_zeroShares() public {
        vm.expectRevert(IBalanceSheet.ZeroShares.selector);
        balanceSheet.revokeShares(POOL_ID, SC_ID, user1, 0);
    }

    // ============================================================
    // BATCH OPERATIONS TESTS
    // ============================================================

    function test_batchIssue() public {
        address[] memory users = new address[](3);
        users[0] = user1;
        users[1] = user2;
        users[2] = user3;

        uint128[] memory shares = new uint128[](3);
        shares[0] = 1000e18;
        shares[1] = 500e18;
        shares[2] = 750e18;

        balanceSheet.batchIssue(POOL_ID, SC_ID, users, shares);

        assertEq(shareToken.balanceOf(user1), 1000e18);
        assertEq(shareToken.balanceOf(user2), 500e18);
        assertEq(shareToken.balanceOf(user3), 750e18);
        assertEq(balanceSheet.issuanceNonce(POOL_ID, SC_ID), 3);
    }

    function test_batchIssue_skipsZero() public {
        address[] memory users = new address[](3);
        users[0] = user1;
        users[1] = user2;
        users[2] = user3;

        uint128[] memory shares = new uint128[](3);
        shares[0] = 1000e18;
        shares[1] = 0; // Should be skipped
        shares[2] = 750e18;

        balanceSheet.batchIssue(POOL_ID, SC_ID, users, shares);

        assertEq(shareToken.balanceOf(user1), 1000e18);
        assertEq(shareToken.balanceOf(user2), 0);
        assertEq(shareToken.balanceOf(user3), 750e18);
    }

    function test_batchIssue_revert_lengthMismatch() public {
        address[] memory users = new address[](2);
        uint128[] memory shares = new uint128[](3);

        vm.expectRevert(abi.encodeWithSelector(IBalanceSheet.ArrayLengthMismatch.selector, 2, 3));
        balanceSheet.batchIssue(POOL_ID, SC_ID, users, shares);
    }

    function test_batchRevoke() public {
        // First batch issue
        address[] memory users = new address[](2);
        users[0] = user1;
        users[1] = user2;

        uint128[] memory issueShares = new uint128[](2);
        issueShares[0] = 1000e18;
        issueShares[1] = 500e18;

        balanceSheet.batchIssue(POOL_ID, SC_ID, users, issueShares);

        // Then batch revoke
        uint128[] memory revokeShares = new uint128[](2);
        revokeShares[0] = 400e18;
        revokeShares[1] = 200e18;

        balanceSheet.batchRevoke(POOL_ID, SC_ID, users, revokeShares);

        assertEq(shareToken.balanceOf(user1), 600e18);
        assertEq(shareToken.balanceOf(user2), 300e18);
        assertEq(balanceSheet.revocationNonce(POOL_ID, SC_ID), 2);
    }

    // ============================================================
    // QUEUE MANAGEMENT TESTS
    // ============================================================

    function test_queueIssuance() public {
        balanceSheet.queueIssuance(POOL_ID, SC_ID, user1, 1000e18, 1);

        assertEq(balanceSheet.pendingIssuanceCount(POOL_ID, SC_ID), 1);
        assertEq(shareToken.balanceOf(user1), 0); // Not yet issued
    }

    function test_queueIssuance_multiple() public {
        balanceSheet.queueIssuance(POOL_ID, SC_ID, user1, 1000e18, 1);
        balanceSheet.queueIssuance(POOL_ID, SC_ID, user2, 500e18, 1);
        balanceSheet.queueIssuance(POOL_ID, SC_ID, user3, 750e18, 2);

        assertEq(balanceSheet.pendingIssuanceCount(POOL_ID, SC_ID), 3);
    }

    function test_processIssuanceQueue() public {
        balanceSheet.queueIssuance(POOL_ID, SC_ID, user1, 1000e18, 1);
        balanceSheet.queueIssuance(POOL_ID, SC_ID, user2, 500e18, 1);

        uint256 processed = balanceSheet.processIssuanceQueue(POOL_ID, SC_ID, 10);

        assertEq(processed, 2);
        assertEq(balanceSheet.pendingIssuanceCount(POOL_ID, SC_ID), 0);
        assertEq(shareToken.balanceOf(user1), 1000e18);
        assertEq(shareToken.balanceOf(user2), 500e18);
    }

    function test_processIssuanceQueue_partial() public {
        balanceSheet.queueIssuance(POOL_ID, SC_ID, user1, 1000e18, 1);
        balanceSheet.queueIssuance(POOL_ID, SC_ID, user2, 500e18, 1);
        balanceSheet.queueIssuance(POOL_ID, SC_ID, user3, 750e18, 2);

        uint256 processed = balanceSheet.processIssuanceQueue(POOL_ID, SC_ID, 2);

        assertEq(processed, 2);
        assertEq(balanceSheet.pendingIssuanceCount(POOL_ID, SC_ID), 1);
        assertEq(shareToken.balanceOf(user1), 1000e18);
        assertEq(shareToken.balanceOf(user2), 500e18);
        assertEq(shareToken.balanceOf(user3), 0); // Not yet processed
    }

    function test_processIssuanceQueue_revert_empty() public {
        vm.expectRevert(abi.encodeWithSelector(IBalanceSheet.QueueEmpty.selector, POOL_ID, SC_ID));
        balanceSheet.processIssuanceQueue(POOL_ID, SC_ID, 10);
    }

    function test_queueRevocation() public {
        // Issue shares first
        balanceSheet.issueShares(POOL_ID, SC_ID, user1, 1000e18);

        balanceSheet.queueRevocation(POOL_ID, SC_ID, user1, 400e18, 1);

        assertEq(balanceSheet.pendingRevocationCount(POOL_ID, SC_ID), 1);
        assertEq(shareToken.balanceOf(user1), 1000e18); // Not yet revoked
    }

    function test_processRevocationQueue() public {
        balanceSheet.issueShares(POOL_ID, SC_ID, user1, 1000e18);
        balanceSheet.issueShares(POOL_ID, SC_ID, user2, 500e18);

        balanceSheet.queueRevocation(POOL_ID, SC_ID, user1, 400e18, 1);
        balanceSheet.queueRevocation(POOL_ID, SC_ID, user2, 200e18, 1);

        uint256 processed = balanceSheet.processRevocationQueue(POOL_ID, SC_ID, 10);

        assertEq(processed, 2);
        assertEq(balanceSheet.pendingRevocationCount(POOL_ID, SC_ID), 0);
        assertEq(shareToken.balanceOf(user1), 600e18);
        assertEq(shareToken.balanceOf(user2), 300e18);
    }

    // ============================================================
    // VIEW FUNCTION TESTS
    // ============================================================

    function test_getShareToken() public view {
        assertEq(balanceSheet.getShareToken(POOL_ID, SC_ID), address(shareToken));
    }

    function test_nonces() public {
        assertEq(balanceSheet.issuanceNonce(POOL_ID, SC_ID), 0);
        assertEq(balanceSheet.revocationNonce(POOL_ID, SC_ID), 0);

        balanceSheet.issueShares(POOL_ID, SC_ID, user1, 1000e18);
        assertEq(balanceSheet.issuanceNonce(POOL_ID, SC_ID), 1);

        balanceSheet.revokeShares(POOL_ID, SC_ID, user1, 500e18);
        assertEq(balanceSheet.revocationNonce(POOL_ID, SC_ID), 1);
    }

    // ============================================================
    // FUZZ TESTS
    // ============================================================

    function testFuzz_issueAndRevoke(uint128 issueAmount, uint128 revokeAmount) public {
        vm.assume(issueAmount > 0 && issueAmount < type(uint128).max);
        vm.assume(revokeAmount > 0 && revokeAmount <= issueAmount);

        balanceSheet.issueShares(POOL_ID, SC_ID, user1, issueAmount);
        assertEq(shareToken.balanceOf(user1), issueAmount);

        balanceSheet.revokeShares(POOL_ID, SC_ID, user1, revokeAmount);
        assertEq(shareToken.balanceOf(user1), issueAmount - revokeAmount);
    }
}
