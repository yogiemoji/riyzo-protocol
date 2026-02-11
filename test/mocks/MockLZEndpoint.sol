// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.28;

import {
    ILayerZeroEndpointV2,
    MessagingParams,
    MessagingFee,
    MessagingReceipt
} from "src/interfaces/gateway/adapters/ILayerZeroAdapter.sol";

/// @title MockLZEndpoint - LayerZero V2 endpoint mock for testing
contract MockLZEndpoint is ILayerZeroEndpointV2 {
    uint256 public nativeFee = 0.01 ether;
    uint256 public sendCount;
    MessagingParams public lastParams;
    address public lastRefund;
    address public delegate;

    function send(MessagingParams calldata params, address refundAddress)
        external
        payable
        returns (MessagingReceipt memory)
    {
        sendCount++;
        lastParams = params;
        lastRefund = refundAddress;

        return MessagingReceipt({
            guid: keccak256(abi.encode(sendCount, params.dstEid)),
            nonce: uint64(sendCount),
            fee: MessagingFee({nativeFee: msg.value, lzTokenFee: 0})
        });
    }

    function quote(MessagingParams calldata, address) external view returns (MessagingFee memory) {
        return MessagingFee({nativeFee: nativeFee, lzTokenFee: 0});
    }

    function setDelegate(address delegate_) external {
        delegate = delegate_;
    }

    // --- Test helpers ---
    function setNativeFee(uint256 fee) external {
        nativeFee = fee;
    }
}
