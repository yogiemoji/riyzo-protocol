// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.28;

import "forge-std/Test.sol";
import {Gateway} from "src/core/messaging/Gateway.sol";
import {Root} from "src/admin/Root.sol";
import {GasService} from "src/core/messaging/GasService.sol";
import {MockMessageHandler} from "test/mocks/MockMessageHandler.sol";
import {MultiAdapter} from "src/core/messaging/MultiAdapter.sol";
import {MockAdapter} from "test/mocks/MockAdapter.sol";

contract GatewayTest is Test {
    Gateway public gateway;
    Root public root;
    GasService public gasService;
    MultiAdapter public multiAdapter;
    MockAdapter public adapter1;
    MockMessageHandler public poolManager;
    MockMessageHandler public investmentManager;
    MockMessageHandler public spokeHandler;

    uint16 constant HUB_CHAIN = 1;
    uint16 constant LOCAL_CHAIN = 2;

    function setUp() public {
        root = new Root(address(this), 0, address(this));
        gasService = new GasService(100_000, 50_000, 1e18, 1e18);
        multiAdapter = new MultiAdapter(LOCAL_CHAIN);
        adapter1 = new MockAdapter();
        poolManager = new MockMessageHandler();
        investmentManager = new MockMessageHandler();
        spokeHandler = new MockMessageHandler();

        gateway = new Gateway(address(root));
        gateway.file("gasService", address(gasService));
        gateway.file("poolManager", address(poolManager));
        gateway.file("investmentManager", address(investmentManager));
        gateway.file("multiAdapter", address(multiAdapter));
        gateway.file("hubChainId", uint256(HUB_CHAIN));

        // Wire MultiAdapter
        multiAdapter.file("gateway", address(gateway));
        multiAdapter.rely(address(gateway));

        // Setup adapter
        address[] memory adapters = new address[](1);
        adapters[0] = address(adapter1);
        multiAdapter.setAdapters(HUB_CHAIN, adapters, 1, 0);

        // Fund gateway for gas
        vm.deal(address(gateway), 10 ether);
    }

    // --- handle (incoming) ---

    function test_handle_dispatchToPoolManager() public {
        bytes memory message = abi.encodePacked(uint8(10), uint64(1)); // ID 10 -> poolManager

        vm.prank(address(multiAdapter));
        gateway.handle(message);

        assertEq(poolManager.handleCount(), 1);
    }

    function test_handle_dispatchToInvestmentManager() public {
        bytes memory message = abi.encodePacked(uint8(20), uint64(1)); // ID 20 -> investmentManager

        vm.prank(address(multiAdapter));
        gateway.handle(message);

        assertEq(investmentManager.handleCount(), 1);
    }

    function test_handle_dispatchToSpokeHandler() public {
        gateway.file("spokeHandler", address(spokeHandler));

        bytes memory message = abi.encodePacked(uint8(10), uint64(1)); // ID 10 -> spokeHandler (when set)

        vm.prank(address(multiAdapter));
        gateway.handle(message);

        assertEq(spokeHandler.handleCount(), 1);
        assertEq(poolManager.handleCount(), 0);
    }

    function test_handle_dispatchToGasService() public {
        // GasService handles message ID 8 - requires auth from gateway
        gasService.rely(address(gateway));

        // UpdateCentrifugeGasPrice message: type(8) + uint128 gasPrice + uint64 computedAt
        bytes memory message = abi.encodePacked(uint8(8), uint128(2e18), uint64(block.timestamp + 1));

        vm.prank(address(multiAdapter));
        gateway.handle(message);

        // GasService updated the gas price
        assertEq(gasService.gasPrice(), 2e18);
    }

    function test_handle_customHandler() public {
        MockMessageHandler customHandler = new MockMessageHandler();
        gateway.file("message", uint8(50), address(customHandler));

        bytes memory message = abi.encodePacked(uint8(50), uint64(1));

        vm.prank(address(multiAdapter));
        gateway.handle(message);

        assertEq(customHandler.handleCount(), 1);
    }

    function test_handle_revert_notMultiAdapter() public {
        bytes memory message = abi.encodePacked(uint8(10), uint64(1));

        vm.prank(address(0xdead));
        vm.expectRevert("Gateway/not-multi-adapter");
        gateway.handle(message);
    }

    function test_handle_revert_unregisteredId() public {
        bytes memory message = abi.encodePacked(uint8(50), uint64(1)); // No handler registered

        vm.prank(address(multiAdapter));
        vm.expectRevert("Gateway/unregistered-message-id");
        gateway.handle(message);
    }

    // --- send (outgoing) ---

    function test_send_withRefuel() public {
        bytes memory message = abi.encodePacked(uint8(10), uint64(1));

        vm.prank(address(poolManager));
        gateway.send(message, address(this));

        assertEq(adapter1.sendCount(), 1);
    }

    function test_send_revert_invalidManager() public {
        bytes memory message = abi.encodePacked(uint8(10), uint64(1));

        vm.prank(address(0xdead));
        vm.expectRevert("Gateway/invalid-manager");
        gateway.send(message, address(this));
    }

    function test_send_revert_notInitialized() public {
        Gateway gw2 = new Gateway(address(root));
        gw2.file("gasService", address(gasService));
        gw2.file("investmentManager", address(investmentManager));

        bytes memory message = abi.encodePacked(uint8(20), uint64(1));

        vm.prank(address(investmentManager));
        vm.expectRevert("Gateway/not-initialized");
        gw2.send(message, address(this));
    }

    // --- topUp ---

    function test_topUp() public {
        gateway.file("payers", address(this), true);
        gateway.topUp{value: 1 ether}();
        // Transient storage is set - would be consumed by subsequent send()
    }

    function test_topUp_revert_notPayer() public {
        vm.expectRevert("Gateway/only-payers-can-top-up");
        gateway.topUp{value: 1 ether}();
    }

    function test_topUp_revert_zeroValue() public {
        gateway.file("payers", address(this), true);
        vm.expectRevert("Gateway/cannot-topup-with-nothing");
        gateway.topUp();
    }

    // --- estimate ---

    function test_estimate() public view {
        bytes memory payload = abi.encodePacked(uint8(10), uint64(1));
        uint256 total = gateway.estimate(payload);
        assertEq(total, adapter1.estimateCost());
    }

    // --- file ---

    function test_file_address() public {
        address newPM = address(0x111);
        gateway.file("poolManager", newPM);

        address newIM = address(0x222);
        gateway.file("investmentManager", newIM);
    }

    function test_file_hubChainId() public {
        gateway.file("hubChainId", uint256(3));
        assertEq(gateway.hubChainId(), 3);
    }

    function test_file_defaultGasLimit() public {
        gateway.file("defaultGasLimit", uint256(500_000));
        assertEq(gateway.defaultGasLimit(), 500_000);
    }

    function test_file_spokeHandler() public {
        gateway.file("spokeHandler", address(spokeHandler));
        assertEq(gateway.spokeHandler(), address(spokeHandler));
    }

    function test_file_revert_unauthorized() public {
        vm.prank(address(0xdead));
        vm.expectRevert("Auth/not-authorized");
        gateway.file("poolManager", address(0x111));
    }

    // --- receive ---

    function test_receive() public {
        (bool sent,) = address(gateway).call{value: 1 ether}("");
        assertTrue(sent);
        assertEq(address(gateway).balance, 11 ether); // 10 from setUp + 1
    }

    receive() external payable {}
}
