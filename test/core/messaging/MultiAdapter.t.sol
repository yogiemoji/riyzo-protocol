// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.28;

import "forge-std/Test.sol";
import {MultiAdapter} from "src/core/messaging/MultiAdapter.sol";
import {MockAdapter} from "test/mocks/MockAdapter.sol";
import {MockMessageHandler} from "test/mocks/MockMessageHandler.sol";

contract MultiAdapterTest is Test {
    MultiAdapter public multiAdapter;
    MockAdapter public adapter1;
    MockAdapter public adapter2;
    MockAdapter public adapter3;
    MockMessageHandler public gateway;

    uint16 constant CHAIN_ETH = 2;
    uint16 constant LOCAL_CHAIN = 1;

    function setUp() public {
        multiAdapter = new MultiAdapter(LOCAL_CHAIN);
        gateway = new MockMessageHandler();
        adapter1 = new MockAdapter();
        adapter2 = new MockAdapter();
        adapter3 = new MockAdapter();

        multiAdapter.file("gateway", address(gateway));
    }

    // --- setAdapters ---

    function test_setAdapters() public {
        address[] memory adapters = new address[](2);
        adapters[0] = address(adapter1);
        adapters[1] = address(adapter2);

        multiAdapter.setAdapters(CHAIN_ETH, adapters, 2, 0);

        address[] memory result = multiAdapter.getAdapters(CHAIN_ETH);
        assertEq(result.length, 2);
        assertEq(result[0], address(adapter1));
        assertEq(result[1], address(adapter2));
        assertEq(multiAdapter.globalSessionId(), 1);
    }

    function test_setAdapters_withRecovery() public {
        address[] memory adapters = new address[](3);
        adapters[0] = address(adapter1);
        adapters[1] = address(adapter2);
        adapters[2] = address(adapter3);

        multiAdapter.setAdapters(CHAIN_ETH, adapters, 2, 3);

        address[] memory result = multiAdapter.getAdapters(CHAIN_ETH);
        assertEq(result.length, 3);
    }

    function test_setAdapters_revert_empty() public {
        address[] memory adapters = new address[](0);
        vm.expectRevert("MultiAdapter/empty-adapter-set");
        multiAdapter.setAdapters(CHAIN_ETH, adapters, 1, 0);
    }

    function test_setAdapters_revert_invalidThreshold() public {
        address[] memory adapters = new address[](2);
        adapters[0] = address(adapter1);
        adapters[1] = address(adapter2);

        vm.expectRevert("MultiAdapter/invalid-threshold");
        multiAdapter.setAdapters(CHAIN_ETH, adapters, 0, 0);

        vm.expectRevert("MultiAdapter/invalid-threshold");
        multiAdapter.setAdapters(CHAIN_ETH, adapters, 3, 0);
    }

    function test_setAdapters_revert_duplicates() public {
        address[] memory adapters = new address[](2);
        adapters[0] = address(adapter1);
        adapters[1] = address(adapter1);

        vm.expectRevert("MultiAdapter/no-duplicates");
        multiAdapter.setAdapters(CHAIN_ETH, adapters, 2, 0);
    }

    function test_setAdapters_revert_unauthorized() public {
        address[] memory adapters = new address[](1);
        adapters[0] = address(adapter1);

        vm.prank(address(0xdead));
        vm.expectRevert("Auth/not-authorized");
        multiAdapter.setAdapters(CHAIN_ETH, adapters, 1, 0);
    }

    // --- handle: threshold 1 (fast path) ---

    function test_handle_threshold1() public {
        address[] memory adapters = new address[](1);
        adapters[0] = address(adapter1);
        multiAdapter.setAdapters(CHAIN_ETH, adapters, 1, 0);

        bytes memory payload = abi.encodePacked(uint8(10), uint64(1));
        vm.prank(address(adapter1));
        multiAdapter.handle(CHAIN_ETH, payload);

        assertEq(gateway.handleCount(), 1);
    }

    // --- handle: threshold 2 (voting) ---

    function test_handle_threshold2_twoAdapters() public {
        _setupTwoAdapters();

        bytes memory payload = abi.encodePacked(uint8(10), uint64(1));

        // First adapter: vote but no execution
        vm.prank(address(adapter1));
        multiAdapter.handle(CHAIN_ETH, payload);
        assertEq(gateway.handleCount(), 0);

        // Second adapter: threshold met, execute
        vm.prank(address(adapter2));
        multiAdapter.handle(CHAIN_ETH, payload);
        assertEq(gateway.handleCount(), 1);
    }

    function test_handle_threshold2_sameAdapterTwice_noExecution() public {
        _setupTwoAdapters();

        bytes memory payload = abi.encodePacked(uint8(10), uint64(1));

        // Same adapter votes twice - only 1 unique voter, threshold not met
        vm.prank(address(adapter1));
        multiAdapter.handle(CHAIN_ETH, payload);
        vm.prank(address(adapter1));
        multiAdapter.handle(CHAIN_ETH, payload);

        // Still needs adapter2 to confirm
        assertEq(gateway.handleCount(), 0);
    }

    function test_handle_revert_invalidAdapter() public {
        _setupTwoAdapters();

        bytes memory payload = abi.encodePacked(uint8(10), uint64(1));
        vm.prank(address(0xbeef));
        vm.expectRevert("MultiAdapter/invalid-adapter");
        multiAdapter.handle(CHAIN_ETH, payload);
    }

    // --- handle: session invalidation ---

    function test_handle_sessionInvalidation() public {
        _setupTwoAdapters();

        bytes memory payload = abi.encodePacked(uint8(10), uint64(1));

        // First adapter votes
        vm.prank(address(adapter1));
        multiAdapter.handle(CHAIN_ETH, payload);

        // Reconfigure adapters (new session)
        address[] memory newAdapters = new address[](2);
        newAdapters[0] = address(adapter1);
        newAdapters[1] = address(adapter2);
        multiAdapter.setAdapters(CHAIN_ETH, newAdapters, 2, 0);

        // Old vote is invalidated, need fresh votes
        vm.prank(address(adapter2));
        multiAdapter.handle(CHAIN_ETH, payload);
        assertEq(gateway.handleCount(), 0); // Only 1 fresh vote

        vm.prank(address(adapter1));
        multiAdapter.handle(CHAIN_ETH, payload);
        assertEq(gateway.handleCount(), 1); // Now 2 fresh votes
    }

    // --- handle: parallel duplicate messages ---

    function test_handle_parallelDuplicates() public {
        _setupTwoAdapters();

        bytes memory payload = abi.encodePacked(uint8(10), uint64(1));

        // Both adapters confirm first message
        vm.prank(address(adapter1));
        multiAdapter.handle(CHAIN_ETH, payload);
        vm.prank(address(adapter2));
        multiAdapter.handle(CHAIN_ETH, payload);
        assertEq(gateway.handleCount(), 1);

        // Same message again (duplicate) - needs fresh votes
        vm.prank(address(adapter1));
        multiAdapter.handle(CHAIN_ETH, payload);
        vm.prank(address(adapter2));
        multiAdapter.handle(CHAIN_ETH, payload);
        assertEq(gateway.handleCount(), 2);
    }

    // --- send ---

    function test_send() public {
        _setupTwoAdapters();

        bytes memory payload = abi.encodePacked(uint8(10), uint64(1));
        uint256 cost = multiAdapter.estimate(CHAIN_ETH, payload, 300_000);

        multiAdapter.send{value: cost}(CHAIN_ETH, payload, 300_000, address(this));

        assertEq(adapter1.sendCount(), 1);
        assertEq(adapter2.sendCount(), 1);
    }

    function test_send_revert_noAdapters() public {
        bytes memory payload = abi.encodePacked(uint8(10), uint64(1));
        vm.expectRevert("MultiAdapter/no-adapters");
        multiAdapter.send(CHAIN_ETH, payload, 300_000, address(this));
    }

    function test_send_revert_unauthorized() public {
        _setupTwoAdapters();

        bytes memory payload = abi.encodePacked(uint8(10), uint64(1));
        vm.prank(address(0xdead));
        vm.expectRevert("Auth/not-authorized");
        multiAdapter.send(CHAIN_ETH, payload, 300_000, address(this));
    }

    // --- estimate ---

    function test_estimate() public {
        _setupTwoAdapters();
        adapter1.setEstimateCost(0.01 ether);
        adapter2.setEstimateCost(0.02 ether);

        bytes memory payload = abi.encodePacked(uint8(10), uint64(1));
        uint256 total = multiAdapter.estimate(CHAIN_ETH, payload, 300_000);

        assertEq(total, 0.03 ether);
    }

    // --- file ---

    function test_file_gateway() public {
        address newGateway = address(0x123);
        multiAdapter.file("gateway", newGateway);
        assertEq(multiAdapter.gateway(), newGateway);
    }

    function test_file_revert_unrecognized() public {
        vm.expectRevert("MultiAdapter/file-unrecognized-param");
        multiAdapter.file("unknown", address(0x123));
    }

    // --- view ---

    function test_localChainId() public view {
        assertEq(multiAdapter.localChainId(), LOCAL_CHAIN);
    }

    // --- Helpers ---

    function _setupTwoAdapters() internal {
        address[] memory adapters = new address[](2);
        adapters[0] = address(adapter1);
        adapters[1] = address(adapter2);
        multiAdapter.setAdapters(CHAIN_ETH, adapters, 2, 0);
    }

    receive() external payable {}
}
