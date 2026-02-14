// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {Root} from "src/admin/Root.sol";
import {FullRestrictions} from "src/hooks/FullRestrictions.sol";
import {IHook, HookData} from "src/interfaces/token/IHook.sol";
import {IERC165} from "src/interfaces/IERC7575.sol";
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

    // ============================================================
    // BASE CLASS METHOD TESTS (BaseTransferHook coverage)
    // ============================================================

    // --- freeze ---
    function test_freeze_setsHookData() public {
        hook.freeze(address(token), user1);
        assertTrue(hook.isFrozen(address(token), user1));
    }

    function test_freeze_revert_zeroAddress() public {
        vm.expectRevert("BaseTransferHook/cannot-freeze-zero-address");
        hook.freeze(address(token), address(0));
    }

    function test_freeze_revert_endorsedUser() public {
        root.endorse(user1);
        vm.expectRevert("BaseTransferHook/endorsed-user-cannot-be-frozen");
        hook.freeze(address(token), user1);
    }

    function test_freeze_revert_unauthorized() public {
        vm.prank(user1);
        vm.expectRevert("Auth/not-authorized");
        hook.freeze(address(token), user2);
    }

    // --- unfreeze ---
    function test_unfreeze_clearsHookData() public {
        hook.freeze(address(token), user1);
        assertTrue(hook.isFrozen(address(token), user1));

        hook.unfreeze(address(token), user1);
        assertFalse(hook.isFrozen(address(token), user1));
    }

    function test_unfreeze_revert_unauthorized() public {
        vm.prank(user1);
        vm.expectRevert("Auth/not-authorized");
        hook.unfreeze(address(token), user2);
    }

    // --- updateMember ---
    function test_updateMember_setsMembership() public {
        hook.updateMember(address(token), user1, validUntil);

        (bool isValid, uint64 until) = hook.isMember(address(token), user1);
        assertTrue(isValid);
        assertEq(until, validUntil);
    }

    function test_updateMember_revert_expiredValidUntil() public {
        vm.expectRevert("BaseTransferHook/invalid-valid-until");
        hook.updateMember(address(token), user1, uint64(block.timestamp - 1));
    }

    function test_updateMember_revert_endorsedUser() public {
        root.endorse(user1);
        vm.expectRevert("BaseTransferHook/endorsed-user-cannot-be-updated");
        hook.updateMember(address(token), user1, validUntil);
    }

    function test_updateMember_revert_unauthorized() public {
        vm.prank(user1);
        vm.expectRevert("Auth/not-authorized");
        hook.updateMember(address(token), user2, validUntil);
    }

    function test_updateMember_preservesFreezeState() public {
        hook.freeze(address(token), user1);
        hook.updateMember(address(token), user1, validUntil);

        assertTrue(hook.isFrozen(address(token), user1));
        (bool isValid,) = hook.isMember(address(token), user1);
        assertTrue(isValid);
    }

    // --- batchUpdateMember ---
    function test_batchUpdateMember_success() public {
        address[] memory users = new address[](2);
        users[0] = user1;
        users[1] = user2;
        uint64[] memory validUntils = new uint64[](2);
        validUntils[0] = validUntil;
        validUntils[1] = validUntil;

        hook.batchUpdateMember(address(token), users, validUntils);

        (bool isValid1,) = hook.isMember(address(token), user1);
        (bool isValid2,) = hook.isMember(address(token), user2);
        assertTrue(isValid1);
        assertTrue(isValid2);
    }

    function test_batchUpdateMember_revert_lengthMismatch() public {
        address[] memory users = new address[](2);
        users[0] = user1;
        users[1] = user2;
        uint64[] memory validUntils = new uint64[](1);
        validUntils[0] = validUntil;

        vm.expectRevert("BaseTransferHook/array-length-mismatch");
        hook.batchUpdateMember(address(token), users, validUntils);
    }

    // --- isMember ---
    function test_isMember_notMember() public view {
        (bool isValid, uint64 until) = hook.isMember(address(token), user1);
        assertFalse(isValid);
        assertEq(until, 0);
    }

    // --- updateRestriction (message dispatch) ---
    function test_updateRestriction_updateMember() public {
        // BytesLib.toAddress(1) reads 20 bytes at offset 1 = address
        // BytesLib.toUint64(33) reads 8 bytes at offset 33 = validUntil
        // Format: [type(1)][address(20)][padding(12)][validUntil(8)] = 41 bytes
        bytes memory update = abi.encodePacked(
            uint8(1), // RestrictionUpdate.UpdateMember
            user1, // 20 bytes address
            bytes12(0), // 12 bytes padding
            validUntil // 8 bytes uint64
        );
        hook.updateRestriction(address(token), update);

        (bool isValid,) = hook.isMember(address(token), user1);
        assertTrue(isValid);
    }

    function test_updateRestriction_freeze() public {
        // toAddress(1) reads 20 bytes starting at offset 1
        bytes memory update = abi.encodePacked(uint8(2), user1); // RestrictionUpdate.Freeze = 2
        hook.updateRestriction(address(token), update);
        assertTrue(hook.isFrozen(address(token), user1));
    }

    function test_updateRestriction_unfreeze() public {
        hook.freeze(address(token), user1);

        bytes memory update = abi.encodePacked(uint8(3), user1); // RestrictionUpdate.Unfreeze = 3
        hook.updateRestriction(address(token), update);
        assertFalse(hook.isFrozen(address(token), user1));
    }

    function test_updateRestriction_batchUpdateMember() public {
        // Format: [type(1), count_hi(1), count_lo(1), {user(20), validUntil(8)}...]
        bytes memory update = abi.encodePacked(
            uint8(4), // RestrictionUpdate.BatchUpdateMember = 4
            uint8(0), // count high byte
            uint8(2), // count low byte = 2 users
            user1,
            validUntil,
            user2,
            validUntil
        );
        hook.updateRestriction(address(token), update);

        (bool isValid1,) = hook.isMember(address(token), user1);
        (bool isValid2,) = hook.isMember(address(token), user2);
        assertTrue(isValid1);
        assertTrue(isValid2);
    }

    function test_updateRestriction_revert_invalidUpdate() public {
        bytes memory update = abi.encodePacked(uint8(255));
        vm.expectRevert();
        hook.updateRestriction(address(token), update);
    }

    function test_updateRestriction_revert_unauthorized() public {
        bytes memory update = abi.encodePacked(uint8(2), user1);
        vm.prank(user1);
        vm.expectRevert("Auth/not-authorized");
        hook.updateRestriction(address(token), update);
    }

    // --- supportsInterface ---
    function test_supportsInterface_IHook() public view {
        assertTrue(hook.supportsInterface(type(IHook).interfaceId));
    }

    function test_supportsInterface_IERC165() public view {
        assertTrue(hook.supportsInterface(type(IERC165).interfaceId));
    }

    function test_supportsInterface_unsupported() public view {
        assertFalse(hook.supportsInterface(bytes4(0xdeadbeef)));
    }
}
