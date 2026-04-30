// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {SSTORE2} from "solmate/src/utils/SSTORE2.sol";
import {SvgRects} from "./SvgRects.sol";
import {StringConverter} from "./StringConverter.sol";
import {PlayerMetadata, XIPlayerMetadataLibrary} from "./XIPlayerMetadata.sol";
import {IXIPlayerArt, ArtParams} from "./IXIPlayerArt.sol";
import {OwnableBase} from "../library/OwnableBase.sol";

/// @dev XI Player tier on-chain SVG generator — Nouns CC0 part library.
///
///   Storage strategy: SSTORE2 — each part is its own bytecode contract.
///     Cost: ~200 gas / byte for deploy vs 20,000 gas / 32 bytes for SSTORE.
///     ~100× cheaper for read-heavy data. Standard for on-chain image storage.
///
///   Part format: raw Nouns RLE bytes (verbatim from image-data.json).
///     byte 0  : paletteIndex (ignored)
///     bytes 1-4: bounds (top, right, bottom, left)
///     bytes 5+: pairs of (length, colorIndex)
///
///   Layers (back-to-front):
///     1. background (single solid rect from background palette)
///     2. body
///     3. accessory
///     4. head
///     5. glasses
///
///   Workflow:
///     deploy → admin loads palette + backgrounds + parts (batched) → renounceOwnership → immutable.
contract XIPlayerArt is OwnableBase, IXIPlayerArt {
    using StringConverter for uint256;

    uint8 private constant CANVAS_SIZE = 32;
    uint8 private constant HEX_PER_COLOR = 6;

    /// @dev Shared color palette — packed ASCII hex blob, 6 bytes per color.
    ///   Stored as a single SSTORE2 contract: ~720 B for 239 Nouns colors.
    ///   Replaces the prior `string[] storage` (one SSTORE per color, 239 × 22K gas)
    ///   with a single 320K-gas write at deploy time.
    address private _palettePtr;
    /// @dev Background-only palette.
    string[] private backgrounds;

    /// @dev SSTORE2 pointers per layer. Each address holds raw RLE bytes for that part id.
    mapping(uint256 => address) private _bodyPtr;
    mapping(uint256 => address) private _accessoryPtr;
    mapping(uint256 => address) private _headPtr;
    mapping(uint256 => address) private _glassesPtr;

    uint16 public bodyCount;
    uint16 public accessoryCount;
    uint16 public headCount;
    uint16 public glassesCount;

    constructor(address owner_) OwnableBase(owner_) {}

    // ─── Admin: palette + backgrounds ─────────────────────────────────

    /// @dev Write the entire color palette as one SSTORE2 blob.
    ///   `blob` is tightly packed ASCII hex: each color contributes exactly
    ///   6 bytes (e.g. "ff7043" → 0x66 0x66 0x37 0x30 0x34 0x33).
    ///   Caller is responsible for lowercasing hex digits.
    ///   Up to `type(uint16).max` colors supported (paletteCount slot is uint16).
    ///   Replaceable until ownership is renounced; the prior SSTORE2 contract
    ///   is orphaned (still on-chain, unreferenced) on overwrite.
    function setPalette(bytes calldata blob) external onlyOwner {
        require(blob.length % HEX_PER_COLOR == 0, "len%6");
        require(blob.length / HEX_PER_COLOR <= type(uint16).max, "too big");
        _palettePtr = SSTORE2.write(blob);
    }

    function setBackgrounds(string[] calldata colors) external onlyOwner {
        delete backgrounds;
        for (uint256 i = 0; i < colors.length; i++) {
            backgrounds.push(colors[i]);
        }
    }

    // ─── Admin: parts (batched SSTORE2 deploys) ───────────────────────

    function setBody(uint256[] calldata ids, bytes[] calldata datas) external onlyOwner {
        bodyCount = uint16(uint256(bodyCount) + _setParts(ids, datas, _setBodyPtr));
    }

    function setAccessory(uint256[] calldata ids, bytes[] calldata datas) external onlyOwner {
        accessoryCount = uint16(uint256(accessoryCount) + _setParts(ids, datas, _setAccessoryPtr));
    }

    function setHead(uint256[] calldata ids, bytes[] calldata datas) external onlyOwner {
        headCount = uint16(uint256(headCount) + _setParts(ids, datas, _setHeadPtr));
    }

    function setGlasses(uint256[] calldata ids, bytes[] calldata datas) external onlyOwner {
        glassesCount = uint16(uint256(glassesCount) + _setParts(ids, datas, _setGlassesPtr));
    }

    function _setParts(
        uint256[] calldata ids,
        bytes[] calldata datas,
        function(uint256, address) internal setter
    ) private returns (uint256 added) {
        require(ids.length == datas.length, "len");
        for (uint256 i = 0; i < ids.length; i++) {
            // Note: when overwriting an existing part id, the old SSTORE2 contract is orphaned
            // (still on-chain but unreferenced). Acceptable since admin renounces after seeding.
            setter(ids[i], SSTORE2.write(datas[i]));
            added++;
        }
    }

    // Indirect setters (function pointers can only point to internal funcs in same contract).
    function _setBodyPtr(uint256 id, address ptr) internal {
        _bodyPtr[id] = ptr;
    }

    function _setAccessoryPtr(uint256 id, address ptr) internal {
        _accessoryPtr[id] = ptr;
    }

    function _setHeadPtr(uint256 id, address ptr) internal {
        _headPtr[id] = ptr;
    }

    function _setGlassesPtr(uint256 id, address ptr) internal {
        _glassesPtr[id] = ptr;
    }

    // ─── Public views: render SVG ─────────────────────────────────────

    function getSeedData(uint256 seed) external pure returns (PlayerMetadata memory) {
        return XIPlayerMetadataLibrary.decode(seed);
    }

    function generate(uint256 seed) external view returns (string memory) {
        return _renderSvg(XIPlayerMetadataLibrary.decode(seed));
    }

    function generateFromMetadata(PlayerMetadata memory m) external view returns (string memory) {
        return _renderSvg(m);
    }

    function _renderSvg(PlayerMetadata memory m) internal view returns (string memory svg) {
        svg = string.concat(
            "<svg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 ",
            uint256(CANVAS_SIZE).toString(),
            " ",
            uint256(CANVAS_SIZE).toString(),
            "' shape-rendering='crispEdges'>"
        );

        // Read palette blob once into memory; reused across all 4 part layers.
        bytes memory palette = _palettePtr == address(0) ? bytes("") : SSTORE2.read(_palettePtr);

        // Background
        if (backgrounds.length > 0) {
            svg = string.concat(
                svg,
                SvgRects.solidRect(
                    0, 0, CANVAS_SIZE, CANVAS_SIZE, backgrounds[m.background % backgrounds.length]
                )
            );
        }

        // Body
        if (m.body > 0 && bodyCount > 0) {
            address ptr = _bodyPtr[((uint256(m.body) - 1) % bodyCount) + 1];
            if (ptr != address(0)) {
                svg = string.concat(svg, SvgRects.decodeToSvg(SSTORE2.read(ptr), palette));
            }
        }

        // Accessory
        if (m.accessory > 0 && accessoryCount > 0) {
            address ptr = _accessoryPtr[((uint256(m.accessory) - 1) % accessoryCount) + 1];
            if (ptr != address(0)) {
                svg = string.concat(svg, SvgRects.decodeToSvg(SSTORE2.read(ptr), palette));
            }
        }

        // Head
        if (m.head > 0 && headCount > 0) {
            address ptr = _headPtr[((uint256(m.head) - 1) % headCount) + 1];
            if (ptr != address(0)) {
                svg = string.concat(svg, SvgRects.decodeToSvg(SSTORE2.read(ptr), palette));
            }
        }

        // Glasses
        if (m.glasses > 0 && glassesCount > 0) {
            address ptr = _glassesPtr[((uint256(m.glasses) - 1) % glassesCount) + 1];
            if (ptr != address(0)) {
                svg = string.concat(svg, SvgRects.decodeToSvg(SSTORE2.read(ptr), palette));
            }
        }

        svg = string.concat(svg, "</svg>");
    }

    function getArtParams() external view returns (ArtParams memory) {
        uint16 paletteCount =
            _palettePtr == address(0) ? 0 : uint16(SSTORE2.read(_palettePtr).length / HEX_PER_COLOR);
        return ArtParams({
            paletteCount: paletteCount,
            backgroundCount: uint16(backgrounds.length),
            bodyCount: bodyCount,
            accessoryCount: accessoryCount,
            headCount: headCount,
            glassesCount: glassesCount
        });
    }
}
