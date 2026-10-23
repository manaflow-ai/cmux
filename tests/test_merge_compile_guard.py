#!/usr/bin/env python3
"""merge_compile_guard: a hand merge of a feat-cmux-next PR that changes Swift is refused only once its compile
finished red; a compile still pending, and the guard's own slow or failed read, are warnings.

On 2026-10-21 (UTC) #22835, #21480 and #21487 were merged with `gh pr merge` while their compile was pending. Later
that day, under load on cosmic-gray, the guard's GitHub reads timed out and refused #23660 and #23371 for hours with
every gate met (Leo: "IF THE MERGE HOOK IS WRONG THEN JUST FUCKING MERGE").
"""
from __future__ import annotations

import json
import os
import stat
import subprocess
import sys
import tempfile
import textwrap
import time
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
HOOK = ROOT / "scripts/ci/merge-compile-guard-hook.sh"
sys.path.insert(0, str(ROOT / "scripts/ci"))
import merge_compile_guard as guard  # noqa: E402

COMPILE = guard.COMPILE
HEAD = "c" * 40
SWIFT = ["Packages/macOS/CmuxNext/Sources/A.swift"]


def pr(number=7, base="feat-cmux-next", head=HEAD):
    return {"number": number, "base": base, "head": head, "state": "open"}


def check(name, status="completed", conclusion="success"):
    return {"name": name, "status": status, "conclusion": conclusion if status == "completed" else None}


class Verdict(unittest.TestCase):
    def test_a_swift_pr_merges_only_once_its_compile_passed(self):
        self.assertIn("still running", guard.verdict(pr(), SWIFT, [check(COMPILE, "in_progress")]))
        self.assertIn("still running", guard.verdict(pr(), SWIFT, [check(COMPILE, "queued")]))
        self.assertIn("finished failure", guard.verdict(pr(), SWIFT, [check(COMPILE, conclusion="failure")]))
        self.assertIn("finished cancelled", guard.verdict(pr(), SWIFT, [check(COMPILE, conclusion="cancelled")]))
        self.assertEqual(guard.verdict(pr(), SWIFT, [check(COMPILE)]), "")
        # A rerun that passed after a red counts.
        self.assertEqual(guard.verdict(pr(), SWIFT, [check(COMPILE, conclusion="failure"), check(COMPILE)]), "")

    def test_only_a_compile_that_finished_red_refuses(self):
        """Everything else is a Hold: the hook says it and the merge goes ahead (HQ's landing gate does the same)."""
        for checks in ([], [check(COMPILE, "queued")], [check(COMPILE, "in_progress")],
                       [check("cmux-next path routing", "in_progress")], [check(COMPILE, conclusion="cancelled")],
                       [check(guard.FLEET_COMPILE, conclusion="cancelled")]):
            with self.subTest(checks=checks):
                self.assertIsInstance(guard.verdict(pr(), SWIFT, checks), guard.Hold)
        for checks in ([check(COMPILE, conclusion="failure")], [check(COMPILE, conclusion="timed_out")],
                       [check(guard.FLEET_COMPILE, conclusion="failure")],
                       [check(COMPILE, conclusion="failure"), check(COMPILE, "queued")]):
            with self.subTest(checks=checks):
                why = guard.verdict(pr(), SWIFT, checks)
                self.assertTrue(why)
                self.assertNotIsInstance(why, guard.Hold)

    def test_a_red_fleet_compile_refuses_even_with_a_release_compile_queued(self):
        """Codex review of #24265: the red check read only Release attempts, so a failed build-fleet compile next to
        a queued Release compile read as a wait and became a warning, and a fleet pass on the head could silence it."""
        fleet = guard.FLEET_COMPILE
        for runs in ([check(fleet, conclusion="failure"), check(COMPILE, "queued")],
                     [check(fleet, conclusion="failure"), check(COMPILE, "in_progress")],
                     [check(fleet, conclusion="timed_out"), check("cmux-next path routing", "in_progress")]):
            with self.subTest(runs=runs):
                self.assertFalse(guard.compile_wait(runs))
                for fleet_passed in (False, True):
                    why = guard.verdict(pr(), SWIFT, runs, fleet_passed=fleet_passed)
                    self.assertIn(f"{fleet} finished", why)
                    self.assertNotIsInstance(why, guard.Hold)
        # A passing rerun of either compile clears it.
        self.assertEqual(guard.verdict(pr(), SWIFT, [check(fleet, conclusion="failure"), check(fleet)]), "")
        self.assertEqual(guard.verdict(pr(), SWIFT, [check(fleet, conclusion="failure"), check(COMPILE)]), "")

    def test_a_compile_not_created_yet_waits_while_cmux_next_routes_and_places(self):
        for job in guard.ROUTING:
            with self.subTest(job=job):
                self.assertIn("has not created", guard.verdict(pr(), SWIFT, [check(job, "in_progress")]))
        self.assertIn("no checks yet", guard.verdict(pr(), SWIFT, []))
        # cmux-next finished routing without a compile, or never ran on this head.
        self.assertEqual(guard.verdict(pr(), SWIFT, [check("cmux-next path routing")]), "")
        self.assertEqual(guard.verdict(pr(), SWIFT, [check("web / lint")]), "")

    def test_a_prs_build_fleet_compile_stands_in_for_its_skipped_release_compile(self):
        # A same-repository PR compiles on the build fleet; its Mac Release compile runs only with no fleet verdict.
        fleet = guard.FLEET_COMPILE
        self.assertIn(fleet, guard.ROUTING)
        self.assertIn("has not created", guard.verdict(pr(), SWIFT, [check(fleet, "in_progress")]))
        self.assertEqual(guard.verdict(pr(), SWIFT, [check(fleet), check(COMPILE, conclusion="skipped")]), "")
        for conclusion in ("failure", "timed_out"):
            with self.subTest(conclusion=conclusion):
                runs = [check(fleet, conclusion=conclusion), check(COMPILE, conclusion="skipped")]
                self.assertIn(f"{fleet} finished {conclusion}", guard.verdict(pr(), SWIFT, runs))
                self.assertIn(f"{fleet} finished {conclusion}", guard.verdict(pr(), SWIFT, runs, fleet_passed=True))
        # A run cancelled while the fleet compiled leaves no verdict at all (the Release compile skips on a
        # cancelled run): that is no compile, not a pass, and a fleet pass on the exact head stands in.
        stopped = [check(fleet, conclusion="cancelled"), check(COMPILE, conclusion="skipped")]
        self.assertIn(f"{fleet} was cancelled", guard.verdict(pr(), SWIFT, stopped))
        self.assertTrue(guard.compile_wait(stopped))
        self.assertEqual(guard.verdict(pr(), SWIFT, stopped, fleet_passed=True), "")
        # A rerun that passed after the cancel counts.
        self.assertEqual(guard.verdict(pr(), SWIFT, stopped + [check(fleet)]), "")
        # No fleet verdict: the Mac Release compile that ran instead decides.
        self.assertEqual(guard.verdict(pr(), SWIFT, [check(fleet), check(COMPILE)]), "")
        self.assertIn("still running", guard.verdict(pr(), SWIFT, [check(fleet), check(COMPILE, "queued")]))

    def test_what_the_compile_does_not_cover_is_not_held(self):
        # The router skipped it (iOS, a package outside the graph, a fork).
        self.assertEqual(guard.verdict(pr(), ["ios/CmuxiOS/A.swift"], [check(COMPILE, conclusion="skipped")]), "")
        self.assertEqual(guard.verdict(pr(), ["webviews/src/a.tsx"], [check(COMPILE, "queued")]), "")
        self.assertEqual(guard.verdict(pr(base="main"), SWIFT, [check(COMPILE, "queued")]), "")

    def test_headers_manifests_and_projects_count_as_swift(self):
        for path in ("Sources/CCmuxAppFFI/include/ffi.h", "Packages/macOS/CmuxNext/Package.resolved",
                     "cmux.xcodeproj/project.pbxproj", "Config/Next.xcconfig", "Sources/X/module.modulemap"):
            with self.subTest(path=path):
                self.assertIn("still running", guard.verdict(pr(), [path], [check(COMPILE, "queued")]))


