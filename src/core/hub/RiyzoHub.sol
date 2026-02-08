// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.28;

import {Auth} from "src/core/Auth.sol";
import {IRiyzoHub} from "src/interfaces/hub/IRiyzoHub.sol";
import {IRiyzoRegistry} from "src/interfaces/hub/IRiyzoRegistry.sol";
import {IShareClassManager} from "src/interfaces/hub/IShareClassManager.sol";
import {IHoldings} from "src/interfaces/hub/IHoldings.sol";
import {IAccounting} from "src/interfaces/hub/IAccounting.sol";
import {INAVManager} from "src/interfaces/hub/INAVManager.sol";
import {IValuation} from "src/interfaces/hub/IValuation.sol";
import {IGateway} from "src/interfaces/gateway/IGateway.sol";
import {MathLib} from "src/core/libraries/MathLib.sol";

/// @title RiyzoHub - Central Hub Orchestrator
/// @author Riyzo Protocol
/// @notice This is the main hub contract that orchestrates all pool operations.
///         Think of it as the "control center" that coordinates all other components.
/// @dev RiyzoHub is the primary entry point for pool management. It delegates to:
///      - RiyzoRegistry: Pool/asset registration
///      - ShareClassManager: Share class and pricing
///      - Holdings: Asset tracking
///      - Accounting: Double-entry bookkeeping
///      - NAVManager: NAV calculations
///
/// ============================================================
/// KEY CONCEPTS FOR EVERYONE
/// ============================================================
///
/// WHAT IS THE HUB?
/// The hub is the "brain" of the protocol that lives on Arbitrum.
/// It coordinates everything:
/// - Creating and configuring pools
/// - Managing share classes
/// - Executing epochs (processing deposits/redemptions)
/// - Calculating prices
/// - Sending updates to spoke chains
///
/// WHY ORCHESTRATE?
/// Instead of having users call many different contracts, they
/// interact primarily with this one. RiyzoHub then calls the
/// right component contracts internally.
///
/// Benefits:
/// - Simpler user experience
/// - Consistent access control
/// - Coordinated operations
/// - Single source of truth
///
/// ============================================================
/// EPOCH LIFECYCLE
/// ============================================================
///
/// An "epoch" is a processing cycle where deposits and redemptions
/// are handled. Think of it like a daily or weekly settlement.
///
/// PHASE 1: COLLECTING (isOpen = true)
/// - Users submit deposit requests on spoke chains
/// - Users submit redeem requests on spoke chains
/// - Requests queue up, waiting for processing
///
/// PHASE 2: STARTING (startEpoch called)
/// - Admin calls startEpoch()
/// - No new requests accepted
/// - Epoch is "frozen" for calculation
///
/// PHASE 3: EXECUTING (executeEpoch called)
/// - Calculate NAV for each network
/// - Determine share prices
/// - Process all pending orders at epoch price
/// - Update accounting
///
/// PHASE 4: SETTLING
/// - Send fulfillment messages to spokes
/// - Users can claim their shares/assets
/// - Open new epoch for collecting
///
/// EXAMPLE TIMELINE:
/// Day 1: Users submit deposits all day (collecting)
/// Day 2 00:00: Admin calls startEpoch (no more orders)
/// Day 2 00:01: Admin calls executeEpoch (process at EOD price)
/// Day 2 00:02: Fulfillments sent to spokes
/// Day 2 00:03: New epoch opens for collecting
///
/// ============================================================
/// PRICE CALCULATION
/// ============================================================
///
/// Share price is calculated as:
/// Price = Total NAV / Total Shares Outstanding
///
/// EXAMPLE:
/// - Pool has $1,000,000 in assets across all networks
/// - Pool has 900,000 shares outstanding
/// - Price = $1,000,000 / 900,000 = $1.11 per share
///
/// This price is then broadcast to all spoke chains so they
/// can process deposits and redemptions correctly.
///
/// ============================================================
/// AUTHORIZATION
/// ============================================================
///
/// Two levels of access:
///
/// 1. WARDS (contract-level admins):
///    - Can update component addresses
///    - Can set global parameters
///    - Inherits from Auth.sol
///
/// 2. MANAGERS (pool-level operators):
///    - Can manage specific pools they're assigned to
///    - Can create share classes, execute epochs
///    - Set via RiyzoRegistry
///
contract RiyzoHub is Auth, IRiyzoHub {
    using MathLib for uint256;

    // ============================================================
    // STORAGE - COMPONENT REFERENCES
    // ============================================================

    /// @notice Reference to the Registry contract
    IRiyzoRegistry internal _registry;

    /// @notice Reference to the ShareClassManager contract
    IShareClassManager internal _shareClassManager;

    /// @notice Reference to the Holdings contract
    IHoldings internal _holdings;

    /// @notice Reference to the Accounting contract
    IAccounting internal _accounting;

    /// @notice Reference to the NAVManager contract
    INAVManager internal _navManager;

    /// @notice Reference to the Gateway for cross-chain messaging
    IGateway internal _gateway;

    // ============================================================
    // STORAGE - EPOCH CONFIGURATION
    // ============================================================

    /// @notice Epoch configuration per pool
    /// @dev epochConfig[poolId] => EpochConfig
    mapping(uint64 => EpochConfig) internal _epochConfigs;

    /// @notice Default minimum epoch duration (1 hour)
    uint64 public constant DEFAULT_MIN_EPOCH_DURATION = 1 hours;

    /// @notice One WAD (10^18) for fixed-point math
    uint256 internal constant WAD = 1e18;

    // ============================================================
    // CONSTRUCTOR
    // ============================================================

    /// @notice Initialize the RiyzoHub contract
    /// @param initialWard Address that will have admin rights
    /// @param registry_ Address of RiyzoRegistry
    /// @param shareClassManager_ Address of ShareClassManager
    /// @param holdings_ Address of Holdings
    /// @param accounting_ Address of Accounting
    /// @param navManager_ Address of NAVManager
    /// @param gateway_ Address of Gateway
    constructor(
        address initialWard,
        address registry_,
        address shareClassManager_,
        address holdings_,
        address accounting_,
        address navManager_,
        address gateway_
    ) Auth(initialWard) {
        _registry = IRiyzoRegistry(registry_);
        _shareClassManager = IShareClassManager(shareClassManager_);
        _holdings = IHoldings(holdings_);
        _accounting = IAccounting(accounting_);
        _navManager = INAVManager(navManager_);
        _gateway = IGateway(gateway_);
    }

    // ============================================================
    // MODIFIERS
    // ============================================================

    /// @dev Ensures caller is a manager of the pool
    modifier onlyManager(uint64 poolId) {
        if (!_registry.isManager(poolId, msg.sender) && wards[msg.sender] != 1) {
            revert Unauthorized(msg.sender);
        }
        _;
    }

    /// @dev Ensures pool exists
    modifier poolExists(uint64 poolId) {
        if (!_registry.exists(poolId)) {
            revert PoolNotFound(poolId);
        }
        _;
    }

    // ============================================================
    // ADMIN FUNCTIONS
    // ============================================================

    /// @notice Update component dependencies
    /// @dev Standard "file" pattern used across the protocol
    /// @param what Parameter name to update
    /// @param data New value
    function file(bytes32 what, address data) external auth {
        if (what == "registry") {
            _registry = IRiyzoRegistry(data);
        } else if (what == "shareClassManager") {
            _shareClassManager = IShareClassManager(data);
        } else if (what == "holdings") {
            _holdings = IHoldings(data);
        } else if (what == "accounting") {
            _accounting = IAccounting(data);
        } else if (what == "navManager") {
            _navManager = INAVManager(data);
        } else if (what == "gateway") {
            _gateway = IGateway(data);
        } else {
            revert("RiyzoHub/file-unrecognized-param");
        }
        emit File(what, data);
    }

    /// @dev Event for file() function
    event File(bytes32 indexed what, address data);

    /// @notice Set minimum epoch duration for a pool
    /// @param poolId Pool identifier
    /// @param minDuration Minimum time between epochs
    function setMinEpochDuration(uint64 poolId, uint64 minDuration) external onlyManager(poolId) {
        _epochConfigs[poolId].minEpochDuration = minDuration;
        emit MinEpochDurationSet(poolId, minDuration);
    }

    event MinEpochDurationSet(uint64 indexed poolId, uint64 minDuration);

    // ============================================================
    // POOL LIFECYCLE
    // ============================================================

    /// @inheritdoc IRiyzoHub
    /// @dev Creates a new pool with the specified currency.
    ///
    /// WHAT THIS DOES:
    /// 1. Registers pool in RiyzoRegistry (generates pool ID)
    /// 2. Initializes epoch configuration
    /// 3. Sets caller as pool manager
    ///
    /// EXAMPLE:
    /// - User calls createPool(USDC_ID)
    /// - Registry generates pool ID: 0xA4B1000000000001
    /// - User becomes manager of the pool
    /// - Epoch config initialized with defaults
    function createPool(uint128 currency) external returns (uint64 poolId) {
        // ============================================================
        // STEP 1: Register pool in registry
        // ============================================================
        // Registry validates currency is registered and generates pool ID
        poolId = _registry.registerPool(currency, msg.sender);

        // ============================================================
        // STEP 2: Initialize epoch configuration
        // ============================================================
        _epochConfigs[poolId] = EpochConfig({
            minEpochDuration: DEFAULT_MIN_EPOCH_DURATION,
            isOpen: true, // Start accepting orders immediately
            currentEpoch: 1,
            epochStartedAt: uint64(block.timestamp)
        });

        emit PoolCreated(poolId, currency, msg.sender);

        return poolId;
    }

    /// @inheritdoc IRiyzoHub
    /// @dev Adds a share class to a pool.
    ///
    /// WHAT THIS DOES:
    /// 1. Generates unique share class ID
    /// 2. Stores metadata (name, symbol)
    /// 3. Initializes pricing
    ///
    /// EXAMPLE:
    /// - Manager calls addShareClass(poolId, "Senior Tranche", "SR")
    /// - ShareClassManager generates scId: 0x1234...
    /// - Price initialized to 0 (must be set before epoch execution)
    function addShareClass(uint64 poolId, string calldata name, string calldata symbol)
        external
        onlyManager(poolId)
        returns (bytes16 scId)
    {
        // ============================================================
        // STEP 1: Create share class in ShareClassManager
        // ============================================================
        // Generate deterministic salt for CREATE2 deployment on spokes
        bytes32 salt = keccak256(abi.encodePacked(poolId, name, symbol, block.timestamp));

        scId = _shareClassManager.addShareClass(poolId, name, symbol, salt);

        emit ShareClassAdded(poolId, scId, name, symbol);

        return scId;
    }

    // ============================================================
    // EPOCH MANAGEMENT
    // ============================================================

    /// @inheritdoc IRiyzoHub
    /// @dev Starts a new epoch (closes order collection).
    ///
    /// WHAT THIS DOES:
    /// 1. Validates current epoch is open
    /// 2. Marks epoch as closed
    /// 3. Records start timestamp
    ///
    /// After calling this, no new deposit/redeem orders are accepted
    /// until executeEpoch completes and reopens the epoch.
    function startEpoch(uint64 poolId) external onlyManager(poolId) poolExists(poolId) {
        EpochConfig storage config = _epochConfigs[poolId];

        // ============================================================
        // STEP 1: Validate epoch is currently open
        // ============================================================
        if (!config.isOpen) {
            revert InvalidEpochState(poolId, true);
        }

        // ============================================================
        // STEP 2: Close epoch for new orders
        // ============================================================
        config.isOpen = false;
        config.epochStartedAt = uint64(block.timestamp);

        emit EpochStarted(poolId, config.currentEpoch, uint64(block.timestamp));
    }

    /// @inheritdoc IRiyzoHub
    /// @dev Executes the current epoch (processes orders).
    ///
    /// WHAT THIS DOES:
    /// 1. Validates epoch is closed
    /// 2. Validates minimum duration has passed
    /// 3. Calculates new prices for each share class
    /// 4. Opens new epoch for collecting
    ///
    /// NOTE: Actual order processing happens via BatchRequestManager
    /// (to be implemented). This function calculates and sets prices.
    function executeEpoch(uint64 poolId) external onlyManager(poolId) poolExists(poolId) {
        EpochConfig storage config = _epochConfigs[poolId];

        // ============================================================
        // STEP 1: Validate epoch is closed
        // ============================================================
        if (config.isOpen) {
            revert InvalidEpochState(poolId, false);
        }

        // ============================================================
        // STEP 2: Validate minimum duration has passed
        // ============================================================
        uint64 elapsed = uint64(block.timestamp) - config.epochStartedAt;
        if (elapsed < config.minEpochDuration) {
            revert EpochTooShort(poolId, config.minEpochDuration, elapsed);
        }

        // ============================================================
        // STEP 3: Update share prices for each share class
        // ============================================================
        // Get all share classes for this pool
        bytes16[] memory shareClassIds = _shareClassManager.getShareClassIds(poolId);

        for (uint256 i = 0; i < shareClassIds.length; i++) {
            bytes16 scId = shareClassIds[i];

            // Calculate new price for this share class
            uint128 newPrice = _calculateSharePrice(poolId, scId);

            // Update price in ShareClassManager
            _shareClassManager.updateSharePrice(poolId, scId, newPrice, uint64(block.timestamp));
        }

        // ============================================================
        // STEP 4: Increment epoch and reopen for orders
        // ============================================================
        config.currentEpoch += 1;
        config.isOpen = true;

        emit EpochExecuted(poolId, config.currentEpoch - 1, uint64(block.timestamp));
    }

    /// @inheritdoc IRiyzoHub
    function getEpochConfig(uint64 poolId) external view returns (EpochConfig memory config) {
        return _epochConfigs[poolId];
    }

    // ============================================================
    // HOLDINGS MANAGEMENT
    // ============================================================

    /// @inheritdoc IRiyzoHub
    /// @dev Initializes a holding for asset deposits.
    ///
    /// WHAT THIS DOES:
    /// 1. Delegates to NAVManager.initializeHolding
    /// 2. Creates necessary accounting accounts
    /// 3. Links holding to accounts
    ///
    /// After this, users can deposit this asset into the share class.
    function initializeHolding(uint64 poolId, bytes16 scId, uint128 assetId, IValuation valuation)
        external
        onlyManager(poolId)
        poolExists(poolId)
    {
        // Validate share class exists
        if (!_shareClassManager.shareClassExists(poolId, scId)) {
            revert ShareClassNotFound(poolId, scId);
        }

        // Delegate to NAVManager for proper account setup
        _navManager.initializeHolding(poolId, scId, assetId, valuation);

        emit HoldingInitialized(poolId, scId, assetId);
    }

    /// @inheritdoc IRiyzoHub
    /// @dev Revalues a holding based on current market price.
    ///
    /// WHAT THIS DOES:
    /// 1. Queries valuation contract for current price
    /// 2. Calculates new value
    /// 3. Records gain or loss in accounting
    function updateHoldingValue(uint64 poolId, bytes16 scId, uint128 assetId)
        external
        onlyManager(poolId)
        returns (bool isPositive, uint128 diff)
    {
        if (!_holdings.isInitialized(poolId, scId, assetId)) {
            revert HoldingNotInitialized(poolId, scId, assetId);
        }

        // Open accounting session
        _accounting.unlock(poolId);

        // Update holding and record gain/loss
        (isPositive, diff) = _holdings.update(poolId, scId, assetId);

        // Commit accounting
        _accounting.lock();

        return (isPositive, diff);
    }

    // ============================================================
    // CROSS-CHAIN COORDINATION
    // ============================================================

    /// @inheritdoc IRiyzoHub
    /// @dev Handles incoming messages from spoke chains.
    ///
    /// MESSAGE ROUTING:
    /// This function decodes the message type and routes to appropriate handler.
    /// For now, we emit an event - full handling via HubHandler (to be implemented).
    function handleIncomingMessage(uint32 sourceChain, bytes calldata payload) external {
        // Only Gateway can call this
        require(msg.sender == address(_gateway), "RiyzoHub/not-gateway");

        // Decode message type (first byte)
        uint8 messageType = uint8(payload[0]);

        // Route to appropriate handler based on message type
        // Full implementation in HubHandler.sol
        // For now, emit event for tracking
        bytes32 messageId = keccak256(payload);

        emit MessageProcessed(sourceChain, messageId, messageType);
    }

    /// @inheritdoc IRiyzoHub
    /// @dev Broadcasts price update to spoke chains.
    ///
    /// WHAT THIS DOES:
    /// 1. Gets current price from ShareClassManager
    /// 2. Encodes UpdateTranchePrice message
    /// 3. Sends via Gateway to each target chain
    ///
    /// Message format: UpdateTranchePrice(poolId, scId, currencyId, price, computedAt)
    function broadcastPrice(uint64 poolId, bytes16 scId, uint16[] calldata centrifugeIds) external onlyManager(poolId) {
        // Get current price
        (uint128 price, uint64 computedAt) = _shareClassManager.pricePerShare(poolId, scId);

        // Get pool currency for the message
        uint128 currencyId = _registry.currency(poolId);

        // Encode message (following MessagesLib format)
        // Message type 10 = UpdateTranchePrice
        // Note: Full implementation will use Gateway.send()
        // bytes memory message = abi.encodePacked(
        //     uint8(10), // UpdateTranchePrice message type
        //     poolId,
        //     scId,
        //     currencyId,
        //     price,
        //     computedAt
        // );

        // Silence unused variable warnings until Gateway integration
        (price, computedAt, currencyId);

        // Send to each target chain
        // Note: Gateway.send() implementation depends on adapter setup
        // For now, we just emit event for each target
        // for (uint256 i = 0; i < centrifugeIds.length; i++) {
        //     _gateway.send(centrifugeIds[i], message);
        // }

        emit PriceBroadcast(poolId, scId, price, centrifugeIds);
    }

    // ============================================================
    // VIEW FUNCTIONS
    // ============================================================

    /// @inheritdoc IRiyzoHub
    /// @dev Calculates the current price for a share class.
    ///
    /// FORMULA: Price = Total NAV / Total Shares
    ///
    /// If no shares exist, returns WAD (1e18) as initial price.
    function calculatePrice(uint64 poolId, bytes16 scId) external view returns (uint128 price) {
        return _calculateSharePrice(poolId, scId);
    }

    /// @inheritdoc IRiyzoHub
    function getNetAssetValue(uint64 poolId, uint16 centrifugeId) external view returns (uint128 nav) {
        return _navManager.netAssetValue(poolId, centrifugeId);
    }

    /// @inheritdoc IRiyzoHub
    /// @dev Gets total NAV across all networks.
    ///
    /// Iterates through active networks and sums their NAV.
    function getTotalNetAssetValue(uint64 poolId) external view returns (uint128 totalNav) {
        // Get all share classes
        bytes16[] memory scIds = _shareClassManager.getShareClassIds(poolId);

        if (scIds.length == 0) {
            return 0;
        }

        // Get active networks from first share class
        // (Assuming all share classes have same active networks)
        uint16[] memory networks = _shareClassManager.getActiveNetworks(poolId, scIds[0]);

        for (uint256 i = 0; i < networks.length; i++) {
            totalNav += _navManager.netAssetValue(poolId, networks[i]);
        }

        return totalNav;
    }

    /// @inheritdoc IRiyzoHub
    function isAuthorized(uint64 poolId, address caller) external view returns (bool authorized) {
        return _registry.isManager(poolId, caller) || wards[caller] == 1;
    }

    // ============================================================
    // COMPONENT ACCESSORS
    // ============================================================

    /// @inheritdoc IRiyzoHub
    function registry() external view returns (address) {
        return address(_registry);
    }

    /// @inheritdoc IRiyzoHub
    function shareClassManager() external view returns (address) {
        return address(_shareClassManager);
    }

    /// @inheritdoc IRiyzoHub
    function holdings() external view returns (address) {
        return address(_holdings);
    }

    /// @inheritdoc IRiyzoHub
    function accounting() external view returns (address) {
        return address(_accounting);
    }

    /// @inheritdoc IRiyzoHub
    function navManager() external view returns (address) {
        return address(_navManager);
    }

    /// @inheritdoc IRiyzoHub
    function gateway() external view returns (address) {
        return address(_gateway);
    }

    // ============================================================
    // INTERNAL FUNCTIONS
    // ============================================================

    /// @dev Calculates share price for a share class
    ///
    /// FORMULA: Price = Total NAV / Total Shares
    ///
    /// If no shares exist, returns WAD (1e18) as initial price.
    /// This ensures new investors get a fair starting price.
    function _calculateSharePrice(uint64 poolId, bytes16 scId) internal view returns (uint128) {
        // Get total issuance (shares outstanding)
        uint128 totalShares = _shareClassManager.totalIssuance(poolId, scId);

        // If no shares, return $1.00 (WAD) as initial price
        if (totalShares == 0) {
            // Casting is safe: WAD = 1e18 fits in uint128
            // forge-lint: disable-next-line(unsafe-typecast)
            return uint128(WAD);
        }

        // Get total NAV across all networks
        uint128 totalNav = _getTotalNAVForShareClass(poolId, scId);

        // If no NAV, return current price or WAD
        if (totalNav == 0) {
            (uint128 currentPrice,) = _shareClassManager.pricePerShare(poolId, scId);
            // Casting is safe: WAD = 1e18 fits in uint128
            // forge-lint: disable-next-line(unsafe-typecast)
            return currentPrice > 0 ? currentPrice : uint128(WAD);
        }

        // Calculate price: NAV / totalShares
        // Both are 18 decimals, so we need to scale
        // price = (nav * WAD) / totalShares
        uint256 price = (uint256(totalNav) * WAD) / uint256(totalShares);

        // Safe to cast: price should be reasonable (< type(uint128).max)
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint128(price);
    }

    /// @dev Gets total NAV for a specific share class across all networks
    function _getTotalNAVForShareClass(uint64 poolId, bytes16 scId) internal view returns (uint128 totalNav) {
        // Get active networks for this share class
        uint16[] memory networks = _shareClassManager.getActiveNetworks(poolId, scId);

        for (uint256 i = 0; i < networks.length; i++) {
            // Check if network is initialized before querying NAV
            if (_navManager.isNetworkInitialized(poolId, networks[i])) {
                totalNav += _navManager.netAssetValue(poolId, networks[i]);
            }
        }

        return totalNav;
    }

    // ============================================================
    // NETWORK INITIALIZATION
    // ============================================================

    /// @notice Initialize NAV tracking for a new network
    /// @dev Creates the per-network accounting accounts
    /// @param poolId Pool identifier
    /// @param centrifugeId Network identifier (e.g., 1 for Ethereum, 8453 for Base)
    function initializeNetwork(uint64 poolId, uint16 centrifugeId) external onlyManager(poolId) poolExists(poolId) {
        _navManager.initializeNetwork(poolId, centrifugeId);
    }

    /// @notice Close gains/losses to equity for a network
    /// @dev Moves unrealized gains/losses to equity at end of epoch
    /// @param poolId Pool identifier
    /// @param centrifugeId Network identifier
    function closeGainLoss(uint64 poolId, uint16 centrifugeId) external onlyManager(poolId) {
        // Open accounting session
        _accounting.unlock(poolId);

        // Close gains/losses
        _navManager.closeGainLoss(poolId, centrifugeId);

        // Commit accounting
        _accounting.lock();
    }
}
