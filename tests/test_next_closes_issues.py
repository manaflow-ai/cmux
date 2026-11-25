"""scripts/ci/next_closes_issues.py: a pull request merged into feat-cmux-next closes the issues it names.

GitHub closes an issue from "Fixes #N" only when the pull request merges into the default branch
(main), so a feat-cmux-next merge left its fixed issues open. The workflow
.github/workflows/cmux-next-closes-issues.yml runs this script on each merge.
"""

import importlib.util
import json
import os
import pathlib
import subprocess
import sys
import tempfile
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[1]
WORKFLOW = ROOT / ".github/workflows/cmux-next-closes-issues.yml"
REPO = "manaflow-ai/cmux"


def load(name, relative):
    spec = importlib.util.spec_from_file_location(name, ROOT / relative)
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


CLOSES = load("next_closes_issues", "scripts/ci/next_closes_issues.py")


def refs(text):
    return CLOSES.closing_refs(text, REPO)


class ClosingRefsTests(unittest.TestCase):
    def test_every_github_keyword_in_any_case(self):
        words = ["close", "closes", "closed", "fix", "fixes", "fixed", "resolve", "resolves", "resolved"]
        for index, word in enumerate(words, start=1):
            for spelled in (word, word.upper(), word.capitalize()):
                with self.subTest(word=spelled):
                    self.assertEqual(refs(f"{spelled} #{index}"), [index])

    def test_colon_after_the_keyword(self):
        self.assertEqual(refs("Fixes: #48434"), [48434])

    def test_this_repo_by_name_and_by_url(self):
        self.assertEqual(refs("Fixes manaflow-ai/cmux#46019"), [46019])
        self.assertEqual(refs("Closes MANAFLOW-AI/CMUX#46019"), [46019])
        self.assertEqual(refs("Resolves https://github.com/manaflow-ai/cmux/issues/49392"), [49392])

    def test_other_repos_are_left_alone(self):
        self.assertEqual(refs("Fixes manaflow-ai/cmuxterm-hq#12"), [])
        self.assertEqual(refs("Fixes https://github.com/manaflow-ai/cmux-platform/issues/12"), [])
        self.assertEqual(refs("Fixes other/cmux#12"), [])

    def test_several_refs_in_order_without_repeats(self):
        body = "Fixes #3, fixes #1.\nAlso closes #3 and resolves manaflow-ai/cmux#2"
        self.assertEqual(refs(body), [3, 1, 2])

    def test_a_keyword_must_name_the_ref(self):
        self.assertEqual(refs("See #12, related to #13"), [])
        # GitHub needs the keyword before each ref: the second one is only a mention.
        self.assertEqual(refs("Fixes #12, #13"), [12])

    def test_keyword_inside_a_longer_word_does_not_count(self):
        self.assertEqual(refs("prefixes #12"), [])
        self.assertEqual(refs("hotfix #12"), [])
        self.assertEqual(refs("unresolved #12"), [])
        self.assertEqual(refs("closest #12"), [])

    def test_ref_must_end_at_the_number(self):
        self.assertEqual(refs("Fixes #12abc"), [])
        self.assertEqual(refs("Fixes #12."), [12])
        self.assertEqual(refs("(fixes #12)"), [12])

    def test_template_comments_and_code_are_not_refs(self):
        body = "\n".join([
            "<!-- If this closes an issue, say `Fixes #1234` here. -->",
            "Run `fixes #99` in the shell.",
            "```",
            "Fixes #98",
            "```",
            "~~~text",
            "closes #97",
            "~~~",
            "Fixes #5",
        ])
        self.assertEqual(refs(body), [5])

    def test_empty_and_missing_text(self):
        self.assertEqual(refs(""), [])
        self.assertEqual(refs(None), [])


def event(**pr):
    base = {
        "number": 48464,
        "merged": True,
        "merge_commit_sha": "a" * 40,
        "title": "Sidebar: keep the folder open",
        "body": "Fixes #48434",
        "base": {"ref": "feat-cmux-next"},
        "head": {"repo": {"full_name": REPO}},
    }
    base.update(pr)
    return {"action": "closed", "pull_request": base, "repository": {"full_name": REPO}}


class PlanTests(unittest.TestCase):
    def test_merged_pull_request_names_its_issues(self):
        plan = CLOSES.plan(event(title="Fix #7: sidebar", body="Fixes #48434"), REPO)
        self.assertIsNone(plan.skip)
        self.assertEqual(plan.issues, [7, 48434])
        self.assertEqual(plan.pull, 48464)
        self.assertEqual(plan.comment, f"Fixed on feat-cmux-next by #48464 ({'a' * 40}).")

    def test_closed_without_merge_does_nothing(self):
        plan = CLOSES.plan(event(merged=False), REPO)
        self.assertEqual(plan.issues, [])
        self.assertIn("not merged", plan.skip)

    def test_other_base_does_nothing(self):
        # main is the default branch: GitHub closes those issues itself.
        plan = CLOSES.plan(event(base={"ref": "main"}), REPO)
        self.assertEqual(plan.issues, [])
        self.assertIn("feat-cmux-next", plan.skip)

    def test_fork_pull_request_is_skipped(self):
        plan = CLOSES.plan(event(head={"repo": {"full_name": "someone/cmux"}}), REPO)
        self.assertEqual(plan.issues, [])
        self.assertIn("fork", plan.skip)

    def test_pull_request_never_closes_itself(self):
        plan = CLOSES.plan(event(body="Fixes #48464 and fixes #1"), REPO)
        self.assertEqual(plan.issues, [1])


class FakeGitHub:
    def __init__(self, items):
        self.items = items
        self.calls = []

    def issue(self, number):
        self.calls.append(("get", number))
        return self.items.get(number)

    def close(self, number, comment):
        self.calls.append(("close", number, comment))


