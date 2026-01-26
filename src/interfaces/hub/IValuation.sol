// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.28;

/// @title IValuation - Asset Pricing Interface
/// @author Riyzo Protocol
/// @notice Interface for contracts that provide asset pricing/valuation.
///         Think of this as the "price oracle" that tells us what assets are worth.
/// @dev Different valuation strategies can implement this interface:
///      - Oracle-based (Chainlink, Pyth)
///      - Manual (admin-set prices)
///      - Formula-based (calculated from other prices)
///
/// KEY CONCEPTS:
/// - Price: The value of 1 unit of the base asset in quote currency (18 decimals)
/// - Quote: Convert a specific amount of base asset to quote currency value
///
/// EXAMPLE:
/// - If ETH price is $2000, getPrice() returns 2000e18
/// - If we have 1.5 ETH, getQuote(1.5e18) returns 3000e18 (1.5 * 2000)
interface IValuation {
    // ============================================================
    // EVENTS
    // ============================================================

    /// @notice Emitted when a price is updated
    /// @param poolId The pool this price applies to
    /// @param scId The share class this price applies to
    /// @param assetId The asset being priced
    /// @param price The new price (18 decimals)
    event PriceUpdated(uint64 indexed poolId, bytes16 indexed scId, uint128 indexed assetId, uint256 price);

    // ============================================================
    // VIEW FUNCTIONS
    // ============================================================

    /// @notice Get the current price of an asset
    /// @dev Returns the value of 1 unit of the asset in pool currency.
    ///      Always returns 18 decimal fixed-point.
    ///
    /// EXAMPLE:
    /// - Asset is WETH, pool currency is USDC
    /// - If 1 ETH = $2000, returns 2000e18
    ///
    /// @param poolId Which pool to get the price for
    /// @param scId Which share class (prices may differ per share class)
    /// @param assetId The asset to price
    /// @return price The price per unit (18 decimals)
    function getPrice(uint64 poolId, bytes16 scId, uint128 assetId) external view returns (uint256 price);

    /// @notice Convert an asset amount to its value in pool currency
    /// @dev This is essentially: amount * price / 10^assetDecimals
    ///      Handles decimal conversions internally.
    ///
    /// EXAMPLE:
    /// - Asset is WETH (18 decimals), price is $2000
    /// - Input: 1.5 ETH = 1500000000000000000 (1.5e18)
    /// - Output: $3000 = 3000000000000000000000 (3000e18)
    ///
    /// @param poolId Which pool context
    /// @param scId Which share class context
    /// @param assetId The asset being valued
    /// @param baseAmount Amount of the asset (in asset's native decimals)
    /// @return quoteAmount Value in pool currency (18 decimals)
    function getQuote(uint64 poolId, bytes16 scId, uint128 assetId, uint128 baseAmount)
        external
        view
        returns (uint128 quoteAmount);

    /// @notice Check if this valuation contract supports a specific asset
    /// @param poolId The pool context
    /// @param scId The share class context
    /// @param assetId The asset to check
    /// @return supported True if this valuation can price the asset
    function isSupported(uint64 poolId, bytes16 scId, uint128 assetId) external view returns (bool supported);

    /// @notice Get the timestamp of the last price update
    /// @dev Used for staleness checks by NAVGuard
    /// @param poolId The pool context
    /// @param scId The share class context
    /// @param assetId The asset to check
    /// @return timestamp Unix timestamp of last update
    function lastUpdated(uint64 poolId, bytes16 scId, uint128 assetId) external view returns (uint64 timestamp);
}
