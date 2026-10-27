#!/usr/bin/env python3
"""stories/incremental_build.py: leaf edits and restores, rebuild-only timing, the rebuilt-module list, the MQ15
queue, lab-host refusal and the result-v1 it writes, on a fixture git tree with a fake builder.

  python3 -m unittest scripts/perf-lab/tests/test_incremental_build.py
"""
from __future__ import annotations

import hashlib
import importlib.util
import io
import json
import os
import re
import signal
import subprocess
import sys
import tempfile
import threading
import unittest
from contextlib import redirect_stdout
from pathlib import Path

HERE = Path(__file__).resolve().parent
LAB = HERE.parent
ROOT = LAB.parent.parent

_SPEC = importlib.util.spec_from_file_location("perf_lab_incremental_build_under_test",
                                               LAB / "stories" / "incremental_build.py")
ib = importlib.util.module_from_spec(_SPEC)
sys.modules[_SPEC.name] = ib
_SPEC.loader.exec_module(ib)
perf_result = ib.perf_result


def _load(name: str, path: Path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


queues = _load("perf_lab_queues_under_incremental_build_test", LAB / "queues.py")

FACTS = {"chip": "Apple M4 Pro", "memory_bytes": 48 * 2 ** 30, "macos": "26.1", "macos_build": "25B78"}
LEAVES = (
    ib.Leaf("compat_leaf", ib.SWIFT, "Packages/macOS/CmuxNext/Sources/CmuxNextCompat/Leaf.swift"),
    ib.Leaf("app_handler", ib.SWIFT, "Packages/macOS/CmuxNext/Sources/CmuxNextApp/Handler.swift"),
    ib.Leaf("tui_crate_leaf", ib.CARGO, "cmux-tui/crates/leaf/src/lib.rs"),
)
SWIFT_REBUILD_LOG = """[1/4] Compiling CmuxNextCompat MacName.swift
[2/4] Emitting module CmuxNextCompat
[3/4] Compiling CmuxNextApp AppearanceHandlers.swift
Queuing Sources/CmuxNextCompat/MacName.swift (initial)
Queuing because of dependencies discovered later: {compile: /tmp/B.o <= Sources/CmuxNextApp/B.swift}
[4/4] Linking CmuxNextApp
Build complete!
"""
CARGO_REBUILD_LOG = """   Compiling cmux-panic-log v0.1.0 (/r/cmux-tui/crates/cmux-panic-log)
   Compiling cmux-tui v0.9.0 (/r/cmux-tui/crates/cmux-tui)
    Finished `dev` profile [unoptimized + debuginfo] target(s) in 4.20s
"""


def warm_log(repo: Path) -> str:
    """Warnings in the text swiftc 6.2 prints for -warn-long-function-bodies=100 (DiagnosticsSema.def
    debug_long_function_body "%kind0 took %1ms to type-check (limit: %2ms)" and debug_long_closure_body), plus an
    expression warning, which only -warn-long-expression-type-checking gives."""
    sources = f"{repo}/Packages/macOS/CmuxNext/Sources"
    return "\n".join([
        f"{sources}/CmuxNextApp/Big.swift:10:10: warning: instance method 'render()' took 450ms to type-check "
        "(limit: 100ms)",
        f"{sources}/CmuxNextApp/Big.swift:40:9: warning: getter for property 'layout' took 120ms to type-check "
        "(limit: 100ms)",
        f"{sources}/CmuxNextSidebar/Row.swift:7:3: warning: initializer 'init(model:)' took 450ms to type-check "
        "(limit: 100ms)",
        # the same body reported twice (two jobs): the larger time stays
        f"{sources}/CmuxNextSidebar/Row.swift:7:3: warning: initializer 'init(model:)' took 300ms to type-check "
        "(limit: 100ms)",
        # exactly the limit: the compiler warns at elapsed >= limit, so it is in the queue
        f"\x1b[1m{sources}/CmuxNextApp/Small.swift:3:6: warning: global function 'fast()' took 100ms to type-check "
        "(limit: 100ms)\x1b[0m",
        f"{sources}/CmuxNextApp/Closures.swift:12:31: warning: closure took 140ms to type-check (limit: 100ms)",
        f"{sources}/CmuxNextApp/Expr.swift:9:9: warning: expression took 900ms to type-check (limit: 100ms)",
        "/Users/x/.build/checkouts/sentry/Sources/S.swift:1:13: warning: static method 'dep()' took 999ms to "
        "type-check (limit: 100ms)",
        "Packages/macOS/CmuxNext/Sources/CmuxNextApp/Relative.swift:2:7: warning: instance method 'rel()' took "
        "101ms to type-check (limit: 100ms)",
    ]) + "\n"


QUEUE_FILES = ["Packages/macOS/CmuxNext/Sources/CmuxNextApp/Big.swift",
               "Packages/macOS/CmuxNext/Sources/CmuxNextSidebar/Row.swift",
               "Packages/macOS/CmuxNext/Sources/CmuxNextApp/Closures.swift",
               "Packages/macOS/CmuxNext/Sources/CmuxNextApp/Relative.swift",
               "Packages/macOS/CmuxNext/Sources/CmuxNextApp/Small.swift"]


def alive(pid: int) -> bool:
    """A process that still runs (a zombie waiting for its parent to reap it runs no code)."""
    state = subprocess.run(["ps", "-o", "stat=", "-p", str(pid)], capture_output=True, text=True).stdout.strip()
    return bool(state) and not state.startswith("Z")


class FakeBuilder:
    """Records each build: its role, the bytes of every leaf while it ran, and the log a real build would write."""

    def __init__(self, repo: Path, directory: Path, fail: frozenset = frozenset(), seconds: float = 7.5) -> None:
        self.repo, self.directory, self.fail, self.seconds = repo, directory, fail, seconds
        self.calls: list[tuple[str, Path, tuple[str, ...], dict[str, bytes]]] = []
        directory.mkdir(parents=True, exist_ok=True)

    def __call__(self, role: str, workdir: Path, command):
        snapshot = {leaf.path: (self.repo / leaf.path).read_bytes() for leaf in LEAVES}
        self.calls.append((role, workdir, tuple(command), snapshot))
        cargo = "cargo" in command
        if role.startswith("warm-"):
            text = "Build complete!\n" if cargo else warm_log(self.repo)
        else:
            text = CARGO_REBUILD_LOG if cargo else SWIFT_REBUILD_LOG
        log = self.directory / f"{role}.log"
        log.write_text(text)
        return ib.Build(role, 1 if role in self.fail else 0, self.seconds, log)


class FixtureRepo:
    def __init__(self) -> None:
        self._dir = tempfile.TemporaryDirectory()
        self.root = Path(self._dir.name) / "repo"
        self.root.mkdir()
        self.git("init", "-q")
        for leaf in LEAVES:
            path = self.root / leaf.path
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text("struct A {}\n" if leaf.kind == ib.SWIFT else "pub fn a() {}")  # the Rust leaf: no EOL
        self.git("add", ".")
        self.git("-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "-m", "fixture")
        self.sha = self.git("rev-parse", "HEAD").strip()

    def git(self, *args: str) -> str:
        return subprocess.run(["git", "-C", str(self.root), *args], capture_output=True, text=True, check=True).stdout

    def bytes(self) -> dict[str, bytes]:
        return {leaf.path: (self.root / leaf.path).read_bytes() for leaf in LEAVES}

    def close(self) -> None:
        self._dir.cleanup()


class IncrementalBuildTest(unittest.TestCase):
    def setUp(self) -> None:
        self.repo = FixtureRepo()
        self.addCleanup(self.repo.close)
        self.pristine = self.repo.bytes()
        self.work = Path(self.repo._dir.name)
        self.builder = FakeBuilder(self.repo.root, self.work / "builds")

    def measure(self, rounds: int = 2, builder=None) -> "ib.Outcome":
        return ib.measure(self.repo.root, LEAVES, rounds, builder or self.builder, self.work / "scratch",
                          self.work / "cargo")

    # ------------------------------------------------------------ edits, restores, timing

    def test_each_timed_rebuild_sees_only_its_own_leaf_edited_and_every_leaf_is_restored(self) -> None:
        outcome = self.measure()
        self.assertEqual(self.repo.bytes(), self.pristine)
        roles = [call[0] for call in self.builder.calls]
        self.assertEqual(roles[:2], ["warm-swift", "warm-cargo"])
        timed = [call for call in self.builder.calls if not call[0].startswith("warm-")
                 and not call[0].endswith("-restored")]
        self.assertEqual([c[0] for c in timed], ["compat_leaf-r0", "app_handler-r0", "tui_crate_leaf-r0",
                                                 "compat_leaf-r1", "app_handler-r1", "tui_crate_leaf-r1"])
        for role, _workdir, _command, snapshot in timed:
            name, round_index = role.rsplit("-r", 1)
            for leaf in LEAVES:
                if leaf.name == name:
                    self.assertNotEqual(snapshot[leaf.path], self.pristine[leaf.path])
                    self.assertTrue(ib.probe_only(snapshot[leaf.path], self.pristine[leaf.path]))
                    self.assertIn(f"probe {round_index}".encode(), snapshot[leaf.path])
                else:
                    self.assertEqual(snapshot[leaf.path], self.pristine[leaf.path], (role, leaf.path))
        # each timed rebuild is followed by an untimed rebuild of the pristine tree
        for index, role in enumerate(roles):
            if role in {c[0] for c in timed}:
                self.assertEqual(roles[index + 1], f"{role}-restored")
                self.assertEqual(self.builder.calls[index + 1][3], self.pristine)
        self.assertTrue(outcome.complete)

    def test_the_samples_are_the_timed_rebuilds_only(self) -> None:
        seconds = iter([600.0, 900.0, 11.0, 50.0, 12.0, 51.0, 3.0, 40.0, 13.0, 52.0, 14.0, 53.0, 4.0, 41.0])

        class Timed(FakeBuilder):
            def __call__(inner, role, workdir, command):
                build = super().__call__(role, workdir, command)
                return ib.Build(build.role, 0, next(seconds), build.log)

        outcome = self.measure(builder=Timed(self.repo.root, self.work / "timed"))
        self.assertEqual([s.seconds for s in outcome.ok_samples("compat_leaf")], [11.0, 13.0])
        self.assertEqual([s.seconds for s in outcome.ok_samples("app_handler")], [12.0, 14.0])
        self.assertEqual([s.seconds for s in outcome.ok_samples("tui_crate_leaf")], [3.0, 4.0])

    def test_a_leaf_is_restored_when_its_build_raises(self) -> None:
        class Boom(FakeBuilder):
            def __call__(inner, role, workdir, command):
                if role == "app_handler-r0":
                    inner.calls.append((role, workdir, tuple(command), self.repo.bytes()))
                    raise ib.Interrupted(signal.SIGTERM)
                return super().__call__(role, workdir, command)

        builder = Boom(self.repo.root, self.work / "boom")
        with self.assertRaises(ib.Interrupted):
            self.measure(builder=builder)
        self.assertNotEqual(builder.calls[-1][3], self.pristine)  # the leaf was edited when the signal came
        self.assertEqual(self.repo.bytes(), self.pristine)

    def test_a_signal_during_a_build_restores_the_leaf(self) -> None:
        class Signalled(FakeBuilder):
            def __call__(inner, role, workdir, command):
                if role == "compat_leaf-r1":
                    os.kill(os.getpid(), signal.SIGTERM)
                return super().__call__(role, workdir, command)

        with ib.signals_raise(), self.assertRaises(ib.Interrupted) as raised:
            self.measure(builder=Signalled(self.repo.root, self.work / "sig"))
        self.assertEqual(raised.exception.signum, signal.SIGTERM)
        self.assertEqual(self.repo.bytes(), self.pristine)

    def test_a_signal_mid_build_stops_the_build_before_the_restore(self) -> None:
        pids = self.work / "pids"
        script = f'echo "$$" > "{pids}"; sleep 60 & echo "$!" >> "{pids}"; wait'
        metrics = ib.MetricsBuilder(self.work / "real")
        edited = {}

        def builder(role, workdir, command):
            if role != "compat_leaf-r0":
                return self.builder(role, workdir, command)
            edited["leaf"] = (self.repo.root / LEAVES[0].path).read_bytes()
            threading.Timer(1.0, os.kill, (os.getpid(), signal.SIGTERM)).start()
            return metrics(role, self.work, ["sh", "-c", script])

        with redirect_stdout(io.StringIO()), ib.signals_raise(), self.assertRaises(ib.Interrupted):
            self.measure(builder=builder)
        leader, child = (int(pid) for pid in pids.read_text().split())
        self.assertFalse(alive(leader), "the build command outlived measure()")
        self.assertFalse(alive(child), "a job the build started outlived measure()")
        self.assertNotEqual(edited["leaf"], self.pristine[LEAVES[0].path])
        self.assertEqual(self.repo.bytes(), self.pristine)

    def test_a_leaf_missing_from_head_skips_only_that_leaf(self) -> None:
        gone = ib.Leaf("gone_leaf", ib.SWIFT, "Packages/macOS/CmuxNext/Sources/CmuxNextSidebar/Gone.swift")
        outcome = ib.measure(self.repo.root, (*LEAVES, gone), 2, self.builder, self.work / "scratch",
                             self.work / "cargo")
        self.assertEqual(outcome.errors, [f"{gone.path}: not in HEAD, so gone_leaf is not measured"])
        for leaf in LEAVES:
            self.assertEqual(len(outcome.ok_samples(leaf.name)), 2, leaf.name)
        self.assertEqual(outcome.ok_samples("gone_leaf"), [])
        self.assertFalse(outcome.complete)
        self.assertFalse((self.repo.root / gone.path).exists())
        self.assertEqual(self.repo.bytes(), self.pristine)

    def test_a_dirty_leaf_is_refused_before_any_build(self) -> None:
        dirty = self.repo.root / LEAVES[1].path
        dirty.write_text("struct Mine {}\n")
        with self.assertRaisesRegex(ib.StoryError, "differs from HEAD"):
            self.measure()
        self.assertEqual(self.builder.calls, [])
        self.assertEqual(dirty.read_text(), "struct Mine {}\n")

    def test_a_failed_rebuild_keeps_the_other_samples_and_is_not_complete(self) -> None:
        builder = FakeBuilder(self.repo.root, self.work / "fail", fail=frozenset({"app_handler-r1"}))
        outcome = self.measure(builder=builder)
        self.assertEqual(len(outcome.ok_samples("app_handler")), 1)
        self.assertEqual(len(outcome.ok_samples("compat_leaf")), 2)
        self.assertFalse(outcome.complete)
        self.assertEqual(self.repo.bytes(), self.pristine)

    def test_a_failed_warm_build_skips_only_that_toolchain(self) -> None:
        builder = FakeBuilder(self.repo.root, self.work / "warm", fail=frozenset({"warm-swift"}))
        outcome = self.measure(builder=builder)
        self.assertEqual(outcome.ok_samples("compat_leaf"), [])
        self.assertEqual(len(outcome.ok_samples("tui_crate_leaf")), 2)
        self.assertIsNone(outcome.queue)
        self.assertIn("warm swift build exited 1", outcome.errors[0])

    def test_the_swift_build_turns_on_the_type_check_and_incremental_diagnostics(self) -> None:
        self.measure(rounds=1)
        swift = next(call for call in self.builder.calls if call[0] == "warm-swift")
        self.assertEqual(swift[1], self.repo.root / ib.SWIFT_PACKAGE)
        self.assertIn("-warn-long-function-bodies=100", swift[2])
        self.assertIn("-driver-show-incremental", swift[2])
        self.assertIn(ib.SWIFT_TARGET, swift[2])
        cargo = next(call for call in self.builder.calls if call[0] == "warm-cargo")
        self.assertEqual(cargo[1], self.repo.root / ib.CARGO_WORKSPACE)
        self.assertIn(f"CARGO_TARGET_DIR={self.work / 'cargo'}", cargo[2])

    # ------------------------------------------------------------ restore from HEAD (the shell trap)

    def test_restore_from_head_puts_back_only_probe_edits(self) -> None:
        probed, theirs = LEAVES[0], LEAVES[1]
        rust = LEAVES[2]
        (self.repo.root / probed.path).write_bytes(self.pristine[probed.path] + b"// incremental-build probe 3\n")
        (self.repo.root / rust.path).write_bytes(self.pristine[rust.path] + b"\n// incremental-build probe 0\n")
        (self.repo.root / theirs.path).write_bytes(self.pristine[theirs.path] + b"// a real edit\n")
        lines = ib.restore_from_head(self.repo.root, LEAVES)
        self.assertEqual((self.repo.root / probed.path).read_bytes(), self.pristine[probed.path])
        self.assertEqual((self.repo.root / rust.path).read_bytes(), self.pristine[rust.path])
        self.assertIn(b"a real edit", (self.repo.root / theirs.path).read_bytes())
        self.assertEqual([line.split(": ", 1)[1] for line in lines],
                         ["restored", "left alone (not HEAD plus probe lines)", "restored"])

    def test_probe_only(self) -> None:
        self.assertTrue(ib.probe_only(b"a\n// incremental-build probe 1\n", b"a\n"))
        self.assertTrue(ib.probe_only(b"a\n// incremental-build probe 1\n", b"a"))
        self.assertFalse(ib.probe_only(b"a\n", b"a\n"))
        self.assertFalse(ib.probe_only(b"a\nb\n// incremental-build probe 1\n", b"a\n"))
        self.assertFalse(ib.probe_only(b"b\n// incremental-build probe 1\n", b"a\n"))

    # ------------------------------------------------------------ rebuilt modules

    def test_rebuilt_modules_from_swiftpm_and_cargo_logs(self) -> None:
        self.assertEqual(ib.rebuilt_modules(SWIFT_REBUILD_LOG, ib.SWIFT), ["CmuxNextApp", "CmuxNextCompat"])
        self.assertEqual(ib.rebuilt_modules(CARGO_REBUILD_LOG, ib.CARGO), ["cmux-panic-log", "cmux-tui"])
        self.assertEqual(ib.rebuilt_modules("\x1b[1m[1/2] Compiling CmuxNextCompat X.swift\x1b[0m\n", ib.SWIFT),
                         ["CmuxNextCompat"])

    # ------------------------------------------------------------ MQ15

    def test_typecheck_queue_is_one_task_per_repo_file_at_or_over_the_limit(self) -> None:
        queue = ib.typecheck_queue(warm_log(self.repo.root), self.repo.root)
        self.assertEqual(queue["schema"], ib.QUEUE_SCHEMA)
        self.assertEqual([task["file"] for task in queue["tasks"]], QUEUE_FILES)
        big = queue["tasks"][0]
        self.assertEqual([(f["declaration"], f["subject"]) for f in big["functions"]],
                         [("instance method", "render()"), ("getter for property", "layout")])
        self.assertEqual(queue["tasks"][1]["functions"], [{"line": 7, "column": 3, "subject": "init(model:)",
                                                           "declaration": "initializer", "ms": 450.0}])
        self.assertEqual(queue["tasks"][2]["functions"], [{"line": 12, "column": 31, "subject": "closure",
                                                           "declaration": "closure", "ms": 140.0}])
        self.assertEqual(queue["tasks"][4]["functions"][0]["ms"], 100.0)
        self.assertEqual(queue["functions"], 6)  # not the expression or the dependency

    def test_typecheck_queue_is_deterministic_for_one_log(self) -> None:
        text = warm_log(self.repo.root)
        shuffled = "\n".join(reversed(text.splitlines())) + "\n"
        first = ib.typecheck_queue(text, self.repo.root)
        self.assertEqual(json.dumps(first, sort_keys=True), json.dumps(ib.typecheck_queue(text, self.repo.root),
                                                                        sort_keys=True))
        self.assertEqual(first, ib.typecheck_queue(shuffled, self.repo.root))

    def lab_queue(self, *argv: str) -> subprocess.CompletedProcess:
        return subprocess.run([sys.executable, "-I", str(LAB / "lab.py"), "queue", "typecheck", *argv,
                               "--root", str(self.repo.root)], capture_output=True, text=True)

    def test_lab_py_queue_typecheck_reads_a_log_and_a_run_folder(self) -> None:
        log = self.work / "warm.log"
        log.write_text(warm_log(self.repo.root))
        from_log = self.lab_queue("--log", str(log))
        self.assertEqual(from_log.returncode, 0, from_log.stderr)
        self.assertEqual([line.split("\t")[0] for line in from_log.stdout.splitlines()], [*QUEUE_FILES, "5 items"])
        self.assertEqual(from_log.stdout.splitlines()[0].split("\t")[1:],
                         [f"{QUEUE_FILES[0]}:10", "instance method render() :10 450 ms, "
                                                  "getter for property layout :40 120 ms"])
        run = self.work / "run"
        run.mkdir()
        (run / ib.QUEUE_FILE).write_text(json.dumps(ib.typecheck_queue(warm_log(self.repo.root), self.repo.root)))
        from_dir = self.lab_queue("--dir", str(run))
        self.assertEqual((from_dir.returncode, from_dir.stdout), (0, from_log.stdout), from_dir.stderr)

    def ingest(self, out: Path, db: Path, keep: bool = True):
        ingest = _load("perf_lab_ingest_under_incremental_build_test", LAB / "ingest.py")
        if not keep:
            (out / ib.QUEUE_FILE).unlink()
        lab = ingest.store.Store(db)
        try:
            lab.migrate()
            report = ingest.ingest_paths(lab, [out], commit_positions=lambda sha: ingest.CommitPosition(7, True))
        finally:
            lab.close()
        self.assertEqual(report.rejected, [])
        return report

    def story_run(self, out: Path) -> None:
        args = ib.parse_args(["--repo", str(self.repo.root), "run", "--out", str(out), "--rounds", "1",
                              "--scratch", str(self.work / "scratch"), "--cargo-target", str(self.work / "cargo")])
        with redirect_stdout(io.StringIO()):
            self.assertEqual(ib.run(args, {}, builder=self.builder, host_facts=lambda: FACTS,
                                    hostname="aws-m4pro-7", catalog=LEAVES), 0)

    def test_lab_py_queue_typecheck_latest_reads_the_stored_run_by_digest(self) -> None:
        out, db = self.work / "out", self.work / "lab.sqlite3"
        self.story_run(out)
        self.assertEqual(self.ingest(out, db).kept_attachments, 3)
        expected = self.lab_queue("--dir", str(out)).stdout
        shutil_out = self.work / "moved"
        os.rename(out, shutil_out)  # the builder's folder is gone: only the store has the queue
        latest = self.lab_queue("--latest", "--db", str(db))
        self.assertEqual((latest.returncode, latest.stdout), (0, expected), latest.stderr)
        by_env = subprocess.run([sys.executable, "-I", str(LAB / "lab.py"), "queue", "typecheck"],
                                capture_output=True, text=True, env={**os.environ, queues.DB_ENV: str(db)})
        self.assertEqual((by_env.returncode, by_env.stdout), (0, expected), by_env.stderr)

    def test_latest_says_why_when_the_store_lacks_the_queue(self) -> None:
        out, db = self.work / "out", self.work / "lab.sqlite3"
        self.story_run(out)
        self.ingest(out, db, keep=False)
        latest = self.lab_queue("--latest", "--db", str(db))
        self.assertEqual(latest.returncode, 1)
        self.assertIn("the store does not hold it; ingest the run's result folder again", latest.stderr)
        no_store = self.lab_queue("--latest", "--db", str(self.work / "none.sqlite3"))
        self.assertEqual(no_store.returncode, 1)
        self.assertIn("no lab store there", no_store.stderr)

    def test_queues_py_lists_mq15(self) -> None:
        run = self.work / "run"
        run.mkdir()
        (run / ib.QUEUE_FILE).write_text(json.dumps(ib.typecheck_queue(warm_log(self.repo.root), self.repo.root)))
        self.assertEqual(queues.find("mq15"), queues.find("typecheck"))
        items = queues.find("MQ15").run(str(self.repo.root), queues.TypecheckSource(run_dir=str(run)))
        self.assertEqual([item.key for item in items], QUEUE_FILES)

    def test_the_wrapper_waits_for_the_story_and_always_moves_the_submodule(self) -> None:
        text = (ROOT / "scripts" / "measure" / "incremental-build.sh").read_text()
        self.assertIn('"${story[@]}" run --out "$out" "$@" &', text)
        self.assertIn('wait "$story_pid"', text)
        self.assertIn('kill -TERM "$story_pid"', text)
        self.assertIn("if ! git submodule update --init --depth 1 ghostty-next; then", text)
        self.assertNotIn("ghostty-next/.git ] ||", text)

    # ------------------------------------------------------------ hosts

    def test_a_lab_host_is_refused(self) -> None:
        pool = self.work / "pool.json"
        pool.write_text(json.dumps({"hosts": [{"name": "cmux17"}]}))
        self.assertIn("perf-lab label", ib.lab_host_refusal({"CMUX_CI_LABELS": "measure,perf-lab"}, "aws-m4pro-7",
                                                            pool))
        self.assertIn("cmux17 is a perf-lab host", ib.lab_host_refusal({}, "CMUX17.local", pool))
        self.assertIsNone(ib.lab_host_refusal({"CMUX_CI_LABELS": "measure"}, "aws-m4pro-7", pool))
        pool.write_text("{")
        with self.assertRaisesRegex(ib.StoryError, "cannot be excluded"):
            ib.lab_host_refusal({}, "aws-m4pro-7", pool)

    def test_the_checked_in_pool_hosts_are_refused(self) -> None:
        names = [host["name"] for host in json.loads((LAB / "pool.json").read_text())["hosts"]]
        for name in names:
            self.assertIsNotNone(ib.lab_host_refusal({}, name))
        for builder in json.loads((LAB / "pool.json").read_text())["builders"]:
            self.assertIsNone(ib.lab_host_refusal({}, builder["name"]))

    def test_run_refuses_on_a_lab_host_before_it_builds(self) -> None:
        args = ib.parse_args(["--repo", str(self.repo.root), "run", "--out", str(self.work / "out")])
        code = ib.run(args, {"CMUX_CI_LABELS": "perf-lab"}, builder=self.builder, host_facts=lambda: FACTS,
                      hostname="aws-m4pro-7", catalog=LEAVES)
        self.assertEqual(code, 2)
        self.assertEqual(self.builder.calls, [])

    def test_host_block_has_no_display(self) -> None:
        host = ib.host_block(FACTS)
        self.assertEqual(host.host_class, "apple-m4-pro/48gb/0hz")
        self.assertIsNone(host.display_hz)
        with self.assertRaisesRegex(ib.StoryError, "chip or memory"):
            ib.host_block({**FACTS, "chip": None})

    # ------------------------------------------------------------ result-v1

    def test_run_writes_valid_results_with_the_attachments(self) -> None:
        out = self.work / "out"
        args = ib.parse_args(["--repo", str(self.repo.root), "run", "--out", str(out), "--rounds", "2",
                              "--scratch", str(self.work / "scratch"), "--cargo-target", str(self.work / "cargo"),
                              "--app", "/x/cmux DEV t.app", "--tag", "t", "light"])
        with redirect_stdout(io.StringIO()):
            code = ib.run(args, {}, builder=self.builder, host_facts=lambda: FACTS, hostname="aws-m4pro-7",
                          catalog=LEAVES)
        self.assertEqual(code, 0)
        self.assertEqual(self.repo.bytes(), self.pristine)
        written = perf_result.read_dir(out)
        by_metric = {r.metric: r for r in written}
        self.assertEqual(sorted(by_metric), sorted([
            "build.incremental.compat_leaf_s", "build.incremental.compat_leaf.rebuilt_modules",
            "build.incremental.app_handler_s", "build.incremental.app_handler.rebuilt_modules",
            "build.incremental.tui_crate_leaf_s", "build.incremental.tui_crate_leaf.rebuilt_modules",
            "build.typecheck.slow_functions"]))
        timed = by_metric["build.incremental.app_handler_s"]
        self.assertEqual(timed.samples, [7.5, 7.5])
        self.assertEqual(timed.target_ref.target, "incremental-build")
        self.assertEqual((timed.build.sha, timed.build.config, timed.story), (self.repo.sha, "debug", ib.STORY))
        self.assertEqual(by_metric["build.incremental.tui_crate_leaf.rebuilt_modules"].samples, [2, 2])
        self.assertEqual(by_metric["build.typecheck.slow_functions"].samples, [6])
        kinds = {a.kind: a.digest for a in timed.attachments}
        self.assertEqual(sorted(kinds), ["incremental-diagnostics", "rebuilt-modules", "typecheck-queue"])
        for kind, digest in kinds.items():
            data = (out / f"{kind}.json").read_bytes()
            self.assertEqual(digest, f"sha256:{hashlib.sha256(data).hexdigest()}")
        modules = json.loads((out / ib.MODULES_FILE).read_text())
        self.assertEqual(modules["rebuilds"][0], {"leaf": "compat_leaf", "round": 0, "seconds": 7.5, "exit_code": 0,
                                                  "modules": ["CmuxNextApp", "CmuxNextCompat"]})
        diagnostics = json.loads((out / ib.DIAGNOSTICS_FILE).read_text())["rebuilds"][0]
        self.assertEqual(diagnostics["initial_files"], ["Sources/CmuxNextCompat/MacName.swift"])

    def test_the_catalog_story_matches_the_metrics_the_story_writes(self) -> None:
        story = json.loads((LAB / "stories.d" / "incremental-build.json").read_text())
        patterns = [re.compile(m["name"]) for m in story["metrics"]]
        for leaf in ib.LEAVES:
            for metric in (f"build.incremental.{leaf.name}_s", f"build.incremental.{leaf.name}.rebuilt_modules"):
                self.assertTrue(any(p.fullmatch(metric) for p in patterns), metric)
            self.assertIn(f"file:{leaf.path}", story["needs"])
            self.assertTrue((ROOT / leaf.path).is_file(), leaf.path)
        self.assertTrue(any(p.fullmatch("build.typecheck.slow_functions") for p in patterns))
        self.assertEqual((story["config"], story["tier"]), (ib.CONFIG, "builder"))

    def test_a_session_other_than_light_is_refused(self) -> None:
        args = ib.parse_args(["--repo", str(self.repo.root), "run", "--out", str(self.work / "out"), "stress"])
        self.assertEqual(ib.run(args, {}, builder=self.builder, host_facts=lambda: FACTS, hostname="b",
                                catalog=LEAVES), 2)
        self.assertEqual(self.builder.calls, [])


class MetricsBuilderTest(unittest.TestCase):
    """The real builder: swiftpm_build_metrics.run_build around a stand-in command; the receipt's time is the
    command's alone."""

    def test_metrics_builder_times_the_command_and_keeps_its_log(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            work = Path(directory)
            builder = ib.MetricsBuilder(work / "builds")
            cwd = os.getcwd()
            build = builder("probe", work, [sys.executable, "-c", "print('[1/1] Compiling CmuxNextCompat A.swift')"])
            self.assertEqual(build.exit_code, 0)
            self.assertGreaterEqual(build.seconds, 0)
            self.assertIn("Compiling CmuxNextCompat", build.log.read_text())
            receipt = json.loads((work / "builds" / "probe.json").read_text())
            self.assertEqual(receipt["build_step_seconds"], build.seconds)
            self.assertEqual(os.getcwd(), cwd)


if __name__ == "__main__":
    unittest.main()
