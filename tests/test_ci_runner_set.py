#!/usr/bin/env python3
"""The CI paths that have stalled must resolve through the live Linux pool.

The broker can move a fast-check run only when its workflow accepts the
declared overflow set.  These jobs therefore must read RUNNER_POOLS for their
normal route and may not fall back to one Blacksmith label.
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
# The one Linux label (scripts/ci/one_linux_label.py) replaced the RUNNER_POOLS linux sizes.
POOL = "'cmux-linux'"
# Credentialed jobs the generator leaves on the ephemeral pool ("admits only an ephemeral vendor runner").
EPHEMERAL_POOL_JOBS = {("fast-checks.yml", "checks")}
TARGETS = {
    "app-platform.yml": {"check"},
    "cmux-next-terminal.yml": {"rust-terminal-linux", "swift-terminal-linux"},
    "fast-checks.yml": {"checks"},
    # 2026-10-31T23:57Z queue alarms: each sat 44-46 min on one Blacksmith size that started nothing
    # (gallery health on a fixed 16 vCPU label, web validation and PR checks' base-only on 32, the cloud
    # backend check on the capability map's fixed 4 vCPU label). Gallery health now reads the 16 vCPU pool,
    # which moves to 32 vCPU on a stall (POOL_16 below). PR checks' jobs are now one advisory job holding a
    # write token (CI v2 step 6), on a one-job Blacksmith VM: test_pr_checks_advisory_takes_a_one_job_vm.
    "web-validation.yml": {"changes", "build", "tests", "database", "web-validation"},
    "pr-body-checks.yml": {"body"},
}


def runs_on_text(job: dict, where: str) -> str:
    """The job's runs-on as its one cell; a matrix nothing resolves, or more than one cell, fails."""
    cells = workflow_jobs.runs_on_cells(job)
    if cells is None or len(cells) != 1:
        raise AssertionError(f"{where}: runs-on does not resolve to one value: {cells!r}")
    return cells[0]


