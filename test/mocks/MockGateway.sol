// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.28;

/// @title MockGateway - Gateway mock for testing spoke contracts
contract MockGateway {
    // Track sent messages for verification
    bytes[] public sentMessages;
    address[] public sentSources;

    event MessageSent(bytes message, address source);

    function send(bytes calldata message, address source) external payable {
        sentMessages.push(message);
        sentSources.push(source);
        emit MessageSent(message, source);
    }

    function getSentMessageCount() external view returns (uint256) {
        return sentMessages.length;
    }

    function getLastMessage() external view returns (bytes memory) {
        require(sentMessages.length > 0, "No messages sent");
        return sentMessages[sentMessages.length - 1];
    }

    function getLastSource() external view returns (address) {
        require(sentSources.length > 0, "No messages sent");
        return sentSources[sentSources.length - 1];
    }

    function clearMessages() external {
        delete sentMessages;
        delete sentSources;
    }
}
