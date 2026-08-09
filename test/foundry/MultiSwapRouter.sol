// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {CurrencySettler} from "@uniswap/v4-core/test/utils/CurrencySettler.sol";

/// @dev Minimal test-only router that executes N swaps against the SAME pool
///      inside a single PoolManager.unlock() callback — i.e. one real EVM
///      "atomic composability unit" from the hook's point of view, as opposed
///      to calling PoolSwapTest.swap() N times (which runs N separate
///      lock/unlock cycles, each fully closing out before the next starts).
///
///      This is the structure that actually exercises the transient-storage
///      flag pairing risk noted in CuratioHook.beforeSwap/afterSwap: multiple
///      swap() calls to the same pool happening before any of them "returns"
///      to an external caller.
///
///      NOTE: import paths / exact PoolManager.swap and settle/take method
///      signatures can drift slightly between v4-core versions — adjust to
///      match whatever version is pinned in your lockfile if this doesn't
///      compile as-is. The core test logic (loop of swaps inside one
///      unlockCallback) is what matters.
contract MultiSwapRouter is IUnlockCallback {
    using CurrencySettler for Currency;

    IPoolManager public immutable manager;

    struct CallbackData {
        PoolKey key;
        SwapParams[] swaps;
        address payer;
    }

    constructor(IPoolManager _manager) {
        manager = _manager;
    }

    /// @notice Executes `swaps.length` swaps against `key`, all inside one
    ///         unlock() callback.
    function multiSwap(PoolKey calldata key, SwapParams[] calldata swaps) external {
        manager.unlock(abi.encode(CallbackData({key: key, swaps: swaps, payer: msg.sender})));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(manager), "Only PoolManager");
        CallbackData memory cbData = abi.decode(data, (CallbackData));

        BalanceDelta totalDelta;

        for (uint256 i = 0; i < cbData.swaps.length; i++) {
            // Each iteration triggers a full beforeSwap -> core swap ->
            // afterSwap cycle for the SAME pool, but none of them "exit" to
            // an external caller between iterations — they all happen inside
            // this single callback execution.
            BalanceDelta delta = manager.swap(cbData.key, cbData.swaps[i], "");
            totalDelta = totalDelta + delta;
        }

        // Settle net deltas at the end (standard v4 test-router settlement
        // pattern via CurrencySettler; matches PoolSwapTest's approach).
        _settleDelta(cbData.key.currency0, cbData.payer, totalDelta.amount0());
        _settleDelta(cbData.key.currency1, cbData.payer, totalDelta.amount1());

        return "";
    }

    function _settleDelta(Currency currency, address payer, int128 amount) internal {
        if (amount < 0) {
            currency.settle(manager, payer, uint256(uint128(-amount)), false);
        } else if (amount > 0) {
            currency.take(manager, payer, uint256(uint128(amount)), false);
        }
    }
}
