// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {
    Fixture,
    Vm,
    PoolKey,
    Currency,
    BalanceDelta,
    SwapParams,
    ModifyLiquidityParams,
    TickMath,
    SwarmPegHook,
    HookFlags
} from "./Fixture.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {BeforeSwapDelta} from "v4-core/src/types/BeforeSwapDelta.sol";
import {TransientStateLibrary} from "v4-core/src/libraries/TransientStateLibrary.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";

abstract contract HookTests is Fixture {
    function test_permissionsInitializationAndSize() public view {
        Hooks.Permissions memory p = hook.getHookPermissions();
        assertTrue(
            p.beforeInitialize && p.beforeSwap && p.afterSwap && p.beforeSwapReturnDelta && p.afterSwapReturnDelta
        );
        assertFalse(p.beforeRemoveLiquidity || p.afterRemoveLiquidity || p.afterAddLiquidityReturnDelta);
        assertTrue(HookFlags.matches(address(hook), HookFlags.SWARMPEG));
        assertTrue(hook.initialized());
        assertEq(PoolId.unwrap(hook.poolId()), PoolId.unwrap(key.toId()));
        assertEq(hook.maintenancePot(), address(pot));
        assertEq(address(pot), vm.computeCreateAddress(address(hook), 1));
        assertGt(address(pot).code.length, 0);
        assertEq(address(pot.poolManager()), address(manager));
        assertEq(address(pot.votingToken()), address(token));
        assertLe(address(hook).code.length, 24576);
    }

    function test_callbacksRejectUnauthorizedAndWrongPools() public {
        SwapParams memory params = _params(true, true, 1 ether);
        vm.expectRevert(SwarmPegHook.OnlyPoolManager.selector);
        hook.beforeInitialize(address(this), key, ONE);
        vm.expectRevert(SwarmPegHook.OnlyPoolManager.selector);
        hook.beforeSwap(address(this), key, params, "");
        vm.expectRevert(SwarmPegHook.OnlyPoolManager.selector);
        hook.afterSwap(address(this), key, params, BalanceDelta.wrap(0), "");
        PoolKey memory wrong = key;
        wrong.fee = 3000;
        vm.expectRevert(SwarmPegHook.InvalidPool.selector);
        vm.prank(address(manager));
        hook.beforeSwap(address(this), wrong, params, "");
        vm.expectRevert(SwarmPegHook.InvalidPool.selector);
        vm.prank(address(manager));
        hook.afterSwap(address(this), wrong, params, BalanceDelta.wrap(0), "");
        vm.expectRevert(SwarmPegHook.AlreadyInitialized.selector);
        vm.prank(address(manager));
        hook.beforeInitialize(address(this), key, ONE);
    }

    function test_buyExactInput() public {
        _assertFee(true, true, 100 ether);
    }

    function test_buyExactOutput() public {
        _assertFee(true, false, 100 ether);
    }

    function test_sellExactInput() public {
        _assertFee(false, true, 100 ether);
    }

    function test_sellExactOutput() public {
        _assertFee(false, false, 100 ether);
    }

    function testFuzz_feeAndSettlement(bool buy, bool exactInput, uint256 amount) public {
        _assertFee(buy, exactInput, bound(amount, 1000, 10_000 ether));
    }

    function _assertFee(bool buy, bool exactInput, uint256 amount) internal {
        uint256 beforeClaims = _claims();
        uint256 beforePair = imd.balanceOf(address(this));
        uint256 beforeToken = token.balanceOf(address(this));
        vm.recordLogs();
        BalanceDelta delta = _trade(buy, exactInput, amount);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 fee;
        uint256 corePair;
        bool found;
        for (uint256 i; i < logs.length; ++i) {
            if (
                logs[i].emitter == address(hook)
                    && logs[i].topics[0] == keccak256("FeeAccrued(bytes32,bool,uint256,uint256,address)")
            ) {
                (bool loggedBuy, uint256 paired, uint256 charged) = abi.decode(logs[i].data, (bool, uint256, uint256));
                assertEq(loggedBuy, buy);
                assertEq(address(uint160(uint256(logs[i].topics[2]))), address(pot));
                fee = charged;
                corePair = paired;
                found = true;
            }
        }
        assertTrue(found);
        uint256 expected = buy && exactInput
            ? _ceil(amount * 2, 100)
            : !buy && !exactInput ? _ceil(amount * 2, 98) : _ceil(corePair * 2, buy ? 98 : 100);
        assertEq(fee, expected);
        assertEq(_claims() - beforeClaims, fee);
        assertEq(hook.totalFees(), _claims());
        assertEq(imd.balanceOf(address(hook)), 0);
        assertEq(token.balanceOf(address(hook)), 0);
        assertEq(address(manager).balance, 0);
        if (buy) {
            assertEq(beforePair - imd.balanceOf(address(this)), corePair + fee);
            assertGt(token.balanceOf(address(this)), beforeToken);
            if (exactInput) assertEq(beforePair - imd.balanceOf(address(this)), amount);
            else assertEq(token.balanceOf(address(this)) - beforeToken, amount);
        } else {
            assertEq(imd.balanceOf(address(this)) - beforePair, corePair - fee);
            assertLt(token.balanceOf(address(this)), beforeToken);
            if (exactInput) assertEq(beforeToken - token.balanceOf(address(this)), amount);
            else assertEq(imd.balanceOf(address(this)) - beforePair, amount);
        }
        assertTrue(delta.amount0() != 0 && delta.amount1() != 0);
        assertEq(TransientStateLibrary.currencyDelta(manager, address(hook), key.currency0), 0);
        assertEq(TransientStateLibrary.currencyDelta(manager, address(hook), key.currency1), 0);
        assertEq(TransientStateLibrary.currencyDelta(manager, address(router), key.currency0), 0);
        assertEq(TransientStateLibrary.currencyDelta(manager, address(router), key.currency1), 0);
    }

    function test_partialPairedSpecifiedRevertsWithoutFees() public {
        uint256 beforePair = imd.balanceOf(address(this));
        uint256 beforeToken = token.balanceOf(address(this));
        SwapParams memory buy = _params(true, true, 10_000 ether);
        buy.sqrtPriceLimitX96 = TickMath.getSqrtPriceAtTick(buy.zeroForOne ? int24(-1) : int24(1));
        vm.expectRevert();
        router.swap(key, buy, 10_000 ether, 0);
        SwapParams memory sell = _params(false, false, 10_000 ether);
        sell.sqrtPriceLimitX96 = TickMath.getSqrtPriceAtTick(sell.zeroForOne ? int24(-1) : int24(1));
        vm.expectRevert();
        router.swap(key, sell, 20_000 ether, 0);
        assertEq(_claims(), 0);
        assertEq(hook.tradeCount(), 0);
        assertEq(imd.balanceOf(address(this)), beforePair);
        assertEq(token.balanceOf(address(this)), beforeToken);
    }

    function test_partialUnspecifiedPairChargesActualFill() public {
        SwapParams memory sell = _params(false, true, 10_000 ether);
        sell.sqrtPriceLimitX96 = TickMath.getSqrtPriceAtTick(sell.zeroForOne ? int24(-1) : int24(1));
        uint256 beforeToken = token.balanceOf(address(this));
        uint256 beforePair = imd.balanceOf(address(this));
        router.swap(key, sell, 10_000 ether, 1);
        assertLt(beforeToken - token.balanceOf(address(this)), 10_000 ether);
        uint256 gross = imd.balanceOf(address(this)) - beforePair + _claims();
        assertEq(_claims(), _ceil(gross * 2, 100));
    }

    function test_slippageFailureRollsBackFeesAndPulse() public {
        vm.expectRevert();
        router.swap(key, _params(true, true, 100 ether), 100 ether, 101 ether);
        assertEq(_claims(), 0);
        assertEq(hook.currentPulse(), 0);
        assertEq(hook.tradeCount(), 0);
    }

    function test_dustAndExtremeAmountsRefused() public {
        SwapParams memory p = _params(true, true, 1);
        vm.expectRevert(SwarmPegHook.InvalidSwapAmount.selector);
        vm.prank(address(manager));
        hook.beforeSwap(address(router), key, p, "");
        p.amountSpecified = type(int256).min;
        vm.expectRevert(SwarmPegHook.InvalidSwapAmount.selector);
        vm.prank(address(manager));
        hook.beforeSwap(address(router), key, p, "");
        p.amountSpecified = 0;
        vm.expectRevert(SwarmPegHook.InvalidSwapAmount.selector);
        vm.prank(address(manager));
        hook.beforeSwap(address(router), key, p, "");
    }

    function test_liquidityCollectionAndRemovalUnrestricted() public {
        _trade(true, true, 100 ether);
        _trade(false, true, 100 ether);
        uint256 fees = hook.totalFees();
        BalanceDelta collected = router.modify(key, ModifyLiquidityParams(-887220, 887220, 0, bytes32(0)), 0, 0);
        assertTrue(collected.amount0() > 0 || collected.amount1() > 0);
        router.modify(key, ModifyLiquidityParams(-887220, 887220, -LIQUIDITY, bytes32(0)), 0, 0);
        assertEq(hook.totalFees(), fees);
    }

    function test_claimRedemptionOnlyPaysPot() public {
        _trade(true, true, 100 ether);
        uint256 fees = _claims();
        vm.prank(alice);
        pot.redeemFees(fees);
        assertEq(_claims(), 0);
        assertEq(imd.balanceOf(address(pot)), fees);
        assertEq(imd.balanceOf(alice), 0);
        vm.expectRevert();
        pot.redeemFees(1);
        assertEq(imd.balanceOf(address(pot)), fees);
    }
}

contract HookTokenFirstTest is HookTests {
    function setUp() public {
        _setup(true, true);
    }
}

contract HookPairFirstTest is HookTests {
    function setUp() public {
        _setup(false, true);
    }
}

contract HookOneSidedTest is Fixture {
    function test_oneSidedTokenOnlySeedBuyWithoutAnyPairInventory(bool tokenFirst) public {
        _setup(tokenFirst, false);
        _seed(tokenFirst ? int24(60) : int24(-600), tokenFirst ? int24(600) : int24(-60));
        assertEq(imd.balanceOf(address(manager)), 0);
        assertEq(address(manager).balance, 0);
        _trade(true, true, 100 ether);
        assertEq(_claims(), 2 ether);
        assertEq(imd.balanceOf(address(manager)), 100 ether);
        pot.redeemFees(2 ether);
        assertEq(imd.balanceOf(address(pot)), 2 ether);
    }
}
