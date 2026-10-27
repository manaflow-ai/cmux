#!/usr/bin/env python3
"""builds.py and scripts/measure/perf-lab-build.sh: the build ledger, and the builder step on a fixture repo.

The fixture repo stands in for cmux: a fake scripts/reload.sh that behaves as the real one where the step
depends on it (its body, the bench configuration line included, goes only to its own log, named by
`==> log: PATH`; a compile error exits 65 with BUILD FAILED; FAKE_RELOAD_MODE plays a full disk, BUILD
INTERRUPTED, a kill, a hang), a fake GhosttyKit download and a `ghostty` submodule. ANCIENT is a commit
before task 147 (bench only, compiled with CMUX_BLOCKING_CHECKS); OLD predates perf-lab-build.sh; the step
runs from a later TIP commit and builds OLD with OLD's own reload.sh and OLD's pinned submodule commit.

  python3 -m unittest scripts/perf-lab/tests/test_builds.py
"""
from __future__ import annotations

import fcntl
import importlib.util
import json
import os
import re
import shutil
import signal
import subprocess
import sys
import tempfile
import time
import unittest
import zipfile
from datetime import datetime, timezone
from pathlib import Path

REPO = Path(__file__).resolve().parents[3]
BUILDS_PY = REPO / "scripts/perf-lab/builds.py"
BUILD_SH = REPO / "scripts/measure/perf-lab-build.sh"
_SPEC = importlib.util.spec_from_file_location("perf_lab_builds", BUILDS_PY)
builds = importlib.util.module_from_spec(_SPEC)
sys.modules[_SPEC.name] = builds
_SPEC.loader.exec_module(builds)

NOW = datetime(2026, 10, 25, 12, 0, tzinfo=timezone.utc)
SHA_A = "a" * 40
DIGEST = "d" * 64
CHECKS_ARM = "        bench-checks) config=bench-checks ;;"

# A commit's reload.sh. %(extra_arm)s adds bench-checks (task 147); %(bench_extra)s is what `bench` adds to
# CMUX_BENCH_HOOKS (before 147: -DCMUX_BLOCKING_CHECKS). Records each run in FAKE_RELOAD_RUNS.
FAKE_RELOAD = r"""#!/usr/bin/env bash
set -euo pipefail
tag="" config="" derived=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --tag) tag="$2"; shift 2 ;;
    --config)
      case "$2" in
        debug) config=debug ;;
        release) config=release ;;
        bench) config=bench ;;
%(extra_arm)s
        *) echo "error: --config takes debug, release or bench" >&2; exit 1 ;;
      esac
      shift 2 ;;
    --derived-data) derived="$2"; shift 2 ;;
    --no-global-cli-links) shift ;;
    *) echo "error: unknown option $1" >&2; exit 1 ;;
  esac
done
echo "$(git rev-parse HEAD) $config $(cat ghostty/VERSION)" >> "$FAKE_RELOAD_RUNS"
if [[ "${FAKE_RELOAD_MODE:-}" == disk ]]; then
  echo "error: cmux-next build needs 40 GiB free on the home volume; 3 GiB free." >&2
  exit 1
fi
app="$derived/Build/Products/Release/cmux DEV $tag.app"
log="$FAKE_RELOAD_LOG"
: > "$log"
exec 3>&1 4>&2
exec >>"$log" 2>&1
finalize() {
  local rc=$?
  trap - EXIT
  exec 1>&3 2>&4
  if [[ "$rc" -ne 0 ]]; then
    cat "$log" >&2
    echo "==> reload FAILED (exit $rc) after 1s" >&2
    echo "==> log: $log" >&2
    exit "$rc"
  fi
  echo "==> reload succeeded in 1s"
  echo "==> log: $log"
  echo
  echo "App path:"
  echo "  $app"
}
trap finalize EXIT
defines=" -DCMUX_BENCH_HOOKS%(bench_extra)s"
[[ "$config" != bench-checks ]] || defines=" -DCMUX_BENCH_HOOKS -DCMUX_BLOCKING_CHECKS"
echo "==> bench configuration: Release optimization with$defines (no DEBUG)"
if [[ -f BROKEN || "${FAKE_RELOAD_MODE:-}" == broken ]]; then
  echo "Sources/App.swift:3:7: error: cannot find 'x' in scope"
  echo "** BUILD FAILED **"
  exit 65
fi
case "${FAKE_RELOAD_MODE:-}" in
  interrupted)
    echo "** BUILD INTERRUPTED **"
    echo "error: xcodebuild reported ** BUILD INTERRUPTED **; refusing to reuse DerivedData app artifacts" >&2
    exit 65 ;;
  killed) kill -KILL $$ ;;
  hang) sh -c 'echo $$ > "$FAKE_RELOAD_HANG_PID"; exec sleep 60' ;;
esac
mkdir -p "$app/Contents/MacOS"
cat VERSION > "$app/Contents/MacOS/cmux"
"""

