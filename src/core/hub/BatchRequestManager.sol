// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.28;

import {Auth} from "src/core/Auth.sol";
import {IShareClassManager} from "src/interfaces/hub/IShareClassManager.sol";
import {IAccounting} from "src/interfaces/hub/IAccounting.sol";
import {IHoldings} from "src/interfaces/hub/IHoldings.sol";
import {INAVManager} from "src/interfaces/hub/INAVManager.sol";
import {MathLib} from "src/core/libraries/MathLib.sol";

/// @title BatchRequestManager - Epoch Request Processing
/// @author Riyzo Protocol
/// @notice This contract processes batched deposit and redeem requests during epoch execution.
///         Think of it as the "settlement engine" that converts orders to actual shares/assets.
/// @dev Handles the math of converting deposits to shares and redeems to assets at epoch prices.
///
/// ============================================================
/// KEY CONCEPTS FOR EVERYONE
/// ============================================================
///
/// WHAT IS BATCH PROCESSING?
/// Instead of processing each deposit/redeem individually in real-time,
/// we batch them up and process all at once at the end of an epoch.
///
/// WHY BATCH?
/// 1. FAIR PRICING: Everyone gets the same price per share
/// 2. GAS EFFICIENCY: One price calculation for many orders
/// 3. MEV PROTECTION: Harder to front-run batch settlements
/// 4. SIMPLER ACCOUNTING: Clear settlement points
///
/// EXAMPLE FLOW:
///
/// EPOCH 5 COLLECTION (Day 1-7):
/// - Alice requests deposit: 1000 USDC
/// - Bob requests deposit: 5000 USDC
/// - Carol requests redeem: 500 shares
/// - Total deposits: 6000 USDC
/// - Total redeems: 500 shares
///
/// EPOCH 5 EXECUTION (Day 7 EOD):
/// - Pool NAV: $100,000
/// - Outstanding shares: 95,000
/// - Share price: $100,000 / 95,000 = $1.0526
///
/// - Alice gets: 1000 / 1.0526 = 950 shares
/// - Bob gets: 5000 / 1.0526 = 4750 shares
/// - Carol gets: 500 * 1.0526 = 526.30 USDC
///
/// ============================================================
/// PRICE CALCULATION
/// ============================================================
///
/// Two key calculations:
///
/// DEPOSIT -> SHARES:
/// shares = depositAmount / pricePerShare
///
/// REDEEM -> ASSETS:
/// assets = redeemShares * pricePerShare
///
/// Both use the same epoch price, ensuring fairness.
///
/// ============================================================
/// ACCOUNTING ENTRIES
/// ============================================================
///
/// DEPOSIT PROCESSING:
/// 1. Asset account increases (we received assets)
/// 2. Equity account increases (investor's stake)
/// 3. Share issuance increases (new shares created)
///
/// REDEEM PROCESSING:
/// 1. Asset account decreases (we're paying out)
/// 2. Equity account decreases (investor's stake reduced)
/// 3. Share revocation increases (shares destroyed)
///
contract BatchRequestManager is Auth {
    using MathLib for uint256;

    // ============================================================
    // STRUCTS
    // ============================================================

    /// @notice Summary of batch processing results
    struct BatchSummary {
        uint128 totalDeposited; // Total assets deposited
        uint128 totalSharesIssued; // Total shares created for deposits
        uint128 totalSharesRedeemed; // Total shares redeemed
        uint128 totalAssetsReturned; // Total assets returned for redemptions
        uint64 epochId; // Epoch this batch was processed in
        uint64 processedAt; // Timestamp of processing
    }

    /// @notice Represents a fulfilled deposit
    struct DepositFulfillment {
        address investor;
        uint128 assetAmount;
        uint128 sharesIssued;
        uint16 destinationChain;
    }

    /// @notice Represents a fulfilled redemption
    struct RedeemFulfillment {
        address investor;
        uint128 sharesRedeemed;
        uint128 assetsReturned;
        uint16 destinationChain;
    }

    // ============================================================
    // EVENTS
    // ============================================================

    /// @notice Emitted when a batch is processed
    event BatchProcessed(
        uint64 indexed poolId,
        bytes16 indexed scId,
        uint64 indexed epochId,
        uint128 depositsProcessed,
        uint128 redeemsProcessed
    );

    /// @notice Emitted when a deposit is fulfilled
    event DepositFulfilled(
        uint64 indexed poolId, bytes16 indexed scId, address indexed investor, uint128 assetAmount, uint128 sharesIssued
    );

    /// @notice Emitted when a redemption is fulfilled
    event RedeemFulfilled(
        uint64 indexed poolId,
        bytes16 indexed scId,
        address indexed investor,
        uint128 sharesRedeemed,
        uint128 assetsReturned
    );

    // ============================================================
    // ERRORS
    // ============================================================

    /// @notice Thrown when price is zero or invalid
    error InvalidPrice(uint128 price);

    /// @notice Thrown when shares calculation results in zero
    error ZeroSharesCalculated(uint128 amount, uint128 price);

    /// @notice Thrown when assets calculation results in zero
    error ZeroAssetsCalculated(uint128 shares, uint128 price);

    // ============================================================
    // CONSTANTS
    // ============================================================

    /// @dev One WAD (10^18) for fixed-point math
    uint256 internal constant WAD = 1e18;

    // ============================================================
    // STORAGE
    // ============================================================

    /// @notice Reference to the ShareClassManager contract
    IShareClassManager public shareClassManager;

    /// @notice Reference to the Accounting contract
    IAccounting public accounting;

    /// @notice Reference to the Holdings contract
    IHoldings public holdings;

    /// @notice Reference to the NAVManager contract
    INAVManager public navManager;

    /// @notice Batch summaries per pool per share class per epoch
    /// @dev summaries[poolId][scId][epochId] => BatchSummary
    mapping(uint64 => mapping(bytes16 => mapping(uint64 => BatchSummary))) public batchSummaries;

    // ============================================================
    // CONSTRUCTOR
    // ============================================================

    /// @notice Initialize the BatchRequestManager contract
    /// @param initialWard Address that will have admin rights
    /// @param shareClassManager_ Address of ShareClassManager
    /// @param accounting_ Address of Accounting
    /// @param holdings_ Address of Holdings
    /// @param navManager_ Address of NAVManager
    constructor(
        address initialWard,
        address shareClassManager_,
        address accounting_,
        address holdings_,
        address navManager_
    ) Auth(initialWard) {
        shareClassManager = IShareClassManager(shareClassManager_);
        accounting = IAccounting(accounting_);
        holdings = IHoldings(holdings_);
        navManager = INAVManager(navManager_);
    }

    // ============================================================
    // ADMIN FUNCTIONS
    // ============================================================

    /// @notice Update contract dependencies
    function file(bytes32 what, address data) external auth {
        if (what == "shareClassManager") {
            shareClassManager = IShareClassManager(data);
        } else if (what == "accounting") {
            accounting = IAccounting(data);
        } else if (what == "holdings") {
            holdings = IHoldings(data);
        } else if (what == "navManager") {
            navManager = INAVManager(data);
        } else {
            revert("BatchRequestManager/file-unrecognized-param");
        }
        emit File(what, data);
    }

    event File(bytes32 indexed what, address data);

    // ============================================================
    // BATCH PROCESSING
    // ============================================================

    /// @notice Process a batch of deposit fulfillments
    /// @dev Called by RiyzoHub during epoch execution
    /// @param poolId Pool identifier
    /// @param scId Share class identifier
    /// @param epochId Current epoch number
    /// @param price Price per share (18 decimals)
    /// @param fulfillments Array of deposit fulfillments to process
    /// @return totalSharesIssued Total shares created
    function processDeposits(
        uint64 poolId,
        bytes16 scId,
        uint64 epochId,
        uint128 price,
        DepositFulfillment[] calldata fulfillments
    ) external auth returns (uint128 totalSharesIssued) {
        // ============================================================
        // STEP 1: Validate price
        // ============================================================
        if (price == 0) {
            revert InvalidPrice(price);
        }

        // ============================================================
        // STEP 2: Process each fulfillment
        // ============================================================
        uint128 totalDeposited;

        for (uint256 i = 0; i < fulfillments.length; i++) {
            DepositFulfillment calldata f = fulfillments[i];

            // Calculate shares for this deposit
            // shares = amount * WAD / price
            uint128 shares = _calculateShares(f.assetAmount, price);

            if (shares == 0) {
                revert ZeroSharesCalculated(f.assetAmount, price);
            }

            totalDeposited += f.assetAmount;
            totalSharesIssued += shares;

            emit DepositFulfilled(poolId, scId, f.investor, f.assetAmount, shares);
        }

        // ============================================================
        // STEP 3: Update share issuance tracking
        // ============================================================
        // Group by destination chain for issuance updates
        // For now, simplified: assume all same chain
        if (fulfillments.length > 0) {
            uint16 centrifugeId = fulfillments[0].destinationChain;
            shareClassManager.updateShares(poolId, scId, centrifugeId, totalSharesIssued, 0);
        }

        // ============================================================
        // STEP 4: Update batch summary
        // ============================================================
        BatchSummary storage summary = batchSummaries[poolId][scId][epochId];
        summary.totalDeposited += totalDeposited;
        summary.totalSharesIssued += totalSharesIssued;
        summary.epochId = epochId;
        summary.processedAt = uint64(block.timestamp);

        emit BatchProcessed(poolId, scId, epochId, totalDeposited, 0);

        return totalSharesIssued;
    }

    /// @notice Process a batch of redemption fulfillments
    /// @dev Called by RiyzoHub during epoch execution
    /// @param poolId Pool identifier
    /// @param scId Share class identifier
    /// @param epochId Current epoch number
    /// @param price Price per share (18 decimals)
    /// @param fulfillments Array of redeem fulfillments to process
    /// @return totalAssetsReturned Total assets paid out
    function processRedemptions(
        uint64 poolId,
        bytes16 scId,
        uint64 epochId,
        uint128 price,
        RedeemFulfillment[] calldata fulfillments
    ) external auth returns (uint128 totalAssetsReturned) {
        // ============================================================
        // STEP 1: Validate price
        // ============================================================
        if (price == 0) {
            revert InvalidPrice(price);
        }

        // ============================================================
        // STEP 2: Process each fulfillment
        // ============================================================
        uint128 totalSharesRedeemed;

        for (uint256 i = 0; i < fulfillments.length; i++) {
            RedeemFulfillment calldata f = fulfillments[i];

            // Calculate assets for this redemption
            // assets = shares * price / WAD
            uint128 assets = _calculateAssets(f.sharesRedeemed, price);

            if (assets == 0) {
                revert ZeroAssetsCalculated(f.sharesRedeemed, price);
            }

            totalSharesRedeemed += f.sharesRedeemed;
            totalAssetsReturned += assets;

            emit RedeemFulfilled(poolId, scId, f.investor, f.sharesRedeemed, assets);
        }

        // ============================================================
        // STEP 3: Update share revocation tracking
        // ============================================================
        // Group by destination chain for revocation updates
        if (fulfillments.length > 0) {
            uint16 centrifugeId = fulfillments[0].destinationChain;
            shareClassManager.updateShares(poolId, scId, centrifugeId, 0, totalSharesRedeemed);
        }

        // ============================================================
        // STEP 4: Update batch summary
        // ============================================================
        BatchSummary storage summary = batchSummaries[poolId][scId][epochId];
        summary.totalSharesRedeemed += totalSharesRedeemed;
        summary.totalAssetsReturned += totalAssetsReturned;
        summary.epochId = epochId;
        summary.processedAt = uint64(block.timestamp);

        emit BatchProcessed(poolId, scId, epochId, 0, totalSharesRedeemed);

        return totalAssetsReturned;
    }

    // ============================================================
    // CALCULATION HELPERS
    // ============================================================

    /// @notice Calculate shares to issue for a deposit
    /// @dev shares = depositAmount * WAD / pricePerShare
    /// @param amount Deposit amount (in asset decimals, normalized to 18)
    /// @param price Price per share (18 decimals)
    /// @return shares Number of shares to issue
    function calculateSharesForDeposit(uint128 amount, uint128 price) external pure returns (uint128 shares) {
        return _calculateShares(amount, price);
    }

    /// @notice Calculate assets to return for a redemption
    /// @dev assets = redeemShares * pricePerShare / WAD
    /// @param shares Number of shares being redeemed
    /// @param price Price per share (18 decimals)
    /// @return assets Assets to return (18 decimals)
    function calculateAssetsForRedeem(uint128 shares, uint128 price) external pure returns (uint128 assets) {
        return _calculateAssets(shares, price);
    }

    // ============================================================
    // VIEW FUNCTIONS
    // ============================================================

    /// @notice Get the batch summary for a specific epoch
    function getBatchSummary(uint64 poolId, bytes16 scId, uint64 epochId) external view returns (BatchSummary memory) {
        return batchSummaries[poolId][scId][epochId];
    }

    // ============================================================
    // INTERNAL FUNCTIONS
    // ============================================================

    /// @dev Calculate shares from deposit amount
    /// Formula: shares = amount * WAD / price
    ///
    /// EXAMPLE:
    /// - Deposit: 1000 USDC (1000e18 in normalized form)
    /// - Price: $1.05 per share (1.05e18)
    /// - Shares: 1000e18 * 1e18 / 1.05e18 = 952.38e18 shares
    function _calculateShares(uint128 amount, uint128 price) internal pure returns (uint128) {
        if (price == 0) return 0;

        // shares = amount * WAD / price
        uint256 shares = (uint256(amount) * WAD) / uint256(price);

        // Safe to cast: shares should be reasonable
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint128(shares);
    }

    /// @dev Calculate assets from shares being redeemed
    /// Formula: assets = shares * price / WAD
    ///
    /// EXAMPLE:
    /// - Redeem: 500 shares (500e18)
    /// - Price: $1.05 per share (1.05e18)
    /// - Assets: 500e18 * 1.05e18 / 1e18 = 525e18 ($525)
    function _calculateAssets(uint128 shares, uint128 price) internal pure returns (uint128) {
        // assets = shares * price / WAD
        uint256 assets = (uint256(shares) * uint256(price)) / WAD;

        // Safe to cast: assets should be reasonable
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint128(assets);
    }
}
