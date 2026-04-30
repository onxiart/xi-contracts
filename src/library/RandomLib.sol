// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @dev Structure for pseudo-random generator state.
struct Random {
    uint256 seed;
    uint256 nonce;
}

/// @dev Library for pseudo-random number generation.
library RandomLibrary {
    /// @dev Generates the next pseudo-random number.
    /// @param random Generator state struct.
    function next(Random memory random) internal pure returns (uint256) {
        return uint256(keccak256(abi.encodePacked(random.seed, ++random.nonce)));
    }
}
