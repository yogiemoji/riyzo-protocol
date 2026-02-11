// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.28;

import {Root} from "src/admin/Root.sol";
import {IGuardian} from "src/interfaces/IGuardian.sol";

interface ISafe {
    function isOwner(address signer) external view returns (bool);
}

contract Guardian is IGuardian {
    Root public immutable root;
    ISafe public immutable safe;

    constructor(address safe_, address root_) {
        root = Root(root_);
        safe = ISafe(safe_);
    }

    modifier onlySafe() {
        _onlySafe();
        _;
    }

    function _onlySafe() internal view {
        require(msg.sender == address(safe), "Guardian/not-the-authorized-safe");
    }

    modifier onlySafeOrOwner() {
        _onlySafeOrOwner();
        _;
    }

    function _onlySafeOrOwner() internal view {
        require(
            msg.sender == address(safe) || _isSafeOwner(msg.sender), "Guardian/not-the-authorized-safe-or-its-owner"
        );
    }

    // --- Admin actions ---
    /// @inheritdoc IGuardian
    function pause() external onlySafeOrOwner {
        root.pause();
    }

    /// @inheritdoc IGuardian
    function unpause() external onlySafe {
        root.unpause();
    }

    /// @inheritdoc IGuardian
    function scheduleRely(address target) external onlySafe {
        root.scheduleRely(target);
    }

    /// @inheritdoc IGuardian
    function cancelRely(address target) external onlySafe {
        root.cancelRely(target);
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
