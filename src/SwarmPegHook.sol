// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, toBeforeSwapDelta} from "v4-core/src/types/BeforeSwapDelta.sol";
import {Base64} from "@openzeppelin/contracts/utils/Base64.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {SwarmPeg} from "./SwarmPeg.sol";
import {GlyphRenderer} from "./GlyphRenderer.sol";
import {LaunchConstants} from "./LaunchConstants.sol";

/// @notice Ownerless, immutable IMD fee hook and canonical SwarmPeg renderer.
/// @dev Only enabled callbacks exist; all other callback selectors revert. There is
/// no hook-owned liquidity, custom curve, privileged router, or LP fee override.
contract SwarmPegHook {
    using Strings for uint256;
    using Strings for address;

    IPoolManager public immutable poolManager;
    SwarmPeg public immutable token;
    address public immutable maintenancePot;
    address public immutable launchFactory;
    address public constant PAIRED_ASSET = LaunchConstants.IMD;
    uint256 public constant FEE_BPS = 200;
    uint256 public constant MAX_PULSE = 1000;
    uint256 public constant PULSE_DECAY_PER_BLOCK = 1;
    uint256 public constant IMD_PER_PULSE = 1 ether;

    PoolId public poolId;
    bool public initialized;
    uint256 public totalFees;
    uint256 public tradeCount;
    mapping(uint256 blockNumber => bytes32 entropy) public tradeEntropy;

    struct PulsePoint {
        uint64 blockNumber;
        uint16 value;
    }
    PulsePoint[] public pulseHistory;

    error InvalidAddress();
    error OnlyPoolManager();
    error InvalidPool();
    error OnlyLaunchFactory();
    error AlreadyInitialized();
    error InvalidSwapAmount();
    error PartialFillOfPairedAmount();

    event PoolBound(bytes32 indexed poolId, address indexed token);
    event FeeAccrued(bytes32 indexed poolId, bool buy, uint256 pairedPoolAmount, uint256 fee, address indexed pot);
    event TradeRecorded(uint256 indexed number, uint256 indexed blockNumber, address indexed router, bytes32 entropy);
    event PulseUpdated(uint256 indexed blockNumber, uint256 previousPulse, uint256 pulse);

    constructor(IPoolManager manager_, SwarmPeg token_, address maintenancePot_, address factory_) {
        if (
            address(manager_) == address(0) || address(token_) == address(0) || maintenancePot_ == address(0)
                || factory_ == address(0) || address(token_) == PAIRED_ASSET
        ) revert InvalidAddress();
        poolManager = manager_;
        token = token_;
        maintenancePot = maintenancePot_;
        launchFactory = factory_;
        Hooks.validateHookPermissions(IHooks(address(this)), getHookPermissions());
    }

    modifier onlyPoolManager() {
        if (msg.sender != address(poolManager)) revert OnlyPoolManager();
        _;
    }

    function getHookPermissions() public pure returns (Hooks.Permissions memory p) {
        p.beforeInitialize = true;
        p.beforeSwap = true;
        p.afterSwap = true;
        p.beforeSwapReturnDelta = true;
        p.afterSwapReturnDelta = true;
    }

    function beforeInitialize(address sender, PoolKey calldata key, uint160) external onlyPoolManager returns (bytes4) {
        if (sender != launchFactory) revert OnlyLaunchFactory();
        if (initialized) revert AlreadyInitialized();
        address c0 = Currency.unwrap(key.currency0);
        address c1 = Currency.unwrap(key.currency1);
        if (
            address(key.hooks) != address(this) || key.fee != LaunchConstants.LP_FEE
                || key.tickSpacing != LaunchConstants.TICK_SPACING
                || !((c0 == address(token) && c1 == PAIRED_ASSET) || (c0 == PAIRED_ASSET && c1 == address(token)))
        ) {
            revert InvalidPool();
        }
        initialized = true;
        poolId = key.toId();
        emit PoolBound(PoolId.unwrap(poolId), address(token));
        return IHooks.beforeInitialize.selector;
    }

    function beforeSwap(address, PoolKey calldata key, SwapParams calldata params, bytes calldata)
        external
        view
        onlyPoolManager
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        _checkPool(key);
        uint256 amount = _specifiedAmount(params.amountSpecified);
        bool pairSpecified = _pairIsSpecified(key, params);
        uint256 fee;
        if (pairSpecified) {
            // Buy exact input: take 2% of the gross budget. Sell exact output:
            // gross up the requested net IMD output to preserve exactness.
            fee = params.amountSpecified < 0 ? _ceilDiv(amount * 2, 100) : _ceilDiv(amount * 2, 98);
            if (params.amountSpecified < 0 && fee >= amount) revert InvalidSwapAmount();
            if (amount + fee > uint256(uint128(type(int128).max))) revert InvalidSwapAmount();
        }
        return (IHooks.beforeSwap.selector, toBeforeSwapDelta(int128(uint128(fee)), 0), 0);
    }

    function afterSwap(
        address sender,
        PoolKey calldata key,
        SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata
    ) external onlyPoolManager returns (bytes4, int128) {
        _checkPool(key);
        uint256 specified = _specifiedAmount(params.amountSpecified);
        bool pair0 = Currency.unwrap(key.currency0) == PAIRED_ASSET;
        bool buy = params.zeroForOne == pair0;
        int128 pairDelta = pair0 ? delta.amount0() : delta.amount1();
        // Core deltas are negative for input, positive for output.
        if ((buy && pairDelta > 0) || (!buy && pairDelta < 0)) revert InvalidSwapAmount();
        uint256 paired = pairDelta < 0 ? uint256(-int256(pairDelta)) : uint256(int256(pairDelta));
        bool pairSpecified = _pairIsSpecified(key, params);
        uint256 fee;
        if (pairSpecified) {
            fee = buy ? _ceilDiv(specified * 2, 100) : _ceilDiv(specified * 2, 98);
            uint256 expected = buy ? specified - fee : specified + fee;
            // v4 cannot alter the specified delta in afterSwap. Reverting atomically
            // prevents charging the reserved fee for an unfilled price-limited trade.
            if (paired != expected) revert PartialFillOfPairedAmount();
        } else {
            fee = buy ? _ceilDiv(paired * 2, 98) : _ceilDiv(paired * 2, 100);
        }
        if (fee > uint256(uint128(type(int128).max))) revert InvalidSwapAmount();
        if (fee != 0) {
            totalFees += fee;
            // Minting a claim debits this hook; the positive return delta credits it.
            // No IMD transfer occurs before the router has settled its input.
            poolManager.mint(maintenancePot, uint256(uint160(PAIRED_ASSET)), fee);
            emit FeeAccrued(PoolId.unwrap(poolId), buy, paired, fee, maintenancePot);
        }
        if (paired != 0) _recordTrade(sender, params, delta, paired);
        return (IHooks.afterSwap.selector, pairSpecified ? int128(0) : int128(uint128(fee)));
    }

    function currentPulse() public view returns (uint256) {
        return pulseAt(block.number);
    }

    /// @notice Historical pulse, decayed by one point per elapsed block. Current-block
    /// history can still change; a completed block's history never changes.
    function pulseAt(uint256 atBlock) public view returns (uint256) {
        uint256 low;
        uint256 high = pulseHistory.length;
        while (low < high) {
            uint256 mid = (low + high) / 2;
            if (pulseHistory[mid].blockNumber <= atBlock) low = mid + 1;
            else high = mid;
        }
        if (low == 0) return 0;
        PulsePoint memory point = pulseHistory[low - 1];
        uint256 decay = (atBlock - point.blockNumber) * PULSE_DECAY_PER_BLOCK;
        return decay >= point.value ? 0 : point.value - decay;
    }

    /// @notice Permissionless keeper notification. Decay is computed in views even if
    /// no keeper calls; callers cannot choose or inflate the pulse or receive a bounty.
    function updatePulse() external returns (uint256 value) {
        value = currentPulse();
        uint256 n = pulseHistory.length;
        uint256 old = n == 0 ? 0 : pulseHistory[n - 1].value;
        if (old != value) {
            _writePulse(value);
            emit PulseUpdated(block.number, old, value);
        }
    }

    function glyphSeed(address holder, uint256 slot) public view returns (bytes32 id, bytes32 seed) {
        SwarmPeg.Glyph memory g = token.glyphAt(holder, slot);
        id = g.id;
        // Trade entropy aggregates actual PoolManager deltas for the acquisition block.
        // No router-supplied user identity or external entropy service is trusted.
        seed = keccak256(
            abi.encode(g.transferSeed, tradeEntropy[g.bornBlock], g.bornBlock, g.previousHolder, pulseAt(g.bornBlock))
        );
    }

    function glyphSVG(address holder, uint256 slot) public view returns (string memory) {
        (bytes32 id, bytes32 seed) = glyphSeed(holder, slot);
        return GlyphRenderer.render(seed, id, currentPulse());
    }

    function glyphURI(address holder, uint256 slot) external view returns (string memory) {
        (bytes32 id,) = glyphSeed(holder, slot);
        return string.concat(
            "data:application/json;base64,",
            Base64.encode(
                bytes(
                    string.concat(
                        '{"name":"SwarmPeg #',
                        uint256(id).toHexString(32),
                        '","description":"A whole-token balance glyph. Immutable on-chain rules; live swarm pulse.","holder":"',
                        holder.toHexString(),
                        '","slot":',
                        slot.toString(),
                        ',"pulse":',
                        currentPulse().toString(),
                        ',"image":"data:image/svg+xml;base64,',
                        Base64.encode(bytes(glyphSVG(holder, slot))),
                        '"}'
                    )
                )
            )
        );
    }

    function _recordTrade(address sender, SwapParams calldata params, BalanceDelta delta, uint256 paired) private {
        uint256 old = currentPulse();
        uint256 addition = paired / IMD_PER_PULSE;
        uint256 next = old + addition;
        if (next > MAX_PULSE) next = MAX_PULSE;
        _writePulse(next);
        uint256 number = ++tradeCount;
        bytes32 entropy = keccak256(
            abi.encode(
                tradeEntropy[block.number],
                sender,
                params,
                delta,
                block.number,
                block.prevrandao,
                block.number == 0 ? bytes32(0) : blockhash(block.number - 1),
                next,
                number
            )
        );
        tradeEntropy[block.number] = entropy;
        emit TradeRecorded(number, block.number, sender, entropy);
        emit PulseUpdated(block.number, old, next);
    }

    function _writePulse(uint256 value) private {
        uint256 n = pulseHistory.length;
        if (n != 0 && pulseHistory[n - 1].blockNumber == block.number) pulseHistory[n - 1].value = uint16(value);
        else pulseHistory.push(PulsePoint(uint64(block.number), uint16(value)));
    }

    function _pairIsSpecified(PoolKey calldata key, SwapParams calldata params) private pure returns (bool) {
        bool specified0 = (params.amountSpecified < 0) == params.zeroForOne;
        return specified0 == (Currency.unwrap(key.currency0) == PAIRED_ASSET);
    }

    function _specifiedAmount(int256 amount) private pure returns (uint256 value) {
        if (amount == 0 || amount == type(int256).min) revert InvalidSwapAmount();
        value = uint256(amount < 0 ? -amount : amount);
        if (value > uint256(uint128(type(int128).max))) revert InvalidSwapAmount();
    }

    function _checkPool(PoolKey calldata key) private view {
        if (!initialized || PoolId.unwrap(key.toId()) != PoolId.unwrap(poolId)) revert InvalidPool();
    }

    function _ceilDiv(uint256 numerator, uint256 denominator) private pure returns (uint256) {
        return numerator == 0 ? 0 : (numerator - 1) / denominator + 1;
    }
}
