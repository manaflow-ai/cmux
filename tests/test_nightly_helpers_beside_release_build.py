#!/usr/bin/env python3
"""build-nightly-app keeps its helper builds off its serial path, and ships the same app.

Before, the job ran the web bundles, the OptChat Chief, the iPhone host and the
third-party notices one after another before xcodebuild (about 5 min a night,
up to 9). Now:
  - build-nightly-inputs builds the web bundles and the notices beside the app build
    from the resolved build commit, beside build-nightly-app, which never needs it, downloads each
    hand-off by pattern (a missing one is no error) and builds it itself unless
    it matches its checkout (scripts/ci/nightly_inputs.py);
  - the Chief and the iPhone host build in the background (scripts/ci/
    background_build.py) while xcodebuild runs, and a step right after it joins
    them and runs the Xcode phases' own bundle scripts on the app;
  - the notices replace the committed copy the Release build bundled, before
    the app is stripped, archived or uploaded.
This pins that structure and runs both scripts on fixtures.
"""

from __future__ import annotations

import hashlib
import importlib.util
import json
import re
import os
import subprocess
import sys
import tarfile
import tempfile
import time
import unittest
from pathlib import Path

import yaml

sys.path.insert(0, str(Path(__file__).resolve().parent))
from nightly_workflow_text import nightly_text  # noqa: E402  (moved step scripts put back inline)

ROOT = Path(__file__).resolve().parents[1]
WORKFLOW = ROOT / ".github/workflows/nightly.yml"
BACKGROUND = ROOT / "scripts/ci/background_build.py"
INPUTS = ROOT / "scripts/ci/nightly_inputs.py"

spec = importlib.util.spec_from_file_location("nightly_inputs", INPUTS)
nightly_inputs = importlib.util.module_from_spec(spec)
spec.loader.exec_module(nightly_inputs)

CHIEF = "Build the OptChat Chief (cmux-next)"
MOBILE = "Build the cmux-next iPhone host (cmux-mobile-host)"
WEB_DOWNLOAD = "Download the web bundles built beside the app (cmux-next)"
WEB_BUILD = "Build the web bundles (cmux-next)"
RELEASE = "Build nightly app (Release)"
BUNDLE = "Bundle the OptChat Chief and the iPhone host"
NOTICES_DOWNLOAD = "Download the third-party notices generated beside the app (cmux-next)"
NOTICES = "Generate third-party notices (cmux-next)"
STOP = "Stop the helper builds still running"
CEF = "Fetch the Chromium engine"
CEF_JOIN = "Finish fetching the Chromium engine"
# The only step allowed between the engine join and the Release build: it ends the
# run before the compile once a job publish needs has failed.
PUBLISH_CHECK = "Stop when the run can no longer publish (before the compile)"
INPUTS_JOB = "build-nightly-inputs"


class WorkflowStructureTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.jobs = yaml.safe_load(nightly_text())["jobs"]
        cls.app = cls.jobs["build-nightly-app"]
        cls.names = [step.get("name", "") for step in cls.app["steps"]]

    def step(self, name):
        return self.app["steps"][self.names.index(name)]

    def index(self, name):
        self.assertIn(name, self.names)
        return self.names.index(name)

    def test_inputs_job_builds_the_app_commit_holds_no_secret_and_runs_off_the_mac(self):
        job = self.jobs[INPUTS_JOB]
        self.assertEqual(job["needs"], ["decide", "resolve-nightly-cmux-tui-client"])
        self.assertEqual(job["steps"][0]["with"]["ref"], "${{ needs.resolve-nightly-cmux-tui-client.outputs.build_sha }}")
        self.assertNotIn("environment", job)
        self.assertEqual(job["permissions"], {"contents": "read"})
        self.assertIn("blacksmith-32vcpu-ubuntu-2404", job["runs-on"])
        self.assertNotIn("macos", job["runs-on"])
        self.assertNotIn("secrets.", yaml.safe_dump(job))
        uploads = [step["with"]["name"] for step in job["steps"] if "upload-artifact" in step.get("uses", "")]
        self.assertEqual(uploads, ["cmux-nightly-web-bundles", "cmux-nightly-notices"])
        names = [step.get("name", "") for step in job["steps"]]
        # The bundles go up first: the Mac takes them minutes before the notices.
        self.assertLess(names.index("Upload the web bundles"), names.index("Generate the third-party notices"))

    def test_the_app_build_never_waits_for_the_inputs_job(self):
        self.assertNotIn(INPUTS_JOB, self.app["needs"])
        for name, artifact in ((WEB_DOWNLOAD, "cmux-nightly-web-bundles"),
                               (NOTICES_DOWNLOAD, "cmux-nightly-notices")):
            step = self.step(name)
            self.assertIn("download-artifact", step["uses"])
            self.assertEqual(step["with"]["pattern"], artifact)
            self.assertNotIn("name", step["with"])
            self.assertTrue(step["continue-on-error"])

    def test_web_bundles_are_installed_right_before_the_release_build_with_a_local_fallback(self):
        self.assertLess(self.index(CHIEF), self.index(WEB_DOWNLOAD))
        self.assertLess(self.index(MOBILE), self.index(WEB_DOWNLOAD))
        self.assertLess(self.index("Fetch the Chromium engine"), self.index(WEB_DOWNLOAD))
        self.assertEqual(self.index(WEB_DOWNLOAD) + 1, self.index(WEB_BUILD))
        self.assertEqual(self.index(WEB_BUILD) + 1, self.index(CEF_JOIN))
        self.assertEqual(self.index(CEF_JOIN) + 1, self.index(PUBLISH_CHECK))
        self.assertEqual(self.index(PUBLISH_CHECK) + 1, self.index(RELEASE))
        run = self.step(WEB_BUILD)["run"]
        self.assertIn("nightly_inputs.py install-web", run)
        self.assertIn("scripts/cmux-next/build-web-bundles.sh --force", run)

    def test_the_engine_fetch_runs_in_the_background_and_is_joined_before_the_release_build(self):
        # It starts before the other pre-build steps, and only it holds the engine keys.
        self.assertLess(self.index(CEF), self.index("Start Release DerivedData empty"))
        self.assertLess(self.index("Wait through GitHub API rate limits in this job's gh calls"), self.index(CEF))
        fetch = self.step(CEF)
        self.assertIn("inputs.nightly_next_unsigned_run == ''", fetch["if"])
        run = fetch["run"]
        self.assertIn('background_build.py start --state "$RUNNER_TEMP/nightly-helper-builds" chromium-engine --', run)
        command = run[run.index("chromium-engine --"):]
        for script in ("ensure-cef.sh --optional\n", "ensure-cef.sh --optional --arch x86_64",
                       "ensure-remote-browser-host.sh --optional"):
            self.assertIn(script, command)
        self.assertIn("set -e", command)
        join = self.step(CEF_JOIN)
        self.assertEqual(join["if"], fetch["if"])
        self.assertIn('background_build.py join --state "$RUNNER_TEMP/nightly-helper-builds" chromium-engine', join["run"])
        for i, step in enumerate(self.app["steps"]):
            if i != self.index(CEF):
                self.assertNotIn("CMUX_CEF_R2", yaml.safe_dump(step.get("env", {})), step.get("name"))
        # Every track starts it, so every track's cleanup stops it.
        self.assertNotIn("track", self.step(STOP)["if"])
        self.assertIn("always()", self.step(STOP)["if"])

    def run_engine_fetch(self, failing):
        """Run the fetch step's own command and its join on stub fetch scripts; return the join."""
        with tempfile.TemporaryDirectory() as tmp:
            work = Path(tmp)
            (work / "scripts/cmux-next").mkdir(parents=True)
            (work / "scripts/ci").mkdir(parents=True)
            (work / "scripts/ci/background_build.py").write_bytes(BACKGROUND.read_bytes())
            for script in ("ensure-cef.sh", "ensure-remote-browser-host.sh"):
                stub = work / "scripts/cmux-next" / script
                status = 1 if script == failing else 0
                stub.write_text(f'#!/bin/bash\necho "{script} $*" >> "$RUNNER_TEMP/calls"\nexit {status}\n')
                stub.chmod(0o755)
            env = {**os.environ, "RUNNER_TEMP": str(work / "temp")}
            (work / "temp").mkdir()
            started = subprocess.run(["bash", "-e", "-c", self.step(CEF)["run"]], cwd=work, env=env,
                                     capture_output=True, text=True)
            self.assertEqual(started.returncode, 0, started.stderr)
            join = subprocess.run(["bash", "-e", "-c", self.step(CEF_JOIN)["run"]], cwd=work, env=env,
                                  capture_output=True, text=True, timeout=60)
            calls = (work / "temp/calls").read_text().splitlines() if (work / "temp/calls").exists() else []
            return join, calls

    def test_the_engine_join_succeeds_after_every_fetch_ran(self):
        join, calls = self.run_engine_fetch(failing=None)
        self.assertEqual(join.returncode, 0, join.stdout + join.stderr)
        self.assertEqual(calls, ["ensure-cef.sh --optional", "ensure-cef.sh --optional --arch x86_64",
                                 "ensure-remote-browser-host.sh --optional"])

    def test_a_failed_fetch_fails_the_join(self):
        # ensure-cef.sh exits 1 only when the store is unusable; the host script on a digest mismatch.
        for failing in ("ensure-cef.sh", "ensure-remote-browser-host.sh"):
            with self.subTest(failing=failing):
                join, _ = self.run_engine_fetch(failing=failing)
                self.assertNotEqual(join.returncode, 0, join.stdout + join.stderr)

    def test_chief_and_iphone_host_build_in_the_background_and_xcodebuild_never_sees_them(self):
        for name, script, env in ((CHIEF, "build-optchat-chief.sh", "OPTCHAT_CHIEF"),
                                  (MOBILE, "build-mobile-host.sh", "MOBILE_HOST")):
            with self.subTest(name=name):
                step = self.step(name)
                self.assertIn("inputs.nightly_next_unsigned_run == ''", step["if"])
                run = step["run"]
                self.assertIn("background_build.py start", run)
                command = run[run.index("background_build.py start"):]
                self.assertIn(script, command.split("\n", 2)[1], "the build script runs only inside the start command")
                self.assertEqual(run.count(script), 1)
                # Set for xcodebuild, these would make its phase require a binary still building.
                self.assertNotIn(f"CMUX_NEXT_{env}_BIN=", run.replace(f"CMUX_NEXT_{env}_PENDING_BIN=", ""))
                self.assertNotIn(f"CMUX_NEXT_REQUIRE_{env}", run)
        self.assertNotIn("CMUX_NEXT_OPTCHAT_CHIEF_BIN", self.step(RELEASE)["run"])

    def test_helpers_are_joined_and_bundled_right_after_the_release_build(self):
        self.assertEqual(self.index(RELEASE) + 1, self.index(BUNDLE))
        run = self.step(BUNDLE)["run"]
        for helper, script, require in (("optchat-chief", "bundle-optchat-chief.sh", "CMUX_NEXT_REQUIRE_OPTCHAT_CHIEF=1"),
                                        ("mobile-host", "bundle-mobile-host.sh", "CMUX_NEXT_REQUIRE_MOBILE_HOST=1")):
            self.assertIn(f"background_build.py join --state \"$state\" {helper}", run)
            self.assertLess(run.index(f"join --state \"$state\" {helper}"), run.index(script))
            self.assertIn(require, run)
        self.assertIn("UNLOCALIZED_RESOURCES_FOLDER_PATH=cmux.app/Contents/Resources", run)

    def test_notices_replace_the_bundled_copy_before_the_app_leaves_the_job(self):
        self.assertLess(self.index(RELEASE), self.index(NOTICES_DOWNLOAD))
        self.assertEqual(self.index(NOTICES_DOWNLOAD) + 1, self.index(NOTICES))
        for later in ("Strip unsigned nightly app before transfer", "Archive unsigned nightly app"):
            self.assertLess(self.index(NOTICES), self.index(later))
            self.assertLess(self.index(BUNDLE), self.index(later))
        run = self.step(NOTICES)["run"]
        self.assertIn("nightly_inputs.py install-notices", run)
        self.assertIn("generate-third-party-notices.sh --tui-source tree", run)
        self.assertIn("nightly_inputs.py bundle-notices build-universal/Build/Products/Release/cmux.app", run)

    def test_a_failed_or_cancelled_job_stops_the_background_builds(self):
        step = self.app["steps"][-1]
        self.assertEqual(step["name"], STOP)
        self.assertTrue(step["if"].startswith("always()"))
        self.assertIn("background_build.py stop", step["run"])


