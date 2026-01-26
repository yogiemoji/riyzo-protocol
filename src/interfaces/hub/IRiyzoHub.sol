// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.28;

import {IValuation} from "src/interfaces/hub/IValuation.sol";

/// @title IRiyzoHub - Central Hub Orchestrator Interface
/// @author Riyzo Protocol
/// @notice Interface for the main hub contract that orchestrates all pool operations.
///         Think of this as the "control center" that coordinates all other components.
/// @dev RiyzoHub is the primary entry point for pool management. It delegates to:
///      - RiyzoRegistry: Pool/asset registration
///      - ShareClassManager: Share class and pricing
///      - Holdings: Asset tracking
///      - Accounting: Double-entry bookkeeping
///      - NAVManager: NAV calculations
///
/// KEY RESPONSIBILITIES:
/// - Pool lifecycle (create, configure)
/// - Share class management
/// - Epoch coordination (collect orders, execute, settle)
/// - Cross-chain message handling
/// - Price broadcasting to spoke chains
///
/// EPOCH LIFECYCLE:
/// 1. COLLECT: Users submit deposit/redeem requests on spokes
/// 2. START: Admin calls startEpoch() - no new orders accepted
/// 3. EXECUTE: Admin calls executeEpoch() - match orders, calculate prices
/// 4. SETTLE: Fulfillment messages sent to spokes
///
/// EXAMPLE FLOW:
/// 1. createPool(USDC) - Creates pool with USDC as base currency
/// 2. addShareClass(poolId, "Senior", "SR") - Add senior tranche
/// 3. initializeHolding(poolId, scId, USDC) - Enable USDC deposits
/// 4. Users deposit on spokes, messages arrive via handleIncomingMessage()
/// 5. Admin calls executeEpoch() - processes all pending orders
/// 6. broadcastPrice() - sends new prices to all spoke chains
interface IRiyzoHub {
    // ============================================================
    // STRUCTS
    // ============================================================

    /// @notice Configuration for epoch execution
    struct EpochConfig {
        /// @notice Minimum time between epochs (seconds)
        uint64 minEpochDuration;
        /// @notice Whether epoch is currently open for orders
        bool isOpen;
        /// @notice Current epoch number
        uint64 currentEpoch;
        /// @notice Timestamp when current epoch started
        uint64 epochStartedAt;
    }

    // ============================================================
    // EVENTS
    // ============================================================

    /// @notice Emitted when a new pool is created
    event PoolCreated(uint64 indexed poolId, uint128 indexed currency, address indexed creator);

    /// @notice Emitted when a share class is added to a pool
    event ShareClassAdded(uint64 indexed poolId, bytes16 indexed scId, string name, string symbol);

    /// @notice Emitted when an epoch is started
    event EpochStarted(uint64 indexed poolId, uint64 indexed epochId, uint64 timestamp);

    /// @notice Emitted when an epoch is executed
    event EpochExecuted(uint64 indexed poolId, uint64 indexed epochId, uint64 timestamp);

    /// @notice Emitted when prices are broadcast to spokes
    event PriceBroadcast(uint64 indexed poolId, bytes16 indexed scId, uint128 price, uint16[] targetChains);

    /// @notice Emitted when a holding is initialized
    event HoldingInitialized(uint64 indexed poolId, bytes16 indexed scId, uint128 indexed assetId);

    /// @notice Emitted when an incoming message is processed
    event MessageProcessed(uint32 indexed sourceChain, bytes32 indexed messageId, uint8 messageType);

    // ============================================================
    // ERRORS
    // ============================================================

    /// @notice Thrown when pool doesn't exist
    error PoolNotFound(uint64 poolId);

    /// @notice Thrown when caller isn't authorized
    error Unauthorized(address caller);

    /// @notice Thrown when epoch is not in expected state
    error InvalidEpochState(uint64 poolId, bool expectedOpen);

    /// @notice Thrown when epoch duration hasn't elapsed
    error EpochTooShort(uint64 poolId, uint64 minDuration, uint64 elapsed);

    /// @notice Thrown when share class doesn't exist
    error ShareClassNotFound(uint64 poolId, bytes16 scId);

    /// @notice Thrown when holding isn't initialized
    error HoldingNotInitialized(uint64 poolId, bytes16 scId, uint128 assetId);

    /// @notice Thrown when message type is unknown
    error UnknownMessageType(uint8 messageType);

    // ============================================================
    // POOL LIFECYCLE
    // ============================================================

    /// @notice Create a new pool
    /// @dev Registers pool in registry, sets creator as manager.
    ///
    /// WHAT THIS DOES:
    /// - Generates chain-prefixed pool ID
    /// - Registers in RiyzoRegistry
    /// - Sets msg.sender as initial manager
    /// - Initializes epoch config
    ///
    /// @param currency Asset ID of pool's base currency (must be pre-registered)
    /// @return poolId The generated pool identifier
    function createPool(uint128 currency) external returns (uint64 poolId);

    /// @notice Add a share class to a pool
    /// @dev Creates share class in ShareClassManager and sets up for pricing.
    ///
    /// @param poolId Pool to add share class to
    /// @param name Human-readable name (e.g., "Senior Tranche")
    /// @param symbol Token symbol (e.g., "RIYZO-SR")
    /// @return scId The generated share class ID
    function addShareClass(uint64 poolId, string calldata name, string calldata symbol) external returns (bytes16 scId);

    // ============================================================
    // EPOCH MANAGEMENT
    // ============================================================

