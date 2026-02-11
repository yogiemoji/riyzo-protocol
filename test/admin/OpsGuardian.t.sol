// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {Root} from "src/admin/Root.sol";
import {OpsGuardian} from "src/admin/OpsGuardian.sol";
import {NAVGuard} from "src/core/hub/NAVGuard.sol";
import {ShareClassManager} from "src/core/hub/ShareClassManager.sol";
import {NAVManager} from "src/core/hub/NAVManager.sol";
import {Accounting} from "src/core/hub/Accounting.sol";
import {Holdings} from "src/core/hub/Holdings.sol";
import {MockSafe} from "test/mocks/MockSafe.sol";
import {MockERC20} from "test/mocks/MockERC20.sol";
import {SafeTransferLib} from "src/core/libraries/SafeTransferLib.sol";

/// @dev Simple contract that implements recoverTokens for testing
contract RecoverableVault {
    mapping(address => uint256) public wards;

    constructor(address ward) {
        wards[ward] = 1;
    }

    function recoverTokens(address token, address to, uint256 amount) external {
        require(wards[msg.sender] == 1, "Auth/not-authorized");
        SafeTransferLib.safeTransfer(token, to, amount);
    }
}

contract OpsGuardianTest is Test {
    Root public root;
    NAVGuard public navGuard;
    OpsGuardian public opsGuardian;
    MockSafe public safe;
    ShareClassManager public scm;
    NAVManager public navManager;
    Accounting public accounting;
    Holdings public holdings;

    address public admin = address(this);
    address public safeOwner = address(0x1);
    address public nonOwner = address(0x2);
    address public escrow = address(0x99);

    uint64 public constant POOL_ID = 1;

    function setUp() public {
        safe = new MockSafe();
        safe.setOwner(safeOwner, true);

        root = new Root(escrow, 0, admin);

        // Deploy NAVGuard dependencies
        accounting = new Accounting(admin);
        holdings = new Holdings(admin, accounting);
        scm = new ShareClassManager(admin);
        navManager = new NAVManager(admin, accounting, holdings);
        navGuard = new NAVGuard(admin, address(scm), address(navManager));

        // Deploy OpsGuardian
        opsGuardian = new OpsGuardian(address(safe), address(root), address(navGuard));

        // Wire auth: OpsGuardian needs ward on NAVGuard and Root
        navGuard.rely(address(opsGuardian));
        root.rely(address(opsGuardian));
    }

    // --- PausePool ---
    function test_pausePool_bySafe() public {
        vm.prank(address(safe));
        opsGuardian.pausePool(POOL_ID);
        assertTrue(navGuard.isPaused(POOL_ID));
    }

    function test_pausePool_bySafeOwner() public {
        vm.prank(safeOwner);
        opsGuardian.pausePool(POOL_ID);
        assertTrue(navGuard.isPaused(POOL_ID));
    }

    function test_pausePool_revert_unauthorized() public {
        vm.prank(nonOwner);
        vm.expectRevert("OpsGuardian/not-the-authorized-safe-or-its-owner");
        opsGuardian.pausePool(POOL_ID);
    }

    // --- UnpausePool ---
    function test_unpausePool_bySafe() public {
        vm.prank(address(safe));
        opsGuardian.pausePool(POOL_ID);

        vm.prank(address(safe));
        opsGuardian.unpausePool(POOL_ID);
        assertFalse(navGuard.isPaused(POOL_ID));
    }

    function test_unpausePool_revert_bySafeOwner() public {
        vm.prank(address(safe));
        opsGuardian.pausePool(POOL_ID);

        vm.prank(safeOwner);
        vm.expectRevert("OpsGuardian/not-the-authorized-safe");
        opsGuardian.unpausePool(POOL_ID);
    }

    function test_unpausePool_revert_unauthorized() public {
        vm.prank(nonOwner);
        vm.expectRevert("OpsGuardian/not-the-authorized-safe");
        opsGuardian.unpausePool(POOL_ID);
    }

    // --- ConfigureGuard ---
    function test_configureGuard_bySafe() public {
        vm.prank(address(safe));
        opsGuardian.configureGuard(POOL_ID, 500, 7200, true);

        NAVGuard.GuardConfig memory config = navGuard.getGuardConfig(POOL_ID);
        assertEq(config.maxPriceChangeBps, 500);
        assertEq(config.maxStalenessSeconds, 7200);
        assertTrue(config.enforceLimits);
    }

    function test_configureGuard_revert_bySafeOwner() public {
        vm.prank(safeOwner);
        vm.expectRevert("OpsGuardian/not-the-authorized-safe");
        opsGuardian.configureGuard(POOL_ID, 500, 7200, true);
    }

    function test_configureGuard_revert_unauthorized() public {
        vm.prank(nonOwner);
        vm.expectRevert("OpsGuardian/not-the-authorized-safe");
        opsGuardian.configureGuard(POOL_ID, 500, 7200, true);
    }

    // --- RecoverTokens ---
    function test_recoverTokens_bySafe() public {
        // Deploy a recoverable vault with Root as ward, send tokens to it
        RecoverableVault vault = new RecoverableVault(address(root));
        MockERC20 token = new MockERC20("Test", "TST", 18);
        token.mint(address(vault), 1000e18);

        vm.prank(address(safe));
        opsGuardian.recoverTokens(address(vault), address(token), admin, 1000e18);

        assertEq(token.balanceOf(admin), 1000e18);
    }

    function test_recoverTokens_revert_bySafeOwner() public {
        vm.prank(safeOwner);
        vm.expectRevert("OpsGuardian/not-the-authorized-safe");
        opsGuardian.recoverTokens(address(0x5), address(0x1), admin, 100);
    }
}
