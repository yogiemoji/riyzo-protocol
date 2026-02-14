// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.28;

import {BaseTransferHook} from "src/hooks/BaseTransferHook.sol";
import {HookData} from "src/interfaces/token/IHook.sol";

/// @title  FreezeOnly
/// @notice Minimal compliance hook: only enforces freeze checks, no memberlist required.
///         Suitable for permissionless tokens that still need emergency freeze capability.
contract FreezeOnly is BaseTransferHook {
    constructor(address root_, address escrow_, address deployer) BaseTransferHook(root_, escrow_, deployer) {}

    /// @inheritdoc BaseTransferHook
    function checkERC20Transfer(address from, address to, uint256, HookData calldata hookData)
        public
        view
        override
        returns (bool)
    {
        if (_isSourceFrozen(from, hookData)) return false;
        if (_isTargetFrozen(hookData)) return false;
        return true;
    }
}
