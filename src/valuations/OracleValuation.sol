// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.28;

import {Auth} from "src/core/Auth.sol";
import {IValuation} from "src/interfaces/hub/IValuation.sol";
import {IRiyzoRegistry} from "src/interfaces/hub/IRiyzoRegistry.sol";
import {MathLib} from "src/core/libraries/MathLib.sol";

/// @title  OracleValuation
/// @notice Permissioned price feed valuation. Pool managers authorize feeders
///         who can set prices per (poolId, scId, assetId) triple.
/// @dev    No auto-revaluation on setPrice. Pool managers call hub.updateHoldingValue()
///         separately to trigger revaluation.
contract OracleValuation is Auth, IValuation {
    using MathLib for uint256;

    struct Price {
        uint256 value;
        bool isValid;
        uint64 updatedAt;
    }

    // --- Events ---
    event FeederUpdated(uint64 indexed poolId, address indexed feeder, bool canFeed);

    // --- Storage ---
    IRiyzoRegistry public registry;

    /// @notice Per-pool feeder permissions
    mapping(uint64 poolId => mapping(address feeder => bool)) public feeders;

    /// @notice Price data per (poolId, scId, assetId)
    mapping(uint64 => mapping(bytes16 => mapping(uint128 => Price))) public priceData;

    constructor(address initialWard, address registry_) Auth(initialWard) {
        registry = IRiyzoRegistry(registry_);
    }

    // --- Admin ---

    /// @notice Update contract dependencies
    function file(bytes32 what, address data) external auth {
        if (what == "registry") {
            registry = IRiyzoRegistry(data);
        } else {
            revert("OracleValuation/file-unrecognized-param");
        }
    }

    /// @notice Authorize or revoke a feeder for a pool
    /// @dev Only callable by pool managers (checked via registry)
    function updateFeeder(uint64 poolId, address feeder, bool canFeed) external {
        require(registry.isManager(poolId, msg.sender), "OracleValuation/not-pool-manager");
        feeders[poolId][feeder] = canFeed;
        emit FeederUpdated(poolId, feeder, canFeed);
    }

    /// @notice Set a price for an asset in a pool/share class context
    /// @dev Only callable by authorized feeders
    function setPrice(uint64 poolId, bytes16 scId, uint128 assetId, uint256 newPrice) external {
        require(feeders[poolId][msg.sender], "OracleValuation/not-authorized-feeder");
        require(newPrice > 0, "OracleValuation/zero-price");

        priceData[poolId][scId][assetId] = Price({value: newPrice, isValid: true, updatedAt: uint64(block.timestamp)});

        emit PriceUpdated(poolId, scId, assetId, newPrice);
    }

    // --- IValuation ---

    /// @inheritdoc IValuation
    function getPrice(uint64 poolId, bytes16 scId, uint128 assetId) external view returns (uint256 price) {
        Price storage p = priceData[poolId][scId][assetId];
        require(p.isValid, "OracleValuation/price-not-set");
        return p.value;
    }

    /// @inheritdoc IValuation
    function getQuote(uint64 poolId, bytes16 scId, uint128 assetId, uint128 baseAmount)
        external
        view
        returns (uint128 quoteAmount)
    {
        Price storage p = priceData[poolId][scId][assetId];
        require(p.isValid, "OracleValuation/price-not-set");

        uint8 assetDecimals = registry.decimals(assetId);
        // quoteAmount = baseAmount * price / 10^assetDecimals
        return MathLib.toUint128(MathLib.mulDiv(uint256(baseAmount), p.value, 10 ** assetDecimals));
    }

    /// @inheritdoc IValuation
    function isSupported(uint64 poolId, bytes16 scId, uint128 assetId) external view returns (bool) {
        return priceData[poolId][scId][assetId].isValid;
    }

    /// @inheritdoc IValuation
    function lastUpdated(uint64 poolId, bytes16 scId, uint128 assetId) external view returns (uint64) {
        return priceData[poolId][scId][assetId].updatedAt;
    }
}
