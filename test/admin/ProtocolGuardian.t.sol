// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {Root} from "src/admin/Root.sol";
import {ProtocolGuardian} from "src/admin/ProtocolGuardian.sol";
import {MockSafe} from "test/mocks/MockSafe.sol";

/// @dev Safe mock that reverts on isOwner to test catch branch
contract RevertingSafe {
    function isOwner(address) external pure returns (bool) {
        revert("boom");
    }
}

contract ProtocolGuardianTest is Test {
    Root public root;
    ProtocolGuardian public guardian;
    MockSafe public safe;

    address public admin = address(this);
    address public safeOwner = address(0x1);
    address public nonOwner = address(0x2);
    address public escrow = address(0x99);

    function setUp() public {
        safe = new MockSafe();
        safe.setOwner(safeOwner, true);

        root = new Root(escrow, 0, admin);
        guardian = new ProtocolGuardian(address(safe), address(root));

        // Grant guardian ward on root
        root.rely(address(guardian));
    }

    // --- Pause ---
    function test_pause_bySafe() public {
        vm.prank(address(safe));
        guardian.pause();
        assertTrue(root.paused());
    }

    function test_pause_bySafeOwner() public {
        vm.prank(safeOwner);
        guardian.pause();
        assertTrue(root.paused());
    }

    function test_pause_revert_unauthorized() public {
        vm.prank(nonOwner);
        vm.expectRevert("ProtocolGuardian/not-the-authorized-safe-or-its-owner");
        guardian.pause();
    }

    // --- Unpause ---
    function test_unpause_bySafe() public {
        vm.prank(address(safe));
        guardian.pause();

        vm.prank(address(safe));
        guardian.unpause();
        assertFalse(root.paused());
    }

    function test_unpause_revert_bySafeOwner() public {
        vm.prank(address(safe));
        guardian.pause();

        vm.prank(safeOwner);
        vm.expectRevert("ProtocolGuardian/not-the-authorized-safe");
        guardian.unpause();
    }

    // --- ScheduleRely ---
    function test_scheduleRely_bySafe() public {
        address target = address(0x3);
        vm.prank(address(safe));
        guardian.scheduleRely(target);
        assertTrue(root.schedule(target) > 0);
    }

    function test_scheduleRely_revert_bySafeOwner() public {
        vm.prank(safeOwner);
        vm.expectRevert("ProtocolGuardian/not-the-authorized-safe");
        guardian.scheduleRely(address(0x3));
    }

    // --- CancelRely ---
    function test_cancelRely_bySafe() public {
        address target = address(0x3);
        vm.prank(address(safe));
        guardian.scheduleRely(target);

        vm.prank(address(safe));
        guardian.cancelRely(target);
        assertEq(root.schedule(target), 0);
    }

    function test_cancelRely_revert_bySafeOwner() public {
        address target = address(0x3);
        vm.prank(address(safe));
        guardian.scheduleRely(target);

        vm.prank(safeOwner);
        vm.expectRevert("ProtocolGuardian/not-the-authorized-safe");
        guardian.cancelRely(target);
    }

    // --- _isSafeOwner catch branch ---
    function test_pause_revert_whenSafeReverts() public {
        RevertingSafe badSafe = new RevertingSafe();
        ProtocolGuardian badGuardian = new ProtocolGuardian(address(badSafe), address(root));
        root.rely(address(badGuardian));

        // Caller is not the safe itself, and isOwner reverts — catch returns false
        vm.prank(address(0x77));
        vm.expectRevert("ProtocolGuardian/not-the-authorized-safe-or-its-owner");
        badGuardian.pause();
    }
}
