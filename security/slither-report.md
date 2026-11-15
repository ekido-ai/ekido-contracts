# Slither report

Static analysis of `contracts/src/` with every finding triaged. **This is not an audit.** The contracts are unaudited and testnet only.

## How it was run

| | |
|---|---|
| Date | 14 Nov 2026 |
| Tool | Slither 0.11.6 |
| Compiler | solc 0.8.33 via forge 1.5.1-stable, optimizer on, 200 runs |
| Libraries | OpenZeppelin Contracts v5.7.0, forge-std v1.17.0 |
| Scope | `src/GPUChainEscrow.sol`, `src/ProviderRegistry.sol`, `src/MockUSDC.sol` |
| Command | `slither . --filter-paths "lib/|test/|script/"` from `contracts/` |

The raw output is in [`slither-output.txt`](slither-output.txt). The line numbers in it are as Slither printed them on a Windows checkout and can be a few lines off from the file on GitHub; the function names are exact.

## Result

12 results from 102 detectors, by Slither's own impact rating: **0 High, 2 Medium, 7 Low, 3 Informational**. Both Medium results are false positives (a local variable that deliberately starts at its default value). None of the 12 needs a code change.

| # | Detector | Impact | Where | Triage |
|---|---|---|---|---|
| 1 | `uninitialized-local` | Medium | `paid` in `GPUChainEscrow._applyVerdict` | False positive. Intended: the default value 0 is the starting value of the running total. |
| 2 | `uninitialized-local` | Medium | `previous` in `GPUChainEscrow._checkSignatures` | False positive. Intended: the default `address(0)` is the starting point for the strictly-ascending signer check, and `ECDSA.recover` reverts instead of returning the zero address. |
| 3 | `timestamp` | Low | `createJob`: `deadline <= block.timestamp` | Accepted. See the note on timestamps below. |
| 4 | `timestamp` | Low | `dispute`: `block.timestamp >= job.disputeEnd` | Accepted. Same note. |
| 5 | `timestamp` | Low | `markActive`: `block.timestamp >= job.deadline` | Accepted. Same note. |
| 6 | `timestamp` | Low | `submitAttestation`: `block.timestamp > verdict.expiry` | Accepted. Same note. |
| 7 | `timestamp` | Low | `finalize`: `block.timestamp < job.disputeEnd` | Accepted. Same note. |
| 8 | `timestamp` | Low | `finalizeAfterArbiterTimeout`: `block.timestamp < job.disputedAt + ARBITER_TIMEOUT` | Accepted. Same note. |
| 9 | `timestamp` | Low | `claimTimeoutRefund`: `block.timestamp < job.deadline + REFUND_GRACE` | Accepted. Same note. |
| 10 | `unindexed-event-address` | Informational | `GPUChainEscrow.CoordinatorUpdated` | Dismissed. Cosmetic; changing the event would change the ABI the coordinator and web app read. |
| 11 | `unindexed-event-address` | Informational | `GPUChainEscrow.ArbiterUpdated` | Dismissed. Same reason. |
| 12 | `unindexed-event-address` | Informational | `ProviderRegistry.CoordinatorUpdated` | Dismissed. Same reason. |

### Note on the timestamp results

Deadlines, the refund grace, the dispute window and the arbiter timeout are meant to be hours and days, and a block producer can shift a timestamp only by seconds. The comparisons are how the contract enforces its deadlines, so they stay.

One caveat that the tests document: the contract itself sets no minimum dispute window or deadline lead, so a job created with a window of a few seconds is exposed to that shift. `test/TimestampEdge.t.sol` pins this behaviour, and it is listed under the trust limits in [`../README.md`](../README.md).

## Fuzz and invariant tests

These run with `forge test` (settings in `foundry.toml`: 512 fuzz runs; 128 invariant runs at depth 64).

| Test | What it checks |
|---|---|
| `InvariantTest.invariant_contractIsAlwaysSolvent` in `test/GPUChainEscrow.t.sol` | Across random sequences of create, activate, attest, dispute, resolve, finalize, cancel, timeout and withdraw calls, the escrow's token balance always equals `totalLocked + totalWithdrawable`, so it is never below what it owes |
| `FuzzTest.testFuzz_settlementConservesFunds` | For any budget and any split between two providers and the client, the three withdrawable balances add up to the budget and nothing stays locked |
| `FuzzTest.testFuzz_wrongTotalAlwaysRejected` | A verdict whose amounts do not add up to the budget is always rejected |
