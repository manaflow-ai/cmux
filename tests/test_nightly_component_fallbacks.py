#!/usr/bin/env python3
"""No single nightly component's failure holds the publish; each is a visible stale part instead.

Leo, 2026-11-25: "are we able to decouple". The do-list: "No single component's failure blocks the publish.
Webview checks, the cmux-tui client, the iPhone host and the visual gate each fall back to their last good
artifact and publish with a visible 'stale part' note on NOW, or run as non-blocking reports. Only "the app
doesn't launch or isn't signed" blocks. Default ON." vars.NIGHTLY_COMPONENT_GATES=block restores the old hold.
"""
from __future__ import annotations

import os
import re
import shutil
import subprocess
import tempfile
import time
import unittest
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]
WORKFLOW = ROOT / ".github/workflows/nightly.yml"
STEPS = ROOT / "scripts/ci/nightly-steps"
DECOUPLED = "${{ vars.NIGHTLY_COMPONENT_GATES != 'block' }}"


def one_line(value) -> str:
    return re.sub(r"\s+", " ", str(value or "")).strip()


class WorkflowTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.jobs = yaml.safe_load(WORKFLOW.read_text(encoding="utf-8"))["jobs"]

    def step(self, job: str, **match) -> dict:
        for step in self.jobs[job]["steps"]:
            if all(step.get(k) == v for k, v in match.items()):
                return step
        self.fail(f"{job} has no step {match}")

    def test_early_webview_red_is_a_report_by_default(self) -> None:
        job = self.jobs["early-nightly-webviews"]
        self.assertEqual(self.step("early-nightly-webviews", id="checks").get("continue-on-error"), DECOUPLED)
        red = one_line(job["outputs"]["red_sha"])
        self.assertIn("vars.NIGHTLY_COMPONENT_GATES == 'block' && steps.checks.outcome == 'failure'", red)
        notes = [s for s in job["steps"] if "stale-part.sh webview-checks" in str(s.get("run", ""))]
        self.assertEqual(len(notes), 1, "a red check leaves a stale-part note")

    def test_one_job_webview_join_does_not_fail_the_build(self) -> None:
        job = self.jobs["nightly-next-one"]
        self.assertEqual(self.step("nightly-next-one", id="webview-checks").get("continue-on-error"), DECOUPLED)
        self.assertIn("vars.NIGHTLY_COMPONENT_GATES == 'block'", one_line(job["outputs"]["webview_red"]))
        # continue-on-error leaves failure() false, so the fixit hand-off reads the step's outcome.
        self.assertEqual(one_line(self.step("nightly-next-one", id="fixit-nofix")["if"]),
                         "${{ !cancelled() && steps.webview-checks.outcome == 'failure' }}")
        self.assertEqual(job["env"].get("NIGHTLY_COMPONENT_GATES"), "${{ vars.NIGHTLY_COMPONENT_GATES }}")

    def test_both_publication_gates_read_the_switch(self) -> None:
        for job in ("publish-nightly", "nightly-next-one"):
            gate = self.step(job, id="gate")
            self.assertEqual(gate["env"].get("NIGHTLY_COMPONENT_GATES"), "${{ vars.NIGHTLY_COMPONENT_GATES }}", job)

    def test_resolve_checks_out_again_into_a_fresh_store(self) -> None:
        steps = self.jobs["resolve-nightly-cmux-tui-client"]["steps"]
        first = next(i for i, s in enumerate(steps) if s.get("id") == "checkout")
        self.assertIs(steps[first].get("continue-on-error"), True)
        drop, again = steps[first + 1], steps[first + 2]
        self.assertEqual(drop["if"], "steps.checkout.outcome == 'failure'")
        self.assertIn('rm -rf "$GITHUB_WORKSPACE/.git"', drop["run"])
        self.assertEqual(again["if"], "steps.checkout.outcome == 'failure'")
        self.assertTrue(again["uses"].startswith("actions/checkout@"))
        self.assertEqual(again["with"]["ref"], steps[first]["with"]["ref"])

    def test_visual_gate_never_holds_the_publish(self) -> None:
        for job in ("publish-nightly", "nightly-next-one"):
            needs = self.jobs[job].get("needs") or []
            self.assertFalse([n for n in needs if "visual" in n], f"{job} must not wait on the visual gate")


def run(cmd, cwd, env=None) -> subprocess.CompletedProcess:
    full = {**os.environ, **(env or {})}
    return subprocess.run(cmd, cwd=cwd, env=full, capture_output=True, text=True, check=False)


