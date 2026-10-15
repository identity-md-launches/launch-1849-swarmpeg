// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {SwarmPeg} from "../src/SwarmPeg.sol";

contract SwarmPegTest is Test {
    SwarmPeg token;
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    function setUp() public {
        token = new SwarmPeg();
    }

    function test_fixedSupplyAndLaunchAllocation() public {
        assertEq(token.name(), "SwarmPeg");
        assertEq(token.symbol(), "SWARMPEG");
        assertEq(token.decimals(), 18);
        assertEq(token.totalSupply(), 1_000_000_000 ether);
        assertEq(token.balanceOf(address(this)), token.totalSupply());
        assertEq(token.glyphCount(address(this)), 1_000_000_000);
        assertEq(token.batchCount(address(this)), 1);
        token.transfer(alice, 880_000_000 ether);
        token.transfer(bob, 100_000_000 ether);
        assertEq(token.balanceOf(address(this)), 20_000_000 ether);
        assertEq(token.batchCount(alice), 1);
        assertEq(token.glyphCount(alice), 880_000_000);
        assertTrue(token.glyphAt(alice, 879_999_999).id != bytes32(0));
        assertEq(token.totalSupply(), 1_000_000_000 ether);
    }

    function test_fractionalBoundariesRetireAndRecreate() public {
        token.transfer(alice, 2.4 ether);
        SwarmPeg.Glyph memory first = token.glyphAt(alice, 0);
        SwarmPeg.Glyph memory last = token.glyphAt(alice, 1);
        vm.prank(alice);
        token.transfer(bob, 0.5 ether);
        assertEq(token.glyphCount(alice), 1);
        assertEq(token.glyphCount(bob), 0);
        assertEq(token.glyphAt(alice, 0).id, first.id);
        vm.expectRevert(SwarmPeg.NoGlyph.selector);
        token.glyphAt(alice, 1);
        token.transfer(alice, 0.1 ether);
        assertEq(token.glyphCount(alice), 2);
        assertTrue(token.glyphAt(alice, 1).id != last.id);
        assertEq(token.glyphAt(alice, 1).previousHolder, address(this));
        token.transfer(bob, 0.5 ether);
        assertEq(token.glyphCount(bob), 1);
        assertTrue(token.glyphAt(alice, 1).id != token.glyphAt(bob, 0).id);
    }

    function test_batchesRetainPrefixAndDiscardManyInLogTime() public {
        for (uint256 i; i < 48; ++i) {
            token.transfer(alice, 1 ether);
        }
        bytes32 prefix = token.glyphAt(alice, 0).id;
        bytes32 retired = token.glyphAt(alice, 47).id;
        vm.prank(alice);
        token.transfer(bob, 47 ether);
        assertEq(token.batchCount(alice), 1);
        assertEq(token.glyphAt(alice, 0).id, prefix);
        token.transfer(alice, 47 ether);
        assertEq(token.batchCount(alice), 2);
        assertTrue(token.glyphAt(alice, 47).id != retired);
        assertEq(token.glyphAt(alice, 0).id, prefix);
        vm.prank(alice);
        token.transfer(bob, 48 ether);
        assertEq(token.batchCount(alice), 0);
        token.transfer(alice, 1 ether);
        assertEq(token.batchCount(alice), 1);
        assertTrue(token.glyphAt(alice, 0).id != prefix);
    }

    function test_zeroAndSelfTransfersDoNotReroll() public {
        token.transfer(alice, 3 ether);
        bytes32 id = token.glyphAt(alice, 1).id;
        bytes32 seed = token.glyphAt(alice, 1).transferSeed;
        vm.prank(alice);
        token.transfer(alice, 1 ether);
        token.transfer(alice, 0);
        assertEq(token.glyphAt(alice, 1).id, id);
        assertEq(token.glyphAt(alice, 1).transferSeed, seed);
    }

    function test_allowanceAndFailureAtomicity() public {
        token.transfer(alice, 3 ether);
        vm.prank(alice);
        token.approve(bob, 1 ether);
        vm.prank(bob);
        token.transferFrom(alice, bob, 1 ether);
        assertEq(token.allowance(alice, bob), 0);
        assertEq(token.balanceOf(bob), 1 ether);
        bytes32 id = token.glyphAt(alice, 0).id;
        vm.expectRevert();
        vm.prank(bob);
        token.transferFrom(alice, bob, 1 ether);
        vm.expectRevert();
        vm.prank(alice);
        token.transfer(bob, 4 ether);
        vm.expectRevert();
        token.transfer(address(0), 1);
        assertEq(token.glyphAt(alice, 0).id, id);
        assertEq(token.totalSupply(), 1_000_000_000 ether);
    }

    function test_noAdminOrMintSelectors() public {
        string[7] memory signatures = [
            "mint(address,uint256)",
            "pause()",
            "owner()",
            "upgradeTo(address)",
            "transferOwnership(address)",
            "setHook(address)",
            "setMinter(address)"
        ];
        for (uint256 i; i < signatures.length; ++i) {
            (bool ok,) = address(token).call(abi.encodeWithSignature(signatures[i], alice, 1 ether));
            assertFalse(ok);
        }
        assertEq(token.balanceOf(alice), 0);
    }

    function testFuzz_transferConservesSupplyAndWholeGlyphs(uint256 initial, uint256 amount) public {
        initial = bound(initial, 0, token.totalSupply());
        amount = bound(amount, 0, initial);
        token.transfer(alice, initial);
        vm.prank(alice);
        token.transfer(bob, amount);
        assertEq(token.glyphCount(alice), (initial - amount) / 1 ether);
        assertEq(token.glyphCount(bob), amount / 1 ether);
        assertEq(token.balanceOf(address(this)) + token.balanceOf(alice) + token.balanceOf(bob), token.totalSupply());
        if (token.glyphCount(alice) != 0) {
            assertTrue(token.glyphAt(alice, token.glyphCount(alice) - 1).id != bytes32(0));
        }
        if (token.glyphCount(bob) != 0) assertTrue(token.glyphAt(bob, token.glyphCount(bob) - 1).id != bytes32(0));
    }
}
