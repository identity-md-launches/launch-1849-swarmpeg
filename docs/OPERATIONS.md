# Deployment and operation

## Before launch

1. Build the pinned sources and run the default tests and formatting check. Dependencies are ordinary vendored files with revisions in `dependencies.json`; no submodules or linked external libraries are used by the launch contracts.
2. Have an independent contributor review the deployed bytecode and fee-delta accounting. The local self-review is not an independent audit.
3. The manifest/deployer supplies the real chain-1 PoolManager and factory. Deploy `SwarmPeg` with no arguments from the authorized launch factory, then `SwarmMaintenance(manager, token)`, then `SwarmPegHook(manager, token, pot, factory)` at a CREATE2 address with low bits `0x20cc`.
4. Verify the pot's manager/token wiring and the hook's manager/token/pot/factory getters. `PrepareDeployment.validateDeployedDependencies` assists with this check. Address inputs are immutable: bad deployment wiring cannot be repaired by an owner.
5. Initialize the exact SWARMPEG/IMD pool from the factory, with fee 12500 and spacing 60, in the same transaction as hook deployment. The factory supplies its opening-market-cap price and sorted currencies. No third party can initialize through this hook. Constructors do not read external contracts.
6. Apply the factory's standard 88%/2%/10% distribution and pool seeding. Do not allocate tokens to these application contracts. No network wallet, requester wallet, or swarm wallet is hardcoded into them.
7. Rehearse against current mainnet state and the actual factory's transaction before release, including real IMD behavior and the final opening price. Verify source and deployed runtime bytecode after the authorized network launch.

The project provides no funded wallet, broadcaster, keys, or attestation. It does not create the launch manifest. `PrepareDeployment` is a read-only calculation helper, not an alternative factory. Salt search can be resumed with a new start range; changing any constructor input or build setting changes the CREATE2 address and requires remining.

## After launch

There are **no owner-only settings to configure**. No operator can set the pulse, fee, renderer, mint supply, pause swaps, or withdraw the pot unilaterally.

- **Traders/frontends:** discover the deployed token/hook/pot from the accepted launch record. Route through the exact pool; show the additional IMD hook fee, integer rounding, and partial-fill policy. Set minimum output, maximum input, deadline, and exact-output completion protections in the selected router. The Solidity test router is not a supported production integration.
- **Glyph viewers/indexers:** track ERC-20 transfers plus glyph range events. Query by `(holder, slot)`, not an ERC-721 ID. Wait for block completion/finality before caching seeds. Requery live SVG when pulse changes. Display that art is rerollable, is not secure randomness, and is not a separate transferable NFT.
- **Keepers/swarm agents:** `updatePulse()` is permissionless. Views already apply decay, so its purpose is recording state/events for consumers. `redeemFees(amount)` makes accumulated IMD claims liquid inside the pot. It cannot pay the caller. These calls require ordinary gas and have no automatic bounty; compensation can be proposed and voted upon as a job.
- **Job proposers:** publish the work and reproducible artifact, derive its `workHash`, approve exactly the needed proposal stake, then call `proposePayment(worker, amount, workHash)`. The contract records a hash, not off-chain storage availability. Ensure the recipient is the worker's real address before voting.
- **Voters:** inspect work, pot funds, and the fixed payout recipient. Approve and deposit voting tokens through `vote(id, support, amount)`. Deposits cannot be withdrawn during voting, and a vote cannot be changed or cast twice. At or after `voteEnd`, call `withdrawVote(id)` to recover the deposited tokens.
- **Anyone:** execute passed jobs after the delay and before expiry, or close rejected/expired jobs. Failed pair-token transfers leave payment state and claims intact for retry within the window. A pending passed job can be closed after expiry if it cannot be paid.
- **Monitoring:** watch accumulated claims, redemption failures, open proposal deadlines, payouts, LP-fee collections, pulse history, pool liquidity, and the real IMD token's operational behavior.

## Assumptions and limits

The supplied Ethereum IMD address is an 18-decimal ERC-20 whose standard transfer behavior is required for pool settlement and redemption. The delivered token itself has no transfer tax or external calls. Hook fees remain IMD-denominated claims until redeemed; they are exposed to IMD and PoolManager risk. Underlying IMD restrictions or failures may prevent pool settlement or job payouts. This hook has no conversion path or rescue administrator.

Glyph ownership follows whole balances, including contracts holding tokens on behalf of others. For example, escrowed voting tokens confer temporary glyph slots to the pot, and a router may temporarily acquire/retire slots during settlement. The ERC-20 owner at the end of the operation is authoritative. Direct SWARMPEG donations to the maintenance pot are not votes and are not recoverable through `withdrawVote`; clients should use the explicit voting methods.

The 2% hook fee applies to this hook's bound pool. Permissionless ERC-20 transfers and other pools cannot be taxed or prevented. Immutability means fixes require new opt-in deployments, not changing the existing pool. Governance approval demonstrates tokenholder acceptance, not formal verification of work quality.
