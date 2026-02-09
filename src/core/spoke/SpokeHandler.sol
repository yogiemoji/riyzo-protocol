// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.28;

import {Auth} from "src/core/Auth.sol";
import {ISpokeHandler} from "src/interfaces/spoke/ISpokeHandler.sol";
import {IRiyzoSpoke} from "src/interfaces/spoke/IRiyzoSpoke.sol";
import {IBalanceSheet} from "src/interfaces/spoke/IBalanceSheet.sol";
import {IPoolEscrow} from "src/interfaces/spoke/IPoolEscrow.sol";
import {IAsyncRequestManager} from "src/interfaces/spoke/IAsyncRequestManager.sol";
import {IInvestmentManager} from "src/interfaces/IInvestmentManager.sol";
import {IHook} from "src/interfaces/token/IHook.sol";
import {ITranche} from "src/interfaces/token/ITranche.sol";
import {MessagesLib} from "src/core/libraries/MessagesLib.sol";
import {BytesLib} from "src/core/libraries/BytesLib.sol";

/// @title SpokeHandler - Incoming Message Handler
/// @author Riyzo Protocol
/// @notice Processes incoming messages from the hub chain.
///         Routes messages to appropriate spoke components based on message type.
/// @dev SpokeHandler is the spoke-side counterpart to HubHandler.
///      It receives messages via Gateway and dispatches to:
///      - RiyzoSpoke (pool/tranche registration, price updates)
///      - BalanceSheet (share issuance/revocation)
///      - PoolEscrow (asset movements)
///      - AsyncRequestManager (request state updates)
///
/// MESSAGE TYPES HANDLED:
/// | Type                          | ID | Action                        |
/// |-------------------------------|-----|-------------------------------|
/// | AddPool                       | 10  | Register pool on spoke        |
/// | AddTranche                    | 11  | Register share class          |
/// | UpdateTranchePrice            | 14  | Update share class price      |
/// | UpdateRestriction              | 19  | Update transfer restrictions   |
/// | FulfilledDepositRequest       | 22  | Issue shares to user          |
/// | FulfilledRedeemRequest        | 23  | Release assets to user        |
/// | FulfilledCancelDepositRequest | 26  | Return deposit to user        |
/// | FulfilledCancelRedeemRequest  | 27  | Return shares to user         |
contract SpokeHandler is Auth, ISpokeHandler {
    using BytesLib for bytes;

    // ============================================================
    // STATE
    // ============================================================

    /// @notice Gateway contract address
    address public gateway;

    /// @notice RiyzoSpoke contract address
    address public spoke;

    /// @notice BalanceSheet contract address
    address public balanceSheet;

    /// @notice PoolEscrow contract address
    address public poolEscrow;

    /// @notice AsyncRequestManager contract address
    address public asyncRequestManager;

    /// @notice SpokeInvestmentManager contract address
    address public spokeInvestmentManager;

    /// @notice RestrictionManager contract address
    address public restrictionManager;

    // ============================================================
    // CONSTRUCTOR
    // ============================================================

    /// @param deployer Initial ward address
    constructor(address deployer) Auth(deployer) {}

    // ============================================================
    // CONFIGURATION
    // ============================================================

    /// @notice Set configuration values
    /// @param what Configuration key
    /// @param data Address value
    function file(bytes32 what, address data) external auth {
        if (what == "gateway") gateway = data;
        else if (what == "spoke") spoke = data;
        else if (what == "balanceSheet") balanceSheet = data;
        else if (what == "poolEscrow") poolEscrow = data;
        else if (what == "asyncRequestManager") asyncRequestManager = data;
        else if (what == "spokeInvestmentManager") spokeInvestmentManager = data;
        else if (what == "restrictionManager") restrictionManager = data;
        else revert("SpokeHandler/file-unrecognized-param");
    }

    // ============================================================
    // MESSAGE HANDLING
    // ============================================================

    /// @inheritdoc ISpokeHandler
    function handle(bytes calldata message) external auth {
        if (message.length == 0) revert MalformedMessage(message);

        uint8 messageType = uint8(message[0]);
        bytes32 messageHash = keccak256(message);

        bool success;

        if (messageType == uint8(MessagesLib.Call.AddPool)) {
            success = _handleAddPool(message);
            emit PoolAdded(_parsePoolId(message), address(0));
        } else if (messageType == uint8(MessagesLib.Call.AddTranche)) {
            success = _handleAddTranche(message);
        } else if (messageType == uint8(MessagesLib.Call.UpdateTranchePrice)) {
            success = _handleUpdatePrice(message);
        } else if (messageType == uint8(MessagesLib.Call.UpdateRestriction)) {
            success = _handleUpdateRestriction(message);
        } else if (messageType == uint8(MessagesLib.Call.FulfilledDepositRequest)) {
            success = _handleFulfilledDeposit(message);
        } else if (messageType == uint8(MessagesLib.Call.FulfilledRedeemRequest)) {
            success = _handleFulfilledRedeem(message);
        } else if (messageType == uint8(MessagesLib.Call.FulfilledCancelDepositRequest)) {
            success = _handleFulfilledCancelDeposit(message);
        } else if (messageType == uint8(MessagesLib.Call.FulfilledCancelRedeemRequest)) {
            success = _handleFulfilledCancelRedeem(message);
        } else {
            revert UnknownMessageType(messageType);
        }

        emit MessageHandled(messageHash, messageType, success);
    }

    // ============================================================
    // INTERNAL HANDLERS
    // ============================================================

    /// @dev Handle AddPool message
    /// Message format: [type(1), poolId(8), currency(16)]
    function _handleAddPool(bytes calldata message) internal returns (bool) {
        uint64 poolId = message.toUint64(1);
        // Currency is asset ID (16 bytes) but we need address on this chain
        // For now, assume currency mapping is handled separately
        address currency = _bytes16ToAddress(message.toBytes16(9));

        IRiyzoSpoke(spoke).registerPool(poolId, currency);
        emit PoolAdded(poolId, currency);
        return true;
    }

    /// @dev Handle AddTranche message
    /// Message format: [type(1), poolId(8), trancheId(16), name, symbol, decimals, hook]
    function _handleAddTranche(bytes calldata message) internal returns (bool) {
        uint64 poolId = message.toUint64(1);
        bytes16 scId = message.toBytes16(9);

        // Parse name and symbol from message
        // Simplified: use default names for now
        string memory name = "Share Token";
        string memory symbol = "ST";

        address shareToken = IRiyzoSpoke(spoke).registerShareClass(poolId, scId, name, symbol);
        emit TrancheAdded(poolId, scId, shareToken);
        return true;
    }

    /// @dev Handle UpdateTranchePrice message
    /// Message format: [type(1), poolId(8), trancheId(16), price(16), timestamp(8)]
    function _handleUpdatePrice(bytes calldata message) internal returns (bool) {
        uint64 poolId = message.toUint64(1);
        bytes16 scId = message.toBytes16(9);
        uint128 price = message.toUint128(25);
        uint64 timestamp = message.toUint64(41);

        IRiyzoSpoke(spoke).updatePrice(poolId, scId, price, timestamp);
        emit PriceUpdated(poolId, scId, price);
        return true;
    }

    /// @dev Handle UpdateRestriction message
    /// Message format: [type(1), poolId(8), trancheId(16), update(variable)]
    function _handleUpdateRestriction(bytes calldata message) internal returns (bool) {
        uint64 poolId = message.toUint64(1);
        bytes16 scId = message.toBytes16(9);

        IRiyzoSpoke.ShareClassState memory sc = IRiyzoSpoke(spoke).getShareClass(poolId, scId);
        require(sc.exists, "SpokeHandler/share-class-not-found");

        address shareToken = sc.shareToken;
        address hook = ITranche(shareToken).hook();
        require(hook != address(0), "SpokeHandler/no-hook-set");

        // Pass the restriction update payload (everything after type+poolId+trancheId)
        bytes memory update = message[25:];
        IHook(hook).updateRestriction(shareToken, update);

        emit RestrictionUpdated(poolId, scId, shareToken);
        return true;
    }

    /// @dev Handle FulfilledDepositRequest message
    /// Message format: [type(1), poolId(8), trancheId(16), user(32), assetId(16), assetAmount(16), shareAmount(16)]
    function _handleFulfilledDeposit(bytes calldata message) internal returns (bool) {
        uint64 poolId = message.toUint64(1);
        bytes16 scId = message.toBytes16(9);
        address user = _bytes32ToAddress(message.toBytes32(25));
        uint128 assetId = message.toUint128(57);
        uint128 assetAmount = message.toUint128(73);
        uint128 shareAmount = message.toUint128(89);

        if (spokeInvestmentManager != address(0)) {
            // Delegate to SpokeInvestmentManager for InvestmentState bookkeeping + vault callbacks
            IInvestmentManager(spokeInvestmentManager)
                .fulfillDepositRequest(poolId, scId, user, assetId, assetAmount, shareAmount);
        } else {
            // Legacy path: direct spoke component calls
            IBalanceSheet(balanceSheet).issueShares(poolId, scId, user, shareAmount);
            address currency = IRiyzoSpoke(spoke).getPool(poolId).currency;
            IPoolEscrow(poolEscrow).confirmDeposit(poolId, scId, currency, assetAmount);
            address vault = _getVaultForShareClass(poolId, scId, currency);
            if (vault != address(0) && asyncRequestManager != address(0)) {
                IAsyncRequestManager(asyncRequestManager).fulfillDeposit(vault, user, shareAmount);
            }
        }

        emit DepositFulfilled(poolId, scId, user, assetAmount, shareAmount);
        return true;
    }

    /// @dev Handle FulfilledRedeemRequest message
    /// Message format: [type(1), poolId(8), trancheId(16), user(32), assetId(16), assetAmount(16), shareAmount(16)]
    function _handleFulfilledRedeem(bytes calldata message) internal returns (bool) {
        uint64 poolId = message.toUint64(1);
        bytes16 scId = message.toBytes16(9);
        address user = _bytes32ToAddress(message.toBytes32(25));
        uint128 assetId = message.toUint128(57);
        uint128 assetAmount = message.toUint128(73);
        uint128 shareAmount = message.toUint128(89);

        if (spokeInvestmentManager != address(0)) {
            IInvestmentManager(spokeInvestmentManager)
                .fulfillRedeemRequest(poolId, scId, user, assetId, assetAmount, shareAmount);
        } else {
            IBalanceSheet(balanceSheet).revokeShares(poolId, scId, user, shareAmount);
            address currency = IRiyzoSpoke(spoke).getPool(poolId).currency;
            IPoolEscrow(poolEscrow).reserveForRedeem(poolId, scId, currency, assetAmount);
            IPoolEscrow(poolEscrow).releaseToUser(poolId, scId, currency, user, assetAmount);
            address vault = _getVaultForShareClass(poolId, scId, currency);
            if (vault != address(0) && asyncRequestManager != address(0)) {
                IAsyncRequestManager(asyncRequestManager).fulfillRedeem(vault, user, assetAmount);
            }
        }

        emit RedeemFulfilled(poolId, scId, user, shareAmount, assetAmount);
        return true;
    }

    /// @dev Handle FulfilledCancelDepositRequest message
    /// Message format: [type(1), poolId(8), trancheId(16), user(32), assetId(16), amount(16), fulfillment(16)]
    function _handleFulfilledCancelDeposit(bytes calldata message) internal returns (bool) {
        uint64 poolId = message.toUint64(1);
        bytes16 scId = message.toBytes16(9);
        address user = _bytes32ToAddress(message.toBytes32(25));
        uint128 assetId = message.toUint128(57);
        uint128 amount = message.toUint128(73);
        uint128 fulfillment = message.toUint128(89);

        if (spokeInvestmentManager != address(0)) {
            IInvestmentManager(spokeInvestmentManager)
                .fulfillCancelDepositRequest(poolId, scId, user, assetId, amount, fulfillment);
        } else {
            address currency = IRiyzoSpoke(spoke).getPool(poolId).currency;
            IPoolEscrow(poolEscrow).releaseDepositReservation(poolId, scId, currency, amount);
            address vault = _getVaultForShareClass(poolId, scId, currency);
            if (vault != address(0) && asyncRequestManager != address(0)) {
                IAsyncRequestManager(asyncRequestManager).cancelDepositRequest(vault, user);
            }
        }

        emit CancelDepositFulfilled(poolId, scId, user, amount);
        return true;
    }

    /// @dev Handle FulfilledCancelRedeemRequest message
    /// Message format: [type(1), poolId(8), trancheId(16), user(32), assetId(16), shares(16)]
    function _handleFulfilledCancelRedeem(bytes calldata message) internal returns (bool) {
        uint64 poolId = message.toUint64(1);
        bytes16 scId = message.toBytes16(9);
        address user = _bytes32ToAddress(message.toBytes32(25));
        uint128 assetId = message.toUint128(57);
        uint128 shares = message.toUint128(73);

        if (spokeInvestmentManager != address(0)) {
            IInvestmentManager(spokeInvestmentManager).fulfillCancelRedeemRequest(poolId, scId, user, assetId, shares);
        } else {
            address currency = IRiyzoSpoke(spoke).getPool(poolId).currency;
            address vault = _getVaultForShareClass(poolId, scId, currency);
            if (vault != address(0) && asyncRequestManager != address(0)) {
                IAsyncRequestManager(asyncRequestManager).cancelRedeemRequest(vault, user);
            }
        }

        emit CancelRedeemFulfilled(poolId, scId, user, shares);
        return true;
    }

    // ============================================================
    // VIEW FUNCTIONS
    // ============================================================

    /// @inheritdoc ISpokeHandler
    function supportsMessageType(uint8 messageType) external pure returns (bool) {
        return messageType == uint8(MessagesLib.Call.AddPool) || messageType == uint8(MessagesLib.Call.AddTranche)
            || messageType == uint8(MessagesLib.Call.UpdateTranchePrice)
            || messageType == uint8(MessagesLib.Call.UpdateRestriction)
            || messageType == uint8(MessagesLib.Call.FulfilledDepositRequest)
            || messageType == uint8(MessagesLib.Call.FulfilledRedeemRequest)
            || messageType == uint8(MessagesLib.Call.FulfilledCancelDepositRequest)
            || messageType == uint8(MessagesLib.Call.FulfilledCancelRedeemRequest);
    }

    // ============================================================
    // INTERNAL HELPERS
    // ============================================================

    /// @dev Parse pool ID from message
    function _parsePoolId(bytes calldata message) internal pure returns (uint64) {
        return message.toUint64(1);
    }

    /// @dev Convert bytes16 to address (takes last 20 bytes)
    function _bytes16ToAddress(bytes16 b) internal pure returns (address) {
        return address(uint160(uint128(b)));
    }

    /// @dev Convert bytes32 to address (takes last 20 bytes)
    function _bytes32ToAddress(bytes32 b) internal pure returns (address) {
        return address(uint160(uint256(b)));
    }

    /// @dev Get vault address for pool/shareClass/asset combination
    function _getVaultForShareClass(uint64 poolId, bytes16 scId, address asset) internal view returns (address) {
        return IRiyzoSpoke(spoke).getVault(poolId, scId, asset);
    }
}
