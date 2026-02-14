// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity >=0.5.0;

interface IOpsGuardian {
    /// @notice Pause a specific pool (emergency)
    /// @dev Callable by both safe and its owners
    function pausePool(uint64 poolId) external;

    /// @notice Unpause a specific pool
    /// @dev Callable by safe only
    function unpausePool(uint64 poolId) external;

    /// @notice Configure NAV guard parameters for a pool
    /// @dev Callable by safe only
    function configureGuard(uint64 poolId, uint16 maxPriceChangeBps, uint64 maxStalenessSeconds, bool enforceLimits)
        external;

    /// @notice Recover tokens stuck in a target contract
    /// @dev Callable by safe only
    function recoverTokens(address target, address token, address to, uint256 amount) external;
}
