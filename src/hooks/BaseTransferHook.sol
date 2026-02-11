// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.28;

import {Auth} from "src/core/Auth.sol";
import {IRoot} from "src/interfaces/IRoot.sol";
import {ITranche} from "src/interfaces/token/ITranche.sol";
import {IHook, HookData} from "src/interfaces/token/IHook.sol";
import {BitmapLib} from "src/core/libraries/BitmapLib.sol";
import {BytesLib} from "src/core/libraries/BytesLib.sol";
import {IERC165} from "src/interfaces/IERC7575.sol";
import {RestrictionUpdate, IRestrictionManager} from "src/interfaces/token/IRestrictionManager.sol";

/// @title  BaseTransferHook
/// @notice Abstract base for transfer hooks with memberlist/freeze logic and
///         operation-type detection helpers. Subclasses override `checkERC20Transfer`
///         to implement different compliance policies.
/// @dev    HookData encoding: upper 64 bits = validUntil, LSB = frozen.
abstract contract BaseTransferHook is Auth, IRestrictionManager, IHook {
    using BitmapLib for *;
    using BytesLib for bytes;

    /// @dev Least significant bit used for freeze flag
    uint8 public constant FREEZE_BIT = 0;

    IRoot public immutable root;
    address public immutable escrow;

    constructor(address root_, address escrow_, address deployer) Auth(deployer) {
        root = IRoot(root_);
        escrow = escrow_;
    }

    // --- ERC20 transfer callbacks ---

    /// @inheritdoc IHook
    function onERC20Transfer(address from, address to, uint256 value, HookData calldata hookData)
        external
        virtual
        returns (bytes4)
    {
        require(checkERC20Transfer(from, to, value, hookData), "BaseTransferHook/transfer-blocked");
        return IHook.onERC20Transfer.selector;
    }

    /// @inheritdoc IHook
    function onERC20AuthTransfer(
        address, /* sender */
        address, /* from */
        address, /* to */
        uint256, /* value */
        HookData calldata /* hookData */
    ) external pure returns (bytes4) {
        return IHook.onERC20AuthTransfer.selector;
    }

    /// @inheritdoc IHook
    function checkERC20Transfer(address from, address to, uint256 value, HookData calldata hookData)
        public
        view
        virtual
        returns (bool);

    // --- Restriction updates ---

    /// @inheritdoc IHook
    function updateRestriction(address token, bytes memory update) external auth {
        RestrictionUpdate updateId = RestrictionUpdate(update.toUint8(0));

        if (updateId == RestrictionUpdate.UpdateMember) {
            updateMember(token, update.toAddress(1), update.toUint64(33));
        } else if (updateId == RestrictionUpdate.Freeze) {
            freeze(token, update.toAddress(1));
        } else if (updateId == RestrictionUpdate.Unfreeze) {
            unfreeze(token, update.toAddress(1));
        } else if (updateId == RestrictionUpdate.BatchUpdateMember) {
            _handleBatchUpdateMember(token, update);
        } else {
            revert("BaseTransferHook/invalid-update");
        }
    }

    function _handleBatchUpdateMember(address token, bytes memory update) internal {
        uint16 count = uint16(update.toUint8(1)) << 8 | uint16(update.toUint8(2));
        uint256 offset = 3;
        for (uint16 i = 0; i < count; i++) {
            address user = update.toAddress(offset);
            uint64 validUntil = update.toUint64(offset + 20);
            updateMember(token, user, validUntil);
            offset += 28;
        }
    }

    // --- Freeze management ---

    /// @inheritdoc IRestrictionManager
    function freeze(address token, address user) public auth {
        require(user != address(0), "BaseTransferHook/cannot-freeze-zero-address");
        require(!root.endorsed(user), "BaseTransferHook/endorsed-user-cannot-be-frozen");

        uint128 hookData = uint128(ITranche(token).hookDataOf(user));
        ITranche(token).setHookData(user, bytes16(hookData.setBit(FREEZE_BIT, true)));

        emit Freeze(token, user);
    }

    /// @inheritdoc IRestrictionManager
    function unfreeze(address token, address user) public auth {
        uint128 hookData = uint128(ITranche(token).hookDataOf(user));
        ITranche(token).setHookData(user, bytes16(hookData.setBit(FREEZE_BIT, false)));

        emit Unfreeze(token, user);
    }

    /// @inheritdoc IRestrictionManager
    function isFrozen(address token, address user) public view returns (bool) {
        return uint128(ITranche(token).hookDataOf(user)).getBit(FREEZE_BIT);
    }

    // --- Member management ---

    /// @inheritdoc IRestrictionManager
    function updateMember(address token, address user, uint64 validUntil) public auth {
        require(block.timestamp <= validUntil, "BaseTransferHook/invalid-valid-until");
        require(!root.endorsed(user), "BaseTransferHook/endorsed-user-cannot-be-updated");

        uint128 hookData = uint128(validUntil) << 64;
        hookData.setBit(FREEZE_BIT, isFrozen(token, user));
        ITranche(token).setHookData(user, bytes16(hookData));

        emit UpdateMember(token, user, validUntil);
    }

    /// @inheritdoc IRestrictionManager
    function batchUpdateMember(address token, address[] calldata users, uint64[] calldata validUntils) external auth {
        require(users.length == validUntils.length, "BaseTransferHook/array-length-mismatch");
        for (uint256 i = 0; i < users.length; i++) {
            updateMember(token, users[i], validUntils[i]);
        }
    }

    /// @inheritdoc IRestrictionManager
    function isMember(address token, address user) external view returns (bool isValid, uint64 validUntil) {
        validUntil = abi.encodePacked(ITranche(token).hookDataOf(user)).toUint64(0);
        isValid = validUntil >= block.timestamp;
    }

    // --- Operation detection helpers ---

    function _isSourceFrozen(address from, HookData calldata hookData) internal view returns (bool) {
        return uint128(hookData.from).getBit(FREEZE_BIT) && !root.endorsed(from);
    }

    function _isTargetFrozen(HookData calldata hookData) internal pure returns (bool) {
        return uint128(hookData.to).getBit(FREEZE_BIT);
    }

    function _isTargetMember(HookData calldata hookData) internal view returns (bool) {
        return uint128(hookData.to) >> 64 >= block.timestamp;
    }

    function _isMinting(address from) internal pure returns (bool) {
        return from == address(0);
    }

    function _isBurning(address to) internal pure returns (bool) {
        return to == address(0);
    }

    function _isEscrowTransfer(address from, address to) internal view returns (bool) {
        return from == escrow || to == escrow;
    }

    // --- ERC165 ---

    /// @inheritdoc IERC165
    function supportsInterface(bytes4 interfaceId) external pure override returns (bool) {
        return interfaceId == type(IHook).interfaceId || interfaceId == type(IERC165).interfaceId;
    }
}
