// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.28;

import {Root} from "src/admin/Root.sol";
import {IProtocolGuardian} from "src/interfaces/IProtocolGuardian.sol";

interface ISafe {
    function isOwner(address signer) external view returns (bool);
}

contract ProtocolGuardian is IProtocolGuardian {
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
        require(msg.sender == address(safe), "ProtocolGuardian/not-the-authorized-safe");
    }

    modifier onlySafeOrOwner() {
        _onlySafeOrOwner();
        _;
    }

    function _onlySafeOrOwner() internal view {
        require(
            msg.sender == address(safe) || _isSafeOwner(msg.sender),
            "ProtocolGuardian/not-the-authorized-safe-or-its-owner"
        );
    }

    // --- Admin actions ---
    /// @inheritdoc IProtocolGuardian
    function pause() external onlySafeOrOwner {
        root.pause();
    }

    /// @inheritdoc IProtocolGuardian
    function unpause() external onlySafe {
        root.unpause();
    }

    /// @inheritdoc IProtocolGuardian
    function scheduleRely(address target) external onlySafe {
        root.scheduleRely(target);
    }

    /// @inheritdoc IProtocolGuardian
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
