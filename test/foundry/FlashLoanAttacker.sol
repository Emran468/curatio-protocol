// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {MockERC20} from "@uniswap/v4-core/lib/solmate/src/test/utils/mocks/MockERC20.sol";

/// @notice Simulates a realistic atomic flash-loan attack: borrow capital,
///         swap hard in one direction to skew the price, then immediately
///         swap back in the SAME transaction before repaying — exactly
///         how a real flash loan must be unwound within one block.
contract FlashLoanAttacker is IUnlockCallback {
    using BalanceDeltaLibrary for BalanceDelta;

    IPoolManager public immutable manager;

    struct CallbackData {
        PoolKey key;
        Currency currency; // the currency the attacker is "borrowing" / holding
        uint256 amount;
    }

    constructor(IPoolManager _manager) {
        manager = _manager;
    }

    /// @notice Entry point called by the test (as attacker) to kick off the attack.
    function executeFlashLoanAttack(PoolKey calldata key, Currency currency, uint256 amount) external {
        CallbackData memory data = CallbackData({key: key, currency: currency, amount: amount});
        manager.unlock(abi.encode(data));
    }

    /// @dev Called back by PoolManager once the lock is acquired.
    function unlockCallback(bytes calldata rawData) external override returns (bytes memory) {
        require(msg.sender == address(manager), "not manager");

        CallbackData memory data = abi.decode(rawData, (CallbackData));
        bool zeroForOne = Currency.unwrap(data.currency) == Currency.unwrap(data.key.currency0);

        // ------------------------------------------------------------
        // 1. Push the price hard in one direction using the borrowed capital.
        // ------------------------------------------------------------
        BalanceDelta delta1 = manager.swap(
            data.key,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -int256(data.amount), // exact input
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            ""
        );

        int128 received = zeroForOne ? delta1.amount1() : delta1.amount0();
        require(received > 0, "swap produced no output");

        // ------------------------------------------------------------
        // 2. Immediately swap back (same block/tx) — this is the part
        //    that makes it a genuine flash-loan-style attack: the
        //    position must be fully unwound before the callback returns.
        // ------------------------------------------------------------
        BalanceDelta delta2 = manager.swap(
            data.key,
            SwapParams({
                zeroForOne: !zeroForOne,
                amountSpecified: -int256(uint256(uint128(received))), // exact input of what we just received
                sqrtPriceLimitX96: !zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            ""
        );

        // ------------------------------------------------------------
        // 3. Net both swaps' deltas together and settle up.
        //    Negative net = we owe the pool -> sync + transfer + settle.
        //    Positive net = pool owes us -> take.
        // ------------------------------------------------------------
        _settleOrTake(data.key.currency0, delta1.amount0() + delta2.amount0());
        _settleOrTake(data.key.currency1, delta1.amount1() + delta2.amount1());

        return "";
    }

    function _settleOrTake(Currency currency, int128 amount) internal {
        if (amount < 0) {
            manager.sync(currency);
            MockERC20(Currency.unwrap(currency)).transfer(address(manager), uint256(uint128(-amount)));
            manager.settle();
        } else if (amount > 0) {
            manager.take(currency, address(this), uint256(uint128(amount)));
        }
    }
}