    /// @notice Start a new epoch (stop accepting new orders)
    /// @dev Called before executeEpoch to freeze order book.
    ///
    /// WHAT THIS DOES:
    /// - Marks epoch as closed (no new orders)
    /// - Records epoch start timestamp
    /// - Prepares for execution
    ///
    /// @param poolId Pool to start epoch for
    function startEpoch(uint64 poolId) external;

    /// @notice Execute the current epoch
    /// @dev Processes all pending orders at calculated prices.
    ///
    /// WHAT THIS DOES:
    /// 1. Calculates new NAV for each network
    /// 2. Determines share prices: price = NAV / totalSupply
    /// 3. Processes deposits: assets -> shares at epoch price
    /// 4. Processes redeems: shares -> assets at epoch price
    /// 5. Updates accounting entries
    /// 6. Sends fulfillment messages to spokes
    ///
    /// @param poolId Pool to execute epoch for
    function executeEpoch(uint64 poolId) external;

    /// @notice Get epoch configuration for a pool
    /// @param poolId Pool identifier
    /// @return config The EpochConfig struct
    function getEpochConfig(uint64 poolId) external view returns (EpochConfig memory config);

    // ============================================================
    // HOLDINGS MANAGEMENT
    // ============================================================

    /// @notice Initialize a holding for asset deposits
    /// @dev Sets up asset tracking and accounting linkage.
    ///
    /// @param poolId Pool identifier
    /// @param scId Share class identifier
    /// @param assetId Asset to enable deposits for
    /// @param valuation Pricing contract for this asset
    function initializeHolding(uint64 poolId, bytes16 scId, uint128 assetId, IValuation valuation) external;

    /// @notice Revalue a holding based on current prices
    /// @dev Queries valuation, updates holding value, records gain/loss.
    ///
    /// @param poolId Pool identifier
    /// @param scId Share class identifier
    /// @param assetId Asset to revalue
    /// @return isPositive True if value increased
    /// @return diff Absolute value of change
    function updateHoldingValue(uint64 poolId, bytes16 scId, uint128 assetId)
        external
        returns (bool isPositive, uint128 diff);

    // ============================================================
    // CROSS-CHAIN COORDINATION
    // ============================================================

    /// @notice Handle incoming message from spoke chain
    /// @dev Called by Gateway when messages arrive from adapters.
    ///      Routes to appropriate handler based on message type.
    ///
    /// MESSAGE TYPES HANDLED:
    /// - DepositRequest (20): Queue deposit order
    /// - RedeemRequest (21): Queue redeem order
    /// - CancelDepositRequest (24): Cancel pending deposit
    /// - CancelRedeemRequest (25): Cancel pending redeem
    ///
    /// @param sourceChain Originating chain ID
    /// @param payload Encoded message data
    function handleIncomingMessage(uint32 sourceChain, bytes calldata payload) external;

    /// @notice Broadcast price update to spoke chains
    /// @dev Sends UpdateTranchePrice message to specified networks.
    ///
    /// WHAT THIS DOES:
    /// - Gets current price from ShareClassManager
    /// - Encodes UpdateTranchePrice message
    /// - Sends via Gateway to each target chain
    ///
    /// @param poolId Pool identifier
    /// @param scId Share class identifier
    /// @param centrifugeIds Array of target network IDs
    function broadcastPrice(uint64 poolId, bytes16 scId, uint16[] calldata centrifugeIds) external;

    // ============================================================
    // VIEW FUNCTIONS
    // ============================================================

    /// @notice Calculate price for a share class
    /// @dev Price = NAV / Total Supply
    ///
    /// @param poolId Pool identifier
    /// @param scId Share class identifier
    /// @return price Price per share (18 decimals)
    function calculatePrice(uint64 poolId, bytes16 scId) external view returns (uint128 price);

    /// @notice Get the NAV for a pool on a specific network
    /// @param poolId Pool identifier
    /// @param centrifugeId Network identifier
    /// @return nav Net Asset Value (18 decimals)
    function getNetAssetValue(uint64 poolId, uint16 centrifugeId) external view returns (uint128 nav);

    /// @notice Get total NAV across all networks
    /// @param poolId Pool identifier
    /// @return totalNav Sum of NAV from all networks
    function getTotalNetAssetValue(uint64 poolId) external view returns (uint128 totalNav);

    /// @notice Check if caller is authorized for a pool
    /// @param poolId Pool identifier
    /// @param caller Address to check
    /// @return authorized True if caller is manager or ward
    function isAuthorized(uint64 poolId, address caller) external view returns (bool authorized);

    // ============================================================
    // COMPONENT ACCESSORS
    // ============================================================

    /// @notice Get the Registry contract address
    /// @return registry Address of RiyzoRegistry
    function registry() external view returns (address registry);

    /// @notice Get the ShareClassManager contract address
    /// @return scm Address of ShareClassManager
    function shareClassManager() external view returns (address scm);

    /// @notice Get the Holdings contract address
    /// @return holdings Address of Holdings
    function holdings() external view returns (address holdings);

    /// @notice Get the Accounting contract address
    /// @return accounting Address of Accounting
    function accounting() external view returns (address accounting);

    /// @notice Get the NAVManager contract address
    /// @return navManager Address of NAVManager
    function navManager() external view returns (address navManager);

    /// @notice Get the Gateway contract address
    /// @return gateway Address of Gateway for cross-chain messaging
    function gateway() external view returns (address gateway);
}
