// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {
    Fixture,
    PoolKey,
    Currency,
    IHooks,
    IPoolManager,
    SwarmPeg,
    SwarmPegHook,
    SwarmMaintenance,
    HookFlags,
    LaunchConstants
} from "./Fixture.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {PrepareDeployment} from "../script/PrepareDeployment.s.sol";

contract DeploymentTest is Fixture {
    PrepareDeployment internal plan;

    function setUp() public {
        _setup(true, false);
        plan = new PrepareDeployment();
    }

    function test_realCreate2MiningDeploymentAndFactoryInitialization() public {
        PrepareDeployment.Config memory c = _config();
        (SwarmPegHook fresh,) = _deploy(c, 0);
        assertEq(address(fresh.poolManager()), address(manager));
        assertEq(address(fresh.token()), address(token));
        assertEq(fresh.launchFactory(), address(this));
        _assertTreasury(fresh, c);
        assertNotEq(fresh.maintenancePot(), address(pot));
        plan.validateDeployedDependencies(c, fresh);
        key.hooks = IHooks(address(fresh));
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

    function test_freshHooksDeploySeparateTreasuriesAndRouteFeesOnlyToTheirOwn() public {
        PrepareDeployment.Config memory c = _config();
        (SwarmPegHook first, bytes32 salt) = _deploy(c, 0);
        (SwarmPegHook second,) = _deploy(c, uint256(salt) + 1);
        _assertTreasury(first, c);
        _assertTreasury(second, c);
        assertNotEq(first.maintenancePot(), second.maintenancePot());
        address originalPot = address(pot);

        hook = first;
        pot = SwarmMaintenance(first.maintenancePot());
        key.hooks = IHooks(address(first));
        manager.initialize(key, ONE);
        _seed(-887220, 887220);
        _trade(true, true, 100 ether);
        assertEq(first.totalFees(), 2 ether);
        assertEq(_claims(), 2 ether);
        uint256 currencyId = uint256(uint160(address(imd)));
        assertEq(manager.balanceOf(second.maintenancePot(), currencyId), 0);
        assertEq(manager.balanceOf(originalPot, currencyId), 0);
        SwarmMaintenance otherPot = SwarmMaintenance(second.maintenancePot());
        vm.expectRevert();
        otherPot.redeemFees(1);
        assertEq(_claims(), 2 ether);

        vm.prank(worker);
        pot.redeemFees(2 ether);
        assertEq(_claims(), 0);
        assertEq(imd.balanceOf(first.maintenancePot()), 2 ether);
        assertEq(imd.balanceOf(second.maintenancePot()), 0);
        assertEq(imd.balanceOf(worker), 0);
    }

    function test_constructorDeploysTreasuryWithoutCallingExternalDependencies() public {
        PrepareDeployment.Config memory c = _config();
        c.manager = IPoolManager(makeAddr("not-yet-deployed-manager"));
        c.token = SwarmPeg(makeAddr("not-yet-deployed-token"));
        assertEq(address(c.manager).code.length, 0);
        assertEq(address(c.token).code.length, 0);
        (SwarmPegHook fresh,) = _deploy(c, 0);
        _assertTreasury(fresh, c);
        assertFalse(fresh.initialized());
    }

    function test_treasuryCreationFailureRevertsHookDeploymentAtomically() public {
        PrepareDeployment.Config memory c = _config();
        bytes memory code = plan.creationCode(c);
        (bytes32 salt, address predicted) = plan.mine(c, 0, 200_000);
        address expectedPot = vm.computeCreateAddress(predicted, 1);
        // Simulate a CREATE collision; a hook without its treasury must never survive.
        vm.etch(expectedPot, hex"00");
        assertEq(_create2(code, salt), address(0));
        assertEq(predicted.code.length, 0);
        assertEq(vm.getNonce(predicted), 0);
        assertEq(expectedPot.code, hex"00");
        vm.etch(expectedPot, "");
        assertEq(_create2(code, salt), predicted);
        _assertTreasury(SwarmPegHook(predicted), c);
    }

    function test_badFlagsRefusedBeforeTreasuryCreation() public {
        address invalid = address(0x30000000); // explicitly lacks the required low bits
        address expectedPot = vm.computeCreateAddress(invalid, vm.getNonce(invalid));
        vm.etch(invalid, abi.encodePacked(type(SwarmPegHook).creationCode, abi.encode(manager, token, address(this))));
        (bool badFlags, bytes memory reason) = invalid.call("");
        assertFalse(badFlags);
        assertEq(reason, abi.encodeWithSelector(Hooks.HookAddressNotValid.selector, invalid));
        assertEq(expectedPot.code.length, 0);
    }

    function test_zeroConstructorParametersAndPairedTokenRefused() public {
        vm.expectRevert(SwarmPegHook.InvalidAddress.selector);
        new SwarmPegHook(IPoolManager(address(0)), token, address(this));
        vm.expectRevert(SwarmPegHook.InvalidAddress.selector);
        new SwarmPegHook(manager, SwarmPeg(address(0)), address(this));
        vm.expectRevert(SwarmPegHook.InvalidAddress.selector);
        new SwarmPegHook(manager, token, address(0));
        vm.expectRevert(SwarmPegHook.InvalidAddress.selector);
        new SwarmPegHook(manager, SwarmPeg(LaunchConstants.IMD), address(this));
    }

    function test_preparationRejectsInvalidConfiguration() public {
        PrepareDeployment.Config memory c = _config();
        c.manager = IPoolManager(address(0));
        vm.expectRevert(PrepareDeployment.InvalidConfiguration.selector);
        plan.creationCode(c);
        c = _config();
        c.token = SwarmPeg(address(0));
        vm.expectRevert(PrepareDeployment.InvalidConfiguration.selector);
        plan.creationCode(c);
        c = _config();
        c.factory = address(0);
        vm.expectRevert(PrepareDeployment.InvalidConfiguration.selector);
        plan.creationCode(c);
        c = _config();
        c.token = SwarmPeg(LaunchConstants.IMD);
        vm.expectRevert(PrepareDeployment.InvalidConfiguration.selector);
        plan.creationCode(c);
    }

    function test_preparationRejectsMismatchedDeployedDependencies() public {
        PrepareDeployment.Config memory c = _config();
        plan.validateDeployedDependencies(c, hook);
        c.manager = IPoolManager(alice);
        vm.expectRevert(PrepareDeployment.InvalidConfiguration.selector);
        plan.validateDeployedDependencies(c, hook);
        c = _config();
        c.token = SwarmPeg(alice);
        vm.expectRevert(PrepareDeployment.InvalidConfiguration.selector);
        plan.validateDeployedDependencies(c, hook);
        c = _config();
        c.factory = alice;
        vm.expectRevert(PrepareDeployment.InvalidConfiguration.selector);
        plan.validateDeployedDependencies(c, hook);
        c = _config();
        vm.mockCall(address(pot), abi.encodeWithSelector(pot.votingToken.selector), abi.encode(alice));
        vm.expectRevert(PrepareDeployment.InvalidConfiguration.selector);
        plan.validateDeployedDependencies(c, hook);
    }

    function test_saltSearchExhaustionIsExplicit() public {
        PrepareDeployment.Config memory c = _config();
        vm.expectRevert(PrepareDeployment.SaltNotFound.selector);
        plan.mine(c, 0, 0);
    }

    function test_runtimeHasNoDelegatecallSelfdestructOrCallcode() public view {
        _scan(address(token).code);
        _scan(address(hook).code);
        _scan(address(pot).code);
    }

    function _config() internal view returns (PrepareDeployment.Config memory) {
        return PrepareDeployment.Config(manager, token, address(this));
    }

    function _deploy(PrepareDeployment.Config memory c, uint256 start)
        internal
        returns (SwarmPegHook fresh, bytes32 salt)
    {
        bytes memory code = plan.creationCode(c);
        assertLe(code.length, 49152);
        address predicted;
        (salt, predicted) = plan.mine(c, start, 200_000);
        address deployed = _create2(code, salt);
        assertNotEq(deployed, address(0));
        assertEq(deployed, predicted);
        assertTrue(HookFlags.matches(deployed, HookFlags.SWARMPEG));
        fresh = SwarmPegHook(deployed);
    }

    function _create2(bytes memory code, bytes32 salt) internal returns (address deployed) {
        assembly ("memory-safe") { deployed := create2(0, add(code, 32), mload(code), salt) }
    }

    function _assertTreasury(SwarmPegHook fresh, PrepareDeployment.Config memory c) internal view {
        address treasury = fresh.maintenancePot();
        assertEq(treasury, vm.computeCreateAddress(address(fresh), 1));
        assertGt(treasury.code.length, 0);
        assertLe(treasury.code.length, 24576);
        assertEq(address(SwarmMaintenance(treasury).poolManager()), address(c.manager));
        assertEq(address(SwarmMaintenance(treasury).votingToken()), address(c.token));
        assertEq(SwarmMaintenance(treasury).totalPaid(), 0);
        assertEq(SwarmMaintenance(treasury).jobCount(), 0);
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
