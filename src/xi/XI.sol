// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC20} from "solady/src/tokens/ERC20.sol";
import {OwnableBase} from "../library/OwnableBase.sol";
import {Random, RandomLibrary} from "../library/RandomLib.sol";
import {IRandomSeedProvider} from "../library/IRandomSeedProvider.sol";
import {IStartableToken} from "../token/IStartableToken.sol";
import {IXIPlayerArt} from "../svg/IXIPlayerArt.sol";
import {IXI, IdentityStatus, IdentityData, SlotState, TokenData, TokenView} from "./IXI.sol";

/// @title XI — ERC20 + Player card container with append-only identity registry
/// @notice
/// XI is the protocol's ERC20 token AND the Player Tier (Tier 1) container.
/// 1 ERC20 unit (10^18) corresponds to one Player card. ERC20 transfers drive
/// card mint / burn / transfer:
///
///   pool    → user   weighted-random gacha mint of Active identity
///   presale → user   weighted-random gacha mint (sale path; same gacha
///                    output as pool→user, but the sale contract enforces the
///                    purchase cap so buyers receive cards immediately)
///   user    → user   1:1 transfer existing cards (no mint)
///   user    → pool   burn cards (releases the slot for re-mint)
///
/// The identity registry is **append-only forever**:
///   - admin can `appendIdentity` / `appendBatch` (e.g. 2026 squads after FIFA roster)
///   - admin can `correctWithErrata(oldId, newData)` → flips oldId to Errata, appends newId
///   - admin can `markDeprecated(id, reason)` → removes id from mint pool
///   - admin **cannot** modify any IdentityData field once written
///
/// Mint algorithm: uniform random over the mint pool. Each Active identity
/// contributes **at most one** entry to the pool — present iff the current
/// version still has slots left (`currentVersionPrintCount < 5`). Once the
/// current version fills, the entry is removed and stays removed until a burn
/// closes the version and opens the next one. Errata / Deprecated identities
/// have their entry drained immediately and never reappear.
///
/// Weight is therefore 0 or 1 (mintable / not), not graduated 0..5. With ~22k
/// jersey identities and 10k total supply (avg 0.45 cards/identity in
/// circulation), the gacha is in practice indistinguishable from the old
/// `5 - printCount` weighting and saves ~1.75B gas across the protocol's
/// lifecycle (mainly Phase 2 SeedGenesis: 1 push per identity instead of 5).
///
/// Versioning (Rule A — burn-triggered version bump):
///   - `appendIdentity` initializes `currentVersion = 1` with 5 mint pool entries.
///   - Mints fill the current version: print #1, #2, ..., up to #5. After #5
///     the pool has 0 entries for this id; further mints are blocked.
///   - **Any burn of a current-version card** closes that version: the next
///     mint produces print #1 of `currentVersion + 1`. The mint pool is
///     immediately topped up to 5 entries for the new version, regardless of
///     how many prints the closed version had (1..5). Print #5 is therefore
///     not required for version progression — the mechanic depends only on
///     burn events, not on filling the version.
///   - Burning an **older-version** card (i.e. `t.versionNumber < currentVersion`)
///     only decrements `circulating`; it does not advance the version or push
///     pool entries. So once v1 has been closed by a burn, burning the
///     remaining v1 cards has no effect on the mint odds for v2.
///   - There is no per-identity cap on circulating cards: v1 prints 2,3,4 and
///     v2 prints 1,2,3,4 can coexist (7 alive simultaneously).
///   - Same-version cards share the same on-chain SVG seed, so each version
///     is one visual print run.
contract XI is OwnableBase, ERC20, IStartableToken, IXI {
    using RandomLibrary for Random;

    // ----- Constants -----

    uint256 public constant UNIT_PER_CARD = 1e18; // tokens per player card
    uint256 public constant INITIAL_SUPPLY = 10_000e18;
    /// @dev Hard cap on prints per single version of one identity. Reaching
    /// this count stalls further mints of that identity until a burn closes
    /// the version and opens the next one. Has nothing to do with the number
    /// of cards a wallet may hold or the total alive count — neither is
    /// capped.
    uint8 public constant MAX_PRINTS_PER_VERSION = 5;

    // Max buy ramp (anti-bot at launch). Same shape as Panpeg.
    uint256 private constant _MAX_BUY_PRECISION = 100000;
    uint256 private constant _START_MAX_BUY_COUNT = (INITIAL_SUPPLY * 250) / _MAX_BUY_PRECISION; // 0.25%
    uint256 private constant _ADD_MAX_BUY_PERCENT_PER_SEC = 3; // +0.003%/sec

    // ----- Immutables -----

    address private immutable _NOT_MINTABLE_ACCOUNT;

    // ----- Storage -----

    // Identity registry (append-only, mapping not array — supports growth)
    mapping(uint16 => IdentityData) private _identities;
    mapping(uint16 => IdentityStatus) public override identityStatus;
    mapping(uint16 => uint16) public override correctedBy;
    uint16 private _identityCount;

    // Per-identity slot state
    mapping(uint16 => SlotState) private _slotState;

    // Mint pool for O(1) uniform random pick. Each Active identity contributes
    // exactly 0 or 1 entry: present iff `currentVersionPrintCount < 5`.
    //   Mint: pop the picked entry, increment `currentVersionPrintCount`, then
    //         push the same id back unless that mint just hit 5 (the version
    //         is now full → identity drops out of the pool).
    //   Burn (current version, Active): close v + open v+1 (printCount = 0).
    //         Re-add an entry only if printCount was 5 (the identity had been
    //         removed from the pool); otherwise the entry already remains in
    //         the pool from the prior partial fill.
    //   Burn (older version, or non-Active id): no pool change.
    //   Errata / Deprecated: admin drains the single entry once.
    // Invariant: per-id pool count is 1 if (status == Active AND printCount < 5),
    //            else 0. So `_slotPool.length` = number of mintable identities.
    uint16[] private _slotPool;

    // Per-token data
    mapping(uint256 => TokenData) private _tokens;
    mapping(uint256 => address) private _tokenOwner;
    uint256 private _tokenIdCounter;

    // Owner enumeration: address → tokenId list + index lookup
    mapping(address => mapping(uint256 => uint256)) private _ownedTokens; // owner → idx → tokenId
    mapping(uint256 => uint256) private _ownedTokenIndex; // tokenId → idx
    mapping(address => uint256) private _ownerTokenCounts;

    // Per-owner per-identity counter (eligibility-query primitive for Tier 2-5).
    // uint16 because version cycling lets one wallet hold > 5 of a single
    // identity (across multiple versions); realistic max is bounded by the
    // wallet's XI balance.
    mapping(address => mapping(uint16 => uint16)) private _balanceByIdentity;

    // Holder list (1-indexed; holderNumber = 0 means "not a holder")
    address[] private _holderList;
    mapping(address => uint256) private _holderListNumbers;

    // Hook + pool + presale
    address public hook;
    address public pool;
    /// @notice PresaleManager address — second gacha mint source.
    /// During `presale.buy()` the contract transfers XI to the buyer,
    /// which triggers `_onTokenTransfer(presale, user, amount)` and routes
    /// into the same weighted-random gacha mint path as `pool → user` swaps.
    /// The sale contract enforces the per-tx cap via `maxBuy()` and can run
    /// before `start()`; the pool/airdrop sources remain launch-gated.
    /// Set once at deploy time via `setPresale`.
    address public presale;
    /// @notice AirdropManager address — third gacha mint source.
    /// During `airdrop.claim(proof)` the contract transfers 1 XI per eligible
    /// holder, triggering `_onTokenTransfer(airdrop, user, 1e18)` which routes
    /// into the same weighted-random gacha mint path subject to `maxBuy()`.
    /// Set once at deploy time via `setAirdrop`.
    address public airdrop;
    uint256 private _startTime;

    // Random seed provider
    address private _randomSeedProvider;

    /// @notice XIPlayerArt library — on-chain SVG generator for Player tier cards.
    /// Replaceable while admin holds ownership; intended to be locked in by
    /// `ownerRenounce()` after the Nouns CC0 part library has been seeded
    /// (see scripts/seed-player-art.ts).
    address public playerArt;

    /// @dev Salt mixed into the seed derivation. Bumping this would re-shuffle
    /// every player avatar; intentionally fixed for v1.
    bytes32 internal constant _PLAYER_ART_SALT = "xi.player.art.v1";

    // ----- Constructor -----

    constructor(address owner_) OwnableBase(owner_) {
        _NOT_MINTABLE_ACCOUNT = owner_;
        _mint(owner_, INITIAL_SUPPLY);
    }

    // ----- Modifiers -----

    modifier onlyHook() {
        _checkOnlyHook();
        _;
    }

    function _checkOnlyHook() internal view {
        require(msg.sender == hook, "only for hook");
    }

    // ----- ERC20 metadata -----

    function name() public pure override returns (string memory) {
        return "XI";
    }

    function symbol() public pure override returns (string memory) {
        return "XI";
    }

    // ----- Hook integration -----

    function setHook(address newHook) external onlyOwner {
        hook = newHook;
    }

    function setRandomSeedProvider(address newProvider) external onlyOwner {
        _randomSeedProvider = newProvider;
    }

    /// @notice Wire the PresaleManager as the second gacha mint source.
    /// One-shot: once `presale != 0` this reverts. Designed to be called
    /// during deployment (Deploy.s.sol) before XI ownership is handed to
    /// admin, so the route is locked in by the time the supply moves.
    function setPresale(address newPresale) external onlyOwner {
        if (presale != address(0)) revert PresaleAlreadySet();
        if (newPresale == address(0)) revert ZeroPresale();
        presale = newPresale;
        emit PresaleSet(newPresale);
    }

    /// @notice Wire the AirdropManager as the third gacha mint source.
    /// One-shot: once `airdrop != 0` this reverts. Designed to be called
    /// during deployment (Deploy.s.sol) before XI ownership is handed to
    /// admin, so the route is locked in by the time the supply moves.
    function setAirdrop(address newAirdrop) external onlyOwner {
        if (airdrop != address(0)) revert AirdropAlreadySet();
        if (newAirdrop == address(0)) revert ZeroAirdrop();
        airdrop = newAirdrop;
        emit AirdropSet(newAirdrop);
    }

    /// @notice Swap the on-chain SVG art library used by `playerSvg`.
    /// Replaceable while admin holds ownership (allows post-launch fixes
    /// to the renderer or part library). Locked in once admin renounces
    /// via `ownerRenounce()`.
    function setPlayerArt(address newArt) external onlyOwner {
        emit PlayerArtSet(playerArt, newArt);
        playerArt = newArt;
    }

    function start(address newPool) external onlyHook {
        pool = newPool;
        _startTime = block.timestamp;
    }

    function isStarted() public view returns (bool) {
        return pool != address(0);
    }

    /// @dev Per-second ramping max buy. Same shape as Panpeg.
    /// Before `start()` the sale path still uses the 25 XI bootstrap cap.
    function maxBuy() public view returns (uint256) {
        if (!isStarted()) return _START_MAX_BUY_COUNT;
        uint256 count = _START_MAX_BUY_COUNT
            + (INITIAL_SUPPLY * (block.timestamp - _startTime) * _ADD_MAX_BUY_PERCENT_PER_SEC)
            / _MAX_BUY_PRECISION;
        if (count > INITIAL_SUPPLY) count = INITIAL_SUPPLY;
        return count;
    }

    // ----- IXI: identity registry views -----

    function identityCount() external view override returns (uint16) {
        return _identityCount;
    }

    function identities(uint16 id)
        external
        view
        override
        returns (uint8 countryCode, uint16 tournamentYear, uint8 jerseyNumber, uint8 position)
    {
        IdentityData memory d = _identities[id];
        return (d.countryCode, d.tournamentYear, d.jerseyNumber, d.position);
    }

    /// @dev Internal-friendly accessor that returns the full struct.
    function identityData(uint16 id) external view returns (IdentityData memory) {
        return _identities[id];
    }

    function slotStateOf(uint16 id) external view returns (SlotState memory) {
        return _slotState[id];
    }

    /// @notice Total cards currently alive across all versions of `id`.
    /// Has no upper bound — it is the sum of all simultaneously circulating
    /// prints (any version). Not the input to the gacha weight: that is
    /// `identityWeight(id)`, which depends on the current version's open slots.
    function currentCopies(uint16 id) public view returns (uint16) {
        return _slotState[id].circulating;
    }

    /// @notice 0 / 1 indicator whether this identity is currently in the mint
    /// pool — i.e. Active AND its current version still has print slots left.
    /// Returns 1 when mintable, 0 otherwise. The gacha is uniform across the
    /// set of identities returning 1.
    function identityWeight(uint16 id) public view returns (uint8) {
        if (id >= _identityCount) return 0;
        if (identityStatus[id] != IdentityStatus.Active) return 0;
        if (_slotState[id].currentVersionPrintCount >= MAX_PRINTS_PER_VERSION) return 0;
        return 1;
    }

    // ----- IXI: token / ownership views -----

    function totalSupply() public view override(ERC20, IXI) returns (uint256) {
        return ERC20.totalSupply();
    }

    function holdersCount() external view override returns (uint256) {
        return _holderList.length;
    }

    function ownerTokenCount(address owner_) external view override returns (uint256) {
        return _ownerTokenCounts[owner_];
    }

    function balanceOfIdentity(address owner_, uint16 identityId)
        external
        view
        override
        returns (uint16)
    {
        return _balanceByIdentity[owner_][identityId];
    }

    function ownerTokensPage(address owner_, uint256 page, uint256 pageSize)
        external
        view
        override
        returns (TokenView[] memory result)
    {
        uint256 total = _ownerTokenCounts[owner_];
        uint256 startIdx = page * pageSize;
        if (startIdx >= total) return new TokenView[](0);
        uint256 endIdx = startIdx + pageSize;
        if (endIdx > total) endIdx = total;
        result = new TokenView[](endIdx - startIdx);
        for (uint256 i = 0; i < endIdx - startIdx; i++) {
            uint256 tokenId = _ownedTokens[owner_][startIdx + i];
            TokenData memory t = _tokens[tokenId];
            result[i] = TokenView({
                tokenId: tokenId,
                identityId: t.identityId,
                versionNumber: t.versionNumber,
                printIndex: t.printIndex
            });
        }
    }

    function ownerTokenAt(address owner_, uint256 index)
        external
        view
        override
        returns (TokenView memory)
    {
        if (index >= _ownerTokenCounts[owner_]) revert TokenIndexOutOfRange();
        uint256 tokenId = _ownedTokens[owner_][index];
        TokenData memory t = _tokens[tokenId];
        return TokenView({
            tokenId: tokenId,
            identityId: t.identityId,
            versionNumber: t.versionNumber,
            printIndex: t.printIndex
        });
    }

    function ownerOwns(address owner_, uint256 tokenId) external view override returns (bool) {
        return _tokenOwner[tokenId] == owner_;
    }

    function tokenInfo(uint256 tokenId) external view override returns (uint16, uint16, uint8) {
        TokenData memory t = _tokens[tokenId];
        return (t.identityId, t.versionNumber, t.printIndex);
    }

    /// @notice On-chain SVG for a Player card. View-only; intended for marketplaces
    /// and portfolio rendering. Returns the raw SVG string — callers
    /// wrap it in their own `data:image/svg+xml;base64,…` JSON metadata.
    ///
    /// Seed = keccak256(identityId, versionNumber, salt) — deterministic per
    /// (identity, version) pair, so all prints of the same version share the
    /// exact same artwork ("a print run looks like a print run"). A burn forces
    /// the next mint into a new version → new artwork.
    function playerSvg(uint256 tokenId) external view returns (string memory) {
        if (playerArt == address(0)) revert PlayerArtNotSet();
        if (_tokenOwner[tokenId] == address(0)) revert TokenDoesNotExist();
        TokenData memory t = _tokens[tokenId];
        uint256 seed =
            uint256(keccak256(abi.encode(t.identityId, t.versionNumber, _PLAYER_ART_SALT)));
        return IXIPlayerArt(playerArt).generate(seed);
    }

    function tokenOwner(uint256 tokenId) external view override returns (address) {
        return _tokenOwner[tokenId];
    }

    function isHolder(address addr) external view override returns (bool) {
        return _holderListNumbers[addr] != 0;
    }

    function holderAt(uint256 index) external view override returns (address) {
        return _holderList[index];
    }

    // ----- IXI: card transfer (user-to-user) -----

    function transferCard(address to, uint256 tokenId) external override {
        address from = msg.sender;
        if (_tokenOwner[tokenId] != from) revert NotTokenOwner();
        _transferCard(from, to, tokenId);
        _transfer(from, to, UNIT_PER_CARD);
    }

    function transferCardsList(address to, uint256[] calldata tokenIds) external override {
        address from = msg.sender;
        for (uint256 i = 0; i < tokenIds.length; i++) {
            if (_tokenOwner[tokenIds[i]] != from) revert NotTokenOwner();
            _transferCard(from, to, tokenIds[i]);
        }
        _transfer(from, to, UNIT_PER_CARD * tokenIds.length);
    }

    // ----- IXI: admin (append-only governance) -----

    function appendIdentity(IdentityData calldata data)
        public
        override
        onlyOwner
        returns (uint16 newId)
    {
        newId = _appendIdentity(data);
        emit IdentityAppended(newId, data);
    }

    function appendBatch(IdentityData[] calldata dataList)
        external
        override
        onlyOwner
        returns (uint16 firstNewId, uint16 lastNewId)
    {
        if (dataList.length == 0) revert EmptyAppend();
        firstNewId = _identityCount;
        for (uint256 i = 0; i < dataList.length; i++) {
            _appendIdentity(dataList[i]);
        }
        lastNewId = _identityCount - 1;
        // One log per batch instead of per row — saves ~1-3K gas × N
        // (~10-30M gas total at the 10k-identity Phase 1 seed).
        emit IdentitiesAppended(firstNewId, lastNewId);
    }

    function correctWithErrata(
        uint16 erroneousId,
        IdentityData calldata correctedData,
        string calldata reason
    ) external override onlyOwner returns (uint16 correctedId) {
        if (erroneousId >= _identityCount) revert InvalidIdentity();
        if (identityStatus[erroneousId] == IdentityStatus.Errata) {
            revert IdentityAlreadyErrata();
        }
        // Order matters: drain old id from the pool before appending the new one
        // (otherwise the new id's slots would be touched by _removeIdFromPool's
        // tail-walk if they happened to share a tail position).
        _removeIdFromPool(erroneousId);
        identityStatus[erroneousId] = IdentityStatus.Errata;
        correctedId = _appendIdentity(correctedData);
        correctedBy[erroneousId] = correctedId;
        emit IdentityCorrected(erroneousId, correctedId, reason);
    }

    function markDeprecated(uint16 identityId, string calldata reason) external override onlyOwner {
        if (identityId >= _identityCount) revert InvalidIdentity();
        _removeIdFromPool(identityId);
        identityStatus[identityId] = IdentityStatus.Deprecated;
        emit IdentityDeprecated(identityId, reason);
    }

    // ----- ERC20 sync (the heart of the protocol) -----

    function _afterTokenTransfer(address from, address to, uint256 amount) internal override {
        if (pool == address(0) && from != presale) return;
        _onTokenTransfer(from, to, amount);
    }

    function _onTokenTransfer(address from, address to, uint256 amount) internal {
        // Gacha mint sources:
        //   - pool → user (swap)
        //   - presale → user (sale)  — `to != pool` excludes the
        //     presale → vault settlement that happens during LP finalize's
        //     CL_MINT_POSITION (afterAddLiquidity has already set
        //     pool=vault by the time settlePair runs).
        //   - airdrop → user (Unipeg holder retro claim) — same exclusion
        //     for safety, though airdrop has no vault settlement path.
        bool isMintSource = (from == pool && to != address(0))
            || (from != address(0) && from == presale && to != address(0) && to != pool)
            || (from != address(0) && from == airdrop && to != address(0) && to != pool);
        if (isMintSource) {
            if (_NOT_MINTABLE_ACCOUNT == to) return;
            if (from != presale) require(isStarted(), "not started");
            require(amount <= maxBuy(), "buy limit");
            _mintCardsForBuyer(to, amount / UNIT_PER_CARD);
            return;
        }

        // For non-pool transfers we need to balance card movements with the
        // ERC20 movement. We compute "max cards allowed" for both sides based
        // on their post-transfer balance (already updated) and shuffle accordingly.
        uint256 fromMaxAllowed = balanceOf(from) / UNIT_PER_CARD;
        uint256 fromCount = _ownerTokenCounts[from];
        uint256 fromRemoveCount = fromCount > fromMaxAllowed ? fromCount - fromMaxAllowed : 0;
        if (fromRemoveCount == 0) return;

        bool toCanReceive = (to != pool && to != address(0));
        uint256 toMaxAllowed = toCanReceive ? balanceOf(to) / UNIT_PER_CARD : 0;
        uint256 toCount = _ownerTokenCounts[to];
        uint256 toReceiveAllowed = toCount < toMaxAllowed ? toMaxAllowed - toCount : 0;

        uint256 moveQty = fromRemoveCount < toReceiveAllowed ? fromRemoveCount : toReceiveAllowed;
        if (moveQty > 0) {
            _moveCards(from, to, moveQty);
        }
        _burnCards(from, fromRemoveCount - moveQty);
    }

    // ----- Internal: card mint / burn / transfer primitives -----

    /// @dev Per-buyer batch mint via uniform pick over `_slotPool`. Each Active
    /// identity contributes 0 or 1 entry to the pool, so the pick is uniform
    /// across the set of currently-mintable identities.
    ///
    /// Per draw:
    ///   1. swap-with-last + pop the chosen entry
    ///   2. increment `currentVersionPrintCount`
    ///   3. push the id back **unless** that mint just hit
    ///      `MAX_PRINTS_PER_VERSION` (in which case the identity drops out of
    ///      the pool until a burn re-opens it via `_burnCard`)
    ///
    /// `len` tracks the live pool length locally so each draw avoids a fresh
    /// SLOAD on `_slotPool.length`. It can stay flat (push-back), drop by 1
    /// (no push-back when version fills), and the loop stops once every
    /// remaining entry has filled or the buyer's quota runs out.
    ///
    /// Version bumps live on the burn path (`_burnCard`), not here — minting
    /// never starts a new version.
    function _mintCardsForBuyer(address to, uint256 qty) internal {
        if (qty == 0) return;
        uint256 len = _slotPool.length;
        if (len == 0) return;

        Random memory random = _createRandom();

        // Local accumulators — flushed to storage once after the loop.
        uint256 nextTokenId = _tokenIdCounter;
        uint256 ownerIdx = _ownerTokenCounts[to];

        for (uint256 m = 0; m < qty; m++) {
            if (len == 0) break;

            uint256 idx = random.next() % len;
            uint16 picked = _slotPool[idx];

            // swap-with-last + pop. When idx == last we just pop.
            uint256 last = len - 1;
            if (idx != last) {
                _slotPool[idx] = _slotPool[last];
            }
            _slotPool.pop();
            len = last;

            SlotState storage s = _slotState[picked];
            uint8 nextPrint = s.currentVersionPrintCount + 1;
            s.currentVersionPrintCount = nextPrint;
            uint16 versionNumber = s.currentVersion;
            uint8 printIndex = nextPrint;
            unchecked {
                s.circulating += 1;
            }

            // Re-arm the pool entry unless the current version just filled.
            if (nextPrint < MAX_PRINTS_PER_VERSION) {
                _slotPool.push(picked);
                unchecked {
                    len += 1;
                }
            }

            unchecked {
                nextTokenId += 1;
            }
            uint256 tokenId = nextTokenId;
            _tokens[tokenId] = TokenData({
                identityId: picked,
                versionNumber: versionNumber,
                printIndex: printIndex
            });
            _tokenOwner[tokenId] = to;
            _ownedTokens[to][ownerIdx] = tokenId;
            _ownedTokenIndex[tokenId] = ownerIdx;
            unchecked {
                ownerIdx += 1;
                _balanceByIdentity[to][picked] += 1;
            }

            emit OnTokenMinted(to, tokenId, picked, versionNumber, printIndex);
        }

        // Single sstore per accumulator instead of one per minted card.
        _tokenIdCounter = nextTokenId;
        _ownerTokenCounts[to] = ownerIdx;
        _addHolder(to);
    }

    function _burnCards(address user, uint256 qty) internal {
        for (uint256 i = 0; i < qty; i++) {
            uint256 count = _ownerTokenCounts[user];
            if (count == 0) break;
            uint256 tokenId = _ownedTokens[user][count - 1];
            _burnCard(user, tokenId);
        }
    }

    function _moveCards(address from, address to, uint256 qty) internal {
        for (uint256 i = 0; i < qty; i++) {
            uint256 count = _ownerTokenCounts[from];
            if (count == 0) break;
            uint256 tokenId = _ownedTokens[from][count - 1];
            _transferCard(from, to, tokenId);
        }
    }

    function _burnCard(address user, uint256 tokenId) internal {
        TokenData memory t = _tokens[tokenId];
        SlotState storage s = _slotState[t.identityId];

        // Rule A: any burn of a *current-version* card closes that version
        // and opens the next one. With the 1-entry-per-id pool layout, this
        // means:
        //   - if the closed version was full (printCount == 5), the identity
        //     had been removed from the pool — push it back so the new
        //     version is mintable
        //   - otherwise the entry is already in the pool from the prior
        //     partial fill — leave it; it will be picked next as v+1 print 1
        //
        // Errata / Deprecated identities are excluded: admin has already
        // drained their pool entry permanently and must stay drained.
        //
        // Burning an *older-version* card (`t.versionNumber < s.currentVersion`)
        // is a no-op on the version/pool side — only `circulating` drops.
        // This is the user-visible "v1 prints 2,3,4,5 burned, weight
        // unchanged" property: once v1 has been closed by the first burn,
        // burning the remaining v1 prints does not increase mint odds.
        if (
            t.versionNumber == s.currentVersion
                && identityStatus[t.identityId] == IdentityStatus.Active
        ) {
            if (s.currentVersionPrintCount == MAX_PRINTS_PER_VERSION) {
                _slotPool.push(t.identityId);
            }
            unchecked {
                s.currentVersion += 1;
            }
            s.currentVersionPrintCount = 0;
        }

        unchecked {
            s.circulating -= 1;
            _balanceByIdentity[user][t.identityId] -= 1;
        }

        _removeFromOwner(user, tokenId);
        delete _tokens[tokenId];
        delete _tokenOwner[tokenId];
        _maybeRemoveHolder(user);

        emit OnTokenBurned(user, tokenId);
    }

    function _transferCard(address from, address to, uint256 tokenId) internal {
        if (to == pool || to == address(0)) revert AddressCanNotReceiveCard();
        TokenData memory t = _tokens[tokenId];
        _removeFromOwner(from, tokenId);
        unchecked {
            _balanceByIdentity[from][t.identityId] -= 1;
            _balanceByIdentity[to][t.identityId] += 1;
        }
        _maybeRemoveHolder(from);

        _tokenOwner[tokenId] = to;
        _addToOwner(to, tokenId);
        _addHolder(to);

        emit OnTokenTransfer(from, to, tokenId);
    }

    // ----- Internal: mint pool -----

    /// @dev Drain every remaining `_slotPool` entry for `id`. Walks tail-to-head
    /// so swap-with-last shifts never invalidate already-visited indices.
    /// O(M) where M = `_slotPool.length`. Used by errata / deprecation, not
    /// hot paths — admin-only, infrequent.
    function _removeIdFromPool(uint16 id) internal {
        uint256 i = _slotPool.length;
        while (i > 0) {
            unchecked {
                i -= 1;
            }
            if (_slotPool[i] == id) {
                uint256 last = _slotPool.length - 1;
                if (i != last) {
                    _slotPool[i] = _slotPool[last];
                }
                _slotPool.pop();
            }
        }
    }

    function _createRandom() internal view returns (Random memory) {
        uint256 seed = _randomSeedProvider == address(0)
            ? block.prevrandao
            : IRandomSeedProvider(_randomSeedProvider).randomSeed();
        return Random({seed: seed, nonce: 0});
    }

    // ----- Internal: identity registry mutator -----

    function _appendIdentity(IdentityData calldata data) internal returns (uint16 newId) {
        newId = _identityCount++;
        _identities[newId] = data;
        // Initialize the current version so the very first mint of this
        // identity emits v1 print 1 (rather than v0). Burns will advance to
        // v2, v3, ...
        _slotState[newId].currentVersion = 1;
        // 1 pool entry per identity — present iff the current version still
        // has print slots left. Mint pulls it out, push-back keeps it there
        // until the version fills (MAX_PRINTS_PER_VERSION = 5).
        _slotPool.push(newId);
        // Note: no event emitted here — callers (`appendIdentity` /
        // `appendBatch`) emit at their own granularity. `correctWithErrata`
        // intentionally suppresses any append-side log; its `IdentityCorrected`
        // event already carries the new id.
    }

    // ----- Internal: owner tokens reverse map -----

    function _addToOwner(address owner_, uint256 tokenId) internal {
        uint256 idx = _ownerTokenCounts[owner_];
        _ownedTokens[owner_][idx] = tokenId;
        _ownedTokenIndex[tokenId] = idx;
        _ownerTokenCounts[owner_] = idx + 1;
    }

    function _removeFromOwner(address owner_, uint256 tokenId) internal {
        uint256 lastIdx = _ownerTokenCounts[owner_] - 1;
        uint256 idx = _ownedTokenIndex[tokenId];
        if (idx != lastIdx) {
            uint256 lastTokenId = _ownedTokens[owner_][lastIdx];
            _ownedTokens[owner_][idx] = lastTokenId;
            _ownedTokenIndex[lastTokenId] = idx;
        }
        delete _ownedTokens[owner_][lastIdx];
        delete _ownedTokenIndex[tokenId];
        _ownerTokenCounts[owner_] = lastIdx;
    }

    // ----- Internal: holder list -----

    function _addHolder(address addr) internal {
        if (_holderListNumbers[addr] != 0) return; // already a holder
        _holderList.push(addr);
        _holderListNumbers[addr] = _holderList.length; // 1-indexed
    }

    function _maybeRemoveHolder(address addr) internal {
        if (_ownerTokenCounts[addr] != 0) return;
        uint256 holderNumber = _holderListNumbers[addr];
        if (holderNumber == 0) return;
        uint256 lastIdx = _holderList.length - 1;
        uint256 idx = holderNumber - 1;
        if (idx != lastIdx) {
            address lastHolder = _holderList[lastIdx];
            _holderList[idx] = lastHolder;
            _holderListNumbers[lastHolder] = holderNumber;
        }
        _holderList.pop();
        delete _holderListNumbers[addr];
    }
}
