#!/usr/bin/env python3
"""merge_compile_guard: a hand merge of a feat-cmux-next PR that changes Swift waits for its Release compile.

On 2026-10-21 (UTC) #22835, #21480 and #21487 were merged with `gh pr merge` while their compile was pending.
"""
from __future__ import annotations

import json
import os
import stat
import subprocess
import sys
import tempfile
import textwrap
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
HOOK = ROOT / "scripts/ci/merge-compile-guard-hook.sh"
sys.path.insert(0, str(ROOT / "scripts/ci"))
import merge_compile_guard as guard  # noqa: E402

COMPILE = guard.COMPILE
HEAD = "c" * 40
SWIFT = ["Packages/macOS/CmuxNext/Sources/A.swift"]


def pr(number=7, base="feat-cmux-next"):
    return {"number": number, "base": base, "head": HEAD, "state": "open"}


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

    def test_a_compile_not_created_yet_waits_while_cmux_next_routes_and_places(self):
        for job in guard.ROUTING:
            with self.subTest(job=job):
                self.assertIn("has not created", guard.verdict(pr(), SWIFT, [check(job, "in_progress")]))
        self.assertIn("no checks yet", guard.verdict(pr(), SWIFT, []))
        # cmux-next finished routing without a compile, or never ran on this head.
        self.assertEqual(guard.verdict(pr(), SWIFT, [check("cmux-next path routing")]), "")
        self.assertEqual(guard.verdict(pr(), SWIFT, [check("web / lint")]), "")

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
        why = guard.verdict(pr(), SWIFT, [check(COMPILE, "queued")])
        self.assertIn(f"gh workflow run {guard.FLEET_WORKFLOW} --ref feat-cmux-next -f sha={HEAD}", why)

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

    def test_a_merge_in_a_checkout_it_cannot_read_is_refused_unless_it_names_the_repo(self):
        for command in ('ssh host "cd wt && gh pr merge 5"', 'cd "$WT" && gh pr merge 5'):
            with self.subTest(command=command):
                self.assertEqual(guard.merge_targets(command, "/tmp")[0][2], guard.REMOTE)
                self.assertIn("can't read", guard.refusal(command, "/tmp", lambda *a: self.fail("read")))
        self.assertEqual(guard.refusal('ssh host "gh pr merge 5 -R manaflow-ai/cmux"', "/tmp", lambda *a: ""), "")
        # Unquoted, ssh joins the words into the remote command.
        self.assertEqual(guard.merge_targets("ssh -p 22 cmux16 gh pr merge 5 -R manaflow-ai/cmux", "/tmp"),
                         [("manaflow-ai/cmux", "5", guard.REMOTE)])

    def test_a_merge_whose_checkout_cannot_be_read_is_refused(self):
        # Out of time (or no git): the checkout's repository is unknown, so the merge can't be judged.
        spent = guard.STARTED
        try:
            guard.STARTED = guard.time.monotonic() - guard.BUDGET
            self.assertIn("can't tell which repository", guard.refusal("gh pr merge 5 --squash", "/tmp",
                                                                      lambda *a: self.fail("read")))
        finally:
            guard.STARTED = spent

    def test_a_merge_it_cannot_name_is_refused(self):
        why = guard.refusal('gh pr merge "$PR" -R manaflow-ai/cmux', None, lambda *a: self.fail("read"))
        self.assertIn("can't name", why)


