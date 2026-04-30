// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @dev Identity status for the append-only governance model.
/// Active   — eligible for weighted-random mint
/// Errata   — withdrawn from the mint pool because a corrected version was appended
/// Deprecated — withdrawn for non-error reasons (data dispute, governance)
enum IdentityStatus {
    Active,
    Errata,
    Deprecated
}

/// @dev Core identity record. Append-only: once written it is never modified.
/// Edition-level state is in `SlotState` (separate mapping).
struct IdentityData {
    uint8 countryCode; // index into country code table
    uint16 tournamentYear; // 1930..2026..
    uint8 jerseyNumber; // 0..99 (0 = unknown / no number)
    uint8 position; // 0=GK 1=DEF 2=MID 3=FWD 4=UNK
}

/// @dev Per-identity print-run state.
/// - `circulating` 0..N: total cards currently alive across all versions
///   of this identity (mint +1, burn -1). No per-identity cap — many versions
///   can coexist (e.g. v1 prints 2,3,4 + v2 prints 1,2,3,4 = 7 alive). uint16
///   bounds the worst case at ~65k, far above any plausible accumulation given
///   the 10,000 XI total supply.
/// - `currentVersionPrintCount` 0..5: how many cards have been printed in the
///   current open version. The mint pool holds exactly
///   `MAX_PRINTS_PER_VERSION - currentVersionPrintCount` entries for this id
///   (when status == Active), so reaching 5 stalls further mints until a burn
///   opens the next version.
/// - `currentVersion` monotonic 1..N: initialized to 1 by `appendIdentity`.
///   Bumps when **any** card of the current version is burned (Rule A): the
///   current version closes regardless of remaining print slots, and the next
///   mint produces print #1 of the new version. Older versions stay alive in
///   holder wallets; burning them only decrements `circulating` (no version
///   advance, no pool change). Same-version cards share the same SVG seed.
struct SlotState {
    uint16 circulating;
    uint8 currentVersionPrintCount;
    uint16 currentVersion;
}

/// @dev Per-token data. tokenId is global, monotonic, never reused.
/// Cards within the same (identityId, versionNumber) share the same on-chain
/// SVG (seed = keccak256(identityId, versionNumber, salt)); `printIndex`
/// distinguishes copies within a version (1..MAX_PRINTS_PER_VERSION = 5).
struct TokenData {
    uint16 identityId;
    uint16 versionNumber;
    uint8 printIndex; // 1..5
}

/// @dev Read-only struct returned by enumeration queries.
struct TokenView {
    uint256 tokenId;
    uint16 identityId;
    uint16 versionNumber;
    uint8 printIndex;
}

/// @dev XI player container interface.
/// Players are gacha-minted via ERC20 sync (`pool → user` token transfer triggers
/// weighted-random identity selection). Tier 2-5 cards (Jersey/Country/Stadium/Trophy)
/// are minted via the separate MintGateway contract using eligibility queries here.
interface IXI {
    error NotTokenOwner();
    error TokenIndexOutOfRange();
    error AddressCanNotReceiveCard();
    error IdentityNotActive();
    error InvalidIdentity();
    error EmptyAppend();
    error IdentityAlreadyErrata();
    error PresaleAlreadySet();
    error ZeroPresale();
    error AirdropAlreadySet();
    error ZeroAirdrop();
    error PlayerArtNotSet();
    error TokenDoesNotExist();

    /// @dev Token mint (ERC20 sync minted player card).
    event OnTokenMinted(
        address indexed owner,
        uint256 indexed tokenId,
        uint16 identityId,
        uint16 versionNumber,
        uint8 printIndex
    );
    /// @dev Token burn.
    event OnTokenBurned(address indexed owner, uint256 indexed tokenId);
    /// @dev Token transfer (user-to-user 1:1 with ERC20 transfer).
    event OnTokenTransfer(address indexed from, address indexed to, uint256 indexed tokenId);