class FleetCompileCheck(unittest.TestCase):
    """A passed `cmux-ci compile-check --app` on the exact head stands in for the Release compile.

    #22845's Release compile sat queued over an hour (60 minis offline) after its fleet compile-check
    passed. The pass counts only as the `fleet/compile-check` status that fleet-compile-check.yml, run from
    feat-cmux-next, posts on the head, and only when that run finished green naming the full head.
    """

    def test_a_verified_fleet_pass_stands_in_for_a_release_compile_still_waiting(self):
        for runs in ([check(COMPILE, "queued")], [check(COMPILE, "in_progress")], [],
                     [check(guard.ROUTING[0], "in_progress")]):
            with self.subTest(runs=runs):
                self.assertNotEqual(guard.verdict(pr(), SWIFT, runs), "")
                self.assertEqual(guard.verdict(pr(), SWIFT, runs, fleet_passed=True), "")

    def test_a_fleet_pass_never_overrides_a_release_compile_that_finished_red(self):
        # The fleet compiles on Linux with the pool SDK, not Xcode 26 Release: a red there is the truth.
        for conclusion in ("failure", "timed_out", "action_required", "startup_failure"):
            with self.subTest(conclusion=conclusion):
                runs = [check(COMPILE, conclusion=conclusion)]
                self.assertIn(f"finished {conclusion}", guard.verdict(pr(), SWIFT, runs, fleet_passed=True))
                self.assertFalse(guard.compile_wait(runs))

    def test_a_rerun_queued_after_a_red_compile_is_not_a_wait(self):
        # `gh run rerun --failed` on a red Xcode-only error: the fleet pass must not merge it meanwhile.
        runs = [check(COMPILE, conclusion="failure"), check(COMPILE, "queued")]
        self.assertFalse(guard.compile_wait(runs))
        self.assertIn("still running", guard.verdict(pr(), SWIFT, runs, fleet_passed=True))
        # A red attempt stays red beside a cancelled one, and so does a startup failure.
        self.assertFalse(guard.compile_wait([check(COMPILE, conclusion="startup_failure"), check(COMPILE, "queued")]))
        self.assertFalse(guard.compile_wait([check(COMPILE, conclusion="failure"), check(COMPILE, conclusion="cancelled"),
                                             check(COMPILE, "queued")]))

    def test_a_cancelled_compile_is_no_verdict_so_a_fleet_pass_stands_in(self):
        # #22845: two attempts cancelled, a third queued for hours, a verified fleet pass on the head.
        cancelled = check(COMPILE, conclusion="cancelled")
        for runs in ([cancelled, cancelled, check(COMPILE, "queued")], [cancelled],
                     [check(COMPILE, conclusion="skipped"), cancelled]):
            with self.subTest(runs=runs):
                self.assertTrue(guard.compile_wait(runs))
                self.assertNotEqual(guard.verdict(pr(), SWIFT, runs), "")
                self.assertEqual(guard.verdict(pr(), SWIFT, runs, fleet_passed=True), "")

    def test_every_gh_call_shares_one_deadline_under_the_hooks_timeout(self):
        self.assertLess(guard.BUDGET, 120)
        spent = guard.STARTED
        try:
            guard.STARTED = guard.time.monotonic() - guard.BUDGET
            self.assertIsNone(guard.run(["true"]))
        finally:
            guard.STARTED = spent

    def test_a_refusal_says_how_to_get_a_fleet_pass(self):
        # cmux-ci itself, not a dispatch of the workflow that wraps it: the guard reads the job.
        why = guard.verdict(pr(), SWIFT, [check(COMPILE, "queued")])
        self.assertIn(f"cmux-ci compile-check --ref {HEAD} --app", why)
        self.assertNotIn("gh workflow run", why)

    def test_a_missing_compile_result_names_the_fleet_compile_check_first(self):
        """COMMON.md: the default path is a fleet compile-check on the dev-build workers, not waiting on the Mac
        Release compile."""
        for checks in ([], [check(COMPILE, "queued")], [check("cmux-next path routing", "in_progress")]):
            why = guard.verdict(pr(), SWIFT, checks)
            run = f"cmux-ci compile-check --ref {HEAD} --app"
            self.assertIn(run, why)
            self.assertIn("fleet dev-build workers", why)
            self.assertLess(why.index(run), why.index(COMPILE), why)

    def test_the_fleet_compile_check_refusal_reads_whole_with_several_or_oddly_named_swift_files(self):
        """The refusal is built from its parts: a second file (" and more") or a path holding " and " can't split it."""
        base = "Packages/macOS/CmuxNext/Sources/"
        for swift, what in (([base + "A.swift", base + "B.swift"], f"({base}A.swift and more)"),
                            ([base + "Find and Replace.swift"], f"({base}Find and Replace.swift)")):
            why = guard.verdict(pr(), swift, [])
            self.assertTrue(why.startswith(f"#7 changes Swift {what} and {HEAD[:12]} has no compile result yet."), why)
            self.assertTrue(why.endswith(f"({HEAD[:12]} has no checks yet, so no {COMPILE} either.)"), why)
            self.assertEqual(why.count("cmux-ci compile-check"), 1, why)

    def test_a_refusal_names_the_cause_of_its_own_read_not_an_earlier_one(self):
        guard.run(["false"])
        self.assertTrue(guard.FAILED)
        self.assertEqual(guard.run(["true"]), "")
        self.assertEqual(guard.FAILED, [])

    def test_the_workflow_posts_the_status_the_guard_reads_on_the_sha_it_was_given(self):
        text = (ROOT / ".github/workflows" / guard.FLEET_WORKFLOW).read_text()
        self.assertIn(f"run-name: {guard.FLEET_TITLE}" + "${{ inputs.sha }}", text)
        self.assertIn(f"CONTEXT: {guard.FLEET_CONTEXT}\n", text)
        self.assertIn("compile-check --ref \"$SHA\" --app", text)
        self.assertIn("github.ref == 'refs/heads/feat-cmux-next'", text)
        self.assertIn("statuses/$SHA", text)
        self.assertNotIn("pull_request", text)


