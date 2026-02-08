// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {SpokeHandler} from "src/core/spoke/SpokeHandler.sol";
import {ISpokeHandler} from "src/interfaces/spoke/ISpokeHandler.sol";
import {RiyzoSpoke} from "src/core/spoke/RiyzoSpoke.sol";
import {IRiyzoSpoke} from "src/interfaces/spoke/IRiyzoSpoke.sol";
import {BalanceSheet} from "src/core/spoke/BalanceSheet.sol";
import {PoolEscrow} from "src/core/spoke/PoolEscrow.sol";
import {VaultRegistry} from "src/core/spoke/VaultRegistry.sol";
import {AsyncRequestManager} from "src/managers/spoke/AsyncRequestManager.sol";
import {MessagesLib} from "src/core/libraries/MessagesLib.sol";
import {MockGateway} from "test/mocks/MockGateway.sol";
import {MockEscrow} from "test/mocks/MockEscrow.sol";
import {MockTrancheFactory} from "test/mocks/MockTrancheFactory.sol";
import {MockVaultFactory} from "test/mocks/MockVaultFactory.sol";
import {MockERC20} from "test/mocks/MockERC20.sol";

/// @title SpokeHandlerTest - Unit tests for SpokeHandler.sol
contract SpokeHandlerTest is Test {
    SpokeHandler public handler;
    RiyzoSpoke public spoke;
    BalanceSheet public balanceSheet;
    PoolEscrow public poolEscrow;
    VaultRegistry public vaultRegistry;
    AsyncRequestManager public requestManager;
    MockGateway public gateway;
    MockEscrow public escrow;
    MockTrancheFactory public trancheFactory;
    MockVaultFactory public vaultFactory;
    MockERC20 public usdc;

    address public admin = address(this);
    address public root = address(0x1001);
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
        usdc = new MockERC20("USD Coin", "USDC", 6);

        // Deploy spoke components
        spoke = new RiyzoSpoke(admin);
        balanceSheet = new BalanceSheet(admin);
        poolEscrow = new PoolEscrow(admin, address(escrow));
        vaultRegistry = new VaultRegistry(admin, root, address(escrow));
        requestManager = new AsyncRequestManager(admin);
        handler = new SpokeHandler(admin);

        // Configure VaultRegistry
        vaultRegistry.file("vaultFactory", address(vaultFactory));
        vaultRegistry.file("trancheFactory", address(trancheFactory));

        // Configure RiyzoSpoke
        spoke.file("gateway", address(gateway));
        spoke.file("vaultRegistry", address(vaultRegistry));
        spoke.file("balanceSheet", address(balanceSheet));
        spoke.file("poolEscrow", address(poolEscrow));
        spoke.file("spokeHandler", address(handler));

        // Configure SpokeHandler
        handler.file("gateway", address(gateway));
        handler.file("spoke", address(spoke));
        handler.file("balanceSheet", address(balanceSheet));
        handler.file("poolEscrow", address(poolEscrow));
        handler.file("asyncRequestManager", address(requestManager));

        // Grant permissions
        vaultRegistry.rely(address(spoke));
        balanceSheet.rely(address(spoke));
        balanceSheet.rely(address(handler));
        poolEscrow.rely(address(spoke));
        poolEscrow.rely(address(handler));
        requestManager.rely(address(handler));
        spoke.rely(address(handler));

        // Fund escrow with USDC for redemption tests
        usdc.mint(address(escrow), 1_000_000e6);
        escrow.approveMax(address(usdc), address(poolEscrow));
    }

    // ============================================================
    // CONFIGURATION TESTS
    // ============================================================

    function test_file() public {
        address newSpoke = address(0x1234);
        handler.file("spoke", newSpoke);
        assertEq(handler.spoke(), newSpoke);
    }

    function test_file_revert_unrecognized() public {
        vm.expectRevert("SpokeHandler/file-unrecognized-param");
        handler.file("unknown", address(0x1));
    }

    function test_file_revert_unauthorized() public {
        vm.prank(unauthorized);
        vm.expectRevert("Auth/not-authorized");
        handler.file("spoke", address(0x1));
    }

    // ============================================================
    // SUPPORTS MESSAGE TYPE TESTS
    // ============================================================

    function test_supportsMessageType_addPool() public view {
        assertTrue(handler.supportsMessageType(uint8(MessagesLib.Call.AddPool)));
    }

    function test_supportsMessageType_addTranche() public view {
        assertTrue(handler.supportsMessageType(uint8(MessagesLib.Call.AddTranche)));
    }

    function test_supportsMessageType_updateTranchePrice() public view {
        assertTrue(handler.supportsMessageType(uint8(MessagesLib.Call.UpdateTranchePrice)));
    }

    function test_supportsMessageType_fulfilledDepositRequest() public view {
        assertTrue(handler.supportsMessageType(uint8(MessagesLib.Call.FulfilledDepositRequest)));
    }

    function test_supportsMessageType_fulfilledRedeemRequest() public view {
        assertTrue(handler.supportsMessageType(uint8(MessagesLib.Call.FulfilledRedeemRequest)));
    }

    function test_supportsMessageType_invalid() public view {
        assertFalse(handler.supportsMessageType(uint8(MessagesLib.Call.Invalid)));
        assertFalse(handler.supportsMessageType(uint8(MessagesLib.Call.DepositRequest)));
    }

    // ============================================================
    // HANDLE MESSAGE TESTS
    // ============================================================

    function test_handle_revert_unknownType() public {
        bytes memory message = abi.encodePacked(uint8(MessagesLib.Call.Invalid));

        vm.expectRevert(abi.encodeWithSelector(ISpokeHandler.UnknownMessageType.selector, uint8(MessagesLib.Call.Invalid)));
        handler.handle(message);
    }

    function test_handle_revert_emptyMessage() public {
        bytes memory message = "";

        vm.expectRevert(abi.encodeWithSelector(ISpokeHandler.MalformedMessage.selector, message));
        handler.handle(message);
    }

    function test_handle_revert_unauthorized() public {
        bytes memory message = abi.encodePacked(uint8(MessagesLib.Call.AddPool), POOL_ID);

        vm.prank(unauthorized);
        vm.expectRevert("Auth/not-authorized");
        handler.handle(message);
    }

    // ============================================================
    // ADD POOL MESSAGE TESTS
    // ============================================================

    function test_handleAddPool() public {
        // Encode AddPool message: type(1) + poolId(8) + currency(16)
        bytes memory message = abi.encodePacked(
            uint8(MessagesLib.Call.AddPool),
            POOL_ID,
            bytes16(uint128(uint160(address(usdc))))
        );

        handler.handle(message);

        IRiyzoSpoke.PoolState memory pool = spoke.getPool(POOL_ID);
        assertTrue(pool.exists);
        assertEq(pool.poolId, POOL_ID);
    }

    // ============================================================
    // UPDATE PRICE MESSAGE TESTS
    // ============================================================

    function test_handleUpdatePrice() public {
        // First register pool and share class
        spoke.registerPool(POOL_ID, address(usdc));
        spoke.registerShareClass(POOL_ID, SC_ID, "Senior", "SR");

        uint128 price = 1.05e18;
        uint64 timestamp = uint64(block.timestamp);

        // Encode UpdateTranchePrice message: type(1) + poolId(8) + trancheId(16) + price(16) + timestamp(8)
        bytes memory message = abi.encodePacked(
            uint8(MessagesLib.Call.UpdateTranchePrice),
            POOL_ID,
            SC_ID,
            price,
            timestamp
        );

        handler.handle(message);

        (uint128 storedPrice, uint64 storedTimestamp) = spoke.getPrice(POOL_ID, SC_ID);
        assertEq(storedPrice, price);
        assertEq(storedTimestamp, timestamp);
    }

    // ============================================================
    // VIEW FUNCTION TESTS
    // ============================================================

    function test_gateway() public view {
        assertEq(handler.gateway(), address(gateway));
    }

    function test_spoke() public view {
        assertEq(handler.spoke(), address(spoke));
    }

    function test_balanceSheet() public view {
        assertEq(handler.balanceSheet(), address(balanceSheet));
    }

    function test_poolEscrow() public view {
        assertEq(handler.poolEscrow(), address(poolEscrow));
    }

    function test_asyncRequestManager() public view {
        assertEq(handler.asyncRequestManager(), address(requestManager));
    }
}
