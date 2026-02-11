// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.28;

import {IAxelarGateway, IAxelarGasService} from "src/interfaces/gateway/adapters/IAxelarAdapter.sol";

/// @title MockAxelarGateway - Axelar gateway mock for testing
contract MockAxelarGateway is IAxelarGateway {
    uint256 public callCount;
    string public lastDestChain;
    string public lastDestAddr;
    bytes public lastPayload;
    bool public validateResult = true;

    function callContract(string calldata destinationChain, string calldata contractAddress, bytes calldata payload)
        external
    {
        callCount++;
        lastDestChain = destinationChain;
        lastDestAddr = contractAddress;
        lastPayload = payload;
    }

    function validateContractCall(bytes32, string calldata, string calldata, bytes32) external view returns (bool) {
        return validateResult;
    }

    // --- Test helpers ---
    function setValidateResult(bool result) external {
        validateResult = result;
    }
}

/// @title MockAxelarGasService - Axelar gas service mock for testing
contract MockAxelarGasService is IAxelarGasService {
    uint256 public payCount;
    uint256 public lastValue;

    function payNativeGasForContractCall(address, string calldata, string calldata, bytes calldata, address)
        external
        payable
    {
        payCount++;
        lastValue = msg.value;
    }
}
