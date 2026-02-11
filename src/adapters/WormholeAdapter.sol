// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.28;

import {Auth} from "src/core/Auth.sol";
import {IAdapter} from "src/interfaces/gateway/IAdapter.sol";
import {
    IWormholeAdapter,
    IWormholeRelayer,
    IWormholeReceiver
} from "src/interfaces/gateway/adapters/IWormholeAdapter.sol";
import {IMultiAdapter} from "src/interfaces/gateway/IMultiAdapter.sol";

/// @title  WormholeAdapter
/// @notice Cross-chain adapter integrating with Wormhole automatic relayer for multi-chain routing.
///         Translates between Riyzo chain IDs and Wormhole chain IDs.
///         Chain mappings: Arbitrum=23, Ethereum=2, Base=30
contract WormholeAdapter is Auth, IWormholeAdapter {
    struct WHSource {
        uint16 chainId; // Riyzo chain ID
        address adapter; // Remote adapter address
    }

    struct WHDestination {
        uint16 wormholeId; // Wormhole chain ID
        address adapter; // Remote adapter address
    }

    IMultiAdapter public immutable entrypoint;

    /// @inheritdoc IWormholeAdapter
    IWormholeRelayer public immutable relayer;

    /// @dev Wormhole chain ID for this chain (used for refund routing)
    uint16 public immutable localWormholeId;

    /// @dev Source lookup: Wormhole chain ID => source config
    mapping(uint16 wormholeId => WHSource) public sources;

    /// @dev Destination lookup: Riyzo chain ID => destination config
    mapping(uint16 chainId => WHDestination) public destinations;

    constructor(address entrypoint_, address relayer_, uint16 localWormholeId_) Auth(msg.sender) {
        entrypoint = IMultiAdapter(entrypoint_);
        relayer = IWormholeRelayer(relayer_);
        localWormholeId = localWormholeId_;
    }

    // --- Configuration ---

    /// @inheritdoc IAdapter
    function wire(uint16 chainId, bytes calldata data) external auth {
        (uint16 wormholeId, address adapter) = abi.decode(data, (uint16, address));

        sources[wormholeId] = WHSource({chainId: chainId, adapter: adapter});
        destinations[chainId] = WHDestination({wormholeId: wormholeId, adapter: adapter});
    }

    /// @inheritdoc IAdapter
    function isWired(uint16 chainId) external view returns (bool) {
        return destinations[chainId].wormholeId != 0;
    }

    // --- Incoming ---

    /// @inheritdoc IWormholeReceiver
    function receiveWormholeMessages(
        bytes memory payload,
        bytes[] memory,
        bytes32 sourceAddress,
        uint16 sourceChain,
        bytes32 /* deliveryHash */
    ) external payable {
        require(msg.sender == address(relayer), "WormholeAdapter/not-relayer");

        WHSource memory source = sources[sourceChain];
        require(source.chainId != 0, "WormholeAdapter/unknown-source");

        // Wormhole left-pads addresses into bytes32
        address sourceAddr = address(uint160(uint256(sourceAddress)));
        require(sourceAddr == source.adapter, "WormholeAdapter/invalid-sender");

        entrypoint.handle(source.chainId, payload);
    }

    // --- Outgoing ---

    /// @inheritdoc IAdapter
    function send(uint16 chainId, bytes calldata payload, uint256 gasLimit, address refund) external payable {
        require(msg.sender == address(entrypoint), "WormholeAdapter/not-entrypoint");

        WHDestination memory dest = destinations[chainId];
        require(dest.wormholeId != 0, "WormholeAdapter/not-wired");

        relayer.sendPayloadToEvm{value: msg.value}(
            dest.wormholeId,
            dest.adapter,
            payload,
            0, // receiverValue: no native tokens sent to receiver
            gasLimit,
            localWormholeId,
            refund
        );
    }

    /// @inheritdoc IAdapter
    function estimate(
        uint16 chainId,
        bytes calldata,
        /* payload */
        uint256 gasLimit
    )
        external
        view
        returns (uint256)
    {
        WHDestination memory dest = destinations[chainId];
        require(dest.wormholeId != 0, "WormholeAdapter/not-wired");

        (uint256 cost,) = relayer.quoteEVMDeliveryPrice(dest.wormholeId, 0, gasLimit);
        return cost;
    }
}