class AdvisoryTestCompile(unittest.TestCase):
    """fleet-test-compile.yml's check is advisory: the guard neither waits for it nor needs it.

    It compiles the test targets a PR reaches on a fleet Mac (#23360, #23163 broke the base's test build
    after the app-only fleet/compile-check passed). A red or pending one never holds a merge here, and it
    never posts the fleet/compile-check status the guard trusts.
    """

    ADVISORY = "fleet/test-compile (advisory)"
    WORKFLOW = ROOT / ".github/workflows/fleet-test-compile.yml"

    def test_a_red_or_pending_advisory_check_never_holds_a_merge(self):
        for state, conclusion in (("completed", "failure"), ("queued", None), ("in_progress", None)):
            with self.subTest(state=state):
                advisory = check(self.ADVISORY, state, conclusion or "success")
                self.assertEqual(guard.verdict(pr(), SWIFT, [check(COMPILE), advisory]), "")
                self.assertEqual(guard.verdict(pr(), SWIFT, [check(COMPILE, "queued"), advisory], fleet_passed=True), "")
                # And it never stands in for the Release compile.
                self.assertIn("still running", guard.verdict(pr(), SWIFT, [check(COMPILE, "queued"), advisory]))

    def test_it_is_not_the_fleet_check_the_guard_trusts(self):
        self.assertNotEqual(guard.FLEET_WORKFLOW, self.WORKFLOW.name)
        text = self.WORKFLOW.read_text()
        self.assertIn(f"name: {self.ADVISORY}\n", text)
        self.assertNotIn(guard.FLEET_CONTEXT + "\n", text)
        self.assertNotIn("statuses", text)
        self.assertNotIn(guard.FLEET_TITLE, text)
        fleet = (ROOT / ".github/workflows" / guard.FLEET_WORKFLOW).read_text()
        self.assertNotIn("compile-tests", fleet)
        self.assertNotIn("test-compile", fleet)


# #23606 at bf14aa7d: activity-indicators' `cmux-ci compile-check --ref <head> --app` passed (job
# edfa18ea31a796eac433019a, 2026-10-21 19:32Z), the guard still refused the merge, and the lane dispatched
# fleet-compile-check.yml (run 39662744415) to compile the same head again. The controller's record of
# that job and its receipts.json, as `cmux-ci status` and `cmux-ci artifact` gave them (trimmed).
HEAD_23606 = "bf14aa7d4c88f4ff3c7670414a289e561097f4a2"
JOB_23606 = {
    "id": "edfa18ea31a796eac433019a", "kind": "cmux-next-swift-check",
    "command": f"/Users/Shared/cmux-build-fleet/recipes/cmux-next-swift-check.sh {HEAD_23606} --app",
    "repo": "", "ref": HEAD_23606, "labels": ["cmux-next-linux"], "state": "done",
    "artifact": "sha256:aa657e2ba1f8f5047e597dcf23b4eb72e06b77d1781de83136ad187a6d461fde",
    "submitter": "leoli.4u@gmail.com", "submitter_verified": True, "placement_reason": "linux_pool",
    "created_at": "2026-10-21T19:32:16.88696Z", "updated_at": "2026-10-21T19:33:35.356714Z",
}
RECEIPTS_23606 = [{
    "package": "app", "sha": HEAD_23606, "toolchain_id": "swift-6.3.3-cmux+Xcode_26.6/736c824e5bb154f0",
    "ok": True, "seconds": 59.1,
}]


