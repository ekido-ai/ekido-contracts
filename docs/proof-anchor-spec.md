# ProofAnchor: specification

Ticket: ekido-ai/ekido-internal#58 (A8). Status: spec written before the code; tests in `test/ProofAnchor.t.sol` are written from this page.

## Purpose

Every paid Ekido job leaves a proof: hashes of its terms, its quality verdict and its payout split. The Coordinator groups new proofs into a batch, builds a Merkle root over them off-chain, and writes **one record per batch** here: `(root, count, time)`. Anyone can later check that a job's proof is inside a batch by recomputing the path to an anchored root. The contract keeps nobody's data and nobody's money.

## What it must never do

- Hold, receive or send ETH or any token. It has no payable function, no `receive`, no `fallback`, and makes no external calls.
- Touch `GPUChainEscrow`. It shares no storage and no address with it.
- Let anyone but the coordinator add a batch, or let anyone edit or delete a batch once written.

## State

| Name | Type | Meaning |
|---|---|---|
| `coordinator` | `address` | The only address that may anchor |
| `batchCount` | `uint256` | Number of batches so far; ids run from 0 to `batchCount - 1` |
| batch `i` | `Batch{bytes32 root; uint64 count; uint64 time}` | One anchored batch. `time` is `block.timestamp` when written |
| `rootToId` | private map `root => id + 1` | Lets anyone ask whether a root is anchored; 0 means "not anchored" |

## Functions

| Function | Who | Behaviour |
|---|---|---|
| `constructor(owner_, coordinator_)` | deployer | Sets the owner and the first coordinator. Reverts `ZeroAddress` for a zero coordinator |
| `anchor(root, count)` | coordinator only | Appends a batch and returns its id. Reverts `NotCoordinator` for anyone else, `EmptyRoot` if `root == 0`, `EmptyBatch` if `count == 0`, `AlreadyAnchored` if the root is already stored. Emits `BatchAnchored(id, root, count, time)` |
| `getBatch(id)` | anyone (view) | Returns the batch. Reverts `UnknownBatch` if `id >= batchCount` |
| `isAnchored(root)` | anyone (view) | Returns `(found, id)` |
| `setCoordinator(newCoordinator)` | owner only | Replaces the coordinator (key rotation). Reverts `ZeroAddress` for zero. Emits `CoordinatorUpdated` |
| `renounceOwnership()` | owner | Always reverts `RenounceDisabled`, so the contract can never be left with no one able to rotate the coordinator |
| `owner`, `transferOwnership` | | From OpenZeppelin `Ownable` (v5.7.0), unchanged except `renounceOwnership` |

The constructor also emits `CoordinatorUpdated` for the first coordinator, so the full history of coordinators is in the logs. `CoordinatorUpdated` indexes the address.

## Why it cannot move funds

1. No function is `payable` and there is no `receive` or `fallback`, so a normal transfer to it reverts.
2. No function reads a balance, sends value, calls another contract or uses `delegatecall` or `selfdestruct`.
3. ETH can only reach it by being forced in (for example another contract self-destructing to it). Such ETH is stuck, nothing can send it out, and nothing in the contract depends on its balance.

## Verification of a proof (off-chain)

`root` is the Merkle root over the batch's proof leaves (built by C25). A verifier takes one job's leaf and its Merkle path, recomputes the root, and checks `isAnchored(root)`. Which hash function and leaf format are used is defined by C25, not here; this contract treats `root` as opaque 32 bytes.

## Deployment

Base Sepolia only, and only after Piyush's "haan". Constructor arguments: the owner (a team-held address) and the coordinator's address.
