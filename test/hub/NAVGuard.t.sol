// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {NAVGuard} from "src/core/hub/NAVGuard.sol";
import {ShareClassManager} from "src/core/hub/ShareClassManager.sol";
import {NAVManager} from "src/core/hub/NAVManager.sol";
import {Accounting} from "src/core/hub/Accounting.sol";
import {Holdings} from "src/core/hub/Holdings.sol";
import {IValuation} from "src/interfaces/hub/IValuation.sol";

/// @title MockValuationForGuard - Mock with configurable timestamp
contract MockValuationForGuard is IValuation {
    uint64 public mockTimestamp;

    function setLastUpdated(uint64 timestamp) external {
        mockTimestamp = timestamp;
    }

    function getPrice(uint64, bytes16, uint128) external pure override returns (uint256) {
        return 1e18;
    }

    function getQuote(uint64, bytes16, uint128, uint128 baseAmount) external pure override returns (uint128) {
        return baseAmount;
    }

    function isSupported(uint64, bytes16, uint128) external pure override returns (bool) {
        return true;
    }

    function lastUpdated(uint64, bytes16, uint128) external view override returns (uint64) {
        return mockTimestamp;
    }
}

/// @title NAVGuardTest - Unit tests for NAVGuard.sol
/// @notice Tests price movement limits, staleness checks, and pause functionality
contract NAVGuardTest is Test {
    NAVGuard public guard;
    ShareClassManager public scm;
    NAVManager public navManager;
    Accounting public accounting;
    Holdings public holdings;
    MockValuationForGuard public valuation;

    address public admin = address(this);
    address public guardian = address(0x1);

    uint64 public constant POOL_ID = 1;
    bytes16 public scId;
    uint128 public constant ASSET_ID = 1;

    function setUp() public {
        // Deploy dependencies
        accounting = new Accounting(admin);
        holdings = new Holdings(admin, accounting);
        scm = new ShareClassManager(admin);
        navManager = new NAVManager(admin, accounting, holdings);
        valuation = new MockValuationForGuard();

        // Deploy NAVGuard
        guard = new NAVGuard(admin, address(scm), address(navManager));

        // Create a share class for testing
        scId = scm.addShareClass(POOL_ID, "Test", "TST", bytes32(uint256(1)));

        // Configure guard
        guard.configureGuard(POOL_ID, 1000, 3600, true); // 10% max change, 1 hour staleness

        // Add guardian
        guard.updateGuardian(guardian, true);
    }

    // ============================================================
    // CONFIGURATION TESTS
    // ============================================================

    function test_configureGuard_success() public {
        guard.configureGuard(POOL_ID, 500, 7200, true);

        NAVGuard.GuardConfig memory config = guard.getGuardConfig(POOL_ID);
        assertEq(config.maxPriceChangeBps, 500);
        assertEq(config.maxStalenessSeconds, 7200);
        assertTrue(config.enforceLimits);
    }

    function test_configureGuard_revert_invalidBps() public {
        vm.expectRevert("NAVGuard/invalid-bps");
        guard.configureGuard(POOL_ID, 10001, 3600, true); // > 100%
    }

    function test_configureGuard_preservesPauseState() public {
        guard.pause(POOL_ID);

        guard.configureGuard(POOL_ID, 500, 7200, true);

        assertTrue(guard.isPaused(POOL_ID));
    }

    // ============================================================
    // GUARDIAN TESTS
    // ============================================================

    function test_updateGuardian_add() public {
        address newGuardian = address(0x2);
        guard.updateGuardian(newGuardian, true);

        assertTrue(guard.isGuardian(newGuardian));
    }

    function test_updateGuardian_remove() public {
        guard.updateGuardian(guardian, false);

        assertFalse(guard.isGuardian(guardian));
    }

    function test_updateGuardian_revert_unauthorized() public {
        vm.prank(address(0x99));
        vm.expectRevert("Auth/not-authorized");
        guard.updateGuardian(address(0x2), true);
    }

    // ============================================================
    // PAUSE TESTS
    // ============================================================

    function test_pause_byGuardian() public {
        vm.prank(guardian);
        guard.pause(POOL_ID);

        assertTrue(guard.isPaused(POOL_ID));
    }

    function test_pause_byWard() public {
        guard.pause(POOL_ID);

        assertTrue(guard.isPaused(POOL_ID));
    }

    function test_pause_revert_notGuardian() public {
        vm.prank(address(0x99));
        vm.expectRevert("NAVGuard/not-guardian");
        guard.pause(POOL_ID);
    }

    function test_unpause_success() public {
        guard.pause(POOL_ID);
        guard.unpause(POOL_ID);

        assertFalse(guard.isPaused(POOL_ID));
    }

    function test_unpause_revert_notPaused() public {
        vm.expectRevert(abi.encodeWithSelector(NAVGuard.PoolNotPaused.selector, POOL_ID));
        guard.unpause(POOL_ID);
    }

    function test_unpause_onlyWard() public {
        guard.pause(POOL_ID);

        // Guardian cannot unpause
        vm.prank(guardian);
        vm.expectRevert("Auth/not-authorized");
        guard.unpause(POOL_ID);
    }

    // ============================================================
    // PRICE VALIDATION TESTS
    // ============================================================

    function test_validatePrice_firstPrice() public {
        uint128 price = 1e18;

        (bool valid, uint16 changeBps) = guard.validatePrice(POOL_ID, scId, price);

        assertTrue(valid);
        assertEq(changeBps, 0);
        assertEq(guard.getLastValidatedPrice(POOL_ID, scId), price);
    }

    function test_validatePrice_withinLimit() public {
        // Set initial price
        guard.validatePrice(POOL_ID, scId, 1e18);

        // 5% increase (within 10% limit)
        (bool valid, uint16 changeBps) = guard.validatePrice(POOL_ID, scId, 1.05e18);

        assertTrue(valid);
        assertEq(changeBps, 500); // 5%
    }

    function test_validatePrice_exactlyAtLimit() public {
        guard.validatePrice(POOL_ID, scId, 1e18);

        // Exactly 10% increase
        (bool valid, uint16 changeBps) = guard.validatePrice(POOL_ID, scId, 1.1e18);

        assertTrue(valid);
        assertEq(changeBps, 1000); // 10%
    }

    function test_validatePrice_revert_exceedsLimit() public {
        guard.validatePrice(POOL_ID, scId, 1e18);

        // 15% increase (exceeds 10% limit)
        vm.expectRevert(abi.encodeWithSelector(NAVGuard.PriceChangeExceedsLimit.selector, POOL_ID, scId, 1500, 1000));
        guard.validatePrice(POOL_ID, scId, 1.15e18);
    }

    function test_validatePrice_decrease() public {
        guard.validatePrice(POOL_ID, scId, 1e18);

        // 5% decrease
        (bool valid, uint16 changeBps) = guard.validatePrice(POOL_ID, scId, 0.95e18);

        assertTrue(valid);
        assertEq(changeBps, 500);
    }

    function test_validatePrice_revert_whenPaused() public {
        guard.pause(POOL_ID);

        vm.expectRevert(abi.encodeWithSelector(NAVGuard.PoolIsPaused.selector, POOL_ID));
        guard.validatePrice(POOL_ID, scId, 1e18);
    }

    function test_validatePrice_limitsNotEnforced() public {
        // Disable limits
        guard.configureGuard(POOL_ID, 1000, 3600, false);

        guard.validatePrice(POOL_ID, scId, 1e18);

        // 50% change should pass when limits disabled
        (bool valid, uint16 changeBps) = guard.validatePrice(POOL_ID, scId, 1.5e18);

        assertTrue(valid);
        assertEq(changeBps, 0); // Not calculated when disabled
    }

    // ============================================================
    // STALENESS TESTS
    // ============================================================

    function test_checkStaleness_fresh() public {
        // Warp time forward to ensure we have room to calculate age
        vm.warp(block.timestamp + 1 hours);
        valuation.setLastUpdated(uint64(block.timestamp - 30 minutes));

        (bool isStale, uint64 age) = guard.checkStaleness(POOL_ID, scId, ASSET_ID, valuation);

        assertFalse(isStale);
        assertEq(age, 30 minutes);
    }

    function test_checkStaleness_stale() public {
        // Warp time forward to ensure we have room to calculate age
        vm.warp(block.timestamp + 3 hours);
        valuation.setLastUpdated(uint64(block.timestamp - 2 hours));

        (bool isStale, uint64 age) = guard.checkStaleness(POOL_ID, scId, ASSET_ID, valuation);

        assertTrue(isStale);
        assertEq(age, 2 hours);
    }

    function test_requireFreshValuation_success() public {
        // Warp time forward to ensure we have room to calculate age
        vm.warp(block.timestamp + 1 hours);
        valuation.setLastUpdated(uint64(block.timestamp - 30 minutes));

        // Should not revert
        guard.requireFreshValuation(POOL_ID, scId, ASSET_ID, valuation);
    }

    function test_requireFreshValuation_revert_stale() public {
        // Warp time forward to ensure we have room to calculate age
        vm.warp(block.timestamp + 3 hours);
        valuation.setLastUpdated(uint64(block.timestamp - 2 hours));

        vm.expectRevert(
            abi.encodeWithSelector(NAVGuard.ValuationTooStale.selector, POOL_ID, scId, ASSET_ID, 2 hours, 1 hours)
        );
        guard.requireFreshValuation(POOL_ID, scId, ASSET_ID, valuation);
    }

    // ============================================================
    // CALCULATE CHANGE BPS TESTS
    // ============================================================

    function test_calculateChangeBps_increase() public view {
        uint16 change = guard.calculateChangeBps(100e18, 110e18);
        assertEq(change, 1000); // 10%
    }

    function test_calculateChangeBps_decrease() public view {
        uint16 change = guard.calculateChangeBps(100e18, 90e18);
        assertEq(change, 1000); // 10%
    }

    function test_calculateChangeBps_noChange() public view {
        uint16 change = guard.calculateChangeBps(100e18, 100e18);
        assertEq(change, 0);
    }

    function test_calculateChangeBps_zeroOldPrice() public view {
        uint16 change = guard.calculateChangeBps(0, 100e18);
        assertEq(change, 0);
    }

    function test_calculateChangeBps_largeChange() public view {
        // > 100% change should cap at 10000
        uint16 change = guard.calculateChangeBps(100e18, 300e18);
        assertEq(change, 10000); // Capped at 100%
    }

    // ============================================================
    // EVENT TESTS
    // ============================================================

    function test_events_poolPaused() public {
        vm.expectEmit(true, true, false, false);
        emit NAVGuard.PoolPaused(POOL_ID, admin);

        guard.pause(POOL_ID);
    }

    function test_events_poolUnpaused() public {
        guard.pause(POOL_ID);

        vm.expectEmit(true, true, false, false);
        emit NAVGuard.PoolUnpaused(POOL_ID, admin);

        guard.unpause(POOL_ID);
    }

    function test_events_priceValidated() public {
        vm.expectEmit(true, true, false, true);
        emit NAVGuard.PriceValidated(POOL_ID, scId, 1e18, 0);

        guard.validatePrice(POOL_ID, scId, 1e18);
    }

    // ============================================================
    // FILE TESTS
    // ============================================================

    function test_file_shareClassManager() public {
        ShareClassManager newScm = new ShareClassManager(admin);

        guard.file("shareClassManager", address(newScm));

        assertEq(address(guard.shareClassManager()), address(newScm));
    }

    function test_file_navManager() public {
        NAVManager newNav = new NAVManager(admin, accounting, holdings);

        guard.file("navManager", address(newNav));

        assertEq(address(guard.navManager()), address(newNav));
    }

    function test_file_revert_unrecognized() public {
        vm.expectRevert("NAVGuard/file-unrecognized-param");
        guard.file("unknown", address(0x1));
    }

    // ============================================================
    // FUZZ TESTS
    // ============================================================

    function testFuzz_calculateChangeBps(uint128 oldPrice, uint128 newPrice) public view {
        vm.assume(oldPrice > 0);
        vm.assume(oldPrice < type(uint128).max / 10000);

        uint16 change = guard.calculateChangeBps(oldPrice, newPrice);

        // Change should never exceed MAX_BPS
        assertTrue(change <= 10000);
    }

    function testFuzz_priceValidation(uint128 initialPrice, uint128 newPrice) public {
        vm.assume(initialPrice > 0);
        vm.assume(initialPrice < type(uint128).max / 2);
        vm.assume(newPrice > 0);
        vm.assume(newPrice < type(uint128).max / 2);

        // Disable limits for fuzz testing
        guard.configureGuard(POOL_ID, 10000, 3600, false);

        guard.validatePrice(POOL_ID, scId, initialPrice);
        (bool valid,) = guard.validatePrice(POOL_ID, scId, newPrice);

        assertTrue(valid);
        assertEq(guard.getLastValidatedPrice(POOL_ID, scId), newPrice);
    }
}