def background(*args, **kwargs):
    return subprocess.run([sys.executable, str(BACKGROUND), *args], capture_output=True, text=True, **kwargs)


class BackgroundBuildTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.state = Path(self.tmp.name) / "state"
        self.addCleanup(background, "stop", "--state", str(self.state))

    def start(self, name, script):
        result = background("start", "--state", str(self.state), name, "--", "sh", "-c", script)
        self.assertEqual(result.returncode, 0, result.stderr)
        return result

    def test_join_waits_for_the_build_and_prints_its_log(self):
        began = time.monotonic()
        self.start("chief", "sleep 1; echo built the chief")
        self.assertLess(time.monotonic() - began, 1, "start must not wait for the build")
        result = background("join", "--state", str(self.state), "chief")
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertGreaterEqual(time.monotonic() - began, 1)
        self.assertIn("built the chief", result.stdout)

    def test_a_failed_build_fails_the_join(self):
        self.start("mobile", "echo cargo failed >&2; exit 3")
        result = background("join", "--state", str(self.state), "mobile")
        self.assertEqual(result.returncode, 1)
        self.assertIn("cargo failed", result.stdout)
        self.assertIn("status 3", result.stdout)

    def test_a_build_that_never_started_fails_the_join(self):
        result = background("join", "--state", str(self.state), "chief")
        self.assertEqual(result.returncode, 1)
        self.assertIn("never started", result.stdout)

    def test_a_join_times_out(self):
        self.start("chief", "sleep 30")
        result = background("join", "--state", str(self.state), "chief", "--timeout", "1")
        self.assertEqual(result.returncode, 1)
        self.assertIn("did not finish within 1 s", result.stdout)

    def test_stop_kills_a_running_build_and_its_join_fails(self):
        self.start("chief", "sleep 30 & wait")
        began = time.monotonic()
        self.assertEqual(background("stop", "--state", str(self.state)).returncode, 0)
        result = background("join", "--state", str(self.state), "chief", "--timeout", "10")
        self.assertLess(time.monotonic() - began, 10)
        self.assertEqual(result.returncode, 1)
        self.assertIn("without a status", result.stdout)

    def test_stop_leaves_a_finished_build_alone(self):
        self.start("chief", "true")
        self.assertEqual(background("join", "--state", str(self.state), "chief").returncode, 0)
        self.assertNotIn("sent", background("stop", "--state", str(self.state)).stdout)

    def test_a_name_starts_once(self):
        self.start("chief", "true")
        again = background("start", "--state", str(self.state), "chief", "--", "true")
        self.assertEqual(again.returncode, 2)


