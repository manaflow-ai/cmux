#!/usr/bin/env python3
"""A push of only backup/* refs (saved work, no pull request) skips the gate's code-quality layers and the arch
ratchet, and keeps the workflow checks (scripts/cmux-next/prepush-gate.py, backup_only_push).

2026-11-28: the arch ratchet refused pushes of backup/cmux-cg-composer, backup/cmux-cg-tower and
backup/cmux-tp-mutedtokens.noindex over code-quality rows, so old work could not be saved before its folder went.
"""
import importlib.util
import io
import sys
import tempfile
import unittest
import unittest.mock
from pathlib import Path

SOURCE = Path(__file__).resolve().parents[1]
SHA = "a" * 40
ZERO = "0" * 40


def load_gate():
    spec = importlib.util.spec_from_file_location("cmux_next_prepush_gate_backup", SOURCE / "scripts/cmux-next/prepush-gate.py")
    gate = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = gate
    spec.loader.exec_module(gate)
    return gate


gate = load_gate()


def line(ref: str, sha: str = SHA) -> str:
    return f"refs/heads/x {sha} {ref} {ZERO}"


class BackupOnlyPush(unittest.TestCase):
    def test_backup_refs_only(self):
        self.assertTrue(gate.backup_only_push([line("refs/heads/backup/cmux-cg-composer")]))
        self.assertTrue(gate.backup_only_push([line("refs/heads/backup/cmux-cg-tower"),
                                               line("refs/heads/backup/cmux-cg-tower--lane-x"), ""]))

    def test_wip_net_backup_refs(self):
        # 2026-11-28: the arch ratchet held lane/cold-activation-865-next-wip 12 h; the WIP net
        # saves a refused checkout as lane/backup/<branch>-<host>-wip, which a lane VM's broker takes
        self.assertTrue(gate.backup_only_push([line("refs/heads/lane/backup/cold-activation-865-next-lane-vm-wip")]))
        self.assertTrue(gate.backup_only_push([line("refs/heads/lane/backup/x-wip"), line("refs/heads/backup/y")]))
        self.assertFalse(gate.backup_only_push([line("refs/heads/lane/backup/x-wip"), line("refs/heads/lane/x-wip")]))

    def test_any_other_ref_keeps_every_layer(self):
        self.assertFalse(gate.backup_only_push([line("refs/heads/backup/a"), line("refs/heads/lane/a")]))
        self.assertFalse(gate.backup_only_push([line("refs/heads/feat-cmux-next")]))
        self.assertFalse(gate.backup_only_push([line("refs/heads/lane/x-wip")]))  # checkpoints get draft PRs
        self.assertFalse(gate.backup_only_push([line("refs/heads/lane/backup/x")]))  # a lane/ ref without -wip
        self.assertFalse(gate.backup_only_push([line("refs/heads/lane/backup/-wip")]))
        self.assertFalse(gate.backup_only_push([line("refs/heads/lane/backup-x-wip")]))
        self.assertFalse(gate.backup_only_push([line("refs/tags/backup/x")]))
        self.assertFalse(gate.backup_only_push([line("refs/heads/backup/")]))

    def test_unreadable_or_empty_keeps_every_layer(self):
        self.assertFalse(gate.backup_only_push([]))
        self.assertFalse(gate.backup_only_push(["garbage"]))
        self.assertFalse(gate.backup_only_push([line("refs/heads/backup/a", ZERO)]))  # a delete: no commits


class MainSkipsCodeQuality(unittest.TestCase):
    def run_main(self, ref: str):
        calls = {"only": [], "guardrails": 0, "trailer": 0}

        def gate_own(repo, own, only, *args, **kwargs):
            calls["only"].append(only)
            return []

        def start_guardrails(*args, **kwargs):
            calls["guardrails"] += 1
            return (None, None)

        def compile_trailer(*args, **kwargs):
            calls["trailer"] += 1
            return False

        push_range = unittest.mock.Mock()
        push_range.pushed_ranges.return_value = ([unittest.mock.Mock(describe=lambda: "r")], [])
        with tempfile.TemporaryDirectory() as tmp, \
                unittest.mock.patch.object(gate, "claim_trusted_scripts", lambda d: (d, None)), \
                unittest.mock.patch.object(gate, "load_push_range", lambda *a: push_range), \
                unittest.mock.patch.object(gate, "gate_own", gate_own), \
                unittest.mock.patch.object(gate, "start_guardrails", start_guardrails), \
                unittest.mock.patch.object(gate, "guardrails", lambda *a: False), \
                unittest.mock.patch.object(gate, "compile_trailer", compile_trailer), \
                unittest.mock.patch.object(gate, "compile_ranges", lambda *a: []), \
                unittest.mock.patch.object(gate, "perf_cron_tests", lambda *a: None), \
                unittest.mock.patch.object(gate, "stale_hook_warning", lambda *a: None), \
                unittest.mock.patch.object(gate, "advisory_finish", lambda *a: None), \
                unittest.mock.patch.dict("os.environ", {"GITHUB_ACTIONS": ""}), \
                unittest.mock.patch("sys.stdin", io.StringIO(line(ref) + "\n")), \
                unittest.mock.patch("sys.stdout", io.StringIO()), \
                unittest.mock.patch("sys.stderr", io.StringIO()):
            code = gate._main(["--repo", tmp, "--pre-push", "--trusted-scripts-dir", tmp])
        return code, calls

    def test_backup_push_runs_only_the_workflow_layers(self):
        code, calls = self.run_main("refs/heads/backup/cmux-cg-composer")
        self.assertEqual(code, 0)
        self.assertEqual(calls["only"], [set(gate.BACKUP_PUSH_LAYERS)])
        self.assertEqual(calls["guardrails"], 0, "the arch ratchet runs inside the guardrails")
        self.assertEqual(calls["trailer"], 0)
        self.assertEqual(gate.BACKUP_PUSH_LAYERS, {"workflows", "job-bounds", "reusable-perms"})

    def test_wip_net_backup_runs_only_the_workflow_layers(self):
        code, calls = self.run_main("refs/heads/lane/backup/x-lane-vm-wip")
        self.assertEqual(code, 0)
        self.assertEqual(calls["only"], [set(gate.BACKUP_PUSH_LAYERS)])
        self.assertEqual(calls["guardrails"], 0)
        self.assertEqual(calls["trailer"], 0)

    def test_lane_push_runs_every_layer(self):
        code, calls = self.run_main("refs/heads/lane/x")
        self.assertEqual(code, 0)
        self.assertEqual(calls["only"], [None])
        self.assertEqual(calls["guardrails"], 1)
        self.assertEqual(calls["trailer"], 1)


if __name__ == "__main__":
    unittest.main()
