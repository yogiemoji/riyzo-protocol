// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {QueueManager} from "src/managers/spoke/QueueManager.sol";
import {IQueueManager} from "src/interfaces/spoke/IQueueManager.sol";

/// @title QueueManagerTest - Unit tests for QueueManager.sol
contract QueueManagerTest is Test {
    QueueManager public queueManager;

    address public admin = address(this);
    address public unauthorized = address(0x999);

    uint64 public constant POOL_ID = 1;
    bytes16 public constant SC_ID = bytes16(uint128(1));

    function setUp() public {
        queueManager = new QueueManager(admin);

        // Set default config
        IQueueManager.QueueConfig memory config = IQueueManager.QueueConfig({
            minBatchSize: 1000e6, maxDelay: 1 hours, gasLimit: 500_000, autoSyncEnabled: true
        });
        queueManager.setQueueConfig(POOL_ID, SC_ID, config);
    }

    // ============================================================
    // CONFIGURATION TESTS
    // ============================================================

    function test_setQueueConfig() public {
        IQueueManager.QueueConfig memory config = IQueueManager.QueueConfig({
            minBatchSize: 5000e6, maxDelay: 2 hours, gasLimit: 1_000_000, autoSyncEnabled: false
        });

        queueManager.setQueueConfig(POOL_ID, SC_ID, config);

        IQueueManager.QueueConfig memory stored = queueManager.getQueueConfig(POOL_ID, SC_ID);
        assertEq(stored.minBatchSize, 5000e6);
        assertEq(stored.maxDelay, 2 hours);
        assertEq(stored.gasLimit, 1_000_000);
        assertFalse(stored.autoSyncEnabled);
    }

    function test_setQueueConfig_revert_zeroMaxDelay() public {
        IQueueManager.QueueConfig memory config =
            IQueueManager.QueueConfig({minBatchSize: 1000e6, maxDelay: 0, gasLimit: 500_000, autoSyncEnabled: true});

        vm.expectRevert(abi.encodeWithSelector(IQueueManager.InvalidConfig.selector, "maxDelay cannot be zero"));
        queueManager.setQueueConfig(POOL_ID, SC_ID, config);
    }

    function test_setQueueConfig_revert_unauthorized() public {
        IQueueManager.QueueConfig memory config = IQueueManager.QueueConfig({
            minBatchSize: 1000e6, maxDelay: 1 hours, gasLimit: 500_000, autoSyncEnabled: true
        });

        vm.prank(unauthorized);
        vm.expectRevert("Auth/not-authorized");
        queueManager.setQueueConfig(POOL_ID, SC_ID, config);
    }

    function test_enableAutoSync() public {
        queueManager.disableAutoSync(POOL_ID, SC_ID);
        assertFalse(queueManager.getQueueConfig(POOL_ID, SC_ID).autoSyncEnabled);

        queueManager.enableAutoSync(POOL_ID, SC_ID);
        assertTrue(queueManager.getQueueConfig(POOL_ID, SC_ID).autoSyncEnabled);
    }

    function test_disableAutoSync() public {
        assertTrue(queueManager.getQueueConfig(POOL_ID, SC_ID).autoSyncEnabled);

        queueManager.disableAutoSync(POOL_ID, SC_ID);
        assertFalse(queueManager.getQueueConfig(POOL_ID, SC_ID).autoSyncEnabled);
    }

    // ============================================================
    // QUEUE ACCUMULATION TESTS
    // ============================================================

    function test_addToPendingDeposits() public {
        queueManager.addToPendingDeposits(POOL_ID, SC_ID, 500e6);

        IQueueManager.QueueState memory state = queueManager.getQueueState(POOL_ID, SC_ID);
        assertEq(state.pendingAssets, 500e6);
    }

    function test_addToPendingDeposits_multiple() public {
        queueManager.addToPendingDeposits(POOL_ID, SC_ID, 500e6);
        queueManager.addToPendingDeposits(POOL_ID, SC_ID, 300e6);

        IQueueManager.QueueState memory state = queueManager.getQueueState(POOL_ID, SC_ID);
        assertEq(state.pendingAssets, 800e6);
    }

    function test_addToPendingRedeems() public {
        queueManager.addToPendingRedeems(POOL_ID, SC_ID, 100e18);

        IQueueManager.QueueState memory state = queueManager.getQueueState(POOL_ID, SC_ID);
        assertEq(state.pendingShares, 100e18);
    }

    // ============================================================
    // SYNC TRIGGER TESTS
    // ============================================================

    function test_shouldSync_false_noItems() public view {
        assertFalse(queueManager.shouldSync(POOL_ID, SC_ID));
    }

    function test_shouldSync_false_autoSyncDisabled() public {
        queueManager.disableAutoSync(POOL_ID, SC_ID);
        queueManager.addToPendingDeposits(POOL_ID, SC_ID, 5000e6); // Above threshold

        assertFalse(queueManager.shouldSync(POOL_ID, SC_ID));
    }

    function test_shouldSync_true_batchThreshold() public {
        queueManager.addToPendingDeposits(POOL_ID, SC_ID, 1500e6); // Above 1000e6 threshold

        assertTrue(queueManager.shouldSync(POOL_ID, SC_ID));
    }

    function test_shouldSync_true_timeThreshold() public {
        queueManager.addToPendingDeposits(POOL_ID, SC_ID, 100e6); // Below batch threshold

        // Initially true because no sync has happened and there are pending items
        assertTrue(queueManager.shouldSync(POOL_ID, SC_ID));
    }

    function test_isBatchThresholdMet() public {
        assertFalse(queueManager.isBatchThresholdMet(POOL_ID, SC_ID));

        queueManager.addToPendingDeposits(POOL_ID, SC_ID, 500e6);
        assertFalse(queueManager.isBatchThresholdMet(POOL_ID, SC_ID));

        queueManager.addToPendingDeposits(POOL_ID, SC_ID, 600e6);
        assertTrue(queueManager.isBatchThresholdMet(POOL_ID, SC_ID));
    }

    function test_checkAndSync() public {
        queueManager.addToPendingDeposits(POOL_ID, SC_ID, 1500e6);

        bool synced = queueManager.checkAndSync(POOL_ID, SC_ID);

        assertTrue(synced);
        IQueueManager.QueueState memory state = queueManager.getQueueState(POOL_ID, SC_ID);
        assertEq(state.pendingAssets, 0);
        assertGt(state.lastSyncTimestamp, 0);
        assertEq(state.lastSyncEpoch, 1);
    }

    function test_checkAndSync_false_noTrigger() public {
        // Config with high threshold, disabled initially
        queueManager.disableAutoSync(POOL_ID, SC_ID);
        queueManager.addToPendingDeposits(POOL_ID, SC_ID, 100e6);

        bool synced = queueManager.checkAndSync(POOL_ID, SC_ID);

        assertFalse(synced);
    }

    function test_forceSync() public {
        queueManager.addToPendingDeposits(POOL_ID, SC_ID, 100e6);
        queueManager.addToPendingRedeems(POOL_ID, SC_ID, 50e18);

        queueManager.forceSync(POOL_ID, SC_ID);

        IQueueManager.QueueState memory state = queueManager.getQueueState(POOL_ID, SC_ID);
        assertEq(state.pendingAssets, 0);
        assertEq(state.pendingShares, 0);
        assertGt(state.lastSyncTimestamp, 0);
    }

    function test_forceSync_revert_unauthorized() public {
        queueManager.addToPendingDeposits(POOL_ID, SC_ID, 100e6);

        vm.prank(unauthorized);
        vm.expectRevert("Auth/not-authorized");
        queueManager.forceSync(POOL_ID, SC_ID);
    }

    // ============================================================
    // KEEPER INTERFACE TESTS
    // ============================================================

    function test_performSync() public {
        queueManager.addToPendingDeposits(POOL_ID, SC_ID, 1500e6);

        queueManager.performSync(POOL_ID, SC_ID);

        IQueueManager.QueueState memory state = queueManager.getQueueState(POOL_ID, SC_ID);
        assertEq(state.pendingAssets, 0);
    }

    function test_performSync_revert_conditionsNotMet() public {
        queueManager.disableAutoSync(POOL_ID, SC_ID);
        queueManager.addToPendingDeposits(POOL_ID, SC_ID, 100e6);

        vm.expectRevert(abi.encodeWithSelector(IQueueManager.SyncConditionsNotMet.selector, POOL_ID, SC_ID));
        queueManager.performSync(POOL_ID, SC_ID);
    }

    function test_shouldSyncBatch() public {
        uint64 poolId2 = 2;
        bytes16 scId2 = bytes16(uint128(2));

        // Setup config for second pool
        IQueueManager.QueueConfig memory config = IQueueManager.QueueConfig({
            minBatchSize: 1000e6, maxDelay: 1 hours, gasLimit: 500_000, autoSyncEnabled: true
        });
        queueManager.setQueueConfig(poolId2, scId2, config);

        // Add deposits to pool 1 above threshold
        queueManager.addToPendingDeposits(POOL_ID, SC_ID, 1500e6);

        uint64[] memory poolIds = new uint64[](2);
        poolIds[0] = POOL_ID;
        poolIds[1] = poolId2;

        bytes16[] memory scIds = new bytes16[](2);
        scIds[0] = SC_ID;
        scIds[1] = scId2;

        bool[] memory results = queueManager.shouldSyncBatch(poolIds, scIds);

        assertTrue(results[0]); // Pool 1 should sync
        assertFalse(results[1]); // Pool 2 should not sync (no pending)
    }

    // ============================================================
    // VIEW FUNCTION TESTS
    // ============================================================

    function test_timeSinceLastSync_neverSynced() public view {
        uint64 time = queueManager.timeSinceLastSync(POOL_ID, SC_ID);
        assertEq(time, type(uint64).max);
    }

    function test_timeSinceLastSync_afterSync() public {
        queueManager.addToPendingDeposits(POOL_ID, SC_ID, 1500e6);
        queueManager.checkAndSync(POOL_ID, SC_ID);

        uint64 time = queueManager.timeSinceLastSync(POOL_ID, SC_ID);
        assertEq(time, 0); // Just synced

        vm.warp(block.timestamp + 100);
        time = queueManager.timeSinceLastSync(POOL_ID, SC_ID);
        assertEq(time, 100);
    }

    function test_getQueueState() public {
        queueManager.addToPendingDeposits(POOL_ID, SC_ID, 500e6);
        queueManager.addToPendingRedeems(POOL_ID, SC_ID, 50e18);

        IQueueManager.QueueState memory state = queueManager.getQueueState(POOL_ID, SC_ID);

        assertEq(state.pendingAssets, 500e6);
        assertEq(state.pendingShares, 50e18);
        assertEq(state.lastSyncTimestamp, 0);
        assertEq(state.lastSyncEpoch, 0);
    }

    // ============================================================
    // FUZZ TESTS
    // ============================================================

    function testFuzz_accumulation(uint128 amount1, uint128 amount2) public {
        vm.assume(amount1 < type(uint128).max / 2);
        vm.assume(amount2 < type(uint128).max / 2);

        queueManager.addToPendingDeposits(POOL_ID, SC_ID, amount1);
        queueManager.addToPendingDeposits(POOL_ID, SC_ID, amount2);

        IQueueManager.QueueState memory state = queueManager.getQueueState(POOL_ID, SC_ID);
        assertEq(state.pendingAssets, uint256(amount1) + uint256(amount2));
    }
}
