#!/usr/bin/env python3
"""builds.py and scripts/measure/perf-lab-build.sh: the build ledger, and the builder step on a fixture repo.

The fixture repo stands in for cmux: a fake scripts/reload.sh (prints the App path and the bench defines,
counts its runs), a fake GhosttyKit download and a `ghostty` submodule. Its OLD commit predates
perf-lab-build.sh; the step runs from a later TIP commit and builds OLD with OLD's own reload.sh and
OLD's pinned submodule commit.

  python3 -m unittest scripts/perf-lab/tests/test_builds.py
"""
from __future__ import annotations

import fcntl
import importlib.util
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
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

# OLD's reload.sh: knows bench only (before task 147). Fails when the tree has BROKEN. Records each run.
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
if [[ -f BROKEN ]]; then
  echo "Sources/App.swift:3:7: error: cannot find 'x' in scope"
  echo "** BUILD FAILED **"
  exit 1
fi
echo "==> bench configuration: Release optimization with -DCMUX_BENCH_HOOKS%(define)s (no DEBUG)"
app="$derived/Build/Products/Release/cmux DEV $tag.app"
mkdir -p "$app/Contents/MacOS"
cat VERSION > "$app/Contents/MacOS/cmux"
echo "==> reload succeeded in 1s"
echo
echo "App path:"
echo "  $app"
"""

FAKE_GHOSTTYKIT = """#!/usr/bin/env bash
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


class LedgerTests(unittest.TestCase):
    def setUp(self) -> None:
        self.dir = Path(tempfile.mkdtemp())
        self.ledger = builds.BuildLedger(self.dir, clock=lambda: NOW)

    def tearDown(self) -> None:
        shutil.rmtree(self.dir)

    def ok(self, **changes) -> builds.BuildRecord:
        fields = dict(sha=SHA_A, config="bench", status="ok", seconds=12, digest=DIGEST, app="cmux DEV t.app")
        return builds.BuildRecord(**{**fields, **changes})

    def failed(self) -> builds.BuildRecord:
        return builds.BuildRecord(sha=SHA_A, config="bench", status="failed", seconds=3, reason="error: x")

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
        self.ledger.record(self.failed())
        self.assertFalse(self.ledger.has_build(SHA_A, "bench"))
        self.assertFalse(self.ledger.should_build(SHA_A, "bench"))
        with self.assertRaisesRegex(builds.BuildError, "already recorded as failed"):
            self.ledger.record(self.ok())
        with self.assertRaisesRegex(builds.BuildError, "never retried"):
            self.ledger.forget(SHA_A, "bench")
        self.assertEqual(self.ledger.get(SHA_A, "bench").status, "failed")

    def test_a_replayed_record_is_a_no_op_and_another_digest_is_refused(self) -> None:
        first = self.ledger.record(self.ok(job="job-1"))
        self.assertEqual(self.ledger.record(self.ok(job="job-2")), first)
        with self.assertRaisesRegex(builds.BuildError, "already recorded"):
            self.ledger.record(self.ok(digest="e" * 64))

    def test_forget_drops_an_ok_record(self) -> None:
        self.ledger.record(self.ok())
        self.ledger.forget(SHA_A, "bench")
        self.assertTrue(self.ledger.should_build(SHA_A, "bench"))

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
        old = FAKE_RELOAD % {"extra_arm": "", "define": ""}
        new = FAKE_RELOAD % {"extra_arm": "        bench-checks) config=bench-checks ;;", "define": ""}
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


class ScriptTextTests(unittest.TestCase):
    def test_never_config_debug(self) -> None:
        text = BUILD_SH.read_text()
        self.assertNotRegex(text, r"--config[ =]\"?(debug|release)")
        self.assertRegex(text, r"\n  bench \| bench-checks\) ;;\n")
        self.assertEqual(builds.CONFIGS, ("bench", "bench-checks"))
        calls = re.findall(r"scripts/reload\.sh[^\n]*", text)
        self.assertTrue(calls)
        self.assertTrue(all('--config "$config"' in call for call in calls), calls)


