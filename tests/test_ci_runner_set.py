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
from runs_on_labels import resolve_labels  # noqa: E402


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


def labels_at(route: str, event: str, head: str = "manaflow-ai/cmux") -> set:
    return resolve_labels(route, context={"github.event_name": event, "github.repository": "manaflow-ai/cmux",
                                         "github.event.pull_request.head.repo.full_name": head,
                                         "github.ref": "refs/heads/feature", "github.sha": "abc"})


class RunnerSetTests(unittest.TestCase):
    def test_secret_bearing_changes_takes_live_placement_then_ephemeral_blacksmith(self) -> None:
        # Its credentialed body takes a live verified fleet Linux placement when available, then
        # ephemeral Blacksmith on every attempt: GitHub-hosted Ubuntu left it queued for hours on
        # 2026-11-18 (cmux#45735), so no attempt takes hosted Ubuntu.
        job = yaml.safe_load((WORKFLOWS / "ci.yml").read_text())["jobs"]["changes"]
        runs_on = runs_on_text(job, "ci.yml#changes")
        self.assertIn("needs.portable-placement.outputs.linux_runner", runs_on)
        self.assertIn("needs.portable-placement.outputs.placed_attempt == format('{0}', github.run_attempt)", runs_on)
        self.assertNotIn("github.run_attempt == 1 && 'ubuntu-24.04'", runs_on)
        self.assertTrue(runs_on.rstrip().endswith(
            "|| vars.CI_CLOUD_OVERFLOW_SAVED && fromJSON(vars.RUNNER_POOLS).linux_16 || fromJSON(vars.RUNNER_POOLS).linux_8 }}"), runs_on)
        self.assertEqual(job["needs"], ["portable-placement"])
        self.assertEqual(yaml.safe_load((WORKFLOWS / "ci.yml").read_text())["jobs"]["portable-placement"]["steps"][-1]["env"]["LINUX_ONLY"], "changes")

    def test_light_report_jobs_keep_the_writer_isolated(self) -> None:
        for workflow, name in (("pr-red-checks-comment.yml", "comment"), ("cmux-next.yml", "path_route"),
                               ("ci-guards.yml", "guard-status"), ("pr-checks.yml", "size"),
                               ("pr-checks.yml", "ui-review")):
            with self.subTest(workflow=workflow, job=name):
                job = workflow_jobs.jobs(WORKFLOWS / workflow)[name]
                route = runs_on_text(job, name)
                expected = "cmux-gcp-pr-control-jit-x64" if name == "comment" else "cmux-linux"
                self.assertEqual(labels_at(route, "pull_request"), {expected})
                fork_labels = labels_at(route, "pull_request", "outside/fork")
                if name == "comment":
                    self.assertEqual(fork_labels, {"ubuntu-24.04"})
                else:
                    self.assertNotIn("cmux-linux", fork_labels)

    def test_release_verifier_executes_the_tag_only_on_a_single_job_runner(self) -> None:
        job = workflow_jobs.jobs(WORKFLOWS / "coderouter-verify-release.yml")["verify"]
        for event in ("release", "workflow_dispatch"):
            self.assertEqual(labels_at(runs_on_text(job, "verify"), event), {"cmux-gcp-pr-control-jit-x64"})

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
                    if workflow == "fast-checks.yml":
                        # A dispatch can name a different source revision. Keep the bounded dispatch pool.
                        self.assertIn(POOL, runs_on)
                        self.assertNotIn("cmux-linux", runs_on)
                    else:
                        triggers = document.get("on", document.get(True, {}))
                        event = "push" if "push" in triggers else "pull_request"
                        self.assertEqual(labels_at(runs_on, event), {"cmux-linux"})
                        self.assertNotIn("cmux-linux", labels_at(runs_on, "pull_request", "outside/fork"))

    def test_dispatch_with_a_different_checkout_or_a_tag_uses_one_job(self) -> None:
        job = next(job for job in workflow_jobs.jobs(WORKFLOWS / "cmux-mobile-ffi.yml").values()
                   if "!inputs.ref" in str(job.get("runs-on")))
        route = runs_on_text(job, "cmux-mobile-ffi")
        context = {"github.event_name": "workflow_dispatch", "github.repository": "manaflow-ai/cmux",
                   "github.sha": "abc", "github.event.pull_request.head.sha": "",
                   "github.event.pull_request.head.repo.full_name": ""}
        for ref, checkout, wanted in (("refs/heads/main", "abc", "cmux-linux"),
                                      ("refs/heads/main", "other", "cmux-gcp-pr-control-jit-x64"),
                                      ("refs/tags/v1", "abc", "cmux-gcp-pr-control-jit-x64")):
            with self.subTest(ref=ref, checkout=checkout):
                self.assertEqual(resolve_labels(route, context={**context, "github.ref": ref, "inputs.ref": checkout}),
                                 {wanted})

    def test_dispatched_unverified_macos_refs_use_ephemeral_capacity(self) -> None:
        mobile = yaml.safe_load((WORKFLOWS / "cmux-mobile-ffi.yml").read_text())["jobs"]["apple"]
        mobile_route = runs_on_text(mobile, "cmux-mobile-ffi.yml#apple")
        batch = yaml.safe_load((WORKFLOWS / "cmux-next-batch.yml").read_text())["jobs"]["regen"]
        batch_route = runs_on_text(batch, "cmux-next-batch.yml#regen")
        context = {
            "github.event_name": "workflow_dispatch",
            "github.repository": "manaflow-ai/cmux",
            "github.sha": "abc",
            "github.ref": "refs/heads/feat-cmux-next",
            "github.event.pull_request.head.repo.full_name": "",
            "github.event.pull_request.head.sha": "",
        }
        self.assertEqual(resolve_labels(mobile_route, context={**context, "inputs.ref": "other"}),
                         {"blacksmith-6vcpu-macos-26"})
        self.assertEqual(resolve_labels(batch_route, context={**context, "inputs.sha": "other"}),
                         {"blacksmith-6vcpu-macos-26"})

    def test_dispatch_inputs_keep_unverified_revisions_off_persistent_linux(self) -> None:
        context = {
            "github.event_name": "workflow_dispatch",
            "github.repository": "manaflow-ai/cmux",
            "github.ref": "refs/heads/feat-cmux-next",
            "github.sha": "abc",
            "github.event.pull_request.head.repo.full_name": "",
            "github.event.pull_request.head.sha": "",
        }

        web = yaml.safe_load((WORKFLOWS / "cmux-next-web-bundle-publish.yml").read_text())["jobs"]["build"]
        web_route = runs_on_text(web, "cmux-next-web-bundle-publish.yml#build")
        base_context = {**context, "inputs.pr": "", "inputs.ref": "", "inputs.base": ""}
        self.assertEqual(resolve_labels(web_route, context=base_context), {"cmux-linux"})
        for key, value in (("inputs.pr", "47965"), ("inputs.ref", "feature"), ("inputs.base", "deadbeef")):
            with self.subTest(workflow="web-bundle", input=key):
                self.assertEqual(resolve_labels(web_route, context={**base_context, key: value}), {"cmux-gcp-pr-control-jit-x64"})

        tui = yaml.safe_load((WORKFLOWS / "cmux-tui-spec.yml").read_text())["jobs"]["clippy"]
        tui_route = runs_on_text(tui, "cmux-tui-spec.yml#clippy")
        base_context = {**context, "inputs.commit": "", "inputs.base": ""}
        self.assertEqual(resolve_labels(tui_route, context=base_context), {"cmux-linux"})
        for key, value in (("inputs.commit", "deadbeef"), ("inputs.base", "deadbeef")):
            with self.subTest(workflow="tui-spec", input=key):
                self.assertEqual(resolve_labels(tui_route, context={**base_context, key: value}), {"cmux-gcp-pr-control-jit-x64"})

        skew = yaml.safe_load((WORKFLOWS / "cmux-next-skew-matrix.yml").read_text())["jobs"]["skew-matrix"]
        skew_route = runs_on_text(skew, "cmux-next-skew-matrix.yml#skew-matrix")
        self.assertEqual(resolve_labels(skew_route, context={**context, "inputs.commit": "abc", "inputs.old_commit": ""}), {"cmux-linux"})
        self.assertEqual(resolve_labels(skew_route, context={**context, "inputs.commit": "abc", "inputs.old_commit": "deadbeef"}), {"cmux-gcp-pr-control-jit-x64"})

    def test_gallery_health_uses_the_pool_for_owned_work(self) -> None:
        job = workflow_jobs.jobs(WORKFLOWS / "gallery-health.yml")["health"]
        route = runs_on_text(job, "gallery-health.yml#health")
        self.assertEqual(labels_at(route, "pull_request"), {"cmux-linux"})
        self.assertNotIn("cmux-linux", labels_at(route, "pull_request", "elsewhere/fork"))

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
        self.assertEqual(labels_at(gate_runs_on, "pull_request"), {"cmux-linux"})
        self.assertEqual(labels_at(gate_runs_on, "pull_request", "elsewhere/fork"),
                         {"ubuntu-24.04"})
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


if __name__ == "__main__":
    unittest.main()
