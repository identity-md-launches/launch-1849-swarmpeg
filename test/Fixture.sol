// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {SwapParams, ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {SwarmPeg} from "../src/SwarmPeg.sol";
import {SwarmPegHook} from "../src/SwarmPegHook.sol";
import {SwarmMaintenance} from "../src/SwarmMaintenance.sol";
import {HookFlags} from "../src/HookFlags.sol";
import {LaunchConstants} from "../src/LaunchConstants.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {PoolHarness} from "./mocks/PoolHarness.sol";

abstract contract Fixture is Test {
    PoolManager internal manager;
    SwarmPeg internal token;
    MockERC20 internal imd;
    SwarmPegHook internal hook;
    SwarmMaintenance internal pot;
    PoolHarness internal router;
    PoolKey internal key;
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal worker = makeAddr("worker");
    uint160 internal constant ONE = 79228162514264337593543950336;
    int256 internal constant LIQUIDITY = 1_000_000 ether;

    function _setup(bool tokenFirst, bool seed) internal {
        _setupAtPrice(tokenFirst, seed, ONE);
    }

    function _setupAtPrice(bool tokenFirst, bool seed, uint160 price) internal {
        manager = new PoolManager(address(this));
        // Both ordering branches are exercised with the actual token constructor.
        address tokenAddress = tokenFirst ? address(0x100000) : address(type(uint160).max - 100_000);
        _constructAt(tokenAddress, type(SwarmPeg).creationCode);
        token = SwarmPeg(tokenAddress);
        imd = MockERC20(LaunchConstants.IMD);
        _constructAt(
            address(imd), abi.encodePacked(type(MockERC20).creationCode, abi.encode("IdentityMD", "IMD", 1e30))
        );
        pot = new SwarmMaintenance(manager, token);
        address hookAddress = address(uint160(0x10000000) | HookFlags.SWARMPEG);
        _constructAt(
            hookAddress,
            abi.encodePacked(type(SwarmPegHook).creationCode, abi.encode(manager, token, address(pot), address(this)))
        );
        hook = SwarmPegHook(hookAddress);
        router = new PoolHarness(manager);
        key = PoolKey(
            Currency.wrap(tokenFirst ? address(token) : address(imd)),
            Currency.wrap(tokenFirst ? address(imd) : address(token)),
            12_500,
            60,
            IHooks(address(hook))
        );
        token.approve(address(router), type(uint256).max);
        imd.approve(address(router), type(uint256).max);
        manager.initialize(key, price);
        if (seed) _seed(-887220, 887220);
    }

    function _constructAt(address target, bytes memory creationCode) internal {
        vm.etch(target, creationCode);
        (bool ok, bytes memory runtime) = target.call("");
        require(ok, "construction failed");
        vm.etch(target, runtime);
    }

    function _seed(int24 lower, int24 upper) internal {
        router.modify(key, ModifyLiquidityParams(lower, upper, LIQUIDITY, bytes32(0)), 2_000_000 ether, 2_000_000 ether);
    }

    function _params(bool buy, bool exactInput, uint256 amount) internal view returns (SwapParams memory) {
        bool pair0 = Currency.unwrap(key.currency0) == address(imd);
        bool zeroForOne = buy == pair0;
        return SwapParams(
            zeroForOne,
            exactInput ? -int256(amount) : int256(amount),
            zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
        );
    }

    function _trade(bool buy, bool exactInput, uint256 amount) internal returns (BalanceDelta) {
        return router.swap(key, _params(buy, exactInput, amount), amount * 5 + 100 ether, 0);
    }

    function _claims() internal view returns (uint256) {
        return manager.balanceOf(address(pot), uint256(uint160(address(imd))));
    }

    function _ceil(uint256 n, uint256 d) internal pure returns (uint256) {
        return n == 0 ? 0 : (n - 1) / d + 1;
    }
}
