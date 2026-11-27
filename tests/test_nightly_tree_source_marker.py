#!/usr/bin/env python3
"""Exercise the observations that the NOW artifact-tree reader consumes."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / "scripts/ci/nightly_tree_source.py"
KEY = "c" * 40
SHA = "9b1eb696154eb725069d18bed02902c04cdc4494"


class TreeSource(unittest.TestCase):
    def invoke(self, kind, **changes):
        with tempfile.TemporaryDirectory() as tmp:
            output = Path(tmp) / "output"
            output.touch()
            env = dict(os.environ, RUNNER_TEMP=tmp, GITHUB_OUTPUT=str(output),
                       GITHUB_RUN_ID="41275955555", GITHUB_RUN_ATTEMPT="2",
                       TREE_PENDING="true", TREE_READY="false", OWNS_KEY="true",
                       TREE_KEY=KEY, BUILD_SHA=SHA, GITHUB_SHA="a" * 40)
            env.update(changes)
            result = subprocess.run([sys.executable, str(SCRIPT), kind], env=env,
                                    capture_output=True, text=True)
            values = dict(line.split("=", 1) for line in output.read_text().splitlines())
            files = {p.name: json.loads(p.read_text()) for p in Path(tmp).glob("tree-*.json")}
            return result, values, files

    def test_pending_dependency_is_bound_to_build_not_control_sha(self):
        result, values, files = self.invoke("dependency")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(values["name"], f"nightly-tree-dependency-{KEY}-{SHA}-attempt-2")
        self.assertEqual(files, {"tree-dependency.json": {
            "schema_version": 1, "kind": "dependency", "key": KEY,
            "build_sha": SHA, "run_id": 41275955555, "run_attempt": 2}})
        self.assertEqual(Path(values["path"]).name, "tree-dependency.json")

    def test_nonpending_and_unknown_dependency_publish_nothing(self):
        for pending in ("false", "", "unknown"):
            with self.subTest(pending=pending):
                result, values, files = self.invoke("dependency", TREE_PENDING=pending)
                self.assertEqual((result.returncode, values, files), (0, {}, {}))

    def test_owner_is_exact_key_lookup_with_current_attempt_payload(self):
        result, values, files = self.invoke("owner", GITHUB_RUN_ID="41275912151", GITHUB_RUN_ATTEMPT="1")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(values["name"], f"cmux-tui-tree-owner-{KEY}")
        self.assertEqual(files, {"tree-owner.json": {
            "schema_version": 1, "kind": "owner", "key": KEY,
            "run_id": 41275912151, "run_attempt": 1}})
        self.assertEqual(Path(values["path"]).name, "tree-owner.json")

    def test_rerun_replaces_attempt_payload_without_changing_owner_lookup(self):
        _, first, old_files = self.invoke("owner", GITHUB_RUN_ATTEMPT="1")
        _, second, new_files = self.invoke("owner", GITHUB_RUN_ATTEMPT="2")
        self.assertEqual(first["name"], second["name"])
        self.assertEqual(old_files["tree-owner.json"]["run_attempt"], 1)
        self.assertEqual(new_files["tree-owner.json"]["run_attempt"], 2)

    def test_waiting_and_unknown_ownership_publish_nothing(self):
        for owns in ("false", "", "unknown"):
            with self.subTest(owns=owns):
                result, values, files = self.invoke("owner", OWNS_KEY=owns)
                self.assertEqual((result.returncode, values, files), (0, {}, {}))

    def test_ready_or_unknown_tree_cannot_be_a_build_blocker(self):
        for ready in ("true", "", "unknown"):
            with self.subTest(ready=ready):
                result, values, files = self.invoke("owner", TREE_READY=ready)
                self.assertEqual((result.returncode, values, files), (0, {}, {}))

    def test_canonical_key_validation_prevents_ambiguous_metadata(self):
        for key in ("", "x" * 40, "a" * 39, "v2-" + KEY, KEY + "\nname=other"):
            with self.subTest(key=key):
                result, values, files = self.invoke("owner", TREE_KEY=key)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual((values, files), ({}, {}))

    def test_missing_build_source_does_not_fall_back_to_control_sha(self):
        result, values, files = self.invoke("dependency", BUILD_SHA="")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual((values, files), ({}, {}))

    def test_invalid_run_or_attempt_cannot_publish(self):
        for field in ("GITHUB_RUN_ID", "GITHUB_RUN_ATTEMPT"):
            for value in ("", "0", "-1", "1.0", "unknown"):
                with self.subTest(field=field, value=value):
                    result, values, files = self.invoke("owner", **{field: value})
                    self.assertNotEqual(result.returncode, 0)
                    self.assertEqual((values, files), ({}, {}))


if __name__ == "__main__":
    unittest.main()
