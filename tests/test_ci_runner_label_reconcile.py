#!/usr/bin/env python3
"""runner_label_reconcile.py converges glaeda mini runners' labels to glaeda's rule, idempotently."""
from __future__ import annotations

import contextlib
import importlib.util
import io
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts/ci/runner_label_reconcile.py"
WORKFLOW = ROOT / ".github/workflows/runner-label-reconcile.yml"
SPEC = importlib.util.spec_from_file_location("runner_label_reconcile", SCRIPT)
reconcile = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(reconcile)

# A stand-in for glaeda_fleet_labels.widened_labels(): a std side label also gets the light one.
RULES = '''
def widened_labels(labels):
    out = list(dict.fromkeys(labels))
    if "glaeda-side-std-xcode-26.6" in out and "glaeda-side-light-xcode-26.6" not in out:
        out.append("glaeda-side-light-xcode-26.6")
    return out
'''


def runner(rid, name, *custom, busy=False):
    return {"id": rid, "name": name, "busy": busy,
            "labels": [{"name": "self-hosted", "type": "read-only"}, {"name": "macOS", "type": "read-only"},
                       *({"name": label, "type": "custom"} for label in custom)]}


class FakeApi:
    def __init__(self, runners):
        self.list, self.calls = runners, []

    def runners(self):
        return self.list

    def set_labels(self, rid, labels):
        self.calls.append((rid, list(labels)))
        for item in self.list:
            if item["id"] == rid:
                item["labels"] = [label for label in item["labels"] if label["type"] != "custom"] + [
                    {"name": label, "type": "custom"} for label in labels]


class Reconcile(unittest.TestCase):
    def run_main(self, api, *argv):
        with tempfile.TemporaryDirectory() as tmp:
            rules = Path(tmp) / "rules.py"
            rules.write_text(RULES)
            out = io.StringIO()
            with contextlib.redirect_stdout(out):
                self.assertEqual(reconcile.main(list(argv), {"GLAEDA_LABELS": str(rules)}, api), 0)
            return out.getvalue()

    def fleet(self):
        return [runner(1, "cmux7-glaeda-3", "glaeda-mini", "glaeda-std-xcode-26.6", "glaeda-side-std-xcode-26.6",
                       busy=True),
                runner(2, "cmux7-glaeda", "glaeda-mini", "glaeda-std-xcode-26.6", "glaeda-root-std-xcode-26.6"),
                runner(3, "blacksmith-x", "blacksmith-6vcpu-macos-26", "glaeda-side-std-xcode-26.6")]

    def test_a_dry_run_changes_nothing(self):
        api = FakeApi(self.fleet())
        self.assertIn("cmux7-glaeda-3: would add glaeda-side-light-xcode-26.6", self.run_main(api))
        self.assertEqual(api.calls, [])

    def test_apply_sets_only_glaeda_minis_that_differ_and_is_idempotent(self):
        api = FakeApi(self.fleet())
        self.run_main(api, "--apply")
        # Only custom labels are sent; a busy runner is relabelled too (labels never interrupt a job), and a
        # runner without glaeda-mini is never touched.
        self.assertEqual(api.calls, [(1, ["glaeda-mini", "glaeda-std-xcode-26.6", "glaeda-side-std-xcode-26.6",
                                          "glaeda-side-light-xcode-26.6"])])
        self.assertIn("0 runner(s) relabelled", self.run_main(api, "--apply"))
        self.assertEqual(len(api.calls), 1)

    def test_the_workflow_reads_glaedas_rule_and_applies_on_schedule(self):
        text = WORKFLOW.read_text()
        self.assertIn("repository: teamleaderleo/glaeda", text)
        self.assertIn("GLAEDA_LABELS: glaeda/scripts/glaeda_fleet_labels.py", text)
        self.assertIn("permission-organization-self-hosted-runners: write", text)
        self.assertIn("github.event_name == 'schedule' || inputs.apply", text)


if __name__ == "__main__":
    unittest.main()
