// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.28;

import "forge-std/Test.sol";
import {LayerZeroAdapter} from "src/adapters/LayerZeroAdapter.sol";
import {MultiAdapter} from "src/core/messaging/MultiAdapter.sol";
import {MockLZEndpoint} from "test/mocks/MockLZEndpoint.sol";
import {MockMessageHandler} from "test/mocks/MockMessageHandler.sol";
import {Origin} from "src/interfaces/gateway/adapters/ILayerZeroAdapter.sol";

contract LayerZeroAdapterTest is Test {
    LayerZeroAdapter public adapter;
    MultiAdapter public multiAdapter;
    MockLZEndpoint public endpoint;
    MockMessageHandler public gateway;

    uint16 constant CHAIN_ETH = 2;
    uint16 constant LOCAL_CHAIN = 1;
    uint32 constant LZ_EID_ETH = 30101;
    address constant REMOTE_ADAPTER = address(0x1234);

    function setUp() public {
        multiAdapter = new MultiAdapter(LOCAL_CHAIN);
        gateway = new MockMessageHandler();
        endpoint = new MockLZEndpoint();

        adapter = new LayerZeroAdapter(address(multiAdapter), address(endpoint));

        // Wire for Ethereum
        adapter.wire(CHAIN_ETH, abi.encode(uint32(LZ_EID_ETH), REMOTE_ADAPTER));

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
        assertFalse(adapter.isWired(3));
    }

    function test_wire_setsDelegate() public view {
        assertEq(endpoint.delegate(), address(adapter));
    }

    // --- lzReceive (incoming) ---

    function test_lzReceive() public {
        bytes memory payload = abi.encodePacked(uint8(10), uint64(1));
        Origin memory origin = Origin({srcEid: LZ_EID_ETH, sender: bytes32(uint256(uint160(REMOTE_ADAPTER))), nonce: 1});

        vm.prank(address(endpoint));
        adapter.lzReceive(origin, bytes32(0), payload, address(0), "");

        assertEq(gateway.handleCount(), 1);
    }

    function test_lzReceive_revert_notEndpoint() public {
        bytes memory payload = abi.encodePacked(uint8(10), uint64(1));
        Origin memory origin = Origin({srcEid: LZ_EID_ETH, sender: bytes32(uint256(uint160(REMOTE_ADAPTER))), nonce: 1});

        vm.prank(address(0xdead));
        vm.expectRevert("LayerZeroAdapter/not-endpoint");
        adapter.lzReceive(origin, bytes32(0), payload, address(0), "");
    }

    function test_lzReceive_revert_unknownSource() public {
        bytes memory payload = abi.encodePacked(uint8(10), uint64(1));
        Origin memory origin = Origin({
            srcEid: 99999, // Unknown EID
            sender: bytes32(uint256(uint160(REMOTE_ADAPTER))),
            nonce: 1
        });

        vm.prank(address(endpoint));
        vm.expectRevert("LayerZeroAdapter/unknown-source");
        adapter.lzReceive(origin, bytes32(0), payload, address(0), "");
    }

    function test_lzReceive_revert_invalidSender() public {
        bytes memory payload = abi.encodePacked(uint8(10), uint64(1));
        Origin memory origin = Origin({
            srcEid: LZ_EID_ETH,
            sender: bytes32(uint256(uint160(address(0xdead)))), // Wrong sender
            nonce: 1
        });

        vm.prank(address(endpoint));
        vm.expectRevert("LayerZeroAdapter/invalid-sender");
        adapter.lzReceive(origin, bytes32(0), payload, address(0), "");
    }

    // --- send (outgoing) ---

    function test_send() public {
        bytes memory payload = abi.encodePacked(uint8(10), uint64(1));

        vm.prank(address(multiAdapter));
        adapter.send{value: 0.01 ether}(CHAIN_ETH, payload, 300_000, address(this));

        assertEq(endpoint.sendCount(), 1);
    }

    function test_send_revert_notEntrypoint() public {
        bytes memory payload = abi.encodePacked(uint8(10), uint64(1));

        vm.prank(address(0xdead));
        vm.expectRevert("LayerZeroAdapter/not-entrypoint");
        adapter.send(CHAIN_ETH, payload, 300_000, address(this));
    }

    function test_send_revert_notWired() public {
        bytes memory payload = abi.encodePacked(uint8(10), uint64(1));

        vm.prank(address(multiAdapter));
        vm.expectRevert("LayerZeroAdapter/not-wired");
        adapter.send(3, payload, 300_000, address(this)); // Chain 3 not wired
    }

    // --- estimate ---

    function test_estimate() public view {
        bytes memory payload = abi.encodePacked(uint8(10), uint64(1));
        uint256 cost = adapter.estimate(CHAIN_ETH, payload, 300_000);
        assertEq(cost, 0.01 ether);
    }

    receive() external payable {}
}
