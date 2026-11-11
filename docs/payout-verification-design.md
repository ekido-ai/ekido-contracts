# Independent payout verification: implementation target

The original workers signed coordinator-supplied payout fields after checking only their own final quality result. The local reproduction in `experiments/results/verifier_payout_trust_gap_20261105.json` shows why the contract quorum alone is insufficient. The default worker now uses the independent passing-verdict checks below; the protocol remains under validation and failed-job signing is refused. Explicit unsafe local demo mode retains the original vulnerability.

## Trust anchors

- Each verifier gets its chain ID, RPC endpoint and escrow address from its own deployment configuration, not the coordinator's task. It checks the actual RPC chain ID.
- The funded on-chain job fixes the spec hash, policy hash and budget. Each verifier independently reads these from the configured escrow and checks its locally observed job and evaluation against them.
- To bind the coordinator's off-chain job ID to that specific funded job, the client can sign a `gpuchain.job_binding.v1` document containing both job IDs, chain ID, escrow, spec hash, policy hash and budget. The verifier recovers the signer and matches it to the escrow's client. The prototype checker currently uses EIP-191 EOA signatures; contract wallets would need an EIP-1271 path before being supported.
- The client-approved job spec must fix eligible provider wallet addresses and prices, including any later replacement that may be paid. The signer-to-provider relationship must be established using the provider wallet's signed worker-key delegation. A coordinator-supplied price or mapping alone is not a trust anchor.
- A provider's worker-key delegation does not by itself prove that provider agreed to its rate. The checker requires a provider-signed quote binding the rate, workload, job, chain, escrow and wallet. Offline helpers produce quotes and client bindings for the new job creation path. The implementation uses EOA signatures; contract-wallet consent needs an EIP-1271 path.
- An honest verifier stores its own signed final PASS and the exact job, policy and checkpoint it evaluated. It checks the proposed reports, their distinct authorized signers and their evaluation context against the escrow's snapshotted verifier set and quorum.

## Evidence to validate before signing

1. A bounded ordered collection of complete signed checkpoint manifests, including the final checkpoint. Recompute each manifest hash, verify the worker signature and wallet delegation, and require the exact hash list in the proposed verdict.
2. Each manifest belongs to the same job and immutable spec. Require parent links to match, steps to strictly increase and the final step to match the agreed total. Refuse missing, duplicate, reordered, substituted or rejected lineage entries.
3. Derive steps per enrolled signer from the authenticated manifests, compute amounts in exact USDC base units from the pre-agreed provider terms, aggregate worker keys belonging to the same wallet, enforce the budget cap using the protocol's deterministic order, and compare every payee, amount and refund with the proposed verdict.
4. Verify report signatures, final-check context, allowed verifier membership and distinct quorum independently. The coordinator cannot replace the final reports or change the signing domain, job, budget or quality policy.
5. Refuse malformed or missing evidence, unknown provider terms, missing delegation history or chain-read failures. Never silently fall back to the current weaker signing behavior. Define explicit failure/refund behavior separately; do not accidentally change the currently agreed full-refund policy.

The coordinator retains the wallet-signed delegation for newly enrolled worker keys and supplies known proofs and handover reports with settlement evidence. Older enrollments without a stored signature cannot be authenticated retroactively; the secure path refuses to pay them unless independently authenticated proof is supplied. The signed creation path accepts locally preallocated job IDs and commits provider terms before funding, including for live remote replacements. Existing unsigned demo jobs do not satisfy the new path. Verifiers and job creators need a coordinated rollout; the frozen escrow bytecode does not need to change because it already commits to the spec hash.

## Required validation

Use positive end-to-end settlement on a local chain and adversarial tests that change the payout recipient, amount, rate, worker delegation, checkpoint step, parent, job, reports, budget, chain ID and escrow address one at a time. Include worker restart with its older key, missing proofs, unavailable RPC, and a failed-job refund. Run the complete CPU suites and keep raw results. Only then can the project claim a non-colluding verifier quorum refuses a coordinator's fabricated payout under these stated trust assumptions.

Even a correctly signed checkpoint is a provider's claim about the step and its contents; the quality test is not a proof that each training step actually executed. This design does not change that limit.
