// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Fixture, PoolKey, Currency, IHooks, SwarmPegHook, HookFlags} from "./Fixture.sol";
import {PrepareDeployment} from "../script/PrepareDeployment.s.sol";

contract DeploymentTest is Fixture {
    function setUp() public {
        _setup(true, false);
    }

    function test_realCreate2MiningDeploymentAndFactoryInitialization() public {
        PrepareDeployment plan = new PrepareDeployment();
        PrepareDeployment.Config memory c = PrepareDeployment.Config(manager, token, pot, address(this));
        plan.validateDeployedDependencies(c);
        bytes memory code = plan.creationCode(c);
        (bytes32 salt, address predicted) = plan.mine(c, 0, 200_000);
        address deployed;
        assembly ("memory-safe") { deployed := create2(0, add(code, 32), mload(code), salt) }
        assertEq(deployed, predicted);
        assertTrue(HookFlags.matches(deployed, HookFlags.SWARMPEG));
        SwarmPegHook fresh = SwarmPegHook(deployed);
        assertEq(address(fresh.poolManager()), address(manager));
        assertEq(address(fresh.token()), address(token));
        assertEq(fresh.maintenancePot(), address(pot));
        assertEq(fresh.launchFactory(), address(this));
        key.hooks = IHooks(deployed);
        vm.expectRevert();
        vm.prank(alice);
        manager.initialize(key, ONE);
        assertFalse(fresh.initialized());
        PoolKey memory wrong = key;
        wrong.fee = 3000;
        vm.expectRevert();
        manager.initialize(wrong, ONE);
        wrong = key;
        wrong.tickSpacing = 10;
        vm.expectRevert();
        manager.initialize(wrong, ONE);
        wrong = key;
        wrong.currency0 = Currency.wrap(alice);
        vm.expectRevert();
        manager.initialize(wrong, ONE);
        assertFalse(fresh.initialized());
        manager.initialize(key, ONE);
        assertTrue(fresh.initialized());
        vm.expectRevert();
        manager.initialize(key, ONE);
    }

    function test_badFlagsAndZeroConstructorParametersRefused() public {
        address invalid = address(0x30000000); // explicitly lacks the required low bits
        vm.etch(
            invalid,
            abi.encodePacked(type(SwarmPegHook).creationCode, abi.encode(manager, token, address(pot), address(this)))
        );
        (bool badFlags,) = invalid.call("");
        assertFalse(badFlags);
        address valid = address(uint160(0x20000000) | HookFlags.SWARMPEG);
        vm.etch(
            valid,
            abi.encodePacked(type(SwarmPegHook).creationCode, abi.encode(manager, token, address(0), address(this)))
        );
        (bool ok,) = valid.call("");
        assertFalse(ok);
    }

    function test_runtimeHasNoDelegatecallSelfdestructOrCallcode() public view {
        _scan(address(token).code);
        _scan(address(hook).code);
        _scan(address(pot).code);
    }

    function _scan(bytes memory code) internal pure {
        assertGt(code.length, 0);
        assertLe(code.length, 24576);
        for (uint256 i; i < code.length; ++i) {
            uint8 op = uint8(code[i]);
            if (op >= 0x60 && op <= 0x7f) {
                i += op - 0x5f;
                continue;
            }
            assertTrue(op != 0xff && op != 0xf4 && op != 0xf2);
        }
    }
}
