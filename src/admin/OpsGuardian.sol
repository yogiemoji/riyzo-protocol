// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.28;

import {Root} from "src/admin/Root.sol";
import {NAVGuard} from "src/core/hub/NAVGuard.sol";
import {IOpsGuardian} from "src/interfaces/IOpsGuardian.sol";

interface ISafe {
    function isOwner(address signer) external view returns (bool);
}

/// @title  OpsGuardian
/// @notice Thin Safe wrapper around NAVGuard for pool-level operational controls.
///         Separates day-to-day pool operations from protocol-wide governance.
contract OpsGuardian is IOpsGuardian {
    Root public immutable root;
    NAVGuard public immutable navGuard;
    ISafe public immutable safe;

    constructor(address safe_, address root_, address navGuard_) {
        safe = ISafe(safe_);
        root = Root(root_);
        navGuard = NAVGuard(navGuard_);
    }

    modifier onlySafe() {
        require(msg.sender == address(safe), "OpsGuardian/not-the-authorized-safe");
        _;
    }

    modifier onlySafeOrOwner() {
        require(
            msg.sender == address(safe) || _isSafeOwner(msg.sender), "OpsGuardian/not-the-authorized-safe-or-its-owner"
        );
        _;
    }

    // --- Pool operations ---
    /// @inheritdoc IOpsGuardian
    function pausePool(uint64 poolId) external onlySafeOrOwner {
        navGuard.pause(poolId);
    }

    /// @inheritdoc IOpsGuardian
    function unpausePool(uint64 poolId) external onlySafe {
        navGuard.unpause(poolId);
    }

    /// @inheritdoc IOpsGuardian
    function configureGuard(uint64 poolId, uint16 maxPriceChangeBps, uint64 maxStalenessSeconds, bool enforceLimits)
        external
        onlySafe
    {
        navGuard.configureGuard(poolId, maxPriceChangeBps, maxStalenessSeconds, enforceLimits);
    }

    /// @inheritdoc IOpsGuardian
    function recoverTokens(address target, address token, address to, uint256 amount) external onlySafe {
        root.recoverTokens(target, token, to, amount);
    }

    // --- Helpers ---
    function _isSafeOwner(address addr) internal view returns (bool) {
        try safe.isOwner(addr) returns (bool isOwner) {
            return isOwner;
        } catch {
            return false;
        }
    }
}
