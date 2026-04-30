// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @dev Player avatar trait struct — Nouns 5-layer model.
///   Each field is a part id; 0 reserved for "absent" (skip layer at render time).
///
/// Layers (Nouns-canonical order, drawn back-to-front):
///   1. background — solid color from BACKGROUND palette (uint8 index)
///   2. body       — torso silhouette (Nouns CC0 bodies)
///   3. accessory  — chest accessory like ties / bandanas (Nouns CC0)
///   4. head       — the iconic identifying element (Nouns CC0 heads — animals/objects/food)
///   5. glasses    — Noggles variants (Nouns CC0)
///
/// Colors: each layer's part bundles its own palette indices internally (multi-color per part).
/// Background is the only single-color layer.
struct PlayerMetadata {
    uint8 background;
    uint8 body;
    uint8 accessory;
    uint8 head;
    uint8 glasses;
}

/// @dev Encode/decode PlayerMetadata into uint256 (5 bytes used).
///   Bit layout (LSB first, 1 byte each):
///     0  background
///     1  body
///     2  accessory
///     3  head
///     4  glasses
library XIPlayerMetadataLibrary {
    function encode(PlayerMetadata memory m) internal pure returns (uint256 r) {
        r |= uint256(m.background) << 0;
        r |= uint256(m.body) << 8;
        r |= uint256(m.accessory) << 16;
        r |= uint256(m.head) << 24;
        r |= uint256(m.glasses) << 32;
    }

    function decode(uint256 seed) internal pure returns (PlayerMetadata memory) {
        return PlayerMetadata({
            background: _byte(seed, 0),
            body: _byte(seed, 8),
            accessory: _byte(seed, 16),
            head: _byte(seed, 24),
            glasses: _byte(seed, 32)
        });
    }

    /// @dev Extracts the byte at `shift` position. Truncating cast is intentional —
    ///      decoding one byte at a time from a packed seed.
    function _byte(uint256 seed, uint8 shift) private pure returns (uint8) {
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint8(seed >> shift);
    }
}
