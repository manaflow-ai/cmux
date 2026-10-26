#!/usr/bin/env python3
"""Tests for driver_daemon.py.

Run: python3 -I scripts/cmux-next/oracle/driver_daemon_test.py (stdlib unittest; selftest.py, task 019,
runs it too). The unit tests need nothing. The live tests start real daemons and run when
CMUX_ORACLE_DAEMON_BINARY names a cmux-tui (`linux_run.sh build` prints one; a debug build works too):
they drive cases with kill, restart, waitFor, readOnly and typed-error steps and check the I6 teardown.
Linux or a fleet Mac only, never the person's Mac.
"""

from __future__ import annotations

import copy
import json
import os
import shutil
import signal
import socket
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

import driver_daemon as d  # noqa: E402

BINARY = os.environ.get("CMUX_ORACLE_DAEMON_BINARY", "")
# netns (unshare -rn, the default) or none on a host that refuses unprivileged user namespaces.
ISOLATION = os.environ.get("CMUX_ORACLE_ISOLATION", "netns")
EXAMPLE = HERE.parents[2] / "schemas" / "oracle" / "fixtures" / "case-example-daemon.json"


class PathTests(unittest.TestCase):
    def test_state_root_is_two_short_tokens_under_tmp_o(self):
        paths = d.CasePaths.for_case(None, "20261026T120000Z-abcdef", "17")
        parts = paths.root.relative_to("/tmp/o").parts
        self.assertEqual(len(parts), 2)
        self.assertTrue(all(len(part) == 6 for part in parts), parts)
        self.assertLessEqual(len(os.fsencode(str(paths.socket))), d.SOCKET_LIMIT)

    def test_oracle_state_root_wins(self):
        paths = d.CasePaths.for_case("/tmp/o/aaaaaa/1", "run", "1")
        self.assertEqual(paths.socket, Path("/tmp/o/aaaaaa/1/s.sock"))

    def test_long_socket_path_is_refused_before_anything_starts(self):
        paths = d.CasePaths(Path("/tmp/" + "x" * 100))
        with self.assertRaises(d.CaseError) as caught:
            paths.check()
        self.assertIn("over 100", caught.exception.message)

    def test_non_empty_root_belongs_to_another_case(self):
        with tempfile.TemporaryDirectory(dir="/tmp") as root:
            Path(root, "left").write_text("x")
            with self.assertRaises(d.CaseError):
                d.CasePaths(Path(root)).create()

    def test_environment_is_built_from_nothing(self):
        paths = d.CasePaths(Path("/tmp/o/aaaaaa/bbbbbb"))
        env = d.case_environment(paths, "seed-1", d.hermetic_env.NO_ISOLATION_REQUESTED).env
        self.assertEqual(env[d.MARKER_ENV], "/tmp/o/aaaaaa/bbbbbb")
        self.assertEqual(env["CMUX_TUI_SOCKET"], "/tmp/o/aaaaaa/bbbbbb/s.sock")
        self.assertTrue(all(value.startswith("/tmp/o/aaaaaa/bbbbbb") for key, value in env.items()
                            if key in ("HOME", "TMPDIR", "XDG_RUNTIME_DIR", "CMUX_TUI_STATE_DIR")))
        self.assertNotIn("SSH_AUTH_SOCK", env)
        self.assertEqual(env["TZ"], "UTC")
        self.assertEqual(env["CMUX_TUI_OFFLINE"], "1")

    def test_run_directory_lists_the_environment(self):
        with tempfile.TemporaryDirectory(dir="/tmp") as out:
            d.write_environment(Path(out), d.hermetic_env.NO_ISOLATION_REQUESTED)
            receipt = json.loads(Path(out, "environment.json").read_text())
        self.assertEqual(receipt["env"]["HOME"], "$CASE_ROOT/home")
        self.assertEqual(receipt["env"][d.MARKER_ENV], "$CASE_ROOT")
        self.assertEqual(receipt["isolation"]["kind"], "none")


