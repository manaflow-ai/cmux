#!/usr/bin/env python3
"""Nightly routing uses pooled capacity and never a reserved host.

Native work follows the dev-build route: an owned controller-managed Mac pool
first, then the trusted Blacksmith macOS pool. Control, verification and
publication steps use the Linux pool. A nightly may not name a runner-specific
label or rely on the old dedicated builder tuple.
"""

from __future__ import annotations

import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
WORKFLOWS = ROOT / ".github" / "workflows"

SINGLE_HOST = re.compile(r"cmux22|glaeda-runner-[a-z0-9][a-z0-9-]*", re.IGNORECASE)
OLD_NIGHTLY_RUNNER = re.compile(r"CI_NIGHTLY_(?:NEXT_)?TRUSTED_(?:POOL|RUNNER)")
# The cmux-tui nightly calls the shared package builder, which keeps its own
# fallbacks for other callers; the nightly must override every runner input.
TUI_NIGHTLY_RUNNER_INPUTS = (
    "macos_runner",
    "macos_retry_runner",
    "linux_runner",
    "linux_arm64_runner",
    "windows_runner",
)


def nightly_workflows() -> list[Path]:
    paths = set(WORKFLOWS.glob("*nightly*.yml")) | set(WORKFLOWS.glob("*notarization*.yml"))
    return sorted(paths)


def code_lines(path: Path):
    for number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), start=1):
        if line.lstrip().startswith("#"):
            continue
        yield number, line.split(" # ", 1)[0]


