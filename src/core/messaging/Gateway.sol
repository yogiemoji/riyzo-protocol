// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.28;

import {Auth} from "src/core/Auth.sol";
import {BytesLib} from "src/core/libraries/BytesLib.sol";
import {MessagesLib} from "src/core/libraries/MessagesLib.sol";
import {SafeTransferLib} from "src/core/libraries/SafeTransferLib.sol";
import {TransientStorage} from "src/core/libraries/TransientStorage.sol";
import {IGateway, IMessageHandler} from "src/interfaces/gateway/IGateway.sol";
import {IRoot} from "src/interfaces/IRoot.sol";
import {IGasService} from "src/interfaces/gateway/IGasService.sol";
import {IMultiAdapter} from "src/interfaces/gateway/IMultiAdapter.sol";
import {IRecoverable} from "src/interfaces/IRoot.sol";

/// @title  Gateway
/// @notice Message routing contract that dispatches incoming cross-chain messages to the
///         appropriate handler (PoolManager, InvestmentManager, SpokeHandler, Root, GasService)
///         and forwards outgoing messages through MultiAdapter for cross-chain delivery.
///         Quorum voting and adapter management are handled by MultiAdapter.
contract Gateway is Auth, IGateway, IRecoverable {
    using BytesLib for bytes;
    using TransientStorage for bytes32;

    bytes32 public constant QUOTA_SLOT = bytes32(uint256(keccak256("Riyzo/quota")) - 1);

    IRoot public immutable root;

    address public poolManager;
    address public investmentManager;

    /// @inheritdoc IGateway
    address public spokeHandler;

    IGasService public gasService;

    /// @inheritdoc IGateway
    address public multiAdapter;

    /// @inheritdoc IGateway
    uint16 public hubChainId;

    /// @inheritdoc IGateway
    uint256 public defaultGasLimit = 300_000;

    /// @inheritdoc IGateway
    mapping(address payer => bool) public payers;

    /// @inheritdoc IGateway
    mapping(uint8 messageId => address) public messageHandlers;

    constructor(address root_) Auth(msg.sender) {
        root = IRoot(root_);
    }

    modifier pauseable() {
        require(!root.paused(), "Gateway/paused");
        _;
    }

    receive() external payable {
        emit ReceiveNativeTokens(msg.sender, msg.value);
    }

    // --- Administration ---

    /// @inheritdoc IGateway
    function file(bytes32 what, address instance) external auth {
        if (what == "gasService") gasService = IGasService(instance);
        else if (what == "investmentManager") investmentManager = instance;
        else if (what == "poolManager") poolManager = instance;
        else if (what == "multiAdapter") multiAdapter = instance;
        else if (what == "spokeHandler") spokeHandler = instance;
        else revert("Gateway/file-unrecognized-param");

        emit File(what, instance);
    }

    /// @inheritdoc IGateway
    function file(bytes32 what, uint8 data1, address data2) public auth {
        if (what == "message") {
            require(data1 > uint8(type(MessagesLib.Call).max), "Gateway/hardcoded-message-id");
            messageHandlers[data1] = data2;
        } else {
            revert("Gateway/file-unrecognized-param");
        }
        emit File(what, data1, data2);
    }

    /// @inheritdoc IGateway
    function file(bytes32 what, address payer, bool isAllowed) external auth {
        if (what == "payers") payers[payer] = isAllowed;
        else revert("Gateway/file-unrecognized-param");

        emit File(what, payer, isAllowed);
    }

    /// @inheritdoc IGateway
    function file(bytes32 what, uint256 value) external auth {
        if (what == "hubChainId") hubChainId = uint16(value);
        else if (what == "defaultGasLimit") defaultGasLimit = value;
        else revert("Gateway/file-unrecognized-param");

        emit File(what, value);
    }

    /// @inheritdoc IRecoverable
    function recoverTokens(address token, address receiver, uint256 amount) external auth {
        if (token == address(0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE)) {
            SafeTransferLib.safeTransferETH(receiver, amount);
        } else {
            SafeTransferLib.safeTransfer(token, receiver, amount);
        }
    }

    // --- Incoming ---

    /// @inheritdoc IGateway
    function handle(bytes calldata message) external pauseable {
        require(msg.sender == multiAdapter, "Gateway/not-multi-adapter");
        _dispatch(message, false);
        emit ExecuteMessage(message);
    }

    function _dispatch(bytes memory message, bool isBatched) internal {
        uint8 id = message.toUint8(0);
        address manager;

        if (id == 4) {
            // Handle batch messages
            require(!isBatched, "Gateway/no-recursive-batching-allowed");
            uint256 offset = 1;
            uint256 messageLength = message.length;

            while (offset + 2 <= messageLength) {
                uint16 subMessageLength = message.toUint16(offset);
                bytes memory subMessage = new bytes(subMessageLength);
                offset = offset + 2;

                require(offset + subMessageLength <= messageLength, "Gateway/corrupted-message");
                for (uint256 i; i < subMessageLength; i++) {
                    subMessage[i] = message[offset + i];
                }
                _dispatch(subMessage, true);

                offset += subMessageLength;
            }
            return;
        } else if (id >= 5 && id <= 7) {
            manager = address(root);
        } else if (id == 8) {
            manager = address(gasService);
        } else if (id >= 9 && id <= 19) {
            // On spoke chains, route to spokeHandler; fall back to poolManager on hub
            manager = spokeHandler != address(0) ? spokeHandler : poolManager;
        } else if (id >= 20 && id <= 28) {
            manager = investmentManager;
        } else {
            manager = messageHandlers[id];
            require(manager != address(0), "Gateway/unregistered-message-id");
        }

        IMessageHandler(manager).handle(message);
    }

    // --- Outgoing ---

    /// @inheritdoc IGateway
    function send(bytes calldata message, address source) public payable pauseable {
        bool isManager = msg.sender == investmentManager || msg.sender == poolManager;
        require(isManager || msg.sender == messageHandlers[message.toUint8(0)], "Gateway/invalid-manager");

        require(multiAdapter != address(0), "Gateway/not-initialized");

        uint256 fuel = QUOTA_SLOT.tloadUint256();

        if (fuel != 0) {
            IMultiAdapter(multiAdapter).send{value: fuel}(hubChainId, message, defaultGasLimit, address(this));
            QUOTA_SLOT.tstore(0);
        } else if (gasService.shouldRefuel(source, message)) {
            uint256 cost = IMultiAdapter(multiAdapter).estimate(hubChainId, message, defaultGasLimit);
            uint256 payment = cost <= address(this).balance ? cost : address(this).balance;
            IMultiAdapter(multiAdapter).send{value: payment}(hubChainId, message, defaultGasLimit, address(this));
        } else {
            revert("Gateway/not-enough-gas-funds");
        }

        emit SendMessage(message);
    }

    /// @inheritdoc IGateway
    function topUp() external payable {
        require(payers[msg.sender], "Gateway/only-payers-can-top-up");
        require(msg.value != 0, "Gateway/cannot-topup-with-nothing");
        QUOTA_SLOT.tstore(msg.value);
    }

    // --- Helpers ---

    /// @inheritdoc IGateway
    function estimate(bytes calldata payload) external view returns (uint256 total) {
        return IMultiAdapter(multiAdapter).estimate(hubChainId, payload, defaultGasLimit);
    }
}
