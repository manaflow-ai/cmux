#!/usr/bin/env python3
"""scripts/cmux-next/build-timing.sh (p05-ipc-194): log parsing, edits, rows, restore.

No build: a fake `swift` on PATH prints SwiftPM-style step lines, so the whole
flow (edit, time, parse, put back, row, verdict) runs in well under a second.
"""

from __future__ import annotations

import importlib.util
import json
import os
import stat
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]
SCRIPT = REPO / "scripts/cmux-next/build-timing.sh"
spec = importlib.util.spec_from_file_location("build_timing", REPO / "scripts/cmux-next/build_timing.py")
assert spec and spec.loader
bt = importlib.util.module_from_spec(spec)
spec.loader.exec_module(bt)

SWIFT_LOG = """\
Building for debugging...
[0/12] Write sources
[1/12] Compiling plugin CmuxNextWireGenPlugin
[3/12] Running CmuxNextWireGen sdk-schema.json
[4/12] Emitting module CmuxNextDaemonWire
[5/12] Compiling CmuxNextDaemonWire DaemonRequest.swift
[9/12] Compiling CmuxNextDaemon Foo.swift, Bar.swift
[12/12] Linking CmuxNextApp
Build complete! (4.21s)
"""

LEAF_LOG = """\
[1/3] Compiling CmuxNextDaemonWire DaemonRequest.swift
[2/3] Emitting module CmuxNextDaemonWire
[3/3] Write Objects.LinkFileList
Build complete! (1.02s)
"""

SDK_SCHEMA = {
    "commands": {
        "list-sessions": {"request": {"kind": "object", "fields": {}}, "clients": ["cli"]},
        "ping": {"request": {"kind": "object", "fields": {}}},
        "send": {"request": {"kind": "object", "fields": {"text": {}}}, "clients": ["macos", "cli"]},
        "events": {"request": {"kind": "ref", "name": "X"}},
    }
}

FAKE_SWIFT = """#!/usr/bin/env python3
import os, sys
from pathlib import Path
log = Path(os.environ["FAKE_SWIFT_CALLS"])
with log.open("a") as f:
    f.write(" ".join(sys.argv[1:]) + "\\n")
if sys.argv[1:2] == ["--version"]:
    print("Swift version 6.2 (fake)")
    sys.exit(0)
if os.environ.get("FAKE_SWIFT_FAIL"):
    print("error: boom")
    sys.exit(1)
print("[1/2] Compiling CmuxNextDaemon DaemonRequest.swift")
if os.environ.get("FAKE_SWIFT_GENERATOR"):
    print("[1/2] Running CmuxNextWireGen")
print("[2/2] Emitting module CmuxNextDaemon")
print("Build complete!")
"""


class ParseTests(unittest.TestCase):
    def test_swift_log_targets_steps_and_generator(self) -> None:
        parsed = bt.parse_swift_log(SWIFT_LOG, bt.DEFAULT_GENERATOR_PATTERN)
        self.assertEqual(parsed["targets"], ["CmuxNextDaemon", "CmuxNextDaemonWire"])
        self.assertEqual(parsed["steps"], 12)
        self.assertTrue(parsed["generator_ran"])

    def test_compiling_the_generator_module_is_not_running_it(self) -> None:
        log = "[1/2] Compiling CmuxNextWireGen main.swift\n[2/2] Emitting module CmuxNextWireGen\n"
        parsed = bt.parse_swift_log(log, bt.DEFAULT_GENERATOR_PATTERN)
        self.assertFalse(parsed["generator_ran"])
        self.assertEqual(parsed["targets"], ["CmuxNextWireGen"])

    def test_leaf_log_does_not_run_generator(self) -> None:
        parsed = bt.parse_swift_log(LEAF_LOG, bt.DEFAULT_GENERATOR_PATTERN)
        self.assertEqual(parsed["targets"], ["CmuxNextDaemonWire"])
        self.assertFalse(parsed["generator_ran"])

    def test_cargo_log(self) -> None:
        log = "   Compiling cmux-ipc v0.1.0 (/x)\n   Compiling cmux-tui-core v0.1.0 (/y)\n    Finished dev\n"
        parsed = bt.parse_cargo_log(log)
        self.assertEqual(parsed["targets"], ["cmux-ipc", "cmux-tui-core"])
        self.assertTrue(parsed["generator_ran"])


