"""Check that the contracts deployed on Base Sepolia are what this repository compiles to.

Run from the repository root after the libraries are in place (see contracts/README.md):

    python infra/verify_deployed_contracts.py

It asks `forge inspect` for each contract's runtime bytecode, reads the deployed code from the chain, and compares
them byte by byte. Values set in the constructor (immutables) are zeros in the compiled code and filled in at
deployment, so the check counts where the two differ and whether every difference is a zero on the compiled side.
Everything else, including the trailing metadata hash that commits to the source and compiler settings, must match.

Read-only: it sends `eth_getCode` calls and uses no key. Set FORGE to the forge binary if it is not on PATH.
"""
from __future__ import annotations

import json
import os
import subprocess
import sys
import urllib.request
from pathlib import Path

RPCS = ["https://base-sepolia-rpc.publicnode.com", "https://sepolia.base.org"]
CONTRACTS = Path(__file__).resolve().parents[1] / "contracts"
TARGETS = {
    "GPUChainEscrow": "0x1BF65f755457a92850009c88AFb337Ec57745a22",
    "ProviderRegistry": "0xcdf927CE0D885552529C5463993e64429a51c2Ff",
}
METADATA_BYTES = 53  # the CBOR tail solc appends: the metadata hash and the compiler version


def deployed_code(address: str) -> bytes:
    body = json.dumps({"jsonrpc": "2.0", "id": 1, "method": "eth_getCode", "params": [address, "latest"]}).encode()
    last: Exception | None = None
    for rpc in RPCS:
        try:
            request = urllib.request.Request(rpc, body, {"content-type": "application/json", "user-agent": "curl/8.5.0"})
            with urllib.request.urlopen(request, timeout=30) as response:
                return bytes.fromhex(json.load(response)["result"][2:])
        except Exception as exc:  # try the next endpoint
            last = exc
    raise SystemExit(f"no RPC answered: {last}")


def compiled_code(name: str) -> bytes:
    forge = os.environ.get("FORGE", "forge")
    out = subprocess.run([forge, "inspect", name, "deployedBytecode"], cwd=CONTRACTS, capture_output=True, text=True, check=True)
    return bytes.fromhex(out.stdout.strip().removeprefix("0x"))


def runs(offsets: list[int]) -> list[tuple[int, int]]:
    grouped: list[tuple[int, int]] = []
    for offset in offsets:
        if grouped and offset - grouped[-1][1] == 1:
            grouped[-1] = (grouped[-1][0], offset)
        else:
            grouped.append((offset, offset))
    return grouped


def check(name: str, address: str) -> bool:
    chain, local = deployed_code(address), compiled_code(name)
    print(f"{name} {address}")
    print(f"  deployed {len(chain)} bytes, compiled here {len(local)} bytes")
    if len(chain) != len(local):
        print("  RESULT: different length, not the same build")
        return False
    diff = [i for i in range(len(chain)) if chain[i] != local[i]]
    if not diff:
        print("  RESULT: identical")
        return True
    only_zero_slots = all(local[i] == 0 for i in diff)
    metadata_differs = any(i >= len(chain) - METADATA_BYTES for i in diff)
    print(f"  {len(diff)} differing bytes in {len(runs(diff))} runs")
    print(f"  every differing byte is zero in the compiled code (constructor values): {only_zero_slots}")
    print(f"  metadata hash differs: {metadata_differs}")
    ok = only_zero_slots and not metadata_differs
    print("  RESULT: " + ("same build; only constructor values differ" if ok else "NOT the same build"))
    return ok


if __name__ == "__main__":
    results = [check(name, address) for name, address in TARGETS.items()]
    sys.exit(0 if all(results) else 1)
