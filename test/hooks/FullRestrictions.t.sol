// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {Root} from "src/admin/Root.sol";
import {FullRestrictions} from "src/hooks/FullRestrictions.sol";
import {HookData} from "src/interfaces/token/IHook.sol";
import {MockTranche} from "test/mocks/MockTranche.sol";

contract FullRestrictionsTest is Test {
    Root public root;
    FullRestrictions public hook;
    MockTranche public token;

    address public admin = address(this);
    address public escrowAddr = address(0xE5);
    address public user1 = address(0x1);
    address public user2 = address(0x2);

    uint64 public validUntil;

    function setUp() public {
        root = new Root(escrowAddr, 0, admin);
        hook = new FullRestrictions(address(root), escrowAddr, admin);
        token = new MockTranche();

        validUntil = uint64(block.timestamp + 365 days);

        // Endorse escrow so it bypasses checks
        root.endorse(escrowAddr);
    }

    // --- Helper to build HookData ---
    function _hookData(bytes16 from, bytes16 to) internal pure returns (HookData memory) {
        return HookData({from: from, to: to});
    }

    function _memberData(uint64 until) internal pure returns (bytes16) {
        return bytes16(uint128(until) << 64);
    }

    function _frozenData() internal pure returns (bytes16) {
        return bytes16(uint128(1)); // LSB = frozen
    }

    function _memberAndFrozenData(uint64 until) internal pure returns (bytes16) {
        return bytes16((uint128(until) << 64) | 1);
    }

    // --- Frozen source blocked ---
    function test_frozenSource_blocked() public view {
        HookData memory hd = _hookData(_frozenData(), _memberData(validUntil));
        assertFalse(hook.checkERC20Transfer(user1, user2, 100, hd));
    }

    function test_frozenSource_endorsed_allowed() public {
        root.endorse(user1);
        HookData memory hd = _hookData(_frozenData(), _memberData(validUntil));
        assertTrue(hook.checkERC20Transfer(user1, user2, 100, hd));
    }

    // --- Frozen target blocked ---
    function test_frozenTarget_blocked() public view {
        HookData memory hd = _hookData(bytes16(0), _frozenData());
        assertFalse(hook.checkERC20Transfer(user1, user2, 100, hd));
    }

    // --- Mint to escrow (deposit fulfillment) ---
    function test_mintToEscrow_allowed() public view {
        HookData memory hd = _hookData(bytes16(0), bytes16(0));
        assertTrue(hook.checkERC20Transfer(address(0), escrowAddr, 100, hd));
    }

    // --- Burn (redeem) ---
    function test_burn_allowed() public view {
        HookData memory hd = _hookData(bytes16(0), bytes16(0));
        assertTrue(hook.checkERC20Transfer(user1, address(0), 100, hd));
    }

    // --- Target membership required ---
    function test_transfer_targetMember_allowed() public view {
        HookData memory hd = _hookData(bytes16(0), _memberData(validUntil));
        assertTrue(hook.checkERC20Transfer(user1, user2, 100, hd));
    }

    function test_transfer_targetNotMember_blocked() public view {
        HookData memory hd = _hookData(bytes16(0), bytes16(0));
        assertFalse(hook.checkERC20Transfer(user1, user2, 100, hd));
    }

    function test_transfer_targetExpiredMember_blocked() public view {
        uint64 expired = uint64(block.timestamp - 1);
        HookData memory hd = _hookData(bytes16(0), _memberData(expired));
        assertFalse(hook.checkERC20Transfer(user1, user2, 100, hd));
    }

    // --- Endorsed target bypasses membership ---
    function test_endorsedTarget_bypasses_membership() public {
        root.endorse(user2);
        HookData memory hd = _hookData(bytes16(0), bytes16(0));
        assertTrue(hook.checkERC20Transfer(user1, user2, 100, hd));
    }

    // --- onERC20Transfer reverts when blocked ---
    function test_onERC20Transfer_revert_blocked() public {
        HookData memory hd = _hookData(bytes16(0), bytes16(0));
        vm.expectRevert("BaseTransferHook/transfer-blocked");
        hook.onERC20Transfer(user1, user2, 100, hd);
    }

    // --- onERC20AuthTransfer always succeeds ---
    function test_onERC20AuthTransfer_always_succeeds() public view {
        HookData memory hd = _hookData(bytes16(0), bytes16(0));
        bytes4 result = hook.onERC20AuthTransfer(admin, user1, user2, 100, hd);
        assertEq(result, hook.onERC20AuthTransfer.selector);
    }
}