class PointerTests(unittest.TestCase):
    def test_resolve(self):
        doc = {"a": [{"b/c": 1, "d~e": 2}], "0": "zero"}
        self.assertEqual(d.resolve_pointer(doc, "/a/0/b~1c"), 1)
        self.assertEqual(d.resolve_pointer(doc, "/a/0/d~0e"), 2)
        self.assertEqual(d.resolve_pointer(doc, "/0"), "zero")
        self.assertIs(d.resolve_pointer(doc, "/a/01"), d.MISSING)
        self.assertIs(d.resolve_pointer(doc, "/a/1"), d.MISSING)
        self.assertEqual(d.resolve_pointer(doc, ""), doc)

    def test_step_refs_resolve_from_earlier_replies(self):
        replies = {"create-ws": {"value": {"workspace_id": "ws_" + "a" * 32}}}
        target = {"workspace": "$step:create-ws#/value/workspace_id", "session": "fixture"}
        self.assertEqual(d.resolve_refs(target, replies)["workspace"], "ws_" + "a" * 32)
        with self.assertRaises(d.CaseError):
            d.resolve_refs("$step:create-ws#/value/pane_id", replies)
        with self.assertRaises(d.CaseError):
            d.resolve_refs("$step:later#/value", replies)


class PredicateTests(unittest.TestCase):
    def check(self, wait, value, baseline=d.MISSING):
        return d.predicate_holds(wait, value, baseline)

    def test_equals_and_named_predicates(self):
        self.assertTrue(self.check({"equals": [1]}, [1]))
        self.assertFalse(self.check({"equals": None}, d.MISSING))
        self.assertTrue(self.check({"predicate": "exists"}, 0))
        self.assertTrue(self.check({"predicate": "absent"}, d.MISSING))
        self.assertTrue(self.check({"predicate": "empty"}, []))
        self.assertTrue(self.check({"predicate": "nonEmpty"}, "x"))
        self.assertFalse(self.check({"predicate": "nonEmpty"}, d.MISSING))
        self.assertTrue(self.check({"predicate": "changed"}, 2, 1))
        self.assertFalse(self.check({"predicate": "changed"}, 1, 1))

    def test_operator_predicates(self):
        self.assertTrue(self.check({"predicate": {"op": "lengthEquals", "value": 2}}, [1, 2]))
        self.assertTrue(self.check({"predicate": {"op": "gte", "value": 2}}, 2))
        self.assertFalse(self.check({"predicate": {"op": "gt", "value": 2}}, True))
        self.assertTrue(self.check({"predicate": {"op": "contains", "value": "b"}}, ["a", "b"]))
        self.assertTrue(self.check({"predicate": {"op": "contains", "value": "ell"}}, "hello"))
        self.assertFalse(self.check({"predicate": {"op": "lt", "value": 1}}, d.MISSING))


class SelectorTests(unittest.TestCase):
    SPEC = {"params": {"selectors": {"machine": "required", "session": "required", "workspace": "required"}}}

    def test_fixture_handles_names_and_ids(self):
        ws = "ws_" + "b" * 32
        self.assertEqual(d.selector_params(self.SPEC, {"machine": "local", "session": "fixture", "workspace": ws},
                                           "workspace.rename"),
                         {"machine": "current", "session": "current", "workspace": ws})
        self.assertEqual(d.selector_params(self.SPEC, {"workspace": "missing-workspace"}, "workspace.rename"),
                         {"machine": "current", "session": "current", "workspace": "name:missing-workspace"})

    def test_unknown_selector_is_a_case_error(self):
        with self.assertRaises(d.CaseError):
            d.selector_params(self.SPEC, {"pane": "p"}, "workspace.rename")


class CrashScopeTests(unittest.TestCase):
    def test_allowed_kill(self):
        entries = [{"kind": "daemon", "reason": "on purpose", "steps": ["kill"]}]
        self.assertIsNone(d.crash_allowed(entries, [d.DaemonExit("kill", "daemon", "SIGKILL", None)]))

    def test_exit_outside_the_listed_steps(self):
        entries = [{"kind": "daemon", "reason": "on purpose", "steps": ["kill"]}]
        refusal = d.crash_allowed(entries, [d.DaemonExit("other", "daemon", "exit 101", 101)])
        self.assertIn("other", refusal)

    def test_more_exits_than_max(self):
        entries = [{"kind": "daemon", "reason": "on purpose"}]
        exits = [d.DaemonExit("a", "daemon", "x", None), d.DaemonExit("b", "daemon", "x", None)]
        self.assertIn("allows 1", d.crash_allowed(entries, exits))


