# SwarmPeg

An immutable Ethereum Uniswap v4 hook launch paired with **IMD**. SwarmPeg is a fixed-supply ERC-20 whose whole-token balances own implicit animated glyphs. `SwarmPegHook` charges **2% in IMD on buys and sells**, records trade-derived art entropy and a swarm pulse, and renders SVG and JSON entirely on chain. **100% of the hook fee goes to an ownerless maintenance pot deployed automatically by the hook's constructor.**

There are no owner, mint-after-construction, pause, upgrade, fee-setting, renderer-setting, or discretionary pulse-setting functions. Maintenance votes authorize payments only; they cannot change these contracts.

## Build and test

```sh
forge build
forge test
forge fmt --check
```

The repository vendors every Solidity dependency as ordinary files. No installation, network, environment variables, filesystem cheatcode permission, FFI, or external service is needed for the default suite. Solidity **0.8.26**, Cancun, optimizer 200, `via_ir = true`, and `bytecode_hash = "none"` are pinned in `foundry.toml`. The existing configuration pins this fuzz seed:

```
0x7dd329dcb6426b6a7b3236d84ade60085e6047dcdeebfd61a8f354d852d6fc70
```

The constructor follow-up is also checked with its supplied seed, without changing the build configuration:

```sh
FOUNDRY_FUZZ_SEED=0x758442a8444751989b11690c736d23a2dbee4bbc6c268031ce2455f1aa5c282e forge test
```

See [validation and security review](docs/SECURITY.md) and [dependency revisions](docs/dependencies.json). The optional `mainnet` profile reads tests in `rehearsal/`; it requires an explicitly supplied Ethereum fork URL and block. It is separate from the offline suite. For example, use `FOUNDRY_PROFILE=mainnet forge test --fork-url <your-authorized-Ethereum-RPC> --fork-block-number 26198120`. No test reads configuration from the environment.

## Contracts and launch parameters

| Contract | Constructor, in ABI order | Responsibility |
| --- | --- | --- |
| `SwarmPeg` | None | Mint exactly `1_000_000_000e18` once to its deploying factory; ERC-20 transfers and compact glyph ownership |
| `SwarmPegHook` | `IPoolManager manager_`, `SwarmPeg token_`, `address factory_` | Deploy its treasury, validate its pool, charge fees, record pulse and trade entropy, render glyphs |
| `SwarmMaintenance` | `IPoolManager manager_`, `IERC20 token_` — supplied internally by the hook | Receive IMD fee claims, redeem them, escrow votes, pay approved jobs |

The hook's only deployment parameters, in ABI order, are the launch's actual PoolManager (`$poolManager`), existing launch token (`$token`), and launch factory (`$factory`). The factory argument is required because `beforeInitialize` reserves first pool initialization to that factory. It grants no treasury, ownership, or upgrade authority, and is never inferred from `msg.sender` or `tx.origin`. There is no `$owner` or external maintenance address argument.

The constructor executes `new SwarmMaintenance(manager_, token_)` and stores its address in `address public immutable maintenancePot`. Each hook receives a dedicated pot with the **same** manager and token. Creation is atomic: a treasury creation failure also reverts hook deployment. Constructors do not call the supplied manager/token or require them to have code; hook construction does deploy the treasury from its embedded creation bytecode. Zero configuration addresses and using IMD as the voting token are rejected.

Deploy the mined hook using the existing token, then discover its treasury through `hook.maintenancePot()`. No separate treasury deployment, registration, placeholder address, or post-launch setter is needed. This change requires no token replacement or mint. `script/PrepareDeployment.s.sol` accepts `Config(manager, token, factory)`, builds the exact hook creation code, mines bounded ranges of CREATE2 salts for the actual factory, and validates deployed wiring via `validateDeployedDependencies(config, hook)`. It never broadcasts or reads keys. Its functions are directly tested, including real CREATE2 deployment. The new creation bytecode requires mining a new salt; salts from the former four-argument constructor must not be reused without recalculation.

Fixed pool terms:

- Chain: Ethereum mainnet, chain ID **1**.
- Pair: IMD, **`0xD34a99Bc0f67aE1bbd63C660e6d0b0dd03E263B7`**, 18 decimals.
- SWARMPEG: 18 decimals; name **SwarmPeg**, symbol **SWARMPEG**.
- LP fee: **12,500 = 1.25%**, in addition to the hook's 2% fee; tick spacing **60**.
- The launch factory derives the opening price from its **2,500 IMD** market-cap policy and actual currency ordering. The hook accepts the factory's valid opening price. Do not deploy with the unit-price test fixture as a production price.
- The factory distributes the single mint: **88% (880 million)** to pool seeding, **2% (20 million)** to the requester/policy recipient, and **10% (100 million)** to the launch's MerkleDistributor for accepted contributors. No supply is reserved for the hook or maintenance pot.

