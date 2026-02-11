// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.28;

/// @title  ArrayLib
library ArrayLib {
    function countNonZeroValues(uint16[8] memory arr) internal pure returns (uint8 count) {
        uint256 elementsCount = arr.length;
        for (uint256 i; i < elementsCount; i++) {
            if (arr[i] != 0) ++count;
        }
    }

    function decreaseFirstNValues(uint16[8] storage arr, uint8 numValues) internal {
        uint256 elementsCount = arr.length;
        for (uint256 i; i < elementsCount; i++) {
            if (numValues == 0) return;

            if (arr[i] != 0) {
                arr[i] -= 1;
                numValues--;
            }
        }

        require(numValues == 0, "ArrayLib/invalid-values");
    }

    function isEmpty(uint16[8] memory arr) internal pure returns (bool) {
        uint256 elementsCount = arr.length;
        for (uint256 i; i < elementsCount; i++) {
            if (arr[i] != 0) return false;
        }
        return true;
    }

    // --- int16[8] functions for MultiAdapter voting ---

    /// @notice Count the number of positive (> 0) values in the array.
    ///         Used to check how many adapters have confirmed a message.
    function countPositiveValues(int16[8] memory arr) internal pure returns (uint8 count) {
        uint256 elementsCount = arr.length;
        for (uint256 i; i < elementsCount; i++) {
            if (arr[i] > 0) ++count;
        }
    }

    /// @notice Decrease the first N positive values by 1, skipping the recovery adapter slot.
    /// @param  arr        The vote array to modify
    /// @param  numValues  Number of values to decrease
    /// @param  skipIndex  0-based index to skip (recovery adapter). Use type(uint8).max to skip nothing.
    function decreaseFirstNValues(int16[8] storage arr, uint8 numValues, uint8 skipIndex) internal {
        uint256 elementsCount = arr.length;
        for (uint256 i; i < elementsCount; i++) {
            if (numValues == 0) return;

            if (uint8(i) == skipIndex) continue;

            if (arr[i] > 0) {
                arr[i] -= 1;
                numValues--;
            }
        }

        require(numValues == 0, "ArrayLib/invalid-values");
    }

    /// @notice Check if all values are non-positive (no pending votes remain).
    function isNonPositive(int16[8] memory arr) internal pure returns (bool) {
        uint256 elementsCount = arr.length;
        for (uint256 i; i < elementsCount; i++) {
            if (arr[i] > 0) return false;
        }
        return true;
    }
}
