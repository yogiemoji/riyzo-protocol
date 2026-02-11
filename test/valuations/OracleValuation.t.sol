// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {OracleValuation} from "src/valuations/OracleValuation.sol";
import {MockRiyzoRegistry} from "test/mocks/MockRiyzoRegistry.sol";

contract OracleValuationTest is Test {
    OracleValuation public valuation;
    MockRiyzoRegistry public registry;

    address public admin = address(this);
    address public manager = address(0x1);
    address public feeder = address(0x2);
    address public nonFeeder = address(0x3);

    uint64 public constant POOL_ID = 1;
    bytes16 public constant SC_ID = bytes16(uint128(1));
    uint128 public constant ASSET_ID = 1;

    function setUp() public {
        registry = new MockRiyzoRegistry();
        registry.setDecimals(ASSET_ID, 18);
        registry.setManager(POOL_ID, manager, true);

        valuation = new OracleValuation(admin, address(registry));

        // Manager authorizes feeder
        vm.prank(manager);
        valuation.updateFeeder(POOL_ID, feeder, true);
    }

    // --- Feeder management ---
    function test_updateFeeder_byManager() public {
        address newFeeder = address(0x4);
        vm.prank(manager);
        valuation.updateFeeder(POOL_ID, newFeeder, true);
        assertTrue(valuation.feeders(POOL_ID, newFeeder));
    }

    function test_updateFeeder_revert_nonManager() public {
        vm.prank(nonFeeder);
        vm.expectRevert("OracleValuation/not-pool-manager");
        valuation.updateFeeder(POOL_ID, nonFeeder, true);
    }

    function test_updateFeeder_revoke() public {
        vm.prank(manager);
        valuation.updateFeeder(POOL_ID, feeder, false);
        assertFalse(valuation.feeders(POOL_ID, feeder));
    }

    // --- setPrice ---
    function test_setPrice_success() public {
        vm.prank(feeder);
        valuation.setPrice(POOL_ID, SC_ID, ASSET_ID, 2000e18);

        assertEq(valuation.getPrice(POOL_ID, SC_ID, ASSET_ID), 2000e18);
    }

    function test_setPrice_revert_nonFeeder() public {
        vm.prank(nonFeeder);
        vm.expectRevert("OracleValuation/not-authorized-feeder");
        valuation.setPrice(POOL_ID, SC_ID, ASSET_ID, 2000e18);
    }

    function test_setPrice_revert_zeroPrice() public {
        vm.prank(feeder);
        vm.expectRevert("OracleValuation/zero-price");
        valuation.setPrice(POOL_ID, SC_ID, ASSET_ID, 0);
    }

    function test_setPrice_updatesTimestamp() public {
        vm.warp(1000);
        vm.prank(feeder);
        valuation.setPrice(POOL_ID, SC_ID, ASSET_ID, 2000e18);

        assertEq(valuation.lastUpdated(POOL_ID, SC_ID, ASSET_ID), 1000);
    }

    // --- getPrice ---
    function test_getPrice_revert_notSet() public {
        vm.expectRevert("OracleValuation/price-not-set");
        valuation.getPrice(POOL_ID, SC_ID, 999); // Different asset, not set
    }

    // --- getQuote ---
    function test_getQuote_18decimals() public {
        vm.prank(feeder);
        valuation.setPrice(POOL_ID, SC_ID, ASSET_ID, 2000e18);

        // 1.5 ETH at $2000 = $3000
        uint128 quote = valuation.getQuote(POOL_ID, SC_ID, ASSET_ID, 1.5e18);
        assertEq(quote, 3000e18);
    }

    function test_getQuote_6decimals() public {
        uint128 usdcAssetId = 2;
        registry.setDecimals(usdcAssetId, 6);

        vm.prank(manager);
        valuation.updateFeeder(POOL_ID, feeder, true);

        vm.prank(feeder);
        valuation.setPrice(POOL_ID, SC_ID, usdcAssetId, 1e18); // $1

        // 1000 USDC (1000e6) at $1 = $1000
        uint128 quote = valuation.getQuote(POOL_ID, SC_ID, usdcAssetId, 1000e6);
        assertEq(quote, 1000e18);
    }

    function test_getQuote_revert_notSet() public {
        vm.expectRevert("OracleValuation/price-not-set");
        valuation.getQuote(POOL_ID, SC_ID, 999, 100);
    }

    // --- isSupported ---
    function test_isSupported_true_afterSetPrice() public {
        vm.prank(feeder);
        valuation.setPrice(POOL_ID, SC_ID, ASSET_ID, 2000e18);
        assertTrue(valuation.isSupported(POOL_ID, SC_ID, ASSET_ID));
    }

    function test_isSupported_false_noPrice() public view {
        assertFalse(valuation.isSupported(POOL_ID, SC_ID, 999));
    }

    // --- lastUpdated ---
    function test_lastUpdated_zero_noPrice() public view {
        assertEq(valuation.lastUpdated(POOL_ID, SC_ID, 999), 0);
    }

    // --- file ---
    function test_file_registry() public {
        MockRiyzoRegistry newRegistry = new MockRiyzoRegistry();
        valuation.file("registry", address(newRegistry));
        assertEq(address(valuation.registry()), address(newRegistry));
    }

    function test_file_revert_unrecognized() public {
        vm.expectRevert("OracleValuation/file-unrecognized-param");
        valuation.file("unknown", address(0x1));
    }
}
