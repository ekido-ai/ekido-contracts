# ekido-contracts

Ekido's smart contracts on Base: the escrow (deployed on Base Sepolia; its name stays `GPUChainEscrow` because the name is part of its signatures) and, next, the proof-anchoring contract.

Part of [Ekido](https://github.com/ekido-ai): your own small AI model, trained on spare devices and paid for only when it works. The shared library, the API contract and the evidence behind every number live in [ekido-core](https://github.com/ekido-ai/ekido-core).

## Rules

- Every change is a pull request with the full report (the PR template); the **Gate** check refuses it otherwise.
- Testnet and test money only. Never commit keys, `.env` contents, wallet keys or customer data.
- Every number we quote is measured and has its raw file.

Licence: all rights reserved (see LICENSE).

---

# Contracts

`GPUChainEscrow` holds the budget and pays out only on a verifier-signed verdict. It is **unaudited, and testnet only.**

## What the escrow does

- `createJob` locks the client's USDC budget with a deadline and a dispute window.
- `submitAttestation` records a verdict that carries enough verifier signatures. The payouts and the refund must add up to the budget exactly. Each provider's amount (per accepted step) and the protocol fee are computed off-chain in `packages/ekido_core` and arrive as payees in the verdict; a refused job has no payees, so no fee is taken on it.
- `finalize` credits each payee and refunds the rest to the client once the dispute window closes. Everyone withdraws their own balance (`withdraw`).
- `markActive` refuses a job whose deadline has passed, and `claimTimeoutRefund` lets anyone refund the client an hour after the deadline.

## Test

From `contracts/`:

```bash
git clone --depth 1 --branch v1.17.0 https://github.com/foundry-rs/forge-std lib/forge-std
git clone --depth 1 --branch v5.7.0 https://github.com/OpenZeppelin/openzeppelin-contracts lib/openzeppelin-contracts
forge test
```

Dependencies in `lib/` aren't tracked, so the two clones are needed once. CI runs the same steps.

| File | What it covers |
|---|---|
| `test/GPUChainEscrow.t.sol` | Create, cancel, activation, attestation, settlement and refund arithmetic, disputes, reentrancy, two fuzz tests and a solvency invariant |
| `test/IndependentF2F5.t.sol` | Exact-second deadline boundaries for `markActive`, `createJob` and the timeout refund; the per-job arbiter snapshot |
| `test/AttackerReview.t.sol` | Attack paths on the 2-of-3 verifier signatures: non-verifier signer, one verifier counted twice, replay on another job, chain or deployment, the same verdict twice, a malleable copy, a field changed after signing. Also six known weaknesses reproduced as `test_poc_*` |
| `test/SignatureVector.t.sol` | The EIP-712 digest and signatures produced by Python (`docs/schemas/vectors/verdict_vector.json`) are accepted by the contract |
| `test/TimestampEdge.t.sol` | Documents that the contract enforces no minimum dispute window, deadline lead or verdict-expiry lead |

## Deploy script

`script/Deploy.s.sol` deploys `GPUChainEscrow` and `ProviderRegistry`. It reads these variables from the environment (names are in `.env.example`): `DEPLOYER_PRIVATE_KEY`, `COORDINATOR_PRIVATE_KEY`, `ARBITER_PRIVATE_KEY`, `VERIFIER_1_PRIVATE_KEY`, `VERIFIER_2_PRIVATE_KEY`, `VERIFIER_3_PRIVATE_KEY`, and optionally `VERIFIER_QUORUM` (default 2) and `DISPUTE_BOND` (default 1,000,000, one test USDC). On Anvil (chain 31337) it also deploys `MockUSDC`; on any other chain it uses `USDC_ADDRESS`. It prints `ESCROW_ADDRESS` and `REGISTRY_ADDRESS`.

**Run on a local chain** (checked: the escrow came up with the expected coordinator, arbiter, bond, one verifier set and a quorum of 2):

```bash
anvil &
forge script script/Deploy.s.sol --rpc-url http://127.0.0.1:8545 --broadcast
```

**Base Sepolia has not been deployed yet.** It needs the team lead's go-ahead, test ETH in the deployer and coordinator wallets, and the testnet-only keys in an uncommitted `.env`. Never commit keys; `broadcast/` is ignored.

Only `DEPLOYER_PRIVATE_KEY` needs to be on the deploy machine. For the coordinator, arbiter and verifiers the script takes `COORDINATOR_ADDRESS`, `ARBITER_ADDRESS` and `VERIFIER_1_ADDRESS` to `VERIFIER_3_ADDRESS`, and falls back to the address of the matching `*_PRIVATE_KEY` only when the address variable is unset, so the earlier way of running it still works. This is a change from the script in the earlier Ekido project. I could not run `forge` here: CI compiles it, but nobody has run this version on Anvil yet.

## ProviderRegistry

`src/ProviderRegistry.sol` holds provider identity and hash references to off-chain GPU passports, and no funds. A provider registers its own wallet once with a metadata hash and can update that hash; the coordinator can anchor a passport root for a registered provider. A registered entry is a provider's claim: being listed proves nothing about its hardware. Tests are in `test/ProviderRegistry.t.sol`.

The registry does not hold worker keys. Enrolling them is the coordinator's job, off-chain, and arrives with the coordinator (#20).

## Minimum dispute window, deadline lead and verdict expiry

**Decision: the coordinator enforces these, not the contract.** The contract checks only that a dispute window is between 1 second and 7 days, that a deadline is in the future, and that a verdict has not expired (`test/TimestampEdge.t.sol` pins this). It was ported as it was, so the minimums live in the coordinator, which refuses to start a job that breaks them:

| Rule | Where the coordinator enforces it | Test |
|---|---|---|
| The dispute window is at least one hour on a public chain. A shorter one is allowed only on the explicitly configured local chain (31337) | `MIN_PUBLIC_DISPUTE_WINDOW_SECONDS` in `SettlementService.require_funded`, `apps/coordinator/ekido_coordinator/settlement_service.py` | `apps/coordinator/tests/test_dispute_window_guard.py` |
| The on-chain deadline is not earlier than the job's agreed deadline (60 seconds of clock tolerance), so a client can't take a refund while work is still running | `DEADLINE_TOLERANCE_SECONDS` in `SettlementService.require_funded` | `apps/coordinator/tests/test_deadline_guard.py` |
| A verdict within 10 minutes of its expiry is rebuilt and signed again instead of submitted | `MIN_SUBMIT_LEAD_SECONDS` in `settlement_service.py` | `test_a_verdict_near_expiry_is_rebuilt_not_submitted` in `apps/coordinator/tests/test_settlement_recovery.py` |

What this does not cover: a client who calls the contract directly, without the coordinator, can still create a job with a one-second window or a short deadline. The coordinator never starts such a job, so no provider is assigned to it.

## Trust limits to state plainly

- Verifiers are a permissioned set, run by the team in this prototype. A quorum of them could approve a bad result.
- The arbiter is a single address, fixed for each job when it's funded. If it stays silent during a dispute, the verdict stands.
- The owner is one key, with no delay: it can change the coordinator at once, and the arbiter and verifier set for new jobs.
- The contract enforces payment rules. It doesn't prove that any computation happened.
- Anyone can refund the client an hour after the on-chain deadline, even if the work is done, unless the verdict was submitted first. The coordinator refuses to start a job whose on-chain deadline is shorter than agreed, but it must also submit the verdict in time.
- A client can delay provider payouts by up to 3 days at no cost: if the arbiter stays silent, a dispute's bond comes back.
- Job IDs are first come, first served. Someone who sees a pending `createJob` can take that ID, so that client must start again with a new job. They can't take the money.
- A refused final model refunds the client in full, and honest providers get nothing for that job.
- The contract sets no minimum dispute window or deadline lead beyond non-zero and not in the past (see `test/TimestampEdge.t.sol`).

## Deployed on Base Sepolia, and checked against this repository

| Contract | Address |
|---|---|
| `GPUChainEscrow` | `0x1BF65f755457a92850009c88AFb337Ec57745a22` |
| `ProviderRegistry` | `0xcdf927CE0D885552529C5463993e64429a51c2Ff` |
| `ProofAnchor` | `0x106Fca32CCf05Dd965B1274E9F2D3B650dDE7115` |

`GPUChainEscrow` and `ProviderRegistry` were deployed from the earlier Ekido repository and are what `https://gpuchain.duckdns.org` uses.

`ProofAnchor` was deployed from this repository on 20 Nov 2026 with `script/DeployProofAnchor.s.sol` (forge, forge-std v1.17.0, OpenZeppelin v5.7.0). The deploy was transaction `0x83222cf4d67a3301e8dcfa95f5876273f54552b56b8bc61b99d43d2194e06ed8`, in block 61273608. Its owner is the team deployer `0x915f91f109980C5E810507feD50d5D364d15E074` (also the escrow's owner), and its coordinator is `0xF560cb62213ae6495A4dCbE75487352EE032B638` (the escrow's coordinator). Both were read back from the chain after the deploy. Nothing anchors to it yet: the coordinator side is ekido-coordinator #14.

On 14 Nov 2026 the code on chain was compared with what this repository compiles to (`infra/verify_deployed_contracts.py`, forge 1.9.0, forge-std v1.17.0, OpenZeppelin v5.7.0). The raw output is `experiments/results/deployment_check_20261114.txt`.

- **`ProviderRegistry`**: 1,396 bytes on chain and compiled here, byte for byte identical.
- **`GPUChainEscrow`**: 11,953 bytes both ways. 225 bytes in 20 places differ, and in every place the compiled code has zeros: those are values the constructor sets (immutables). The metadata hash at the end, which commits to the source and the compiler settings, is identical. I recognised the 1,000,000 dispute bond, the Base Sepolia test USDC address, the contract's own address, the chain id 84532 and the EIP-712 name; I did not identify each of the other differing values one by one.

So the contracts on chain were built from this source with these settings. This does not make them audited: see the Slither report and the limits above.

To run it again: build once in `contracts/` (`forge build`), then from the repository root `python infra/verify_deployed_contracts.py`. It only reads from the chain and uses no key.
