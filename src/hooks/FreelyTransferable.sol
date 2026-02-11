// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.28;

import {BaseTransferHook} from "src/hooks/BaseTransferHook.sol";
import {HookData} from "src/interfaces/token/IHook.sol";

/// @title  FreelyTransferable
/// @notice Relaxed compliance hook: peer-to-peer transfers are unrestricted,
///         but protocol entry/exit points (deposit claim, redeem request) require
///         membership. Freeze still blocks all transfers.
contract FreelyTransferable is BaseTransferHook {
    constructor(address root_, address escrow_, address deployer) BaseTransferHook(root_, escrow_, deployer) {}

    /// @inheritdoc BaseTransferHook
    function checkERC20Transfer(address from, address to, uint256, HookData calldata hookData)
        public
        view
        override
        returns (bool)
    {
        // Frozen source/target always blocked
        if (_isSourceFrozen(from, hookData)) return false;
        if (_isTargetFrozen(hookData)) return false;

        // Minting to non-escrow (deposit claim by user) — target must be member
        if (_isMinting(from) && to != escrow) return _isTargetMember(hookData);

        // Transfer to escrow (redeem request) — source must be member
        if (to == escrow && !_isMinting(from)) {
            // Check source membership via hookData.from upper 64 bits
            return uint128(hookData.from) >> 64 >= block.timestamp;
        }

        // Everything else (peer transfers, mint-to-escrow, burns) — allowed
        return true;
    }
}
