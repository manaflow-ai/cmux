#!/usr/bin/env python3
"""Two slow nightly steps run in the background, and their result still gates the job.

prepare-nightly-variant scans every file of the bundle for browser-data import
targets (cx-f58x, 93-121 s), and build-nightly-app uploads the dSYMs to Sentry
(38-39 s on the serialized warm slot). Both used to block every step after
them. Each now starts in the background and a later "Finish" step reads its
status from a FIFO: the scan runs on a clone of the bundle taken before the
later steps change it, and its failure still fails the job before the prepared
app is uploaded. The Sentry upload stays non-fatal, as before.
"""

from pathlib import Path
import os
import re
import shutil
import subprocess
import tempfile
import unittest

import yaml


ROOT = Path(__file__).resolve().parents[1]
WORKFLOW = ROOT / ".github/workflows/nightly.yml"
CHECKER = ROOT / "scripts/ci/check-browser-data-import-absent.sh"
APP = "build-universal/Build/Products/Release/cmux.app"

PROOF_START = "Prove the browser-data import is compiled out (cx-f58x notary test)"
PROOF_FINISH = "Finish the browser-data import proof"
SENTRY_START = "Upload dSYMs to Sentry"
SENTRY_FINISH = "Finish the dSYM upload to Sentry"
PREPARE_JOBS = ("prepare-nightly-variant-primary", "prepare-nightly-variant")


def steps(job: str) -> list[dict]:
    return yaml.safe_load(WORKFLOW.read_text())["jobs"][job]["steps"]


def step(job: str, name: str) -> dict:
    return next(s for s in steps(job) if s.get("name") == name)


def index(job: str, name: str) -> int:
    return next(i for i, s in enumerate(steps(job)) if s.get("name") == name)


