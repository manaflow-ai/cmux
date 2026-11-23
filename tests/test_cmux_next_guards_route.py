#!/usr/bin/env python3
"""feat-cmux-next pull requests and pushes run the release-notary guard group.

Pushes run it in the release-notary job (in parallel, judged at the tip) and in the CI guard group (so the
merge gate has a base verdict for each of its steps); pull requests run it in the CI guard group, compared
with their base.

ci.yml skips its guards for feat-cmux-next and has no push trigger, so the
nightly, notarization and nightly-next publication tests ran nowhere on the
branch nightly-next ships from (tests/test_nightly_cmux_tui_resolve.py stayed
red there unseen).
"""

import json
import sys
from pathlib import Path
import unittest

import yaml

ROOT = Path(__file__).resolve().parents[1]


def callers():
    for path in sorted((ROOT / ".github/workflows").glob("*.yml")):
        workflow = yaml.safe_load(path.read_text())
        triggers = workflow.get(True) or workflow.get("on") or {}
        for job in (workflow.get("jobs") or {}).values():
            if job.get("uses") == "./.github/workflows/ci-guards.yml":
                yield path.name, triggers, job


class CmuxNextGuardsRouteTests(unittest.TestCase):
    def test_feat_cmux_next_runs_release_notary_on_pushes(self):
        # A push runs every release-notary step in parallel, judged at the tip. The ci-guards.yml matrix leg ran them
        # one after another (915 s on 4 vCPU) and ended cancelled at its 15 minutes, with no verdict, on every push.
        import contextlib  # noqa: PLC0415
        import io  # noqa: PLC0415
        import shlex  # noqa: PLC0415
        import sys  # noqa: PLC0415

        sys.path.insert(0, str(ROOT / "scripts/ci"))
        import run_ci_guards  # noqa: PLC0415

        workflow = yaml.safe_load((ROOT / ".github/workflows/cmux-next-guards.yml").read_text())
        triggers = workflow.get(True) or workflow.get("on") or {}
        push = triggers.get("push") or {}
        self.assertIn("feat-cmux-next", push.get("branches") or [])
        self.assertFalse(push.get("paths"))
        job = workflow["jobs"]["release-notary"]
        # base-coalesce.yml: a push runs it once per 30-minute window on the tip (needs.coalesce.outputs.run).
        self.assertEqual(job["if"], "${{ !cancelled() && needs.coalesce.outputs.run != 'false' && (github.event_name != 'pull_request') }}")
        self.assertEqual(job["timeout-minutes"], 15)
        script = next(step["run"] for step in job["steps"] if step.get("name") == "Run the release-notary guards")
        call = next(line for line in script.splitlines() if "scripts/ci/guards-local.sh" in line)
        args = shlex.split(call.split(" || ", 1)[0].replace('"$(getconf _NPROCESSORS_ONLN)"', "4"))
        args = args[args.index("scripts/ci/guards-local.sh") + 1:]
        # The run stops itself inside the job's 15 minutes. Not GNU `timeout`: a placed mini has none (exit 127,
        # run 44175871401).
        self.assertLess(float(args[args.index("--deadline") + 1]), 15 * 60 - 60)
        self.assertNotRegex(script, r"(?m)^\s*timeout\b")
        # A worker per core (4 on the 4 vCPU pool), the whole group and nothing else, every step past a red one.
        self.assertIn('--jobs "$(getconf _NPROCESSORS_ONLN)"', call)
        self.assertEqual(args[args.index("--group") + 1], "release-notary")
        self.assertEqual(args.count("--group"), 1)
        for flag in ("--step", "--skip-group", "--feat-routes", "--root"):
            self.assertNotIn(flag, args)
        self.assertIn("--keep-going", args)
        self.assertIn('python3 scripts/ci/guards_new_reds.py --tip "$RUNNER_TEMP/release-notary.json"', script)
        # The command runs every step of the group (no step dropped), as one parallel unit.
        workflow_steps = yaml.safe_load((ROOT / ".github/workflows/ci-guards.yml").read_text())
        group_steps = [step["name"] for step in workflow_steps["jobs"]["workflow-guard-tests"]["steps"]
                       if "'release-notary'" in str(step.get("if", ""))
                       and step["name"] not in run_ci_guards.DEPENDENCY_STEPS and "uses" not in step]
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            self.assertEqual(run_ci_guards.main(["--list"] + [a for a in args if a not in ("--keep-going",)
                                                              and not a.startswith("--results")
                                                              and "release-notary.json" not in a]), 0)
        listed = out.getvalue().splitlines()
        # "in order" names the group's ordered head (its ghostty-next init); the rest still share the pool
        # (ordered_split; test_ci_run_guards.CheckoutSetupRunsFirst runs it through main()).
        self.assertTrue(listed[0].startswith(f"workflow-guard-tests / release-notary: {len(group_steps)} steps, "), listed[0])
        self.assertEqual([line[4:] for line in listed[1:]], group_steps)

    def test_a_pull_request_runs_release_notary_against_its_base(self):
        # Run on its own, every pull request was red while the branch was (833 of 1656 runs in the 24 h to
        # 2026-11-05 08:24Z). A pull request runs the group in the CI guard group's head-and-base comparison
        # (guards_new_reds.py), which fails on a step red on the change and not on its base; a push runs
        # the release-notary job, judged at its tip, so a base red fails the push that caused it.
        workflow = yaml.safe_load((ROOT / ".github/workflows/cmux-next-guards.yml").read_text())
        triggers = workflow.get(True) or workflow.get("on") or {}
        pull = triggers.get("pull_request") or {}
        self.assertIn("feat-cmux-next", pull.get("branches") or [])
        # No workflow path filter but the docs-only block (scripts/ci/docs_only_paths.py): the CI guard group runs on
        # every pull request that changes more than prose and routes release-notary inside it, so a change that
        # skips the group still reports a pass. The group is not a required check, so a docs-only pull request
        # that starts no run leaves nothing pending (tests/test_ci_docs_only_prs.py).
        sys.path.insert(0, str(ROOT / "scripts" / "ci"))
        import docs_only_paths  # noqa: PLC0415

        self.assertEqual([str(p) for p in pull.get("paths") or []], list(docs_only_paths.DOCS_ONLY_PATHS),
                         "the guards' only path filter is the docs-only block")
        self.assertNotIn("paths-ignore", pull)
        jobs = workflow["jobs"]
        # nightly-guards runs on every event (the submodule forward-only guard, Guard status), never with the
        # release-notary matrix leg: a push runs the group in parallel in the release-notary job.
        self.assertEqual(jobs["nightly-guards"]["if"], "${{ !cancelled() && needs.coalesce.outputs.run != 'false' }}")
        self.assertEqual(jobs["nightly-guards"]["with"]["linux_guard_tests"], "${{ 'false' }}")
        group = jobs["ci-guard-group"]
        self.assertEqual(group["if"], "${{ !cancelled() && needs.coalesce.outputs.run != 'false' && "
                         "needs.fast-check-route.outputs.ci_guard_group != 'false' && "
                         "(github.event_name != 'pull_request' || !startsWith(github.event.pull_request.base.ref, 'feat-cmux-next') || contains(github.event.pull_request.labels.*.name, 'full-ci')) }}")
        steps = {step.get("name"): step for step in group["steps"]}
        script = steps["Run the ci guard group and the routed groups"]["run"]
        calls = [line for line in script.splitlines() if "scripts/ci/guards-local.sh" in line and "--list" not in line]
        self.assertEqual(len(calls), 2, calls)
        # A pull request routes release-notary by its paths (detect_linux_guard_changes.RELEASE_NOTARY_INPUTS):
        # no --group, so the ci group plus every group classify_feat picks, release-notary among them.
        self.assertIn("--feat-routes", calls[0])
        self.assertNotIn("--group", calls[0])
        self.assertIn("--root .guard-base", calls[1])
        self.assertIn('python3 scripts/ci/guards_new_reds.py "$RUNNER_TEMP/guards-head.json" "$RUNNER_TEMP/guards-base.json"',
                      script)

    def test_a_push_runs_every_guard_group_a_pull_request_can_run(self):
        # The merge gate excuses a pull request's guard group red only by the base's newest push run of the same job
        # (base_red_excuse.py GUARD_GROUP_JOB). A push that left release-notary out gave its steps no base verdict,
        # so their reds on a pull request were never excused (cmux#45374 against base run 44110521024).
        import sys  # noqa: PLC0415

        sys.path.insert(0, str(ROOT / "scripts/ci"))
        import detect_linux_guard_changes  # noqa: PLC0415

        workflow = yaml.safe_load((ROOT / ".github/workflows/cmux-next-guards.yml").read_text())
        group = workflow["jobs"]["ci-guard-group"]
        steps = {step.get("name"): step for step in group["steps"]}
        changes = steps["Changed files"]["run"]
        # A push drops its changed-files list, so --feat-routes reads none and routes every group.
        self.assertIn('if [[ "$EVENT_NAME" != pull_request ]]; then', changes)
        self.assertIn('rm -f "$RUNNER_TEMP/changed-files.txt"', changes.split('!= pull_request ]]; then', 1)[1])
        every = set(detect_linux_guard_changes.classify_feat([]))
        self.assertIn("release-notary", every)
        for path in ("scripts/ci/run_ci_guards.py", ".github/workflows/nightly.yml", "Packages/macOS/x.swift",
                     "tests/test_x.py", "webviews/src/x.ts"):
            with self.subTest(path=path):
                self.assertLessEqual(set(detect_linux_guard_changes.classify_feat([path])), every)
        # The same head call for a pull request and a push, and no group left out of either pass.
        script = steps["Run the ci guard group and the routed groups"]["run"]
        self.assertNotIn("--skip-group", script)
        self.assertNotIn("EVENT_NAME", script)

    def test_release_notary_has_ghostty_next_for_the_toolchain_notices(self):
        # toolchain_notices.py fails on a missing ghostty-next/build.zig.zon by
        # design; the guard checkout has no submodules.
        workflow = yaml.safe_load((ROOT / ".github/workflows/ci-guards.yml").read_text())
        steps = workflow["jobs"]["workflow-guard-tests"]["steps"]
        init = [
            s for s in steps
            if "release-notary" in str(s.get("if", "")) and "git submodule update --init --depth 1 ghostty-next" in s.get("run", "")
        ]
        self.assertTrue(init, "release-notary must initialize ghostty-next before the license compliance test")
        names = [s.get("name") for s in steps]
        self.assertLess(names.index(init[0]["name"]), names.index("Validate app bundle license compliance"))


if __name__ == "__main__":
    unittest.main()
