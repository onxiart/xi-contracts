// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {PlayerMetadata} from "./XIPlayerMetadata.sol";

// solhint-disable-previous-line no-unused-import — re-exported in interface signature

/// @dev Aggregated counts of part variants currently loaded.
struct ArtParams {
    uint16 paletteCount; // shared color palette size (Nouns: 239)
    uint16 backgroundCount; // background palette size (Nouns: 2)
    uint16 bodyCount; // _body variants loaded
    uint16 accessoryCount; // _accessory variants loaded
    uint16 headCount; // _head variants loaded
    uint16 glassesCount; // _glasses variants loaded
}

interface IXIPlayerArt {
    /// @dev Renders the player avatar SVG for a given encoded seed.
    function generate(uint256 seed) external view returns (string memory);

    /// @dev Renders SVG from a decoded PlayerMetadata struct (skips decode step).
    function generateFromMetadata(PlayerMetadata memory m) external view returns (string memory);

    /// @dev Decodes a uint256 seed into PlayerMetadata.
    function getSeedData(uint256 seed) external pure returns (PlayerMetadata memory);

    /// @dev Returns aggregated counts so callers can mod indices into loaded ranges.
    function getArtParams() external view returns (ArtParams memory);
}
