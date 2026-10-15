// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {SwarmPeg} from "../src/SwarmPeg.sol";
import {SwarmPegHook} from "../src/SwarmPegHook.sol";
import {SwarmMaintenance} from "../src/SwarmMaintenance.sol";
import {HookFlags} from "../src/HookFlags.sol";

/// @notice Read-only launch preparation. No wallet, environment, filesystem, or broadcast.
/// Call with actual deployment parameters; the authorized network factory does the launch.
contract PrepareDeployment {
    error InvalidConfiguration();
    error SaltNotFound();

    struct Config {
        IPoolManager manager;
        SwarmPeg token;
        SwarmMaintenance pot;
        address factory;
    }

    function creationCode(Config memory c) public pure returns (bytes memory) {
        if (
            address(c.manager) == address(0) || address(c.token) == address(0) || address(c.pot) == address(0)
                || c.factory == address(0)
        ) revert InvalidConfiguration();
        return
            abi.encodePacked(type(SwarmPegHook).creationCode, abi.encode(c.manager, c.token, address(c.pot), c.factory));
    }

    function validateDeployedDependencies(Config memory c) external view {
        if (
            address(c.pot.poolManager()) != address(c.manager) || address(c.pot.votingToken()) != address(c.token)
                || c.token.totalSupply() != 1_000_000_000 ether || c.token.decimals() != 18
        ) revert InvalidConfiguration();
    }

    /// @param start First salt to try; use the next range if SaltNotFound is returned.
    /// @param attempts Bound the amount of computation; typically 200,000 suffices.
    function mine(Config memory c, uint256 start, uint256 attempts)
        external
        pure
        returns (bytes32 salt, address predicted)
    {
        bytes32 hash = keccak256(creationCode(c));
        for (uint256 i; i < attempts; ++i) {
            salt = bytes32(start + i);
            predicted = address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), c.factory, salt, hash)))));
            if (HookFlags.matches(predicted, HookFlags.SWARMPEG)) return (salt, predicted);
        }
        revert SaltNotFound();
    }
}