def fake_cmux_ci(bin_dir: Path, jobs, receipts: dict, log: Path) -> Path:
    """A `cmux-ci` that prints `jobs` for `status` and writes receipts[job id] for `artifact JOB OUT`.
    jobs None: the controller can't be reached."""
    script = bin_dir / "cmux-ci"
    script.write_text(textwrap.dedent(f"""\
        #!{sys.executable}
        import json, sys
        args = sys.argv[1:]
        with open({str(log)!r}, "a") as f:
            f.write(json.dumps(["cmux-ci", *args]) + "\\n")
        jobs, receipts = json.loads({json.dumps(json.dumps(jobs))}), json.loads({json.dumps(json.dumps(receipts))})
        if args == ["status"] and jobs is not None:
            print(json.dumps(jobs))
            sys.exit(0)
        if len(args) == 3 and args[0] == "artifact" and args[1] in receipts:
            with open(args[2], "w") as f:
                json.dump(receipts[args[1]], f)
            print("aa657e2b")
            sys.exit(0)
        sys.exit(1)
        """))
    script.chmod(script.stat().st_mode | stat.S_IEXEC)
    return script


def job(**changes):
    return {**JOB_23606, **changes}


class CmuxCiCompileCheck(unittest.TestCase):
    """A passed `cmux-ci compile-check --ref <head> --app` job is the fleet pass itself: the guard reads it
    from the controller, so a lane never dispatches fleet-compile-check.yml to compile the head twice.

    It counts the way the client's own exit 0 does (ci-client.py compile_check): a done
    cmux-next-swift-check job of the recipe on the exact head with --app, whose receipts.json has an
    `app` receipt that is ok, for that sha.
    """

    def passed(self, jobs, receipts=None, head=HEAD_23606):
        with tempfile.TemporaryDirectory() as tmp:
            tmp = Path(tmp)
            log = tmp / "calls.log"
            client = fake_cmux_ci(tmp, jobs, {JOB_23606["id"]: RECEIPTS_23606} if receipts is None else receipts, log)
            saved = os.environ.get("CMUX_CI_CLIENT")
            os.environ["CMUX_CI_CLIENT"] = str(client)
            try:
                return guard.cmux_ci_passed(head)
            finally:
                if saved is None:
                    os.environ.pop("CMUX_CI_CLIENT")
                else:
                    os.environ["CMUX_CI_CLIENT"] = saved

    def test_the_23606_job_is_a_pass_on_its_head(self):
        self.assertTrue(self.passed([job()]))

    def test_packages_with_the_app_count_as_the_client_builds_them(self):
        command = f"/Users/Shared/cmux-build-fleet/recipes/cmux-next-swift-check.sh {HEAD_23606} --package CmuxNext --app"
        self.assertTrue(self.passed([job(command=command)]))

    def test_it_counts_only_on_the_exact_head(self):
        self.assertFalse(self.passed([job()], head="d" * 40))
        self.assertFalse(self.passed([job()], head=HEAD_23606[:12]))

    def test_anything_but_the_passing_app_check_does_not_count(self):
        other = "d" * 40
        cases = {
            "another sha": [job(ref=other, command=JOB_23606["command"].replace(HEAD_23606, other))],
            "ref and command disagree": [job(ref=other)],
            "packages, not the app": [job(command=JOB_23606["command"].replace("--app", "--package CmuxNext"))],
            "another recipe": [job(command=f"/tmp/mine.sh {HEAD_23606} --app")],
            # The worker runs the command with /bin/sh -c, and `cmux-ci submit` takes any command: a suffix could
            # write its own receipts.json.
            "shell suffix": [job(command=JOB_23606["command"] + " ; echo forged > artifacts/receipts.json")],
            "extra argument": [job(command=JOB_23606["command"] + " --skip")],
            "a repo to clone": [job(repo="https://github.com/x/cmux.git")],
            "another pool": [job(labels=["cmux-next-linux", "mine"])],
            "another kind": [job(kind="custom")],
            "failed": [job(state="failed")],
            "still running": [job(state="running")],
            "cancelled": [job(state="cancelled")],
            "unverified submitter": [job(submitter_verified=False)],
            "no jobs": [],
            "controller unreachable": None,
        }
        for name, jobs in cases.items():
            with self.subTest(name):
                self.assertFalse(self.passed(jobs))

    def test_the_receipts_decide_not_the_job_state(self):
        id_ = JOB_23606["id"]
        cases = {
            "app did not compile": {id_: [{**RECEIPTS_23606[0], "ok": False}]},
            "receipt for another sha": {id_: [{**RECEIPTS_23606[0], "sha": "d" * 40}]},
            "no app receipt": {id_: [{**RECEIPTS_23606[0], "package": "CmuxNext"}]},
            "no receipts": {id_: []},
            "artifact unreadable": {},
        }
        for name, receipts in cases.items():
            with self.subTest(name):
                self.assertFalse(self.passed([job()], receipts))
        # The recipe's other receipt shape.
        self.assertTrue(self.passed([job()], {id_: {"receipts": RECEIPTS_23606}}))

    def test_a_newer_failed_job_does_not_hide_an_older_pass(self):
        failed = job(id="f" * 24, created_at="2026-10-21T19:40:00Z")
        self.assertTrue(self.passed([failed, job()], {JOB_23606["id"]: RECEIPTS_23606,
                                                      failed["id"]: [{**RECEIPTS_23606[0], "ok": False}]}))

    def test_no_client_is_no_pass(self):
        saved = os.environ.get("CMUX_CI_CLIENT")
        os.environ["CMUX_CI_CLIENT"] = "/nonexistent/cmux-ci"
        try:
            self.assertFalse(guard.cmux_ci_passed(HEAD_23606))
        finally:
            if saved is None:
                os.environ.pop("CMUX_CI_CLIENT")
            else:
                os.environ["CMUX_CI_CLIENT"] = saved


