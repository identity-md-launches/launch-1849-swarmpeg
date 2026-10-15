// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {SwapParams, ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";

/// @dev Test router. Pulls only from its entry-point caller, settles its own funds,
/// and applies slippage to the final, hook-adjusted amounts. No arbitrary payer.
contract PoolHarness is IUnlockCallback, ReentrancyGuard {
    using SafeERC20 for IERC20;
    IPoolManager public immutable manager;
    error Slippage();

    constructor(IPoolManager manager_) {
        manager = manager_;
    }

    function swap(PoolKey memory key, SwapParams memory params, uint256 maxInput, uint256 minOutput)
        external
        nonReentrant
        returns (BalanceDelta delta)
    {
        IERC20 input = IERC20(Currency.unwrap(params.zeroForOne ? key.currency0 : key.currency1));
        IERC20 output = IERC20(Currency.unwrap(params.zeroForOne ? key.currency1 : key.currency0));
        input.safeTransferFrom(msg.sender, address(this), maxInput);
        delta = abi.decode(manager.unlock(abi.encode(uint8(0), key, abi.encode(params))), (BalanceDelta));
        int128 inputDelta = params.zeroForOne ? delta.amount0() : delta.amount1();
        int128 outputDelta = params.zeroForOne ? delta.amount1() : delta.amount0();
        require(inputDelta <= 0 && outputDelta >= 0, "unexpected signs");
        uint256 used = uint256(-int256(inputDelta));
        uint256 received = uint256(int256(outputDelta));
        if (used > maxInput || received < minOutput) revert Slippage();
        input.safeTransfer(msg.sender, maxInput - used);
        output.safeTransfer(msg.sender, received);
    }

    function modify(PoolKey memory key, ModifyLiquidityParams memory params, uint256 max0, uint256 max1)
        external
        nonReentrant
        returns (BalanceDelta delta)
    {
        IERC20 c0 = IERC20(Currency.unwrap(key.currency0));
        IERC20 c1 = IERC20(Currency.unwrap(key.currency1));
        uint256 before0 = c0.balanceOf(address(this));
        uint256 before1 = c1.balanceOf(address(this));
        c0.safeTransferFrom(msg.sender, address(this), max0);
        c1.safeTransferFrom(msg.sender, address(this), max1);
        delta = abi.decode(manager.unlock(abi.encode(uint8(1), key, abi.encode(params))), (BalanceDelta));
        c0.safeTransfer(msg.sender, c0.balanceOf(address(this)) - before0);
        c1.safeTransfer(msg.sender, c1.balanceOf(address(this)) - before1);
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(manager), "only manager");
        (uint8 op, PoolKey memory key, bytes memory payload) = abi.decode(data, (uint8, PoolKey, bytes));
        BalanceDelta delta;
        if (op == 0) delta = manager.swap(key, abi.decode(payload, (SwapParams)), "");
        else (delta,) = manager.modifyLiquidity(key, abi.decode(payload, (ModifyLiquidityParams)), "");
        _settle(key.currency0, delta.amount0());
        _settle(key.currency1, delta.amount1());
        return abi.encode(delta);
    }

    function _settle(Currency currency, int128 delta) private {
        if (delta < 0) {
            manager.sync(currency);
            IERC20(Currency.unwrap(currency)).safeTransfer(address(manager), uint256(-int256(delta)));
            manager.settle();
        } else if (delta > 0) {
            manager.take(currency, address(this), uint256(int256(delta)));
        }
    }
}