class EditTests(unittest.TestCase):
    def test_leaf_edit_differs_per_nonce_and_keeps_original(self) -> None:
        original = b"struct A {}\n"
        one, two = bt.leaf_edit(original, 1), bt.leaf_edit(original, 2)
        self.assertTrue(one.startswith(original))
        self.assertNotEqual(one, two)
        self.assertIn(b"private func buildTimingProbe() -> Int { 1 }", one)

    def test_pick_prefers_a_macos_client_command(self) -> None:
        self.assertEqual(bt.pick_schema_command(SDK_SCHEMA, None), "send")

    def test_pick_falls_back_to_ping(self) -> None:
        doc = json.loads(json.dumps(SDK_SCHEMA))
        del doc["commands"]["send"]["clients"]
        self.assertEqual(bt.pick_schema_command(doc, None), "ping")

    def test_pick_refuses_unknown_or_non_object_command(self) -> None:
        with self.assertRaises(bt.UsageError):
            bt.pick_schema_command(SDK_SCHEMA, "nope")
        with self.assertRaises(bt.UsageError):
            bt.pick_schema_command(SDK_SCHEMA, "events")

    def test_schema_edit_adds_one_optional_field_and_keeps_indent(self) -> None:
        original = (json.dumps(SDK_SCHEMA, indent=1) + "\n").encode()
        edited = bt.schema_edit(original, "ping", 3)
        doc = json.loads(edited)
        self.assertEqual(list(doc["commands"]["ping"]["request"]["fields"]), ["build_timing_probe_3"])
        self.assertEqual(doc["commands"]["ping"]["request"]["fields"]["build_timing_probe_3"]["presence"], "optional")
        doc["commands"]["ping"]["request"]["fields"].clear()
        self.assertEqual(doc, SDK_SCHEMA)
        self.assertTrue(edited.decode().startswith('{\n "commands"'))

    def test_schema_edit_on_v2_operations(self) -> None:
        v2 = {"operations": {"agent.list": {"params": {"selectors": {}, "fields": {}}}}}
        original = (json.dumps(v2, indent=2) + "\n").encode()
        doc = json.loads(bt.schema_edit(original, "agent.list", 1))
        self.assertEqual(doc["operations"]["agent.list"]["params"]["fields"]["build_timing_probe_1"]["required"], False)

    def test_real_schemas_have_an_editable_command(self) -> None:
        for path in ("cmux-tui/spec/sdk-schema.json", "cmux-tui/spec/resource-operations-v2.json"):
            original = (REPO / path).read_bytes()
            command = bt.pick_schema_command(json.loads(original), None)
            edited = bt.schema_edit(original, command, 1)
            self.assertGreater(len(edited.splitlines()), len(original.splitlines()), path)

    def test_edited_files_restore_on_exception(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "f"
            path.write_bytes(b"original")
            with self.assertRaises(RuntimeError):
                with bt.EditedFiles() as edits:
                    edits.write(path, b"changed")
                    edits.write(path, b"changed again")
                    raise RuntimeError("build died")
            self.assertEqual(path.read_bytes(), b"original")


class EndToEndTests(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        root = Path(self.tmp.name)
        self.repo = root / "repo"
        leaf = self.repo / "Packages/macOS/CmuxNext/Sources/CmuxNextDaemon/Requests/DaemonRequest.swift"
        leaf.parent.mkdir(parents=True)
        leaf.write_text("public protocol DaemonRequest {}\n")
        schema = self.repo / "cmux-tui/spec/sdk-schema.json"
        schema.parent.mkdir(parents=True)
        schema.write_text(json.dumps(SDK_SCHEMA, indent=1) + "\n")
        self.leaf, self.schema = leaf, schema
        self.originals = {leaf: leaf.read_bytes(), schema: schema.read_bytes()}
        bin_dir = root / "bin"
        bin_dir.mkdir()
        fake = bin_dir / "swift"
        fake.write_text(FAKE_SWIFT)
        fake.chmod(fake.stat().st_mode | stat.S_IXUSR)
        self.calls = root / "calls.log"
        self.out = root / "out.json"
        self.env = {
            "PATH": f"{bin_dir}{os.pathsep}{os.environ['PATH']}",
            "FAKE_SWIFT_CALLS": str(self.calls),
            "CMUX_CI_STEP_KEY": "test",
            "CMUX_CI_SHA": "0123456789abcdef0123",
            "CMUX_CI_CPU_BUDGET": "4",
        }

    def tearDown(self) -> None:
        self.tmp.cleanup()

    def run_script(self, *args: str, **extra_env: str) -> subprocess.CompletedProcess:
        env = {**self.env, **extra_env}
        return subprocess.run(
            [sys.executable, str(REPO / "scripts/cmux-next/build_timing.py"), "--repo-root", str(self.repo),
             "--out", str(self.out), "--repeat", "2", *args],
            env=env, capture_output=True, text=True, timeout=60,
        )

    def assert_restored(self) -> None:
        for path, content in self.originals.items():
            self.assertEqual(path.read_bytes(), content, path)

    def test_leaf_and_schema_rows(self) -> None:
        result = self.run_script("--leaf-edit", "--schema-edit", "--label", "before 025/027")
        self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
        self.assert_restored()
        report = json.loads(self.out.read_text())
        self.assertEqual(report["sha"], "0123456789abcdef0123")
        self.assertEqual(report["layout"], "before-025/027")
        self.assertEqual(report["jobs"], 4)
        self.assertEqual([row["edit"] for row in report["rows"]], ["leaf", "schema"])
        leaf, schema = report["rows"]
        self.assertEqual(len(leaf["samples"]), 2)
        self.assertEqual(leaf["targets"], ["CmuxNextDaemon"])
        self.assertEqual(schema["command"], "send")
        self.assertEqual(schema["target_count"], 1)
        self.assertTrue(report["verdict"]["passed"])
        self.assertIn("| leaf (swift) | before-025/027 |", result.stdout)
        self.assertIn("0123456789ab", result.stdout)
        calls = self.calls.read_text().splitlines()
        builds = [c for c in calls if c.startswith("build ")]
        # warm, noop, 2 leaf, leaf restore, 2 schema, schema restore.
        self.assertEqual(len(builds), 8)
        self.assertTrue(all("--jobs 4" in c and "--target CmuxNextApp" in c for c in builds))

    def test_leaf_that_reruns_generator_fails(self) -> None:
        result = self.run_script("--leaf-edit", FAKE_SWIFT_GENERATOR="1")
        self.assertEqual(result.returncode, bt.EXIT_BUDGET)
        self.assertIn("reran the wire generator", result.stderr)
        self.assert_restored()

    def test_leaf_over_budget_fails(self) -> None:
        result = self.run_script("--leaf-edit", "--max-leaf-seconds", "0")
        self.assertEqual(result.returncode, bt.EXIT_BUDGET)
        self.assertIn("is not under 0.0 s", result.stderr)
        self.assert_restored()

    def test_build_failure_restores_files(self) -> None:
        result = self.run_script("--leaf-edit", "--schema-edit", FAKE_SWIFT_FAIL="1")
        self.assertEqual(result.returncode, bt.EXIT_BUILD)
        self.assertIn("error: boom", result.stderr)
        self.assert_restored()

    def test_refuses_outside_a_fleet_step(self) -> None:
        env = dict(self.env)
        del env["CMUX_CI_STEP_KEY"]
        result = subprocess.run(
            ["bash", str(SCRIPT), "--leaf-edit"], env=env, capture_output=True, text=True, timeout=60,
        )
        self.assertEqual(result.returncode, bt.EXIT_USAGE)
        self.assertIn("fleet step", result.stderr)
        self.assertFalse(self.calls.exists())

    def test_needs_an_edit(self) -> None:
        result = self.run_script()
        self.assertEqual(result.returncode, 2)
        self.assertIn("--leaf-edit", result.stderr)


if __name__ == "__main__":
    unittest.main()
