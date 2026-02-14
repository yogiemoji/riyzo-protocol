// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.28;

import {IValuation} from "src/interfaces/hub/IValuation.sol";
import {IRiyzoRegistry} from "src/interfaces/hub/IRiyzoRegistry.sol";
import {MathLib} from "src/core/libraries/MathLib.sol";

/// @title  IdentityValuation
/// @notice 1:1 pricing for stablecoins. Price is always 1e18 (one unit = one unit).
///         getQuote only performs decimal conversion from asset decimals to 18 decimals.
/// @dev    Stateless read-only contract — no auth needed.
contract IdentityValuation is IValuation {
    using MathLib for uint256;

    IRiyzoRegistry public immutable registry;

    constructor(address registry_) {
        registry = IRiyzoRegistry(registry_);
    }

    /// @inheritdoc IValuation
    function getPrice(uint64, bytes16, uint128) external pure returns (uint256 price) {
        return 1e18;
    }

    /// @inheritdoc IValuation
    function getQuote(uint64, bytes16, uint128 assetId, uint128 baseAmount)
        external
        view
        returns (uint128 quoteAmount)
    {
        uint8 assetDecimals = registry.decimals(assetId);
        // Convert: baseAmount * 1e18 / 10^assetDecimals
        return MathLib.toUint128(uint256(baseAmount) * 1e18 / (10 ** assetDecimals));
    }

    /// @inheritdoc IValuation
    function isSupported(uint64, bytes16, uint128) external pure returns (bool) {
        return true;
    }

    /// @inheritdoc IValuation
    function lastUpdated(uint64, bytes16, uint128) external view returns (uint64) {
        return uint64(block.timestamp);
    }
}
