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
POOL = "fromJSON(vars.RUNNER_POOLS).linux"
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
    def test_secret_bearing_changes_takes_ephemeral_hosted_then_measured_retry(self) -> None:
        # The router runs before any picker can, so it is a declared hosted light job
        # (.github/runners.json hosted_light_jobs). Its credentialed body takes a live
        # verified fleet Linux placement when available, then hosted/paid overflow.
        job = yaml.safe_load((WORKFLOWS / "ci.yml").read_text())["jobs"]["changes"]
        runs_on = runs_on_text(job, "ci.yml#changes")
        self.assertIn("needs.portable-placement.outputs.linux_runner", runs_on)
        self.assertIn("needs.portable-placement.outputs.placed_attempt == format('{0}', github.run_attempt)", runs_on)
        self.assertIn("github.run_attempt == 1 && 'ubuntu-24.04'", runs_on)
        self.assertTrue(runs_on.rstrip().endswith(
            "|| vars.CI_CLOUD_OVERFLOW_SAVED && fromJSON(vars.RUNNER_POOLS).linux_16 || fromJSON(vars.RUNNER_POOLS).linux_8 }}"), runs_on)
        self.assertEqual(job["needs"], ["portable-placement"])
        self.assertEqual(yaml.safe_load((WORKFLOWS / "ci.yml").read_text())["jobs"]["portable-placement"]["steps"][-1]["env"]["LINUX_ONLY"], "changes")

    def test_light_report_jobs_take_hosted_ubuntu_first(self) -> None:
        # Declared light jobs (.github/runners.json hosted_light_jobs): a few seconds of report or
        # routing work each, which on 2026-11-02 waited up to a minute behind the saturated
        # blacksmith-4vcpu-ubuntu-2404 queue. Hosted Ubuntu on attempt 1, then a declared retry.
        import json

        declared = json.loads((ROOT / ".github" / "runners.json").read_text())["hosted_light_jobs"]
        hosted = "github.run_attempt == 1 && 'ubuntu-24.04'"
        # The job that holds a pull-requests write token, or runs the checked-out revision's
        # scripts, retries only on ephemeral Blacksmith; the rest may take the reconciled pool.
        ephemeral = "|| vars.CI_CLOUD_OVERFLOW_SAVED && fromJSON(vars.RUNNER_POOLS).linux_16 || fromJSON(vars.RUNNER_POOLS).linux_8 }}"
        cases = {
            ("pr-red-checks-comment.yml", "comment"): ephemeral,
            ("cmux-next.yml", "path_route"): ephemeral,
            ("ci-guards.yml", "guard-status"): f"|| {POOL} }}}}",
            ("pr-checks.yml", "size"): f"|| {POOL} }}}}",
            ("pr-checks.yml", "ui-review"): f"|| {POOL} }}}}",
        }
        for (workflow, name), tail in cases.items():
            with self.subTest(job=f"{workflow}#{name}"):
                self.assertIn(f"{workflow}#{name}", declared)
                runs_on = runs_on_text(yaml.safe_load((WORKFLOWS / workflow).read_text())["jobs"][name], f"{workflow}#{name}")
                # A fork's run keeps the label it had; every other run reads the pool.
                runs_on = re.sub(r"\(github\.event_name == 'pull_request' && github\.event\.pull_request\.head\.repo\.full_name"
                                 r" != github\.repository && 'blacksmith-\d+vcpu-ubuntu-2404' \|\| (fromJSON\(vars\.RUNNER_POOLS\)\.[a-z0-9_]+)\)", r"\1", runs_on)
                self.assertIn(hosted, runs_on)
                self.assertTrue(runs_on.rstrip().endswith(tail), runs_on)
                self.assertNotIn("cmux-fleet-linux-x64", runs_on)

    def test_stalled_paths_use_the_live_linux_pool(self) -> None:
        for workflow, names in TARGETS.items():
            document = yaml.safe_load((WORKFLOWS / workflow).read_text(encoding="utf-8")) or {}
            jobs = document.get("jobs") or {}
            for name in names:
                with self.subTest(workflow=workflow, job=name):
                    runs_on = runs_on_text(jobs[name], f"{workflow}#{name}")
                    self.assertIn(POOL, runs_on)
                    self.assertNotIn("vars.LINUX_RUNNER || 'blacksmith-", runs_on)
                    self.assertNotIn("CI_CLOUD_OVERFLOW_SAVED && 'blacksmith-", runs_on)
                    self.assertNotIn("outputs.map", runs_on)
                    # Past the fork branches, no Blacksmith size is written down.
                    self.assertNotIn("'blacksmith-", runs_on.split("github.repository && ")[-1].split("|| ", 1)[-1])
                    self.assertNotRegex(runs_on, r"RUNNER_POOLS\)\.linux_\d")

    def test_gallery_health_reads_the_live_16_vcpu_pool(self) -> None:
        # A CPU-bound render (ask-378f0fa70e: 4 vCPU 30.5 s, 16 vCPU 13.4 s for the same cases): the 16 vCPU
        # pool, never a fixed size, so a stalled 16 vCPU moves it to 32 like any pool.
        job = yaml.safe_load((WORKFLOWS / "gallery-health.yml").read_text(encoding="utf-8"))["jobs"]["health"]
        runs_on = runs_on_text(job, "gallery-health.yml#health")
        self.assertTrue(runs_on.rstrip().endswith("|| fromJSON(vars.RUNNER_POOLS).linux_16 }}"), runs_on)
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
        # run the smallest pool (review F1 of #36353: a sleep never takes a bigger runner than it needs).
        self.assertEqual(gate_runs_on.count("'ubuntu-24.04'"), 1)
        self.assertTrue(gate_runs_on.startswith("${{ github.repository_owner != 'manaflow-ai' && 'ubuntu-24.04' || "))
        self.assertEqual(re.findall(r"'blacksmith-[^']+'", gate_runs_on), ["'blacksmith-2vcpu-ubuntu-2404'"])
        self.assertTrue(gate_runs_on.rstrip().endswith("|| fromJSON(vars.RUNNER_POOLS).linux_2 }}"))
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

    def test_fast_checks_keeps_the_broker_overflow_set(self) -> None:
        runs_on = runs_on_text((yaml.safe_load((WORKFLOWS / "fast-checks.yml").read_text()) or {})["jobs"]["checks"],
                               "fast-checks.yml#checks")
        self.assertIn("inputs.runner", runs_on)
        self.assertIn("blacksmith-8vcpu-ubuntu-2404", runs_on)
        self.assertIn("blacksmith-16vcpu-ubuntu-2404", runs_on)
        self.assertIn("blacksmith-32vcpu-ubuntu-2404", runs_on)


