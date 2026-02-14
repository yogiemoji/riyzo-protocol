// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.28;

import {BaseTransferHook} from "src/hooks/BaseTransferHook.sol";
import {HookData} from "src/interfaces/token/IHook.sol";

/// @title  FullRestrictions
/// @notice Strictest compliance hook: all transfers require target membership,
///         frozen accounts are blocked, mints to escrow and burns are always allowed.
contract FullRestrictions is BaseTransferHook {
    constructor(address root_, address escrow_, address deployer) BaseTransferHook(root_, escrow_, deployer) {}

    /// @inheritdoc BaseTransferHook
    function checkERC20Transfer(address from, address to, uint256, HookData calldata hookData)
        public
        view
        override
        returns (bool)
    {
        // Frozen source (unless endorsed) always blocked
        if (_isSourceFrozen(from, hookData)) return false;

        // Frozen target always blocked
        if (_isTargetFrozen(hookData)) return false;

        // Mint to escrow (deposit fulfillment) — always allowed
        if (_isMinting(from) && to == escrow) return true;

        // Burn (redeem execution) — always allowed
        if (_isBurning(to)) return true;

        // Endorsed target bypasses membership
        if (root.endorsed(to)) return true;

        // All other transfers require target membership
        return _isTargetMember(hookData);
    }
}
