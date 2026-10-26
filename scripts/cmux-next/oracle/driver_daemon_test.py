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
import dataclasses
import itertools
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
# Until normalize.py loads the default schema (SchemaTests), the live tests can name one it loads.
SNAPSHOT_SCHEMA = os.environ.get("CMUX_ORACLE_SNAPSHOT_SCHEMA", "")
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

    def test_each_case_has_its_own_session_and_install_directory(self):
        a, b = d.CasePaths(Path("/tmp/o/aaaaaa/000001")), d.CasePaths(Path("/tmp/o/aaaaaa/000002"))
        self.assertNotEqual(a.session, b.session)
        self.assertNotEqual(a.install_dir, b.install_dir)
        self.assertTrue(a.session.startswith(d.SESSION_NAME + "-"))
        self.assertEqual(a.install_dir.parent, Path(f"/tmp/cmux-th-{os.geteuid()}"))
        # Room for a host's `<32 hex terminal id>.sock` within the limit.
        self.assertLessEqual(len(os.fsencode(str(a.install_dir / ("0" * 32 + ".sock")))), d.SOCKET_LIMIT)

    def test_stable_token_is_cmux_tuis_fnv1a(self):
        # codec.rs stable_token: FNV-1a 64; these are the published FNV-1a 64 values.
        self.assertEqual(d.stable_token(""), "cbf29ce484222325")
        self.assertEqual(d.stable_token("a"), "af63dc4c8601ec8c")

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

    def test_session_isolation_takes_the_run_description_without_a_probe(self):
        netns = d.hermetic_env.Isolation("netns", ("/usr/bin/unshare", "-rn"), "resolved by oracle.py", 1001, 1002)
        self.assertEqual(d.session_isolation(netns.describe()), netns)
        self.assertEqual(d.session_isolation("none"), d.hermetic_env.NO_ISOLATION_REQUESTED)
        with self.assertRaises(d.hermetic_env.HermeticError):
            d.session_isolation({"kind": "chroot"})

    def test_socket_paths_reads_each_process_namespace_table(self):
        """A listening socket of this process is found through /proc/<pid>/net/unix, not the driver's
        /proc/net/unix (a case under the netns prefix has its own table)."""
        if not sys.platform.startswith("linux"):
            self.skipTest("Linux /proc")
        with tempfile.TemporaryDirectory(dir="/tmp") as tmp:
            path = os.path.join(tmp, "l.sock")
            listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            self.addCleanup(listener.close)
            listener.bind(path)
            listener.listen(1)
            me = d.CaseProcess(os.getpid(), os.getppid(), "0", ("python3",))
            self.assertIn(path, d.socket_paths([me]))
            gone = d.CaseProcess(2**22 + 7, 1, "0", ("gone",))
            self.assertIn(path, d.socket_paths([gone, me]))


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
    def spawn_parent(self, marker: str) -> "tuple[subprocess.Popen, int]":
        """A marked parent with one child that runs under `env -i` (no marker), like a daemon's hook or git
        child; returns the parent and the child's pid."""
        script = ("import subprocess, sys, time; "
                  "p = subprocess.Popen(['/usr/bin/env', '-i', '/bin/sleep', '60'], start_new_session=True); "
                  "print(p.pid, flush=True); time.sleep(60)")
        parent = subprocess.Popen([sys.executable, "-c", script, "--socket", "/tmp/x.sock"], stdout=subprocess.PIPE,
                                  env={"PATH": "/usr/bin:/bin", d.MARKER_ENV: marker}, start_new_session=True)
        return parent, int(parent.stdout.readline())

    @unittest.skipUnless(sys.platform.startswith("linux"), "reads /proc")
    def test_the_tree_has_every_descendant_marked_or_not(self):
        marker = f"/tmp/o/test{os.getpid()}"
        parent, child = self.spawn_parent(marker)
        try:
            # The child has exec'd sleep once its environment is empty: then it is the process to find.
            deadline = time.monotonic() + 10
            while Path(f"/proc/{child}/cmdline").read_bytes() != b"/bin/sleep\x0060\x00" \
                    and time.monotonic() < deadline:
                time.sleep(0.02)  # test only: env needs a moment to exec sleep
            kids = d.descendants(parent.pid, marker)
            self.assertEqual([p.pid for p in kids], [child], kids)
            self.assertNotIn(f"{d.MARKER_ENV}={marker}".encode(), Path(f"/proc/{child}/environ").read_bytes())
            self.assertEqual(d.still_running(kids), kids)
            # A pid with another start time is another process.
            self.assertEqual(d.still_running([dataclasses.replace(kids[0], start="1")]), [])
            self.assertIn("/tmp/x.sock", d.socket_paths(d.descendants(os.getpid(), marker)))
            self.assertEqual(d.wait_for_exits([parent.pid], 0.05), {parent.pid})
            self.assertEqual({p.pid for p in d.scan_markers()[marker]}, {parent.pid})
            os.kill(child, signal.SIGKILL)
            os.kill(parent.pid, signal.SIGKILL)
            parent.wait()
            self.assertEqual(d.wait_for_exits([parent.pid, child], 5), set())
            self.assertEqual(d.still_running(kids), [])
            self.assertNotIn(marker, d.scan_markers())
        finally:
            for pid in (child, parent.pid):
                try:
                    os.kill(pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
            parent.wait()
            parent.stdout.close()

    @unittest.skipUnless(sys.platform.startswith("linux"), "PR_SET_CHILD_SUBREAPER is Linux only")
    def test_a_worker_keeps_the_orphans_of_its_case_in_its_tree(self):
        """The parent exits and leaves its env -i child: the worker, a subreaper, adopts it and still finds it."""
        helper = r"""
import json, os, subprocess, sys
sys.path.insert(0, sys.argv[1])
import driver_daemon as d
d.become_subreaper()
script = ("import subprocess; p = subprocess.Popen(['/usr/bin/env', '-i', '/bin/sleep', '60'], "
          "start_new_session=True); print(p.pid, flush=True)")
parent = subprocess.Popen([sys.executable, "-c", script], stdout=subprocess.PIPE,
                          env={"PATH": "/usr/bin:/bin", d.MARKER_ENV: sys.argv[2]})
orphan = int(parent.stdout.readline())
parent.wait()
tree = d.descendants(os.getpid(), sys.argv[2])
print(json.dumps({"orphan": orphan, "me": os.getpid(), "tree": [[p.pid, p.ppid] for p in tree]}))
left = d.end_processes(tree, 5)
d.reap_orphans(None)
print(json.dumps({"left": sorted(left), "after": [p.pid for p in d.descendants(os.getpid(), sys.argv[2])]}))
"""
        out = subprocess.run([sys.executable, "-I", "-c", helper, str(HERE), f"/tmp/o/test{os.getpid()}"],
                             check=True, stdout=subprocess.PIPE, timeout=30).stdout.splitlines()
        found, ended = json.loads(out[0]), json.loads(out[1])
        self.assertIn([found["orphan"], found["me"]], found["tree"])
        self.assertEqual(ended, {"left": [], "after": []})

    def test_a_dead_socket_file_is_debt_and_a_listening_one_fails(self):
        paths = d.CasePaths(Path(f"/tmp/o/test{os.getpid()}/proof"))
        shutil.rmtree(paths.root, ignore_errors=True)
        paths.create()
        paths.install_dir.mkdir(parents=True, exist_ok=True)
        listener = socket.socket(socket.AF_UNIX)
        listener.bind(str(paths.root / "live.sock"))
        listener.listen(1)
        for path in (paths.root / "bh-0" / "dead.sock", paths.install_dir / "host.sock"):
            path.parent.mkdir(exist_ok=True)
            dead = socket.socket(socket.AF_UNIX)
            dead.bind(str(path))
            dead.close()  # the file stays; nothing listens on it

        def no_scan():
            raise AssertionError("a finished worker proved its own tree: no process-table scan")

        try:
            proof = d.prove_clean(paths, [], True, no_scan, 5)
            self.assertEqual(len(proof.problems), 1, proof.problems)
            self.assertIn("still listening", proof.problems[0])
            self.assertIn("live.sock", proof.problems[0])
            self.assertEqual(len(proof.debt), 1, proof.debt)
            self.assertIn("dead.sock", proof.debt[0])
            self.assertIn(str(paths.install_dir / "host.sock"), proof.debt[0])
            self.assertFalse(proof.dirty)
            self.assertFalse(paths.root.exists())
            self.assertFalse(paths.install_dir.exists())
        finally:
            listener.close()
            shutil.rmtree(paths.root.parent, ignore_errors=True)
            shutil.rmtree(paths.install_dir, ignore_errors=True)

    def test_a_worker_that_did_not_finish_is_proved_by_one_scan(self):
        paths = d.CasePaths(Path(f"/tmp/o/test{os.getpid()}/hung"))
        shutil.rmtree(paths.root, ignore_errors=True)
        paths.create()
        env = {"PATH": "/usr/bin:/bin", d.MARKER_ENV: str(paths.root)}
        orphan = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(60)"], env=env,
                                  start_new_session=True)
        scans = []

        def scan():
            scans.append(1)
            return d.scan_markers()

        try:
            proof = d.prove_clean(paths, [], False, scan, 5)
            self.assertEqual(len(scans), 1)
            self.assertTrue(any("did not finish" in p and str(orphan.pid) in p for p in proof.problems),
                            proof.problems)
            self.assertEqual(orphan.wait(5), -signal.SIGKILL)
            self.assertFalse(paths.root.exists())
        finally:
            if orphan.poll() is None:
                orphan.kill()
                orphan.wait()
            shutil.rmtree(paths.root.parent, ignore_errors=True)


