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
    def test_control_plane_guards_use_the_small_linux_pool(self):
        workflow = yaml.safe_load((ROOT / ".github/workflows/cmux-next-guards.yml").read_text())
        jobs = workflow["jobs"]
        for name in ("fast-check-route", "security-holes", "workflow-start-lint"):
            with self.subTest(job=name):
                runs_on = jobs[name]["runs-on"]
                self.assertIn("fromJSON(vars.RUNNER_POOLS).linux_2", runs_on)
                self.assertIn("github.repository_owner != 'manaflow-ai' && 'ubuntu-24.04'", runs_on)
                self.assertIn("github.event.pull_request.head.repo.full_name != github.repository && 'ubuntu-24.04'", runs_on)

        # static-checks executes the larger, multi-step nightly capability and generated-string checks.
        self.assertTrue(jobs["static-checks"]["runs-on"].endswith("|| 'cmux-linux' }}"))

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
        # The land tier (tests/test_head_tier.py) wraps it: the condition, then the land condition and label guard.
        self.assertTrue(job["if"].startswith(
            "${{ (!cancelled() && needs.coalesce.outputs.run != 'false' && (github.event_name != 'pull_request')) && "),
            job["if"])
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
        self.assertTrue(jobs["nightly-guards"]["if"].startswith(  # then the land tier (tests/test_head_tier.py)
            "${{ ((github.event.action != 'ready_for_review') && (!cancelled() && needs.coalesce.outputs.run != 'false')) && "),
            jobs["nightly-guards"]["if"])
        self.assertEqual(jobs["nightly-guards"]["with"]["linux_guard_tests"], "${{ 'false' }}")
        group = jobs["ci-guard-group"]
        # Inside the land tier's and the label filter's wrapping (tests/test_head_tier.py), so a contained clause, not a prefix.
        self.assertIn(  # then the land tier (tests/test_head_tier.py)
                        "((github.event.action != 'ready_for_review') && (!cancelled() && needs.coalesce.outputs.run != 'false' && "
                        "needs.fast-check-route.outputs.ci_guard_group != 'false' && "
                        "(github.event_name != 'pull_request' || !startsWith(github.event.pull_request.base.ref, 'feat-cmux-next') || (contains(github.event.pull_request.labels.*.name, 'full-ci') && (github.event.pull_request.base.ref != 'feat-cmux-next' || (github.event.action == 'labeled' && github.event.label.name == 'full-ci') || (vars.CI_FULL_CI_ONE_SHOT || '1') == '0'))))) && ",
                        group["if"])
        # The route feeds only the group and own-change-checks, both skipped on a pull request into feat-cmux-next
        # without full-ci, so the route skips there too (1,115 runner starts in 5.1 h of 11-25 no job read).
        self.assertIn("(github.event_name == 'pull_request' && (github.event_name != 'pull_request' || "
                      "!startsWith(github.event.pull_request.base.ref, 'feat-cmux-next') || "
                      "(contains(github.event.pull_request.labels.*.name, 'full-ci') && (github.event.pull_request.base.ref != 'feat-cmux-next' || (github.event.action == 'labeled' && github.event.label.name == 'full-ci') || (vars.CI_FULL_CI_ONE_SHOT || '1') == '0'))))",
                      jobs["fast-check-route"]["if"])
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

    def test_marking_a_draft_ready_does_not_cancel_its_run(self):
        # The jobs that judge a head skip ready_for_review (the land tier): the draft's run already judges that same
        # head. In the PR's shared group (cancel-in-progress) the ready_for_review run cancelled the draft's run and
        # then skipped, so the head had no guard verdict: 4 of the 10 heads marked ready while their run was going,
        # 03:34Z-04:40Z 2026-11-27 (cmux#60334's b44fdf65, run 45929725137). So that event gets a group of its own.
        workflow = yaml.safe_load((ROOT / ".github/workflows/cmux-next-guards.yml").read_text())
        triggers = workflow.get(True) or workflow.get("on") or {}
        self.assertIn("ready_for_review", triggers["pull_request"]["types"])
        skips = [name for name, job in workflow["jobs"].items()
                 if "github.event.action != 'ready_for_review'" in str(job.get("if") or "")]
        self.assertTrue(skips)
        group = workflow["concurrency"]["group"]
        self.assertIn("${{ github.event_name == 'pull_request' && github.event.action == 'ready_for_review' && "
                      "format('-ready-{0}', github.run_id) || '' }}", group)
        self.assertEqual(workflow["concurrency"]["cancel-in-progress"], "${{ github.event_name == 'pull_request' }}")

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


    def test_ios_placeholder_bounds_runs_only_where_the_diff_reaches_its_inputs(self):
        # ci-runner-min-per-day-50k (Leo, 2026-11-27: "whatever we need to cut, we cut."): the job ran on every pull
        # request event, about 6,000 runs a day. workflow-start-lint's route step, on the depth-2 checkout it already
        # takes, says whether the diff reaches the check's inputs; a miss skips the job (a skipped check run passes
        # land-judge and GitHub's required checks). A push and vars.IOS_PLACEHOLDER_BOUNDS_EVERY_HEAD == '1' run it.
        import os  # noqa: PLC0415
        import subprocess  # noqa: PLC0415
        import tempfile  # noqa: PLC0415

        workflow = yaml.safe_load((ROOT / ".github/workflows/cmux-next-guards.yml").read_text())
        jobs = workflow["jobs"]
        bounds = jobs["ios-placeholder-bounds"]
        self.assertIn("workflow-start-lint", bounds["needs"])
        self.assertIn("(needs.workflow-start-lint.outputs.ios_placeholder != 'false' || "
                      "vars.IOS_PLACEHOLDER_BOUNDS_EVERY_HEAD == '1')", bounds["if"])
        self.assertIn("!cancelled()", bounds["if"])
        lint = jobs["workflow-start-lint"]
        self.assertEqual(lint["outputs"]["ios_placeholder"], "${{ steps.touched.outputs.ios_placeholder }}")
        # A label other than full-ci or ready-to-land changes no file: the lint skips that event.
        self.assertIn("github.event.action == 'labeled' && !contains(fromJSON('[\"full-ci\",\"ready-to-land\"]'), "
                      "github.event.label.name)", lint["if"])
        step = next(s for s in lint["steps"] if s.get("id") == "touched")
        cases = [
            ("pull_request", "cmux-next-ios/App/View.swift", "true"),
            ("pull_request", "cmux-next-ios/design/placeholders.json", "true"),
            ("pull_request", "scripts/ci/ios_placeholder_bounds.py", "true"),
            ("pull_request", "tests/test_ios_placeholder_bounds.py", "true"),
            ("pull_request", ".github/workflows/cmux-next-guards.yml", "true"),
            ("pull_request", "cmux-tui/crates/acpmux/src/lib.rs", "false"),
            ("pull_request", ".github/workflows/ci.yml", "false"),
            ("pull_request", "docs/cmux-next-ios.md", "false"),
            ("push", "cmux-tui/crates/acpmux/src/lib.rs", "true"),
        ]
        for event, changed, want in cases:
            with self.subTest(event=event, changed=changed), tempfile.TemporaryDirectory() as tmp:
                git = ["git", "-C", tmp, "-c", "user.name=t", "-c", "user.email=t@t", "-c", "commit.gpgsign=false"]
                subprocess.run(["git", "init", "-q", tmp], check=True)
                Path(tmp, "base.txt").write_text("base\n")
                subprocess.run(git + ["add", "-A"], check=True)
                subprocess.run(git + ["commit", "-qm", "base"], check=True)
                Path(tmp, changed).parent.mkdir(parents=True, exist_ok=True)
                Path(tmp, changed).write_text("change\n")
                subprocess.run(git + ["add", "-A"], check=True)
                subprocess.run(git + ["commit", "-qm", "change"], check=True)
                out = Path(tmp, "github_output")
                env = {"PATH": os.environ["PATH"], "HOME": tmp, "GITHUB_OUTPUT": str(out), "EVENT_NAME": event}
                subprocess.run(["bash", "-eo", "pipefail", "-c", step["run"]], cwd=tmp, env=env, check=True,
                               capture_output=True)
                lines = out.read_text().splitlines()
                self.assertIn(f"ios_placeholder={want}", lines)


    def test_spec_checks_run_on_every_head_whose_diff_reaches_the_spec(self):
        # #56203 (dd19a6ecf137, 2026-11-27) added the control event `client-disconnected-by` in server code and
        # merged with the spec inventory red: cmux-tui-spec.yml's `inventory` job skips a feat-cmux-next pull request
        # without `full-ci` (run 45977048802: `changes` and `inventory` skipped), the step table's linux job is
        # full-tier only, and the land ran the affected tier, so the check first ran after the merge. The cheap
        # spec and bindings checks run here instead, on every pull request head and push whose diff reaches what
        # they read (scripts/ci/spec_checks.py INPUTS), on our own runners, never a GitHub-hosted one.
        import os  # noqa: PLC0415
        import subprocess  # noqa: PLC0415
        import tempfile  # noqa: PLC0415

        workflow = yaml.safe_load((ROOT / ".github/workflows/cmux-next-guards.yml").read_text())
        jobs = workflow["jobs"]
        job = jobs["spec-checks"]
        self.assertIn("workflow-start-lint", job["needs"])
        self.assertIn("needs.workflow-start-lint.outputs.spec_checks != 'false'", job["if"])
        self.assertIn("!cancelled()", job["if"])
        # No land tier skip: a cheap head runs it (tests/test_head_tier.py KEEP_ON_EVERY_HEAD).
        self.assertNotIn("ready-to-land') && vars.CI_LAND_FULL_PER_PR", job["if"])
        # Own branches on the cmux-linux pool (or the overflow variable), fork pull requests on Blacksmith; the
        # GitHub-hosted label only where Blacksmith is not installed (a copy of this repository under another owner).
        sys.path.insert(0, str(ROOT / "tests"))
        import workflow_jobs  # noqa: PLC0415

        values, unresolved = workflow_jobs.runs_on_values(job)
        self.assertEqual(values, {"ubuntu-24.04", "blacksmith-4vcpu-ubuntu-2404", "cmux-linux"})
        self.assertEqual(unresolved, {"vars.CI_OVERFLOW_LINUX"})
        runs = [s.get("run", "") for s in job["steps"]]
        self.assertIn("python3 -I tests/test_ci_spec_checks.py", runs)
        self.assertTrue(any('python3 -I scripts/ci/spec_checks.py run "${base[@]}"' in r and "--base HEAD^1" in r
                            for r in runs), runs)
        checkout = next(s for s in job["steps"] if str(s.get("uses", "")).startswith("actions/checkout@"))
        self.assertEqual(checkout["with"]["fetch-depth"], 2)  # the merge commit and its base, for the base rerun
        lint = jobs["workflow-start-lint"]
        self.assertEqual(lint["outputs"]["spec_checks"], "${{ steps.touched.outputs.spec_checks }}")
        lint_checkout = next(s for s in lint["steps"] if str(s.get("uses", "")).startswith("actions/checkout@"))
        self.assertIn("/scripts/ci/spec_checks.py", lint_checkout["with"]["sparse-checkout"].split())
        step = next(s for s in lint["steps"] if s.get("id") == "touched")
        cases = [
            ("pull_request", "cmux-tui/spec/events.md", "true"),
            ("pull_request", "cmux-tui/spec/sdk-schema.json", "true"),
            ("pull_request", "cmux-tui/bindings/go/raw/events.go", "true"),
            ("pull_request", "cmux-tui/crates/cmux-tui-core/src/server.rs", "true"),
            ("pull_request", "cmux-tui/crates/cmux-tui-core/src/server/client_kick.rs", "true"),
            ("pull_request", "cmux-tui/scripts/check-spec-inventory.py", "true"),
            ("pull_request", "scripts/ci/spec_checks.py", "true"),
            ("pull_request", "cmux-tui/crates/acpmux/src/lib.rs", "false"),
            ("pull_request", "docs/cmux-next-ios.md", "false"),
            ("pull_request", "webviews/src/App.tsx", "false"),
            ("push", "docs/cmux-next-ios.md", "true"),
        ]
        spec_checks = (ROOT / "scripts/ci/spec_checks.py").read_text()
        for event, changed, want in cases:
            with self.subTest(event=event, changed=changed), tempfile.TemporaryDirectory() as tmp:
                git = ["git", "-C", tmp, "-c", "user.name=t", "-c", "user.email=t@t", "-c", "commit.gpgsign=false"]
                subprocess.run(["git", "init", "-q", tmp], check=True)
                Path(tmp, "scripts/ci").mkdir(parents=True)
                Path(tmp, "scripts/ci/spec_checks.py").write_text(spec_checks)
                subprocess.run(git + ["add", "-A"], check=True)
                subprocess.run(git + ["commit", "-qm", "base"], check=True)
                Path(tmp, changed).parent.mkdir(parents=True, exist_ok=True)
                Path(tmp, changed).write_text("change\n")
                subprocess.run(git + ["add", "-A"], check=True)
                subprocess.run(git + ["commit", "-qm", "change"], check=True)
                out = Path(tmp, "github_output")
                env = {"PATH": os.environ["PATH"], "HOME": tmp, "GITHUB_OUTPUT": str(out), "EVENT_NAME": event}
                subprocess.run(["bash", "-eo", "pipefail", "-c", step["run"]], cwd=tmp, env=env, check=True,
                               capture_output=True)
                self.assertIn(f"spec_checks={want}", out.read_text().splitlines())

if __name__ == "__main__":
    unittest.main()