class ProcessTests(unittest.TestCase):
    def test_tree_running_and_scan_find_a_marked_process_then_its_exit(self):
        marker = f"/tmp/o/test{os.getpid()}"
        env = {"PATH": "/usr/bin:/bin", d.MARKER_ENV: marker}
        # A parent with one child, both marked, like a daemon and its holder.
        script = "import subprocess, sys, time; subprocess.Popen([sys.executable, '-c', 'import time; time.sleep(60)']); time.sleep(60)"
        child = subprocess.Popen([sys.executable, "-c", script, "--socket", "/tmp/x.sock"], env=env,
                                 start_new_session=True)
        try:
            deadline = time.monotonic() + 10
            while len(d.process_tree(child.pid, marker)) < 2 and time.monotonic() < deadline:
                time.sleep(0.02)  # test only: the grandchild needs a moment to exist
            tree = d.process_tree(child.pid, marker)
            self.assertEqual(len(tree), 2, tree)
            self.assertEqual({p.pid for p in d.scan_markers()[marker]}, {p.pid for p in tree})
            self.assertIn("/tmp/x.sock", d.socket_paths([p for p in tree if p.pid == child.pid]))
            self.assertEqual(d.process_tree(child.pid, "/tmp/o/other"), [])
            self.assertEqual(d.wait_for_exits([child.pid], 0.05), {child.pid})
            for proc in tree:
                os.kill(proc.pid, signal.SIGKILL)
            child.wait()
            self.assertEqual(d.wait_for_exits([p.pid for p in tree], 5), set())
            self.assertEqual(d.still_running(tree, marker), [])
            self.assertNotIn(marker, d.scan_markers())
        finally:
            if child.poll() is None:
                child.kill()
                child.wait()

    def test_proof_reports_kills_and_removes_what_a_case_left(self):
        paths = d.CasePaths(Path(f"/tmp/o/test{os.getpid()}/proof"))
        shutil.rmtree(paths.root, ignore_errors=True)
        paths.create()
        listener = socket.socket(socket.AF_UNIX)
        listener.bind(str(paths.root / "left.sock"))
        env = {"PATH": "/usr/bin:/bin", d.MARKER_ENV: str(paths.root)}
        orphan = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(60)"], env=env,
                                  start_new_session=True)
        try:
            problems, dirty = d.prove_clean(paths, [], d.MarkerScan(), 5)
            self.assertFalse(dirty)
            self.assertTrue(any("processes left" in p and str(orphan.pid) in p for p in problems), problems)
            self.assertTrue(any("sockets left" in p and "left.sock" in p for p in problems), problems)
            self.assertEqual(orphan.wait(5), -signal.SIGKILL)
            self.assertFalse(paths.root.exists())
        finally:
            listener.close()
            if orphan.poll() is None:
                orphan.kill()
                orphan.wait()
            shutil.rmtree(paths.root.parent, ignore_errors=True)

    def test_cases_that_ask_together_share_one_scan(self):
        started = threading.Event()
        release = threading.Event()
        calls = []

        def scan():
            calls.append(1)
            started.set()
            release.wait(5)
            return {"/tmp/o/a/1": []}

        joined = d.MarkerScan(scan)
        first = threading.Thread(target=joined.find, args=("/tmp/o/a/1",))
        first.start()
        started.wait(5)
        # These ask while the first scan runs: they need a scan that starts after they asked, one for all.
        waiters = [threading.Thread(target=joined.find, args=("/tmp/o/a/1",)) for _ in range(20)]
        for waiter in waiters:
            waiter.start()
        deadline = time.monotonic() + 10
        # CPython's Condition keeps its waiters in _waiters: all 20 wait before the first scan ends.
        while len(joined._changed._waiters) < len(waiters) and time.monotonic() < deadline:
            time.sleep(0.01)
        release.set()
        for thread in [first, *waiters]:
            thread.join(10)
        self.assertEqual(len(calls), 2)


def example_case() -> dict:
    """The schema's daemon example with the expectations of a headless daemon: it starts with no
    workspace, so one workspace is restored after the restart."""
    case = json.loads(EXAMPLE.read_text(encoding="utf-8"))
    for step in case["steps"]:
        if step["id"] == "restart-daemon":
            step["waitFor"]["predicate"]["value"] = 1
    return case


