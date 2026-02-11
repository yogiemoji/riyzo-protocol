// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.28;

import "forge-std/Test.sol";
import {AxelarAdapter} from "src/adapters/AxelarAdapter.sol";
import {MultiAdapter} from "src/core/messaging/MultiAdapter.sol";
import {MockAxelarGateway, MockAxelarGasService} from "test/mocks/MockAxelarGateway.sol";
import {MockMessageHandler} from "test/mocks/MockMessageHandler.sol";

contract AxelarAdapterTest is Test {
    AxelarAdapter public adapter;
    MultiAdapter public multiAdapter;
    MockAxelarGateway public axelarGateway;
    MockAxelarGasService public axelarGasService;
    MockMessageHandler public gateway;

    uint16 constant CHAIN_ETH = 2;
    uint16 constant LOCAL_CHAIN = 1;

    string constant AXELAR_CHAIN = "ethereum";
    string constant REMOTE_ADAPTER = "0x1234567890abcdef1234567890abcdef12345678";

    function setUp() public {
        multiAdapter = new MultiAdapter(LOCAL_CHAIN);
        gateway = new MockMessageHandler();
        axelarGateway = new MockAxelarGateway();
        axelarGasService = new MockAxelarGasService();

        adapter = new AxelarAdapter(address(multiAdapter), address(axelarGateway), address(axelarGasService));

        // Wire adapter for Ethereum
        adapter.wire(CHAIN_ETH, abi.encode(AXELAR_CHAIN, REMOTE_ADAPTER));

        // Setup MultiAdapter
        multiAdapter.file("gateway", address(gateway));
        address[] memory adapters = new address[](1);
        adapters[0] = address(adapter);
        multiAdapter.setAdapters(CHAIN_ETH, adapters, 1, 0);

        vm.deal(address(this), 10 ether);
        vm.deal(address(multiAdapter), 10 ether);
    }

    // --- wire ---

    function test_wire() public view {
        assertTrue(adapter.isWired(CHAIN_ETH));
        assertFalse(adapter.isWired(3)); // Base not wired
    }

    function test_wire_revert_unauthorized() public {
        vm.prank(address(0xdead));
        vm.expectRevert("Auth/not-authorized");
        adapter.wire(3, abi.encode("base", "0xabcd"));
    }

    // --- execute (incoming) ---

    function test_execute() public {
        bytes memory payload = abi.encodePacked(uint8(10), uint64(1));

        adapter.execute(bytes32(uint256(1)), AXELAR_CHAIN, REMOTE_ADAPTER, payload);

        assertEq(gateway.handleCount(), 1);
    }

    function test_execute_revert_unknownChain() public {
        bytes memory payload = abi.encodePacked(uint8(10), uint64(1));

        vm.expectRevert("AxelarAdapter/unknown-source-chain");
        adapter.execute(bytes32(uint256(1)), "unknown", REMOTE_ADAPTER, payload);
    }

    function test_execute_revert_invalidAddress() public {
        bytes memory payload = abi.encodePacked(uint8(10), uint64(1));

        vm.expectRevert("AxelarAdapter/invalid-source-address");
        adapter.execute(bytes32(uint256(1)), AXELAR_CHAIN, "0xwrongaddress", payload);
    }

    function test_execute_revert_notApproved() public {
        axelarGateway.setValidateResult(false);
        bytes memory payload = abi.encodePacked(uint8(10), uint64(1));

        vm.expectRevert("AxelarAdapter/not-approved-by-axelar-gateway");
        adapter.execute(bytes32(uint256(1)), AXELAR_CHAIN, REMOTE_ADAPTER, payload);
    }

    // --- send (outgoing) ---

    function test_send() public {
        bytes memory payload = abi.encodePacked(uint8(10), uint64(1));

        vm.prank(address(multiAdapter));
        adapter.send{value: 0.01 ether}(CHAIN_ETH, payload, 300_000, address(this));

        assertEq(axelarGateway.callCount(), 1);
        assertEq(axelarGasService.payCount(), 1);
    }

    function test_send_revert_notEntrypoint() public {
        bytes memory payload = abi.encodePacked(uint8(10), uint64(1));

        vm.prank(address(0xdead));
        vm.expectRevert("AxelarAdapter/not-entrypoint");
        adapter.send(CHAIN_ETH, payload, 300_000, address(this));
    }

    function test_send_revert_notWired() public {
        bytes memory payload = abi.encodePacked(uint8(10), uint64(1));

        vm.prank(address(multiAdapter));
        vm.expectRevert("AxelarAdapter/not-wired");
        adapter.send(3, payload, 300_000, address(this)); // Chain 3 not wired
    }

    // --- estimate ---

    function test_estimate() public view {
        bytes memory payload = abi.encodePacked(uint8(10), uint64(1));
        uint256 cost = adapter.estimate(CHAIN_ETH, payload, 300_000);
        assertEq(cost, 58_039_058_122_843);
    }

    // --- file ---

    function test_file_axelarCost() public {
        adapter.file("axelarCost", 100_000);
        assertEq(adapter.axelarCost(), 100_000);
    }

    function test_file_revert_unrecognized() public {
        vm.expectRevert("AxelarAdapter/file-unrecognized-param");
        adapter.file("unknown", 100_000);
    }

    receive() external payable {}
}