This repository does not execute a deployment, assign the swarm allocation, or write `launch.json`. The network's manifest and authorized factory deployment follow acceptance. See [deployment and operations](docs/OPERATIONS.md).

## Hook configuration and fee accounting

The hook uses the general BaseHook design implemented directly against the pinned v4-core interfaces. Only five permission bits are enabled: `beforeInitialize`, `beforeSwap`, `afterSwap`, `beforeSwapReturnDelta`, and `afterSwapReturnDelta`. The address flags are **`0x20cc` (8396)**. No callback or storage can change these permissions. All three callable lifecycle methods verify the PoolManager; disabled methods revert. Initialization additionally checks the factory, exact token pair, LP fee, tick spacing, and hook address and permanently binds one pool.

`beforeInitialize` prevents initialization before hook deployment and rejects unauthorized initialization. `beforeSwap` and its return delta are necessary when IMD is the specified currency. `afterSwap` uses actual core deltas and collects the fee, records trade data, and returns an unspecified-currency fee when needed. No liquidity callbacks are enabled, so liquidity additions, removals, and the factory's zero-change LP-fee collections remain unrestricted.

Every fee is rounded **up** to the nearest IMD minor unit; the maximum rounding difference is less than one minor unit. Define `G` as the gross IMD amount including the hook fee, `C` as the core pool's IMD input on a buy, and `N` as the requested net IMD output on an exact-output sell:

| Trade | Fee | How exactness is preserved |
| --- | --- | --- |
| Buy, exact IMD input `G` | `ceil(G * 2 / 100)` | Before-swap delta leaves `G - fee` for the core pool |
| Buy, exact SWARMPEG output | `ceil(C * 2 / 98)` | After-swap delta adds the fee to actual IMD input |
| Sell, exact SWARMPEG input | `ceil(G * 2 / 100)` of actual core IMD output | After-swap delta subtracts the fee from IMD received |
| Sell, exact net IMD output `N` | `ceil(N * 2 / 98)` | Before-swap delta requests `N + fee` from the core pool |

For a buy, the fee is 2% of the gross IMD paid, inclusive of the hook fee. For a sell, it is 2% of the gross IMD proceeds before the hook fee. The LP fee is independently applied by v4. Dust can round to a one-unit fee; an exact-input IMD buy whose fee consumes its entire input reverts.

**Partial fills:** when IMD is specified (exact-input buys and exact-output sells), the hook verifies the entire adjusted specified amount filled. It atomically reverts otherwise, because `afterSwap` cannot amend v4's specified-currency delta. When IMD is unspecified, partial fills are allowed and charged only on actual core amounts. Routers must enforce the user's minimum output, maximum input, deadline, and desired exact-output completion. This project does not supply a production router; `test/mocks/PoolHarness.sol` is a settlement/slippage test harness.

The hook mints **IMD ERC-6909 claims directly to `SwarmMaintenance`**. Minting debits the hook's transient balance; the returned positive fee delta cancels it. The router settles its adjusted debt. No IMD or ETH is transferred from the manager during fee accrual. This also works when a one-sided launch pool initially holds no IMD and the manager holds no ETH.

Anyone can call `SwarmMaintenance.redeemFees(amount)` to burn its claims and take IMD **only into the pot** during a manager unlock. Payments can redeem the required amount automatically. Failed redemption or payout reverts atomically and can be retried. Claims are not an extra token issuance or a second charge. Fees deliberately remain in IMD, following the brief's explicit paired-asset requirement; no ETH conversion pool, conversion oracle, or owner-set price limit is needed.

## Integer balance glyphs

`glyphCount(holder) == floor(balanceOf(holder) / 1e18)` at every completed ERC-20 operation. No registration, deposit, trusted router, or sync transaction is necessary. Contract wallets, the manager, the distributor, and the voting pot follow the same rule.

Glyphs are **implicit balance slots**, indexed from zero, rather than separately transferable ERC-721s. A holder keeps the lowest slots when their whole balance decreases; the highest slots retire. Whole-balance increases create new identities at the tail. A transfer can retire a glyph without creating one, or create one without retiring one, when fractional balances cross different whole-token boundaries. A whole-token transfer retires an old identity and creates a fresh recipient identity, as in an integer-balance generative token. Sending a zero transfer or a self-transfer cannot reroll art. There is no independent glyph approval or NFT transfer interface.

Acquisitions are stored in compact batches. A billion-token mint, an 880-million-token seed, or a large transfer creates one batch, not one storage entry per token. Tail removal and lookup use a binary search over live batch endpoints (at most 30 iterations for this supply). Retired storage is logically discarded and reused without a linear cleanup loop. Unaffected prefix slots retain their identity and transfer seed.

