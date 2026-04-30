// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @dev uint → decimal string. Adapted from UPEG mainnet (reference/upeg_mainnet/.../StringConverter.sol).
library StringConverter {
    function toString(uint256 value) internal pure returns (string memory) {
        if (value == 0) return "0";
        uint256 temp = value;
        uint256 digits;
        while (temp != 0) {
            digits++;
            temp /= 10;
        }
        bytes memory buffer = new bytes(digits);
        while (value != 0) {
            digits -= 1;
            // 48 + (value % 10) ∈ [48, 57] (ASCII '0'..'9'), uint8 cast is by construction safe.
            // forge-lint: disable-next-line(unsafe-typecast)
            buffer[digits] = bytes1(uint8(48 + uint256(value % 10)));
            value /= 10;
        }
        return string(buffer);
    }
}
