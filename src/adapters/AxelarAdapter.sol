// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.28;

import {Auth} from "src/core/Auth.sol";
import {IAdapter} from "src/interfaces/gateway/IAdapter.sol";
import {IAxelarAdapter, IAxelarGateway, IAxelarGasService} from "src/interfaces/gateway/adapters/IAxelarAdapter.sol";
import {IMultiAdapter} from "src/interfaces/gateway/IMultiAdapter.sol";

/// @title  AxelarAdapter
/// @notice Cross-chain adapter integrating with Axelar Network for multi-chain routing.
///         Translates between Riyzo chain IDs and Axelar chain names.
contract AxelarAdapter is Auth, IAxelarAdapter {
    struct AxelarSource {
        uint16 chainId; // Riyzo chain ID
        bytes32 addressHash; // keccak256 of the source adapter address string
    }

    struct AxelarDestination {
        string chainName; // Axelar chain name (e.g., "ethereum", "base")
        string adapterAddress; // Target adapter address as hex string
    }

    IMultiAdapter public immutable entrypoint;
    IAxelarGateway public immutable axelarGateway;
    IAxelarGasService public immutable axelarGasService;

    /// @inheritdoc IAxelarAdapter
    uint256 public axelarCost = 58_039_058_122_843;

    /// @dev Source chain lookup: Axelar chain name hash => source config
    mapping(bytes32 nameHash => AxelarSource) public sources;

    /// @dev Destination chain lookup: Riyzo chain ID => destination config
    mapping(uint16 chainId => AxelarDestination) internal _destinations;

    constructor(address entrypoint_, address axelarGateway_, address axelarGasService_) Auth(msg.sender) {
        entrypoint = IMultiAdapter(entrypoint_);
        axelarGateway = IAxelarGateway(axelarGateway_);
        axelarGasService = IAxelarGasService(axelarGasService_);
    }

    // --- Administration ---

    /// @inheritdoc IAxelarAdapter
    function file(bytes32 what, uint256 value) external auth {
        if (what == "axelarCost") axelarCost = value;
        else revert("AxelarAdapter/file-unrecognized-param");
        emit File(what, value);
    }

    /// @inheritdoc IAdapter
    function wire(uint16 chainId, bytes calldata data) external auth {
        (string memory chainName, string memory adapterAddress) = abi.decode(data, (string, string));

        // Set source mapping (incoming: Axelar name hash -> riyzo chain ID + address hash)
        sources[keccak256(bytes(chainName))] =
            AxelarSource({chainId: chainId, addressHash: keccak256(bytes(adapterAddress))});

        // Set destination mapping (outgoing: riyzo chain ID -> Axelar chain name + address)
        _destinations[chainId] = AxelarDestination({chainName: chainName, adapterAddress: adapterAddress});
    }

    /// @inheritdoc IAdapter
    function isWired(uint16 chainId) external view returns (bool) {
        return bytes(_destinations[chainId].chainName).length > 0;
    }

    // --- Incoming ---

    /// @inheritdoc IAxelarAdapter
    function execute(
        bytes32 commandId,
        string calldata sourceChain,
        string calldata sourceAddress,
        bytes calldata payload
    ) external {
        AxelarSource memory source = sources[keccak256(bytes(sourceChain))];
        require(source.chainId != 0, "AxelarAdapter/unknown-source-chain");
        require(keccak256(bytes(sourceAddress)) == source.addressHash, "AxelarAdapter/invalid-source-address");
        require(
            axelarGateway.validateContractCall(commandId, sourceChain, sourceAddress, keccak256(payload)),
            "AxelarAdapter/not-approved-by-axelar-gateway"
        );

        entrypoint.handle(source.chainId, payload);
    }

    // --- Outgoing ---

    /// @inheritdoc IAdapter
    function send(
        uint16 chainId,
        bytes calldata payload,
        uint256,
        /* gasLimit */
        address refund
    )
        external
        payable
    {
        require(msg.sender == address(entrypoint), "AxelarAdapter/not-entrypoint");

        AxelarDestination storage dest = _destinations[chainId];
        require(bytes(dest.chainName).length > 0, "AxelarAdapter/not-wired");

        // Pay gas first if ETH was provided
        if (msg.value > 0) {
            axelarGasService.payNativeGasForContractCall{value: msg.value}(
                address(this), dest.chainName, dest.adapterAddress, payload, refund
            );
        }

        axelarGateway.callContract(dest.chainName, dest.adapterAddress, payload);
    }

    /// @inheritdoc IAdapter
    function estimate(
        uint16,
        /* chainId */
        bytes calldata,
        /* payload */
        uint256 /* gasLimit */
    )
        external
        view
        returns (uint256)
    {
        return axelarCost;
    }
}