`SwarmPeg.glyphAt(holder, slot)` gives the unique ID, transfer seed, immediate previous ERC-20 holder, and acquisition block. IDs commit to the chain, token, holder, slot, and globally increasing acquisition serial. Previous holder means the immediate transfer source: for router-mediated trades that may be the router or PoolManager, not a claim about the underlying seller's identity.

The canonical hook's `glyphSeed` mixes that transfer seed with **actual pool trade data from the acquisition block, block number, previous holder, and historical swarm pulse**. A block's trade accumulator includes direction, specified amount, price limit, actual deltas, router, block data, and trade sequence. All trades in the acquisition block contribute; the seed becomes stable after that block. Genesis/non-trading blocks have no trade accumulator. Later blocks never rewrite an earlier seed. Routers and hook data cannot impersonate a glyph owner.

Art entropy is intentionally public and manipulable by trading, transfer timing, and block producers. It is for visuals only: no payout, rarity reward, lottery, financial oracle, or voting power depends on it.

## Pulse and SVG

Pulse ranges from **0 to 1,000**. Each nonzero trade adds `floor(actual core IMD amount / 1e18)` points and saturates at 1,000. Pulse decays by **one point per block**. `currentPulse()` applies decay even without keepers. Anyone may call `updatePulse()` to record a decayed checkpoint and emit an update, but cannot choose the value or obtain a spam bounty. `pulseAt(blockNumber)` exposes history; current-block history remains provisional until the block ends.

Higher pulse increases satellite nodes from **4 to 12**, palette lightness from **48% to 78%**, and animation speed from **3,200 ms to 1,200 ms**. The central pixel agent pulses, connections draw and fade, nodes breathe, and agent status pixels blink. Layered pixel paths vary faces, hair, mouths, and network placement. All SVG elements, CSS keyframes, JSON, and Base64 encoding are produced by immutable Solidity; there are no external images, fonts, scripts, or IPFS links. Reduced-motion viewers are supported.

- `hook.glyphSVG(holder, slot)` returns SVG text.
- `hook.glyphURI(holder, slot)` returns a Base64 JSON data URI containing a Base64 SVG data URI.
- The **seed** is stable after the acquisition block, while the **rendering** intentionally responds to the current pulse.
- Glyph queries for nonexistent or retired slots revert with `NoGlyph`.

[Quiet example](docs/glyph-quiet.svg) · [High-pulse example](docs/glyph-active.svg). Both examples are emitted by the Solidity renderer for the same illustrative seed.

Clean indexer events include `GlyphsCreated`, `GlyphsRetired`, `PoolBound`, `FeeAccrued`, `TradeRecorded`, `PulseUpdated`, `FeesRedeemed`, and the pot's job/vote/payment events. Range events avoid emitting millions of individual glyph events. Views expose batch counts, glyphs, cumulative fees, trade count, per-block entropy, historical pulse, claims/assets, job state, and vote receipts.

## Maintenance jobs without an owner

All fee revenue is maintenance funding; choosing **100%** satisfies the requested majority and avoids an unspecified remainder recipient. Any holder can propose an IMD payment to a named nonzero worker address for completed work identified by `workHash`. The proposal automatically escrows **1 million SWARMPEG** (0.1% of supply) as its affirmative vote. Other holders vote once per proposal by depositing actual SWARMPEG.

Voting lasts **7 days**. A proposal needs at least **10 million affirmative tokens** (1% of supply) and strictly more affirmative than negative votes. Every deposited vote is locked until voting ends, preventing flash-loan voting or recycling one balance among voters. Depositors can withdraw afterward whether the proposal passes, fails, pays, expires, or encounters a payout failure. Tallies remain final after voting closes.

Anyone may execute a passed proposal after a **2-day delay**, during a **14-day execution window**, to its fixed recipient and amount. No caller can redirect the payout. Failed or expired proposals can be closed permissionlessly. Only one proposal is active at a time; this bounds commitments to the pot's available assets. Payment and withdrawal follow checks-effects-interactions with a reentrancy guard. Votes cannot be spent as fee funds because votes are SWARMPEG and funds are IMD.

Holders judge whether the submitted work deserves payment; the contract does not prove that a renderer improvement or swarm service is useful. A voting majority meeting the quorum controls job spending. The proposal stake is refundable, so wealthy holders can delay other proposals by posting unwanted proposals; there is no administrator to override this. Inactivity can leave fees unspent. These are explicit governance tradeoffs.

Jobs may pay for keeper operation, pulse monitoring, renderer research, new **separately deployed** renderers, generative rules, or client tools. The canonical renderer and hook cannot be replaced. New renderers/rules are opt-in companion products; paying for them grants no upgrade authority.
