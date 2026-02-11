// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.28;

import "forge-std/Test.sol";
import {RecoveryAdapter} from "src/adapters/RecoveryAdapter.sol";
import {MultiAdapter} from "src/core/messaging/MultiAdapter.sol";
import {MockAdapter} from "test/mocks/MockAdapter.sol";
import {MockMessageHandler} from "test/mocks/MockMessageHandler.sol";

contract RecoveryAdapterTest is Test {
    RecoveryAdapter public recovery;
    MultiAdapter public multiAdapter;
    MockAdapter public adapter1;
    MockMessageHandler public gateway;

    uint16 constant CHAIN_ETH = 2;
    uint16 constant LOCAL_CHAIN = 1;

    function setUp() public {
        multiAdapter = new MultiAdapter(LOCAL_CHAIN);
        gateway = new MockMessageHandler();
        adapter1 = new MockAdapter();

        recovery = new RecoveryAdapter(address(multiAdapter));

        multiAdapter.file("gateway", address(gateway));

        // Setup with 2-of-2 adapters (adapter1 + recovery)
        address[] memory adapters = new address[](2);
        adapters[0] = address(adapter1);
        adapters[1] = address(recovery);
        multiAdapter.setAdapters(CHAIN_ETH, adapters, 2, 2); // recoveryIndex=2 (recovery is index 1, 1-based=2)
    }

    // --- recover ---

    function test_recover_completes_quorum() public {
        bytes memory payload = abi.encodePacked(uint8(10), uint64(1));

        // Adapter1 votes
        vm.prank(address(adapter1));
        multiAdapter.handle(CHAIN_ETH, payload);
        assertEq(gateway.handleCount(), 0);

        // Recovery adapter injects same message -> threshold met
        recovery.recover(CHAIN_ETH, payload);
        assertEq(gateway.handleCount(), 1);
    }

    function test_recover_revert_unauthorized() public {
        bytes memory payload = abi.encodePacked(uint8(10), uint64(1));

        vm.prank(address(0xdead));
        vm.expectRevert("Auth/not-authorized");
        recovery.recover(CHAIN_ETH, payload);
    }

    // --- no-op functions ---

    function test_send_noop() public {
        recovery.send(CHAIN_ETH, "", 0, address(0));
        // No revert, just no-op
    }

    function test_estimate_zero() public view {
        uint256 cost = recovery.estimate(CHAIN_ETH, "", 0);
        assertEq(cost, 0);
    }

    function test_isWired_alwaysTrue() public view {
        assertTrue(recovery.isWired(CHAIN_ETH));
        assertTrue(recovery.isWired(999));
    }

    receive() external payable {}
}