FAKE_GHOSTTYKIT = """#!/usr/bin/env bash
[[ -z "${FAKE_GHOSTTYKIT_FAIL:-}" ]] || { echo "error: no GhosttyKit archive" >&2; exit 1; }
mkdir -p GhosttyKit.xcframework && cp ghostty/VERSION GhosttyKit.xcframework/Info.plist
"""


def git(cwd: Path, *args: str) -> str:
    return subprocess.run(["git", *args], cwd=cwd, check=True, capture_output=True, text=True,
                          env=GIT_ENV).stdout.strip()


GIT_ENV = {**os.environ, "GIT_AUTHOR_NAME": "t", "GIT_AUTHOR_EMAIL": "t@t", "GIT_COMMITTER_NAME": "t",
           "GIT_COMMITTER_EMAIL": "t@t", "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": os.devnull,
           "GIT_CONFIG_COUNT": "1", "GIT_CONFIG_KEY_0": "protocol.file.allow", "GIT_CONFIG_VALUE_0": "always"}


def write(path: Path, text: str, mode: int = 0o644) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text)
    path.chmod(mode)


def reload_text(*, checks_arm: bool, bench_extra: str = "") -> str:
    return FAKE_RELOAD % {"extra_arm": CHECKS_ARM if checks_arm else "", "bench_extra": bench_extra}


def alive(pid: int) -> bool:
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    return True