@unittest.skipUnless(shutil.which("git") and (shutil.which("zip") or shutil.which("ditto")), "needs git and zip")
class BuildStepTests(unittest.TestCase):
    """Runs perf-lab-build.sh at TIP of a fixture repo against OLD, a commit that predates the script."""

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
        write(upstream / "scripts/reload.sh", FAKE_RELOAD % {"extra_arm": "", "define": ""}, 0o755)
        write(upstream / "scripts/download-prebuilt-ghosttykit.sh", FAKE_GHOSTTYKIT, 0o755)
        write(upstream / "VERSION", "old\n")
        write(upstream / ".gitignore", "GhosttyKit.xcframework\nartifacts/\n")
        git(upstream, "add", "-A")
        git(upstream, "commit", "-q", "-m", "old")
        cls.old = git(upstream, "rev-parse", "HEAD")

        write(upstream / "BROKEN", "x\n")
        git(upstream, "add", "-A")
        git(upstream, "commit", "-q", "-m", "broken")
        cls.broken = git(upstream, "rev-parse", "HEAD")
        git(upstream, "rm", "-q", "BROKEN")

        git(upstream / "ghostty", "checkout", "-q", "main")
        write(upstream / "scripts/reload.sh", FAKE_RELOAD % {
            "extra_arm": "        bench-checks) config=bench-checks ;;", "define": " -DCMUX_BLOCKING_CHECKS"}, 0o755)
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

    def step(self, *args: str, labels: str = "cmux,measure") -> subprocess.CompletedProcess[str]:
        env = {**GIT_ENV, "PERF_LAB_BUILD_ROOT": str(self.cache / "perf-lab-build"),
               "FAKE_RELOAD_RUNS": str(self.runs), "CMUX_CI_LABELS": labels, "CMUX_CI_STEP_KEY": "step-1"}
        env.pop("CI_SHARED_CACHE_DIR", None)
        env.pop("PERF_LAB_BUILD_LOCKED", None)
        return subprocess.run(["bash", "scripts/measure/perf-lab-build.sh", *args], cwd=self.checkout, env=env,
                              capture_output=True, text=True, timeout=120)

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
        self.assertEqual(receipt["defines"], ["CMUX_BENCH_HOOKS"])  # OLD's reload.sh, not TIP's
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

    def test_a_cached_zip_that_is_gone_builds_again(self) -> None:
        first = self.receipt(self.step(f"--build-sha={self.old}"))
        (self.cache / f"perf-lab-build/v1/zips/{first['digest']}.zip").unlink()
        done = self.step(f"--build-sha={self.old}")
        self.assertEqual(done.returncode, 0, done.stdout + done.stderr)
        self.assertFalse(self.receipt(done)["cached"])
        self.assertEqual(len(self.reload_runs()), 2)

    def test_a_failed_build_is_recorded_once_and_never_retried(self) -> None:
        done = self.step(f"--build-sha={self.broken}")
        self.assertEqual(done.returncode, 1, done.stdout + done.stderr)
        receipt = self.receipt(done)
        self.assertEqual((receipt["status"], receipt["digest"]), ("failed", None))
        self.assertIn("cannot find 'x' in scope", receipt["reason"])
        again = self.step(f"--build-sha={self.broken}")
        self.assertEqual(again.returncode, 1)
        self.assertEqual(self.receipt(again)["status"], "failed")
        self.assertEqual(len(self.reload_runs()), 1)

    def test_bench_checks_of_a_commit_without_that_config_fails_once_without_building(self) -> None:
        done = self.step(f"--build-sha={self.old}", "--config=bench-checks")
        self.assertEqual(done.returncode, 1, done.stdout + done.stderr)
        self.assertIn("no --config bench-checks", self.receipt(done)["reason"])
        self.assertEqual(self.reload_runs(), [])
        # bench of the same commit is its own key and still builds.
        self.assertEqual(self.step(f"--build-sha={self.old}").returncode, 0)

    def test_bench_checks_at_tip(self) -> None:
        done = self.step(f"--build-sha={self.tip}", "--config=bench-checks")
        self.assertEqual(done.returncode, 0, done.stdout + done.stderr)
        receipt = self.receipt(done)
        self.assertEqual(receipt["defines"], ["CMUX_BENCH_HOOKS", "CMUX_BLOCKING_CHECKS"])
        self.assertEqual(self.reload_runs(), [f"{self.tip} bench-checks ghostty-2"])

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