class RunBatchTests(unittest.TestCase):
    def test_the_sessions_of_a_run_scan_the_process_table_only_for_a_worker_that_did_not_finish(self):
        """oracle.py opens a session per batch (batch limit 1 for the daemon), so a scan per case would be
        one per case at any --jobs. A worker that finished proved its own tree; only a hung one needs a scan."""
        import oracle  # noqa: PLC0415 - sibling of this file

        scans = []
        lock = threading.Lock()

        def scan():
            with lock:
                scans.append(1)
            return {}

        class StubWorker(d.DaemonSession):
            def __init__(self, session_ctx):  # noqa: D107 - no binary or schema: the worker is stubbed
                self.scan = scan
                self.session_ctx = dict(session_ctx)

            def run_worker(self, case, case_ctx, scale):
                hung = case.get("hung", False)
                status = "Timeout" if hung else "Pass"
                return {"status": status, "message": "", "checkpoints": [], "sockets": []}, not hung

        base = Path(f"/tmp/o/test{os.getpid()}")
        batches = []
        for index in range(8):
            data = {"id": f"c{index}", "suite": "s", "hung": index == 5}
            case = oracle.Case(f"s/c{index}", "s", Path("c.json"), data)
            batches.append((oracle.Work(case, {"case_id": case.id, "state_root": str(base / f"{index:06d}")}),))
        try:
            results, errors, _logs = oracle.run_phase(batches, StubWorker, {"run_id": "batch-test"}, 8,
                                                      itertools.count())
        finally:
            shutil.rmtree(base, ignore_errors=True)
        self.assertEqual(errors, [])
        self.assertEqual(sorted(row[1]["status"] for row in results), ["Pass"] * 7 + ["Timeout"])
        self.assertEqual(len(scans), 1)


