// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";

/// @notice Immutable, entirely on-chain SVG. All helpers are internal (no linked library).
library GlyphRenderer {
    using Strings for uint256;

    function traits(uint256 pulse) internal pure returns (uint256 nodes, uint256 durationMs, uint256 lightness) {
        if (pulse > 1000) pulse = 1000;
        return (4 + pulse / 125, 3200 - pulse * 2, 48 + pulse * 30 / 1000);
    }

    function render(bytes32 seed, bytes32 id, uint256 pulse) internal pure returns (string memory) {
        (uint256 nodes, uint256 duration, uint256 lightness) = traits(pulse);
        string memory hue = (uint256(seed) % 360).toString();
        string memory color = string.concat("hsl(", hue, ",88%,", lightness.toString(), "%)");
        string memory accent = string.concat("hsl(", ((uint256(seed) % 360 + 65) % 360).toString(), ",90%,80%)");
        string memory body = string.concat(
            '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 320 360" role="img" aria-label="SwarmPeg animated agent network">',
            "<style>:root{--c:",
            color,
            ";--a:",
            accent,
            ";--t:",
            duration.toString(),
            "ms}.wire{stroke:var(--c);stroke-width:1;fill:none;stroke-dasharray:5 9;animation:draw var(--t) linear infinite}",
            ".node{animation:breathe var(--t) ease-in-out infinite alternate}.core{transform-origin:160px 160px;animation:pulse var(--t) ease-in-out infinite}",
            ".status{animation:blink var(--t) steps(2,end) infinite}.agent{shape-rendering:crispEdges}",
            "@keyframes draw{0%{stroke-dashoffset:28;opacity:.15}100%{stroke-dashoffset:0;opacity:.85}}",
            "@keyframes pulse{0%,100%{transform:scale(1);opacity:.8}50%{transform:scale(1.07);opacity:1}}",
            "@keyframes breathe{from{opacity:.55}to{opacity:1}}@keyframes blink{0%,70%{opacity:1}71%,100%{opacity:.15}}",
            "@media(prefers-reduced-motion:reduce){.wire,.node,.core,.status{animation:none}}</style>",
            '<rect width="320" height="360" rx="18" fill="#080d18"/>',
            '<path d="M16 32H304M16 320H304" stroke="#263146"/>',
            '<text x="18" y="23" fill="#cbd5e1" font-family="monospace" font-size="10">SWARMPEG / ON-CHAIN AGENTS</text>'
        );
        uint256 priorX = 160;
        uint256 priorY = 160;
        string memory faces;
        for (uint256 i; i < nodes; ++i) {
            bytes32 nodeSeed = keccak256(abi.encode(seed, i));
            uint256 x = 40 + uint256(nodeSeed) % 240;
            uint256 y = 55 + (uint256(nodeSeed) >> 32) % 245;
            // Keep satellites away from the central agent.
            if (x > 120 && x < 200 && y > 120 && y < 200) x = x < 160 ? 72 : 248;
            body = string.concat(body, '<path class="wire" d="M160 160L', x.toString(), " ", y.toString(), '"/>');
            if (i != 0) {
                body = string.concat(
                    body,
                    '<path class="wire" d="M',
                    priorX.toString(),
                    " ",
                    priorY.toString(),
                    "L",
                    x.toString(),
                    " ",
                    y.toString(),
                    '"/>'
                );
            }
            faces = string.concat(
                faces,
                '<g class="node"><rect x="',
                (x - 13).toString(),
                '" y="',
                (y - 13).toString(),
                '" width="26" height="26" rx="4" fill="#131e32" stroke="var(--c)"/>',
                _agent(nodeSeed, x - 8, y - 9, 2),
                "</g>"
            );
            priorX = x;
            priorY = y;
        }
        return string.concat(
            body,
            faces,
            '<g class="core"><rect x="137" y="135" width="46" height="50" rx="8" fill="#17243b" stroke="var(--a)"/>',
            _agent(seed, 144, 140, 4),
            "</g>",
            '<text x="18" y="340" fill="var(--c)" font-family="monospace" font-size="10">PULSE ',
            pulse.toString(),
            " / ",
            uint256(uint32(bytes4(id))).toHexString(4),
            "</text></svg>"
        );
    }

    function _agent(bytes32 seed, uint256 x, uint256 y, uint256 scale) private pure returns (string memory) {
        uint256 style = uint256(seed) % 3;
        string memory hair = style == 0
            ? "M1 1h6v2H1zM0 2h1v3H0z"
            : style == 1 ? "M2 0h4v1H2zM1 1h6v2H1zM6 3h1v3H6z" : "M1 1h6v1H1zM3 0h2v1H3zM0 2h2v2H0z";
        string memory mouth = (uint256(seed) >> 8) % 2 == 0 ? "M3 6h2v1H3z" : "M2 6h1v1H2zM3 7h3v1H3z";
        return string.concat(
            '<g class="agent" transform="translate(',
            x.toString(),
            " ",
            y.toString(),
            ") scale(",
            scale.toString(),
            ')"><path d="M1 2h6v5H6v1H2V7H1z" fill="var(--c)"/>',
            '<path d="',
            hair,
            '" fill="var(--a)"/><path d="M2 4h1v1H2zM5 4h1v1H5z',
            mouth,
            '" fill="#0a1020"/><path d="M1 8h6v2H1z" fill="var(--a)"/>',
            '<rect class="status" x="7" y="0" width="1" height="1" fill="#ffffff"/></g>'
        );
    }
}