class BackgroundStepTests(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.tmp, ignore_errors=True)
        self.ws = self.tmp / "ws"
        (self.ws / "scripts/ci").mkdir(parents=True)
        (self.ws / APP / "Contents/MacOS").mkdir(parents=True)
        (self.ws / APP / "Contents/MacOS/cmux").write_text("cmux Safe Storage\n")
        shutil.copy(CHECKER, self.ws / "scripts/ci" / CHECKER.name)
        self.runner_temp = self.tmp / "runner-temp"
        self.runner_temp.mkdir()
        self.path = os.environ["PATH"]
        if shutil.which("ditto") is None:
            # This test runs on Linux, where cp -c is not clonefile(2) and
            # ditto, the step's fallback copy, does not exist.
            shim = self.tmp / "bin"
            shim.mkdir()
            (shim / "ditto").write_text('#!/bin/sh\nexec cp -a "$1" "$2"\n')
            (shim / "ditto").chmod(0o755)
            self.path = f"{shim}{os.pathsep}{self.path}"

    def run_step(self, job: str, name: str) -> subprocess.CompletedProcess:
        # Each step is its own shell, as on the runner: the background job
        # outlives the step that started it.
        env = {**os.environ, "PATH": self.path, "RUNNER_TEMP": str(self.runner_temp)}
        run = step(job, name)["run"]
        # A step whose block moved to scripts/ci/nightly-steps/ calls it from the job's checkout.
        for moved in re.findall(r"scripts/ci/nightly-steps/[A-Za-z0-9_.-]+\.sh", run):
            (self.ws / moved).parent.mkdir(parents=True, exist_ok=True)
            shutil.copy(ROOT / moved, self.ws / moved)
        return subprocess.run(["bash", "-e", "-c", run], cwd=self.ws, env=env,
                              text=True, capture_output=True, timeout=60)

    def test_the_proof_finishes_before_the_prepared_app_is_uploaded(self):
        for job in PREPARE_JOBS:
            with self.subTest(job=job):
                start, finish = index(job, PROOF_START), index(job, PROOF_FINISH)
                self.assertLess(start, index(job, "Inject universal Ghostty CLI helper"))
                self.assertLess(index(job, "Package prepared app for signing"), finish)
                self.assertLess(finish, index(job, "Upload prepared app for signing"))
                self.assertEqual(step(job, PROOF_START)["if"], step(job, PROOF_FINISH)["if"])
                self.assertNotIn("continue-on-error", step(job, PROOF_FINISH))

    def test_a_clean_bundle_passes_even_when_later_steps_add_files(self):
        for job in PREPARE_JOBS:
            with self.subTest(job=job):
                started = self.run_step(job, PROOF_START)
                self.assertEqual(started.returncode, 0, started.stderr)
                # A later step changes the original; the proof read the bundle as it was.
                added = self.ws / APP / "Contents/MacOS/added"
                added.write_text("Login Data\n")
                finished = self.run_step(job, PROOF_FINISH)
                self.assertEqual(finished.returncode, 0, finished.stdout + finished.stderr)
                self.assertIn("browser-data import targets absent", finished.stdout)
                self.assertFalse((self.runner_temp / "browser-data-proof").exists())
                added.unlink()

    def test_a_bundle_with_a_browser_target_fails_the_finish_step(self):
        (self.ws / APP / "Contents/MacOS/cmux").write_text("Chrome Safe Storage\n")
        for job in PREPARE_JOBS:
            with self.subTest(job=job):
                started = self.run_step(job, PROOF_START)
                self.assertEqual(started.returncode, 0, started.stderr)
                finished = self.run_step(job, PROOF_FINISH)
                self.assertNotEqual(finished.returncode, 0, finished.stdout)
                self.assertIn("Chrome Safe Storage", finished.stdout)
                self.assertIn("the browser-data import proof failed", finished.stderr)

    def test_the_proof_scans_the_installed_cmux_tui_client(self):
        # build-nightly-app installs the client before prepare; a browser target
        # list in bin/cmux (or its companions) fails the proof like any other file.
        bin_dir = self.ws / APP / "Contents/Resources/bin"
        for name in ("cmux", "cmux-tui", "cmux-app-host", "cmux-tui-ssh/cmux-tui-x86_64-unknown-linux-musl"):
            with self.subTest(binary=name):
                target = bin_dir / name
                target.parent.mkdir(parents=True, exist_ok=True)
                target.write_text("Chrome Safe Storage\n")
                for job in PREPARE_JOBS:
                    started = self.run_step(job, PROOF_START)
                    self.assertEqual(started.returncode, 0, started.stderr)
                    finished = self.run_step(job, PROOF_FINISH)
                    self.assertNotEqual(finished.returncode, 0, finished.stdout)
                    self.assertIn(f"Contents/Resources/bin/{name}", finished.stdout)
                target.unlink()

    def test_a_resumed_unsigned_app_is_proven_too(self):
        # A resume (nightly_next_unsigned_run) restores a saved unsigned app,
        # client included, in prepare; the proof scans it like a fresh build.
        for job in PREPARE_JOBS:
            for name in (PROOF_START, PROOF_FINISH):
                with self.subTest(job=job, step=name):
                    self.assertNotIn("nightly_next_unsigned_run", step(job, name)["if"])

    def test_a_finish_without_a_start_fails(self):
        for job in PREPARE_JOBS:
            with self.subTest(job=job):
                finished = self.run_step(job, PROOF_FINISH)
                self.assertNotEqual(finished.returncode, 0)
                self.assertIn("never started", finished.stderr)

    def test_the_sentry_upload_overlaps_the_artifact_uploads_and_stays_non_fatal(self):
        job = "build-nightly-app"
        self.assertLess(index(job, SENTRY_START), index(job, "Archive unsigned nightly app"))
        self.assertLess(index(job, "Keep the nightly-next dSYMs for publication"), index(job, SENTRY_FINISH))
        self.assertEqual(step(job, SENTRY_START)["if"], step(job, SENTRY_FINISH)["if"])
        self.assertIs(step(job, SENTRY_START)["continue-on-error"], True)
        self.assertIs(step(job, SENTRY_FINISH)["continue-on-error"], True)
        uploader = self.ws / "scripts/upload-sentry-dsyms.sh"
        for status, ok in ((0, True), (3, False)):
            with self.subTest(status=status):
                uploader.write_text(f'#!/bin/bash\necho "uploaded $*"\nexit {status}\n')
                uploader.chmod(0o755)
                started = self.run_step(job, SENTRY_START)
                self.assertEqual(started.returncode, 0, started.stderr)
                finished = self.run_step(job, SENTRY_FINISH)
                self.assertIn("uploaded build-universal/Build/Products/Release/", finished.stdout)
                self.assertEqual(finished.returncode == 0, ok, finished.stderr)


if __name__ == "__main__":
    unittest.main()