def fake_gh(bin_dir: Path, answers: dict[str, str], log: Path) -> None:
    """A `gh` that prints answers[<the first argument that names an endpoint>] and logs its argv."""
    script = bin_dir / "gh"
    script.write_text(textwrap.dedent(f"""\
        #!{sys.executable}
        import json, sys
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
    def run_hook(self, command: str, compile_state: tuple[str, str | None] | None, statuses=None, fleet_runs=None,
                 other_statuses=None, on_base="ahead"):
        """statuses: the head's fleet/compile-check statuses; fleet_runs: {run id: fleet_run()}; other_statuses:
        statuses on another sha."""
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
                "repos/manaflow-ai/cmux/pulls/22835": json.dumps(pr(22835)),
                "view": json.dumps({"number": 22835}),
                f"repos/manaflow-ai/cmux/commits/{HEAD}/check-runs?filter=all": "\n".join(json.dumps(r) for r in runs),
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
            fake_gh(bin_dir, answers, log)
            payload = json.dumps({"tool_name": "Bash", "cwd": str(tmp), "tool_input": {"command": command}})
            env = {**os.environ, "PATH": f"{bin_dir}{os.pathsep}{os.environ['PATH']}"}
            done = subprocess.run(["bash", str(HOOK)], input=payload, capture_output=True, text=True, env=env,
                                  timeout=60)
            self.assertEqual(done.returncode, 0, done.stderr)
            calls = log.read_text().splitlines() if log.exists() else []
            return (json.loads(done.stdout) if done.stdout.strip() else None), calls

    def test_a_merge_with_the_compile_pending_is_refused(self):
        out, _ = self.run_hook("gh pr merge 22835 -R manaflow-ai/cmux --squash", ("in_progress", None))
        decision = out["hookSpecificOutput"]
        self.assertEqual(decision["permissionDecision"], "deny")
        self.assertIn("#22835 changes Swift", decision["permissionDecisionReason"])

    def test_a_merge_after_a_green_compile_goes_ahead(self):
        out, calls = self.run_hook("gh pr merge 22835 -R manaflow-ai/cmux --squash", ("completed", "success"))
        self.assertIsNone(out)
        self.assertTrue(any("--paginate" in json.loads(c) for c in calls))

    def test_a_bare_merge_checks_the_checkouts_branch(self):
        """gh refuses `pr view -R` without a selector, so the branch is looked up in the checkout."""
        out, calls = self.run_hook("gh pr merge --squash 2>&1", ("in_progress", None))
        self.assertIn("#22835 changes Swift", out["hookSpecificOutput"]["permissionDecisionReason"])
        view = [json.loads(c) for c in calls if json.loads(c)[:2] == ["pr", "view"]]
        self.assertEqual(view, [["pr", "view", "--json", "number"]])
        out, _ = self.run_hook("gh pr merge --squash", ("completed", "success"))
        self.assertIsNone(out)

    def test_an_unreadable_github_refuses(self):
        out, _ = self.run_hook("gh pr merge 1 -R manaflow-ai/cmux --squash", None)
        self.assertIn("could not read #1 from GitHub", out["hookSpecificOutput"]["permissionDecisionReason"])

    MERGE = "gh pr merge 22835 -R manaflow-ai/cmux --squash"

    def test_a_fleet_pass_on_the_exact_head_lets_a_queued_compile_merge(self):
        out, calls = self.run_hook(self.MERGE, ("queued", None), statuses=[status()], fleet_runs={99: fleet_run()})
        self.assertIsNone(out)
        self.assertTrue(any(f"commits/{HEAD}/statuses" in " ".join(json.loads(c)) for c in calls))

    def test_a_fleet_pass_on_a_different_sha_does_not_count(self):
        # The pass was posted on another commit (an older head): the head has no status.
        out, _ = self.run_hook(self.MERGE, ("queued", None), statuses=[], other_statuses=[status()],
                               fleet_runs={99: fleet_run(sha="d" * 40)})
        self.assertIn("still running", out["hookSpecificOutput"]["permissionDecisionReason"])
        # A status on the head that links a run which compiled another sha.
        out, _ = self.run_hook(self.MERGE, ("queued", None), statuses=[status()],
                               fleet_runs={99: fleet_run(sha="d" * 40)})
        self.assertIn("still running", out["hookSpecificOutput"]["permissionDecisionReason"])
        # A run that names only a prefix of the head.
        out, _ = self.run_hook(self.MERGE, ("queued", None), statuses=[status()],
                               fleet_runs={99: fleet_run(sha=HEAD[:12])})
        self.assertIn("still running", out["hookSpecificOutput"]["permissionDecisionReason"])

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
                self.assertIsNotNone(out, name)
                self.assertEqual(out["hookSpecificOutput"]["permissionDecision"], "deny")

    def test_a_run_whose_workflow_commit_left_the_branch_does_not_count(self):
        for on_base in ("diverged", "behind", None):
            with self.subTest(on_base=on_base):
                out, _ = self.run_hook(self.MERGE, ("queued", None), statuses=[status()],
                                       fleet_runs={99: fleet_run()}, on_base=on_base)
                self.assertEqual(out["hookSpecificOutput"]["permissionDecision"], "deny")

    def test_every_attempt_of_the_compile_is_read(self):
        out, calls = self.run_hook(self.MERGE, ("queued", None), statuses=[status()], fleet_runs={99: fleet_run()})
        self.assertTrue(any("check-runs?filter=all&" in " ".join(json.loads(c)) for c in calls))

    def test_a_fleet_pass_does_not_let_a_red_release_compile_merge(self):
        out, calls = self.run_hook(self.MERGE, ("completed", "failure"), statuses=[status()],
                                   fleet_runs={99: fleet_run()})
        self.assertIn("finished failure", out["hookSpecificOutput"]["permissionDecisionReason"])
        self.assertFalse(any("statuses" in " ".join(json.loads(c)) for c in calls))

    def test_a_newer_unverified_status_does_not_hide_a_verified_pass(self):
        out, _ = self.run_hook(self.MERGE, ("queued", None), statuses=[status(state="pending", run=98), status()],
                               fleet_runs={99: fleet_run()})
        self.assertIsNone(out)

    def test_a_green_compile_reads_no_fleet_status(self):
        out, calls = self.run_hook(self.MERGE, ("completed", "success"), statuses=[])
        self.assertIsNone(out)
        self.assertFalse(any("statuses" in " ".join(json.loads(c)) for c in calls))

    def test_other_commands_never_start_python_or_gh(self):
        out, calls = self.run_hook("git status && gh pr view 22835", None)
        self.assertIsNone(out)
        self.assertEqual(calls, [])


if __name__ == "__main__":
    unittest.main()
