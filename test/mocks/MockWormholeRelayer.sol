// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.28;

import {IWormholeRelayer} from "src/interfaces/gateway/adapters/IWormholeAdapter.sol";

/// @title MockWormholeRelayer - Wormhole relayer mock for testing
contract MockWormholeRelayer is IWormholeRelayer {
    uint256 public deliveryPrice = 0.01 ether;
    uint256 public sendCount;
    uint16 public lastTargetChain;
    address public lastTargetAddress;
    bytes public lastPayload;
    uint256 public lastGasLimit;

    function sendPayloadToEvm(
        uint16 targetChain,
        address targetAddress,
        bytes memory payload,
        uint256,
        uint256 gasLimit,
        uint16,
        address
    ) external payable returns (uint64 sequence) {
        sendCount++;
        lastTargetChain = targetChain;
        lastTargetAddress = targetAddress;
        lastPayload = payload;
        lastGasLimit = gasLimit;
        return uint64(sendCount);
    }

    function quoteEVMDeliveryPrice(uint16, uint256, uint256)
        external
        view
        returns (uint256 nativePriceQuote, uint256 targetChainRefundPerGasUnused)
    {
        return (deliveryPrice, 0);
    }

    // --- Test helpers ---
    function setDeliveryPrice(uint256 price) external {
        deliveryPrice = price;
    }
}