@unittest.skipUnless(BINARY, "CMUX_ORACLE_DAEMON_BINARY names no cmux-tui")
class LiveTests(unittest.TestCase):
    """Real daemons; each case must leave nothing behind (I6)."""

    @classmethod
    def setUpClass(cls):
        cls.run_id = f"driver-test-{os.getpid()}-{time.time_ns()}"
        cls.session = d.open_session({"binary": BINARY, "run_id": cls.run_id, "isolation": ISOLATION})
        cls.count = 0

    def run_case(self, case: dict) -> dict:
        type(self).count += 1
        root = d.DEFAULT_STATE_BASE / d.short_token(self.run_id) / f"{self.count:06d}"
        result = self.session.run_case(case, {"case_id": f"{case['suite']}/{case['id']}", "state_root": str(root)})
        self.assertNotIn(str(root), d.scan_markers(), "I6: the case left processes")
        self.assertFalse(root.exists(), "the case left its state root")
        return result

    def test_example_case_passes_without_the_virtual_clock_step(self):
        case = example_case()
        case["steps"] = [s for s in case["steps"] if s["op"] != "advance_clock"]
        result = self.run_case(case)
        self.assertEqual(result["status"], "Pass", result["message"])
        last = result["checkpoints"][-1]["snapshot"]["facets"]["daemon"]["session"]
        self.assertEqual(len(last["workspaces"]), 1)
        self.assertEqual(result["checkpoints"][-1]["snapshot"]["facets"]["crashes"]["status"], "not-comparable")

    def test_two_runs_give_equal_canonical_layouts(self):
        """The layout sections relabel to equal values across two daemons. Not the whole facet yet: the
        open `extra` objects still hold the per-root machine id and wall-clock output times, which the
        virtual clock and seeded ids (p15-oracle-185) and their schema rules make comparable."""
        case = example_case()
        case["steps"] = [s for s in case["steps"] if s["op"] not in ("advance_clock", "kill", "restart")]
        first, second = self.run_case(copy.deepcopy(case)), self.run_case(copy.deepcopy(case))
        self.assertEqual(first["status"], "Pass", first["message"])
        self.assertEqual(second["status"], "Pass", second["message"])

        def layouts(result):
            return [{key: cp["snapshot"]["facets"]["daemon"]["session"][key]
                     for key in ("workspaces", "screens", "panes", "tabs")} for cp in result["checkpoints"]]

        self.assertEqual(json.dumps(layouts(first), sort_keys=True), json.dumps(layouts(second), sort_keys=True))

    def test_killed_daemon_terminals_are_ended_at_teardown(self):
        case = example_case()
        case["steps"] = [s for s in case["steps"] if s["id"] in ("create-ws", "kill-daemon")]
        result = self.run_case(case)
        self.assertEqual(result["status"], "Pass", result["message"])

    def test_kill_outside_allow_crashes_is_a_crash(self):
        case = example_case()
        case["steps"] = [s for s in case["steps"] if s["id"] in ("create-ws", "kill-daemon")]
        case["allow_crashes"] = []
        result = self.run_case(case)
        self.assertEqual((result["status"], result["step"]), ("Crash", "kill-daemon"))

    def test_wrong_typed_error_is_a_failure(self):
        case = example_case()
        case["steps"] = [s for s in case["steps"] if s["id"] == "rename-missing"]
        case["steps"][0]["expect"]["error"] = "validation.invalid"
        result = self.run_case(case)
        self.assertEqual((result["status"], result["step"]), ("Failure", "rename-missing"))
        self.assertIn("selector.not_found", result["message"])

    def test_wait_for_that_never_holds_is_a_timeout(self):
        case = example_case()
        case["steps"] = [s for s in case["steps"] if s["id"] in ("create-ws", "kill-daemon", "restart-daemon")]
        case["steps"][2]["waitFor"] = {"pointer": "/daemon/session/workspaces",
                                      "predicate": {"op": "lengthEquals", "value": 5}, "maxMs": 300}
        result = self.run_case(case)
        self.assertEqual((result["status"], result["step"]), ("Timeout", "restart-daemon"))

    def test_daemon_ops_outside_this_driver_are_refused(self):
        case = example_case()
        case["steps"] = [{"id": "cli", "op": "cli", "target": {"session": "fixture"}, "args": {"argv": ["ls"]},
                          "expect": {"outcome": "ok"}}]
        result = self.run_case(case)
        self.assertEqual(result["status"], "Crash")
        self.assertIn("driver_cli.py", result["message"])


if __name__ == "__main__":
    unittest.main(verbosity=1)
