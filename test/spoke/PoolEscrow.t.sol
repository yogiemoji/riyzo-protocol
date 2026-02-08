// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {PoolEscrow} from "src/core/spoke/PoolEscrow.sol";
import {IPoolEscrow} from "src/interfaces/spoke/IPoolEscrow.sol";
import {MockERC20} from "test/mocks/MockERC20.sol";
import {MockEscrow} from "test/mocks/MockEscrow.sol";

/// @title PoolEscrowTest - Unit tests for PoolEscrow.sol
contract PoolEscrowTest is Test {
    PoolEscrow public poolEscrow;
    MockERC20 public usdc;
    MockEscrow public escrow;

    address public admin = address(this);
    address public user1 = address(0x1);
    address public user2 = address(0x2);
    address public unauthorized = address(0x999);

    uint64 public constant POOL_ID = 1;
    bytes16 public constant SC_ID = bytes16(uint128(1));

    function setUp() public {
        // Deploy mock contracts
        usdc = new MockERC20("USD Coin", "USDC", 6);
        escrow = new MockEscrow();

        // Deploy PoolEscrow
        poolEscrow = new PoolEscrow(admin, address(escrow));

        // Fund the escrow with USDC for redemption tests
        usdc.mint(address(escrow), 1_000_000e6);

        // Approve poolEscrow to transfer from escrow
        escrow.approveMax(address(usdc), address(poolEscrow));
    }

    // ============================================================
    // CONSTRUCTOR TESTS
    // ============================================================

    function test_constructor() public view {
        assertEq(poolEscrow.escrow(), address(escrow));
        assertEq(poolEscrow.wards(admin), 1);
    }

    function test_constructor_revert_zeroEscrow() public {
        vm.expectRevert("PoolEscrow/zero-escrow");
        new PoolEscrow(admin, address(0));
    }

    // ============================================================
    // DEPOSIT FLOW TESTS
    // ============================================================

    function test_recordDeposit() public {
        poolEscrow.recordDeposit(POOL_ID, SC_ID, address(usdc), 1000e6);

        assertEq(poolEscrow.pendingDepositBalance(POOL_ID, SC_ID, address(usdc)), 1000e6);
        assertEq(poolEscrow.availableBalance(POOL_ID, SC_ID, address(usdc)), 0);
    }

    function test_recordDeposit_multiple() public {
        poolEscrow.recordDeposit(POOL_ID, SC_ID, address(usdc), 1000e6);
        poolEscrow.recordDeposit(POOL_ID, SC_ID, address(usdc), 500e6);

        assertEq(poolEscrow.pendingDepositBalance(POOL_ID, SC_ID, address(usdc)), 1500e6);
    }

    function test_recordDeposit_revert_zeroAmount() public {
        vm.expectRevert(IPoolEscrow.ZeroAmount.selector);
        poolEscrow.recordDeposit(POOL_ID, SC_ID, address(usdc), 0);
    }

    function test_recordDeposit_revert_unauthorized() public {
        vm.prank(unauthorized);
        vm.expectRevert("Auth/not-authorized");
        poolEscrow.recordDeposit(POOL_ID, SC_ID, address(usdc), 1000e6);
    }

    function test_confirmDeposit() public {
        poolEscrow.recordDeposit(POOL_ID, SC_ID, address(usdc), 1000e6);
        poolEscrow.confirmDeposit(POOL_ID, SC_ID, address(usdc), 1000e6);

        assertEq(poolEscrow.pendingDepositBalance(POOL_ID, SC_ID, address(usdc)), 0);
        assertEq(poolEscrow.availableBalance(POOL_ID, SC_ID, address(usdc)), 1000e6);
    }

    function test_confirmDeposit_partial() public {
        poolEscrow.recordDeposit(POOL_ID, SC_ID, address(usdc), 1000e6);
        poolEscrow.confirmDeposit(POOL_ID, SC_ID, address(usdc), 400e6);

        assertEq(poolEscrow.pendingDepositBalance(POOL_ID, SC_ID, address(usdc)), 600e6);
        assertEq(poolEscrow.availableBalance(POOL_ID, SC_ID, address(usdc)), 400e6);
    }

    function test_confirmDeposit_revert_insufficient() public {
        poolEscrow.recordDeposit(POOL_ID, SC_ID, address(usdc), 500e6);

        vm.expectRevert(
            abi.encodeWithSelector(
                IPoolEscrow.InsufficientPendingDeposits.selector,
                POOL_ID, SC_ID, address(usdc), 1000e6, 500e6
            )
        );
        poolEscrow.confirmDeposit(POOL_ID, SC_ID, address(usdc), 1000e6);
    }

    // ============================================================
    // REDEEM FLOW TESTS
    // ============================================================

    function test_reserveForRedeem() public {
        // Setup: confirm deposit first
        poolEscrow.recordDeposit(POOL_ID, SC_ID, address(usdc), 1000e6);
        poolEscrow.confirmDeposit(POOL_ID, SC_ID, address(usdc), 1000e6);

        // Reserve for redeem
        poolEscrow.reserveForRedeem(POOL_ID, SC_ID, address(usdc), 400e6);

        assertEq(poolEscrow.availableBalance(POOL_ID, SC_ID, address(usdc)), 600e6);
        assertEq(poolEscrow.pendingRedeemBalance(POOL_ID, SC_ID, address(usdc)), 400e6);
    }

    function test_reserveForRedeem_revert_insufficient() public {
        poolEscrow.recordDeposit(POOL_ID, SC_ID, address(usdc), 500e6);
        poolEscrow.confirmDeposit(POOL_ID, SC_ID, address(usdc), 500e6);

        vm.expectRevert(
            abi.encodeWithSelector(
                IPoolEscrow.InsufficientBalance.selector,
                POOL_ID, SC_ID, address(usdc), 1000e6, 500e6
            )
        );
        poolEscrow.reserveForRedeem(POOL_ID, SC_ID, address(usdc), 1000e6);
    }

    function test_releaseToUser() public {
        // Setup
        poolEscrow.recordDeposit(POOL_ID, SC_ID, address(usdc), 1000e6);
        poolEscrow.confirmDeposit(POOL_ID, SC_ID, address(usdc), 1000e6);
        poolEscrow.reserveForRedeem(POOL_ID, SC_ID, address(usdc), 400e6);

        // Release to user
        poolEscrow.releaseToUser(POOL_ID, SC_ID, address(usdc), user1, 400e6);

        assertEq(poolEscrow.pendingRedeemBalance(POOL_ID, SC_ID, address(usdc)), 0);
        assertEq(usdc.balanceOf(user1), 400e6);
    }

    function test_releaseToUser_revert_zeroAddress() public {
        poolEscrow.recordDeposit(POOL_ID, SC_ID, address(usdc), 1000e6);
        poolEscrow.confirmDeposit(POOL_ID, SC_ID, address(usdc), 1000e6);
        poolEscrow.reserveForRedeem(POOL_ID, SC_ID, address(usdc), 400e6);

        vm.expectRevert(IPoolEscrow.ZeroAddress.selector);
        poolEscrow.releaseToUser(POOL_ID, SC_ID, address(usdc), address(0), 400e6);
    }

    // ============================================================
    // CANCELLATION FLOW TESTS
    // ============================================================

    function test_releaseDepositReservation() public {
        poolEscrow.recordDeposit(POOL_ID, SC_ID, address(usdc), 1000e6);

        poolEscrow.releaseDepositReservation(POOL_ID, SC_ID, address(usdc), 600e6);

        assertEq(poolEscrow.pendingDepositBalance(POOL_ID, SC_ID, address(usdc)), 400e6);
    }

    function test_releaseRedeemReservation() public {
        poolEscrow.recordDeposit(POOL_ID, SC_ID, address(usdc), 1000e6);
        poolEscrow.confirmDeposit(POOL_ID, SC_ID, address(usdc), 1000e6);
        poolEscrow.reserveForRedeem(POOL_ID, SC_ID, address(usdc), 400e6);

        poolEscrow.releaseRedeemReservation(POOL_ID, SC_ID, address(usdc), 400e6);

        assertEq(poolEscrow.pendingRedeemBalance(POOL_ID, SC_ID, address(usdc)), 0);
        assertEq(poolEscrow.availableBalance(POOL_ID, SC_ID, address(usdc)), 1000e6);
    }

    // ============================================================
    // EMERGENCY TESTS
    // ============================================================

    function test_emergencyWithdraw() public {
        poolEscrow.recordDeposit(POOL_ID, SC_ID, address(usdc), 1000e6);
        poolEscrow.confirmDeposit(POOL_ID, SC_ID, address(usdc), 500e6);

        poolEscrow.emergencyWithdraw(POOL_ID, SC_ID, address(usdc), user1, 700e6);

        // Should deduct from balance first (500), then pendingDeposits (200)
        assertEq(poolEscrow.availableBalance(POOL_ID, SC_ID, address(usdc)), 0);
        assertEq(poolEscrow.pendingDepositBalance(POOL_ID, SC_ID, address(usdc)), 300e6);
        assertEq(usdc.balanceOf(user1), 700e6);
    }

    function test_emergencyWithdraw_revert_unauthorized() public {
        poolEscrow.recordDeposit(POOL_ID, SC_ID, address(usdc), 1000e6);

        vm.prank(unauthorized);
        vm.expectRevert("Auth/not-authorized");
        poolEscrow.emergencyWithdraw(POOL_ID, SC_ID, address(usdc), user1, 500e6);
    }

    // ============================================================
    // VIEW FUNCTION TESTS
    // ============================================================

    function test_getAccount() public {
        poolEscrow.recordDeposit(POOL_ID, SC_ID, address(usdc), 1000e6);
        poolEscrow.confirmDeposit(POOL_ID, SC_ID, address(usdc), 600e6);
        poolEscrow.reserveForRedeem(POOL_ID, SC_ID, address(usdc), 200e6);

        IPoolEscrow.EscrowAccount memory account = poolEscrow.getAccount(POOL_ID, SC_ID, address(usdc));

        assertEq(account.balance, 400e6);
        assertEq(account.pendingDeposits, 400e6);
        assertEq(account.pendingRedeems, 200e6);
    }

    function test_totalAccountedBalance() public {
        poolEscrow.recordDeposit(POOL_ID, SC_ID, address(usdc), 1000e6);
        poolEscrow.confirmDeposit(POOL_ID, SC_ID, address(usdc), 600e6);
        poolEscrow.reserveForRedeem(POOL_ID, SC_ID, address(usdc), 200e6);

        uint128 total = poolEscrow.totalAccountedBalance(POOL_ID, SC_ID, address(usdc));

        // balance (400) + pendingDeposits (400) + pendingRedeems (200) = 1000
        assertEq(total, 1000e6);
    }

    // ============================================================
    // FUZZ TESTS
    // ============================================================

    function testFuzz_depositFlow(uint128 amount) public {
        vm.assume(amount > 0 && amount < type(uint128).max / 2);

        poolEscrow.recordDeposit(POOL_ID, SC_ID, address(usdc), amount);
        assertEq(poolEscrow.pendingDepositBalance(POOL_ID, SC_ID, address(usdc)), amount);

        poolEscrow.confirmDeposit(POOL_ID, SC_ID, address(usdc), amount);
        assertEq(poolEscrow.availableBalance(POOL_ID, SC_ID, address(usdc)), amount);
        assertEq(poolEscrow.pendingDepositBalance(POOL_ID, SC_ID, address(usdc)), 0);
    }
}
