# Validation and security review

This is an implementation self-review against the supplied Ethereum and Uniswap v4 security references, not an independent security audit. No production transaction was sent.

## Test scope

The default suite deploys the pinned, real Uniswap v4 PoolManager locally, the real SwarmPeg token, the hook at its required address flags, and a settlement/slippage harness. The hook constructor now creates the maintenance pot; every fee, governance, glyph, and invariant fixture discovers that pot via `maintenancePot()`. The suite exercises both currency orderings and never uses an RPC, fork, test environment variable, FFI, or filesystem permission.

Covered behavior:

- Single fixed mint, name/symbol/decimals, standard 88%/10%/2% transfer amounts, exact ERC-20 transfers, allowance exhaustion, missing allowance, insufficient balances, zero recipient, and unavailable admin/mint selectors.
- Whole balances at fractional boundaries, stable retained glyph prefixes, retired IDs, large transfers, multi-batch trimming, unique regenerated identities, zero/self-transfer behavior, and randomized supply/glyph conservation.
- Real CREATE2 salt mining, constructor flag validation, correct factory initialization, unauthorized callers, wrong token/fee/spacing/pool keys, repeat initialization, runtime size and absence of SELFDESTRUCT, DELEGATECALL, and CALLCODE opcodes.
- Three-argument hook deployment with an automatically created treasury; identical manager/token wiring, distinct pots for separate hooks, claims isolated to the correct pot, constructor success with undeployed external dependencies, invalid constructor/configuration rejection, and atomic hook deployment failure when treasury creation fails. A simulated child-address collision is removed to verify that the same CREATE2 deployment can then succeed. The deployment helper validates the resulting hook and its discovered pot without requiring a pot input.
- Both orderings of all four fee paths; fee rounding and exactness; positive/negative core deltas; actual balances and fee claims; zero transient balances; price-limited fills and atomic failures; router slippage; dust and extreme amounts.
- One-sided liquidity that initially supplies SWARMPEG only, with no IMD or ETH in the PoolManager; a buy successfully accrues claims before the router settles IMD.
- Full-range liquidity, permissionless liquidity withdrawal and zero-change LP-fee collection; trades at the policy's 2,500-IMD whole-supply valuation in both orderings.
- Claim redemption only to the pot; insufficient claims; forged unlock callbacks; approved payment, execution delay/window, expiration, opposition, insufficient quorum, repeated/late votes, locked vote withdrawal, duplicate withdrawal, duplicate payment, invalid work/recipient/amount, and rollback/retry when IMD refuses a payout.
- Pulse saturation/decay/history, permissionless decay updates, canonical seed inputs, stable completed-block seeds, live rendering, on-chain metadata, invalid slots, denser/brighter/faster high-pulse art, and absence of external artwork/script references.
- Stateful invariants with 64 runs of 48 randomized operations: transfers among four holders, all trade modes, claim redemption, and block/pulse advancement. Supply, glyph endpoints, cumulative fees, claims plus redeemed IMD, pulse bounds, and zero final transient deltas are checked together. The run uses `fail_on_revert = true`.

The existing configuration retains fuzz seed `0x7dd329dcb6426b6a7b3236d84ade60085e6047dcdeebfd61a8f354d852d6fc70`. This follow-up also ran the complete suite with `FOUNDRY_FUZZ_SEED=0x758442a8444751989b11690c736d23a2dbee4bbc6c268031ce2455f1aa5c282e`. The result table records local checks of the constructor change; it is evidence for reviewers, not independent attestation.

| Final local check | Result |
| --- | --- |
| `forge build --sizes` | Pass, Solidity 0.8.26 |
| `forge test` with the existing pinned seed | **58 tests passed, 0 failed, 0 skipped** across 9 suites |
| `forge test` with the follow-up's supplied fuzz seed | **58 tests passed, 0 failed, 0 skipped** across 9 suites |
| Stateful invariant group, each seed | **64 runs, 3,072 calls, 0 reverts**, both invariants passed |
| `forge fmt --check` | Pass |
| SwarmPeg runtime / initcode | 3,249 / 5,318 bytes |
| SwarmPegHook runtime / creation bytecode | 12,499 / 18,618 bytes; 18,714-byte initcode including the three arguments |
| SwarmMaintenance runtime / initcode | 4,977 / 5,252 bytes |
| Link references in launch creation bytecode | None |
| Build configuration and vendored dependency fingerprints | Unchanged |

Hook creation bytecode now embeds the existing treasury's creation bytecode; hook and treasury runtimes remain 12,499 and 4,977 bytes. The hook's initcode, including arguments, remains below the 49,152-byte limit, and each runtime remains below 24,576 bytes. The source token, renderer, fee accounting, pulse logic, and treasury governance were not modified. The factory is retained solely to authenticate first pool initialization.

The earlier implementation recorded 6,492 gas in `beforeSwap` and 148,235 gas in `afterSwap` for a first exact-input buy, and generated valid XML SVG samples of 3,728 and 7,909 bytes. Those historical measurements were not rerun in this constructor follow-up. The fee callback performs no SVG rendering and its cost does not scale with the number of whole tokens traded.

## Accounting and adversarial review