def git(root, *args):
    subprocess.run(["git", "-C", str(root), *args], check=True, capture_output=True)


class NightlyInputsTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name) / "repo"
        (self.root / "scripts/cmux-next").mkdir(parents=True)
        (self.root / "THIRD_PARTY_LICENSES.md").write_text("committed notices\n")
        key = self.root / "scripts/cmux-next/web-bundle-key.py"
        key.write_text("import os\nprint(os.environ.get('FAKE_KEY', 'key-a'))\n")
        builder = self.root / "scripts/cmux-next/build-web-bundles.sh"
        builder.write_text('#!/bin/sh\nset -eu\n[ "$1" = --from ] && find "$2" -type f | sort > "$(dirname "$0")/installed.txt"\n')
        builder.chmod(0o755)
        for relative in nightly_inputs.WEB_OUTPUTS:
            path = self.root / relative
            if relative.endswith((".js", ".html")):
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text(f"{relative}\n")
            else:
                path.mkdir(parents=True)
                (path / "index.html").write_text(f"{relative}\n")
        git(self.root, "init", "-q")
        git(self.root, "add", "-A")
        git(self.root, "-c", "user.name=t", "-c", "user.email=t@t", "commit", "-qm", "fixture")
        self.addCleanup(setattr, nightly_inputs, "ROOT", nightly_inputs.ROOT)
        nightly_inputs.ROOT = self.root
        self.handoff = Path(self.tmp.name) / "handoff"

    def test_web_bundles_round_trip_when_the_source_key_matches(self):
        nightly_inputs.pack_web(self.handoff, "key-a")
        nightly_inputs.install_web(self.handoff)
        installed = (self.root / "scripts/cmux-next/installed.txt").read_text()
        self.assertEqual(installed.count("\n"), len(nightly_inputs.WEB_OUTPUTS))

    def test_the_hand_off_carries_every_path_build_web_bundles_from_requires(self):
        script = (ROOT / "scripts/cmux-next/build-web-bundles.sh").read_text()
        names = dict(re.findall(r'^([A-Z]+)="([^"$]+)"$', script, re.M))
        loop = re.search(r'^  for path in (.+); do\n    \[ -e "\$FROM_ROOT/\$path" \]', script, re.M)
        self.assertIsNotNone(loop, "build-web-bundles.sh --from's required-path loop moved")
        required = set()
        for word in loop.group(1).split():
            match = re.fullmatch(r'"\$([A-Z]+)(/[^"]*)?"', word)
            self.assertIsNotNone(match, word)
            required.add(names[match.group(1)] + (match.group(2) or ""))
        self.assertEqual(required, set(nightly_inputs.WEB_OUTPUTS))

    def test_web_bundles_of_another_source_key_are_not_used(self):
        nightly_inputs.pack_web(self.handoff, "key-b")
        with self.assertRaises(nightly_inputs.NotUsable):
            nightly_inputs.install_web(self.handoff)

    def test_a_changed_archive_is_not_used(self):
        nightly_inputs.pack_web(self.handoff, "key-a")
        with (self.handoff / nightly_inputs.WEB_TAR).open("ab") as archive:
            archive.write(b"\0" * 512)
        with self.assertRaises(nightly_inputs.NotUsable):
            nightly_inputs.install_web(self.handoff)

    def test_an_archive_member_outside_the_outputs_is_refused(self):
        self.handoff.mkdir()
        evil = Path(self.tmp.name) / "evil"
        evil.write_text("x")
        with tarfile.open(self.handoff / nightly_inputs.WEB_TAR, "w") as archive:
            archive.add(evil, arcname="Resources/markdown-viewer/webviews-app/../../../escape")
        digest = hashlib.sha256((self.handoff / nightly_inputs.WEB_TAR).read_bytes()).hexdigest()
        (self.handoff / nightly_inputs.WEB_RECORD).write_text(json.dumps({"source_key": "key-a", "sha256": digest}))
        with self.assertRaises(nightly_inputs.NotUsable):
            nightly_inputs.install_web(self.handoff)
        self.assertFalse((self.root.parent / "escape").exists())

    def test_no_hand_off_exits_3_so_the_step_builds_here(self):
        result = subprocess.run([sys.executable, str(INPUTS), "install-web", str(self.handoff)],
                                capture_output=True, text=True)
        self.assertEqual(result.returncode, 3, result.stdout + result.stderr)
        result = subprocess.run([sys.executable, str(INPUTS), "install-notices", str(self.handoff)],
                                capture_output=True, text=True)
        self.assertEqual(result.returncode, 3, result.stdout + result.stderr)

    def test_notices_are_taken_only_from_this_commit(self):
        (self.root / "THIRD_PARTY_LICENSES.md").write_text("tree notices\n")
        nightly_inputs.pack_notices(self.handoff)
        git(self.root, "checkout", "-q", "--", "THIRD_PARTY_LICENSES.md")
        nightly_inputs.install_notices(self.handoff)
        self.assertEqual((self.root / "THIRD_PARTY_LICENSES.md").read_text(), "tree notices\n")
        git(self.root, "-c", "user.name=t", "-c", "user.email=t@t", "commit", "-qam", "next")
        with self.assertRaises(nightly_inputs.NotUsable):
            nightly_inputs.install_notices(self.handoff)

    def test_bundle_notices_replaces_only_the_committed_copy(self):
        app = Path(self.tmp.name) / "cmux.app"
        bundled = app / nightly_inputs.APP_NOTICES
        bundled.parent.mkdir(parents=True)
        bundled.write_text("committed notices\n")
        os.chmod(bundled, 0o600)
        (self.root / "THIRD_PARTY_LICENSES.md").write_text("tree notices\n")
        nightly_inputs.bundle_notices(app)
        self.assertEqual(bundled.read_text(), "tree notices\n")
        self.assertEqual(bundled.stat().st_mode & 0o777, 0o644)
        with self.assertRaises(SystemExit):
            nightly_inputs.bundle_notices(app)


if __name__ == "__main__":
    unittest.main()
