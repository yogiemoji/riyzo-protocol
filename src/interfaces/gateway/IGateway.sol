// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.28;

/// @title  IMessageHandler
/// @notice Interface for contracts that handle incoming cross-chain messages.
///         Implemented by Gateway, PoolManager, InvestmentManager, Root, GasService, SpokeHandler.
interface IMessageHandler {
    /// @notice Handle an incoming message
    /// @param  message Incoming message payload
    function handle(bytes memory message) external;
}

/// @title  IGateway
/// @notice Message routing contract that dispatches incoming messages to handlers
///         and forwards outgoing messages through MultiAdapter for cross-chain delivery.
interface IGateway {
    // --- Events ---
    event ExecuteMessage(bytes message);
    event SendMessage(bytes message);
    event File(bytes32 indexed what, address instance);
    event File(bytes32 indexed what, uint8 messageId, address manager);
    event File(bytes32 indexed what, address caller, bool isAllowed);
    event File(bytes32 indexed what, uint256 value);
    event ReceiveNativeTokens(address indexed sender, uint256 amount);

    // --- View ---
    /// @notice Returns the address of the contract that handles the given message id.
    function messageHandlers(uint8 messageId) external view returns (address);

    /// @notice Check if the address is allowed to top up gas.
    function payers(address caller) external view returns (bool isAllowed);

    /// @notice The MultiAdapter used for cross-chain message routing
    function multiAdapter() external view returns (address);

    /// @notice The SpokeHandler for spoke-chain message dispatch (address(0) on hub)
    function spokeHandler() external view returns (address);

    /// @notice Target chain ID for outgoing messages (hub chain ID on spokes)
    function hubChainId() external view returns (uint16);

    /// @notice Default gas limit for cross-chain message execution
    function defaultGasLimit() external view returns (uint256);

    // --- Administration ---
    /// @notice Update an address parameter.
    /// @param  what Accepts "gasService", "investmentManager", "poolManager",
    ///              "multiAdapter", "spokeHandler"
    /// @param  data New address
    function file(bytes32 what, address data) external;

    /// @notice Register a custom message handler for a message type ID.
    /// @param  what Accepts "message"
    /// @param  data1 The message type ID (must be > max hardcoded ID)
    /// @param  data2 The handler contract address
    function file(bytes32 what, uint8 data1, address data2) external;

    /// @notice Update payer allowlist.
    /// @param  what Accepts "payers"
    /// @param  caller Address of the payer
    /// @param  isAllowed Whether the caller is allowed to top up
    function file(bytes32 what, address caller, bool isAllowed) external;

    /// @notice Update a numeric parameter.
    /// @param  what Accepts "hubChainId", "defaultGasLimit"
    /// @param  value New value
    function file(bytes32 what, uint256 value) external;

    // --- Incoming ---
    /// @notice Handle an incoming message from the MultiAdapter.
    ///         Validates msg.sender is the MultiAdapter, then dispatches to the appropriate handler.
    /// @param  message Incoming cross-chain message
    function handle(bytes calldata message) external;

    // --- Outgoing ---
    /// @notice Send an outgoing message through the MultiAdapter to the hub chain.
    /// @param  message Message to send
    /// @param  source  Original transaction source (for gas refuel eligibility)
    function send(bytes calldata message, address source) external payable;

    /// @notice Prepay gas for cross-chain message delivery.
    ///         Must be called with msg.value. Only allowed payers can call.
    function topUp() external payable;

    // --- Helpers ---
    /// @notice Estimate the total cost for sending a message through all adapters.
    /// @param  payload Message to estimate for
    /// @return total   Total cost in native tokens (wei)
    function estimate(bytes calldata payload) external view returns (uint256 total);
}