class SchemaTests(unittest.TestCase):
    def test_a_session_opens_on_the_default_snapshot_schema(self):
        """oracle.py passes no snapshot_schema, so `oracle.py run --product daemon` needs normalize.py to load
        its own default schema. Red while schemas/oracle/snapshot-v1.schema.json uses keywords normalize.py
        refuses (the p15-oracle-011/013 agreement)."""
        try:
            d.open_session({"binary": sys.executable, "run_id": "schema-test"})
        except ValueError as error:
            self.fail(str(error)[:3000])


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
        extra = {"snapshot_schema": SNAPSHOT_SCHEMA} if SNAPSHOT_SCHEMA else {}
        cls.session = d.open_session({"binary": BINARY, "run_id": cls.run_id, "isolation": ISOLATION, **extra})
        cls.count = 0

    @classmethod
    def tearDownClass(cls):
        d.remove_empty_dir(d.DEFAULT_STATE_BASE / d.short_token(cls.run_id))

    def run_case(self, case: dict) -> dict:
        type(self).count += 1
        root = d.DEFAULT_STATE_BASE / d.short_token(self.run_id) / f"{self.count:06d}"
        result = self.session.run_case(case, {"case_id": f"{case['suite']}/{case['id']}", "state_root": str(root)})
        self.assertNotIn(str(root), d.scan_markers(), "I6: the case left processes")
        self.assertFalse(root.exists(), "the case left its state root")
        self.assertFalse(d.CasePaths(root).install_dir.exists(), "the case left its install directory")
        return result

    def test_case_runs_in_the_session_isolation_and_its_sockets_are_accounted(self):
        """The readiness pipe and the socket round trips work under the isolation prefix, the case runs as
        the caller's uid, and the terminal host's socket (bound in the case's install directory, from inside
        the case's network namespace) is in the worker's `sockets`, so I6 checks it."""
        case = example_case()
        case["steps"] = [s for s in case["steps"] if s["id"] == "create-ws"]
        type(self).count += 1
        paths = d.CasePaths(d.DEFAULT_STATE_BASE / d.short_token(self.run_id) / f"{self.count:06d}")
        paths.check()
        paths.create()
        result, finished = self.session.run_worker(case, {"case_id": "t/isolation", "state_root": str(paths.root)},
                                                   1.0)
        proof = d.prove_clean(paths, result.get("sockets", ()), finished, self.session.scan, d.EXIT_S)
        self.assertEqual(result["status"], "Pass", result["message"])
        self.assertEqual(proof.problems, [])
        isolation = result["environment"]["isolation"]
        if ISOLATION == "netns":
            self.assertEqual(isolation["kind"], "netns")
        self.assertEqual((isolation["uid"], isolation["gid"]), (os.getuid(), os.getgid()))
        install = f"{paths.install_dir}/"
        self.assertTrue(any(path.startswith(install) for path in result["sockets"]), result["sockets"])
        self.assertFalse(paths.install_dir.exists())

    def test_example_case_passes_without_the_virtual_clock_step(self):
        case = example_case()
        case["steps"] = [s for s in case["steps"] if s["op"] != "advance_clock"]
        result = self.run_case(case)
        self.assertEqual(result["status"], "Pass", result["message"])
        last = result["checkpoints"][-1]["snapshot"]["facets"]["daemon"]["session"]
        self.assertEqual(len(last["workspaces"]), 1)
        self.assertEqual(last["session"].get("name", d.SESSION_NAME), d.SESSION_NAME)
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

    def test_killed_daemon_with_no_terminal_leaves_nothing(self):
        """Nothing outlives the daemon, so only the teardown's new daemon removes the killed one's socket."""
        case = example_case()
        case["steps"] = [s for s in case["steps"] if s["id"] == "kill-daemon"]
        result = self.run_case(case)
        self.assertEqual(result["status"], "Pass", result["message"])
        self.assertNotIn("s.sock", " ".join(result.get("daemon_debt", [])))

    def test_terminal_hosts_bind_in_the_case_install_directory(self):
        paths = d.CasePaths(d.DEFAULT_STATE_BASE / d.short_token(self.run_id) / "hosts0")
        paths.create()
        case_env = d.case_environment(paths, "hosts", self.session.isolation).prepare()
        daemon = d.Daemon(BINARY, paths, case_env, 1.0)
        try:
            daemon.start("hosts")
            daemon.request("workspace.create", {**d.SELECTORS, "name": "w", "initial_content": "terminal"},
                           "hosts-1", d.REQUEST_S)
            deadline = time.monotonic() + 10
            while not d.socket_files(paths.install_dir) and time.monotonic() < deadline:
                time.sleep(0.02)  # test only: the host binds after workspace.create replies
            self.assertTrue(d.socket_files(paths.install_dir), f"no host socket in {paths.install_dir}")
            daemon.stop("hosts", end_terminals=True)
        finally:
            daemon.kill(signal.SIGKILL)
            d.prove_clean(paths, [], False, d.scan_markers, 5)

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