# The most jobs one pull request push can start on GitHub-hosted Ubuntu: every job of a pull request workflow, or of a
# workflow it calls, whose runs-on can name an `ubuntu-*` hosted label past the outside-manaflow-ai and fork branches.
# The org runs at most 20 hosted jobs at once, so a push that asks for 19 fills the pool by itself and the next push's
# light jobs wait: on 2026-11-17 (19 here) hosted jobs waited 92 s at p90 over 2 h and 181 s over 24 h while
# blacksmith-2vcpu-ubuntu-2404 started jobs in 4-5 s, and NOW paged fast gates' resolve, placement and post over their
# 60 s queue budget for 9 hours. Lower it when a job moves off hosted; never raise it. A light job whose workflow does
# its real work on Blacksmith reads a pool instead (.github/runners.json hosted_light_jobs $comment).
HOSTED_PER_PUSH_MAX = 14
_OUTSIDE = re.compile(r"^\$\{\{ github\.repository_owner != 'manaflow-ai' && 'ubuntu-24\.04' \|\| ")
_FORK = re.compile(r"github\.event_name == 'pull_request' && github\.event\.pull_request\.head\.repo\.full_name"
                   r" != github\.repository && '[^']*' \|\| ")
_HOSTED = re.compile(r"'ubuntu-(?:latest|[0-9.]+(?:-arm)?)'|^ubuntu-")


def hosted_jobs_per_push() -> list[str]:
    docs = {p.name: yaml.safe_load(p.read_text(encoding="utf-8")) or {} for p in WORKFLOWS.glob("*.yml")}

    def triggers(doc: dict) -> set[str]:
        on = doc.get(True, doc.get("on")) or {}
        return {on} if isinstance(on, str) else set(on)

    reached: set[str] = set()
    stack = [name for name, doc in docs.items() if triggers(doc) & {"pull_request", "pull_request_target"}]
    while stack:
        name = stack.pop()
        if name in reached:
            continue
        reached.add(name)
        for job in (docs[name].get("jobs") or {}).values():
            called = re.fullmatch(r"\./\.github/workflows/([^@]+)", str(job.get("uses", "")))
            if called and called.group(1) in docs:
                stack.append(called.group(1))
    hosted = []
    for name in sorted(reached):
        for key, job in (docs[name].get("jobs") or {}).items():
            route = _FORK.sub("", _OUTSIDE.sub("", str(job.get("runs-on", ""))))
            if _HOSTED.search(route):
                hosted.append(f"{name}#{key}")
    return hosted


class HostedBurstTests(unittest.TestCase):
    def test_one_push_asks_for_fewer_hosted_jobs_than_the_org_runs_at_once(self) -> None:
        hosted = hosted_jobs_per_push()
        self.assertLessEqual(len(hosted), HOSTED_PER_PUSH_MAX,
                             f"{len(hosted)} jobs a pull request push can start on GitHub-hosted Ubuntu (at most "
                             f"{HOSTED_PER_PUSH_MAX}; the org runs 20 at once). Route the new one to a RUNNER_POOLS "
                             f"pool: {hosted}")

    def test_fast_gates_light_jobs_never_wait_for_a_hosted_slot(self) -> None:
        hosted = hosted_jobs_per_push()
        for key in ("portable-placement", "resolve", "post"):
            with self.subTest(job=key):
                self.assertNotIn(f"cmux-next-fast-gates.yml#{key}", hosted)
                route = runs_on_text(yaml.safe_load((WORKFLOWS / "cmux-next-fast-gates.yml").read_text())["jobs"][key],
                                     f"cmux-next-fast-gates.yml#{key}")
                # A pool, so its writer moves a stalled member on: the job never waits on a label nothing serves.
                self.assertTrue(route.rstrip().endswith("|| fromJSON(vars.RUNNER_POOLS).linux_2 }}"), route)

    def test_the_count_sees_a_hosted_attempt_one_route(self) -> None:
        route = ("${{ github.repository_owner != 'manaflow-ai' && 'ubuntu-24.04' || github.event_name == 'pull_request'"
                 " && github.event.pull_request.head.repo.full_name != github.repository && 'blacksmith-2vcpu-ubuntu-2404'"
                 " || github.run_attempt == 1 && 'ubuntu-24.04' || fromJSON(vars.RUNNER_POOLS).linux_2 }}")
        self.assertTrue(_HOSTED.search(_FORK.sub("", _OUTSIDE.sub("", route))))
        pooled = route.replace("github.run_attempt == 1 && 'ubuntu-24.04' || ", "")
        self.assertFalse(_HOSTED.search(_FORK.sub("", _OUTSIDE.sub("", pooled))))
        self.assertTrue(_HOSTED.search("ubuntu-latest"))


if __name__ == "__main__":
    unittest.main()
