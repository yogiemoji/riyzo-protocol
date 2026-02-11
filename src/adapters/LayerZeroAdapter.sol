// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.28;

import {Auth} from "src/core/Auth.sol";
import {IAdapter} from "src/interfaces/gateway/IAdapter.sol";
import {
    ILayerZeroAdapter,
    ILayerZeroEndpointV2,
    ILayerZeroReceiver,
    Origin,
    MessagingParams,
    MessagingFee
} from "src/interfaces/gateway/adapters/ILayerZeroAdapter.sol";
import {IMultiAdapter} from "src/interfaces/gateway/IMultiAdapter.sol";

/// @title  LayerZeroAdapter
/// @notice Cross-chain adapter integrating with LayerZero V2 for multi-chain routing.
///         Translates between Riyzo chain IDs and LayerZero endpoint IDs (EIDs).
///         Chain mappings: Arbitrum=30110, Ethereum=30101, Base=30184
contract LayerZeroAdapter is Auth, ILayerZeroAdapter {
    struct LZSource {
        uint16 chainId; // Riyzo chain ID
        bytes32 adapter; // Remote adapter address as bytes32 (left-padded)
    }

    struct LZDestination {
        uint32 lzEid; // LayerZero endpoint ID
        bytes32 adapter; // Remote adapter address as bytes32 (left-padded)
    }

    IMultiAdapter public immutable entrypoint;

    /// @inheritdoc ILayerZeroAdapter
    ILayerZeroEndpointV2 public immutable endpoint;

    /// @dev Source lookup: LZ EID => source config
    mapping(uint32 lzEid => LZSource) public sources;

    /// @dev Destination lookup: Riyzo chain ID => destination config
    mapping(uint16 chainId => LZDestination) public destinations;

    constructor(address entrypoint_, address endpoint_) Auth(msg.sender) {
        entrypoint = IMultiAdapter(entrypoint_);
        endpoint = ILayerZeroEndpointV2(endpoint_);
        ILayerZeroEndpointV2(endpoint_).setDelegate(address(this));
    }

    // --- Configuration ---

    /// @inheritdoc IAdapter
    function wire(uint16 chainId, bytes calldata data) external auth {
        (uint32 lzEid, address adapter) = abi.decode(data, (uint32, address));
        bytes32 adapterBytes32 = bytes32(uint256(uint160(adapter)));

        sources[lzEid] = LZSource({chainId: chainId, adapter: adapterBytes32});
        destinations[chainId] = LZDestination({lzEid: lzEid, adapter: adapterBytes32});
    }

    /// @inheritdoc IAdapter
    function isWired(uint16 chainId) external view returns (bool) {
        return destinations[chainId].lzEid != 0;
    }

    // --- Incoming ---

    /// @inheritdoc ILayerZeroReceiver
    function lzReceive(
        Origin calldata origin,
        bytes32,
        bytes calldata message,
        address,
        bytes calldata /* extraData */
    )
        external
        payable
    {
        require(msg.sender == address(endpoint), "LayerZeroAdapter/not-endpoint");

        LZSource memory source = sources[origin.srcEid];
        require(source.chainId != 0, "LayerZeroAdapter/unknown-source");
        require(origin.sender == source.adapter, "LayerZeroAdapter/invalid-sender");

        entrypoint.handle(source.chainId, message);
    }

    // --- Outgoing ---

    /// @inheritdoc IAdapter
    function send(uint16 chainId, bytes calldata payload, uint256 gasLimit, address refund) external payable {
        require(msg.sender == address(entrypoint), "LayerZeroAdapter/not-entrypoint");

        LZDestination memory dest = destinations[chainId];
        require(dest.lzEid != 0, "LayerZeroAdapter/not-wired");

        MessagingParams memory params = MessagingParams({
            dstEid: dest.lzEid,
            receiver: dest.adapter,
            message: payload,
            options: _buildOptions(gasLimit),
            payInLzToken: false
        });

        endpoint.send{value: msg.value}(params, refund);
    }

    /// @inheritdoc IAdapter
    function estimate(uint16 chainId, bytes calldata payload, uint256 gasLimit) external view returns (uint256) {
        LZDestination memory dest = destinations[chainId];
        require(dest.lzEid != 0, "LayerZeroAdapter/not-wired");

        MessagingParams memory params = MessagingParams({
            dstEid: dest.lzEid,
            receiver: dest.adapter,
            message: payload,
            options: _buildOptions(gasLimit),
            payInLzToken: false
        });

        MessagingFee memory fee = endpoint.quote(params, address(this));
        return fee.nativeFee;
    }

    // --- Internal ---

    /// @dev Build LayerZero V2 executor options for lzReceive gas limit.
    ///      Format: TYPE_3 header + executor worker options
    function _buildOptions(uint256 gasLimit) internal pure returns (bytes memory) {
        return abi.encodePacked(
            uint16(3), // TYPE_3 options
            uint8(1), // WORKER_ID (executor)
            uint16(17), // Option size: 1 (type byte) + 16 (gas uint128)
            uint8(1), // OPTION_TYPE_LZRECEIVE
            uint128(gasLimit) // Gas limit for lzReceive execution
        );
    }
}