class ScriptTests(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.tmp)
        self.summary = self.tmp / "summary.md"
        self.env = {"GITHUB_STEP_SUMMARY": str(self.summary), "RUNNER_TEMP": str(self.tmp)}

    def test_stale_part_writes_annotation_summary_and_record(self) -> None:
        out = run(["bash", str(STEPS / "stale-part.sh"), "cmux-mobile-host", "failed\nto build"], self.tmp, self.env)
        self.assertEqual(out.returncode, 0, out.stderr)
        self.assertEqual(out.stdout.strip(), "::warning title=Nightly stale part::cmux-mobile-host: failed to build")
        self.assertIn("stale part, cmux-mobile-host: failed to build", self.summary.read_text())
        self.assertEqual((self.tmp / "nightly-stale-parts").read_text(), "cmux-mobile-host\tfailed to build\n")

    def make_host(self, key: str, arch: str, age: int) -> Path:
        path = self.tmp / "cache" / key / arch / "cmux-mobile-host"
        path.parent.mkdir(parents=True)
        path.write_text(key)
        path.chmod(0o755)
        then = time.time() - age
        os.utime(path, (then, then))
        return path

    def test_last_good_host_is_the_newest_of_the_arch(self) -> None:
        self.make_host("old", "arm64", 300)
        newest = self.make_host("new", "arm64", 10)
        self.make_host("other", "arm64-x86_64", 1)
        env = {"CMUX_NEXT_MOBILE_HOST_CACHE": str(self.tmp / "cache")}
        out = run(["bash", str(STEPS / "last-good-mobile-host.sh"), "arm64"], self.tmp, env)
        self.assertEqual((out.returncode, out.stdout.strip()), (0, str(newest)), out.stderr)
        out = run(["bash", str(STEPS / "last-good-mobile-host.sh"), "x86_64"], self.tmp, env)
        self.assertEqual((out.returncode, out.stdout), (1, ""))

    def bundle_tree(self, host_status: int) -> Path:
        """A tree with the bundle step script and stubs: the background joins and the phase scripts."""
        tree = self.tmp / "tree"
        (tree / "scripts/ci/nightly-steps").mkdir(parents=True)
        (tree / "scripts/cmux-next").mkdir(parents=True)
        (tree / "build-universal/Build/Products/Release/cmux.app/Contents/Resources").mkdir(parents=True)
        for name in ("app-bundle-chief-and-mobile-host.sh", "stale-part.sh", "last-good-mobile-host.sh"):
            shutil.copy(STEPS / name, tree / "scripts/ci/nightly-steps" / name)
        (tree / "scripts/ci/background_build.py").write_text(
            "import sys\nsys.exit(%d if sys.argv[-1] == 'mobile-host' else 0)\n" % host_status)
        for name in ("bundle-optchat-chief.sh", "bundle-mobile-host.sh", "bundle-screen-sharing-helper.sh"):
            stub = tree / "scripts/cmux-next" / name
            stub.write_text(f'#!/usr/bin/env bash\necho "{name} ${{CMUX_NEXT_MOBILE_HOST_BIN:-}}" >> "$RUNNER_TEMP/bundled"\n')
            stub.chmod(0o755)
        return tree

    def bundle(self, tree: Path, **extra) -> subprocess.CompletedProcess:
        env = {**self.env, "NIGHTLY_COMPILE_ARCHS": "arm64", "CMUX_NEXT_OPTCHAT_CHIEF_PENDING_BIN": "/chief",
               "CMUX_NEXT_MOBILE_HOST_PENDING_BIN": "/host", "CMUX_NEXT_SCREEN_HELPER_PENDING_BIN": "/screen",
               "CMUX_NEXT_MOBILE_HOST_CACHE": str(self.tmp / "cache"), "NIGHTLY_COMPONENT_GATES": "", **extra}
        return run(["bash", "scripts/ci/nightly-steps/app-bundle-chief-and-mobile-host.sh"], tree, env)

    def bundled(self) -> str:
        return (self.tmp / "bundled").read_text()

    def test_a_built_host_bundles_as_before(self) -> None:
        out = self.bundle(self.bundle_tree(0))
        self.assertEqual(out.returncode, 0, out.stderr)
        self.assertIn("bundle-mobile-host.sh /host", self.bundled())
        self.assertNotIn("stale part", out.stdout)

    def test_a_failed_host_bundles_the_last_good_one(self) -> None:
        cached = self.make_host("prev", "arm64", 5)
        out = self.bundle(self.bundle_tree(1))
        self.assertEqual(out.returncode, 0, out.stderr)
        self.assertIn(f"bundle-mobile-host.sh {cached}", self.bundled())
        self.assertIn("::warning title=Nightly stale part::cmux-mobile-host: the iPhone host failed to build; "
                      "bundled the last good one", out.stdout)
        self.assertIn("bundle-screen-sharing-helper.sh", self.bundled(), "the steps after it still run")

    def test_a_failed_host_with_no_cache_ships_without_it(self) -> None:
        out = self.bundle(self.bundle_tree(1))
        self.assertEqual(out.returncode, 0, out.stderr)
        self.assertNotIn("bundle-mobile-host.sh", self.bundled())
        self.assertIn("ships without iPhone connections", out.stdout)

    def test_block_restores_the_hold(self) -> None:
        self.make_host("prev", "arm64", 5)
        out = self.bundle(self.bundle_tree(1), NIGHTLY_COMPONENT_GATES="block")
        self.assertNotEqual(out.returncode, 0)
        self.assertNotIn("bundle-mobile-host.sh", self.bundled())

    def test_publish_gate_notes_a_red_webview_check_instead_of_refusing(self) -> None:
        text = (STEPS / "publish-final-gate.sh").read_text()
        soft = text.index('[ "${NIGHTLY_COMPONENT_GATES:-}" != block ]')
        self.assertLess(soft, text.index('refuse "${verdict:-the webview check verdict is unreadable}"'))
        self.assertIn("::warning title=Nightly stale part::webview-checks:", text)
        # The App Store shelf no longer holds a publish (Leo, 2026-11-25); report-nightly-shelf-red files its red.
        self.assertNotIn("App Store shelf verdict is unreadable", text)


if __name__ == "__main__":
    unittest.main()
