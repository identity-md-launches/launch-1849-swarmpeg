// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {HookTests} from "../test/Hook.t.sol";
import {
    PoolManager,
    SwarmPeg,
    SwarmPegHook,
    SwarmMaintenance,
    MockERC20,
    PoolHarness,
    PoolKey,
    Currency,
    IHooks,
    HookFlags,
    LaunchConstants
} from "../test/Fixture.sol";

/// @notice Optional fork profile. Default tests have no network dependencies.
/// The fork must be supplied on the command line, never from a test environment read.
/// A new real v4 manager isolates the rehearsal; the paired IMD is the deployed mainnet token.
contract MainnetPairRehearsalTest is HookTests {
    function setUp() public {
        require(block.chainid == 1 && LaunchConstants.IMD.code.length != 0, "supply an Ethereum mainnet fork");
        manager = new PoolManager(address(this));
        token = new SwarmPeg();
        imd = MockERC20(LaunchConstants.IMD);
        assertEq(imd.symbol(), "IMD");
        assertEq(imd.decimals(), 18);
        deal(address(imd), address(this), 100_000_000 ether);
        pot = new SwarmMaintenance(manager, token);
        address hookAddress = address(uint160(0x10000000) | HookFlags.SWARMPEG);
        _constructAt(
            hookAddress,
            abi.encodePacked(type(SwarmPegHook).creationCode, abi.encode(manager, token, address(pot), address(this)))
        );
        hook = SwarmPegHook(hookAddress);
        router = new PoolHarness(manager);
        bool tokenFirst = address(token) < address(imd);
        key = PoolKey(
            Currency.wrap(tokenFirst ? address(token) : address(imd)),
            Currency.wrap(tokenFirst ? address(imd) : address(token)),
            12_500,
            60,
            IHooks(address(hook))
        );
        token.approve(address(router), type(uint256).max);
        imd.approve(address(router), type(uint256).max);
        manager.initialize(key, ONE);
        _seed(-887220, 887220);
    }
}
