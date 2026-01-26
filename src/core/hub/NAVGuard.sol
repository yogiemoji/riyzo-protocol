// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.28;

import {Auth} from "src/core/Auth.sol";
import {IShareClassManager} from "src/interfaces/hub/IShareClassManager.sol";
import {INAVManager} from "src/interfaces/hub/INAVManager.sol";
import {IValuation} from "src/interfaces/hub/IValuation.sol";
import {MathLib} from "src/core/libraries/MathLib.sol";

/// @title NAVGuard - NAV Safety Mechanisms
/// @author Riyzo Protocol
/// @notice This contract provides safety checks and limits for NAV updates.
///         Think of it as a "circuit breaker" that prevents manipulation.
/// @dev Implements configurable limits on price movements and staleness checks.
///
/// ============================================================
/// KEY CONCEPTS FOR EVERYONE
/// ============================================================
///
/// WHY DO WE NEED NAV GUARDS?
/// NAV (Net Asset Value) determines share prices. If NAV is manipulated,
/// bad actors could:
/// - Inflate NAV before redemption (steal from pool)
/// - Deflate NAV before deposit (get more shares than deserved)
/// - Use stale prices to exploit time differences
///
/// WHAT GUARDS DO WE HAVE?
///
/// 1. PRICE MOVEMENT LIMITS
///    - Maximum % change per epoch
///    - Prevents sudden large swings
///    - Example: Max 10% change per day
///
/// 2. STALENESS CHECKS
///    - Valuations must be recent
///    - Prevents using outdated prices
///    - Example: Max 1 hour old
///
/// 3. DEVIATION ALERTS
///    - Warn when NAV differs significantly from expected
///    - Helps catch bugs or manipulation early
///    - Example: Alert if > 5% from previous epoch
///
/// 4. PAUSE CAPABILITY
///    - Can halt operations if anomalies detected
///    - Gives time to investigate issues
///    - Requires multisig/timelock to unpause
///
/// ============================================================
/// PRICE MOVEMENT LIMITS
/// ============================================================
///
/// Each pool/share class has a maximum allowed price change per epoch.
/// If the new price exceeds this limit, the transaction reverts.
///
/// FORMULA:
/// priceChange = |newPrice - oldPrice| / oldPrice * 10000
/// If priceChange > maxBps, REVERT
///
/// EXAMPLE:
/// - Old price: $1.00
/// - New price: $1.15
/// - Change: 15% = 1500 bps
/// - Max allowed: 1000 bps (10%)
/// - Result: REVERTS (15% > 10%)
///
/// WHY BPS (BASIS POINTS)?
/// - 1 bps = 0.01%
/// - 100 bps = 1%
/// - 1000 bps = 10%
/// - More precise than percentages for small changes
///
/// ============================================================
/// STALENESS CHECKS
/// ============================================================
///
/// Valuation prices must be updated within a certain time window.
/// Stale prices could be exploited by traders with newer information.
///
/// EXAMPLE:
/// - ETH price updated 2 hours ago
/// - Max staleness: 1 hour
/// - Result: Valuation is STALE, cannot use for NAV
///
/// ============================================================
/// EMERGENCY CONTROLS
/// ============================================================
///
/// If a pool is paused:
/// - No new deposits/redeems accepted
/// - No epoch execution
/// - Price updates blocked
/// - Holdings cannot be modified
///
/// Pause can be triggered by:
/// - Authorized guardian addresses
/// - Automatic circuit breakers (if implemented)
///
contract NAVGuard is Auth {
    using MathLib for uint256;

    // ============================================================
    // STRUCTS
    // ============================================================

    /// @notice Configuration for NAV guards per pool
    struct GuardConfig {
        /// @notice Maximum price change in basis points (1 bps = 0.01%)
        /// Example: 1000 = 10% max change
        uint16 maxPriceChangeBps;

        /// @notice Maximum allowed staleness for valuations (seconds)
        /// Example: 3600 = 1 hour
        uint64 maxStalenessSeconds;

        /// @notice Whether this pool is paused
        bool isPaused;

        /// @notice Whether price limits are enforced
        bool enforceLimits;
    }

    /// @notice Record of a price validation
    struct PriceValidation {
        uint128 oldPrice;
        uint128 newPrice;
        uint16 changeBps;
        bool passed;
        uint64 validatedAt;
    }

    // ============================================================
    // EVENTS
    // ============================================================

    /// @notice Emitted when guard config is updated
    event GuardConfigUpdated(
        uint64 indexed poolId, uint16 maxPriceChangeBps, uint64 maxStalenessSeconds, bool enforceLimits
    );

    /// @notice Emitted when a pool is paused
    event PoolPaused(uint64 indexed poolId, address indexed pausedBy);

    /// @notice Emitted when a pool is unpaused
    event PoolUnpaused(uint64 indexed poolId, address indexed unpausedBy);

    /// @notice Emitted when a price validation fails
    event PriceValidationFailed(
        uint64 indexed poolId, bytes16 indexed scId, uint128 oldPrice, uint128 newPrice, uint16 changeBps
    );

    /// @notice Emitted when a valuation is deemed stale
    event StaleValuation(uint64 indexed poolId, bytes16 indexed scId, uint128 indexed assetId, uint64 lastUpdated);

    /// @notice Emitted when price is validated successfully
    event PriceValidated(uint64 indexed poolId, bytes16 indexed scId, uint128 price, uint16 changeBps);

    // ============================================================
    // ERRORS
    // ============================================================

    /// @notice Thrown when price change exceeds maximum allowed
    error PriceChangeExceedsLimit(uint64 poolId, bytes16 scId, uint16 changeBps, uint16 maxBps);

    /// @notice Thrown when valuation is too stale
    error ValuationTooStale(uint64 poolId, bytes16 scId, uint128 assetId, uint64 age, uint64 maxAge);

    /// @notice Thrown when pool is paused
    error PoolIsPaused(uint64 poolId);

    /// @notice Thrown when trying to unpause a pool that isn't paused
    error PoolNotPaused(uint64 poolId);

    // ============================================================
    // CONSTANTS
    // ============================================================

    /// @notice Maximum basis points (100%)
    uint16 public constant MAX_BPS = 10000;

    /// @notice Default max price change (10%)
    uint16 public constant DEFAULT_MAX_PRICE_CHANGE_BPS = 1000;

    /// @notice Default max staleness (1 hour)
    uint64 public constant DEFAULT_MAX_STALENESS = 1 hours;

    // ============================================================
    // STORAGE
    // ============================================================

    /// @notice Guard configuration per pool
    mapping(uint64 => GuardConfig) public guardConfigs;

    /// @notice Last validated price per pool per share class
    mapping(uint64 => mapping(bytes16 => uint128)) public lastValidatedPrice;

    /// @notice Guardian addresses that can pause pools
    mapping(address => bool) public guardians;

    /// @notice Reference to ShareClassManager for price lookups
    IShareClassManager public shareClassManager;

    /// @notice Reference to NAVManager for NAV calculations
    INAVManager public navManager;

    // ============================================================
    // CONSTRUCTOR
    // ============================================================

    /// @notice Initialize the NAVGuard contract
    /// @param initialWard Address that will have admin rights
    /// @param shareClassManager_ Address of ShareClassManager
    /// @param navManager_ Address of NAVManager
    constructor(address initialWard, address shareClassManager_, address navManager_) Auth(initialWard) {
        shareClassManager = IShareClassManager(shareClassManager_);
        navManager = INAVManager(navManager_);
    }

    // ============================================================
    // ADMIN FUNCTIONS
    // ============================================================

    /// @notice Update contract dependencies
    function file(bytes32 what, address data) external auth {
        if (what == "shareClassManager") {
            shareClassManager = IShareClassManager(data);
        } else if (what == "navManager") {
            navManager = INAVManager(data);
        } else {
            revert("NAVGuard/file-unrecognized-param");
        }
        emit File(what, data);
    }

    event File(bytes32 indexed what, address data);

    /// @notice Add or remove a guardian
    /// @param guardian Address to update
    /// @param isActive Whether address should be guardian
    function updateGuardian(address guardian, bool isActive) external auth {
        guardians[guardian] = isActive;
        emit GuardianUpdated(guardian, isActive);
    }

    event GuardianUpdated(address indexed guardian, bool isGuardian);

    /// @notice Configure guards for a pool
    /// @param poolId Pool identifier
    /// @param maxPriceChangeBps Maximum price change in bps
    /// @param maxStalenessSeconds Maximum valuation age
    /// @param enforceLimits Whether to enforce limits
    function configureGuard(uint64 poolId, uint16 maxPriceChangeBps, uint64 maxStalenessSeconds, bool enforceLimits)
        external
        auth
    {
        require(maxPriceChangeBps <= MAX_BPS, "NAVGuard/invalid-bps");

        guardConfigs[poolId] = GuardConfig({
            maxPriceChangeBps: maxPriceChangeBps,
            maxStalenessSeconds: maxStalenessSeconds,
            isPaused: guardConfigs[poolId].isPaused, // Preserve pause state
            enforceLimits: enforceLimits
        });

        emit GuardConfigUpdated(poolId, maxPriceChangeBps, maxStalenessSeconds, enforceLimits);
    }

    // ============================================================
    // PAUSE FUNCTIONS
    // ============================================================

    /// @notice Pause a pool (emergency)
    /// @dev Can be called by guardians or wards
    /// @param poolId Pool to pause
    function pause(uint64 poolId) external {
        require(guardians[msg.sender] || wards[msg.sender] == 1, "NAVGuard/not-guardian");

        guardConfigs[poolId].isPaused = true;

        emit PoolPaused(poolId, msg.sender);
    }

    /// @notice Unpause a pool
    /// @dev Only wards can unpause (more restrictive than pause)
    /// @param poolId Pool to unpause
    function unpause(uint64 poolId) external auth {
        if (!guardConfigs[poolId].isPaused) {
            revert PoolNotPaused(poolId);
        }

        guardConfigs[poolId].isPaused = false;

        emit PoolUnpaused(poolId, msg.sender);
    }

    // ============================================================
    // VALIDATION FUNCTIONS
    // ============================================================

    /// @notice Validate a new price against limits
    /// @dev Called before setting new share prices
    /// @param poolId Pool identifier
    /// @param scId Share class identifier
    /// @param newPrice Proposed new price
    /// @return valid True if price passes validation
    /// @return changeBps The calculated change in basis points
    function validatePrice(uint64 poolId, bytes16 scId, uint128 newPrice)
        external
        returns (bool valid, uint16 changeBps)
    {
        // Check if pool is paused
        if (guardConfigs[poolId].isPaused) {
            revert PoolIsPaused(poolId);
        }

        // Get configuration
        GuardConfig storage config = guardConfigs[poolId];

        // If limits not enforced, always valid
        if (!config.enforceLimits) {
            lastValidatedPrice[poolId][scId] = newPrice;
            emit PriceValidated(poolId, scId, newPrice, 0);
            return (true, 0);
        }

        // Get last validated price
        uint128 oldPrice = lastValidatedPrice[poolId][scId];

        // If no previous price, accept any (first price)
        if (oldPrice == 0) {
            lastValidatedPrice[poolId][scId] = newPrice;
            emit PriceValidated(poolId, scId, newPrice, 0);
            return (true, 0);
        }

        // Calculate price change in basis points
        changeBps = _calculateChangeBps(oldPrice, newPrice);

        // Check against limit
        uint16 maxBps = config.maxPriceChangeBps;
        if (maxBps == 0) {
            maxBps = DEFAULT_MAX_PRICE_CHANGE_BPS;
        }

        if (changeBps > maxBps) {
            emit PriceValidationFailed(poolId, scId, oldPrice, newPrice, changeBps);
            revert PriceChangeExceedsLimit(poolId, scId, changeBps, maxBps);
        }

        // Update last validated price
        lastValidatedPrice[poolId][scId] = newPrice;

        emit PriceValidated(poolId, scId, newPrice, changeBps);

        return (true, changeBps);
    }

    /// @notice Check if a valuation is stale
    /// @param poolId Pool identifier
    /// @param scId Share class identifier
    /// @param assetId Asset identifier
    /// @param valuation Valuation contract to check
    /// @return isStale True if valuation is too old
    /// @return age Age of the valuation in seconds
    function checkStaleness(uint64 poolId, bytes16 scId, uint128 assetId, IValuation valuation)
        external
        view
        returns (bool isStale, uint64 age)
    {
        // Get last updated timestamp from valuation
        uint64 lastUpdated = valuation.lastUpdated(poolId, scId, assetId);

        // Calculate age
        // forge-lint: disable-next-line(unsafe-typecast)
        age = uint64(block.timestamp) - lastUpdated;

        // Get max staleness
        GuardConfig storage config = guardConfigs[poolId];
        uint64 maxStaleness = config.maxStalenessSeconds;
        if (maxStaleness == 0) {
            maxStaleness = DEFAULT_MAX_STALENESS;
        }

        isStale = age > maxStaleness;

        return (isStale, age);
    }

    /// @notice Validate valuation is not stale (reverts if stale)
    /// @param poolId Pool identifier
    /// @param scId Share class identifier
    /// @param assetId Asset identifier
    /// @param valuation Valuation contract to check
    function requireFreshValuation(uint64 poolId, bytes16 scId, uint128 assetId, IValuation valuation) external view {
        // Get last updated timestamp
        uint64 lastUpdated = valuation.lastUpdated(poolId, scId, assetId);

        // Calculate age
        // forge-lint: disable-next-line(unsafe-typecast)
        uint64 age = uint64(block.timestamp) - lastUpdated;

        // Get max staleness
        GuardConfig storage config = guardConfigs[poolId];
        uint64 maxStaleness = config.maxStalenessSeconds;
        if (maxStaleness == 0) {
            maxStaleness = DEFAULT_MAX_STALENESS;
        }

        if (age > maxStaleness) {
            revert ValuationTooStale(poolId, scId, assetId, age, maxStaleness);
        }
    }

    // ============================================================
    // VIEW FUNCTIONS
    // ============================================================

    /// @notice Check if a pool is paused
    function isPaused(uint64 poolId) external view returns (bool) {
        return guardConfigs[poolId].isPaused;
    }

    /// @notice Check if an address is a guardian
    function isGuardian(address addr) external view returns (bool) {
        return guardians[addr];
    }

    /// @notice Get guard configuration for a pool
    function getGuardConfig(uint64 poolId) external view returns (GuardConfig memory) {
        return guardConfigs[poolId];
    }

    /// @notice Get last validated price for a share class
    function getLastValidatedPrice(uint64 poolId, bytes16 scId) external view returns (uint128) {
        return lastValidatedPrice[poolId][scId];
    }

    /// @notice Calculate price change in basis points (view function)
    /// @param oldPrice Previous price
    /// @param newPrice New price
    /// @return changeBps Change in basis points
    function calculateChangeBps(uint128 oldPrice, uint128 newPrice) external pure returns (uint16 changeBps) {
        return _calculateChangeBps(oldPrice, newPrice);
    }

    // ============================================================
    // INTERNAL FUNCTIONS
    // ============================================================

    /// @dev Calculate price change in basis points
    /// Formula: changeBps = |newPrice - oldPrice| / oldPrice * 10000
    function _calculateChangeBps(uint128 oldPrice, uint128 newPrice) internal pure returns (uint16) {
        if (oldPrice == 0) return 0;

        uint256 diff;
        if (newPrice >= oldPrice) {
            diff = newPrice - oldPrice;
        } else {
            diff = oldPrice - newPrice;
        }

        // changeBps = diff * 10000 / oldPrice
        uint256 changeBps = (diff * MAX_BPS) / oldPrice;

        // Cap at MAX_BPS to prevent overflow when casting
        if (changeBps > MAX_BPS) {
            return MAX_BPS;
        }

        // forge-lint: disable-next-line(unsafe-typecast)
        return uint16(changeBps);
    }
}
