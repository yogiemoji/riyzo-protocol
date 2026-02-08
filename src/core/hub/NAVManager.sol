// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.28;

import {Auth} from "src/core/Auth.sol";
import {INAVManager} from "src/interfaces/hub/INAVManager.sol";
import {IAccounting} from "src/interfaces/hub/IAccounting.sol";
import {IHoldings} from "src/interfaces/hub/IHoldings.sol";
import {IValuation} from "src/interfaces/hub/IValuation.sol";

/// @title NAVManager - Net Asset Value Manager
/// @author Riyzo Protocol
/// @notice This contract calculates and tracks Net Asset Value (NAV) per pool per network.
///         Think of NAV as the "net worth" of a pool's holdings on a specific chain.
/// @dev NAV is calculated from accounting balances using:
///      NAV = Equity + Gains - Losses - Liabilities
///
/// ============================================================
/// KEY CONCEPTS FOR EVERYONE
/// ============================================================
///
/// WHAT IS NAV?
/// Net Asset Value (NAV) = Total Assets - Total Liabilities
/// It's the "net worth" of the pool - what's left after paying all debts.
///
/// EXAMPLE:
/// - Pool has $100,000 in assets (USDC, ETH, bonds)
/// - Pool has $10,000 in liabilities (loans, fees owed)
/// - NAV = $100,000 - $10,000 = $90,000
///
/// WHY PER-NETWORK NAV?
/// Riyzo is a cross-chain protocol. Users on different chains deposit
/// into the same logical pool, but we track their contributions separately:
/// - Ethereum users deposit into Ethereum's "slice" of the pool
/// - Base users deposit into Base's "slice" of the pool
///
/// This allows fair pricing: if Ethereum deposits $1M and Base deposits $100K,
/// they shouldn't share gains/losses equally.
///
/// ============================================================
/// ACCOUNT ID DERIVATION
/// ============================================================
///
/// Instead of storing account IDs in mappings, we compute them on-the-fly.
/// This saves gas and storage costs.
///
/// Account ID = (identifier << 16) | AccountTypeCode
///
/// For asset accounts:   (assetId << 16) | 0x0001
/// For equity accounts:  (centrifugeId << 16) | 0x0002
/// For gain accounts:    (centrifugeId << 16) | 0x0003
/// For loss accounts:    (centrifugeId << 16) | 0x0004
/// For expense accounts: (assetId << 16) | 0x0005
/// For liability accounts: (centrifugeId << 16) | 0x0006
///
/// ============================================================
/// NAV CALCULATION FORMULA
/// ============================================================
///
/// NAV = Equity + Gain - Loss - Liability
///
/// WHERE:
/// - Equity: Total value of investor deposits
/// - Gain: Unrealized profits from price appreciation
/// - Loss: Unrealized losses from price depreciation
/// - Liability: Debts, loans, obligations
///
/// EXAMPLE:
/// - Equity = $100,000 (investors deposited this much)
/// - Gain = $5,000 (assets appreciated)
/// - Loss = $1,000 (some assets depreciated)
/// - Liability = $2,000 (fees owed)
/// - NAV = 100,000 + 5,000 - 1,000 - 2,000 = $102,000
///
/// ============================================================
/// TYPICAL FLOW: Initializing a New Network
/// ============================================================
///
/// When a new spoke chain (e.g., Base) wants to participate in a pool:
///
/// 1. Admin calls initializeNetwork(poolId, BASE_CENTRIFUGE_ID)
/// 2. NAVManager creates 4 accounts in Accounting.sol:
///    - Equity account for Base network
///    - Gain account for Base network
///    - Loss account for Base network
///    - Liability account for Base network
/// 3. Base users can now deposit and their NAV is tracked separately
///
/// ============================================================
/// CLOSING GAINS/LOSSES
/// ============================================================
///
/// At the end of an epoch or when shares are redeemed, unrealized gains/losses
/// should be "closed" (moved to equity). This is called "realizing" the gains.
///
/// EXAMPLE:
/// - Gain account shows $5,000 of unrealized profits
/// - Loss account shows $1,000 of unrealized losses
/// - Net = $4,000 gain
/// - closeGainLoss() moves this $4,000 to equity
/// - Result: Equity increases by $4,000, gain/loss accounts are zeroed
///
contract NAVManager is Auth, INAVManager {
    // ============================================================
    // ACCOUNT TYPE CODES
    // ============================================================
    // These are embedded in account IDs to identify account types

    /// @dev Asset accounts track value of owned assets
    uint16 internal constant ACCOUNT_TYPE_ASSET = 0x0001;

    /// @dev Equity accounts track investor deposits per network
    uint16 internal constant ACCOUNT_TYPE_EQUITY = 0x0002;

    /// @dev Gain accounts track unrealized profits per network
    uint16 internal constant ACCOUNT_TYPE_GAIN = 0x0003;

    /// @dev Loss accounts track unrealized losses per network
    uint16 internal constant ACCOUNT_TYPE_LOSS = 0x0004;

    /// @dev Expense accounts track costs for liabilities
    uint16 internal constant ACCOUNT_TYPE_EXPENSE = 0x0005;

    /// @dev Liability accounts track obligations per network
    uint16 internal constant ACCOUNT_TYPE_LIABILITY = 0x0006;

    // ============================================================
    // STORAGE
    // ============================================================

    /// @notice Reference to the Accounting contract
    IAccounting public accounting;

    /// @notice Reference to the Holdings contract
    IHoldings public holdings;

    /// @notice Tracks which networks have been initialized for each pool
    /// @dev networkInitialized[poolId][centrifugeId] => bool
    mapping(uint64 => mapping(uint16 => bool)) internal _networkInitialized;

    // ============================================================
    // CONSTRUCTOR
    // ============================================================

    /// @notice Initialize the NAVManager contract
    /// @param initialWard Address that will have admin rights
    /// @param accounting_ Address of the Accounting contract
    /// @param holdings_ Address of the Holdings contract
    constructor(address initialWard, IAccounting accounting_, IHoldings holdings_) Auth(initialWard) {
        accounting = accounting_;
        holdings = holdings_;
    }

    // ============================================================
    // ADMIN FUNCTIONS
    // ============================================================

    /// @notice Update contract dependencies
    /// @dev Standard "file" pattern used across the protocol
    /// @param what Parameter name to update
    /// @param data New value
    function file(bytes32 what, address data) external auth {
        if (what == "accounting") {
            accounting = IAccounting(data);
        } else if (what == "holdings") {
            holdings = IHoldings(data);
        } else {
            revert("NAVManager/file-unrecognized-param");
        }
        emit File(what, data);
    }

    /// @dev Event for file() function
    event File(bytes32 indexed what, address data);

    // ============================================================
    // NETWORK INITIALIZATION
    // ============================================================

    /// @inheritdoc INAVManager
    /// @dev Creates the per-network accounting accounts.
    ///
    /// WHAT THIS DOES:
    /// 1. Verifies network hasn't been initialized for this pool
    /// 2. Creates 4 accounting accounts:
    ///    - Equity: Tracks investor stake from this network
    ///    - Gain: Tracks unrealized profits for this network
    ///    - Loss: Tracks unrealized losses for this network
    ///    - Liability: Tracks obligations for this network
    /// 3. Marks network as initialized
    ///
    /// EXAMPLE:
    /// initializeNetwork(1, 1) // Pool 1, Ethereum mainnet
    /// - Creates equity account for Ethereum investors
    /// - Creates gain account for Ethereum gains
    /// - Creates loss account for Ethereum losses
    /// - Creates liability account for Ethereum liabilities
    function initializeNetwork(uint64 poolId, uint16 centrifugeId) external auth {
        // ============================================================
        // STEP 1: Verify network not already initialized
        // ============================================================
        if (_networkInitialized[poolId][centrifugeId]) {
            revert NetworkAlreadyInitialized(poolId, centrifugeId);
        }

        // ============================================================
        // STEP 2: Create per-network accounting accounts
        // ============================================================
        // Equity account - tracks investor deposits from this network
        bytes32 eqAccount = _equityAccount(centrifugeId);
        accounting.createAccount(poolId, eqAccount, IAccounting.AccountType.Equity);

        // Gain account - tracks unrealized profits for this network
        bytes32 gAccount = _gainAccount(centrifugeId);
        accounting.createAccount(poolId, gAccount, IAccounting.AccountType.Gain);

        // Loss account - tracks unrealized losses for this network
        bytes32 lAccount = _lossAccount(centrifugeId);
        accounting.createAccount(poolId, lAccount, IAccounting.AccountType.Loss);

        // Liability account - tracks obligations for this network
        bytes32 liabAccount = _liabilityAccount(centrifugeId);
        accounting.createAccount(poolId, liabAccount, IAccounting.AccountType.Liability);

        // ============================================================
        // STEP 3: Mark network as initialized
        // ============================================================
        _networkInitialized[poolId][centrifugeId] = true;

        emit NetworkInitialized(poolId, centrifugeId);
    }

    // ============================================================
    // HOLDING INITIALIZATION
    // ============================================================

    /// @inheritdoc INAVManager
    /// @dev Creates a holding and its associated accounting accounts.
    ///
    /// WHAT THIS DOES:
    /// 1. Creates asset account in Accounting.sol
    /// 2. Prepares the linked accounts array (asset, equity, gain, loss)
    /// 3. Calls Holdings.initialize() with the accounts
    ///
    /// WHY USE THIS INSTEAD OF HOLDINGS.INITIALIZE DIRECTLY?
    /// - Ensures proper account linkage
    /// - Creates asset account before initializing holding
    /// - Simpler interface for callers
    ///
    /// NOTE: This function requires the caller to have auth on both
    /// NAVManager and be a ward on Holdings and Accounting.
    function initializeHolding(uint64 poolId, bytes16 scId, uint128 assetId, IValuation valuation) external auth {
        // ============================================================
        // STEP 1: Create asset account in Accounting
        // ============================================================
        bytes32 aAccount = _assetAccount(assetId);

        // Check if account already exists (might be shared across share classes)
        if (!accounting.accountExists(poolId, aAccount)) {
            accounting.createAccount(poolId, aAccount, IAccounting.AccountType.Asset);
        }

        // ============================================================
        // STEP 2: Prepare linked accounts array
        // ============================================================
        // For asset holdings, we need 4 accounts:
        // [0] Asset account - tracks asset value
        // [1] Equity account - we'll use a placeholder (actual equity is per-network)
        // [2] Gain account - placeholder (actual gains are per-network)
        // [3] Loss account - placeholder (actual losses are per-network)
        //
        // NOTE: The actual equity/gain/loss accounting happens at the network level.
        // For holdings, we use generic accounts that can be aggregated.
        IHoldings.HoldingAccount[] memory accounts = new IHoldings.HoldingAccount[](4);

        accounts[0] = IHoldings.HoldingAccount({accountId: aAccount, accountType: uint8(IAccounting.AccountType.Asset)});

        // For equity/gain/loss, we use a "global" account (centrifugeId = 0)
        // In practice, these should be linked to specific network accounts
        // via the NAVManager's closeGainLoss and NAV calculation functions
        accounts[1] = IHoldings.HoldingAccount({
            accountId: _equityAccount(0), // Global equity placeholder
            accountType: uint8(IAccounting.AccountType.Equity)
        });

        accounts[2] = IHoldings.HoldingAccount({
            accountId: _gainAccount(0), // Global gain placeholder
            accountType: uint8(IAccounting.AccountType.Gain)
        });

        accounts[3] = IHoldings.HoldingAccount({
            accountId: _lossAccount(0), // Global loss placeholder
            accountType: uint8(IAccounting.AccountType.Loss)
        });

        // ============================================================
        // STEP 3: Initialize holding in Holdings contract
        // ============================================================
        holdings.initialize(poolId, scId, assetId, valuation, false, accounts);

        emit HoldingInitialized(poolId, scId, assetId);
    }

    /// @inheritdoc INAVManager
    /// @dev Similar to initializeHolding but for liabilities.
    ///
    /// For liability holdings, we create:
    /// [0] Expense account - tracks costs
    /// [1] Liability account - tracks obligations
    function initializeLiability(uint64 poolId, bytes16 scId, uint128 assetId, IValuation valuation) external auth {
        // ============================================================
        // STEP 1: Create expense account in Accounting
        // ============================================================
        bytes32 expAccount = _expenseAccount(assetId);

        if (!accounting.accountExists(poolId, expAccount)) {
            accounting.createAccount(poolId, expAccount, IAccounting.AccountType.Expense);
        }

        // ============================================================
        // STEP 2: Prepare linked accounts array for liability
        // ============================================================
        IHoldings.HoldingAccount[] memory accounts = new IHoldings.HoldingAccount[](2);

        accounts[0] =
            IHoldings.HoldingAccount({accountId: expAccount, accountType: uint8(IAccounting.AccountType.Expense)});

        accounts[1] = IHoldings.HoldingAccount({
            accountId: _liabilityAccount(0), // Global liability placeholder
            accountType: uint8(IAccounting.AccountType.Liability)
        });

        // ============================================================
        // STEP 3: Initialize holding as liability
        // ============================================================
        holdings.initialize(poolId, scId, assetId, valuation, true, accounts);

        emit HoldingInitialized(poolId, scId, assetId);
    }

    // ============================================================
    // GAIN/LOSS CLOSING
    // ============================================================

    /// @inheritdoc INAVManager
    /// @dev Closes (realizes) gains and losses to equity for a network.
    ///
    /// WHAT THIS DOES:
    /// 1. Gets gain and loss account values for the network
    /// 2. Calculates net gain or loss
    /// 3. Transfers to/from equity account
    /// 4. Zeros out gain and loss accounts
    ///
    /// WHY DO THIS?
    /// - Unrealized gains/losses are "paper" profits/losses
    /// - Closing them "realizes" them - moves to equity
    /// - Done at end of epoch or when shares redeemed
    ///
    /// EXAMPLE:
    /// - Gain account: $5,000
    /// - Loss account: $1,000
    /// - Net: +$4,000
    /// - After close: Equity +$4,000, Gain = $0, Loss = $0
    function closeGainLoss(uint64 poolId, uint16 centrifugeId) external auth {
        // ============================================================
        // STEP 1: Verify network is initialized
        // ============================================================
        if (!_networkInitialized[poolId][centrifugeId]) {
            revert NetworkNotInitialized(poolId, centrifugeId);
        }

        // ============================================================
        // STEP 2: Get account values
        // ============================================================
        bytes32 gainAcct = _gainAccount(centrifugeId);
        bytes32 lossAcct = _lossAccount(centrifugeId);
        bytes32 equityAcct = _equityAccount(centrifugeId);

        (bool gainPositive, uint128 gainValue) = accounting.accountValue(poolId, gainAcct);
        (bool lossPositive, uint128 lossValue) = accounting.accountValue(poolId, lossAcct);

        // ============================================================
        // STEP 3: Calculate net gain or loss
        // ============================================================
        // Gain and loss are both credit-normal, so positive values are "normal"
        // If gain > loss: net gain, increase equity
        // If loss > gain: net loss, decrease equity

        // Handle edge cases where accounts might be negative (shouldn't happen normally)
        if (!gainPositive) gainValue = 0;
        if (!lossPositive) lossValue = 0;

        // Skip if nothing to close
        if (gainValue == 0 && lossValue == 0) {
            return;
        }

        // ============================================================
        // STEP 4: Open accounting transaction
        // ============================================================
        accounting.unlock(poolId);

        if (gainValue >= lossValue) {
            // ============================================================
            // CASE A: Net Gain
            // ============================================================
            // Transfer net gain to equity
            // Debit Gain account (decrease gain)
            // Credit Equity account (increase equity)
            uint128 netGain = gainValue - lossValue;

            if (gainValue > 0) {
                // Zero out gain account: debit it (gain is credit-normal)
                accounting.debit(gainAcct, gainValue);
            }
            if (lossValue > 0) {
                // Zero out loss account: debit it (loss is credit-normal)
                accounting.credit(lossAcct, lossValue);
            }
            if (netGain > 0) {
                // Credit equity for net gain
                accounting.credit(equityAcct, netGain);
            }

            emit GainLossClosed(poolId, centrifugeId, true, netGain);
        } else {
            // ============================================================
            // CASE B: Net Loss
            // ============================================================
            // Transfer net loss from equity
            // Debit Equity account (decrease equity)
            // Credit Loss account (decrease loss - zeroing it out)
            uint128 netLoss = lossValue - gainValue;

            if (gainValue > 0) {
                // Zero out gain account
                accounting.debit(gainAcct, gainValue);
            }
            if (lossValue > 0) {
                // Zero out loss account
                accounting.credit(lossAcct, lossValue);
            }
            if (netLoss > 0) {
                // Debit equity for net loss
                accounting.debit(equityAcct, netLoss);
            }

            emit GainLossClosed(poolId, centrifugeId, false, netLoss);
        }

        // ============================================================
        // STEP 5: Commit accounting transaction
        // ============================================================
        accounting.lock();
    }

    // ============================================================
    // VIEW FUNCTIONS
    // ============================================================

    /// @inheritdoc INAVManager
    /// @dev Calculates NAV = Equity + Gain - Loss - Liability
    ///
    /// IMPORTANT: Returns 0 if NAV would be negative!
    /// This prevents underflow and indicates an insolvent pool.
    ///
    /// EXAMPLE:
    /// - Equity = $100,000
    /// - Gain = $5,000
    /// - Loss = $1,000
    /// - Liability = $2,000
    /// - NAV = 100,000 + 5,000 - 1,000 - 2,000 = $102,000
    function netAssetValue(uint64 poolId, uint16 centrifugeId) external view returns (uint128 nav) {
        if (!_networkInitialized[poolId][centrifugeId]) {
            revert NetworkNotInitialized(poolId, centrifugeId);
        }

        // Get all account values
        (bool equityPositive, uint128 equityValue) = accounting.accountValue(poolId, _equityAccount(centrifugeId));
        (bool gainPositive, uint128 gainValue) = accounting.accountValue(poolId, _gainAccount(centrifugeId));
        (bool lossPositive, uint128 lossValue) = accounting.accountValue(poolId, _lossAccount(centrifugeId));
        (bool liabilityPositive, uint128 liabilityValue) =
            accounting.accountValue(poolId, _liabilityAccount(centrifugeId));

        // Handle negative values (edge cases - shouldn't happen normally)
        if (!equityPositive) equityValue = 0;
        if (!gainPositive) gainValue = 0;
        if (!lossPositive) lossValue = 0;
        if (!liabilityPositive) liabilityValue = 0;

        // Calculate NAV = Equity + Gain - Loss - Liability
        // Use unchecked to allow underflow, then check and return 0 if negative
        uint256 positive = uint256(equityValue) + uint256(gainValue);
        uint256 negative = uint256(lossValue) + uint256(liabilityValue);

        if (positive >= negative) {
            // Safe: result fits in uint128 because positive/negative are sums of uint128 values
            // and we've verified positive >= negative
            // forge-lint: disable-next-line(unsafe-typecast)
            nav = uint128(positive - negative);
        } else {
            // NAV would be negative - return 0
            // This indicates an insolvent pool (liabilities exceed assets)
            nav = 0;
        }
    }

    /// @inheritdoc INAVManager
    function getAccountValues(uint64 poolId, uint16 centrifugeId)
        external
        view
        returns (uint128 equity, uint128 gain, uint128 loss, uint128 liability)
    {
        if (!_networkInitialized[poolId][centrifugeId]) {
            revert NetworkNotInitialized(poolId, centrifugeId);
        }

        (, equity) = accounting.accountValue(poolId, _equityAccount(centrifugeId));
        (, gain) = accounting.accountValue(poolId, _gainAccount(centrifugeId));
        (, loss) = accounting.accountValue(poolId, _lossAccount(centrifugeId));
        (, liability) = accounting.accountValue(poolId, _liabilityAccount(centrifugeId));
    }

    /// @inheritdoc INAVManager
    function isNetworkInitialized(uint64 poolId, uint16 centrifugeId) external view returns (bool initialized) {
        return _networkInitialized[poolId][centrifugeId];
    }

    // ============================================================
    // ACCOUNT ID DERIVATION (Pure Functions)
    // ============================================================

    /// @inheritdoc INAVManager
    function assetAccount(uint128 assetId) external pure returns (bytes32 accountId) {
        return _assetAccount(assetId);
    }

    /// @inheritdoc INAVManager
    function expenseAccount(uint128 assetId) external pure returns (bytes32 accountId) {
        return _expenseAccount(assetId);
    }

    /// @inheritdoc INAVManager
    function equityAccount(uint16 centrifugeId) external pure returns (bytes32 accountId) {
        return _equityAccount(centrifugeId);
    }

    /// @inheritdoc INAVManager
    function gainAccount(uint16 centrifugeId) external pure returns (bytes32 accountId) {
        return _gainAccount(centrifugeId);
    }

    /// @inheritdoc INAVManager
    function lossAccount(uint16 centrifugeId) external pure returns (bytes32 accountId) {
        return _lossAccount(centrifugeId);
    }

    /// @inheritdoc INAVManager
    function liabilityAccount(uint16 centrifugeId) external pure returns (bytes32 accountId) {
        return _liabilityAccount(centrifugeId);
    }

    // ============================================================
    // INTERNAL ACCOUNT ID DERIVATION
    // ============================================================

    /// @dev Derive asset account ID: (assetId << 16) | ACCOUNT_TYPE_ASSET
    function _assetAccount(uint128 assetId) internal pure returns (bytes32) {
        return bytes32((uint256(assetId) << 16) | ACCOUNT_TYPE_ASSET);
    }

    /// @dev Derive expense account ID: (assetId << 16) | ACCOUNT_TYPE_EXPENSE
    function _expenseAccount(uint128 assetId) internal pure returns (bytes32) {
        return bytes32((uint256(assetId) << 16) | ACCOUNT_TYPE_EXPENSE);
    }

    /// @dev Derive equity account ID: (centrifugeId << 16) | ACCOUNT_TYPE_EQUITY
    function _equityAccount(uint16 centrifugeId) internal pure returns (bytes32) {
        return bytes32((uint256(centrifugeId) << 16) | ACCOUNT_TYPE_EQUITY);
    }

    /// @dev Derive gain account ID: (centrifugeId << 16) | ACCOUNT_TYPE_GAIN
    function _gainAccount(uint16 centrifugeId) internal pure returns (bytes32) {
        return bytes32((uint256(centrifugeId) << 16) | ACCOUNT_TYPE_GAIN);
    }

    /// @dev Derive loss account ID: (centrifugeId << 16) | ACCOUNT_TYPE_LOSS
    function _lossAccount(uint16 centrifugeId) internal pure returns (bytes32) {
        return bytes32((uint256(centrifugeId) << 16) | ACCOUNT_TYPE_LOSS);
    }

    /// @dev Derive liability account ID: (centrifugeId << 16) | ACCOUNT_TYPE_LIABILITY
    function _liabilityAccount(uint16 centrifugeId) internal pure returns (bytes32) {
        return bytes32((uint256(centrifugeId) << 16) | ACCOUNT_TYPE_LIABILITY);
    }
}
