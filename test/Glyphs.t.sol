// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Fixture} from "./Fixture.sol";
import {GlyphRenderer} from "../src/GlyphRenderer.sol";
import {SwarmPeg} from "../src/SwarmPeg.sol";

contract GlyphsTest is Fixture {
    function setUp() public {
        _setup(true, true);
    }

    function test_higherPulseHasMoreNodesBrighterColorsFasterAnimation() public pure {
        (uint256 n0, uint256 t0, uint256 l0) = GlyphRenderer.traits(0);
        (uint256 n1, uint256 t1, uint256 l1) = GlyphRenderer.traits(1000);
        assertGt(n1, n0);
        assertLt(t1, t0);
        assertGt(l1, l0);
        string memory quiet = GlyphRenderer.render(keccak256("agent"), keccak256("id"), 0);
        string memory active = GlyphRenderer.render(keccak256("agent"), keccak256("id"), 1000);
        assertGt(bytes(active).length, bytes(quiet).length);
        assertEq(_count(quiet, 'class="wire"'), 7);
        assertEq(_count(active, 'class="wire"'), 23);
        assertEq(_count(active, "@keyframes"), 4);
        assertEq(_count(active, "https:"), 0);
        assertEq(_count(active, "ipfs:"), 0);
        assertEq(_count(active, "<script"), 0);
    }

    function test_seedCombinesTransferTradeBlockPreviousHolderAndPulse() public {
        vm.roll(100);
        _trade(true, true, 100 ether);
        token.transfer(alice, 2 ether);
        SwarmPeg.Glyph memory g = token.glyphAt(alice, 0);
        (bytes32 id, bytes32 seed) = hook.glyphSeed(alice, 0);
        assertEq(id, g.id);
        assertEq(g.previousHolder, address(this));
        assertEq(g.bornBlock, 100);
        assertTrue(hook.tradeEntropy(100) != bytes32(0));
        assertEq(
            seed,
            keccak256(
                abi.encode(g.transferSeed, hook.tradeEntropy(100), g.bornBlock, g.previousHolder, hook.pulseAt(100))
            )
        );
        (, bytes32 other) = hook.glyphSeed(alice, 1);
        assertTrue(other != seed);
        vm.roll(101);
        _trade(false, true, 100 ether);
        (, bytes32 same) = hook.glyphSeed(alice, 0);
        assertEq(same, seed, "completed acquisition blocks are immutable");
    }

    function test_livePulseDecayHistoryAndPermissionlessUpdate() public {
        vm.roll(100);
        _trade(true, true, 100 ether);
        assertEq(hook.currentPulse(), 98);
        assertEq(hook.pulseAt(99), 0);
        assertEq(hook.pulseAt(100), 98);
        vm.roll(110);
        assertEq(hook.currentPulse(), 88);
        vm.prank(alice);
        assertEq(hook.updatePulse(), 88);
        assertEq(hook.pulseAt(105), 93);
        assertEq(hook.pulseAt(100), 98);
        vm.roll(1110);
        assertEq(hook.currentPulse(), 0);
        hook.updatePulse();
        assertEq(hook.currentPulse(), 0);
        _trade(true, true, 2000 ether);
        assertEq(hook.currentPulse(), 1000);
        assertEq(hook.pulseAt(100), 98);
    }

    function test_svgAndMetadataAreOnChainAndMissingGlyphReverts() public {
        token.transfer(alice, 1 ether);
        string memory svg = hook.glyphSVG(alice, 0);
        assertEq(_count(svg, "<svg"), 1);
        assertEq(_count(svg, "</svg>"), 1);
        assertGt(_count(svg, "class=\"agent\""), 0);
        assertEq(_count(hook.glyphURI(alice, 0), "data:application/json;base64,"), 1);
        vm.expectRevert(SwarmPeg.NoGlyph.selector);
        hook.glyphSVG(alice, 1);
        vm.prank(alice);
        token.transfer(bob, 1 ether);
        vm.expectRevert(SwarmPeg.NoGlyph.selector);
        hook.glyphURI(alice, 0);
        assertGt(bytes(hook.glyphSVG(bob, 0)).length, 1000);
    }

    function test_noOwnerPauseOrRendererReplacement() public {
        string[6] memory selectors = [
            "owner()", "pause()", "upgradeTo(address)", "setRenderer(address)", "setPulse(uint256)", "setFee(uint256)"
        ];
        for (uint256 i; i < selectors.length; ++i) {
            (bool ok,) = address(hook).call(abi.encodeWithSignature(selectors[i], alice));
            assertFalse(ok);
        }
    }

    function _count(string memory text, string memory needle) private pure returns (uint256 count) {
        bytes memory a = bytes(text);
        bytes memory b = bytes(needle);
        if (a.length < b.length) return 0;
        for (uint256 i; i <= a.length - b.length; ++i) {
            bool same = true;
            for (uint256 j; j < b.length; ++j) {
                if (a[i + j] != b[j]) {
                    same = false;
                    break;
                }
            }
            if (same) ++count;
        }
    }
}
