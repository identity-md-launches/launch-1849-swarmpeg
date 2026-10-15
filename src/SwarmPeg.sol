// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {LaunchConstants} from "./LaunchConstants.sol";

/// @notice Fixed-supply ERC-20 with one implicit glyph for each whole token held.
/// @dev Glyphs are balance slots, not separately transferable ERC-721s. Losing a whole
/// token retires the highest slot; gaining one creates a new identity. Compact batches
/// make even the billion-token constructor mint and the 88% allocation constant-size.
contract SwarmPeg is ERC20 {
    struct Batch {
        uint64 end; // exclusive slot endpoint; at most 1 billion
        uint64 serial;
        uint64 bornBlock;
        address previousHolder;
        bytes32 entropy;
    }

    struct Glyph {
        bytes32 id;
        bytes32 transferSeed;
        address previousHolder;
        uint64 bornBlock;
    }

    mapping(address holder => mapping(uint256 batch => Batch)) private _batches;
    mapping(address holder => uint256 count) public batchCount;
    uint64 public batchSerial;

    error NoGlyph();

    event GlyphsCreated(
        address indexed holder,
        uint256 firstSlot,
        uint256 endSlot,
        uint64 indexed serial,
        address indexed previousHolder,
        bytes32 entropy,
        uint64 bornBlock
    );
    event GlyphsRetired(address indexed holder, uint256 firstSlot, uint256 endSlot);

    constructor() ERC20("SwarmPeg", "SWARMPEG") {
        _mint(msg.sender, LaunchConstants.SUPPLY);
    }

    function glyphCount(address holder) public view returns (uint256) {
        return balanceOf(holder) / 1 ether;
    }

    function glyphAt(address holder, uint256 slot) public view returns (Glyph memory glyph) {
        if (slot >= glyphCount(holder)) revert NoGlyph();
        Batch storage b = _batches[holder][_batchAt(holder, slot)];
        glyph.id = keccak256(abi.encode(block.chainid, address(this), holder, slot, b.serial));
        glyph.transferSeed = keccak256(abi.encode(b.entropy, glyph.id));
        glyph.previousHolder = b.previousHolder;
        glyph.bornBlock = b.bornBlock;
    }

    function _update(address from, address to, uint256 value) internal override {
        uint256 beforeFrom = glyphCount(from);
        uint256 beforeTo = glyphCount(to);
        super._update(from, to, value);
        // Self transfers and zero transfers cannot reroll a glyph.
        if (from == to || value == 0) return;
        uint256 afterFrom = glyphCount(from);
        uint256 afterTo = glyphCount(to);
        if (afterFrom < beforeFrom) {
            if (afterFrom == 0) {
                batchCount[from] = 0;
            } else {
                uint256 last = _batchAt(from, afterFrom - 1);
                _batches[from][last].end = uint64(afterFrom);
                batchCount[from] = last + 1;
            }
            emit GlyphsRetired(from, afterFrom, beforeFrom);
        }
        if (afterTo > beforeTo) {
            uint64 serial = ++batchSerial;
            bytes32 entropy = keccak256(
                abi.encode(
                    from,
                    to,
                    value,
                    msg.sender,
                    serial,
                    block.number,
                    block.prevrandao,
                    block.number == 0 ? bytes32(0) : blockhash(block.number - 1)
                )
            );
            _batches[to][batchCount[to]++] = Batch(uint64(afterTo), serial, uint64(block.number), from, entropy);
            emit GlyphsCreated(to, beforeTo, afterTo, serial, from, entropy, uint64(block.number));
        }
    }

    /// @dev Binary search of live batch endpoints. Retired batches need no linear cleanup;
    /// they become unreachable and are overwritten on subsequent acquisitions.
    function _batchAt(address holder, uint256 slot) private view returns (uint256 low) {
        uint256 high = batchCount[holder];
        while (low < high) {
            uint256 mid = (low + high) / 2;
            if (_batches[holder][mid].end <= slot) low = mid + 1;
            else high = mid;
        }
    }
}
