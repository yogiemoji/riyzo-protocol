// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {Root} from "src/admin/Root.sol";
import {FreezeOnly} from "src/hooks/FreezeOnly.sol";
import {HookData} from "src/interfaces/token/IHook.sol";

contract FreezeOnlyTest is Test {
    Root public root;
    FreezeOnly public hook;

    address public admin = address(this);
    address public escrowAddr = address(0xE5);
    address public user1 = address(0x1);
    address public user2 = address(0x2);

    function setUp() public {
        root = new Root(escrowAddr, 0, admin);
        hook = new FreezeOnly(address(root), escrowAddr, admin);
    }

    function _hookData(bytes16 from, bytes16 to) internal pure returns (HookData memory) {
        return HookData({from: from, to: to});
    }

    function _frozenData() internal pure returns (bytes16) {
        return bytes16(uint128(1));
    }

    // --- Frozen source blocked ---
    function test_frozenSource_blocked() public view {
        HookData memory hd = _hookData(_frozenData(), bytes16(0));
        assertFalse(hook.checkERC20Transfer(user1, user2, 100, hd));
    }

    // --- Frozen target blocked ---
    function test_frozenTarget_blocked() public view {
        HookData memory hd = _hookData(bytes16(0), _frozenData());
        assertFalse(hook.checkERC20Transfer(user1, user2, 100, hd));
    }

    // --- Unfrozen always allowed (no memberlist) ---
    function test_unfrozen_allowed() public view {
        HookData memory hd = _hookData(bytes16(0), bytes16(0));
        assertTrue(hook.checkERC20Transfer(user1, user2, 100, hd));
    }

    // --- No memberlist check ---
    function test_nonMember_allowed() public view {
        // Target has no membership data, but still passes (FreezeOnly has no memberlist)
        HookData memory hd = _hookData(bytes16(0), bytes16(0));
        assertTrue(hook.checkERC20Transfer(user1, user2, 100, hd));
    }

    // --- Endorsed frozen source allowed ---
    function test_endorsedFrozenSource_allowed() public {
        root.endorse(user1);
        HookData memory hd = _hookData(_frozenData(), bytes16(0));
        assertTrue(hook.checkERC20Transfer(user1, user2, 100, hd));
    }

    // --- Both frozen blocked ---
    function test_bothFrozen_blocked() public view {
        HookData memory hd = _hookData(_frozenData(), _frozenData());
        assertFalse(hook.checkERC20Transfer(user1, user2, 100, hd));
    }
}
