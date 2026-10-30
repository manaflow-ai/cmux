#!/usr/bin/env python3
"""pr-checks.yml skips its advisory jobs only on a push that just merged the base.

A base-only update started about 6.5 advisory runs per head on 2026-10-26; the
folded workflow starts one run whose first job answers whether the push only
merged feat-cmux-next. It says yes only when the new head's parents are the
previous head and a commit on the base, the new head's tree is the clean merge
of the two, the pull request's diff is unchanged, the fetched history is whole
above the merge base, and the previous head's own push run finished green.
Anything else answers no, so every check runs: another event, a plain commit,
a merge that also edits or moves an edit, a merge of a branch that is not the
base, a head the branch has moved past, a cut history, or a previous run that
was cancelled, held or never ran.

None of the skipped jobs can fail a pull request, so a skipped one hides no
verdict; pr-capture-check, which can, is not in this workflow.

The step runs here as the workflow runs it, against a local origin, with `gh`
replaced by a stub that answers the previous head's run.
"""
from __future__ import annotations

import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

import yaml

import git_fixture_env  # noqa: F401  (disables git auto maintenance)

ROOT = Path(__file__).resolve().parents[1]
WORKFLOW_PATH = ROOT / ".github/workflows/pr-checks.yml"
WORKFLOW = yaml.safe_load(WORKFLOW_PATH.read_text())
JOBS = WORKFLOW["jobs"]
STEP = next(s for s in JOBS["base-only"]["steps"] if s.get("id") == "decide")
# PR size answers on every push: a base-only skip would keep an older answer.
SKIPPED_ON_BASE_ONLY = ("link", "split")
ALWAYS = ("size",)
ANSWER = "needs.base-only.outputs.base_only != 'true'"
LINES = "".join(f"let a{i} = {i}\n" for i in range(60))
SAME = "x\n" * 30  # identical lines: one replacement reads the same wherever it is


def git(repo: Path, *args: str) -> str:
    return subprocess.run(["git", "-C", str(repo), *args], check=True, capture_output=True, text=True).stdout.strip()


def write(repo: Path, path: str, text: str) -> None:
    target = repo / path
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_text(text, encoding="utf-8")


def edit(text: str, line: int, new: str) -> str:
    rows = text.splitlines(keepends=True)
    rows[line] = new
    return "".join(rows)


def run(status: str, conclusion: str | None, title: str = "synchronize: t", number: int = 1, pr: int = 7) -> dict:
    return {"status": status, "conclusion": conclusion, "display_title": f"#{pr} {title}", "run_number": number}


def normalized(repo: Path, a: str, b: str) -> str:
    diff = git(repo, "-c", "diff.renames=false", "diff", "-U0", "--binary", "--no-color", a, b)
    return "\n".join(line for line in diff.splitlines() if not line.startswith(("index ", "@@")))


class BaseOnlyStepTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        root = Path(self.tmp.name)
        self.src = src = root / "src"
        src.mkdir()
        git(src, "init", "-q", "-b", "feat-cmux-next")
        git(src, "config", "user.email", "t@example.com")
        git(src, "config", "user.name", "t")
        git(src, "config", "uploadpack.allowFilter", "true")
        git(src, "config", "uploadpack.allowAnySHA1InWant", "true")
        write(src, "app/a.swift", LINES)
        write(src, "app/same.swift", SAME)
        write(src, "docs/base.md", "base\n")
        git(src, "add", "-A")
        git(src, "commit", "-qm", "base")
        git(src, "checkout", "-qb", "pr")
        write(src, "app/a.swift", edit(LINES, 5, "let a5 = 50\n"))
        write(src, "app/new.swift", "let n = 1\n")
        write(src, "app/same.swift", edit(SAME, 5, "y\n"))
        git(src, "add", "-A")
        git(src, "commit", "-qm", "pr")
        self.before = git(src, "rev-parse", "HEAD")
        git(src, "checkout", "-q", "feat-cmux-next")
        # The base moves under the pull request: a line far from its hunk, and a file of its own.
        write(src, "app/a.swift", edit(LINES, 40, "let a40 = 400\n"))
        write(src, "docs/base.md", "base moved\n")
        git(src, "commit", "-qam", "base moves on")
        self.base = git(src, "rev-parse", "HEAD")
        git(src, "checkout", "-q", "pr")
        self.temp = root / "temp"
        self.temp.mkdir()
        self.bin = root / "bin"
        self.bin.mkdir()
        self.gh_log = root / "gh.log"
        self.runs = root / "runs.json"
        self.answer([run("completed", "success")])
        # The stub applies the step's own --jq filter to the canned runs, as gh would.
        (self.bin / "gh").write_text(
            '#!/usr/bin/env bash\necho "$*" >> "$GH_LOG"\n'
            '[ -n "${GH_FAIL:-}" ] && exit 1\n'
            'while [ $# -gt 0 ]; do [ "$1" = --jq ] && { shift; jq -r "$1" "$GH_RUNS"; exit; }; shift; done\n')
        (self.bin / "gh").chmod(0o755)

    def tearDown(self):
        self.tmp.cleanup()

    def answer(self, runs: list[dict]) -> None:
        self.runs.write_text(json.dumps({"workflow_runs": runs}))

    def push(self, sha: str) -> str:
        git(self.src, "update-ref", "refs/pull/7/head", sha)
        return sha

    def merge_base(self, *extra: tuple[str, str]) -> str:
        git(self.src, "merge", "-q", "--no-ff", "--no-commit", "feat-cmux-next")
        for path, text in extra:
            write(self.src, path, text)
            git(self.src, "add", path)
        git(self.src, "commit", "-qm", "Merge feat-cmux-next")
        return self.push(git(self.src, "rev-parse", "HEAD"))

    def decide(self, after: str, action: str = "synchronize", before: str | None = None,
               remote: str | None = None, **extra: str) -> tuple[str, str]:
        output = self.temp / "github_output"
        output.write_text("")
        env = {**os.environ, "PATH": f"{self.bin}:{os.environ['PATH']}", "GH_LOG": str(self.gh_log),
               "GH_RUNS": str(self.runs), "RUNNER_TEMP": str(self.temp), "GITHUB_OUTPUT": str(output),
               "GITHUB_STEP_SUMMARY": str(self.temp / "summary.md"), "ACTION": action, "REPOSITORY": "o/r",
               "BEFORE": self.before if before is None else before, "AFTER": after,
               "BASE_REF": "feat-cmux-next", "PR": "7", "REMOTE": remote or f"file://{self.src}", **extra}
        subprocess.run(["rm", "-rf", str(self.temp / "base-only")], check=True)
        result = subprocess.run(["bash", "-c", STEP["run"]], cwd=self.temp, env=env, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        outputs = dict(line.split("=", 1) for line in output.read_text().splitlines() if "=" in line)
        return outputs.get("base_only", ""), result.stdout

    def gh_calls(self) -> list[str]:
        # API calls only: a host's git may use gh as its credential helper.
        calls = self.gh_log.read_text().splitlines() if self.gh_log.exists() else []
        return [call for call in calls if call.startswith("api ")]

    def test_a_clean_merge_of_the_base_is_base_only(self):
        answer, why = self.decide(self.merge_base())
        self.assertEqual(answer, "true", why)
        self.assertEqual(len(self.gh_calls()), 1)
        self.assertIn(f"actions/workflows/pr-checks.yml/runs?head_sha={self.before}&event=pull_request", self.gh_calls()[0])

    def test_a_merge_that_also_edits_runs_everything(self):
        answer, why = self.decide(self.merge_base(("app/new.swift", "let n = 2\n")))
        self.assertEqual(answer, "false", why)
        self.assertEqual(self.gh_calls(), [])

    def test_a_merge_that_moves_an_edit_runs_everything(self):
        # The same replacement at another of the identical lines: the -U0 diff without line
        # numbers is the same, the merged tree is not.
        after = self.merge_base(("app/same.swift", edit(SAME, 7, "y\n")))
        old_base = git(self.src, "merge-base", self.before, self.base)
        self.assertEqual(normalized(self.src, old_base, self.before), normalized(self.src, self.base, after))
        answer, why = self.decide(after)
        self.assertEqual(answer, "false", why)
        self.assertIn("clean merge", why)

    def test_a_previous_run_that_did_not_finish_green_runs_everything(self):
        after = self.merge_base()
        for runs in ([run("completed", "cancelled")], [run("in_progress", None)], [],
                     [run("completed", "success", number=1), run("completed", "cancelled", number=2)],
                     [run("completed", "success", "synchronize (held): t")],
                     [run("completed", "success", "edited: t")],
                     [run("completed", "success", "opened (draft): t")]):
            with self.subTest(runs=runs):
                self.answer(runs)
                answer, why = self.decide(after)
                self.assertEqual(answer, "false", why)
                self.assertIn("previous head", why)
        self.answer([run("completed", "success", "ready_for_review: t", 2), run("completed", "cancelled", "edited: t", 3)])
        self.assertEqual(self.decide(after)[0], "true")

    def test_another_pull_requests_run_at_the_same_head_does_not_count(self):
        after = self.merge_base()
        self.answer([run("completed", "cancelled", number=1), run("completed", "success", number=2, pr=8),
                     run("completed", "success", number=3, pr=77)])
        answer, why = self.decide(after)
        self.assertEqual(answer, "false", why)

    def test_a_failed_history_listing_runs_everything(self):
        after = self.merge_base()
        # A git whose `rev-list ... --not` fails (a SIGPIPE, say): the shallow check is not skipped.
        real = subprocess.run(["bash", "-c", "command -v git"], capture_output=True, text=True).stdout.strip()
        (self.bin / "git").write_text('#!/usr/bin/env bash\nfor a; do [ "$a" = --not ] && exit 141; done\n'
                                      f'exec {real} "$@"\n')
        (self.bin / "git").chmod(0o755)
        answer, why = self.decide(after)
        self.assertEqual(answer, "false", why)
        self.assertIn("Could not list the history", why)

    def test_an_unreadable_previous_run_runs_everything(self):
        answer, why = self.decide(self.merge_base(), GH_FAIL="1")
        self.assertEqual(answer, "false", why)

    def test_a_plain_commit_runs_everything(self):
        write(self.src, "app/new.swift", "let n = 2\n")
        git(self.src, "commit", "-qam", "more")
        answer, _ = self.decide(self.push(git(self.src, "rev-parse", "HEAD")))
        self.assertEqual(answer, "false")

    def test_a_merge_of_another_branch_runs_everything(self):
        git(self.src, "checkout", "-qb", "other", self.base)
        write(self.src, "docs/other.md", "other\n")
        git(self.src, "add", "-A")
        git(self.src, "commit", "-qm", "other")
        git(self.src, "checkout", "-q", "pr")
        git(self.src, "merge", "-q", "--no-ff", "-m", "Merge other", "other")
        answer, why = self.decide(self.push(git(self.src, "rev-parse", "HEAD")))
        self.assertEqual(answer, "false")
        self.assertIn("not on feat-cmux-next", why)

    def test_other_events_and_a_new_branch_run_everything(self):
        after = self.merge_base()
        self.assertEqual(self.decide(after, action="opened")[0], "false")
        self.assertEqual(self.decide(after, before="0" * 40)[0], "false")
        # A merge onto some other previous head (a force push) is not a base-only update.
        self.assertEqual(self.decide(after, before=self.base)[0], "false")

    def test_a_head_the_branch_moved_past_runs_everything(self):
        after = self.merge_base()
        write(self.src, "app/new.swift", "let n = 3\n")
        git(self.src, "commit", "-qam", "newer")
        self.push(git(self.src, "rev-parse", "HEAD"))
        answer, why = self.decide(after)
        self.assertEqual(answer, "false")
        self.assertIn("moved past", why)

    def test_a_history_cut_above_the_merge_base_runs_everything(self):
        # The base merges an old side branch: the shallow fetch keeps the merge but cuts
        # the side branch's parent, so the history above the merge base is not whole.
        git(self.src, "checkout", "-q", "feat-cmux-next")
        git(self.src, "checkout", "-qb", "side", f"{self.base}^")
        write(self.src, "docs/side.md", "side\n")
        git(self.src, "add", "-A")
        old = "2000-01-01T00:00:00Z"
        subprocess.run(["git", "-C", str(self.src), "commit", "-qm", "side"], check=True,
                       env={**os.environ, "GIT_AUTHOR_DATE": old, "GIT_COMMITTER_DATE": old})
        git(self.src, "checkout", "-q", "feat-cmux-next")
        git(self.src, "merge", "-q", "--no-ff", "-m", "Merge side", "side")
        git(self.src, "checkout", "-q", "pr")
        answer, why = self.decide(self.merge_base())
        self.assertEqual(answer, "false", why)

    def test_a_failed_fetch_runs_everything(self):
        answer, why = self.decide("a" * 40, remote=f"file://{self.temp}/missing")
        self.assertEqual(answer, "false", why)
        self.assertEqual(self.gh_calls(), [])


class WorkflowShapeTests(unittest.TestCase):
    def test_the_answer_never_fails_the_run(self):
        self.assertTrue(STEP.get("continue-on-error"))
        self.assertEqual(JOBS["base-only"]["permissions"], {"contents": "read"})
        self.assertEqual(JOBS["base-only"]["if"], "github.event.action == 'synchronize'")

    def test_only_advisory_jobs_and_every_one_waits_on_it(self):
        self.assertEqual(set(JOBS), {"base-only", *SKIPPED_ON_BASE_ONLY, *ALWAYS})
        for job_id in SKIPPED_ON_BASE_ONLY:
            with self.subTest(job=job_id):
                job = JOBS[job_id]
                self.assertEqual(job["needs"], "base-only")
                # A skipped or failed answer runs the job: no implicit success().
                self.assertTrue(str(job["if"]).startswith("${{ !cancelled() && " + ANSWER))
                self.assertNotIn("continue-on-error", job)
        self.assertNotIn("pull_request_target", WORKFLOW_PATH.read_text())

    def test_the_size_check_never_skips_on_a_base_only_update(self):
        for job_id in ALWAYS:
            job = JOBS[job_id]
            self.assertNotIn("needs", job)
            self.assertNotIn("base_only", str(job["if"]))
            self.assertTrue(str(job["if"]).startswith("${{ !cancelled() && "))
            self.assertNotIn("continue-on-error", job)

    def test_the_run_title_names_the_event_the_previous_run_check_reads(self):
        title = WORKFLOW["run-name"]
        self.assertTrue(title.startswith("#${{ github.event.pull_request.number }} ${{ github.event.action }}"), title)
        self.assertIn("vars.CI_QUOTA_HOLD == '1' && ' (held)'", title)
        self.assertIn("github.event.pull_request.draft && ' (draft)'", title)
        self.assertIn('startswith("#@PR@ ")', STEP["run"])
        self.assertIn('test("^#[0-9]+ (opened|synchronize|reopened|ready_for_review):")', STEP["run"])

    def test_a_description_edit_never_cancels_a_push_run(self):
        group = WORKFLOW["concurrency"]["group"]
        self.assertIn("github.event.action == 'edited' && 'edited' || 'push'", group)
        self.assertTrue(WORKFLOW["concurrency"]["cancel-in-progress"])
        for job_id in (*SKIPPED_ON_BASE_ONLY, *ALWAYS):
            self.assertNotIn("concurrency", JOBS[job_id])

    def test_every_push_group_event_runs_every_advisory(self):
        # A push-group run can cancel another, and a green one vouches for all three answers.
        for job_id in ("link", "split"):
            self.assertIn("github.event.action != 'edited'", str(JOBS[job_id]["if"]) + str(JOBS["split"]["if"]))
        self.assertIn("github.event.action != 'edited'", str(JOBS["split"]["if"]))
        for event in ("opened", "synchronize", "reopened", "ready_for_review"):
            self.assertIn(event, str(JOBS["link"]["if"]))
            self.assertIn(event, str(JOBS["size"]["if"]))

    def test_check_names_are_unchanged(self):
        names = {job_id: job.get("name", job_id) for job_id, job in JOBS.items()}
        self.assertEqual(names["link"], "link")
        self.assertEqual(names["size"], "PR size")
        self.assertEqual(names["split"], "split-plan advisory")


if __name__ == "__main__":
    unittest.main()
