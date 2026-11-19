#!/usr/bin/env python3
"""The CI paths that have stalled run on the one Linux label, cmux-linux.

They used to read the live Linux pool (RUNNER_POOLS) so a stalled vendor size
could be moved; a label is fixed when a job queues, so that never helped a job
already waiting. Since cmuxterm-hq#14156 ("capacity comes to the job") every
own-branch Linux job says cmux-linux and the scaler-hosted provider brings a
runner to it; only a fork's run keeps the label it had.
"""

from __future__ import annotations

import re
import sys
import unittest
from pathlib import Path

import yaml

sys.path.insert(0, str(Path(__file__).resolve().parent))
import workflow_jobs  # noqa: E402


ROOT = Path(__file__).resolve().parents[1]
WORKFLOWS = ROOT / ".github" / "workflows"
LABEL = "'cmux-linux'"
TAIL = f"|| {LABEL} }}}}"
TARGETS = {
    "app-platform.yml": {"check"},
    "cmux-next-terminal.yml": {"rust-terminal-linux", "swift-terminal-linux"},
    "fast-checks.yml": {"checks"},
    # 2026-10-31T23:57Z queue alarms: each sat 44-46 min on one Blacksmith size that started nothing
    # (gallery health on a fixed 16 vCPU label, web validation and PR checks' base-only on 32, the cloud
    # backend check on the capability map's fixed 4 vCPU label). Gallery health now reads the 16 vCPU pool,
    # which moves to 32 vCPU on a stall (POOL_16 below).
    "web-validation.yml": {"changes", "build", "tests", "database", "web-validation"},
    "pr-checks.yml": {"base-only", "size", "ui-review", "split"},
    "pr-body-checks.yml": {"body"},
}


def runs_on_text(job: dict, where: str) -> str:
    """The job's runs-on as its one cell; a matrix nothing resolves, or more than one cell, fails."""
    cells = workflow_jobs.runs_on_cells(job)
    if cells is None or len(cells) != 1:
        raise AssertionError(f"{where}: runs-on does not resolve to one value: {cells!r}")
    return cells[0]


