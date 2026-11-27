#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Behavioral coverage for portable workflow receipts; no browser or CUA required."""
from contextlib import redirect_stderr, redirect_stdout
import copy
import io
import json
from pathlib import Path
import stat
import tempfile
import unittest
from unittest.mock import patch

import workflow


def fixture():
    return {
        "workflowVersion": 1,
        "id": "palette-and-gallery",
        "fixture": "synthetic",
        "untested": ["real provider authentication"],
        "steps": [
            {"id": "open-palette", "driver": "native", "from": "ready", "to": "palette",
             "action": "press_key", "target": {"window": "fixture"},
             "args": {"key": "command+shift+p"}, "expect": {"palette_open": True}},
            {"id": "expand-output", "driver": "gallery", "from": "palette", "to": "expanded",
             "action": "gallery.play", "target": {"entry": "agent-pane", "variant": "tools"},
             "args": {}, "expect": {"expanded": True}},
        ],
    }


def context():
    return {
        "source_sha": "a" * 40,
        "artifact": "fleet-build-123",
        "host": "synthetic-host",
        "environment": {"viewport": {"width": 1000, "height": 800}, "scale": 2,
                        "theme": "dark", "locale": "en-US", "density": "default",
                        "reducedMotion": True},
        "native_config": "/private/launch-credentials.json",
    }


def observed(state=None, ok=True):
    return {"status": "passed", "state": state or {"expanded": True},
            "assertions": [{"name": "visible outcome", "ok": ok}],
            "evidence": {"after": "cua-frame:synthetic"}, "metrics": {"settle_ms": 12},
            "event_refs": ["cua:synthetic:7"]}


class WorkflowTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="workflow-tests-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)

    def execute(self, name="run", adapter=None, manifest=None, build=None):
        adapter = adapter or (lambda step, runtime, out: observed({"visible": step["to"]}))
        return workflow.execute(manifest or fixture(), build or context(), self.root / name,
                                adapters={"native": adapter, "gallery": adapter})

    def save(self, name, value):
        path = self.root / name
        path.write_text(json.dumps(value))
        return str(path)

    def cli(self, *args):
        stdout, stderr = io.StringIO(), io.StringIO()
        with redirect_stdout(stdout), redirect_stderr(stderr):
            code = workflow.main(list(args))
        return code, stdout.getvalue(), stderr.getvalue()

    def test_mixed_drivers_follow_graph_and_link_observed_receipts(self):
        calls = []

        def adapter(step, runtime, out):
            calls.append((step["id"], step["driver"], out.name))
            return observed({"visible": step["to"]})

        receipt = self.execute(adapter=adapter)
        self.assertEqual(calls, [("open-palette", "native", "open-palette"),
                                 ("expand-output", "gallery", "expand-output")])
        self.assertEqual(receipt["status"], "passed")
        self.assertIsNone(receipt["first_failed_step"])
        graph = workflow.read(self.root / "run/graph.json")
        self.assertEqual([(e["from"], e["to"]) for e in graph["edges"]],
                         [("ready", "palette"), ("palette", "expanded")])
        for edge in graph["edges"]:
            step = workflow.read(self.root / "run" / edge["receipt"])
            self.assertEqual(step["id"], edge["stepId"])
            self.assertEqual(step["state_hash"], workflow.digest(step["state"]))
            self.assertEqual(edge["eventRefs"], ["cua:synthetic:7"])

    def test_failed_assertion_stops_later_mutations_and_preserves_failure(self):
        calls = []

        def adapter(step, runtime, out):
            calls.append(step["id"])
            return observed({"palette_open": False}, ok=False)

        receipt = self.execute(adapter=adapter)
        self.assertEqual(calls, ["open-palette"])
        self.assertEqual(receipt["status"], "failed")
        self.assertEqual(receipt["first_failed_step"], "open-palette")
        self.assertFalse(receipt["steps"][0]["assertions"][0]["ok"])
        self.assertEqual(receipt["steps"][1]["status"], "unavailable")

    def test_exception_stops_run_and_does_not_store_credentials_or_typed_text(self):
        secret = "fake-secret-never-save-this"
        build = context()
        build["mcp"] = {"token": secret}
        manifest = fixture()
        manifest["steps"][0]["args"] = {"text": secret}
        calls = []

        def adapter(step, runtime, out):
            calls.append(step["id"])
            raise RuntimeError(secret)

        receipt = self.execute(adapter=adapter, manifest=manifest, build=build)
        self.assertEqual(calls, ["open-palette"])
        self.assertEqual(receipt["status"], "unavailable")
        for path in (self.root / "run").rglob("*.json"):
            self.assertNotIn(secret, path.read_text())
            self.assertNotIn("launch-credentials", path.read_text())

    def test_a_capture_without_executed_assertions_cannot_pass(self):
        def adapter(step, runtime, out):
            result = observed()
            result["assertions"] = []
            return result

        receipt = self.execute(adapter=adapter)
        self.assertEqual(receipt["status"], "unavailable")
        self.assertEqual(receipt["first_failed_step"], "open-palette")

    def test_malformed_adapter_result_is_unavailable_and_stops_actions(self):
        calls = []

        def adapter(step, runtime, out):
            calls.append(step["id"])
            result = observed()
            result["assertions"][0]["ok"] = "yes"
            return result

        receipt = self.execute(adapter=adapter)
        self.assertEqual(calls, ["open-palette"])
        self.assertEqual(receipt["status"], "unavailable")

    def test_manifest_validation_happens_before_any_action_or_output(self):
        def duplicate(value):
            value["steps"][1]["id"] = value["steps"][0]["id"]

        mutations = [
            lambda value: value.update(unknown=True),
            lambda value: value.update(workflowVersion=2),
            lambda value: value.update(fixture="personal"),
            lambda value: value.update(steps=[]),
            lambda value: value["steps"][1].update(target={}),
            lambda value: value["steps"][1].update(driver="shell"),
            lambda value: value["steps"][1].update(id="../escape"),
            lambda value: value["steps"][1].update(unknown=True),
            lambda value: value["steps"][1].update(**{"from": "unrelated"}),
            duplicate,
        ]
        for index, mutate in enumerate(mutations):
            with self.subTest(case=index):
                value = fixture()
                mutate(value)
                calls = []
                with self.assertRaises(ValueError):
                    self.execute(name=str(index), manifest=value,
                                 adapter=lambda *args: calls.append(args))
                self.assertEqual(calls, [])
                self.assertFalse((self.root / str(index)).exists())

    def test_unpinned_build_and_invalid_viewport_fail_before_action(self):
        for source, width in (("main", 1000), ("a" * 40, True), ("a" * 40, 0)):
            with self.subTest(source=source, width=width):
                build = context()
                build["source_sha"] = source
                build["environment"]["viewport"]["width"] = width
                calls = []
                with self.assertRaises(ValueError):
                    self.execute(build=build, adapter=lambda *args: calls.append(args))
                self.assertEqual(calls, [])
                self.assertFalse((self.root / "run").exists())

    def test_run_and_step_receipts_are_private(self):
        self.execute()
        for path in (self.root / "run", *(self.root / "run").rglob("*")):
            self.assertEqual(stat.S_IMODE(path.stat().st_mode), 0o700 if path.is_dir() else 0o600)

    def test_existing_output_is_not_overwritten_or_replayed(self):
        before = self.execute()
        calls = []
        with self.assertRaises(FileExistsError):
            self.execute(adapter=lambda *args: calls.append(args))
        self.assertEqual(calls, [])
        self.assertEqual(workflow.read(self.root / "run/receipt.json"), before)

    def test_comparison_ignores_build_host_timing_and_capture_locations(self):
        before = self.execute()
        after = copy.deepcopy(before)
        after["build"].update(source_sha="b" * 40, artifact="fleet-build-456", host="other-host")
        for step in after["steps"]:
            step.update(duration_ms=999, evidence={"after": "cua-frame:another"},
                        metrics={"settle_ms": 42}, event_refs=["cua:other:99"])
        self.assertEqual(workflow.compare(before, after)["status"], "equivalent")

    def test_comparison_identifies_first_changed_state(self):
        before = self.execute()
        after = copy.deepcopy(before)
        after["steps"][0]["state"] = {"visible": "wrong-window"}
        after["steps"][1]["state"] = {"visible": "collapsed"}
        result = workflow.compare(before, after)
        self.assertEqual(result, {"status": "diverged", "step": "open-palette", "field": "state"})

    def test_comparison_identifies_first_changed_assertion(self):
        before = self.execute()
        after = copy.deepcopy(before)
        after["steps"][1]["assertions"][0]["ok"] = False
        result = workflow.compare(before, after)
        self.assertEqual(result["status"], "diverged")
        self.assertEqual(result["step"], "expand-output")

    def test_unavailable_evidence_cannot_compare_equivalent_to_itself(self):
        receipt = self.execute(adapter=lambda *args: workflow.unavailable("consent_required"))
        result = workflow.compare(receipt, copy.deepcopy(receipt))
        self.assertEqual(result["status"], "unavailable")
        self.assertEqual(result["step"], "open-palette")

    def test_empty_receipts_cannot_prove_equivalence(self):
        receipt = self.execute()
        receipt["steps"] = []
        self.assertNotEqual(workflow.compare(receipt, copy.deepcopy(receipt))["status"], "equivalent")

    def test_different_workflows_cannot_compare(self):
        before = self.execute()
        after = copy.deepcopy(before)
        after["manifest_sha256"] = "b" * 64
        self.assertEqual(workflow.compare(before, after)["status"], "incomparable")

    def test_cli_check_list_and_compare_read_written_receipts(self):
        manifest_path = self.save("manifest.json", fixture())
        code, stdout, stderr = self.cli("check", manifest_path)
        self.assertEqual((code, stderr), (0, ""))
        self.assertEqual(json.loads(stdout)["steps"], 2)
        receipt = self.execute()
        code, stdout, stderr = self.cli("list", str(self.root))
        rows = [json.loads(line) for line in stdout.splitlines()]
        self.assertEqual((code, stderr, len(rows)), (0, "", 1))
        self.assertEqual(rows[0]["workflow"], receipt["workflow"])
        self.assertEqual(rows[0]["artifact"], "fleet-build-123")
        self.assertEqual(rows[0]["steps"][0]["evidence"], receipt["steps"][0]["evidence"])
        receipt_path = str(self.root / "run/receipt.json")
        code, stdout, stderr = self.cli("compare", receipt_path, receipt_path)
        self.assertEqual((code, stderr), (0, ""))
        self.assertEqual(json.loads(stdout)["status"], "equivalent")

    def test_replay_rejects_changed_fixture_before_dispatch(self):
        receipt = self.execute()
        changed = fixture()
        changed["steps"][0]["args"]["key"] = "escape"
        with patch.object(workflow, "execute") as execute:
            code, _, _ = self.cli("replay", self.save("changed.json", changed),
                                  "--context", self.save("context.json", context()),
                                  "--out", str(self.root / "replay"),
                                  "--baseline", self.save("baseline.json", receipt))
        self.assertEqual(code, 2)
        execute.assert_not_called()

    def test_repeated_failed_assertion_is_not_a_successful_replay_exit(self):
        manifest = fixture()
        manifest["steps"] = manifest["steps"][:1]
        failed = self.execute(manifest=manifest, adapter=lambda *args: observed(ok=False))
        # The fake replay adapter has already produced the same failing outcome.
        replay_dir = self.root / "replay"
        replay_dir.mkdir()
        with patch.object(workflow, "execute", return_value=copy.deepcopy(failed)):
            code, stdout, _ = self.cli("replay", self.save("manifest.json", manifest),
                                       "--context", self.save("context.json", context()),
                                       "--out", str(replay_dir),
                                       "--baseline", self.save("baseline.json", failed))
        self.assertNotEqual(code, 0, stdout)


if __name__ == "__main__":
    unittest.main()
