// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

library LaunchConstants {
    address internal constant IMD = 0xD34a99Bc0f67aE1bbd63C660e6d0b0dd03E263B7;
    uint256 internal constant SUPPLY = 1_000_000_000 ether;
    uint24 internal constant LP_FEE = 12_500;
    int24 internal constant TICK_SPACING = 60;
}