    /// @dev Admin: single identity appended via `appendIdentity`.
    ///   Emitted only on the single-entry path. Batch appends use
    ///   `IdentitiesAppended` (one event per batch, not per identity)
    ///   to keep seed-time gas down — at 10k+ identities the per-row event
    ///   was ~10-30M gas of pure log overhead with no on-chain consumer.
    ///   To reconstruct a batch's contents, read `identities(fromId..toId)`.
    event IdentityAppended(uint16 indexed identityId, IdentityData data);
    /// @dev Admin: batch of identities appended via `appendBatch`.
    ///   Both bounds inclusive. New ids are `fromId, fromId+1, ..., toId`.
    event IdentitiesAppended(uint16 fromId, uint16 toId);
    /// @dev Admin: errata correction. Old identity goes to Errata, new identity is Active.
    ///   The new identity's data is **not** republished here — read
    ///   `identities(correctedId)` for the contents.
    event IdentityCorrected(uint16 indexed erroneousId, uint16 indexed correctedId, string reason);
    /// @dev Admin: deprecate (non-error withdrawal).
    event IdentityDeprecated(uint16 indexed identityId, string reason);

    /// @dev Deploy-time wiring: PresaleManager registered as second gacha source.
    event PresaleSet(address indexed presale);
    /// @dev Deploy-time wiring: AirdropManager registered as third gacha source.
    event AirdropSet(address indexed airdrop);
    /// @dev Admin: XIPlayerArt library swapped (replaceable until ownership renounced).
    event PlayerArtSet(address indexed prev, address indexed next);

    // ---- Identity registry ----

    function identityCount() external view returns (uint16);
    function identities(uint16 id)
        external
        view
        returns (uint8 countryCode, uint16 tournamentYear, uint8 jerseyNumber, uint8 position);
    function identityStatus(uint16 id) external view returns (IdentityStatus);
    function correctedBy(uint16 erroneousId) external view returns (uint16 correctedId);

    // ---- Token / ownership ----

    function totalSupply() external view returns (uint256);
    function holdersCount() external view returns (uint256);

    /// @dev How many tokens this owner holds in total.
    function ownerTokenCount(address owner) external view returns (uint256);
    /// @dev How many tokens of a specific identity this owner holds (across all
    /// versions). Used by Tier 2-5 eligibility (`>= 1` checks). uint16 because
    /// version cycling removes the per-identity 5 cap; realistic max is bounded
    /// by the holder's XI balance.
    function balanceOfIdentity(address owner, uint16 identityId) external view returns (uint16);
    /// @dev Page through an owner's tokens.
    function ownerTokensPage(address owner, uint256 page, uint256 pageSize)
        external
        view
        returns (TokenView[] memory);
    function ownerTokenAt(address owner, uint256 index) external view returns (TokenView memory);
    function ownerOwns(address owner, uint256 tokenId) external view returns (bool);

    function tokenInfo(uint256 tokenId)
        external
        view
        returns (uint16 identityId, uint16 versionNumber, uint8 printIndex);
    function tokenOwner(uint256 tokenId) external view returns (address);

    /// @dev Holder enumeration (used by Tier 2-5 eligibility logic and indexers).
    function isHolder(address addr) external view returns (bool);
    function holderAt(uint256 index) external view returns (address);

    // ---- Transfer ----

    /// @dev User-to-user transfer of a single card. Also moves UNIT_PER_CARD ERC20.
    function transferCard(address to, uint256 tokenId) external;
    /// @dev Batch user-to-user transfer.
    function transferCardsList(address to, uint256[] calldata tokenIds) external;

    // ---- Admin (append-only governance) ----

    /// @dev Append a new identity at the end of the pool (id = identityCount, then ++).
    /// Used for 2026 / 2030 / 2034+ batches and gap fixes.
    function appendIdentity(IdentityData calldata data) external returns (uint16 newId);
    /// @dev Append multiple identities atomically.
    function appendBatch(IdentityData[] calldata dataList)
        external
        returns (uint16 firstNewId, uint16 lastNewId);
    /// @dev Append a corrected version + flip the erroneous one to Errata.
    /// The errata token holders keep their cards (now collectibles).
    function correctWithErrata(
        uint16 erroneousId,
        IdentityData calldata correctedData,
        string calldata reason
    ) external returns (uint16 correctedId);
    /// @dev Mark an identity as Deprecated (non-error reason).
    function markDeprecated(uint16 identityId, string calldata reason) external;
}
