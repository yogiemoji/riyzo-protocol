// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.28;

import {IAdapter} from "src/interfaces/gateway/IAdapter.sol";

/// @title MockAdapter - Simple adapter mock for testing MultiAdapter
contract MockAdapter is IAdapter {
    uint256 public estimateCost = 0.01 ether;
    uint256 public sendCount;
    bytes public lastPayload;
    uint16 public lastChainId;
    uint256 public lastGasLimit;
    uint256 public lastValue;

    function send(uint16 chainId, bytes calldata payload, uint256 gasLimit, address) external payable {
        sendCount++;
        lastChainId = chainId;
        lastPayload = payload;
        lastGasLimit = gasLimit;
        lastValue = msg.value;
    }

    function estimate(uint16, bytes calldata, uint256) external view returns (uint256) {
        return estimateCost;
    }

    function wire(uint16, bytes calldata) external {}

    function isWired(uint16) external pure returns (bool) {
        return true;
    }

    // --- Test helpers ---
    function setEstimateCost(uint256 cost) external {
        estimateCost = cost;
    }
}
