// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Fixture, SwapParams, ModifyLiquidityParams} from "./Fixture.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

contract LaunchPriceTest is Fixture {
    function test_policyMarketCapTradesInBothCurrencyOrders(bool tokenFirst) public {
        uint256 numerator = tokenFirst ? 2500 : 1_000_000_000;
        uint256 denominator = tokenFirst ? 1_000_000_000 : 2500;
        uint160 price = uint160(Math.sqrt(numerator * (1 << 192) / denominator));
        _setupAtPrice(tokenFirst, false, price);
        router.modify(
            key,
            ModifyLiquidityParams(-887220, 887220, LIQUIDITY, bytes32(0)),
            tokenFirst ? 880_000_000 ether : 2200 ether,
            tokenFirst ? 2200 ether : 880_000_000 ether
        );
        uint256 beforePair = imd.balanceOf(address(this));
        uint256 beforeToken = token.balanceOf(address(this));
        router.swap(key, _params(true, true, 1 ether), 1 ether, 300_000 ether);
        assertEq(beforePair - imd.balanceOf(address(this)), 1 ether);
        assertGt(token.balanceOf(address(this)) - beforeToken, 300_000 ether);
        assertEq(_claims(), 0.02 ether);
        beforePair = imd.balanceOf(address(this));
        router.swap(key, _params(false, false, 1 ether), 1_000_000 ether, 1 ether);
        assertEq(imd.balanceOf(address(this)) - beforePair, 1 ether);
        assertEq(_claims(), 0.02 ether + _ceil(1 ether * 2, 98));
        beforeToken = token.balanceOf(address(this));
        router.swap(key, _params(true, false, 1000 ether), 0.01 ether, 1000 ether);
        assertEq(token.balanceOf(address(this)) - beforeToken, 1000 ether);
        beforeToken = token.balanceOf(address(this));
        router.swap(key, _params(false, true, 1000 ether), 1000 ether, 0.001 ether);
        assertEq(beforeToken - token.balanceOf(address(this)), 1000 ether);
        pot.redeemFees(_claims());
        assertEq(imd.balanceOf(address(pot)), hook.totalFees());
    }
}
