// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {IdentityValuation} from "src/valuations/IdentityValuation.sol";
import {MockRiyzoRegistry} from "test/mocks/MockRiyzoRegistry.sol";

contract IdentityValuationTest is Test {
    IdentityValuation public valuation;
    MockRiyzoRegistry public registry;

    uint64 public constant POOL_ID = 1;
    bytes16 public constant SC_ID = bytes16(uint128(1));
    uint128 public constant ASSET_ID = 1;

    function setUp() public {
        registry = new MockRiyzoRegistry();
        valuation = new IdentityValuation(address(registry));
    }

    // --- getPrice ---
    function test_getPrice_always1e18() public view {
        assertEq(valuation.getPrice(POOL_ID, SC_ID, ASSET_ID), 1e18);
    }

    // --- getQuote decimal conversions ---
    function test_getQuote_6decimals() public {
        registry.setDecimals(ASSET_ID, 6);
        // 1,000,000 (1e6 = 1 USDC) → 1e18
        uint128 quote = valuation.getQuote(POOL_ID, SC_ID, ASSET_ID, 1e6);
        assertEq(quote, 1e18);
    }

    function test_getQuote_18decimals() public {
        registry.setDecimals(ASSET_ID, 18);
        // 1e18 → 1e18 (no conversion)
        uint128 quote = valuation.getQuote(POOL_ID, SC_ID, ASSET_ID, 1e18);
        assertEq(quote, 1e18);
    }

    function test_getQuote_8decimals() public {
        registry.setDecimals(ASSET_ID, 8);
        // 1e8 (1 WBTC) → 1e18
        uint128 quote = valuation.getQuote(POOL_ID, SC_ID, ASSET_ID, 1e8);
        assertEq(quote, 1e18);
    }

    function test_getQuote_fractionalAmount() public {
        registry.setDecimals(ASSET_ID, 6);
        // 500,000 (0.5 USDC) → 0.5e18
        uint128 quote = valuation.getQuote(POOL_ID, SC_ID, ASSET_ID, 500_000);
        assertEq(quote, 0.5e18);
    }

    // --- isSupported ---
    function test_isSupported_alwaysTrue() public view {
        assertTrue(valuation.isSupported(POOL_ID, SC_ID, ASSET_ID));
        assertTrue(valuation.isSupported(99, bytes16(uint128(99)), 99));
    }

    // --- lastUpdated ---
    function test_lastUpdated_returnsBlockTimestamp() public view {
        assertEq(valuation.lastUpdated(POOL_ID, SC_ID, ASSET_ID), uint64(block.timestamp));
    }
}
