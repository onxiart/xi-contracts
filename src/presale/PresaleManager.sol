// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {PoolKey} from "infinity-core/src/types/PoolKey.sol";
import {Currency} from "infinity-core/src/types/Currency.sol";
import {IPoolManager} from "infinity-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "infinity-core/src/interfaces/IHooks.sol";
import {
    CLPoolParametersHelper
} from "infinity-core/src/pool-cl/libraries/CLPoolParametersHelper.sol";
import {TickMath} from "infinity-core/src/pool-cl/libraries/TickMath.sol";
import {FullMath} from "infinity-core/src/pool-cl/libraries/FullMath.sol";
import {LiquidityAmounts} from "infinity-periphery/src/pool-cl/libraries/LiquidityAmounts.sol";
import {ICLPositionManager} from "infinity-periphery/src/pool-cl/interfaces/ICLPositionManager.sol";
import {Actions} from "infinity-periphery/src/libraries/Actions.sol";
import {Plan, Planner} from "infinity-periphery/src/libraries/Planner.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
import {XI} from "../xi/XI.sol";
import {XIHook} from "../xi_hook/XIHook.sol";
import {IPresaleManager} from "./IPresaleManager.sol";

/// @title PresaleManager — fixed-price direct mint sale for XI.
///
/// Lifecycle:
///   Deploy     constructor() — claims the BNB/XI PoolKey up front so the
///              final liquidity add cannot be frontrun.
///   Sale       buy(quantity) — fixed-price direct mint, up to XI.maxBuy()
///              per purchase. XI transfers straight to the buyer, which
///              triggers the same gacha Player-card mint as a pool swap.
///              BNB is auto-split: TEAM_BNB share goes to TEAM_ immediately,
///              LP_BNB share stays in the contract.
///   Finalize   finalize() — once all PRESALE_TOKENS are sold, anyone can:
///                  1) send TEAM_TOKENS XI to TEAM_WALLET
///                  2) mint full-range LP with LP_TOKENS + LP_BNB into the
///                     pre-initialized pool (this triggers
///                     hook.afterAddLiquidity → XI.start)
///                  3) burn the LP NFT to 0xdEaD
///
/// @dev XI ownership stays with admin. PresaleManager only handles sale
///      inventory and the LP bootstrapping path.
contract PresaleManager is IPresaleManager, Ownable, ReentrancyGuard {
    using CLPoolParametersHelper for bytes32;
    using Planner for Plan;
    using SafeERC20 for IERC20;

    // ---------------------------------------------------------------- constants

    uint256 private constant UNIT_PER_CARD = 1e18;

    /// @notice Token allocation (10000 XI total = TEAM 2000 + LP 3000 + PRESALE 5000).
    /// AirdropManager is funded ad-hoc by team (post-finalize) from TEAM_TOKENS.
    /// These splits are protocol-level invariants and never differ between
    /// testnet and mainnet — only the per-XI price differs across environments,
    /// and HARD_CAP / TEAM_BNB / LP_BNB are derived from PRICE_PER_XI at deploy.
    uint256 public constant TEAM_TOKENS = 2_000e18;
    uint256 public constant LP_TOKENS = 3_000e18;
    uint256 public constant PRESALE_TOKENS = 5_000e18;

    /// @dev Pool params: LP fee = 0 (XIHook skims 1% directly via afterSwap).
    uint24 public constant POOL_FEE = 0;
    int24 public constant TICK_SPACING = 60;
    int24 public constant TICK_LOWER = -887_220; // floor(MIN_TICK / 60) * 60
    int24 public constant TICK_UPPER = 887_220;

    address public constant DEAD = 0x000000000000000000000000000000000000dEaD;

    // ---------------------------------------------------------------- per-deployment

    /// @notice Fixed sale price per 1 XI in BNB wei. **Source of truth** for the
    /// presale economics — testnet 5e12 wei (0.000005 BNB) / mainnet 5e15 wei
    /// (0.005 BNB). Set via constructor arg so testnet and mainnet share
    /// identical bytecode.
    uint256 public immutable PRICE_PER_XI;

    /// @notice Total BNB the presale collects when fully sold = PRICE_PER_XI × 5000.
    /// Mainnet: 25 ether. Testnet rehearsal: 0.025 ether. Derived at deploy.
    uint256 public immutable HARD_CAP;

    /// @notice 15% of HARD_CAP — auto-paid to TEAM_ on every buy.
    uint256 public immutable TEAM_BNB;

    /// @notice 85% of HARD_CAP — held by this contract until finalize().
    uint256 public immutable LP_BNB;

    /// @notice Initial sqrtPriceX96 used to seed the BNB/XI pool. **Pure
    /// derivation from PRICE_PER_XI** — `floor(sqrt(LP_TOKENS × 2^192 / LP_BNB))`,
    /// computed in the constructor. No env input needed.
    /// Testnet (PRICE_PER_XI 5e12, LP_BNB 0.02125 ether) ⇒ 29768759942684519904284778266425.
    /// Mainnet (PRICE_PER_XI 5e15, LP_BNB 21.25 ether) ⇒ 941370845376665816347297325280.
    uint160 public immutable SQRT_PRICE_X96_INIT;

    // ---------------------------------------------------------------- immutables

    XI internal immutable XI_TOKEN;
    XIHook internal immutable HOOK;
    ICLPositionManager internal immutable POSITION_MANAGER;
    IPoolManager internal immutable POOL_MANAGER;
    IAllowanceTransfer internal immutable PERMIT2;
    address internal immutable TEAM_;
    address internal immutable ADMIN_;

    function xiToken() external view returns (XI) {
        return XI_TOKEN;
    }

    function hook() external view returns (XIHook) {
        return HOOK;
    }

    function positionManager() external view returns (ICLPositionManager) {
        return POSITION_MANAGER;
    }

    function poolManager() external view returns (IPoolManager) {
        return POOL_MANAGER;
    }

    function permit2() external view returns (IAllowanceTransfer) {
        return PERMIT2;
    }

    function team() external view returns (address) {
        return TEAM_;
    }

    function admin() external view returns (address) {
        return ADMIN_;
    }

    // ---------------------------------------------------------------- state

    mapping(address => uint256) public purchased;
    uint256 public sold;
    uint256 public raised;
    bool public finalized;
    uint256 public lpTokenId;

    function remaining() public view returns (uint256) {
        return PRESALE_TOKENS - sold;
    }

    function lpReserve() external view returns (uint256) {
        return address(this).balance;
    }

    // ---------------------------------------------------------------- ctor

    constructor(
        XI xi_,
        XIHook hook_,
        ICLPositionManager positionManager_,
        IAllowanceTransfer permit2_,
        address team_,
        address admin_,
        uint256 pricePerXi_
    ) Ownable(admin_) {
        if (pricePerXi_ == 0) revert ZeroValue();

        XI_TOKEN = xi_;
        HOOK = hook_;
        POSITION_MANAGER = positionManager_;
        POOL_MANAGER = IPoolManager(address(positionManager_.clPoolManager()));
        PERMIT2 = permit2_;
        TEAM_ = team_;
        ADMIN_ = admin_;

        // PRICE_PER_XI is the source of truth. HARD_CAP = price × 5000 XI.
        // PRESALE_TOKENS / UNIT_PER_CARD == 5000 (XI count, not wei).
        uint256 hardCap = pricePerXi_ * (PRESALE_TOKENS / UNIT_PER_CARD);
        // Derive 15% / 85% via a local so TEAM_BNB + LP_BNB == HARD_CAP exactly
        // (no rounding drift on values whose lowest 2 decimal digits aren't 0).
        uint256 teamBnb = (hardCap * 15) / 100;
        uint256 lpBnb = hardCap - teamBnb;
        PRICE_PER_XI = pricePerXi_;
        HARD_CAP = hardCap;
        TEAM_BNB = teamBnb;
        LP_BNB = lpBnb;

        // Derive sqrtPriceX96 from LP_BNB. FullMath.mulDiv handles the
        // 2^263-scale intermediate (LP_TOKENS × 2^192) without overflow.
        // For our PRICE_PER_XI ranges (5e12 testnet → 5e15 mainnet), the
        // result lands at ~3e31 / ~9.4e29, both well under uint160 max
        // (~1.46e48), so the cast is safe.
        uint256 sqrtPriceX96 = _sqrt(FullMath.mulDiv(LP_TOKENS, 1 << 192, lpBnb));
        // forge-lint: disable-next-line(unsafe-typecast)
        SQRT_PRICE_X96_INIT = uint160(sqrtPriceX96);

        // Claim the PoolKey at deploy time to prevent frontrun griefing of the
        // eventual LP mint.
        int24 tick = positionManager_.initializePool(_poolKey(), SQRT_PRICE_X96_INIT);
        if (tick == type(int24).max) revert PoolFrontrunDetected();
    }

    /// @dev Babylonian (Newton's) integer square root. Returns floor(sqrt(x)).
    ///   Used once at deploy time to derive SQRT_PRICE_X96_INIT from LP_BNB,
    ///   so gas is paid only once. Worst-case ~80 iterations for uint256.
    function _sqrt(uint256 x) private pure returns (uint256 y) {
        if (x == 0) return 0;
        uint256 z = (x + 1) / 2;
        y = x;
        while (z < y) {
            y = z;
            z = (x / z + z) / 2;
        }
    }

    // ---------------------------------------------------------------- sale

    function buy(uint256 quantity) external payable nonReentrant {
        if (finalized) revert AlreadyFinalized();
        if (quantity == 0) revert ZeroQuantity();

        uint256 xiAmount = quantity * UNIT_PER_CARD;
        uint256 cap = XI_TOKEN.maxBuy();
        if (xiAmount > cap) revert PurchaseTooLarge(xiAmount, cap);

        uint256 remainingTokens = remaining();
        if (xiAmount > remainingTokens) revert SoldOut(xiAmount, remainingTokens);

        uint256 expectedPayment = quantity * PRICE_PER_XI;
        if (msg.value != expectedPayment) {
            revert IncorrectPayment(msg.value, expectedPayment);
        }

        sold += xiAmount;
        raised += msg.value;
        purchased[msg.sender] += xiAmount;

        _safeTransfer(XI_TOKEN, msg.sender, xiAmount);
        _sendBnb(TEAM_, (msg.value * TEAM_BNB) / HARD_CAP);

        emit Purchased(
            msg.sender,
            quantity,
            xiAmount,
            msg.value,
            sold,
            raised
        );

        if (!finalized && sold == PRESALE_TOKENS) {
            _finalize();
        }
    }

    function finalize() external nonReentrant {
        _finalize();
    }

    // ---------------------------------------------------------------- rescueERC20

    /// @notice Recover non-XI ERC20 tokens mistakenly sent to this contract.
    /// XI is forbidden — rescuing it would let owner drain buyers' allocation.
    function rescueERC20(address token, address to, uint256 amount)
        external
        onlyOwner
        nonReentrant
    {
        if (token == address(XI_TOKEN)) revert CannotRescueXi();
        if (token == address(0) || to == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroValue();

        emit Erc20Rescued(token, to, amount);
        IERC20(token).safeTransfer(to, amount);
    }

    // ---------------------------------------------------------------- ERC721 receiver

    /// @notice Required so positionManager._safeMint(address(this), …) doesn't revert.
    function onERC721Received(address, address, uint256, bytes calldata)
        external
        pure
        returns (bytes4)
    {
        return this.onERC721Received.selector;
    }

    // ---------------------------------------------------------------- internals

    function _finalize() internal {
        if (finalized) revert AlreadyFinalized();
        if (sold != PRESALE_TOKENS) revert NotSoldOut(sold, PRESALE_TOKENS);
        finalized = true;

        // 1) team payout (tokens)
        _safeTransfer(XI_TOKEN, TEAM_, TEAM_TOKENS);

        // 2) approve permit2 → positionManager for token1 (XI)
        require(XI_TOKEN.approve(address(PERMIT2), type(uint256).max), "XI approve failed");
        PERMIT2.approve(
            address(XI_TOKEN), address(POSITION_MANAGER), type(uint160).max, type(uint48).max
        );

        // 3) mint full-range position to this contract. This triggers
        //    hook.afterAddLiquidity which calls XI.start(vault).
        PoolKey memory key = _poolKey();
        uint128 liquidity = LiquidityAmounts.getLiquidityForAmounts(
            SQRT_PRICE_X96_INIT,
            TickMath.getSqrtRatioAtTick(TICK_LOWER),
            TickMath.getSqrtRatioAtTick(TICK_UPPER),
            LP_BNB,
            LP_TOKENS
        );

        uint256 tokenId = POSITION_MANAGER.nextTokenId();
        Plan memory plan = Planner.init();
        plan = plan.add(
            Actions.CL_MINT_POSITION,
            abi.encode(
                key,
                TICK_LOWER,
                TICK_UPPER,
                uint256(liquidity),
                // forge-lint: disable-next-line(unsafe-typecast)
                uint128(LP_BNB),
                // forge-lint: disable-next-line(unsafe-typecast)
                uint128(LP_TOKENS),
                address(this),
                bytes("")
            )
        );
        bytes memory payload = plan.finalizeModifyLiquidityWithSettlePair(key);
        POSITION_MANAGER.modifyLiquidities{value: LP_BNB}(payload, block.timestamp);
        lpTokenId = tokenId;

        // 4) burn LP NFT — transfer to 0xdEaD locks fees forever.
        IERC721Min(address(POSITION_MANAGER)).safeTransferFrom(address(this), DEAD, tokenId);

        // 5) Revoke the permit2 allowance granted in step 2.
        PERMIT2.approve(address(XI_TOKEN), address(POSITION_MANAGER), 0, 0);

        emit Finalized(tokenId, SQRT_PRICE_X96_INIT, liquidity);
    }

    function _poolKey() internal view returns (PoolKey memory) {
        bytes32 hookParameters =
            bytes32(uint256(HOOK.getHooksRegistrationBitmap())).setTickSpacing(TICK_SPACING);
        return PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(address(XI_TOKEN)),
            hooks: IHooks(address(HOOK)),
            poolManager: POOL_MANAGER,
            fee: POOL_FEE,
            parameters: hookParameters
        });
    }

    function _safeTransfer(XI token, address to, uint256 amount) internal {
        bool ok = token.transfer(to, amount);
        if (!ok) revert TransferFailed();
    }

    function _sendBnb(address to, uint256 amount) internal {
        if (amount == 0) return;
        (bool ok,) = to.call{value: amount}("");
        if (!ok) revert TransferFailed();
    }

    /// @dev Receive BNB only as fallback protection. Purchases use `buy()`.
    receive() external payable {
        revert DirectTransferNotAllowed();
    }
}

interface IERC721Min {
    function safeTransferFrom(address from, address to, uint256 tokenId) external;
}
