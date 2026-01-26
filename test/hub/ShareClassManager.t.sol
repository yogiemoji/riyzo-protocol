// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {ShareClassManager} from "src/core/hub/ShareClassManager.sol";
import {IShareClassManager} from "src/interfaces/hub/IShareClassManager.sol";

/// @title ShareClassManagerTest - Unit tests for ShareClassManager.sol
/// @notice Tests share class creation, pricing, and issuance tracking
contract ShareClassManagerTest is Test {
    ShareClassManager public scm;

    address public admin = address(this);
    address public user1 = address(0x1);

    uint64 public constant POOL_ID = 1;
    uint16 public constant ETHEREUM_CHAIN = 1;
    uint16 public constant BASE_CHAIN = 8453;

    function setUp() public {
        scm = new ShareClassManager(admin);
    }

    // ============================================================
    // SHARE CLASS CREATION TESTS
    // ============================================================

    function test_addShareClass_success() public {
        bytes16 scId = scm.addShareClass(POOL_ID, "Senior Tranche", "SR", bytes32(uint256(1)));

        assertTrue(scm.shareClassExists(POOL_ID, scId));
        assertEq(scm.shareClassCount(POOL_ID), 1);
    }

    function test_addShareClass_metadata() public {
        bytes32 salt = bytes32(uint256(12345));
        bytes16 scId = scm.addShareClass(POOL_ID, "Senior Tranche", "SR-POOL1", salt);

        IShareClassManager.ShareClassMetadata memory meta = scm.getMetadata(POOL_ID, scId);
        assertEq(meta.name, "Senior Tranche");
        assertEq(meta.symbol, "SR-POOL1");
        assertEq(meta.salt, salt);
    }

    function test_addShareClass_multipleClasses() public {
        bytes16 seniorId = scm.addShareClass(POOL_ID, "Senior", "SR", bytes32(uint256(1)));
        bytes16 juniorId = scm.addShareClass(POOL_ID, "Junior", "JR", bytes32(uint256(2)));

        assertTrue(scm.shareClassExists(POOL_ID, seniorId));
        assertTrue(scm.shareClassExists(POOL_ID, juniorId));
        assertEq(scm.shareClassCount(POOL_ID), 2);

        // IDs should be different
        assertTrue(seniorId != juniorId);
    }

    function test_addShareClass_uniqueIdsPerPool() public {
        bytes16 pool1Sc = scm.addShareClass(1, "Senior", "SR", bytes32(uint256(1)));
        bytes16 pool2Sc = scm.addShareClass(2, "Senior", "SR", bytes32(uint256(1)));

        // Same index but different pool = different ID
        assertTrue(pool1Sc != pool2Sc);
    }

    function test_addShareClass_revert_unauthorized() public {
        vm.prank(user1);
        vm.expectRevert("Auth/not-authorized");
        scm.addShareClass(POOL_ID, "Senior", "SR", bytes32(uint256(1)));
    }

    function test_addShareClass_initialPriceZero() public {
        bytes16 scId = scm.addShareClass(POOL_ID, "Senior", "SR", bytes32(uint256(1)));

        (uint128 price, uint64 computedAt) = scm.pricePerShare(POOL_ID, scId);
        assertEq(price, 0);
        assertEq(computedAt, 0);
    }

    // ============================================================
    // METADATA UPDATE TESTS
    // ============================================================

    function test_updateMetadata_success() public {
        bytes16 scId = scm.addShareClass(POOL_ID, "Senior", "SR", bytes32(uint256(1)));

        scm.updateMetadata(POOL_ID, scId, "Senior Tranche V2", "SR-V2");

        IShareClassManager.ShareClassMetadata memory meta = scm.getMetadata(POOL_ID, scId);
        assertEq(meta.name, "Senior Tranche V2");
        assertEq(meta.symbol, "SR-V2");
    }

    function test_updateMetadata_preservesSalt() public {
        bytes32 originalSalt = bytes32(uint256(12345));
        bytes16 scId = scm.addShareClass(POOL_ID, "Senior", "SR", originalSalt);

        scm.updateMetadata(POOL_ID, scId, "New Name", "NEW");

        IShareClassManager.ShareClassMetadata memory meta = scm.getMetadata(POOL_ID, scId);
        assertEq(meta.salt, originalSalt);
    }

    function test_updateMetadata_revert_notFound() public {
        bytes16 fakeScId = bytes16(uint128(999));

        vm.expectRevert(abi.encodeWithSelector(IShareClassManager.ShareClassNotFound.selector, POOL_ID, fakeScId));
        scm.updateMetadata(POOL_ID, fakeScId, "Name", "SYM");
    }

    // ============================================================
    // PRICE UPDATE TESTS
    // ============================================================

    function test_updateSharePrice_success() public {
        bytes16 scId = scm.addShareClass(POOL_ID, "Senior", "SR", bytes32(uint256(1)));

        uint128 newPrice = 1.05e18; // $1.05
        uint64 timestamp = uint64(block.timestamp);

        scm.updateSharePrice(POOL_ID, scId, newPrice, timestamp);

        (uint128 price, uint64 computedAt) = scm.pricePerShare(POOL_ID, scId);
        assertEq(price, newPrice);
        assertEq(computedAt, timestamp);
    }

    function test_updateSharePrice_revert_futureTimestamp() public {
        bytes16 scId = scm.addShareClass(POOL_ID, "Senior", "SR", bytes32(uint256(1)));

        uint64 futureTime = uint64(block.timestamp + 1 hours);

        vm.expectRevert(
            abi.encodeWithSelector(
                IShareClassManager.FuturePriceTimestamp.selector, futureTime, uint64(block.timestamp)
            )
        );
        scm.updateSharePrice(POOL_ID, scId, 1e18, futureTime);
    }

    function test_updateSharePrice_revert_stalePrice() public {
        bytes16 scId = scm.addShareClass(POOL_ID, "Senior", "SR", bytes32(uint256(1)));

        // Set initial price
        uint64 time1 = uint64(block.timestamp);
        scm.updateSharePrice(POOL_ID, scId, 1e18, time1);

        // Try to set older price
        uint64 olderTime = time1 - 1;
        vm.expectRevert(abi.encodeWithSelector(IShareClassManager.StalePrice.selector, olderTime, time1));
        scm.updateSharePrice(POOL_ID, scId, 1.1e18, olderTime);
    }

    function test_updateSharePrice_allowSameTimestamp() public {
        bytes16 scId = scm.addShareClass(POOL_ID, "Senior", "SR", bytes32(uint256(1)));

        uint64 timestamp = uint64(block.timestamp);
        scm.updateSharePrice(POOL_ID, scId, 1e18, timestamp);

        // Same timestamp should be allowed (for corrections)
        scm.updateSharePrice(POOL_ID, scId, 1.01e18, timestamp);

        (uint128 price,) = scm.pricePerShare(POOL_ID, scId);
        assertEq(price, 1.01e18);
    }

    function test_updateSharePrice_revert_notFound() public {
        bytes16 fakeScId = bytes16(uint128(999));

        vm.expectRevert(abi.encodeWithSelector(IShareClassManager.ShareClassNotFound.selector, POOL_ID, fakeScId));
        scm.updateSharePrice(POOL_ID, fakeScId, 1e18, uint64(block.timestamp));
    }

    // ============================================================
    // ISSUANCE TRACKING TESTS
    // ============================================================

    function test_updateShares_issuance() public {
        bytes16 scId = scm.addShareClass(POOL_ID, "Senior", "SR", bytes32(uint256(1)));

        scm.updateShares(POOL_ID, scId, ETHEREUM_CHAIN, 1000e18, 0);

        uint128 netIssuance = scm.issuance(POOL_ID, scId, ETHEREUM_CHAIN);
        assertEq(netIssuance, 1000e18);
    }

    function test_updateShares_revocation() public {
        bytes16 scId = scm.addShareClass(POOL_ID, "Senior", "SR", bytes32(uint256(1)));

        // Issue 1000, revoke 200
        scm.updateShares(POOL_ID, scId, ETHEREUM_CHAIN, 1000e18, 0);
        scm.updateShares(POOL_ID, scId, ETHEREUM_CHAIN, 0, 200e18);

        uint128 netIssuance = scm.issuance(POOL_ID, scId, ETHEREUM_CHAIN);
        assertEq(netIssuance, 800e18);
    }

    function test_updateShares_cumulative() public {
        bytes16 scId = scm.addShareClass(POOL_ID, "Senior", "SR", bytes32(uint256(1)));

        // Multiple issuances
        scm.updateShares(POOL_ID, scId, ETHEREUM_CHAIN, 1000e18, 0);
        scm.updateShares(POOL_ID, scId, ETHEREUM_CHAIN, 500e18, 100e18);

        IShareClassManager.IssuancePerNetwork memory data = scm.getIssuancePerNetwork(POOL_ID, scId, ETHEREUM_CHAIN);
        assertEq(data.issuances, 1500e18);
        assertEq(data.revocations, 100e18);
    }

    function test_updateShares_multipleNetworks() public {
        bytes16 scId = scm.addShareClass(POOL_ID, "Senior", "SR", bytes32(uint256(1)));

        scm.updateShares(POOL_ID, scId, ETHEREUM_CHAIN, 1000e18, 0);
        scm.updateShares(POOL_ID, scId, BASE_CHAIN, 500e18, 0);

        assertEq(scm.issuance(POOL_ID, scId, ETHEREUM_CHAIN), 1000e18);
        assertEq(scm.issuance(POOL_ID, scId, BASE_CHAIN), 500e18);
    }

    function test_totalIssuance_singleNetwork() public {
        bytes16 scId = scm.addShareClass(POOL_ID, "Senior", "SR", bytes32(uint256(1)));

        scm.updateShares(POOL_ID, scId, ETHEREUM_CHAIN, 1000e18, 200e18);

        uint128 total = scm.totalIssuance(POOL_ID, scId);
        assertEq(total, 800e18);
    }

    function test_totalIssuance_multipleNetworks() public {
        bytes16 scId = scm.addShareClass(POOL_ID, "Senior", "SR", bytes32(uint256(1)));

        scm.updateShares(POOL_ID, scId, ETHEREUM_CHAIN, 1000e18, 100e18); // Net: 900
        scm.updateShares(POOL_ID, scId, BASE_CHAIN, 500e18, 50e18); // Net: 450

        uint128 total = scm.totalIssuance(POOL_ID, scId);
        assertEq(total, 1350e18);
    }

    function test_getActiveNetworks() public {
        bytes16 scId = scm.addShareClass(POOL_ID, "Senior", "SR", bytes32(uint256(1)));

        scm.updateShares(POOL_ID, scId, ETHEREUM_CHAIN, 100e18, 0);
        scm.updateShares(POOL_ID, scId, BASE_CHAIN, 50e18, 0);

        uint16[] memory networks = scm.getActiveNetworks(POOL_ID, scId);
        assertEq(networks.length, 2);
        assertEq(networks[0], ETHEREUM_CHAIN);
        assertEq(networks[1], BASE_CHAIN);
    }

    // ============================================================
    // ENUMERATION TESTS
    // ============================================================

    function test_getShareClassIds() public {
        bytes16 id1 = scm.addShareClass(POOL_ID, "Senior", "SR", bytes32(uint256(1)));
        bytes16 id2 = scm.addShareClass(POOL_ID, "Junior", "JR", bytes32(uint256(2)));
        bytes16 id3 = scm.addShareClass(POOL_ID, "Mezzanine", "MZ", bytes32(uint256(3)));

        bytes16[] memory ids = scm.getShareClassIds(POOL_ID);
        assertEq(ids.length, 3);
        assertEq(ids[0], id1);
        assertEq(ids[1], id2);
        assertEq(ids[2], id3);
    }

    // ============================================================
    // EVENT TESTS
    // ============================================================

    function test_events_shareClassAdded() public {
        vm.expectEmit(true, false, false, true);
        emit IShareClassManager.ShareClassAdded(POOL_ID, bytes16(0), "Senior", "SR");

        scm.addShareClass(POOL_ID, "Senior", "SR", bytes32(uint256(1)));
    }

    function test_events_sharePriceUpdated() public {
        bytes16 scId = scm.addShareClass(POOL_ID, "Senior", "SR", bytes32(uint256(1)));

        uint128 price = 1.05e18;
        uint64 timestamp = uint64(block.timestamp);

        vm.expectEmit(true, true, false, true);
        emit IShareClassManager.SharePriceUpdated(POOL_ID, scId, price, timestamp);

        scm.updateSharePrice(POOL_ID, scId, price, timestamp);
    }

    // ============================================================
    // FUZZ TESTS
    // ============================================================

    function testFuzz_priceUpdate(uint128 price) public {
        vm.assume(price > 0);

        bytes16 scId = scm.addShareClass(POOL_ID, "Senior", "SR", bytes32(uint256(1)));

        scm.updateSharePrice(POOL_ID, scId, price, uint64(block.timestamp));

        (uint128 storedPrice,) = scm.pricePerShare(POOL_ID, scId);
        assertEq(storedPrice, price);
    }

    function testFuzz_issuanceTracking(uint128 issued, uint128 revoked) public {
        vm.assume(issued >= revoked);
        vm.assume(issued < type(uint128).max / 2);

        bytes16 scId = scm.addShareClass(POOL_ID, "Senior", "SR", bytes32(uint256(1)));

        scm.updateShares(POOL_ID, scId, ETHEREUM_CHAIN, issued, revoked);

        uint128 net = scm.issuance(POOL_ID, scId, ETHEREUM_CHAIN);
        assertEq(net, issued - revoked);
    }
}
