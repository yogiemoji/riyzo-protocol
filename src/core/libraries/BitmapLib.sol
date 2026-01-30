// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.28;

/// @title  BitmapLib
library BitmapLib {
    function setBit(uint128 bitmap, uint128 index, bool isTrue) internal pure returns (uint128) {
        if (isTrue) {
            return bitmap | (uint128(1) << index);
        }

        return bitmap & ~(uint128(1) << index);
    }

    function getBit(uint128 bitmap, uint128 index) internal pure returns (bool) {
        uint128 bitAtIndex = bitmap & (uint128(1) << index);
        return bitAtIndex != 0;
    }
}