| Concern | Implementation / assessment |
| --- | --- |
| Callback authentication | Every implemented lifecycle method checks the immutable PoolManager. Initialization also checks the immutable factory. The pool key is bound once and compared on every swap. |
| Hook-address flags | Exactly `0x20cc`; constructor validates against `getHookPermissions`. CREATE2 production-shaped deployment is tested. |
| Treasury deployment | The hook creates its own ownerless treasury after validating parameters and flags, passing the same manager/token and retaining its address immutably. No externally supplied pot can intercept fees, and child creation failure reverts deployment. The child constructor makes no calls to the supplied dependencies. |
| Before-swap NoOp exposure | The specified return delta is solely the immutable fee: 2% of gross input or a 2/98 gross-up of net output. An input fully consumed by the rounded fee is refused. No owner or arbitrary data can claim the entire input. |
| Delta conservation | Before/after positive IMD fees credit the hook, while `manager.mint(pot, IMD, fee)` debits it equally. Redemption burns pot claims for credit and takes IMD for the matching debit. Real manager unlock completion and explicit transient-balance assertions check this. |
| Partial fills | Paired-specified fills must complete or the entire swap reverts. Paired-unspecified fees use actual core deltas. The hook never overrides the LP fee or price limit. |
| Fee liquidity | Accrual uses claims, not a pre-settlement transfer. No native balance is required. Redemption needs available IMD backing and is outside fee accrual. |
| Reentrancy | SwarmPeg performs no external calls. The hook's only mutating external interaction during swaps is claim minting on its trusted manager. Pot entry points use OpenZeppelin ReentrancyGuard and effects-before-interactions. Its unlock callback requires the actual manager and a pending redemption, cleared before interaction. |
| Arbitrary payer/token send | Only a voter/proposer's own `msg.sender` is pulled into escrow. Withdrawals return that sender's recorded deposit; payouts use the proposal's fixed recipient. The test router pulls only from its entry-point caller, settles its own balance, and refunds unused input. |
| Untrusted router identity | Router and trade data influence art, not ownership, authorization, or payouts. Ownership is read directly from the ERC-20's integrated glyph records. No hook-data end-user assertion is trusted. |
| Voting attacks | Funds must remain escrowed until all voting has ended; once-per-voter receipts survive withdrawal. Flash loans cannot withdraw within the voting transaction. Threshold/majority capture with economically acquired tokens remains a disclosed governance risk. |
| Job treasury access | Only the voting outcome can authorize a job payment. Redemptions cannot redirect money. There is no rescue/sweep/admin function. SWARMPEG voting principal is distinct from IMD treasury assets. |
| Randomness | Trade/block/transfer entropy is deliberately grindable cosmetic data. It controls no value transfer, rarity reward, permission, or vote weight. |
| Gas scaling | No loop scales with transferred token amount. Glyph batches use binary search and logical truncation; renderer loops are bounded by 12 satellite nodes. Rendering is a view and does not execute in swap callbacks. |
| Immutable behavior | No owner, proxy, delegatecall, upgrade, pause, fee setter, or renderer pointer. Maintenance can fund new separately deployed artifacts but cannot alter canonical code. |
| Token assumptions | SWARMPEG is standard ERC-20 plus internal glyph accounting; IMD must support ordinary transfers. The project does not claim support for arbitrary fee-on-transfer/rebasing paired currencies. |
| Dependencies | Source revisions and licenses are vendored; no runtime external library linking. Compiler/EVM/optimizer/metadata settings are pinned. |

Forge build's lint pass still reports cosmetic weak-PRNG usage, time comparisons for multi-day voting windows, narrowing casts, and possible post-call state/event changes in existing logic. The entropy is intentionally non-financial. Fee casts are checked against `int128.max`; slot endpoints are bounded by the fixed billion-token supply; pulse values are capped at 1,000. The `uint64` block/time representation exceeds any realistic Ethereum lifetime. The pot's reported post-call reset and payout event are covered by the entry-point reentrancy guard and pending-callback check; the hook interacts with its trusted manager. Lint also flags Solidity's implicit zero initialization of local counters/fees, the unused `unlock` return bytes (the callback returns empty bytes), and existing test timestamp reads around `vm.warp`; the relevant success/failure tests pass with both seeds. These are reviewed observations, not a claim that every possible defect has been ruled out.

## Mainnet observations and limits

The observations below are retained from the earlier implementation. This constructor follow-up performed local checks only and sent no production transactions or RPC requests.

On 2026-10-15, read-only RPC checks of the supplied Ethereum IMD address returned deployed code (22,990 bytes), symbol `IMD`, and decimals `18`. The gateway reported block **26,198,120**. No credentials, local RPC address, or machine-specific configuration is included in this deliverable.

The optional mainnet fork rehearsal was attempted against that block. Foundry's fork client could not retrieve the chain ID and returned **`tcp connect error: Connection refused (os error 111)`**. Direct metadata checks through the authorized gateway succeeded, but a full mainnet execution rehearsal **did not run and is not counted as passed**. The delivered `rehearsal/Mainnet.t.sol` exercises the same fee/lifecycle suite against real mainnet IMD when a reachable fork endpoint is supplied, using a new isolated real PoolManager. It is not the final factory rehearsal.

Slither, Mythril, formal verification, independent adversarial review, final factory/fork rehearsal, explorer verification, and live monitoring were not performed. Independent review and a successful mainnet/factory simulation remain release responsibilities. No automated tool result here substitutes for the network's acceptance checks.

## Primary implementation references

- [Uniswap v4 hook lifecycle and address flags](https://developers.uniswap.org/docs/protocols/v4/concepts/hooks)
- [Pinned v4 Hooks.sol return-delta accounting](https://github.com/Uniswap/v4-core/blob/46c6834698c48bc4a463a86d8420f4eb1d7f3b75/src/libraries/Hooks.sol)
- [Pinned v4 PoolManager](https://github.com/Uniswap/v4-core/blob/46c6834698c48bc4a463a86d8420f4eb1d7f3b75/src/PoolManager.sol)
- [OpenZeppelin Contracts v5.1.0](https://github.com/OpenZeppelin/openzeppelin-contracts/tree/69c8def5f222ff96f2b5beff05dfba996368aa79)