class RunTests(unittest.TestCase):
    def test_closes_only_open_issues(self):
        github = FakeGitHub({
            1: {"number": 1, "state": "open"},
            2: {"number": 2, "state": "closed"},
            3: {"number": 3, "state": "open", "pull_request": {"url": "x"}},
            4: None,
        })
        plan = CLOSES.plan(event(body="Fixes #1, fixes #2, fixes #3, fixes #4"), REPO)
        closed = CLOSES.run(plan, github, dry_run=False)
        self.assertEqual(closed, [1])
        self.assertIn(("close", 1, plan.comment), github.calls)
        self.assertFalse([c for c in github.calls if c[0] == "close" and c[1] != 1])

    def test_dry_run_reads_but_never_closes(self):
        github = FakeGitHub({1: {"number": 1, "state": "open"}})
        plan = CLOSES.plan(event(body="Fixes #1"), REPO)
        self.assertEqual(CLOSES.run(plan, github, dry_run=True), [1])
        self.assertEqual(github.calls, [("get", 1)])

    def test_main_reads_the_event_file_and_skips_quietly(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = pathlib.Path(tmp) / "event.json"
            path.write_text(json.dumps(event(merged=False)))
            self.assertEqual(CLOSES.main(["--event", str(path), "--repo", REPO]), 0)


class BackfillTests(unittest.TestCase):
    LOG = (
        "aaa\x00ci: newer (#30)\n\nFixes #7 and closes #8\n\x1e\n"
        "bbb\x00no pull request here\n\nFixes #9\n\x1e\n"
        "ccc\x00docs: names nothing (#20)\n\nSee #9\n\x1e\n"
        "ddd\x00fix: older (#10)\n\nFixes #10, fixes manaflow-ai/other#5, resolves #6\n\x1e\n"
    )

    def test_each_squash_commit_that_names_an_issue_oldest_first(self):
        plans = CLOSES.plans_from_log(self.LOG, REPO)
        self.assertEqual([(p.pull, p.sha, p.issues) for p in plans], [(10, "ddd", [6]), (30, "aaa", [7, 8])])
        self.assertEqual(plans[0].comment, "Fixed on feat-cmux-next by #10 (ddd).")

    def test_a_reverted_pull_request_closes_nothing(self):
        log = 'eee\x00Revert "fix: older (#10)" (#40)\n\nThis reverts ddd.\n\x1e\n' + self.LOG
        self.assertEqual([p.pull for p in CLOSES.plans_from_log(log, REPO)], [30])

    def test_main_since_reads_the_ref_and_dry_run_never_closes(self):
        github = FakeGitHub({6: {"state": "open"}, 7: {"state": "open"}, 8: {"state": "open"}})
        original_read, original_github = CLOSES.read_log, CLOSES.GitHub
        seen = []
        CLOSES.read_log = lambda ref, since: seen.append((ref, since)) or self.LOG
        CLOSES.GitHub = lambda repo: github
        try:
            self.assertEqual(CLOSES.main(["--since", "2026-09-01", "--repo", REPO, "--dry-run"]), 0)
        finally:
            CLOSES.read_log, CLOSES.GitHub = original_read, original_github
        self.assertEqual(seen, [("origin/feat-cmux-next", "2026-09-01")])
        self.assertFalse([c for c in github.calls if c[0] == "close"])

    def test_read_log_reads_squash_commits(self):
        with tempfile.TemporaryDirectory() as tmp:
            run_git = lambda *a: subprocess.run(["git", "-C", tmp, "-c", "user.name=t", "-c", "user.email=t@t", *a],
                                                check=True, capture_output=True)
            run_git("init", "-q")
            run_git("commit", "-q", "--allow-empty", "-m", "fix: one (#5)", "-m", "Fixes #4")
            cwd = os.getcwd()
            os.chdir(tmp)
            try:
                plans = CLOSES.plans_from_log(CLOSES.read_log("HEAD", "2000-01-01"), REPO)
            finally:
                os.chdir(cwd)
        self.assertEqual([(p.pull, p.issues) for p in plans], [(5, [4])])

    def test_backfill_closes_only_open_issues(self):
        github = FakeGitHub({6: {"state": "open"}, 7: {"state": "closed"}, 8: {"state": "open"}})
        closed = [n for p in CLOSES.plans_from_log(self.LOG, REPO) for n in CLOSES.run(p, github, dry_run=False)]
        self.assertEqual(closed, [6, 8])


class WorkflowTests(unittest.TestCase):
    def setUp(self):
        self.text = WORKFLOW.read_text()

    def test_runs_on_closed_pull_requests_into_next(self):
        self.assertIn("pull_request:", self.text)
        self.assertIn("types: [closed]", self.text)
        self.assertIn("branches: [feat-cmux-next]", self.text)

    def test_never_runs_pull_request_target(self):
        # pull_request_target fires only from the default branch's copy and would hand a write token
        # to a run started by any fork: this workflow stays on pull_request and skips forks.
        code = "\n".join(line.split("#", 1)[0] for line in self.text.splitlines())
        self.assertNotIn("pull_request_target", code)

    def test_write_scope_is_issues_only(self):
        self.assertIn("permissions: {}", self.text)
        self.assertIn("issues: write", self.text)
        self.assertNotIn("contents: write", self.text)
        self.assertNotIn("pull-requests: write", self.text)

    def test_job_gates_on_merge_and_same_repo(self):
        self.assertIn("github.event.pull_request.merged == true", self.text)
        self.assertIn("github.event.pull_request.head.repo.full_name == github.repository", self.text)
        self.assertIn("python3 scripts/ci/next_closes_issues.py", self.text)


if __name__ == "__main__":
    unittest.main()