class LedgerTests(unittest.TestCase):
    def setUp(self) -> None:
        self.dir = Path(tempfile.mkdtemp())
        self.ledger = builds.BuildLedger(self.dir, clock=lambda: NOW)

    def tearDown(self) -> None:
        shutil.rmtree(self.dir)

    def ok(self, **changes) -> builds.BuildRecord:
        fields = dict(sha=SHA_A, config="bench", status="ok", seconds=12, digest=DIGEST, app="cmux DEV t.app")
        return builds.BuildRecord(**{**fields, **changes})

    def failed(self, **changes) -> builds.BuildRecord:
        fields = dict(sha=SHA_A, config="bench", status="failed", seconds=3, reason="error: x")
        return builds.BuildRecord(**{**fields, **changes})

    def test_has_build_only_after_an_ok_record(self) -> None:
        self.assertFalse(self.ledger.has_build(SHA_A, "bench"))
        self.assertTrue(self.ledger.should_build(SHA_A, "bench"))
        stored = self.ledger.record(self.ok())
        self.assertEqual(stored.recorded_at, "2026-10-25T12:00:00+00:00")
        self.assertTrue(self.ledger.has_build(SHA_A, "bench"))
        self.assertFalse(self.ledger.should_build(SHA_A, "bench"))

    def test_the_key_includes_the_config(self) -> None:
        self.ledger.record(self.ok())
        self.assertFalse(self.ledger.has_build(SHA_A, "bench-checks"))
        self.assertTrue(self.ledger.should_build(SHA_A, "bench-checks"))
        self.assertNotEqual(builds.build_key(SHA_A, "bench"), builds.build_key(SHA_A, "bench-checks"))

    def test_a_failed_build_is_recorded_once_and_never_retried(self) -> None:
        first = self.ledger.record(self.failed(job="job-1"))
        self.assertFalse(self.ledger.has_build(SHA_A, "bench"))
        self.assertFalse(self.ledger.should_build(SHA_A, "bench"))
        self.assertEqual(self.ledger.record(self.failed(job="job-2", seconds=9, reason="other")), first)
        with self.assertRaisesRegex(builds.BuildError, "already recorded as failed"):
            self.ledger.record(self.ok())
        self.assertEqual(self.ledger.get(SHA_A, "bench"), first)

    def test_a_rebuilt_ok_record_takes_the_new_digest_and_never_becomes_failed(self) -> None:
        first = self.ledger.record(self.ok(job="job-1"))
        self.assertEqual(self.ledger.record(self.ok(job="job-2", seconds=40)), first)  # a replay
        rebuilt = self.ledger.record(self.ok(digest="e" * 64, seconds=30, job="job-3"))
        self.assertEqual((rebuilt.digest, rebuilt.seconds), ("e" * 64, 30))
        self.assertEqual(self.ledger.get(SHA_A, "bench"), rebuilt)
        with self.assertRaisesRegex(builds.BuildError, "already recorded as ok"):
            self.ledger.record(self.failed())
        self.assertEqual(self.ledger.get(SHA_A, "bench"), rebuilt)
        self.assertEqual(sorted(p.name for p in (self.dir / "records").iterdir()), [f"{SHA_A}-bench.json"])

    def test_forget_is_the_operator_undo_and_keeps_what_it_dropped(self) -> None:
        self.ledger.record(self.failed())
        with self.assertRaisesRegex(builds.BuildError, "reason"):
            self.ledger.forget(SHA_A, "bench", reason=" ")
        self.assertEqual(self.ledger.forget(SHA_A, "bench", reason="builder disk was full").status, "failed")
        self.assertTrue(self.ledger.should_build(SHA_A, "bench"))
        self.assertIsNone(self.ledger.forget(SHA_A, "bench", reason="again"))
        log = [json.loads(line) for line in (self.dir / "forgotten.jsonl").read_text().splitlines()]
        self.assertEqual([(entry["reason"], entry["record"]["status"]) for entry in log],
                         [("builder disk was full", "failed")])
        self.assertEqual(self.ledger.record(self.ok()).status, "ok")

    def test_records_are_validated(self) -> None:
        for changes, message in (({"config": "debug"}, "not a bench config"), ({"config": "release"}, "not a bench"),
                                 ({"digest": "abc"}, "64-hex digest"), ({"digest": DIGEST.upper()}, "64-hex"),
                                 ({"sha": "abc"}, "40-hex"), ({"app": None}, "app bundle name"),
                                 ({"app": "../x.app"}, "app bundle name"), ({"seconds": -1}, "seconds"),
                                 ({"defines": ("-DX",)}, "Swift define")):
            with self.subTest(changes=changes), self.assertRaisesRegex(builds.BuildError, message):
                self.ok(**changes)
        with self.assertRaisesRegex(builds.BuildError, "needs a reason"):
            builds.BuildRecord(sha=SHA_A, config="bench", status="failed", seconds=1)
        with self.assertRaisesRegex(builds.BuildError, "no artifact digest"):
            builds.BuildRecord(sha=SHA_A, config="bench", status="failed", seconds=1, reason="x", digest=DIGEST)

    def test_json_round_trip(self) -> None:
        record = self.ok(defines=("CMUX_BENCH_HOOKS",), recorded_at="2026-10-25T12:00:00+00:00")
        self.assertEqual(builds.BuildRecord.from_json(json.loads(json.dumps(record.to_json()))), record)
        with self.assertRaisesRegex(builds.BuildError, "schema"):
            builds.BuildRecord.from_json({**record.to_json(), "schema": "other/v0"})

    def test_reload_supports_reads_the_config_arm(self) -> None:
        old = reload_text(checks_arm=False)
        new = reload_text(checks_arm=True)
        self.assertTrue(builds.reload_supports(old, "bench"))
        self.assertFalse(builds.reload_supports(old, "bench-checks"))
        self.assertTrue(builds.reload_supports(new, "bench-checks"))
        # The real reload.sh's arm as of this commit.
        self.assertTrue(builds.reload_supports((REPO / "scripts/reload.sh").read_text(), "bench"))

    def test_bench_defines_reads_the_last_configuration_line(self) -> None:
        log = ("==> bench configuration: Release optimization with -DCMUX_BENCH_HOOKS -DCMUX_BLOCKING_CHECKS "
               "(no DEBUG)\n")
        self.assertEqual(builds.bench_defines(log), ("CMUX_BENCH_HOOKS", "CMUX_BLOCKING_CHECKS"))
        self.assertEqual(builds.bench_defines("no such line\n"), ())

    def test_build_outcome_sorts_by_the_log_not_the_exit_code(self) -> None:
        bench = "==> bench configuration: Release optimization with -DCMUX_BENCH_HOOKS (no DEBUG)\n"
        checks = "==> bench configuration: Release optimization with -DCMUX_BENCH_HOOKS -DCMUX_BLOCKING_CHECKS\n"
        compile_error = "Sources/App.swift:3:7: error: cannot find 'x' in scope\n** BUILD FAILED **\n"
        link_error = "ld: symbol(s) not found for architecture arm64\n** BUILD FAILED **\n"
        cases = (
            ("bench", 0, bench, "ok"),
            ("bench-checks", 0, checks, "ok"),
            ("bench", 65, compile_error, "commit"),  # xcodebuild's BUILD FAILED exit code
            ("bench", 1, compile_error, "commit"),
            ("bench", 65, link_error, "commit"),
            ("bench", 65, "** BUILD INTERRUPTED **\nerror: xcodebuild reported ** BUILD INTERRUPTED **\n", "infra"),
            ("bench", 65, compile_error + "** BUILD INTERRUPTED **\n", "infra"),
            ("bench", 1, "error: cmux-next build needs 40 GiB free on the home volume; 3 GiB free.\n", "infra"),
            ("bench", 1, "error: no cached acpmux for this checkout\n", "infra"),
            ("bench", 65, "error: Could not resolve package dependencies:\n** BUILD FAILED **\n", "infra"),
            ("bench", 1, "error: codesign failed\n", "infra"),
            ("bench", 137, compile_error, "infra"),
            ("bench", 124, compile_error, "infra"),
            ("bench", 0, "", "infra"),
            ("bench", 0, checks, "commit"),  # a commit before task 147: bench has the blocking checks
            ("bench-checks", 0, bench, "commit"),
            ("bench", 0, "==> bench configuration: Release optimization with -DDEBUG -DCMUX_BENCH_HOOKS\n", "commit"),
        )
        for config, rc, log, kind in cases:
            with self.subTest(config=config, rc=rc, log=log):
                self.assertEqual(builds.build_outcome(config, rc, log).kind, kind)
        self.assertIn("cannot find 'x' in scope", builds.build_outcome("bench", 65, compile_error).reason)
        self.assertIn("GiB free", builds.build_outcome("bench", 1, cases[7][2]).reason)
        self.assertEqual(builds.build_outcome("bench", 0, bench).defines, ("CMUX_BENCH_HOOKS",))

    def test_run_locked_refuses_a_held_lock_with_75(self) -> None:
        lock = self.dir / "lock"
        with open(lock, "a") as held:
            fcntl.flock(held, fcntl.LOCK_EX)
            done = subprocess.run([sys.executable, "-I", str(BUILDS_PY), "run-locked", str(lock), "--", "true"],
                                  capture_output=True, text=True)
        self.assertEqual(done.returncode, 75, done.stderr)
        done = subprocess.run([sys.executable, "-I", str(BUILDS_PY), "run-locked", str(lock), "--", "sh", "-c",
                               "exit 7"], capture_output=True, text=True)
        self.assertEqual(done.returncode, 7)
        self.assertEqual(lock.read_text(), "")

    def test_run_locked_stops_the_group_a_killed_runner_left(self) -> None:
        lock = self.dir / "lock"
        orphan = subprocess.Popen(["sleep", "60"], start_new_session=True)
        try:
            # A note whose start time is not the leader's: the pid was reused by someone else's group.
            lock.write_text(f"{orphan.pid} Thu Jan  1 00:00:00 1970\n")
            done = subprocess.run([sys.executable, "-I", str(BUILDS_PY), "run-locked", "--grace", "5", str(lock),
                                   "--", "true"], capture_output=True, text=True, timeout=30)
            self.assertEqual(done.returncode, 0, done.stderr)
            self.assertIsNone(orphan.poll())
            lock.write_text(f"{orphan.pid} {builds._started(orphan.pid)}\n")
            done = subprocess.run([sys.executable, "-I", str(BUILDS_PY), "run-locked", "--grace", "5", str(lock),
                                   "--", "true"], capture_output=True, text=True, timeout=30)
            self.assertEqual(done.returncode, 0, done.stderr)
            self.assertIn(f"process group {orphan.pid}", done.stderr)
            self.assertEqual(orphan.wait(timeout=5), -signal.SIGTERM)
        finally:
            if orphan.poll() is None:
                orphan.kill()
                orphan.wait()


