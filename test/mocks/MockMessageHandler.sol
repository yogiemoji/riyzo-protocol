// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.28;

import {IMessageHandler} from "src/interfaces/gateway/IGateway.sol";

/// @title MockMessageHandler - Mock for testing Gateway dispatch
contract MockMessageHandler is IMessageHandler {
    uint256 public handleCount;
    bytes public lastMessage;
    bytes[] public allMessages;

    function handle(bytes memory message) external {
        handleCount++;
        lastMessage = message;
        allMessages.push(message);
    }

    function getMessage(uint256 index) external view returns (bytes memory) {
        return allMessages[index];
    }
}
