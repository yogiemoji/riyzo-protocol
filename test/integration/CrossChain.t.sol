// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.28;

import "forge-std/Test.sol";
import {Gateway} from "src/core/messaging/Gateway.sol";
import {MultiAdapter} from "src/core/messaging/MultiAdapter.sol";
import {Root} from "src/admin/Root.sol";
import {GasService} from "src/core/messaging/GasService.sol";
import {MockAdapter} from "test/mocks/MockAdapter.sol";
import {MockMessageHandler} from "test/mocks/MockMessageHandler.sol";
import {RecoveryAdapter} from "src/adapters/RecoveryAdapter.sol";

/// @title CrossChainTest
/// @notice Integration test for the full cross-chain messaging flow:
///         Gateway -> MultiAdapter -> Adapters (outgoing)
///         Adapters -> MultiAdapter -> Gateway -> Handler (incoming)
contract CrossChainTest is Test {
    // Spoke chain components
    Gateway public spokeGateway;
    MultiAdapter public spokeMultiAdapter;
    Root public spokeRoot;
    GasService public spokeGasService;
    MockMessageHandler public spokePoolManager;
    MockMessageHandler public spokeInvestmentManager;
    MockMessageHandler public spokeSpokeHandler;

    // Adapters
    MockAdapter public adapterAxelar;
    MockAdapter public adapterLZ;
    MockAdapter public adapterWH;
    RecoveryAdapter public recoveryAdapter;

    uint16 constant HUB_CHAIN = 1;
    uint16 constant SPOKE_CHAIN = 2;

    function setUp() public {
        // Deploy spoke infrastructure
        spokeRoot = new Root(address(this), 0, address(this));
        spokeGasService = new GasService(100_000, 50_000, 1e18, 1e18);
        spokeMultiAdapter = new MultiAdapter(SPOKE_CHAIN);
        spokePoolManager = new MockMessageHandler();
        spokeInvestmentManager = new MockMessageHandler();
        spokeSpokeHandler = new MockMessageHandler();

        // Deploy adapters
        adapterAxelar = new MockAdapter();
        adapterLZ = new MockAdapter();
        adapterWH = new MockAdapter();
        recoveryAdapter = new RecoveryAdapter(address(spokeMultiAdapter));

        // Deploy Gateway
        spokeGateway = new Gateway(address(spokeRoot));
        spokeGateway.file("gasService", address(spokeGasService));
        spokeGateway.file("poolManager", address(spokePoolManager));
        spokeGateway.file("investmentManager", address(spokeInvestmentManager));
        spokeGateway.file("spokeHandler", address(spokeSpokeHandler));
        spokeGateway.file("multiAdapter", address(spokeMultiAdapter));
        spokeGateway.file("hubChainId", uint256(HUB_CHAIN));

        // Wire MultiAdapter
        spokeMultiAdapter.file("gateway", address(spokeGateway));
        spokeMultiAdapter.rely(address(spokeGateway));

        // Fund gateway for gas
        vm.deal(address(spokeGateway), 10 ether);
    }

    // --- Outgoing: Manager -> Gateway -> MultiAdapter -> 3 Adapters ---

    function test_outgoing_throughThreeAdapters() public {
        _setup3of3Quorum();

        bytes memory message = abi.encodePacked(uint8(10), uint64(1));

        // InvestmentManager sends message
        vm.prank(address(spokeInvestmentManager));
        spokeGateway.send(message, address(this));

        // All three adapters received the message
        assertEq(adapterAxelar.sendCount(), 1);
        assertEq(adapterLZ.sendCount(), 1);
        assertEq(adapterWH.sendCount(), 1);
    }

    // --- Incoming: 2-of-3 quorum ---

    function test_incoming_2of3_quorum() public {
        _setup2of3Quorum();

        bytes memory message = abi.encodePacked(uint8(10), uint64(1)); // -> spokeHandler

        // First adapter delivers - no execution
        vm.prank(address(adapterAxelar));
        spokeMultiAdapter.handle(HUB_CHAIN, message);
        assertEq(spokeSpokeHandler.handleCount(), 0);

        // Second adapter delivers - threshold met, execute
        vm.prank(address(adapterLZ));
        spokeMultiAdapter.handle(HUB_CHAIN, message);
        assertEq(spokeSpokeHandler.handleCount(), 1);
    }

    function test_incoming_1of3_notEnough() public {
        _setup2of3Quorum();

        bytes memory message = abi.encodePacked(uint8(10), uint64(1));

        // Only one adapter delivers - not enough
        vm.prank(address(adapterAxelar));
        spokeMultiAdapter.handle(HUB_CHAIN, message);
        assertEq(spokeSpokeHandler.handleCount(), 0);
    }

    // --- Recovery adapter injection ---

    function test_recovery_injection() public {
        _setup2of3WithRecovery();

        bytes memory message = abi.encodePacked(uint8(10), uint64(1));

        // Axelar delivers message
        vm.prank(address(adapterAxelar));
        spokeMultiAdapter.handle(HUB_CHAIN, message);
        assertEq(spokeSpokeHandler.handleCount(), 0);

        // LZ is stuck, so governance injects via recovery adapter
        recoveryAdapter.recover(HUB_CHAIN, message);
        assertEq(spokeSpokeHandler.handleCount(), 1);
    }

    // --- Session invalidation ---

    function test_sessionInvalidation_onAdapterReconfig() public {
        _setup2of3Quorum();

        bytes memory message = abi.encodePacked(uint8(10), uint64(1));

        // Axelar delivers first
        vm.prank(address(adapterAxelar));
        spokeMultiAdapter.handle(HUB_CHAIN, message);

        // Adapters get reconfigured (e.g., replacing LZ with recovery)
        address[] memory newAdapters = new address[](3);
        newAdapters[0] = address(adapterAxelar);
        newAdapters[1] = address(adapterWH);
        newAdapters[2] = address(recoveryAdapter);
        spokeMultiAdapter.setAdapters(HUB_CHAIN, newAdapters, 2, 3);

        // Old Axelar vote is invalidated. Need fresh votes.
        vm.prank(address(adapterWH));
        spokeMultiAdapter.handle(HUB_CHAIN, message);
        assertEq(spokeSpokeHandler.handleCount(), 0); // Only 1 fresh vote

        vm.prank(address(adapterAxelar));
        spokeMultiAdapter.handle(HUB_CHAIN, message);
        assertEq(spokeSpokeHandler.handleCount(), 1); // Now 2 fresh votes
    }

    // --- Spoke dispatch routing ---

    function test_dispatch_spokeHandler_for_poolManagerIds() public {
        _setup2of3Quorum();

        // Message IDs 9-19 go to spokeHandler on spoke chains
        for (uint8 id = 9; id <= 19; id++) {
            bytes memory message = abi.encodePacked(id, uint64(1));

            vm.prank(address(adapterAxelar));
            spokeMultiAdapter.handle(HUB_CHAIN, message);
            vm.prank(address(adapterLZ));
            spokeMultiAdapter.handle(HUB_CHAIN, message);
        }

        assertEq(spokeSpokeHandler.handleCount(), 11); // IDs 9-19
        assertEq(spokePoolManager.handleCount(), 0); // Not poolManager
    }

    function test_dispatch_investmentManager_for_investmentIds() public {
        _setup2of3Quorum();

        // Message IDs 20-28 go to investmentManager
        bytes memory message = abi.encodePacked(uint8(20), uint64(1));

        vm.prank(address(adapterAxelar));
        spokeMultiAdapter.handle(HUB_CHAIN, message);
        vm.prank(address(adapterLZ));
        spokeMultiAdapter.handle(HUB_CHAIN, message);

        assertEq(spokeInvestmentManager.handleCount(), 1);
    }

    // --- Full round-trip (outgoing + simulated incoming) ---

    function test_fullRoundTrip() public {
        _setup2of3Quorum();

        // 1. Spoke sends outgoing message to hub
        bytes memory outMessage = abi.encodePacked(uint8(20), uint64(1));
        vm.prank(address(spokeInvestmentManager));
        spokeGateway.send(outMessage, address(this));
        assertEq(adapterAxelar.sendCount(), 1);
        assertEq(adapterLZ.sendCount(), 1);
        assertEq(adapterWH.sendCount(), 1);

        // 2. Hub processes and sends response back (simulated as incoming on spoke)
        bytes memory inMessage = abi.encodePacked(uint8(10), uint64(1));

        // Two adapters confirm the incoming message
        vm.prank(address(adapterAxelar));
        spokeMultiAdapter.handle(HUB_CHAIN, inMessage);
        vm.prank(address(adapterWH));
        spokeMultiAdapter.handle(HUB_CHAIN, inMessage);

        // Message dispatched to spokeHandler
        assertEq(spokeSpokeHandler.handleCount(), 1);
    }

    // --- Helpers ---

    function _setup3of3Quorum() internal {
        address[] memory adapters = new address[](3);
        adapters[0] = address(adapterAxelar);
        adapters[1] = address(adapterLZ);
        adapters[2] = address(adapterWH);
        spokeMultiAdapter.setAdapters(HUB_CHAIN, adapters, 3, 0);
    }

    function _setup2of3Quorum() internal {
        address[] memory adapters = new address[](3);
        adapters[0] = address(adapterAxelar);
        adapters[1] = address(adapterLZ);
        adapters[2] = address(adapterWH);
        spokeMultiAdapter.setAdapters(HUB_CHAIN, adapters, 2, 0);
    }

    function _setup2of3WithRecovery() internal {
        address[] memory adapters = new address[](3);
        adapters[0] = address(adapterAxelar);
        adapters[1] = address(adapterLZ);
        adapters[2] = address(recoveryAdapter);
        spokeMultiAdapter.setAdapters(HUB_CHAIN, adapters, 2, 3); // recovery at index 3 (1-based)
    }

    receive() external payable {}
}
