// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {RiyzoSpoke} from "src/core/spoke/RiyzoSpoke.sol";
import {IRiyzoSpoke} from "src/interfaces/spoke/IRiyzoSpoke.sol";
import {VaultRegistry} from "src/core/spoke/VaultRegistry.sol";
import {BalanceSheet} from "src/core/spoke/BalanceSheet.sol";
import {PoolEscrow} from "src/core/spoke/PoolEscrow.sol";
import {QueueManager} from "src/managers/spoke/QueueManager.sol";
import {MockGateway} from "test/mocks/MockGateway.sol";
import {MockEscrow} from "test/mocks/MockEscrow.sol";
import {MockTrancheFactory} from "test/mocks/MockTrancheFactory.sol";
import {MockVaultFactory} from "test/mocks/MockVaultFactory.sol";

/// @title RiyzoSpokeTest - Unit tests for RiyzoSpoke.sol
contract RiyzoSpokeTest is Test {
    RiyzoSpoke public spoke;
    VaultRegistry public vaultRegistry;
    BalanceSheet public balanceSheet;
    PoolEscrow public poolEscrow;
    QueueManager public queueManager;
    MockGateway public gateway;
    MockEscrow public escrow;
    MockTrancheFactory public trancheFactory;
    MockVaultFactory public vaultFactory;

    address public admin = address(this);
    address public root = address(0x1001);
    address public usdc = address(0x2001);
    address public user1 = address(0x1);
    address public unauthorized = address(0x999);

    uint64 public constant POOL_ID = 1;
    bytes16 public constant SC_ID = bytes16(uint128(1));

    function setUp() public {
        // Deploy mocks
        gateway = new MockGateway();
        escrow = new MockEscrow();
        trancheFactory = new MockTrancheFactory();
        vaultFactory = new MockVaultFactory();

        // Deploy spoke components
        spoke = new RiyzoSpoke(admin);
        vaultRegistry = new VaultRegistry(admin, root, address(escrow));
        balanceSheet = new BalanceSheet(admin);
        poolEscrow = new PoolEscrow(admin, address(escrow));
        queueManager = new QueueManager(admin);

        // Configure VaultRegistry
        vaultRegistry.file("vaultFactory", address(vaultFactory));
        vaultRegistry.file("trancheFactory", address(trancheFactory));

        // Configure RiyzoSpoke
        spoke.file("gateway", address(gateway));
        spoke.file("vaultRegistry", address(vaultRegistry));
        spoke.file("balanceSheet", address(balanceSheet));
        spoke.file("poolEscrow", address(poolEscrow));
        spoke.file("queueManager", address(queueManager));

        // Grant permissions
        vaultRegistry.rely(address(spoke));
        balanceSheet.rely(address(spoke));
        poolEscrow.rely(address(spoke));
        queueManager.rely(address(spoke));
    }

    // ============================================================
    // CONFIGURATION TESTS
    // ============================================================

    function test_file_gateway() public {
        address newGateway = address(0x6001);
        spoke.file("gateway", newGateway);
        assertEq(spoke.gateway(), newGateway);
    }

    function test_file_revert_unrecognized() public {
        vm.expectRevert("RiyzoSpoke/file-unrecognized-param");
        spoke.file("unknown", address(0x1));
    }

    function test_file_revert_unauthorized() public {
        vm.prank(unauthorized);
        vm.expectRevert("Auth/not-authorized");
        spoke.file("gateway", address(0x1));
    }

    function test_file_maxPriceAge() public {
        spoke.file("maxPriceAge", uint64(2 days));
        assertEq(spoke.maxPriceAge(), 2 days);
    }

    // ============================================================
    // POOL REGISTRATION TESTS
    // ============================================================

    function test_registerPool() public {
        spoke.registerPool(POOL_ID, usdc);

        IRiyzoSpoke.PoolState memory pool = spoke.getPool(POOL_ID);
        assertTrue(pool.exists);
        assertEq(pool.poolId, POOL_ID);
        assertEq(pool.currency, usdc);
        assertTrue(pool.isActive);
    }

    function test_registerPool_revert_alreadyExists() public {
        spoke.registerPool(POOL_ID, usdc);

        vm.expectRevert(abi.encodeWithSelector(IRiyzoSpoke.PoolAlreadyExists.selector, POOL_ID));
        spoke.registerPool(POOL_ID, usdc);
    }

    function test_registerPool_revert_unauthorized() public {
        vm.prank(unauthorized);
        vm.expectRevert("Auth/not-authorized");
        spoke.registerPool(POOL_ID, usdc);
    }

    // ============================================================
    // SHARE CLASS REGISTRATION TESTS
    // ============================================================

    function test_registerShareClass() public {
        spoke.registerPool(POOL_ID, usdc);
        address shareToken = spoke.registerShareClass(POOL_ID, SC_ID, "Senior", "SR");

        assertNotEq(shareToken, address(0));

        IRiyzoSpoke.ShareClassState memory sc = spoke.getShareClass(POOL_ID, SC_ID);
        assertTrue(sc.exists);
        assertEq(sc.scId, SC_ID);
        assertEq(sc.shareToken, shareToken);
    }

    function test_registerShareClass_revert_poolNotFound() public {
        vm.expectRevert(abi.encodeWithSelector(IRiyzoSpoke.PoolNotFound.selector, POOL_ID));
        spoke.registerShareClass(POOL_ID, SC_ID, "Senior", "SR");
    }

    function test_registerShareClass_revert_alreadyExists() public {
        spoke.registerPool(POOL_ID, usdc);
        spoke.registerShareClass(POOL_ID, SC_ID, "Senior", "SR");

        vm.expectRevert(abi.encodeWithSelector(IRiyzoSpoke.ShareClassAlreadyExists.selector, POOL_ID, SC_ID));
        spoke.registerShareClass(POOL_ID, SC_ID, "Senior 2", "SR2");
    }

    // ============================================================
    // VAULT LINKING TESTS
    // ============================================================

    function test_linkVault() public {
        spoke.registerPool(POOL_ID, usdc);
        spoke.registerShareClass(POOL_ID, SC_ID, "Senior", "SR");

        address vault = address(0xABCD);
        spoke.linkVault(POOL_ID, SC_ID, usdc, vault);

        assertEq(spoke.getVault(POOL_ID, SC_ID, usdc), vault);
    }

    function test_linkVault_revert_poolNotFound() public {
        vm.expectRevert(abi.encodeWithSelector(IRiyzoSpoke.PoolNotFound.selector, POOL_ID));
        spoke.linkVault(POOL_ID, SC_ID, usdc, address(0x1));
    }

    function test_linkVault_revert_shareClassNotFound() public {
        spoke.registerPool(POOL_ID, usdc);

        vm.expectRevert(abi.encodeWithSelector(IRiyzoSpoke.ShareClassNotFound.selector, POOL_ID, SC_ID));
        spoke.linkVault(POOL_ID, SC_ID, usdc, address(0x1));
    }

    // ============================================================
    // PRICE UPDATE TESTS
    // ============================================================

    function test_updatePrice() public {
        spoke.registerPool(POOL_ID, usdc);
        spoke.registerShareClass(POOL_ID, SC_ID, "Senior", "SR");

        uint128 price = 1.05e18;
        uint64 timestamp = uint64(block.timestamp);

        spoke.updatePrice(POOL_ID, SC_ID, price, timestamp);

        (uint128 storedPrice, uint64 storedTimestamp) = spoke.getPrice(POOL_ID, SC_ID);
        assertEq(storedPrice, price);
        assertEq(storedTimestamp, timestamp);
    }

    function test_updatePrice_revert_poolNotFound() public {
        vm.expectRevert(abi.encodeWithSelector(IRiyzoSpoke.PoolNotFound.selector, POOL_ID));
        spoke.updatePrice(POOL_ID, SC_ID, 1e18, uint64(block.timestamp));
    }

    // ============================================================
    // VIEW FUNCTION TESTS
    // ============================================================

    function test_getPool_notExists() public view {
        IRiyzoSpoke.PoolState memory pool = spoke.getPool(POOL_ID);
        assertFalse(pool.exists);
    }

    function test_getShareClass_notExists() public view {
        IRiyzoSpoke.ShareClassState memory sc = spoke.getShareClass(POOL_ID, SC_ID);
        assertFalse(sc.exists);
    }

    function test_isValidVault() public {
        spoke.registerPool(POOL_ID, usdc);
        address shareToken = spoke.registerShareClass(POOL_ID, SC_ID, "Senior", "SR");

        address vault = vaultRegistry.deployVault(POOL_ID, SC_ID, usdc, shareToken);

        assertFalse(spoke.isValidVault(vault)); // Not active yet

        vaultRegistry.activateVault(vault);
        assertTrue(spoke.isValidVault(vault));
    }

    // ============================================================
    // FUZZ TESTS
    // ============================================================

    function testFuzz_priceUpdate(uint128 price, uint64 timestamp) public {
        vm.assume(price > 0);

        spoke.registerPool(POOL_ID, usdc);
        spoke.registerShareClass(POOL_ID, SC_ID, "Senior", "SR");

        spoke.updatePrice(POOL_ID, SC_ID, price, timestamp);

        (uint128 storedPrice, uint64 storedTimestamp) = spoke.getPrice(POOL_ID, SC_ID);
        assertEq(storedPrice, price);
        assertEq(storedTimestamp, timestamp);
    }
}