def status(state="success", creator="github-actions[bot]", run=99):
    return {"state": state, "creator": creator, "url": f"https://github.com/manaflow-ai/cmux/actions/runs/{run}"}


RUN_SHA, TIP = "e" * 40, "f" * 40  # the commit the fleet run's workflow file came from; feat-cmux-next's tip


def fleet_run(sha=HEAD, branch="feat-cmux-next", path=None, event="workflow_dispatch", conclusion="success",
              head_sha=RUN_SHA):
    return {"path": path or f".github/workflows/{guard.FLEET_WORKFLOW}", "head_branch": branch, "event": event,
            "status": "completed" if conclusion else "in_progress", "conclusion": conclusion,
            "display_title": f"{guard.FLEET_TITLE}{sha}", "head_sha": head_sha}


class Targets(unittest.TestCase):
    def targets(self, command):
        return [(repo, selector) for repo, selector, _ in guard.merge_targets(command, "/tmp")]

    def test_every_merge_form_names_its_pull_request(self):
        cmux = "manaflow-ai/cmux"
        cases = {
            "gh pr merge 22835 --squash": [(None, "22835")],
            "gh pr merge 22835 -R manaflow-ai/cmux --squash": [(cmux, "22835")],
            "gh pr merge --squash --repo manaflow-ai/cmux '#21480'": [(cmux, "21480")],
            # Unquoted, `#21480` is a shell comment: the checkout's branch is what merges.
            "gh pr merge --squash --repo manaflow-ai/cmux #21480": [(cmux, None)],
            "gh pr merge --repo=manaflow-ai/cmux 8": [(cmux, "8")],
            "gh pr merge https://github.com/manaflow-ai/cmux/pull/21487 --auto --squash": [(cmux, "21487")],
            "gh pr merge --squash -t 'fix 123' 9": [(None, "9")],
            'gh pr merge -b "it\\"s 99" 7': [(None, "7")],
            "gh pr merge --squash": [(None, None)],
            # A redirect's fd is not a pull request; the checkout's branch is merged.
            "gh pr merge --squash 2>/dev/null": [(None, None)],
            "gh pr merge --squash --delete-branch 2>&1": [(None, None)],
            "gh pr merge --squash\ngit log -1 4242": [(None, None)],
            "gh pr merge my-branch": [(None, "my-branch")],
            "gh pr merge 123-fix": [(None, "123-fix")],
            'gh pr merge "$PR" --squash': [(None, guard.UNKNOWN)],
            "gh api -X PUT repos/manaflow-ai/cmux/pulls/22914/merge -f merge_method=squash -f sha=abc":
                [(cmux, "22914")],
            "gh api -X PUT repos/{owner}/{repo}/pulls/5/merge": [(None, "5")],
            'gh api -X PUT "repos/manaflow-ai/cmux/pulls/$N/merge"': [(cmux, guard.UNKNOWN)],
            'gh api graphql -f query="mutation{mergePullRequest(input:{})}"': [(None, guard.UNKNOWN)],
            "GH_REPO=manaflow-ai/cmux gh pr merge 5": [(cmux, "5")],
            "git log && gh pr merge 3 -R manaflow-ai/cmux --squash": [(cmux, "3")],
            # A redirect with no fd of its own leaves the number before it alone.
            "gh pr merge 5 >out.txt 2>&1": [(None, "5")],
            "gh pr merge 5 > /tmp/log 2>&1": [(None, "5")],
            # A comment ends at its newline; the next line still runs.
            "echo hi # merge next\ngh pr merge 5 --squash": [(None, "5")],
            'git commit -m "a # b" && gh pr merge 9': [(None, "9")],
            "gh pr merge feat#2": [(None, "feat#2")],
            # Wrappers and shells run the merge too.
            'bash -c "gh pr merge 5"': [(None, "5")],
            "env GH_REPO=manaflow-ai/cmux gh pr merge 5": [(cmux, "5")],
            "command gh pr merge 5": [(None, "5")],
            "/opt/homebrew/bin/gh pr merge 5": [(None, "5")],
            "nice -n 10 gh pr merge 5": [(None, "5")],
            "gh pr merge 5 --squash; echo $'it\\'s'": [(None, "5")],
            'echo "unbalanced && gh pr merge 5': [(None, guard.UNKNOWN)],
            # Control structures, timeouts and command substitution run the merge too.
            "if gh pr checks 5 >/dev/null; then gh pr merge 5 --squash; fi": [(None, "5")],
            "for p in 5; do gh pr merge 5 --squash; done": [(None, "5")],
            "{ gh pr merge 5 --squash; }": [(None, "5")],
            "! gh pr merge 5 --squash": [(None, "5")],
            "timeout 60 gh pr merge 5 --squash": [(None, "5")],
            "timeout -k 5 60 gh pr merge 5": [(None, "5")],
            "echo `gh pr merge 5`": [(None, "5")],
            "out=$(gh pr merge 5 --squash 2>&1)": [(None, "5")],
        }
        for command, want in cases.items():
            with self.subTest(command=command):
                self.assertEqual(self.targets(command), want)

    def test_a_cd_before_the_merge_moves_its_checkout(self):
        self.assertEqual(guard.merge_targets("cd ../other && gh pr merge 6", "/tmp/a"), [(None, "6", "/tmp/a/../other")])

    def test_text_that_only_mentions_a_merge_names_nothing(self):
        for command in ("git merge origin/feat-cmux-next", "gh pr view 3 --json mergeable",
                        "gh api repos/manaflow-ai/cmux/pulls/3/update-branch -X PUT", "echo gh pr merged",
                        'git grep -n "gh pr merge"', 'rg "gh pr merge N --squash" CLAUDE.md',
                        'git commit -m "docs: use gh pr merge 22835 --squash"',
                        "cat > notes.md <<'EOF'\nthen gh pr merge 77\nEOF\necho done",
                        "echo 'unbalanced"):
            with self.subTest(command=command):
                self.assertEqual(self.targets(command), [])

    def test_other_repositories_are_not_guarded(self):
        reader = lambda *a: self.fail("read another repo")  # noqa: E731
        self.assertEqual(guard.refusal("gh pr merge 662 -R teamleaderleo/leo-workspace --squash", None, reader), "")

    def test_a_merge_in_a_checkout_it_cannot_read_is_a_warning_unless_it_names_the_repo(self):
        for command in ('ssh host "cd wt && gh pr merge 5"', 'cd "$WT" && gh pr merge 5'):
            with self.subTest(command=command):
                self.assertEqual(guard.merge_targets(command, "/tmp")[0][2], guard.REMOTE)
                why = guard.refusal(command, "/tmp", lambda *a: self.fail("read"))
                self.assertIn("can't read", why)
                self.assertIsInstance(why, guard.Hold)
        self.assertEqual(guard.refusal('ssh host "gh pr merge 5 -R manaflow-ai/cmux"', "/tmp", lambda *a: ""), "")
        # Unquoted, ssh joins the words into the remote command.
        self.assertEqual(guard.merge_targets("ssh -p 22 cmux16 gh pr merge 5 -R manaflow-ai/cmux", "/tmp"),
                         [("manaflow-ai/cmux", "5", guard.REMOTE)])

    def test_a_merge_whose_checkout_cannot_be_read_is_a_warning(self):
        # Out of time (or no git): the checkout's repository is unknown, so the merge can't be judged.
        spent = guard.STARTED
        try:
            guard.STARTED = guard.time.monotonic() - guard.BUDGET
            why = guard.refusal("gh pr merge 5 --squash", "/tmp", lambda *a: self.fail("read"))
            self.assertIn("can't tell which repository", why)
            self.assertIsInstance(why, guard.Hold)
        finally:
            guard.STARTED = spent

    def test_a_merge_it_cannot_name_is_a_warning(self):
        why = guard.refusal('gh pr merge "$PR" -R manaflow-ai/cmux', None, lambda *a: self.fail("read"))
        self.assertIn("can't name", why)
        self.assertIsInstance(why, guard.Hold)

    def test_a_warning_never_hides_a_red_compile_later_in_the_command(self):
        red = "#5 changes Swift (A.swift) and its compile finished failure on cccccccccccc."
        why = guard.refusal('gh pr merge "$PR" -R manaflow-ai/cmux; gh pr merge 5 -R manaflow-ai/cmux', None,
                            lambda *a: red)
        self.assertEqual(why, f"merge-compile-guard: {red}")
        self.assertNotIsInstance(why, guard.Hold)
        held = guard.refusal("gh pr merge 5 -R manaflow-ai/cmux", None, lambda *a: guard.Hold("still running"))
        self.assertIsInstance(held, guard.Hold)


