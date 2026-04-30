// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {PoolKey} from "infinity-core/src/types/PoolKey.sol";
import {Currency, CurrencyLibrary} from "infinity-core/src/types/Currency.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "infinity-core/src/types/BalanceDelta.sol";
import {ICLPoolManager} from "infinity-core/src/pool-cl/interfaces/ICLPoolManager.sol";
import {CLBaseHook} from "./CLBaseHook.sol";
import {OwnableBase} from "../library/OwnableBase.sol";
import {IRandomSeedProvider} from "../library/IRandomSeedProvider.sol";
import {IStartableToken} from "../token/IStartableToken.sol";

/// @title XIHook — PancakeSwap Infinity CL hook for XI token.
/// @notice
/// Responsibilities:
///   1. afterAddLiquidity → call `XI.start(vault)` on first liquidity event,
///      flipping XI from "paused" to "live" (enabling pool→user weighted-random
///      gacha mints from then on).
///
///      ⚠️ MUST pass `vault` (NOT `poolManager`) — PCS Infinity v4 separates
///      accounting (PoolManager) from custody (Vault). The actual XI ERC20
///      `transfer()` during a swap is invoked by `Vault.take()`, so the
///      `_afterTokenTransfer` hook sees `from == vault`. Setting
///      `XI.pool = poolManager` would break the `from == pool` gacha trigger
///      because no transfer ever has `from == poolManager`.
///
///      Note: this differs from Uniswap v4 (e.g. unipeg) where PoolManager
///      directly transfers tokens — there `XI.pool = poolManager` is correct.
///      PCS Infinity adds the Vault layer that Uniswap v4 lacks.
///   2. afterSwap → mix block entropy into `_randomSeed`, used as the random
///      source for XI's weighted identity picks (via setRandomSeedProvider).
///   3. afterSwap → skim 1% of the unspecified-currency leg of every XI swap
///      (exact-input only) as a hook fee. Pool is configured with LP fee = 0,
///      so users see a single 1% effective tax.
///
///      Settlement: PCS Infinity's `vault.lock` enforces zero unsettled deltas
///      at lock exit (`CurrencyNotSettled`), so the hook cannot leave its
///      `+fee` delta hanging in vault accounting and `withdraw()` later from
///      a separate lock — the swap's lock would already have reverted. Instead
///      the hook calls `vault.take(currency, address(this), fee)` *inside*
///      `_afterSwap` to pull the fee into its own ERC20 / native balance, then
///      returns the fee delta. CLHooks subsequently credits the hook with
///      `+fee` via `accountAppDeltaWithHookDelta`, which exactly cancels the
///      `−fee` from the take — net hook delta is 0 at lock exit, and the
///      caller's output is correctly reduced by the fee.
///
///      Direction skim only fires when `unspecified > 0` (user receiving) —
///      exact-output swaps pass through fee-free for simplicity.
contract XIHook is CLBaseHook, OwnableBase, IRandomSeedProvider {
    using BalanceDeltaLibrary for BalanceDelta;
    using CurrencyLibrary for Currency;

    /// @notice 1% hook fee (100 / 10000). Fixed at deploy; no admin knob.
    uint256 public constant SWAP_FEE_BPS = 100;
    uint256 public constant BPS_BASE = 10_000;

    IStartableToken public token;
    uint256 internal _randomSeed;
    uint256 internal _randomCount;

    error ZeroAddress();
    error ZeroAmount();

    event FeesWithdrawn(Currency indexed currency, uint256 amount, address indexed to);

    constructor(ICLPoolManager poolManager_, address owner_)
        CLBaseHook(poolManager_)
        OwnableBase(owner_)
    {
        _randomSeed = block.timestamp;
    }

    function setToken(address tokenAddress) external onlyOwner {
        token = IStartableToken(tokenAddress);
    }

    function isTokenSet() public view returns (bool) {
        return address(token) != address(0);
    }

    function randomSeed() external view override returns (uint256) {
        return _randomSeed;
    }

    function _randomizeSeed() private {
        _randomSeed = uint256(
            keccak256(
                abi.encodePacked(
                    ++_randomCount, _randomSeed, block.timestamp, block.prevrandao, block.number
                )
            )
        );
    }

    function getHooksRegistrationBitmap() external pure override returns (uint16) {
        return _hooksRegistrationBitmapFrom(
            Permissions({
                beforeInitialize: false,
                afterInitialize: false,
                beforeAddLiquidity: false,
                afterAddLiquidity: true,
                beforeRemoveLiquidity: false,
                afterRemoveLiquidity: false,
                beforeSwap: false,
                afterSwap: true,
                beforeDonate: false,
                afterDonate: false,
                beforeSwapReturnDelta: false,
                afterSwapReturnDelta: true,
                afterAddLiquidityReturnDelta: false,
                afterRemoveLiquidityReturnDelta: false
            })
        );
    }

    function _afterAddLiquidity(
        address,
        PoolKey calldata key,
        ICLPoolManager.ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) internal override returns (bytes4, BalanceDelta) {
        bool isToken = isTokenSet()
            && (Currency.unwrap(key.currency0) == address(token)
                || Currency.unwrap(key.currency1) == address(token));
        if (isToken && !token.isStarted()) token.start(address(vault));
        return (this.afterAddLiquidity.selector, BalanceDeltaLibrary.ZERO_DELTA);
    }

    function _afterSwap(
        address,
        PoolKey calldata key,
        ICLPoolManager.SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata
    ) internal override returns (bytes4, int128) {
        bool isToken = isTokenSet()
            && (Currency.unwrap(key.currency0) == address(token)
                || Currency.unwrap(key.currency1) == address(token));
        if (!isToken) return (this.afterSwap.selector, 0);

        _randomizeSeed();

        // Pick the unspecified leg of the swap. v4 convention mirrored from
        // CLHooks.afterSwap line 184:
        //   amountSpecified < 0 → exact-input  (specified = input token)
        //   amountSpecified > 0 → exact-output (specified = output token)
        // Combined with zeroForOne to map to currency0 / currency1.
        int128 unspecified =
            (params.amountSpecified < 0) == params.zeroForOne ? delta.amount1() : delta.amount0();

        // Only skim when the user is receiving on the unspecified leg (i.e.
        // exact-input swaps). Exact-output swaps have the user paying on the
        // unspecified leg — passing those through fee-free keeps the math
        // simple and removes a footgun (taking from a negative delta would
        // mean charging the hook itself).
        if (unspecified <= 0) return (this.afterSwap.selector, 0);

        // CLHooks afterSwap performs `delta = delta - hookDelta`, so a positive
        // returned value moves currency from the user side to the hook side.
        // Magnitude is bounded by XI total supply 10000e18 ≈ 1e22; multiplying
        // by SWAP_FEE_BPS (100) stays at ~1e24, well below int128 max ~1.7e38.
        // unspecified > 0 was checked above, so the uint cast preserves value.
        // forge-lint: disable-next-line(unsafe-typecast)
        uint256 magnitude = uint256(uint128(unspecified));
        uint256 feeAmount = (magnitude * SWAP_FEE_BPS) / BPS_BASE;
        if (feeAmount == 0) return (this.afterSwap.selector, 0);
        // feeAmount ≤ magnitude → fits int128.
        // forge-lint: disable-next-line(unsafe-typecast)
        int128 fee = int128(int256(feeAmount));

        // The unspecified leg = output token (the side the user receives).
        Currency feeCurrency =
            (params.amountSpecified < 0) == params.zeroForOne ? key.currency1 : key.currency0;

        // Pull the fee out as actual ERC20 / native balance now. CLHooks will
        // credit the hook with +fee delta after this returns, exactly cancelling
        // the −fee delta produced by `vault.take`. Net hook delta at lock exit
        // = 0, so SettlementGuard's CurrencyNotSettled check passes. The fee
        // sits as a real balance on this contract until admin withdraws it.
        vault.take(feeCurrency, address(this), feeAmount);

        return (this.afterSwap.selector, fee);
    }

    /// @notice Hook's actual ERC20 / native balance for `currency`. Fees accrue
    /// here as real balances (not vault deltas) — see `_afterSwap` for why.
    function accumulatedFees(Currency currency) external view returns (uint256) {
        return currency.balanceOfSelf();
    }

    /// @notice Route accrued fees (held as real balance) to `to`. Admin only.
    function withdraw(Currency currency, uint256 amount, address to) external onlyOwner {
        if (to == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();
        currency.transfer(to, amount);
        emit FeesWithdrawn(currency, amount, to);
    }

    /// @notice Receive native fees pulled out of the vault during `_afterSwap`.
    receive() external payable {}
}
