// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IVault} from "infinity-core/src/interfaces/IVault.sol";
import {ILockCallback} from "infinity-core/src/interfaces/ILockCallback.sol";
import {ICLPoolManager} from "infinity-core/src/pool-cl/interfaces/ICLPoolManager.sol";
import {PoolKey} from "infinity-core/src/types/PoolKey.sol";
import {Currency, CurrencyLibrary} from "infinity-core/src/types/Currency.sol";
import {BalanceDelta} from "infinity-core/src/types/BalanceDelta.sol";

interface IERC20 {
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

/// @title SwapHelper — production EOA swap entrypoint for the XI / BNB pool.
///
/// PCS Infinity uses Vault.lock + ILockCallback: an EOA cannot call
/// `PoolManager.swap` directly. This contract is the front-end's bridge —
/// it implements `ILockCallback`, holds no funds between transactions,
/// and supports both directions:
///   - BNB → XI: caller passes msg.value == amountIn
///   - XI → BNB: caller pre-approves XI to this contract; we transferFrom
///                 directly into the vault inside lockAcquired
///
/// V1 only supports exact-input (`amountSpecified < 0`). Exact-output
/// requires refund logic for native input that we do not need yet.
///
/// Slippage protection: caller passes `amountOutMinimum`; the swap reverts
/// inside lockAcquired before `VAULT.take`, so funds never leave the vault
/// when slippage trips.
contract SwapHelper is ILockCallback {
    // TickMath constants (avoid importing the full lib to save bytecode)
    uint160 internal constant MIN_SQRT_RATIO = 4295128739;
    uint160 internal constant MAX_SQRT_RATIO = 1461446703485210103287273052203988822378723970342;

    IVault public immutable VAULT;
    ICLPoolManager public immutable POOL_MANAGER;

    error OnlyVault();
    error ExactInputOnly();
    error NoOutput();
    error InsufficientOutput(uint128 actual, uint128 minimum);

    struct CallData {
        PoolKey key;
        bool zeroForOne;
        int256 amountSpecified; // negative = exact in
        uint160 sqrtPriceLimitX96;
        address payer; // EOA — also receives output
        uint128 amountOutMinimum;
    }

    constructor(IVault vault_, ICLPoolManager poolManager_) {
        VAULT = vault_;
        POOL_MANAGER = poolManager_;
    }

    /// @notice Exact-input swap with slippage protection.
    /// @param key             The pool key (BNB / XI / XIHook).
    /// @param zeroForOne      true = currency0 → currency1 (BNB → XI),
    ///                        false = currency1 → currency0 (XI → BNB).
    /// @param amountSpecified Negative wei of input currency (exact in).
    /// @param amountOutMinimum Revert if output < this (slippage).
    /// @return delta          Final BalanceDelta from the pool.
    function swap(
        PoolKey memory key,
        bool zeroForOne,
        int256 amountSpecified,
        uint128 amountOutMinimum
    ) external payable returns (BalanceDelta delta) {
        if (amountSpecified >= 0) revert ExactInputOnly();

        CallData memory data = CallData({
            key: key,
            zeroForOne: zeroForOne,
            amountSpecified: amountSpecified,
            sqrtPriceLimitX96: zeroForOne ? MIN_SQRT_RATIO + 1 : MAX_SQRT_RATIO - 1,
            payer: msg.sender,
            amountOutMinimum: amountOutMinimum
        });
        bytes memory result = VAULT.lock(abi.encode(data));
        delta = abi.decode(result, (BalanceDelta));
    }

    function lockAcquired(bytes calldata raw) external returns (bytes memory) {
        if (msg.sender != address(VAULT)) revert OnlyVault();
        CallData memory data = abi.decode(raw, (CallData));

        BalanceDelta delta = POOL_MANAGER.swap(
            data.key,
            ICLPoolManager.SwapParams({
                zeroForOne: data.zeroForOne,
                amountSpecified: data.amountSpecified,
                sqrtPriceLimitX96: data.sqrtPriceLimitX96
            }),
            ""
        );

        // 1. Settle the currency we owe the vault.
        Currency curIn = data.zeroForOne ? data.key.currency0 : data.key.currency1;
        int128 deltaIn = data.zeroForOne ? _amount0(delta) : _amount1(delta);
        if (deltaIn < 0) {
            // -deltaIn lives in [1, 2^127] so uint128 cast is safe.
            // forge-lint: disable-next-line(unsafe-typecast)
            uint256 owed = uint256(uint128(-deltaIn));
            if (CurrencyLibrary.isNative(curIn)) {
                VAULT.settle{value: owed}();
            } else {
                VAULT.sync(curIn);
                require(
                    IERC20(Currency.unwrap(curIn)).transferFrom(
                        data.payer, address(VAULT), owed
                    ),
                    "transferFrom failed"
                );
                VAULT.settle();
            }
        }

        // 2. Slippage check before taking — revert keeps funds in the vault.
        Currency curOut = data.zeroForOne ? data.key.currency1 : data.key.currency0;
        int128 deltaOut = data.zeroForOne ? _amount1(delta) : _amount0(delta);
        if (deltaOut <= 0) revert NoOutput();
        // forge-lint: disable-next-line(unsafe-typecast)
        uint128 amountOut = uint128(deltaOut);
        if (amountOut < data.amountOutMinimum) {
            revert InsufficientOutput(amountOut, data.amountOutMinimum);
        }

        // 3. Send output to the EOA that initiated the swap.
        VAULT.take(curOut, data.payer, amountOut);

        return abi.encode(delta);
    }

    // BalanceDelta packs (int128 amount0, int128 amount1) — high half / low half.
    function _amount0(BalanceDelta d) internal pure returns (int128) {
        return int128(BalanceDelta.unwrap(d) >> 128);
    }

    function _amount1(BalanceDelta d) internal pure returns (int128) {
        return int128(BalanceDelta.unwrap(d));
    }

    receive() external payable {}
}