class NightlyOffBlacksmithTests(unittest.TestCase):
    def test_nightly_workflows_are_discovered(self) -> None:
        names = {path.name for path in nightly_workflows()}
        for required in ("nightly.yml", "auto-resume-nightly-notarization.yml"):
            self.assertIn(required, names)

    def test_nightly_jobs_use_pools_not_single_hosts(self) -> None:
        failures = [
            f"{path.name}:{number}: {line.strip()}"
            for path in nightly_workflows()
            for number, line in code_lines(path)
            if SINGLE_HOST.search(line)
        ]
        self.assertEqual(failures, [], "nightly workflows must not depend on a single host")

    def test_nightly_jobs_do_not_read_the_retired_dedicated_runner_tuple(self) -> None:
        failures = [
            f"{path.name}:{number}: {line.strip()}"
            for path in nightly_workflows()
            for number, line in code_lines(path)
            if OLD_NIGHTLY_RUNNER.search(line) and "runs-on:" in line
        ]
        self.assertEqual(failures, [], "nightly workflows must not use the retired dedicated runner tuple")

    def test_nightlies_skip_the_benchmark_mini(self) -> None:
        """cmux11s is the dedicated benchmark mini (since 2026-10-20, a153).

        Its runners are off and must stay idle, so no nightly job may name it or
        any pool it carries: the std PR/side/session pools and the shared
        side-lane or daemon variables (which an operator may point at a std
        pool). Nightly macOS work uses only the cmux15 trusted tuple or the
        light side lane (light-class minis; cmux11s is std class).
        """
        forbidden = re.compile(r"cmux11s|vars\.(CI_NEXT_DAEMON_POOL|CI_NEXT_PROMOTE_POOL|CI_PIN_DAEMON_POOL)\b")
        failures = []
        for path in nightly_workflows():
            for number, line in code_lines(path):
                if forbidden.search(line):
                    failures.append(f"{path.name}:{number}: {line.strip()}")
        self.assertEqual(failures, [], "nightly jobs must never reach the benchmark mini cmux11s")

    @unittest.skipUnless((WORKFLOWS / "cmux-tui-nightly.yml").exists(), "no cmux-tui nightly on this branch")
    def test_tui_nightly_overrides_every_package_builder_runner(self) -> None:
        text = (WORKFLOWS / "cmux-tui-nightly.yml").read_text(encoding="utf-8")
        block = text[text.index("uses: ./.github/workflows/cmux-tui-build-package.yml"):]
        block = block[: block.index("\n  publish-npm:")]
        for name in TUI_NIGHTLY_RUNNER_INPUTS:
            with self.subTest(input=name):
                match = re.search(rf"^\s+{name}: (.+)$", block, re.MULTILINE)
                self.assertIsNotNone(match, f"cmux-tui nightly must pass {name}")
                self.assertNotRegex(match.group(1), SINGLE_HOST)

    def test_native_nightlies_follow_owned_pool_then_blacksmith(self) -> None:
        text = (WORKFLOWS / "nightly.yml").read_text(encoding="utf-8")
        job = text[text.index("\n  build-nightly-app:"):]
        runs_on = re.search(r"^    runs-on: (.+)$", job, re.MULTILINE).group(1)
        # nightly-next: an idle owned Mac, else the moving Blacksmith label (pick-nightly-build-runner).
        self.assertIn("needs.pick-nightly-build-runner.outputs.owned", runs_on)
        self.assertIn("needs.pick-nightly-build-runner.outputs.blacksmith", runs_on)
        self.assertIn("vars.MACOS_RUNNER_26", runs_on)
        self.assertIn("blacksmith-6vcpu-macos-26", runs_on)

    def test_secret_bearing_nightlies_use_the_trusted_owned_pool(self) -> None:
        text = (WORKFLOWS / "nightly.yml").read_text(encoding="utf-8")
        for name in ("build-sign-notarize-nightly", "sign-nightly-identity-legacy"):
            job = text[text.index(f"\n  {name}:"):]
            match = re.search(r"^    runs-on: (.+)$", job, re.MULTILINE)
            with self.subTest(job=name):
                self.assertNotIn("vars.CI_SEED_TRUSTED_POOL", match.group(1))
                self.assertIn("vars.MACOS_RUNNER_26", match.group(1))
                self.assertIn("blacksmith-6vcpu-macos-26", match.group(1))
                self.assertNotIn("vars.CI_SIDE_LANE_RUNNER", match.group(1))

    def test_prepare_runs_on_linux_and_executes_no_mach_o(self) -> None:
        """prepare-nightly-variant only moves and reads files, so it runs on Linux.

        The cmux-tui client install (it runs the client), Apple's strip and the
        capability probes run in build-nightly-app; the theme picker regression
        and the diff sidecar handshake (they run Mach-O) run on the signed app
        in verify-signed-nightly. llvm-lipo thins, which gives Apple lipo's bytes.
        """
        import yaml
        document = yaml.safe_load((WORKFLOWS / "nightly.yml").read_text(encoding="utf-8"))
        jobs = document["jobs"]
        self.assertEqual(jobs["prepare-nightly-variant-primary"]["runs-on"],
                         "${{ github.repository_owner != 'manaflow-ai' && 'ubuntu-24.04' || 'blacksmith-4vcpu-ubuntu-2404' }}")
        self.assertEqual(jobs["prepare-nightly-variant-fallback"]["runs-on"], "ubuntu-24.04")
        moved_out = ("install-cmux-tui-client.sh", "strip-release-bundle.sh", "write-cmux-tui-version.sh",
                     "check-daemon-capabilities.sh", "test_bundled_ghostty_theme_picker_helper.sh",
                     "verify-diff-sidecar-artifact.sh", "select-ci-xcode.sh", "ditto ", "otool", "codesign")
        for name in ("prepare-nightly-variant-primary", "prepare-nightly-variant-fallback"):
            runs = "\n".join(step.get("run", "") for step in jobs[name]["steps"])
            names = [step.get("name", "") for step in jobs[name]["steps"]]
            with self.subTest(job=name):
                for needle in moved_out:
                    self.assertNotIn(needle, runs)
                self.assertIn("Put llvm-lipo on PATH as lipo", names)
                self.assertIn("Require the cmux-tui client build-nightly-app bundled", names)
                self.assertIn("thin-app-bundle.sh", runs)
                self.assertIn("verify_app_libintl.py", runs)
        build = "\n".join(step.get("run", "") for step in jobs["build-nightly-app"]["steps"])
        for needle in ("install-cmux-tui-client.sh", "write-cmux-tui-version.sh", "check-daemon-capabilities.sh"):
            self.assertIn(needle, build)
        steps = [step.get("name") for step in jobs["build-nightly-app"]["steps"]]
        self.assertLess(steps.index("Strip unsigned nightly app before transfer"), steps.index("Bundle the cmux-tui client"))
        self.assertLess(steps.index("Bundle the cmux-tui client"), steps.index("Archive unsigned nightly app"))
        verify = "\n".join(step.get("run", "") for step in jobs["verify-signed-nightly"]["steps"])
        self.assertIn("test_bundled_ghostty_theme_picker_helper.sh", verify)
        self.assertIn("verify-diff-sidecar-artifact.sh", verify)
        helper = "\n".join(step.get("run", "") for step in jobs["build-nightly-ghostty-cli-helper"]["steps"])
        self.assertIn("strip -S -x nightly-helper/ghostty", helper)


    def test_promotion_requests_never_wait_on_blacksmith(self) -> None:
        """The jobs that start a NEXT nightly are part of the nightly path.

        A feat-cmux-next push asks main to promote nightly-next from
        cmux-next.yml and cmux-tui-artifacts.yml (`request-nightly-next`). On
        Blacksmith those requests queued behind its pool like the nightly's own
        jobs, so no nightly started. They must run on GitHub-hosted Linux.
        """
        for name in ("cmux-next.yml", "cmux-tui-artifacts.yml"):
            text = (WORKFLOWS / name).read_text(encoding="utf-8")
            if "\n  request-nightly-next:" not in text:
                continue
            job = text[text.index("\n  request-nightly-next:") + 1:]
            following = re.search(r"\n  [A-Za-z0-9_-]+:\n", job[1:])
            job = job[: following.start() + 1] if following else job
            runs_on = re.search(r"^    runs-on: (.+)$", job, re.MULTILINE).group(1)
            with self.subTest(workflow=name):
                self.assertNotRegex(runs_on, SINGLE_HOST)

    @unittest.skipUnless((WORKFLOWS / "cmux-next.yml").exists(), "no cmux-next on this branch")
    def test_finished_push_runs_start_a_nightly_next_with_a_thirty_minute_catch_up(self) -> None:
        """Every finished feat-cmux-next push run asks for a NEXT nightly.

        A push whose own request was cancelled by the next push, or whose
        request waited on a stalled pool, asked for nothing. The tick closes
        that gap from events and every 30 minutes (the dedicated builder is
        cmux22, plans/cmux-next/nightly-builder-DESIGN.md). It starts when a
        cmux-next or cmux-tui artifacts push run on feat-cmux-next completes,
        whatever its conclusion, and can be started by hand. GitHub runs
        `workflow_run` only from the default branch, so the file must exist
        on main too.
        """
        path = WORKFLOWS / "nightly-next-tick.yml"
        self.assertTrue(path.exists(), "nightly-next-tick.yml must exist")
        text = path.read_text(encoding="utf-8")
        self.assertRegex(text, r"(?m)^\s+schedule:\s*$")
        self.assertRegex(text, r'(?m)^\s+- cron: "7,37 \* \* \* \*"$')
        self.assertIn("workflow_run:", text)
        workflows = re.search(r"(?m)^\s+workflows: \[(.+)\]$", text)
        self.assertIsNotNone(workflows, "workflow_run must name its workflows")
        self.assertIn('"cmux-next"', workflows.group(1))
        self.assertIn('"cmux-tui artifacts"', workflows.group(1))
        self.assertRegex(text, r"(?m)^\s+branches: \[feat-cmux-next\]$")
        self.assertRegex(text, r"(?m)^\s+types: \[completed\]$")
        self.assertIn("github.event.workflow_run.event == 'push'", text)
        self.assertIn("workflow_dispatch:", text)
        self.assertIn("scripts/cmux-next/request-nightly-next.sh --tree-ready", text)
        self.assertIn("cancel-in-progress: false", text)

    def test_no_workflow_reads_the_retired_decide_runner_variable(self) -> None:
        """CI_NIGHTLY_DECIDE_RUNNER named a Blacksmith pool and is deleted."""
        for path in sorted(WORKFLOWS.glob("*.yml")):
            with self.subTest(workflow=path.name):
                self.assertNotIn("CI_NIGHTLY_DECIDE_RUNNER", path.read_text(encoding="utf-8"))


if __name__ == "__main__":
    unittest.main()
