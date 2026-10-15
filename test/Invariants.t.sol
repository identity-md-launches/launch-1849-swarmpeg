// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {
    Fixture,
    SwarmPeg,
    SwarmPegHook,
    PoolKey,
    Currency,
    PoolManager,
    PoolHarness,
    SwapParams,
    TickMath
} from "./Fixture.sol";
import {SwarmMaintenance} from "../src/SwarmMaintenance.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {TransientStateLibrary} from "v4-core/src/libraries/TransientStateLibrary.sol";

contract SwarmHandler is Test {
    SwarmPeg public immutable token;
    MockERC20 public immutable imd;
    PoolHarness public immutable router;
    SwarmPegHook public immutable hook;
    SwarmMaintenance public immutable pot;
    PoolKey internal key;
    address[4] public holders;
    uint256 public redeemed;

    constructor(
        SwarmPeg token_,
        MockERC20 imd_,
        PoolHarness router_,
        SwarmPegHook hook_,
        SwarmMaintenance pot_,
        PoolKey memory key_
    ) {
        token = token_;
        imd = imd_;
        router = router_;
        hook = hook_;
        pot = pot_;
        key = key_;
        holders = [address(this), makeAddr("holder1"), makeAddr("holder2"), makeAddr("holder3")];
        token.approve(address(router), type(uint256).max);
        imd.approve(address(router), type(uint256).max);
    }

    function transferBetween(uint256 fromIndex, uint256 toIndex, uint256 amount) external {
        address from = holders[fromIndex % 4];
        address to = holders[toIndex % 4];
        amount = bound(amount, 0, token.balanceOf(from));
        vm.prank(from);
        token.transfer(to, amount);
    }

    function trade(bool buy, bool exactInput, uint256 amount) external {
        amount = bound(amount, 1000, 100 ether);
        if (token.balanceOf(address(this)) < 10_000 ether || imd.balanceOf(address(this)) < 10_000 ether) return;
        bool pair0 = Currency.unwrap(key.currency0) == address(imd);
        bool zeroForOne = buy == pair0;
        router.swap(
            key,
            SwapParams(
                zeroForOne,
                exactInput ? -int256(amount) : int256(amount),
                zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            ),
            1000 ether,
            0
        );
    }

    function redeem(uint256 amount) external {
        uint256 claims = hook.poolManager().balanceOf(address(pot), uint256(uint160(address(imd))));
        if (claims == 0) return;
        amount = bound(amount, 1, claims);
        redeemed += amount;
        pot.redeemFees(amount);
    }

    function advancePulse(uint256 blocks_) external {
        vm.roll(block.number + bound(blocks_, 1, 200));
        hook.updatePulse();
    }
}

contract SwarmInvariantTest is Fixture {
    SwarmHandler internal handler;

    function setUp() public {
        _setup(true, true);
        handler = new SwarmHandler(token, imd, router, hook, pot, key);
        token.transfer(address(handler), 100_000_000 ether);
        imd.transfer(address(handler), 100_000_000 ether);
        targetContract(address(handler));
        bytes4[] memory selectors = new bytes4[](4);
        selectors[0] = handler.transferBetween.selector;
        selectors[1] = handler.trade.selector;
        selectors[2] = handler.redeem.selector;
        selectors[3] = handler.advancePulse.selector;
        targetSelector(FuzzSelector(address(handler), selectors));
    }

    function invariant_fixedSupplyAndGlyphsMatchEveryWholeBalance() public view {
        uint256 total = token.balanceOf(address(this)) + token.balanceOf(address(manager))
            + token.balanceOf(address(router)) + token.balanceOf(address(pot));
        for (uint256 i; i < 4; ++i) {
            address holder = handler.holders(i);
            uint256 bal = token.balanceOf(holder);
            total += bal;
            assertEq(token.glyphCount(holder), bal / 1 ether);
            if (bal >= 1 ether) {
                assertTrue(token.glyphAt(holder, 0).id != bytes32(0));
                assertTrue(token.glyphAt(holder, bal / 1 ether - 1).id != bytes32(0));
            } else {
                assertEq(token.batchCount(holder), 0);
            }
        }
        assertEq(total, token.totalSupply());
        assertEq(total, 1_000_000_000 ether);
    }

    function invariant_feesConservedAndAllTransientDeltasSettled() public view {
        assertEq(hook.totalFees(), _claims() + handler.redeemed());
        assertEq(imd.balanceOf(address(pot)), handler.redeemed());
        assertEq(imd.balanceOf(address(hook)), 0);
        assertEq(token.balanceOf(address(hook)), 0);
        assertEq(TransientStateLibrary.currencyDelta(manager, address(hook), key.currency0), 0);
        assertEq(TransientStateLibrary.currencyDelta(manager, address(hook), key.currency1), 0);
        assertEq(TransientStateLibrary.currencyDelta(manager, address(router), key.currency0), 0);
        assertEq(TransientStateLibrary.currencyDelta(manager, address(router), key.currency1), 0);
        assertLe(hook.currentPulse(), 1000);
    }
}
