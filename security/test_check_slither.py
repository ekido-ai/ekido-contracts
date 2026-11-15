"""Checks that check_slither.py fails closed. Run from contracts/security: python -m unittest test_check_slither"""
import json
import os
import tempfile
import unittest

import check_slither


def run(report: dict) -> int:
    with tempfile.TemporaryDirectory() as folder:
        path = os.path.join(folder, "slither.json")
        with open(path, "w", encoding="utf-8") as handle:
            json.dump(report, handle)
        return check_slither.main(path)


def finding(impact: str, variable: str, function: str) -> dict:
    parent = {"name": function, "type_specific_fields": {"parent": {"name": "GPUChainEscrow"}}}
    return {
        "check": "uninitialized-local",
        "impact": impact,
        "description": "x",
        "elements": [{"type": "variable", "name": variable, "type_specific_fields": {"parent": parent}}],
    }


class CheckSlitherTest(unittest.TestCase):
    def test_a_crashed_run_fails(self):
        self.assertEqual(run({"success": False, "error": "compilation failed", "results": {}}), 1)
        self.assertEqual(run({"success": False, "error": "compilation failed"}), 1)

    def test_a_report_with_no_success_field_fails(self):
        self.assertEqual(run({}), 1)

    def test_a_clean_run_passes(self):
        self.assertEqual(run({"success": True, "error": None, "results": {"detectors": []}}), 0)

    def test_a_triaged_false_positive_passes(self):
        report = {"success": True, "results": {"detectors": [finding("Medium", "paid", "_applyVerdict")]}}
        self.assertEqual(run(report), 0)

    def test_the_same_detector_elsewhere_fails(self):
        report = {"success": True, "results": {"detectors": [finding("Medium", "total", "submitAttestation")]}}
        self.assertEqual(run(report), 1)


if __name__ == "__main__":
    unittest.main()
