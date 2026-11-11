# Contracts

`GPUChainEscrow` holds the budget and pays out only on a verifier-signed verdict. `ProviderRegistry` holds provider identity and passport hashes, and no funds. Both are **unaudited, and testnet only.**

## Test

From the repo root:

```bash
docker run --rm -v "<repo>:/repo" -w /repo/contracts --entrypoint forge ghcr.io/foundry-rs/foundry:latest test
```

Dependencies in `lib/` aren't tracked. If they're missing, download OpenZeppelin Contracts v5.7.0 into `lib/openzeppelin-contracts` and forge-std into `lib/forge-std`.

## Deploy to Base Sepolia

Get Piyush's go-ahead first. It needs test ETH in the deployer wallet, and `.env` filled in by `python infra/make_test_wallets.py`.

```bash
docker run --rm -v "<repo>:/repo" -w /repo/contracts --env-file <repo>/.env --entrypoint forge \
  ghcr.io/foundry-rs/foundry:latest script script/Deploy.s.sol --rpc-url https://sepolia.base.org --broadcast
```

Then copy the printed `ESCROW_ADDRESS` and `REGISTRY_ADDRESS` into `.env`, and verify the contract on BaseScan.

**Wallets to fund:** deployer and coordinator with test ETH. Client with test ETH and test USDC. Providers need a little test ETH to withdraw.

## Trust limits to state plainly

- Verifiers are a permissioned set, run by the team in this prototype. A quorum of them could approve a bad result.
- The arbiter is a single address, fixed for each job when it's funded. If it stays silent during a dispute, the verdict stands.
- The owner is one key, with no delay: it can change the coordinator at once, and the arbiter and verifier set for new jobs.
- The contract enforces payment rules. It doesn't prove that any computation happened.
- Anyone can refund the client an hour after the on-chain deadline, even if the work is done, unless the verdict was submitted first. The coordinator refuses to start a job whose on-chain deadline is shorter than agreed, but it must also submit the verdict in time.
- A client can delay provider payouts by up to 3 days at no cost: if the arbiter stays silent, a dispute's bond comes back.
- Job IDs are first come, first served. Someone who sees a pending `createJob` can take that ID, so that client must start again with a new job. They can't take the money.
- A refused final model refunds the client in full, and honest providers get nothing for that job.

See `docs/arvind-escrow-review-2026-11-05.md`.
