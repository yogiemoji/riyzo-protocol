// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {Root} from "src/admin/Root.sol";
import {FreelyTransferable} from "src/hooks/FreelyTransferable.sol";
import {HookData} from "src/interfaces/token/IHook.sol";

contract FreelyTransferableTest is Test {
    Root public root;
    FreelyTransferable public hook;

    address public admin = address(this);
    address public escrowAddr = address(0xE5);
    address public user1 = address(0x1);
    address public user2 = address(0x2);

    uint64 public validUntil;

    function setUp() public {
        root = new Root(escrowAddr, 0, admin);
        hook = new FreelyTransferable(address(root), escrowAddr, admin);

        validUntil = uint64(block.timestamp + 365 days);
    }

    function _hookData(bytes16 from, bytes16 to) internal pure returns (HookData memory) {
        return HookData({from: from, to: to});
    }

    function _memberData(uint64 until) internal pure returns (bytes16) {
        return bytes16(uint128(until) << 64);
    }

    function _frozenData() internal pure returns (bytes16) {
        return bytes16(uint128(1));
    }

    // --- Freeze blocks everything ---
    function test_frozenSource_blocked() public view {
        HookData memory hd = _hookData(_frozenData(), bytes16(0));
        assertFalse(hook.checkERC20Transfer(user1, user2, 100, hd));
    }

    function test_frozenTarget_blocked() public view {
        HookData memory hd = _hookData(bytes16(0), _frozenData());
        assertFalse(hook.checkERC20Transfer(user1, user2, 100, hd));
    }

    // --- Peer transfers always allowed ---
    function test_peerTransfer_noMembership_allowed() public view {
        HookData memory hd = _hookData(bytes16(0), bytes16(0));
        assertTrue(hook.checkERC20Transfer(user1, user2, 100, hd));
    }

    // --- Mint to non-escrow (deposit claim) requires target membership ---
    function test_depositClaim_member_allowed() public view {
        HookData memory hd = _hookData(bytes16(0), _memberData(validUntil));
        assertTrue(hook.checkERC20Transfer(address(0), user1, 100, hd));
    }

    function test_depositClaim_nonMember_blocked() public view {
        HookData memory hd = _hookData(bytes16(0), bytes16(0));
        assertFalse(hook.checkERC20Transfer(address(0), user1, 100, hd));
    }

    function test_depositClaim_expiredMember_blocked() public view {
        uint64 expired = uint64(block.timestamp - 1);
        HookData memory hd = _hookData(bytes16(0), _memberData(expired));
        assertFalse(hook.checkERC20Transfer(address(0), user1, 100, hd));
    }

    // --- Mint to escrow (deposit fulfillment) always allowed ---
    function test_mintToEscrow_allowed() public view {
        HookData memory hd = _hookData(bytes16(0), bytes16(0));
        assertTrue(hook.checkERC20Transfer(address(0), escrowAddr, 100, hd));
    }

    // --- Transfer to escrow (redeem request) requires source membership ---
    function test_redeemRequest_member_allowed() public view {
        HookData memory hd = _hookData(_memberData(validUntil), bytes16(0));
        assertTrue(hook.checkERC20Transfer(user1, escrowAddr, 100, hd));
    }

    function test_redeemRequest_nonMember_blocked() public view {
        HookData memory hd = _hookData(bytes16(0), bytes16(0));
        assertFalse(hook.checkERC20Transfer(user1, escrowAddr, 100, hd));
    }

    // --- Burn always allowed ---
    function test_burn_allowed() public view {
        HookData memory hd = _hookData(bytes16(0), bytes16(0));
        assertTrue(hook.checkERC20Transfer(user1, address(0), 100, hd));
    }
}
