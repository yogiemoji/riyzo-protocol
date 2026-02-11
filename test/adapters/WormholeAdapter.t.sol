// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.28;

import "forge-std/Test.sol";
import {WormholeAdapter} from "src/adapters/WormholeAdapter.sol";
import {MultiAdapter} from "src/core/messaging/MultiAdapter.sol";
import {MockWormholeRelayer} from "test/mocks/MockWormholeRelayer.sol";
import {MockMessageHandler} from "test/mocks/MockMessageHandler.sol";

contract WormholeAdapterTest is Test {
    WormholeAdapter public adapter;
    MultiAdapter public multiAdapter;
    MockWormholeRelayer public relayer;
    MockMessageHandler public gateway;

    uint16 constant CHAIN_ETH = 2;
    uint16 constant LOCAL_CHAIN = 1;
    uint16 constant WH_ETH = 2;
    uint16 constant WH_LOCAL = 23; // Arbitrum
    address constant REMOTE_ADAPTER = address(0x1234);

    function setUp() public {
        multiAdapter = new MultiAdapter(LOCAL_CHAIN);
        gateway = new MockMessageHandler();
        relayer = new MockWormholeRelayer();

        adapter = new WormholeAdapter(address(multiAdapter), address(relayer), WH_LOCAL);

        // Wire for Ethereum
        adapter.wire(CHAIN_ETH, abi.encode(uint16(WH_ETH), REMOTE_ADAPTER));

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

    // --- receiveWormholeMessages (incoming) ---

    function test_receiveWormholeMessages() public {
        bytes memory payload = abi.encodePacked(uint8(10), uint64(1));
        bytes32 sourceAddr = bytes32(uint256(uint160(REMOTE_ADAPTER)));

        vm.prank(address(relayer));
        adapter.receiveWormholeMessages(payload, new bytes[](0), sourceAddr, WH_ETH, bytes32(0));

        assertEq(gateway.handleCount(), 1);
    }

    function test_receiveWormholeMessages_revert_notRelayer() public {
        bytes memory payload = abi.encodePacked(uint8(10), uint64(1));
        bytes32 sourceAddr = bytes32(uint256(uint160(REMOTE_ADAPTER)));

        vm.prank(address(0xdead));
        vm.expectRevert("WormholeAdapter/not-relayer");
        adapter.receiveWormholeMessages(payload, new bytes[](0), sourceAddr, WH_ETH, bytes32(0));
    }

    function test_receiveWormholeMessages_revert_unknownSource() public {
        bytes memory payload = abi.encodePacked(uint8(10), uint64(1));
        bytes32 sourceAddr = bytes32(uint256(uint160(REMOTE_ADAPTER)));

        vm.prank(address(relayer));
        vm.expectRevert("WormholeAdapter/unknown-source");
        adapter.receiveWormholeMessages(payload, new bytes[](0), sourceAddr, 999, bytes32(0));
    }

    function test_receiveWormholeMessages_revert_invalidSender() public {
        bytes memory payload = abi.encodePacked(uint8(10), uint64(1));
        bytes32 wrongAddr = bytes32(uint256(uint160(address(0xdead))));

        vm.prank(address(relayer));
        vm.expectRevert("WormholeAdapter/invalid-sender");
        adapter.receiveWormholeMessages(payload, new bytes[](0), wrongAddr, WH_ETH, bytes32(0));
    }

    // --- send (outgoing) ---

    function test_send() public {
        bytes memory payload = abi.encodePacked(uint8(10), uint64(1));

        vm.prank(address(multiAdapter));
        adapter.send{value: 0.01 ether}(CHAIN_ETH, payload, 300_000, address(this));

        assertEq(relayer.sendCount(), 1);
        assertEq(relayer.lastTargetAddress(), REMOTE_ADAPTER);
    }

    function test_send_revert_notEntrypoint() public {
        bytes memory payload = abi.encodePacked(uint8(10), uint64(1));

        vm.prank(address(0xdead));
        vm.expectRevert("WormholeAdapter/not-entrypoint");
        adapter.send(CHAIN_ETH, payload, 300_000, address(this));
    }

    function test_send_revert_notWired() public {
        bytes memory payload = abi.encodePacked(uint8(10), uint64(1));

        vm.prank(address(multiAdapter));
        vm.expectRevert("WormholeAdapter/not-wired");
        adapter.send(3, payload, 300_000, address(this));
    }

    // --- estimate ---

    function test_estimate() public view {
        bytes memory payload = abi.encodePacked(uint8(10), uint64(1));
        uint256 cost = adapter.estimate(CHAIN_ETH, payload, 300_000);
        assertEq(cost, 0.01 ether);
    }

    receive() external payable {}
}