class RunnerSetTests(unittest.TestCase):
    def test_secret_bearing_changes_takes_the_one_linux_label(self) -> None:
        # Its credentialed body runs on cmux-linux, whose runners are one-job VMs; GitHub-hosted Ubuntu left it
        # queued for hours on 2026-11-18 (cmux#45735), so no attempt takes hosted Ubuntu. The placement step
        # stays (its other outputs are read) but no longer picks this job's label.
        job = yaml.safe_load((WORKFLOWS / "ci.yml").read_text())["jobs"]["changes"]
        runs_on = runs_on_text(job, "ci.yml#changes")
        self.assertNotIn("needs.portable-placement.outputs.linux_runner", runs_on)
        self.assertNotIn("github.run_attempt == 1 && 'ubuntu-24.04'", runs_on)
        self.assertNotIn("RUNNER_POOLS", runs_on)
        self.assertTrue(runs_on.rstrip().endswith(TAIL), runs_on)
        self.assertEqual(job["needs"], ["portable-placement"])
        self.assertEqual(yaml.safe_load((WORKFLOWS / "ci.yml").read_text())["jobs"]["portable-placement"]["steps"][-1]["env"]["LINUX_ONLY"], "changes")

    def test_light_report_jobs_run_on_the_one_linux_label_every_attempt(self) -> None:
        # A few seconds of report or routing work each. They took hosted Ubuntu on attempt 1 until
        # 2026-11-18, when GitHub-hosted runners left them queued for hours (cmux#45735); every attempt
        # now takes cmux-linux (cmuxterm-hq#14156).
        import json

        declared = json.loads((ROOT / ".github" / "runners.json").read_text())["hosted_light_jobs"]
        hosted = "github.run_attempt == 1 && 'ubuntu-24.04'"
        # The jobs that hold a pull-requests write token, or run the checked-out revision's scripts, rely on
        # cmux-linux's runners being one-job VMs, like the rest.
        cases = {
            ("pr-red-checks-comment.yml", "comment"): TAIL,
            ("cmux-next.yml", "path_route"): TAIL,
            ("ci-guards.yml", "guard-status"): TAIL,
            ("pr-checks.yml", "size"): TAIL,
            ("pr-checks.yml", "ui-review"): TAIL,
        }
        for (workflow, name), tail in cases.items():
            with self.subTest(job=f"{workflow}#{name}"):
                self.assertNotIn(f"{workflow}#{name}", declared)
                runs_on = runs_on_text(yaml.safe_load((WORKFLOWS / workflow).read_text())["jobs"][name], f"{workflow}#{name}")
                # A fork's run keeps the label it had; every other run takes cmux-linux.
                self.assertNotIn(hosted, runs_on)
                self.assertNotIn("RUNNER_POOLS", runs_on)
                self.assertTrue(runs_on.rstrip().endswith(tail), runs_on)
                self.assertNotIn("cmux-fleet-linux-x64", runs_on)

    def test_no_light_job_takes_hosted_ubuntu_on_attempt_one(self) -> None:
        # On 2026-11-18 jobs that finished on GitHub-hosted had waited a median 10,768 s, so every pull request's
        # `changes` router sat there and its required checks never started. #45861 first added a release valve
        # (hosted_saturated in RUNNER_POOLS); the hosted attempt-1 branch is now gone from every non-nightly
        # workflow (Blacksmith for all CI, cmux#45898) and the valve is gone. Nightlies keep their own routes.
        hosted = re.compile(r"github\.run_attempt == 1 && [^|]*'ubuntu-24\.04'")
        for path in sorted(WORKFLOWS.glob("*.y*ml")):
            if path.name == "nightly.yml":  # nightlies never run on Blacksmith; their hosted routes stay
                continue
            for number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
                with self.subTest(site=f"{path.name}:{number}"):
                    self.assertIsNone(hosted.search(line), line)
                    self.assertNotIn("hosted_saturated", line)

    def test_stalled_paths_use_the_live_linux_pool(self) -> None:
        for workflow, names in TARGETS.items():
            document = yaml.safe_load((WORKFLOWS / workflow).read_text(encoding="utf-8")) or {}
            jobs = document.get("jobs") or {}
            for name in names:
                with self.subTest(workflow=workflow, job=name):
                    runs_on = runs_on_text(jobs[name], f"{workflow}#{name}")
                    self.assertTrue(runs_on.rstrip().endswith(TAIL), runs_on)
                    self.assertNotIn("RUNNER_POOLS", runs_on)
                    self.assertNotIn("vars.LINUX_RUNNER || 'blacksmith-", runs_on)
                    self.assertNotIn("CI_CLOUD_OVERFLOW_SAVED && 'blacksmith-", runs_on)
                    self.assertNotIn("outputs.map", runs_on)
                    # Past the fork branches, no Blacksmith size is written down.
                    self.assertNotIn("'blacksmith-", runs_on.split("github.repository && ")[-1].split("|| ", 1)[-1])
                    self.assertNotIn("inputs.runner", runs_on)

    def test_gallery_health_takes_the_one_linux_label(self) -> None:
        # A CPU-bound render (ask-378f0fa70e: 4 vCPU 30.5 s, 16 vCPU 13.4 s for the same cases), on cmux-linux,
        # whose pool VMs are 16 vCPU; never a fixed vendor size.
        job = yaml.safe_load((WORKFLOWS / "gallery-health.yml").read_text(encoding="utf-8"))["jobs"]["health"]
        runs_on = runs_on_text(job, "gallery-health.yml#health")
        self.assertTrue(runs_on.rstrip().endswith(TAIL), runs_on)
        self.assertNotIn("vars.LINUX_RUNNER", runs_on)
        self.assertNotIn("'blacksmith-", runs_on.split("github.repository && ")[-1].split("|| ", 1)[-1])

    def test_cmux_next_pr_quiet_period_comes_before_every_mac_job(self) -> None:
        # A PR run sleeps until about 5 minutes after the PR's last push, so a newer push cancels a
        # run that has spent only the sleep. Leo, 2026-11-05: "i meant can you do all of htem".
        import json

        jobs = yaml.safe_load((WORKFLOWS / "cmux-next.yml").read_text())["jobs"]
        gate = jobs["pr-quiet-period"]
        gate_runs_on = runs_on_text(gate, "cmux-next.yml#pr-quiet-period")
        # The sleep holds no hosted Ubuntu slot: the org's 20 hosted jobs at once are for the routers
        # and report steps (2026-11-07: the sleeps held 6 of 20 on average), so it is no hosted light job.
        self.assertNotIn("cmux-next.yml#pr-quiet-period",
                         json.loads((ROOT / ".github" / "runners.json").read_text())["hosted_light_jobs"])
        self.assertNotIn("needs", gate)
        self.assertIn("github.event_name == 'pull_request'", gate["if"])
        self.assertIn("github.run_attempt == 1", gate["if"])
        # landing.md: a leo-named-fix PR lands with no wait.
        self.assertIn("!contains(github.event.pull_request.labels.*.name, 'leo-named-fix')", gate["if"])
        # Hosted Ubuntu only outside manaflow-ai; a fork PR takes the smallest fixed size, every other
        # run cmux-linux (cmuxterm-hq#14156).
        self.assertEqual(gate_runs_on.count("'ubuntu-24.04'"), 1)
        self.assertTrue(gate_runs_on.startswith("${{ github.repository_owner != 'manaflow-ai' && 'ubuntu-24.04' || "))
        self.assertEqual(re.findall(r"'blacksmith-[^']+'", gate_runs_on), ["'blacksmith-2vcpu-ubuntu-2404'"])
        self.assertTrue(gate_runs_on.rstrip().endswith(TAIL), gate_runs_on)
        self.assertEqual(gate["permissions"], {})
        self.assertTrue(all(step.get("continue-on-error") for step in gate["steps"]))
        # Only the Mac jobs wait for it (Leo, 2026-11-08, choosing "the Linux checks start at once and only
        # the Mac jobs wait": "yeah"). macos-placement waits for it directly, so the Mac jobs are placed from
        # a reading taken after the wait, and runs when it is skipped (pushes, dispatches, re-runs).
        self.assertIn("pr-quiet-period", jobs["macos-placement"]["needs"])
        self.assertTrue(jobs["macos-placement"]["if"].startswith("${{ !cancelled() && "), jobs["macos-placement"]["if"])

        def needs(name: str) -> list[str]:
            value = jobs[name].get("needs") or []
            return [value] if isinstance(value, str) else list(value)

        def ancestors(name: str) -> set[str]:
            seen: set[str] = set()
            stack = needs(name)
            while stack:
                need = stack.pop()
                if need not in seen:
                    seen.add(need)
                    stack.extend(needs(need))
            return seen

        # Every Mac job (a runs-on that can name a macOS label, or a build-fleet client on the gateway runner
        # that a Mac job's placement judged) waits for it. app-compile-fleet's runner only hands the head to
        # the build fleet's Linux compile, on a gateway runner judged at once (app-compile-placement), and a
        # push-only DEV landing compile never runs on a pull request.
        starts_at_once = {"app-compile-fleet", "dev-landing-compile"}
        # Each matrix cell is read as its values; a matrix value nothing resolves may name a Mac, so it waits too.
        def can_take_a_mac(job: dict) -> bool:
            cells = workflow_jobs.runs_on_cells(job)
            return cells is None or any("macos" in runs_on or "gateway_runner" in runs_on for runs_on in cells)

        mac = {name for name, job in jobs.items() if can_take_a_mac(job) and name not in starts_at_once}
        self.assertTrue({"fast-tier", "swift-canary", "swift-test", "daemon-test", "generated-files", "release-compile",
                         "cmux-scheme-compile", "swift-canary-fleet", "fast-tier-fleet"} <= mac, sorted(mac))
        for name in sorted(mac):
            with self.subTest(job=name):
                self.assertIn("pr-quiet-period", ancestors(name), f"{name} takes a Mac before the quiet period ends")
        self.assertTrue(jobs["dev-landing-place"]["if"].startswith("${{ github.event_name == 'push'"))
        self.assertEqual(needs("dev-landing-compile"), ["dev-landing-place"])
        # The Linux work starts at once: none of it waits for the sleep.
        for name in ("portable-placement", "push-head-preflight", "path_route", "checks", "fast-tier-cargo",
                     "web-bundles", "app-compile-placement", "app-compile-fleet"):
            with self.subTest(job=name):
                self.assertNotIn("pr-quiet-period", ancestors(name), f"{name} waits for the quiet period")
        # The run's group still cancels the whole run, the early Linux jobs included, on a newer push.
        document = yaml.safe_load((WORKFLOWS / "cmux-next.yml").read_text())
        self.assertIn("github.event_name == 'pull_request' ||", document["concurrency"]["cancel-in-progress"])
        # The implicit success() reads every ancestor, the skipped gate included (a push, a re-run), so each
        # job after it says how it treats a skipped or failed need (#35871).
        for name, job in jobs.items():
            if "pr-quiet-period" not in ancestors(name):
                continue
            with self.subTest(job=name):
                self.assertRegex(str(job.get("if", "")), r"always\(\)|cancelled\(\)|failure\(\)",
                                 f"{name} would skip whenever pr-quiet-period skips")

    def test_fast_checks_takes_no_label_from_the_broker(self) -> None:
        # The broker's re-dispatch onto another vendor size moved nothing a queued job could use; with one label
        # a re-dispatch waits on the same label as the first run, and its runner input picks nothing.
        runs_on = runs_on_text((yaml.safe_load((WORKFLOWS / "fast-checks.yml").read_text()) or {})["jobs"]["checks"],
                               "fast-checks.yml#checks")
        self.assertNotIn("inputs.runner", runs_on)
        self.assertTrue(runs_on.rstrip().endswith(TAIL), runs_on)


if __name__ == "__main__":
    unittest.main()