class ScriptTextTests(unittest.TestCase):
    def test_never_config_debug(self) -> None:
        text = BUILD_SH.read_text()
        self.assertNotRegex(text, r"--config[ =]\"?(debug|release)")
        self.assertRegex(text, r"\n  bench \| bench-checks\) ;;\n")
        self.assertEqual(builds.CONFIGS, ("bench", "bench-checks"))
        calls = re.findall(r"scripts/reload\.sh[^\n]*", text)
        self.assertTrue(calls)
        self.assertTrue(all('--config "$config"' in call for call in calls), calls)

    def test_the_ledger_is_named_by_the_build_version(self) -> None:
        text = BUILD_SH.read_text()
        self.assertRegex(text, r"\nPERF_LAB_BUILD_VERSION=1 ")
        self.assertIn('ledger="$root/v$PERF_LAB_BUILD_VERSION"', text)


@unittest.skipUnless(shutil.which("git") and (shutil.which("zip") or shutil.which("ditto")), "needs git and zip")
class BuildStepTests(unittest.TestCase):
    """Runs perf-lab-build.sh at TIP of a fixture repo against older commits."""

    @classmethod
    def setUpClass(cls) -> None:
        cls.dir = Path(tempfile.mkdtemp())
        upstream = cls.dir / "upstream"
        ghostty = cls.dir / "ghostty"
        ghostty.mkdir()
        git(ghostty, "init", "-q", "-b", "main")
        write(ghostty / "VERSION", "ghostty-1\n")
        git(ghostty, "add", "-A")
        git(ghostty, "commit", "-q", "-m", "ghostty 1")
        cls.ghostty_old = git(ghostty, "rev-parse", "HEAD")
        write(ghostty / "VERSION", "ghostty-2\n")
        git(ghostty, "commit", "-q", "-am", "ghostty 2")

        upstream.mkdir()
        git(upstream, "init", "-q", "-b", "main")
        git(upstream, "-c", "protocol.file.allow=always", "submodule", "add", "-q", str(ghostty), "ghostty")
        git(upstream / "ghostty", "checkout", "-q", cls.ghostty_old)
        write(upstream / "scripts/reload.sh", reload_text(checks_arm=False, bench_extra=" -DCMUX_BLOCKING_CHECKS"),
              0o755)
        write(upstream / "scripts/download-prebuilt-ghosttykit.sh", FAKE_GHOSTTYKIT, 0o755)
        write(upstream / "VERSION", "ancient\n")
        write(upstream / ".gitignore", "GhosttyKit.xcframework\nartifacts/\n")
        git(upstream, "add", "-A")
        git(upstream, "commit", "-q", "-m", "ancient: before task 147")
        cls.ancient = git(upstream, "rev-parse", "HEAD")

        write(upstream / "scripts/reload.sh", reload_text(checks_arm=True), 0o755)
        write(upstream / "VERSION", "old\n")
        git(upstream, "add", "-A")
        git(upstream, "commit", "-q", "-m", "old: task 147")
        cls.old = git(upstream, "rev-parse", "HEAD")

        write(upstream / "BROKEN", "x\n")
        git(upstream, "add", "-A")
        git(upstream, "commit", "-q", "-m", "broken")
        cls.broken = git(upstream, "rev-parse", "HEAD")
        git(upstream, "rm", "-q", "BROKEN")

        git(upstream / "ghostty", "checkout", "-q", "main")
        write(upstream / "VERSION", "tip\n")
        for source in (BUILD_SH, BUILDS_PY):
            target = upstream / source.relative_to(REPO)
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(source, target)
        git(upstream, "add", "-A")
        git(upstream, "commit", "-q", "-m", "tip: adds perf-lab-build.sh")
        cls.tip = git(upstream, "rev-parse", "HEAD")
        cls.upstream = upstream

        # The step's checkout: a clone at TIP whose origin is the upstream repo.
        cls.checkout = cls.dir / "step"
        subprocess.run(["git", "clone", "-q", str(upstream), str(cls.checkout)], check=True, env=GIT_ENV)

    @classmethod
    def tearDownClass(cls) -> None:
        shutil.rmtree(cls.dir)

    def setUp(self) -> None:
        self.cache = Path(tempfile.mkdtemp(dir=self.dir))
        self.runs = self.cache / "reload-runs"
        self.runs.touch()
        self.ledger = builds.BuildLedger(self.cache / "perf-lab-build/v1")

    def env(self, labels: str, faults: dict[str, str]) -> dict[str, str]:
        env = {**GIT_ENV, "PERF_LAB_BUILD_ROOT": str(self.cache / "perf-lab-build"),
               "FAKE_RELOAD_RUNS": str(self.runs), "FAKE_RELOAD_LOG": str(self.cache / "reload-own.log"),
               "CMUX_CI_LABELS": labels, "CMUX_CI_STEP_KEY": "step-1", **faults}
        for name in ("CI_SHARED_CACHE_DIR", "PERF_LAB_BUILD_LOCKED", "FAKE_RELOAD_MODE", "FAKE_GHOSTTYKIT_FAIL"):
            if name not in faults:
                env.pop(name, None)
        return env

    def step(self, *args: str, labels: str = "cmux,measure", **faults: str) -> subprocess.CompletedProcess[str]:
        return subprocess.run(["bash", "scripts/measure/perf-lab-build.sh", *args], cwd=self.checkout,
                              env=self.env(labels, faults), capture_output=True, text=True, timeout=120)

    def receipt(self, done: subprocess.CompletedProcess[str]) -> dict[str, object]:
        lines = [line for line in done.stdout.splitlines() if line.startswith("perf-lab-build: {")]
        self.assertTrue(lines, done.stdout + done.stderr)
        receipt = json.loads(lines[-1].removeprefix("perf-lab-build: "))
        self.assertEqual(json.loads((self.checkout / "artifacts/perf-lab-build/receipt.json").read_text()), receipt)
        return receipt

    def reload_runs(self) -> list[str]:
        return self.runs.read_text().splitlines()

    def test_builds_a_commit_older_than_the_script_then_reuses_the_cache(self) -> None:
        self.assertNotIn("perf-lab-build.sh", git(self.upstream, "ls-tree", "-r", "--name-only", self.old))
        done = self.step(f"--build-sha={self.old}")
        self.assertEqual(done.returncode, 0, done.stdout + done.stderr)
        receipt = self.receipt(done)
        self.assertEqual((receipt["sha"], receipt["config"], receipt["status"], receipt["cached"]),
                         (self.old, "bench", "ok", False))
        self.assertRegex(receipt["digest"], r"^[0-9a-f]{64}$")
        self.assertIsInstance(receipt["seconds"], int)
        # The defines come from reload.sh's own log: its stdout never has the bench configuration line.
        self.assertNotIn("bench configuration", (self.checkout / "artifacts/perf-lab-build/reload.log").read_text())
        self.assertEqual(receipt["defines"], ["CMUX_BENCH_HOOKS"])
        self.assertEqual(self.ledger.get(self.old, "bench").defines, ("CMUX_BENCH_HOOKS",))
        self.assertEqual(receipt["build_version"], 1)
        # OLD's tree and OLD's pinned submodule commit, never TIP's.
        self.assertEqual(self.reload_runs(), [f"{self.old} bench ghostty-1"])
        app_zip = self.checkout / "artifacts/perf-lab-build/app.zip"
        self.assertEqual(builds.file_digest(app_zip), receipt["digest"])
        with zipfile.ZipFile(app_zip) as archive:
            self.assertEqual(archive.read(f"{receipt['app']}/Contents/MacOS/cmux"), b"old\n")

        again = self.step(f"--build-sha={self.old}")
        self.assertEqual(again.returncode, 0, again.stdout + again.stderr)
        cached = self.receipt(again)
        self.assertEqual((cached["digest"], cached["cached"]), (receipt["digest"], True))
        self.assertEqual(len(self.reload_runs()), 1)
        self.assertEqual(builds.file_digest(app_zip), receipt["digest"])

    def test_a_cached_zip_that_is_gone_builds_again_and_the_record_takes_its_digest(self) -> None:
        first = self.receipt(self.step(f"--build-sha={self.old}"))
        (self.cache / f"perf-lab-build/v1/zips/{first['digest']}.zip").unlink()
        done = self.step(f"--build-sha={self.old}")
        self.assertEqual(done.returncode, 0, done.stdout + done.stderr)
        rebuilt = self.receipt(done)
        self.assertFalse(rebuilt["cached"])
        self.assertEqual(self.ledger.get(self.old, "bench").digest, rebuilt["digest"])
        self.assertTrue((self.cache / f"perf-lab-build/v1/zips/{rebuilt['digest']}.zip").is_file())
        self.assertEqual(len(self.reload_runs()), 2)

    def test_a_rebuild_that_fails_after_an_ok_build_is_the_builders(self) -> None:
        first = self.receipt(self.step(f"--build-sha={self.old}"))
        (self.cache / f"perf-lab-build/v1/zips/{first['digest']}.zip").unlink()
        done = self.step(f"--build-sha={self.old}", FAKE_RELOAD_MODE="broken")
        self.assertEqual(done.returncode, 75, done.stdout + done.stderr)
        self.assertEqual(self.ledger.get(self.old, "bench").status, "ok")

    def test_a_failed_build_is_recorded_once_and_never_retried(self) -> None:
        done = self.step(f"--build-sha={self.broken}")
        self.assertEqual(done.returncode, 1, done.stdout + done.stderr)
        receipt = self.receipt(done)
        self.assertEqual((receipt["status"], receipt["digest"]), ("failed", None))
        self.assertIn("cannot find 'x' in scope", receipt["reason"])
        self.assertIn("exit 65", receipt["reason"])  # xcodebuild's BUILD FAILED code, as the real reload.sh
        again = self.step(f"--build-sha={self.broken}")
        self.assertEqual(again.returncode, 1)
        self.assertEqual(self.receipt(again)["status"], "failed")
        self.assertEqual(len(self.reload_runs()), 1)

    def test_a_commit_before_task_147_supports_neither_config(self) -> None:
        done = self.step(f"--build-sha={self.ancient}", "--config=bench-checks")
        self.assertEqual(done.returncode, 1, done.stdout + done.stderr)
        self.assertIn("no --config bench-checks", self.receipt(done)["reason"])
        self.assertEqual(self.reload_runs(), [])
        # Its bench builds with the blocking checks: not the bench config, recorded once.
        done = self.step(f"--build-sha={self.ancient}")
        self.assertEqual(done.returncode, 1, done.stdout + done.stderr)
        receipt = self.receipt(done)
        self.assertEqual((receipt["status"], receipt["defines"]), ("failed", []))
        self.assertIn("-DCMUX_BLOCKING_CHECKS present", receipt["reason"])
        self.assertEqual(self.step(f"--build-sha={self.ancient}").returncode, 1)
        self.assertEqual(self.reload_runs(), [f"{self.ancient} bench ghostty-1"])
        # bench of a later commit is its own key and still builds.
        self.assertEqual(self.step(f"--build-sha={self.old}").returncode, 0)

    def test_bench_checks_at_tip(self) -> None:
        done = self.step(f"--build-sha={self.tip}", "--config=bench-checks")
        self.assertEqual(done.returncode, 0, done.stdout + done.stderr)
        receipt = self.receipt(done)
        self.assertEqual(receipt["defines"], ["CMUX_BENCH_HOOKS", "CMUX_BLOCKING_CHECKS"])
        self.assertEqual(self.reload_runs(), [f"{self.tip} bench-checks ghostty-2"])

    def test_a_failure_that_is_not_the_commits_records_nothing(self) -> None:
        missing = "f" * 40
        for args, faults in (((f"--build-sha={self.old}",), {"FAKE_RELOAD_MODE": "disk"}),
                             ((f"--build-sha={self.old}",), {"FAKE_RELOAD_MODE": "interrupted"}),
                             ((f"--build-sha={self.old}",), {"FAKE_RELOAD_MODE": "killed"}),
                             ((f"--build-sha={self.old}",), {"FAKE_GHOSTTYKIT_FAIL": "1"}),
                             ((f"--build-sha={missing}",), {})):
            with self.subTest(args=args, faults=faults):
                done = self.step(*args, **faults)
                self.assertEqual(done.returncode, 75, done.stdout + done.stderr)
                self.assertIn("nothing recorded", done.stderr)
                self.assertIsNone(self.ledger.get(args[0].removeprefix("--build-sha="), "bench"))
        runs = len(self.reload_runs())
        self.assertEqual(runs, 3)  # disk, interrupted and killed reached reload.sh
        done = self.step(f"--build-sha={self.old}")
        self.assertEqual(done.returncode, 0, done.stdout + done.stderr)
        self.assertEqual(len(self.reload_runs()), runs + 1)

    def test_a_cancelled_build_stops_its_whole_process_group(self) -> None:
        hang_pid = self.cache / "hang.pid"
        output = self.cache / "step-output"
        with open(output, "w") as sink:
            step = subprocess.Popen(["bash", "scripts/measure/perf-lab-build.sh", f"--build-sha={self.old}"],
                                    cwd=self.checkout, stdout=sink, stderr=subprocess.STDOUT,
                                    env=self.env("cmux", {"FAKE_RELOAD_MODE": "hang",
                                                          "FAKE_RELOAD_HANG_PID": str(hang_pid)}))
        try:
            deadline = time.monotonic() + 60
            while not (hang_pid.is_file() and hang_pid.read_text().strip()):
                self.assertLess(time.monotonic(), deadline, "the fake build never started")
                if step.poll() is not None:
                    self.fail(f"the step ended before its build started:\n{output.read_text()}")
                time.sleep(0.05)
            grandchild = int(hang_pid.read_text())
            self.assertTrue(alive(grandchild))
            step.send_signal(signal.SIGTERM)  # the step's top process only, as a worker cancels it
            step.wait(timeout=30)
        finally:
            if step.poll() is None:
                step.kill()
                step.wait()
        self.assertEqual(step.returncode, 75, output.read_text())
        self.assertFalse(alive(grandchild), "xcodebuild's stand-in outlived the cancelled step")
        self.assertIsNone(self.ledger.get(self.old, "bench"))
        self.assertEqual((self.cache / "perf-lab-build/lock").read_text(), "")

    def test_refusals(self) -> None:
        for args, labels, message in (
                ((f"--build-sha={self.old}", "--config=debug"), "cmux", "never Debug"),
                ((f"--build-sha={self.old}", "--config=release"), "cmux", "bench or bench-checks"),
                (("--build-sha=abc",), "cmux", "40-hex"),
                ((f"--build-sha={self.old}",), "cmux,perf-lab,measure", "perf-lab label")):
            with self.subTest(args=args, labels=labels):
                done = self.step(*args, labels=labels)
                self.assertEqual(done.returncode, 2, done.stdout + done.stderr)
                self.assertIn(message, done.stderr)
        self.assertEqual(self.reload_runs(), [])

    def test_a_busy_builder_cache_exits_75(self) -> None:
        lock = self.cache / "perf-lab-build/lock"
        lock.parent.mkdir(parents=True)
        with open(lock, "a") as held:
            fcntl.flock(held, fcntl.LOCK_EX)
            done = self.step(f"--build-sha={self.old}")
        self.assertEqual(done.returncode, 75, done.stdout + done.stderr)
        self.assertEqual(self.reload_runs(), [])


if __name__ == "__main__":
    unittest.main()
