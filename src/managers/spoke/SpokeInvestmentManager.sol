// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.28;

import {Auth} from "src/core/Auth.sol";
import {MathLib} from "src/core/libraries/MathLib.sol";
import {CastLib} from "src/core/libraries/CastLib.sol";
import {SafeTransferLib} from "src/core/libraries/SafeTransferLib.sol";
import {IERC20, IERC20Metadata} from "src/interfaces/IERC20.sol";
import {IInvestmentManager, InvestmentState} from "src/interfaces/IInvestmentManager.sol";
import {IRecoverable} from "src/interfaces/IRoot.sol";
import {IERC7540Vault} from "src/interfaces/IERC7540.sol";
import {ITranche} from "src/interfaces/token/ITranche.sol";
import {IRiyzoSpoke} from "src/interfaces/spoke/IRiyzoSpoke.sol";
import {IBalanceSheet} from "src/interfaces/spoke/IBalanceSheet.sol";

/// @title  SpokeInvestmentManager
/// @author Riyzo Protocol
/// @notice Adapter that implements IInvestmentManager for ERC7540Vault, delegating
///         to spoke-layer components (RiyzoSpoke, PoolEscrow, BalanceSheet).
///         This allows the V2-forked vault to work with spoke-layer contracts
///         without modification, preserving upstream tracking.
contract SpokeInvestmentManager is Auth, IInvestmentManager {
    using MathLib for uint256;
    using CastLib for *;

    /// @dev Prices are fixed-point integers with 18 decimals
    uint8 internal constant PRICE_DECIMALS = 18;

    address public immutable escrow;

    IRiyzoSpoke public spoke;
    IBalanceSheet public balanceSheet;

    /// @inheritdoc IInvestmentManager
    mapping(address vault => mapping(address investor => InvestmentState)) public investments;

    constructor(address escrow_, address deployer) Auth(deployer) {
        escrow = escrow_;
    }

    // --- Administration ---
    /// @inheritdoc IInvestmentManager
    function file(bytes32 what, address data) external auth {
        if (what == "spoke") spoke = IRiyzoSpoke(data);
        else if (what == "balanceSheet") balanceSheet = IBalanceSheet(data);
        else revert("SpokeInvestmentManager/file-unrecognized-param");
        emit File(what, data);
    }

    /// @inheritdoc IRecoverable
    function recoverTokens(address token, address to, uint256 amount) external auth {
        SafeTransferLib.safeTransfer(token, to, amount);
    }

    // --- Outgoing message handling ---
    /// @inheritdoc IInvestmentManager
    function requestDeposit(address vault, uint256 assets, address controller, address, address)
        public
        auth
        returns (bool)
    {
        IERC7540Vault vault_ = IERC7540Vault(vault);
        uint128 _assets = assets.toUint128();
        require(_assets != 0, "SpokeInvestmentManager/zero-amount-not-allowed");

        uint64 poolId = vault_.poolId();
        bytes16 trancheId = vault_.trancheId();

        require(
            _canTransfer(vault, address(0), controller, convertToShares(vault, assets)),
            "SpokeInvestmentManager/transfer-not-allowed"
        );

        InvestmentState storage state = investments[vault][controller];
        require(!state.pendingCancelDepositRequest, "SpokeInvestmentManager/cancellation-is-pending");

        state.pendingDepositRequest = state.pendingDepositRequest + _assets;

        // Queue request to hub (spoke handles escrow recording internally)
        spoke.queueDepositRequest(poolId, trancheId, controller, _assets);

        return true;
    }

    /// @inheritdoc IInvestmentManager
    function requestRedeem(address vault, uint256 shares, address controller, address, address)
        public
        auth
        returns (bool)
    {
        uint128 _shares = shares.toUint128();
        require(_shares != 0, "SpokeInvestmentManager/zero-amount-not-allowed");

        IERC7540Vault vault_ = IERC7540Vault(vault);

        InvestmentState storage state = investments[vault][controller];
        require(!state.pendingCancelRedeemRequest, "SpokeInvestmentManager/cancellation-is-pending");

        state.pendingRedeemRequest = state.pendingRedeemRequest + _shares;

        spoke.queueRedeemRequest(vault_.poolId(), vault_.trancheId(), controller, _shares);

        return true;
    }

    /// @inheritdoc IInvestmentManager
    function cancelDepositRequest(address vault, address controller, address) public auth {
        IERC7540Vault vault_ = IERC7540Vault(vault);

        InvestmentState storage state = investments[vault][controller];
        require(state.pendingDepositRequest > 0, "SpokeInvestmentManager/no-pending-deposit-request");
        require(!state.pendingCancelDepositRequest, "SpokeInvestmentManager/cancellation-is-pending");
        state.pendingCancelDepositRequest = true;

        spoke.queueCancelDeposit(vault_.poolId(), vault_.trancheId(), controller);
    }

    /// @inheritdoc IInvestmentManager
    function cancelRedeemRequest(address vault, address controller, address) public auth {
        IERC7540Vault vault_ = IERC7540Vault(vault);
        uint256 approximateTranchesPayout = pendingRedeemRequest(vault, controller);
        require(approximateTranchesPayout > 0, "SpokeInvestmentManager/no-pending-redeem-request");
        require(
            _canTransfer(vault, address(0), controller, approximateTranchesPayout),
            "SpokeInvestmentManager/transfer-not-allowed"
        );

        InvestmentState storage state = investments[vault][controller];
        require(!state.pendingCancelRedeemRequest, "SpokeInvestmentManager/cancellation-is-pending");
        state.pendingCancelRedeemRequest = true;

        spoke.queueCancelRedeem(vault_.poolId(), vault_.trancheId(), controller);
    }

    // --- Incoming message handling ---
    /// @inheritdoc IInvestmentManager
    function handle(bytes calldata) public pure {
        revert("SpokeInvestmentManager/messages-go-through-spoke-handler");
    }

    /// @inheritdoc IInvestmentManager
    function fulfillDepositRequest(
        uint64 poolId,
        bytes16 trancheId,
        address user,
        uint128 assetId,
        uint128 assets,
        uint128 shares
    ) public auth {
        address vault = _getVault(poolId, trancheId);

        InvestmentState storage state = investments[vault][user];
        require(state.pendingDepositRequest != 0, "SpokeInvestmentManager/no-pending-deposit-request");
        state.depositPrice = _calculatePrice(vault, _maxDeposit(vault, user) + assets, state.maxMint + shares);
        state.maxMint = state.maxMint + shares;
        state.pendingDepositRequest = state.pendingDepositRequest > assets ? state.pendingDepositRequest - assets : 0;

        if (state.pendingDepositRequest == 0) delete state.pendingCancelDepositRequest;

        // Mint shares to escrow for ERC-7540 compliance - user claims via vault.deposit()/mint()
        ITranche tranche = ITranche(IERC7540Vault(vault).share());
        tranche.mint(escrow, shares);

        IERC7540Vault(vault).onDepositClaimable(user, assets, shares);
    }

    /// @inheritdoc IInvestmentManager
    function fulfillRedeemRequest(
        uint64 poolId,
        bytes16 trancheId,
        address user,
        uint128 assetId,
        uint128 assets,
        uint128 shares
    ) public auth {
        address vault = _getVault(poolId, trancheId);

        InvestmentState storage state = investments[vault][user];
        require(state.pendingRedeemRequest != 0, "SpokeInvestmentManager/no-pending-redeem-request");

        state.redeemPrice =
            _calculatePrice(vault, state.maxWithdraw + assets, ((maxRedeem(vault, user)) + shares).toUint128());
        state.maxWithdraw = state.maxWithdraw + assets;
        state.pendingRedeemRequest = state.pendingRedeemRequest > shares ? state.pendingRedeemRequest - shares : 0;

        if (state.pendingRedeemRequest == 0) delete state.pendingCancelRedeemRequest;

        // Burn redeemed tranche tokens from escrow
        ITranche tranche = ITranche(IERC7540Vault(vault).share());
        tranche.burn(escrow, shares);

        IERC7540Vault(vault).onRedeemClaimable(user, assets, shares);
    }

    /// @inheritdoc IInvestmentManager
    function fulfillCancelDepositRequest(
        uint64 poolId,
        bytes16 trancheId,
        address user,
        uint128 assetId,
        uint128 assets,
        uint128 fulfillment
    ) public auth {
        address vault = _getVault(poolId, trancheId);

        InvestmentState storage state = investments[vault][user];
        require(state.pendingCancelDepositRequest, "SpokeInvestmentManager/no-pending-cancel-deposit-request");

        state.claimableCancelDepositRequest = state.claimableCancelDepositRequest + assets;
        state.pendingDepositRequest =
            state.pendingDepositRequest > fulfillment ? state.pendingDepositRequest - fulfillment : 0;

        if (state.pendingDepositRequest == 0) delete state.pendingCancelDepositRequest;

        IERC7540Vault(vault).onCancelDepositClaimable(user, assets);
    }

    /// @inheritdoc IInvestmentManager
    function fulfillCancelRedeemRequest(uint64 poolId, bytes16 trancheId, address user, uint128 assetId, uint128 shares)
        public
        auth
    {
        address vault = _getVault(poolId, trancheId);
        InvestmentState storage state = investments[vault][user];
        require(state.pendingCancelRedeemRequest, "SpokeInvestmentManager/no-pending-cancel-redeem-request");

        state.claimableCancelRedeemRequest = state.claimableCancelRedeemRequest + shares;
        state.pendingRedeemRequest = state.pendingRedeemRequest > shares ? state.pendingRedeemRequest - shares : 0;

        if (state.pendingRedeemRequest == 0) delete state.pendingCancelRedeemRequest;

        IERC7540Vault(vault).onCancelRedeemClaimable(user, shares);
    }

    /// @inheritdoc IInvestmentManager
    function triggerRedeemRequest(uint64 poolId, bytes16 trancheId, address user, uint128 assetId, uint128 shares)
        public
        auth
    {
        require(shares != 0, "SpokeInvestmentManager/tranche-token-amount-is-zero");
        address vault = _getVault(poolId, trancheId);

        InvestmentState storage state = investments[vault][user];
        uint128 tokensToTransfer = shares;
        if (state.maxMint >= shares) {
            tokensToTransfer = 0;
            state.maxMint = state.maxMint - shares;
        } else if (state.maxMint != 0) {
            tokensToTransfer = shares - state.maxMint;
            state.maxMint = 0;
        }

        state.pendingRedeemRequest = state.pendingRedeemRequest + shares;
        spoke.queueRedeemRequest(poolId, trancheId, user, shares);

        // Transfer the tranche token amount not covered by tokens in escrow
        if (tokensToTransfer != 0) {
            require(
                ITranche(IERC7540Vault(vault).share()).authTransferFrom(user, user, escrow, tokensToTransfer),
                "SpokeInvestmentManager/transfer-failed"
            );
        }

        emit TriggerRedeemRequest(poolId, trancheId, user, IERC7540Vault(vault).asset(), shares);
        IERC7540Vault(vault).onRedeemRequest(user, user, shares);
    }

    // --- View functions ---
    /// @inheritdoc IInvestmentManager
    function convertToShares(address vault, uint256 _assets) public view returns (uint256 shares) {
        IERC7540Vault vault_ = IERC7540Vault(vault);
        (uint128 latestPrice,) = spoke.getPrice(vault_.poolId(), vault_.trancheId());
        shares = uint256(_calculateShares(_assets.toUint128(), vault, latestPrice, MathLib.Rounding.Down));
    }

    /// @inheritdoc IInvestmentManager
    function convertToAssets(address vault, uint256 _shares) public view returns (uint256 assets) {
        IERC7540Vault vault_ = IERC7540Vault(vault);
        (uint128 latestPrice,) = spoke.getPrice(vault_.poolId(), vault_.trancheId());
        assets = uint256(_calculateAssets(_shares.toUint128(), vault, latestPrice, MathLib.Rounding.Down));
    }

    /// @inheritdoc IInvestmentManager
    function maxDeposit(address vault, address user) public view returns (uint256 assets) {
        if (!_canTransfer(vault, escrow, user, 0)) return 0;
        assets = uint256(_maxDeposit(vault, user));
    }

    function _maxDeposit(address vault, address user) internal view returns (uint128 assets) {
        InvestmentState memory state = investments[vault][user];
        assets = _calculateAssets(state.maxMint, vault, state.depositPrice, MathLib.Rounding.Down);
    }

    /// @inheritdoc IInvestmentManager
    function maxMint(address vault, address user) public view returns (uint256 shares) {
        if (!_canTransfer(vault, escrow, user, 0)) return 0;
        shares = uint256(investments[vault][user].maxMint);
    }

    /// @inheritdoc IInvestmentManager
    function maxWithdraw(address vault, address user) public view returns (uint256 assets) {
        assets = uint256(investments[vault][user].maxWithdraw);
    }

    /// @inheritdoc IInvestmentManager
    function maxRedeem(address vault, address user) public view returns (uint256 shares) {
        InvestmentState memory state = investments[vault][user];
        shares = uint256(_calculateShares(state.maxWithdraw, vault, state.redeemPrice, MathLib.Rounding.Down));
    }

    /// @inheritdoc IInvestmentManager
    function pendingDepositRequest(address vault, address user) public view returns (uint256 assets) {
        assets = uint256(investments[vault][user].pendingDepositRequest);
    }

    /// @inheritdoc IInvestmentManager
    function pendingRedeemRequest(address vault, address user) public view returns (uint256 shares) {
        shares = uint256(investments[vault][user].pendingRedeemRequest);
    }

    /// @inheritdoc IInvestmentManager
    function pendingCancelDepositRequest(address vault, address user) public view returns (bool isPending) {
        isPending = investments[vault][user].pendingCancelDepositRequest;
    }

    /// @inheritdoc IInvestmentManager
    function pendingCancelRedeemRequest(address vault, address user) public view returns (bool isPending) {
        isPending = investments[vault][user].pendingCancelRedeemRequest;
    }

    /// @inheritdoc IInvestmentManager
    function claimableCancelDepositRequest(address vault, address user) public view returns (uint256 assets) {
        assets = investments[vault][user].claimableCancelDepositRequest;
    }

    /// @inheritdoc IInvestmentManager
    function claimableCancelRedeemRequest(address vault, address user) public view returns (uint256 shares) {
        shares = investments[vault][user].claimableCancelRedeemRequest;
    }

    /// @inheritdoc IInvestmentManager
    function priceLastUpdated(address vault) public view returns (uint64 lastUpdated) {
        IERC7540Vault vault_ = IERC7540Vault(vault);
        (, lastUpdated) = spoke.getPrice(vault_.poolId(), vault_.trancheId());
    }

    // --- Vault claim functions ---
    /// @inheritdoc IInvestmentManager
    function deposit(address vault, uint256 assets, address receiver, address controller)
        public
        auth
        returns (uint256 shares)
    {
        require(assets <= _maxDeposit(vault, controller), "SpokeInvestmentManager/exceeds-max-deposit");

        InvestmentState storage state = investments[vault][controller];
        uint128 sharesUp = _calculateShares(assets.toUint128(), vault, state.depositPrice, MathLib.Rounding.Up);
        uint128 sharesDown = _calculateShares(assets.toUint128(), vault, state.depositPrice, MathLib.Rounding.Down);
        _processDeposit(state, sharesUp, sharesDown, vault, receiver);
        shares = uint256(sharesDown);
    }

    /// @inheritdoc IInvestmentManager
    function mint(address vault, uint256 shares, address receiver, address controller)
        public
        auth
        returns (uint256 assets)
    {
        InvestmentState storage state = investments[vault][controller];
        uint128 shares_ = shares.toUint128();
        _processDeposit(state, shares_, shares_, vault, receiver);
        assets = uint256(_calculateAssets(shares_, vault, state.depositPrice, MathLib.Rounding.Down));
    }

    function _processDeposit(
        InvestmentState storage state,
        uint128 sharesUp,
        uint128 sharesDown,
        address vault,
        address receiver
    ) internal {
        require(sharesUp <= state.maxMint, "SpokeInvestmentManager/exceeds-deposit-limits");
        state.maxMint = state.maxMint > sharesUp ? state.maxMint - sharesUp : 0;
        if (sharesDown > 0) {
            require(
                IERC20(IERC7540Vault(vault).share()).transferFrom(escrow, receiver, sharesDown),
                "SpokeInvestmentManager/tranche-tokens-transfer-failed"
            );
        }
    }

    /// @inheritdoc IInvestmentManager
    function redeem(address vault, uint256 shares, address receiver, address controller)
        public
        auth
        returns (uint256 assets)
    {
        require(shares <= maxRedeem(vault, controller), "SpokeInvestmentManager/exceeds-max-redeem");

        InvestmentState storage state = investments[vault][controller];
        uint128 assetsUp = _calculateAssets(shares.toUint128(), vault, state.redeemPrice, MathLib.Rounding.Up);
        uint128 assetsDown = _calculateAssets(shares.toUint128(), vault, state.redeemPrice, MathLib.Rounding.Down);
        _processRedeem(state, assetsUp, assetsDown, vault, receiver);
        assets = uint256(assetsDown);
    }

    /// @inheritdoc IInvestmentManager
    function withdraw(address vault, uint256 assets, address receiver, address controller)
        public
        auth
        returns (uint256 shares)
    {
        InvestmentState storage state = investments[vault][controller];
        uint128 assets_ = assets.toUint128();
        _processRedeem(state, assets_, assets_, vault, receiver);
        shares = uint256(_calculateShares(assets_, vault, state.redeemPrice, MathLib.Rounding.Down));
    }

    function _processRedeem(
        InvestmentState storage state,
        uint128 assetsUp,
        uint128 assetsDown,
        address vault,
        address receiver
    ) internal {
        IERC7540Vault vault_ = IERC7540Vault(vault);
        require(assetsUp <= state.maxWithdraw, "SpokeInvestmentManager/exceeds-redeem-limits");
        state.maxWithdraw = state.maxWithdraw > assetsUp ? state.maxWithdraw - assetsUp : 0;
        if (assetsDown > 0) SafeTransferLib.safeTransferFrom(vault_.asset(), escrow, receiver, assetsDown);
    }

    /// @inheritdoc IInvestmentManager
    function claimCancelDepositRequest(address vault, address receiver, address controller)
        public
        auth
        returns (uint256 assets)
    {
        InvestmentState storage state = investments[vault][controller];
        assets = state.claimableCancelDepositRequest;
        state.claimableCancelDepositRequest = 0;
        if (assets > 0) {
            SafeTransferLib.safeTransferFrom(IERC7540Vault(vault).asset(), escrow, receiver, assets);
        }
    }

    /// @inheritdoc IInvestmentManager
    function claimCancelRedeemRequest(address vault, address receiver, address controller)
        public
        auth
        returns (uint256 shares)
    {
        InvestmentState storage state = investments[vault][controller];
        shares = state.claimableCancelRedeemRequest;
        state.claimableCancelRedeemRequest = 0;
        if (shares > 0) {
            require(
                IERC20(IERC7540Vault(vault).share()).transferFrom(escrow, receiver, shares),
                "SpokeInvestmentManager/tranche-tokens-transfer-failed"
            );
        }
    }

    // --- Helpers ---
    function _calculateShares(uint128 assets, address vault, uint256 price, MathLib.Rounding rounding)
        internal
        view
        returns (uint128 shares)
    {
        if (price == 0 || assets == 0) {
            shares = 0;
        } else {
            (uint8 assetDecimals, uint8 shareDecimals) = _getPoolDecimals(vault);

            uint256 sharesInPriceDecimals =
                _toPriceDecimals(assets, assetDecimals).mulDiv(10 ** PRICE_DECIMALS, price, rounding);

            shares = _fromPriceDecimals(sharesInPriceDecimals, shareDecimals);
        }
    }

    function _calculateAssets(uint128 shares, address vault, uint256 price, MathLib.Rounding rounding)
        internal
        view
        returns (uint128 assets)
    {
        if (price == 0 || shares == 0) {
            assets = 0;
        } else {
            (uint8 assetDecimals, uint8 shareDecimals) = _getPoolDecimals(vault);

            uint256 assetsInPriceDecimals =
                _toPriceDecimals(shares, shareDecimals).mulDiv(price, 10 ** PRICE_DECIMALS, rounding);

            assets = _fromPriceDecimals(assetsInPriceDecimals, assetDecimals);
        }
    }

    function _calculatePrice(address vault, uint128 assets, uint128 shares) internal view returns (uint256) {
        if (assets == 0 || shares == 0) {
            return 0;
        }

        (uint8 assetDecimals, uint8 shareDecimals) = _getPoolDecimals(vault);
        return _toPriceDecimals(assets, assetDecimals)
            .mulDiv(10 ** PRICE_DECIMALS, _toPriceDecimals(shares, shareDecimals), MathLib.Rounding.Down);
    }

    function _toPriceDecimals(uint128 _value, uint8 decimals) internal pure returns (uint256) {
        if (PRICE_DECIMALS == decimals) return uint256(_value);
        return uint256(_value) * 10 ** (PRICE_DECIMALS - decimals);
    }

    function _fromPriceDecimals(uint256 _value, uint8 decimals) internal pure returns (uint128) {
        if (PRICE_DECIMALS == decimals) return _value.toUint128();
        return (_value / 10 ** (PRICE_DECIMALS - decimals)).toUint128();
    }

    function _getPoolDecimals(address vault) internal view returns (uint8 assetDecimals, uint8 shareDecimals) {
        assetDecimals = IERC20Metadata(IERC7540Vault(vault).asset()).decimals();
        shareDecimals = IERC20Metadata(IERC7540Vault(vault).share()).decimals();
    }

    function _canTransfer(address vault, address from, address to, uint256 value) internal view returns (bool) {
        ITranche share = ITranche(IERC7540Vault(vault).share());
        return share.checkTransferRestriction(from, to, value);
    }

    function _getVault(uint64 poolId, bytes16 trancheId) internal view returns (address) {
        IRiyzoSpoke.ShareClassState memory sc = spoke.getShareClass(poolId, trancheId);
        require(sc.exists, "SpokeInvestmentManager/share-class-not-found");

        address currency = spoke.getPool(poolId).currency;
        address vault = spoke.getVault(poolId, trancheId, currency);
        require(vault != address(0), "SpokeInvestmentManager/vault-not-found");

        return vault;
    }
}
