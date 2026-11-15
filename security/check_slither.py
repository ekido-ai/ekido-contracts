"""Fails when a Slither JSON report holds a High or Medium result that has not been triaged.

Usage: python check_slither.py slither.json

The two results below are known false positives, triaged in slither-report.md (#1 and #2). Each is a
local variable that deliberately starts at its default value. They are matched by detector, variable,
function and contract, so the same detector firing anywhere else still fails the job.
"""
import json
import sys

FAIL_ON = {"High", "Medium"}

# (detector, variable, function, contract)
KNOWN_FALSE_POSITIVES = {
    ("uninitialized-local", "paid", "_applyVerdict", "GPUChainEscrow"),
    ("uninitialized-local", "previous", "_checkSignatures", "GPUChainEscrow"),
}


def _signature(finding: dict) -> tuple:
    """(detector, variable, function, contract) for a finding about one variable, else None parts."""
    variable = next((e for e in finding.get("elements", []) if e.get("type") == "variable"), None)
    if variable is None:
        return (finding["check"], None, None, None)
    function = variable.get("type_specific_fields", {}).get("parent", {})
    contract = function.get("type_specific_fields", {}).get("parent", {})
    return (finding["check"], variable.get("name"), function.get("name"), contract.get("name"))


def untriaged(report: dict) -> list[dict]:
    findings = report.get("results", {}).get("detectors", [])
    return [f for f in findings if f.get("impact") in FAIL_ON and _signature(f) not in KNOWN_FALSE_POSITIVES]


def main(path: str) -> int:
    with open(path, encoding="utf-8") as handle:
        report = json.load(handle)
    # A crashed or non-compiling run still writes JSON, without results. Refuse it, or the job would
    # report "0 new High or Medium" when nothing was analysed.
    if report.get("success") is not True:
        print(f"Slither did not complete: {report.get('error')}")
        return 1
    bad = untriaged(report)
    for finding in bad:
        print(f"NEW {finding['impact']} {finding['check']}: {finding.get('description', '').strip()}")
    total = len(report.get("results", {}).get("detectors", []))
    print(f"{total} results, {len(bad)} new High or Medium")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1]))
