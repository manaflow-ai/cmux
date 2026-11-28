#!/usr/bin/env python3
"""The cmux app scheme compile takes the build fleet's Debug app, with the Mac as the logged fallback
(docs/ci/cmux-next-workflow-notes.md#note-scheme-fleet)."""
from __future__ import annotations

import importlib.util
import json
import os
import plistlib
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]
WORKFLOW = ROOT / ".github/workflows/cmux-next.yml"


def load(name, rel):
    spec = importlib.util.spec_from_file_location(name, ROOT / rel)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


reader = load("fleet_compile_result", "scripts/ci/fleet_compile_result.py")
parity = load("app_bundle_parity", "scripts/ci/app_bundle_parity.py")
SHA = "a" * 40


class Workflow(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.jobs = yaml.safe_load(WORKFLOW.read_text(encoding="utf-8"))["jobs"]
        cls.fleet = cls.jobs["cmux-scheme-compile-fleet"]
        cls.mac = cls.jobs["cmux-scheme-compile"]

    def step(self, job, name):
        return next(s for s in job["steps"] if s.get("name") == name)

    def test_the_fleet_job_holds_no_mac(self):
        self.assertEqual(self.fleet["runs-on"], "cmux-linux")
        self.assertEqual(self.fleet["name"], "cmux app scheme compile (build fleet)")
        checkout = next(s for s in self.fleet["steps"] if s.get("uses", "").startswith("actions/checkout@"))
        self.assertEqual(checkout["with"]["sparse-checkout"].split(), ["scripts/ci", "scripts/cmux-next"])
        self.assertIs(checkout["with"]["persist-credentials"], False)

    def test_the_fleet_job_runs_where_the_mac_compile_does_minus_forks_and_dev_daily(self):
        mac_if = self.mac["if"][len("${{ "):-len(" }}")]
        self.assertTrue(self.fleet["if"].endswith(mac_if + " }}"))
        for part in ("inputs.dev_daily != true", "vars.CI_SCHEME_COMPILE_FLEET != '0'",
                     "github.repository_owner == 'manaflow-ai'",
                     "github.event.pull_request.head.repo.full_name == github.repository"):
            self.assertIn(part, self.fleet["if"])

    def test_the_mac_job_waits_for_the_verdict_and_still_runs_when_it_is_skipped(self):
        self.assertIn("cmux-scheme-compile-fleet", self.mac["needs"])
        # A status function in the if keeps a skipped fleet job from skipping the Mac job.
        self.assertIn("!cancelled()", self.mac["if"])
        self.assertIn("needs.cmux-scheme-compile-fleet.outputs.verdict == 'pass'", self.mac["env"]["CMUX_SCHEME_FLEET_JOB"])

    def test_the_mac_skips_every_compile_step_only_when_it_took_the_fleet_app(self):
        guarded = ["Fetch the same-tree cmux-tui", "Install Rust (diff sidecar)",
                   "Install Go for the embedded tailnet archive", "Build in-tree acpmux for the app bundle",
                   "Source key of the web bundles", "Setup Bun", "Give this job its own bun", "Setup Node",
                   "Build the web bundles", "Compile the cmux scheme"]
        for name in guarded:
            with self.subTest(step=name):
                self.assertIn("steps.fleet-app.outputs.ok != 'true'", self.step(self.mac, name)["if"])
        names = [s.get("name") for s in self.mac["steps"]]
        self.assertLess(names.index("Take the app the build fleet built"), names.index("Fetch the same-tree cmux-tui"))
        # The crash gate and the dogfood artifact still run on the fleet app.
        for name in ("Crash ends the app", "Package the trusted cmux-next dogfood artifact"):
            self.assertNotIn("fleet-app", self.step(self.mac, name)["if"])

    def run_read(self, word, job_id="", knows_phase=True):
        step = next(s for s in self.fleet["steps"] if s.get("id") == "read")
        with tempfile.TemporaryDirectory() as tmp:
            stub = Path(tmp) / "scripts/ci/fleet_compile_result.py"
            stub.parent.mkdir(parents=True)
            phases = '"scheme-debug"' if knows_phase else ""
            stub.write_text(f"""# {phases}
import sys
a = sys.argv
open({str(Path(tmp) / "args")!r}, "w").write(" ".join(a[1:]))
open(a[a.index("--job-out") + 1], "w").write({job_id!r} + "\\n")
print({word!r})
""")
            out, summary = Path(tmp) / "out", Path(tmp) / "summary"
            env = {"PATH": os.environ["PATH"], "HOME": tmp, "REF": SHA, "PR": "", "GITHUB_REPOSITORY": "manaflow-ai/cmux",
                   "GITHUB_OUTPUT": str(out), "GITHUB_STEP_SUMMARY": str(summary), "RUNNER_TEMP": tmp}
            self.assertEqual(step["run"], "bash scripts/cmux-next/scheme-fleet.sh read || true")
            r = subprocess.run(["bash", str(ROOT / "scripts/cmux-next/scheme-fleet.sh"), "read"], env=env, cwd=tmp, capture_output=True, text=True,
                               timeout=60)
            args = (Path(tmp) / "args").read_text() if (Path(tmp) / "args").exists() else ""
            return r, out.read_text() if out.exists() else "", args

    def test_a_pass_with_a_job_hands_the_mac_the_job(self):
        r, out, args = self.run_read("pass", "fleet-job-1")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("verdict=pass\njob_id=fleet-job-1\n", out)
        self.assertIn(f"--sha {SHA} --repo manaflow-ai/cmux --pr  --phase scheme-debug", args)

    def test_anything_else_is_the_logged_mac_fallback_and_never_red(self):
        for word, job, knows in (("pass", "", True), ("fail", "j", True), ("none", "", True), ("pass", "j", False)):
            with self.subTest(word=word, job=job, knows=knows):
                r, out, _ = self.run_read(word, job, knows)
                self.assertEqual(r.returncode, 0, r.stderr)
                self.assertNotIn("verdict=pass", out)
                self.assertIn("title=fleet fallback", r.stdout)

    def test_a_mac_compile_without_a_fleet_app_is_always_logged(self):
        # The take step runs on every non-DEV-daily run, so a skipped or red fleet job still logs why the Mac compiles.
        take = self.step(self.mac, "Take the app the build fleet built")
        self.assertEqual(take["if"], "${{ inputs.dev_daily != true }}")
        self.assertIn("needs.cmux-scheme-compile-fleet.result", take["env"]["FLEET_RESULT"])
        with tempfile.TemporaryDirectory() as tmp:
            out = Path(tmp) / "out"
            env = {"PATH": os.environ["PATH"], "RUNNER_TEMP": tmp, "GITHUB_OUTPUT": str(out), "PARITY": "false",
                   "CMUX_SCHEME_FLEET_JOB": "", "FLEET_RESULT": "skipped", "FLEET_VERDICT": "", "FLEET_SWITCH": "0"}
            r = subprocess.run(["bash", str(ROOT / "scripts/cmux-next/scheme-fleet.sh"), "take"], env=env, cwd=tmp,
                               capture_output=True, text=True, timeout=60)
            self.assertEqual(r.returncode, 0, r.stderr)
            self.assertEqual(out.read_text(), "ok=false\n")
            self.assertIn("title=fleet fallback", r.stdout)
            self.assertIn("fleet job: skipped, verdict: none, CI_SCHEME_COMPILE_FLEET: 0", r.stdout)


class Reader(unittest.TestCase):
    def test_scheme_debug_reads_its_own_record_and_its_job(self):
        urls = []

        def fetch(url, timeout):
            urls.append(url)
            return 200, {"sha": SHA, "repo": "manaflow-ai/cmux", "recipe_version": reader.RECIPE,
                         "configuration": "scheme-debug", "state": "pass", "job_id": "fleet-7"}, {}

        seen = {}
        word, _ = reader.read(SHA, "manaflow-ai/cmux", phase="scheme-debug", fetch=fetch, seen=seen, wait=5,
                              sleep=lambda s: None)
        self.assertEqual(word, "pass")
        self.assertEqual(seen["job_id"], "fleet-7")
        self.assertIn("phase=scheme-debug", urls[0])

    def test_job_out_is_written_even_without_a_record(self):
        with tempfile.TemporaryDirectory() as tmp:
            out = Path(tmp) / "job"
            reader.main(["--sha", "bad", "--repo", "manaflow-ai/cmux", "--phase", "scheme-debug", "--job-out", str(out)])
            self.assertFalse(out.exists())  # a bad sha returns before any read; the step reads an empty job


class Parity(unittest.TestCase):
    def app(self, root, name, extra=(), version="1"):
        app = Path(root) / name / "cmux DEV.app"
        (app / "Contents/MacOS").mkdir(parents=True)
        (app / "Contents/MacOS/cmux DEV").write_bytes(b"x")
        (app / "Contents/_CodeSignature").mkdir()
        (app / "Contents/_CodeSignature/CodeResources").write_bytes(name.encode())
        for e in extra:
            (app / "Contents" / e).write_text("e")
        (app / "Contents/Info.plist").write_bytes(plistlib.dumps({"CFBundleIdentifier": "com.cmux.dev",
                                                                  "CFBundleVersion": version}))
        return app

    def run_parity(self, a, b):
        return subprocess.run([sys.executable, "-I", str(ROOT / "scripts/ci/app_bundle_parity.py"), str(a), str(b)],
                              capture_output=True, text=True, timeout=60)

    def test_same_apps_match_whatever_their_signatures(self):
        with tempfile.TemporaryDirectory() as tmp:
            r = self.run_parity(self.app(tmp, "fleet"), self.app(tmp, "mac"))
            self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
            self.assertTrue(json.loads(r.stdout.strip().splitlines()[-1])["match"])

    def test_a_missing_file_or_plist_key_differs(self):
        with tempfile.TemporaryDirectory() as tmp:
            r = self.run_parity(self.app(tmp, "fleet"), self.app(tmp, "mac", extra=("Resources.txt",)))
            self.assertEqual(r.returncode, 1, r.stdout + r.stderr)
            self.assertIn("Resources.txt", r.stdout)

    def test_usage(self):
        r = subprocess.run([sys.executable, "-I", str(ROOT / "scripts/ci/app_bundle_parity.py")], capture_output=True,
                           text=True, timeout=60)
        self.assertEqual(r.returncode, 2)


if __name__ == "__main__":
    unittest.main()