class RunnerSetTests(unittest.TestCase):
    def test_changes_router_takes_the_persistent_linux_pool(self) -> None:
        # Its App-token body (GitHub API reads, no signing or release secret) takes the persistent
        # cmux-linux pool on every attempt, with no placement job before it; forks keep Blacksmith.
        # GitHub-hosted Ubuntu left it queued for hours on 2026-11-18 (cmux#45735).
        jobs = yaml.safe_load((WORKFLOWS / "ci.yml").read_text())["jobs"]
        job = jobs["changes"]
        runs_on = runs_on_text(job, "ci.yml#changes")
        self.assertNotIn("needs.", runs_on)
        self.assertNotIn("github.run_attempt == 1 && 'ubuntu-24.04'", runs_on)
        self.assertIn("github.event.pull_request.head.repo.full_name != github.repository && (vars.CI_FORK_LINUX_RUNNER", runs_on)
        self.assertTrue(runs_on.rstrip().endswith("|| 'cmux-linux' }}"), runs_on)
        self.assertNotIn("needs", job)
        self.assertNotIn("portable-placement", jobs)

    def test_light_report_jobs_run_on_blacksmith_every_attempt(self) -> None:
        # A few seconds of report or routing work each. They took hosted Ubuntu on attempt 1 until
        # 2026-11-18, when GitHub-hosted runners left them queued for hours (cmux#45735); Blacksmith
        # is the rule for all CI, so every attempt reads the declared pool.
        import json

        declared = json.loads((ROOT / ".github" / "runners.json").read_text())["hosted_light_jobs"]
        hosted = "github.run_attempt == 1 && 'ubuntu-24.04'"
        # The job that holds a pull-requests write token, or runs the checked-out revision's
        # scripts, retries only on ephemeral Blacksmith; the rest may take the reconciled pool.
        ephemeral = "|| vars.CI_CLOUD_OVERFLOW_SAVED && fromJSON(vars.RUNNER_POOLS).linux_16 || fromJSON(vars.RUNNER_POOLS).linux_8 }}"
        cases = {
            ("pr-red-checks-comment.yml", "comment"): "|| 'cmux-linux' }}",
            ("cmux-next.yml", "path_route"): "|| 'cmux-linux' }}",
            ("ci-guards.yml", "guard-status"): "|| 'cmux-linux' }}",
        }
        for (workflow, name), tail in cases.items():
            with self.subTest(job=f"{workflow}#{name}"):
                self.assertNotIn(f"{workflow}#{name}", declared)
                runs_on = runs_on_text(yaml.safe_load((WORKFLOWS / workflow).read_text())["jobs"][name], f"{workflow}#{name}")
                # A fork's run keeps the label it had; every other run reads the pool.
                runs_on = re.sub(r"\(github\.event_name == 'pull_request' && github\.event\.pull_request\.head\.repo\.full_name"
                                 r" != github\.repository && 'blacksmith-\d+vcpu-ubuntu-2404' \|\| (fromJSON\(vars\.RUNNER_POOLS\)\.[a-z0-9_]+)\)", r"\1", runs_on)
                self.assertNotIn(hosted, runs_on)
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
                    direct = workflow == "web-validation.yml" and name == "web-validation"
                    if direct:
                        self.assertTrue(runs_on.endswith("|| 'cmux-linux' }}"), runs_on)
                        self.assertIn("github.event.pull_request.head.repo.full_name != github.repository", runs_on)
                        self.assertNotIn("needs.", runs_on)
                    elif (workflow, name) in EPHEMERAL_POOL_JOBS:
                        # one_linux_label.py keeps a credentialed job on the ephemeral vendor pool.
                        self.assertIn("fromJSON(vars.RUNNER_POOLS).linux }}", runs_on)
                    else:
                        self.assertIn(POOL, runs_on)
                    self.assertNotIn("vars.LINUX_RUNNER || 'blacksmith-", runs_on)
                    self.assertNotIn("CI_CLOUD_OVERFLOW_SAVED && 'blacksmith-", runs_on)
                    self.assertNotIn("outputs.map", runs_on)
                    # Past the fork branches, no Blacksmith size is written down.
                    self.assertNotIn("'blacksmith-", runs_on.split("github.repository && ")[-1].split("|| ", 1)[-1])
                    self.assertNotRegex(runs_on, r"RUNNER_POOLS\)\.linux_\d")

    def test_pr_checks_advisory_takes_a_one_job_vm(self) -> None:
        # pr-checks.yml's six jobs became one (CI v2 step 6) that writes the status comment lines, so it never
        # reads RUNNER_POOLS (whose x64 pools lead with persistent machines) and never a shared persistent label:
        # a fork takes Blacksmith, any other run CI_TRUSTED_RUNNER; not the PR control JIT label, which backed up.
        job = yaml.safe_load((WORKFLOWS / "pr-checks.yml").read_text(encoding="utf-8"))["jobs"]["advisory"]
        runs_on = runs_on_text(job, "pr-checks.yml#advisory")
        self.assertNotIn("cmux-gcp-pr-control-jit-x64", runs_on)
        self.assertIn("github.event.pull_request.head.repo.full_name != github.repository && "
                      "'blacksmith-4vcpu-ubuntu-2404'", runs_on)
        self.assertTrue(runs_on.endswith("vars.CI_TRUSTED_RUNNER) && vars.CI_TRUSTED_RUNNER || "
                                         "'blacksmith-4vcpu-ubuntu-2404' }}"), runs_on)
        for persistent in ("RUNNER_POOLS", "cmux-linux", "cmux-fleet-linux-x64"):
            self.assertNotIn(persistent, runs_on)
        self.assertEqual(job["permissions"]["pull-requests"], "write")

    def test_gallery_health_reads_the_live_16_vcpu_pool(self) -> None:
        # A CPU-bound render (ask-378f0fa70e: 4 vCPU 30.5 s, 16 vCPU 13.4 s for the same cases): the 16 vCPU
        # pool, never a fixed size, so a stalled 16 vCPU moves it to 32 like any pool.
        job = yaml.safe_load((WORKFLOWS / "gallery-health.yml").read_text(encoding="utf-8"))["jobs"]["health"]
        runs_on = runs_on_text(job, "gallery-health.yml#health")
        # One Linux label since scripts/ci/one_linux_label.py (Leo, 2026-11-20: "Just send it somewhere").
        self.assertTrue(runs_on.rstrip().endswith("|| 'cmux-linux' }}"), runs_on)
        self.assertNotIn("vars.LINUX_RUNNER", runs_on)
        self.assertNotIn("'blacksmith-", runs_on.split("github.repository && ")[-1].split("|| ", 1)[-1])

    def test_cmux_next_pr_quiet_period_comes_before_every_mac_job(self) -> None:
        # A PR run sleeps until about 5 minutes after the PR's last push, so a newer push cancels a
        # run that has spent only the sleep. Leo, 2026-11-05: "i meant can you do all of htem".
        # Since 2026-11-21 the sleep is macos-placement's first step, not a job of its own (cmuxterm-hq#16094:
        # the pr-quiet-period job was 1.64% of pull request runner-minutes and never red).
        jobs = yaml.safe_load((WORKFLOWS / "cmux-next.yml").read_text())["jobs"]
        self.assertNotIn("pr-quiet-period", jobs)
        placement = jobs["macos-placement"]
        gate = placement["steps"][0]
        self.assertEqual(gate["name"], "Wait until the pull request has had no push for the quiet period")
        self.assertIn("github.event_name == 'pull_request'", gate["if"])
        self.assertIn("github.run_attempt == 1", gate["if"])
        # landing.md: a leo-named-fix PR lands with no wait.
        self.assertIn("!contains(github.event.pull_request.labels.*.name, 'leo-named-fix')", gate["if"])
        self.assertIn("vars.CI_PR_QUIET_PERIOD_SECONDS", gate["if"])
        self.assertTrue(gate.get("continue-on-error"))
        self.assertIn('sleep "$wait"', gate["run"])
        # The job's limit holds its own work and the whole wait (at most 10 minutes, a step limit of 11).
        self.assertGreaterEqual(placement["timeout-minutes"], 8 + gate["timeout-minutes"])
        # Only the Mac jobs wait for it (Leo, 2026-11-08, choosing "the Linux checks start at once and only
        # the Mac jobs wait": "yeah"). macos-placement places them from a reading taken after the wait.
        self.assertTrue(placement["if"].startswith("${{ !cancelled() && "), placement["if"])

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
        # that a Mac job's placement judged) follows macos-placement. app-compile-fleet's runner only hands the
        # head to the build fleet's Linux compile, on a gateway runner judged at once (app-compile-placement), and
        # a push-only DEV landing compile never runs on a pull request.
        starts_at_once = {"app-compile-fleet", "dev-landing-compile"}
        # Each matrix cell is read as its values; a matrix value nothing resolves may name a Mac, so it waits too.
        def can_take_a_mac(job: dict) -> bool:
            cells = workflow_jobs.runs_on_cells(job)
            return cells is None or any("macos" in runs_on or "gateway_runner" in runs_on for runs_on in cells)

        mac = {name for name, job in jobs.items() if can_take_a_mac(job) and name not in starts_at_once}
        self.assertTrue({"fast-tier", "swift-canary", "swift-test", "daemon-test", "generated-files", "release-compile",
                         "cmux-scheme-compile", "swift-canary-fleet", "fast-tier-fleet-mac"} <= mac, sorted(mac))
        for name in sorted(mac):
            with self.subTest(job=name):
                self.assertIn("macos-placement", ancestors(name), f"{name} takes a Mac before the quiet period ends")
        self.assertTrue(jobs["dev-landing-place"]["if"].startswith("${{ github.event_name == 'push'"))
        self.assertEqual(needs("dev-landing-compile"), ["dev-landing-place"])
        # The Linux work starts at once: none of it waits for the sleep.
        for name in ("push-head-preflight", "path_route", "checks", "fast-tier-cargo",
                     "web-bundles", "app-compile-placement", "app-compile-fleet"):
            with self.subTest(job=name):
                self.assertNotIn("macos-placement", ancestors(name), f"{name} waits for the quiet period")
        # The run's group still cancels the whole run, the early Linux jobs included, on a newer push.
        document = yaml.safe_load((WORKFLOWS / "cmux-next.yml").read_text())
        self.assertIn("github.event_name == 'pull_request' ||", document["concurrency"]["cancel-in-progress"])
        # The implicit success() reads every ancestor, a skipped macos-placement included (a fork, an unowned
        # pool, a person's re-run), so each job after it says how it treats a skipped or failed need (#35871).
        for name, job in jobs.items():
            if "macos-placement" not in ancestors(name):
                continue
            with self.subTest(job=name):
                self.assertRegex(str(job.get("if", "")), r"always\(\)|cancelled\(\)|failure\(\)",
                                 f"{name} would skip whenever macos-placement skips")

    def test_fast_checks_keeps_the_broker_overflow_set(self) -> None:
        runs_on = runs_on_text((yaml.safe_load((WORKFLOWS / "fast-checks.yml").read_text()) or {})["jobs"]["checks"],
                               "fast-checks.yml#checks")
        self.assertIn("inputs.runner", runs_on)
        self.assertIn("blacksmith-8vcpu-ubuntu-2404", runs_on)
        self.assertIn("blacksmith-16vcpu-ubuntu-2404", runs_on)
        self.assertIn("blacksmith-32vcpu-ubuntu-2404", runs_on)


if __name__ == "__main__":
    unittest.main()
