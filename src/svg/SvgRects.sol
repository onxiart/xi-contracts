// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {StringConverter} from "./StringConverter.sol";

/// @dev Decoder for Nouns-RLE byte format → SVG <rect> fragments.
///
///   Byte layout (per Nouns DAO MultiPartRLEToSVG.sol):
///     byte 0  : paletteIndex (ignored — single shared palette)
///     byte 1-4: bounds (top, right, bottom, left), uint8 each
///     bytes 5+: pairs of (length, colorIndex)
///
///   Pixels placed left-to-right within bounding box, wrapping at `right`.
///   colorIndex 0 = transparent (skipped). Else palette entry at offset
///   `(colorIndex - 1) * 6` in the packed ASCII hex blob.
library SvgRects {
    using StringConverter for uint256;

    /// @dev Decode RLE bytes + emit <rect> SVG fragments.
    ///
    ///   `palette` is a tightly packed blob of 6-byte ASCII hex entries
    ///   (e.g. "ff7043" for orange). 239 colors → 1434 bytes. Stored once
    ///   via SSTORE2 by XIPlayerArt and read into memory per render.
    function decodeToSvg(bytes memory data, bytes memory palette)
        internal
        pure
        returns (string memory svg)
    {
        if (data.length < 5) return "";
        uint256 top = uint8(data[1]);
        uint256 right = uint8(data[2]);
        uint256 left = uint8(data[4]);

        // Malformed-bounds guard: if width or height is zero, the inner loop
        // would never advance cursorX past `right` and would consume gas forever.
        // Skip rendering this part rather than DOS-ing the call.
        if (right <= left) return "";

        uint256 paletteSize = palette.length / 6;
        uint256 cursorX = left;
        uint256 cursorY = top;

        uint256 i = 5;
        uint256 dataLen = data.length;
        while (i + 1 < dataLen) {
            uint256 length = uint8(data[i]);
            uint256 colorIdx = uint8(data[i + 1]);
            i += 2;

            // Walk pixels, wrapping at right
            while (length > 0) {
                uint256 rowSpace = right - cursorX;
                uint256 take = length < rowSpace ? length : rowSpace;

                // Skip transparent (colorIdx == 0) and out-of-range indices.
                if (colorIdx > 0 && colorIdx <= paletteSize) {
                    svg = string(
                        abi.encodePacked(
                            svg,
                            "<rect x='",
                            cursorX.toString(),
                            "' y='",
                            cursorY.toString(),
                            "' width='",
                            take.toString(),
                            "' height='1' fill='#",
                            _color(palette, colorIdx - 1),
                            "'/>"
                        )
                    );
                }

                cursorX += take;
                length -= take;
                if (cursorX >= right) {
                    cursorX = left;
                    cursorY += 1;
                }
            }
        }
    }

    /// @dev Extract the 6-byte ASCII hex color at slot `slot0Based`.
    function _color(bytes memory palette, uint256 slot0Based)
        private
        pure
        returns (string memory)
    {
        uint256 base = slot0Based * 6;
        bytes memory s = new bytes(6);
        s[0] = palette[base];
        s[1] = palette[base + 1];
        s[2] = palette[base + 2];
        s[3] = palette[base + 3];
        s[4] = palette[base + 4];
        s[5] = palette[base + 5];
        return string(s);
    }

    /// @dev Render a single solid rectangle (used for backgrounds).
    function solidRect(uint8 x, uint8 y, uint8 width, uint8 height, string memory hex_)
        internal
        pure
        returns (string memory)
    {
        return string(
            abi.encodePacked(
                "<rect x='",
                uint256(x).toString(),
                "' y='",
                uint256(y).toString(),
                "' width='",
                uint256(width).toString(),
                "' height='",
                uint256(height).toString(),
                "' fill='#",
                hex_,
                "'/>"
            )
        );
    }
}