def fake_gh(bin_dir: Path, answers: dict[str, str], log: Path, throttle: float = 0, sleep: float = 0) -> None:
    """A `gh` that prints answers[<the first argument that names an endpoint>] and logs its argv. throttle: seconds
    it sleeps first unless CMUX_GH_GUARD_DISABLE=1, as the PATH guard ~/.local/lib/cmux-local-build-guards/gh does
    for a read its caller repeats within 30 s; sleep: seconds it sleeps whatever the environment (a slow GitHub)."""
    script = bin_dir / "gh"
    script.write_text(textwrap.dedent(f"""\
        #!{sys.executable}
        import json, os, sys, time
        if os.environ.get("CMUX_GH_GUARD_DISABLE") != "1":
            time.sleep({throttle})
        time.sleep({sleep})
        args = sys.argv[1:]
        with open({str(log)!r}, "a") as f:
            f.write(json.dumps(args) + "\\n")
        answers = {json.dumps(answers)}
        for arg in args:
            for key, value in answers.items():
                if arg.startswith(key):
                    print(value)
                    sys.exit(0)
        sys.exit(1)
        """))
    script.chmod(script.stat().st_mode | stat.S_IEXEC)


class Hook(unittest.TestCase):
    @staticmethod
    def denial(out) -> str | None:
        """The hook's refusal, or None when the command goes ahead (with or without a warning)."""
        decision = (out or {}).get("hookSpecificOutput") or {}
        return decision.get("permissionDecisionReason") if decision.get("permissionDecision") == "deny" else None

    def warning(self, out) -> str:
        """What the hook says about a merge it lets through: shown to the person and added to the agent's context."""
        self.assertIsNotNone(out)
        self.assertIsNone(self.denial(out), out)
        self.assertNotIn("permissionDecision", out["hookSpecificOutput"])
        self.assertEqual(out["systemMessage"], out["hookSpecificOutput"]["additionalContext"])
        self.assertIn("merging anyway", out["systemMessage"])
        return out["systemMessage"]

    def run_hook(self, command: str, compile_state: tuple[str, str | None] | None, statuses=None, fleet_runs=None,
                 other_statuses=None, on_base="ahead", head=HEAD, cmux_ci_jobs=(), cmux_ci_receipts=None,
                 gh_throttle=0, gh_sleep=0, env_extra=None):
        """statuses: the head's fleet/compile-check statuses; fleet_runs: {run id: fleet_run()}; other_statuses:
        statuses on another sha; cmux_ci_jobs, cmux_ci_receipts: what the controller holds (fake_cmux_ci)."""
        with tempfile.TemporaryDirectory() as tmp:
            tmp = Path(tmp)
            subprocess.run(["git", "init", "-q", str(tmp)], check=True)
            subprocess.run(["git", "-C", str(tmp), "remote", "add", "origin", "https://github.com/manaflow-ai/cmux.git"],
                           check=True)
            bin_dir = tmp / "bin"
            bin_dir.mkdir()
            log = tmp / "gh.log"
            runs = [check("cmux-next path routing")]
            if compile_state:
                runs.append(check(COMPILE, *compile_state))
            answers = {
                "repos/manaflow-ai/cmux/pulls/22835/files": "\n".join(json.dumps(f) for f in SWIFT),
                "repos/manaflow-ai/cmux/pulls/22835": json.dumps(pr(22835, head=head)),
                "view": json.dumps({"number": 22835}),
                f"repos/manaflow-ai/cmux/commits/{head}/check-runs?filter=all": "\n".join(json.dumps(r) for r in runs),
            }
            if statuses is not None:
                answers[f"repos/manaflow-ai/cmux/commits/{HEAD}/statuses"] = "\n".join(json.dumps(s) for s in statuses)
            if other_statuses is not None:
                answers[f"repos/manaflow-ai/cmux/commits/{'d' * 40}/statuses"] = "\n".join(
                    json.dumps(s) for s in other_statuses)
            for run_id, run in (fleet_runs or {}).items():
                answers[f"repos/manaflow-ai/cmux/actions/runs/{run_id}"] = json.dumps(run)
            answers["repos/manaflow-ai/cmux/branches/feat-cmux-next"] = json.dumps(TIP)
            if on_base:
                answers[f"repos/manaflow-ai/cmux/compare/{RUN_SHA}...{TIP}"] = json.dumps(on_base)
            fake_gh(bin_dir, answers, log, throttle=gh_throttle, sleep=gh_sleep)
            client = fake_cmux_ci(bin_dir, list(cmux_ci_jobs) if cmux_ci_jobs is not None else None,
                                  cmux_ci_receipts or {JOB_23606["id"]: RECEIPTS_23606}, log)
            payload = json.dumps({"tool_name": "Bash", "cwd": str(tmp), "tool_input": {"command": command}})
            env = {**os.environ, "PATH": f"{bin_dir}{os.pathsep}{os.environ['PATH']}", "CMUX_CI_CLIENT": str(client),
                   **(env_extra or {})}
            env.pop("CMUX_GH_GUARD_DISABLE", None)
            done = subprocess.run(["bash", str(HOOK)], input=payload, capture_output=True, text=True, env=env,
                                  timeout=60)
            self.assertEqual(done.returncode, 0, done.stderr)
            calls = log.read_text().splitlines() if log.exists() else []
            return (json.loads(done.stdout) if done.stdout.strip() else None), calls

    def test_a_merge_with_the_compile_pending_goes_ahead_with_a_warning(self):
        out, _ = self.run_hook("gh pr merge 22835 -R manaflow-ai/cmux --squash", ("in_progress", None))
        why = self.warning(out)
        self.assertIn("#22835 changes Swift", why)
        self.assertIn("still running", why)

    def test_a_merge_after_a_red_compile_is_refused(self):
        out, _ = self.run_hook("gh pr merge 22835 -R manaflow-ai/cmux --squash", ("completed", "failure"))
        self.assertIn("#22835 changes Swift", self.denial(out))
        self.assertIn("finished failure", self.denial(out))

    def test_a_merge_after_a_green_compile_goes_ahead(self):
        out, calls = self.run_hook("gh pr merge 22835 -R manaflow-ai/cmux --squash", ("completed", "success"))
        self.assertIsNone(out)
        self.assertTrue(any("--paginate" in json.loads(c) for c in calls))

    def test_a_bare_merge_checks_the_checkouts_branch(self):
        """gh refuses `pr view -R` without a selector, so the branch is looked up in the checkout."""
        out, calls = self.run_hook("gh pr merge --squash 2>&1", ("in_progress", None))
        self.assertIn("#22835 changes Swift", self.warning(out))
        view = [json.loads(c) for c in calls if json.loads(c)[:2] == ["pr", "view"]]
        self.assertEqual(view, [["pr", "view", "--json", "number"]])
        out, _ = self.run_hook("gh pr merge --squash", ("completed", "success"))
        self.assertIsNone(out)

    def test_the_gh_guards_repeat_throttle_does_not_slow_the_guard(self):
        """2026-10-21: the hook shares the session's CLAUDE_SESSION_ID, so after a lane's `gh pr view N` the PATH guard
        held the hook's identical read up to 30 s and #23611's merges were refused as unreadable. The guard reads once
        per merge and never polls: its reads skip the throttle."""
        started = time.monotonic()
        out, _ = self.run_hook("gh pr merge 22835 -R manaflow-ai/cmux --squash", ("completed", "success"), gh_throttle=30)
        self.assertIsNone(out)
        self.assertLess(time.monotonic() - started, 10)

    def test_a_slow_github_lets_the_merge_through_and_says_it_timed_out(self):
        """The guard's own read timing out is no evidence against the PR (#23660 and #23371, 2026-10-21)."""
        out, _ = self.run_hook("gh pr merge 22835 -R manaflow-ai/cmux --squash", ("completed", "success"), gh_sleep=5,
                               env_extra={"CMUX_MERGE_GUARD_GH_TIMEOUT": "1"})
        why = self.warning(out)
        self.assertIn("could not read #22835 from GitHub", why)
        self.assertIn("did not answer within 1 s", why)
        self.assertNotIn("rate limit", why)

    def test_an_unreadable_github_lets_the_merge_through(self):
        out, _ = self.run_hook("gh pr merge 1 -R manaflow-ai/cmux --squash", None)
        self.assertIn("could not read #1 from GitHub", self.warning(out))

    MERGE = "gh pr merge 22835 -R manaflow-ai/cmux --squash"

    def test_a_fleet_pass_on_the_exact_head_lets_a_queued_compile_merge(self):
        out, calls = self.run_hook(self.MERGE, ("queued", None), statuses=[status()], fleet_runs={99: fleet_run()})
        self.assertIsNone(out)
        self.assertTrue(any(f"commits/{HEAD}/statuses" in " ".join(json.loads(c)) for c in calls))

    def test_a_fleet_pass_on_a_different_sha_does_not_count(self):
        # The pass was posted on another commit (an older head): the head has no status.
        out, _ = self.run_hook(self.MERGE, ("queued", None), statuses=[], other_statuses=[status()],
                               fleet_runs={99: fleet_run(sha="d" * 40)})
        self.assertIn("still running", self.warning(out))
        # A status on the head that links a run which compiled another sha.
        out, _ = self.run_hook(self.MERGE, ("queued", None), statuses=[status()],
                               fleet_runs={99: fleet_run(sha="d" * 40)})
        self.assertIn("still running", self.warning(out))
        # A run that names only a prefix of the head.
        out, _ = self.run_hook(self.MERGE, ("queued", None), statuses=[status()],
                               fleet_runs={99: fleet_run(sha=HEAD[:12])})
        self.assertIn("still running", self.warning(out))

    def test_a_self_posted_or_unverified_fleet_status_does_not_count(self):
        cases = {
            "posted by a person or agent token": ([status(creator="teamleaderleo")], {99: fleet_run()}),
            "not success": ([status(state="failure")], {99: fleet_run()}),
            "run from another branch": ([status()], {99: fleet_run(branch="my-branch")}),
            "another workflow": ([status()], {99: fleet_run(path=".github/workflows/mine.yml")}),
            "not a dispatch": ([status()], {99: fleet_run(event="push")}),
            # A tag named feat-cmux-next holding a doctored copy of the workflow has head_branch feat-cmux-next.
            "workflow from a commit not on the branch": ([status()], {99: fleet_run(head_sha="a" * 40)}),
            "run failed": ([status()], {99: fleet_run(conclusion="failure")}),
            "run unreadable": ([status(run=98)], {99: fleet_run()}),
            "link to another repo's run": ([{**status(), "url": "https://github.com/x/cmux/actions/runs/99"}],
                                            {99: fleet_run()}),
        }
        for name, (statuses, fleet_runs) in cases.items():
            with self.subTest(name):
                out, _ = self.run_hook(self.MERGE, ("queued", None), statuses=statuses, fleet_runs=fleet_runs)
                self.assertIn("no compile result yet", self.warning(out), name)

    def test_a_run_whose_workflow_commit_left_the_branch_does_not_count(self):
        for on_base in ("diverged", "behind", None):
            with self.subTest(on_base=on_base):
                out, _ = self.run_hook(self.MERGE, ("queued", None), statuses=[status()],
                                       fleet_runs={99: fleet_run()}, on_base=on_base)
                self.assertIn("no compile result yet", self.warning(out))

    def test_every_attempt_of_the_compile_is_read(self):
        out, calls = self.run_hook(self.MERGE, ("queued", None), statuses=[status()], fleet_runs={99: fleet_run()})
        self.assertTrue(any("check-runs?filter=all&" in " ".join(json.loads(c)) for c in calls))

    def test_a_fleet_pass_does_not_let_a_red_release_compile_merge(self):
        out, calls = self.run_hook(self.MERGE, ("completed", "failure"), statuses=[status()],
                                   fleet_runs={99: fleet_run()})
        self.assertIn("finished failure", self.denial(out))
        self.assertFalse(any("statuses" in " ".join(json.loads(c)) for c in calls))

    def test_a_newer_unverified_status_does_not_hide_a_verified_pass(self):
        out, _ = self.run_hook(self.MERGE, ("queued", None), statuses=[status(state="pending", run=98), status()],
                               fleet_runs={99: fleet_run()})
        self.assertIsNone(out)

    def test_the_23606_cmux_ci_pass_lets_its_queued_compile_merge_without_a_dispatch(self):
        # No fleet/compile-check status: the lane ran cmux-ci itself and never dispatched the workflow.
        out, calls = self.run_hook(self.MERGE, ("queued", None), statuses=[], head=HEAD_23606,
                                   cmux_ci_jobs=[job()])
        self.assertIsNone(out)
        self.assertIn(["cmux-ci", "status"], [json.loads(c) for c in calls])
        self.assertFalse(any("statuses" in " ".join(json.loads(c)) for c in calls))  # no GitHub read for it

    def test_a_cmux_ci_pass_on_another_head_refuses_and_says_what_to_run(self):
        out, _ = self.run_hook(self.MERGE, ("queued", None), statuses=[], cmux_ci_jobs=[job()])
        why = self.warning(out)
        self.assertIn("still running", why)
        self.assertIn(f"cmux-ci compile-check --ref {HEAD} --app", why)

    def test_a_cmux_ci_pass_does_not_let_a_red_release_compile_merge(self):
        out, calls = self.run_hook(self.MERGE, ("completed", "failure"), head=HEAD_23606, cmux_ci_jobs=[job()])
        self.assertIn("finished failure", self.denial(out))
        self.assertNotIn(["cmux-ci", "status"], [json.loads(c) for c in calls])

    def test_an_unreachable_controller_falls_back_to_the_fleet_status(self):
        out, _ = self.run_hook(self.MERGE, ("queued", None), statuses=[status()], fleet_runs={99: fleet_run()},
                               cmux_ci_jobs=None)
        self.assertIsNone(out)

    def test_a_green_compile_reads_no_fleet_status(self):
        out, calls = self.run_hook(self.MERGE, ("completed", "success"), statuses=[], cmux_ci_jobs=[job()])
        self.assertIsNone(out)
        self.assertFalse(any("statuses" in " ".join(json.loads(c)) for c in calls))
        self.assertNotIn(["cmux-ci", "status"], [json.loads(c) for c in calls])

    def test_other_commands_never_start_python_or_gh(self):
        out, calls = self.run_hook("git status && gh pr view 22835", None)
        self.assertIsNone(out)
        self.assertEqual(calls, [])


if __name__ == "__main__":
    unittest.main()
