#!/usr/bin/env python3
"""attribution.py: the culprit read from a lab store that verify.py wrote; squash merge, GitHub merge commit,
local merge into the big branch, a commit inside a rebase merge and a direct push (author fallback) in a temp
git repo; OWNERS areas; one idempotent comment per culprit against a fake GitHub; the gh/glaeda-gh client.

  python3 -m unittest scripts/perf-lab/tests/test_attribution.py
"""
from __future__ import annotations

import contextlib
import copy
import importlib.util
import io
import json
import os
import sqlite3
import subprocess
import sys
import tempfile
import unittest
from datetime import datetime, timezone
from pathlib import Path

LAB = Path(__file__).resolve().parent.parent


def _load(name: str, path: Path):
    if name in sys.modules:
        return sys.modules[name]
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


store = _load("perf_lab_store", LAB / "store.py")
verify = _load("perf_lab_verify", LAB / "verify.py")
attribution = _load("perf_lab_attribution", LAB / "attribution.py")

REPO = "manaflow-ai/cmux"
BRANCH = "perf/chrome-parity"
NOW = datetime(2026, 10, 25, 12, 0, tzinfo=timezone.utc)
STORY, METRIC, CLASS = "terminal.key-frame.light", "key_to_frame_ms", "apple-m4-pro/24gb/120hz"
BASE = [10 + 0.1 * (i % 7) for i in range(20)]
SLOWER = [x + 2.5 for x in BASE]  # strict DIFFERENT; p50 10.3 -> 12.8 ms
OWNERS = """\
| Area | Paths | Owner | Read first |
|---|---|---|---|
| cmux-tui daemon | `cmux-tui/crates/cmux-server/` | PL-daemon | [perf-lead.md](perf-lead.md) |
| PTY holder | `cmux-tui/crates/cmux-server/src/holder/` | PL-holder | [pty-holder.md](pty-holder.md) |
| Layout motion | `Packages/macOS/CmuxNext/Sources/CmuxNextLayout/Views/ScreenContentView+Motion*.swift` | PL-motion-core | `motion.md` |
"""
SESSION_A = "https://cmux.com/deeplink/agent?harness=claude&session=aaaa&host=big-red"
SESSION_B = "https://cmux.com/deeplink/agent?harness=codex&session=bbbb&host=cosmic-gray"


class LabStore:
    """A migrated lab store with alert groups whose culprits verify.py's GroupRecorder verified."""

    def __init__(self, path: Path) -> None:
        self.path = path
        lab = store.Store(path, clock=lambda: NOW)
        lab.migrate()
        lab.close()
        with contextlib.closing(sqlite3.connect(path)) as db:
            db.execute("""INSERT INTO series (id, series_key, story, metric, engine, host_class, macos_major,
                                              build_config, unit, better)
                          VALUES (1, 'k1', ?, ?, 'ghostty', ?, 26, 'bench', 'ms', 'lower')""", (STORY, METRIC, CLASS))
            db.commit()

    def group(self, group_id: int, parent: str, culprit: str, *, issue: int | None = 900,
              samples: tuple[list[float], list[float]] = (BASE, SLOWER)) -> verify.Verification:
        with contextlib.closing(sqlite3.connect(self.path)) as db:
            db.execute("""INSERT INTO alert_groups (id, state, start_pos, end_pos, created_at, updated_at)
                          VALUES (?, 'bisecting', 100, 108, 'x', 'x')""", (group_id,))
            db.execute("""INSERT INTO alerts (series_id, group_id, rule, start_pos, end_pos, median_before,
                                              median_after, created_at) VALUES (1, ?, 'edivisive', ?, 108, 10, 12, 'x')""",
                       (group_id, 100 + group_id))
            db.commit()
        request = verify.Request(group_id=group_id, parent_sha=parent, culprit_sha=culprit, story=STORY,
                                 metric=METRIC, host_class=CLASS, better="lower")
        plan = verify.plan(request, (verify.LabHost("cmux16", CLASS, "pinpoint"),))
        recorder = verify.GroupRecorder(self.path, clock=lambda: NOW)
        try:
            job = recorder.start(plan)
            parent_samples, culprit_samples = (iter(values) for values in samples)
            result = verify.run(plan, lambda attempt: [next(parent_samples if attempt.arm == verify.PARENT
                                                            else culprit_samples)])
            recorder.finish(job, result)
        finally:
            recorder.close()
        if issue is not None:
            with contextlib.closing(sqlite3.connect(self.path)) as db:
                db.execute("UPDATE alert_groups SET issue_number = ? WHERE id = ?", (issue, group_id))
                db.commit()
        return result


class FakeGitHub:
    """Serves canned PR and commit reads and keeps the issue comments it is given."""

    def __init__(self, *, pulls: dict[int, dict] | None = None, commit_pulls: dict[str, list] | None = None,
                 commits: dict[str, dict] | None = None) -> None:
        self.pulls, self.commit_pull_lists, self.commits = pulls or {}, commit_pulls or {}, commits or {}
        self.comments: dict[int, list[dict]] = {}
        self.writes: list[tuple] = []
        self._next_id = 1

    def add_comment(self, number: int, body: str) -> dict:
        comment = {"id": self._next_id, "body": body,
                   "html_url": f"https://github.com/{REPO}/issues/{number}#issuecomment-{self._next_id}"}
        self._next_id += 1
        self.comments.setdefault(number, []).append(comment)
        return copy.deepcopy(comment)

    def pull(self, number: int) -> dict:
        return copy.deepcopy(self.pulls[number])

    def commit_pulls(self, sha: str) -> list[dict]:
        return copy.deepcopy(self.commit_pull_lists.get(sha, []))

    def commit(self, sha: str) -> dict:
        if sha not in self.commits:
            raise AssertionError(f"unexpected commit read {sha}")
        return copy.deepcopy(self.commits[sha])

    def issue_comments(self, number: int) -> list[dict]:
        return copy.deepcopy(self.comments.get(number, []))

    def create_comment(self, number: int, body: str) -> dict:
        self.writes.append(("comment", number, body))
        return self.add_comment(number, body)

    def edit_comment(self, comment_id: int, body: str) -> dict:
        self.writes.append(("edit", comment_id, body))
        for comments in self.comments.values():
            for comment in comments:
                if comment["id"] == comment_id:
                    comment["body"] = body
                    return copy.deepcopy(comment)
        raise AssertionError(f"no comment {comment_id}")

    def add_assignee(self, number: int, login: str) -> None:
        self.writes.append(("assign", number, login))

    def marked(self, number: int) -> list[dict]:
        return [c for c in self.comments.get(number, []) if c["body"].startswith("<!-- perf-lab-culprit ")]


def merged_pull(number: int, merge_sha: str, login: str, *, base: str = BRANCH, merged_at: str = "2026-10-25T10:00:00Z"):
    return {"number": number, "html_url": f"https://github.com/{REPO}/pull/{number}", "merged_at": merged_at,
            "merge_commit_sha": merge_sha, "base": {"ref": base}, "user": {"login": login}}


class Repo:
    """A throwaway git repository with fixed identities and no user config."""

    def __init__(self, root: Path) -> None:
        self.root = root
        self.env = {**os.environ, "GIT_CONFIG_GLOBAL": os.devnull, "GIT_CONFIG_NOSYSTEM": "1",
                    "GIT_COMMITTER_NAME": "GitHub", "GIT_COMMITTER_EMAIL": "noreply@github.com"}
        self.git("init", "-q", "-b", BRANCH)
        self.commit("seed", {"README.md": "seed\n"}, author=("Seed", "seed@example.com"))

    def git(self, *args: str, author: tuple[str, str] | None = None) -> str:
        name, email = author or ("Seed", "seed@example.com")
        env = {**self.env, "GIT_AUTHOR_NAME": name, "GIT_AUTHOR_EMAIL": email}
        return subprocess.run(["git", "-C", str(self.root), "-c", "commit.gpgsign=false", *args], env=env,
                              check=True, capture_output=True, text=True).stdout.strip()

    def commit(self, message: str, files: dict[str, str], *, author: tuple[str, str]) -> str:
        for name, text in files.items():
            path = self.root / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(text)
            self.git("add", name)
        self.git("commit", "-q", "-m", message, author=author)
        return self.git("rev-parse", "HEAD")

    def parent(self, sha: str) -> str:
        return self.git("rev-parse", f"{sha}^1")


class AttributionTests(unittest.TestCase):
    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        root = Path(self._tmp.name)
        (root / "repo").mkdir()
        self.repo = Repo(root / "repo")
        self.git = attribution.Git(self.repo.root)
        self.lab = LabStore(root / "lab.sqlite")
        self._groups = 0

    def tearDown(self) -> None:
        self._tmp.cleanup()

    def culprit(self, sha: str, **group):
        self._groups += 1
        self.lab.group(self._groups, self.repo.parent(sha), sha, **group)
        return attribution.load_culprit(self.lab.path, self._groups)

    def attribute(self, culprit, github: FakeGitHub):
        return attribution.attribute(culprit, git=self.git, github=github, branch=BRANCH, owners_text=OWNERS)

    def squash(self) -> str:
        return self.repo.commit(
            "perf(daemon): batch the journal flush (#12)\n\nBody.\n\n"
            "Co-authored-by: Claude <noreply@anthropic.com>\n"
            "Co-Authored-By: Bob Two <bob@example.com>\n"
            f"Agent-Session: {SESSION_A}\n",
            {"cmux-tui/crates/cmux-server/src/journal.rs": "fn flush() {}\n",
             "cmux-tui/crates/cmux-server/src/holder/ring.rs": "fn ring() {}\n",
             "docs/notes.md": "notes\n"},
            author=("Alice One", "alice@example.com"))

    def branch(self, name: str, *, author: tuple[str, str] = ("Bob Two", "bob@example.com")) -> list[str]:
        """Two commits on NAME off the big branch, then one unrelated big-branch commit; back on the big branch."""
        self.repo.git("checkout", "-q", "-b", name)
        first = self.repo.commit(
            "perf(motion): spring step\n\nCo-authored-by: Codex <codex@openai.com>\n" f"Agent-Session: {SESSION_B}\n",
            {"Packages/macOS/CmuxNext/Sources/CmuxNextLayout/Views/ScreenContentView+Motion.swift": "x\n"},
            author=author)
        second = self.repo.commit(f"perf(motion): tidy\n\nAgent-Session: {SESSION_B}\n", {"notes/a.md": "a\n"},
                                  author=author)
        self.repo.git("checkout", "-q", BRANCH)
        self.repo.commit("unrelated big-branch change", {"cmux-tui/crates/cmux-server/src/other.rs": "x\n"},
                         author=("Carol", "carol@example.com"))
        return [first, second]

    def test_the_culprit_is_read_from_the_store_verify_wrote(self) -> None:
        sha = self.squash()
        result = self.lab.group(1, self.repo.parent(sha), sha)
        culprit = attribution.load_culprit(self.lab.path, 1)
        self.assertTrue(culprit.verified)
        self.assertEqual((culprit.group_id, culprit.sha, culprit.issue_number), (1, sha, 900))
        self.assertEqual((culprit.story, culprit.metric, culprit.host_class), (STORY, METRIC, CLASS))
        self.assertEqual(culprit.magnitude, attribution.Magnitude(
            unit="ms", better="lower", parent_p50=result.parent_p50, culprit_p50=result.culprit_p50,
            parent_p99=result.parent_p99, culprit_p99=result.culprit_p99, p_value=result.p_value,
            parent_attempts=20, culprit_attempts=20, host="cmux16"))
        self.assertEqual(culprit.job_id, verify.GroupRecorder(self.lab.path, clock=lambda: NOW).verification_of(1)[0]
                         ["job_id"])

    def test_squash_merge_maps_to_its_pr_author_trailers_and_owners(self) -> None:
        sha = self.squash()
        github = FakeGitHub(commit_pulls={sha: [
            # A stacked PR that also holds the commit but did not merge it.
            {**merged_pull(11, "0" * 40, "zed"), "merged_at": None},
            merged_pull(12, sha, "alice"),
        ]})
        culprit = self.culprit(sha)
        result = self.attribute(culprit, github)
        self.assertEqual(result.pull, attribution.PullRequest(12, f"https://github.com/{REPO}/pull/12", "alice",
                                                              "merge-commit-sha"))
        self.assertEqual(result.assignee, "alice")
        self.assertEqual(result.commit.author, attribution.Person("Alice One", "alice@example.com"))
        self.assertEqual(result.commit.co_authors, (attribution.Person("Claude", "noreply@anthropic.com"),
                                                    attribution.Person("Bob Two", "bob@example.com")))
        self.assertEqual(result.commit.sessions, (SESSION_A,))
        # The holder file belongs to the narrower holder row only; docs/ has no owner.
        self.assertEqual([(a.area, a.owner, a.files) for a in result.areas], [
            ("cmux-tui daemon", "PL-daemon", ("cmux-tui/crates/cmux-server/src/journal.rs",)),
            ("PTY holder", "PL-holder", ("cmux-tui/crates/cmux-server/src/holder/ring.rs",)),
        ])
        published = attribution.publish(result, github=github, repo=REPO)
        self.assertEqual((published.target, published.comment, published.assigned), (12, "created", "alice"))
        [comment] = github.marked(12)
        body = comment["body"]
        self.assertIn("| p50 | 10.3 ms | 12.8 ms | +24.3 % |", body)
        self.assertIn(f"p = {culprit.magnitude.p_value:.2g}, 20 parent and 20 culprit attempts in ABBA order on "
                      f"cmux16, verify job {culprit.job_id}.", body)
        self.assertIn("Issue: #900, assigned to @alice.", body)
        self.assertIn("Co-authors: Claude, Bob Two.", body)
        self.assertIn(f"[1]({SESSION_A})", body)
        self.assertIn("owner PL-holder", body)
        self.assertNotIn("alice@example.com", body)
        self.assertNotIn("No pull request", body)
        self.assertIn(("assign", 900, "alice"), github.writes)

    def test_github_merge_commit_names_its_pr_and_collects_the_branch_people(self) -> None:
        self.branch("bob/fix")
        self.repo.git("merge", "-q", "--no-ff", "bob/fix", "-m", "Merge pull request #34 from bob/fix\n\nSpring step",
                      author=("Merger", "merger@example.com"))
        sha = self.repo.git("rev-parse", "HEAD")
        github = FakeGitHub(pulls={34: merged_pull(34, sha, "bob")})
        result = self.attribute(self.culprit(sha), github)
        self.assertEqual((result.pull.number, result.pull.found_by, result.assignee), (34, "merge-commit", "bob"))
        self.assertEqual(result.commit.author.name, "Merger")
        self.assertEqual({p.email for p in result.commit.co_authors}, {"bob@example.com", "codex@openai.com"})
        self.assertEqual(result.commit.sessions, (SESSION_B,))
        # Only the first-parent diff: the big branch's own change is not the culprit's.
        self.assertEqual(set(result.commit.files), {
            "Packages/macOS/CmuxNext/Sources/CmuxNextLayout/Views/ScreenContentView+Motion.swift", "notes/a.md"})
        self.assertEqual([a.owner for a in result.areas], ["PL-motion-core"])
        self.assertEqual(attribution.publish(result, github=github, repo=REPO).target, 34)
        self.assertEqual(len(github.marked(34)), 1)

    def test_a_local_merge_into_the_big_branch_belongs_to_the_branch_author_not_the_merger(self) -> None:
        _, newest = self.branch("cp/p03-rendering-001")
        self.repo.git("merge", "-q", "--no-ff", "cp/p03-rendering-001", "-m",
                      f"Merge cp/p03-rendering-001 into {BRANCH}", author=("Lead", "lead@example.com"))
        sha = self.repo.git("rev-parse", "HEAD")
        github = FakeGitHub(commit_pulls={sha: []}, commits={newest: {"author": {"login": "bob"}}})
        result = self.attribute(self.culprit(sha), github)
        self.assertIsNone(result.pull)
        self.assertEqual((result.commit.branch_head, result.commit.branch_author),
                         (newest, attribution.Person("Bob Two", "bob@example.com")))
        self.assertEqual(result.assignee, "bob")
        published = attribution.publish(result, github=github, repo=REPO)
        self.assertEqual((published.target, published.assigned), (900, "bob"))
        body = github.marked(900)[0]["body"]
        self.assertIn(f"No pull request: a local merge. Branch author: Bob Two (newest commit `{newest[:10]}`).", body)
        self.assertNotIn("direct push", body)
        self.assertIn(("assign", 900, "bob"), github.writes)

    def test_a_commit_inside_a_rebase_merge_maps_to_the_pr_merged_into_the_branch(self) -> None:
        first = self.repo.commit("perf: step one", {"cmux-tui/crates/cmux-server/src/a.rs": "a\n"},
                                 author=("Erin", "erin@example.com"))
        last = self.repo.commit("perf: step two", {"cmux-tui/crates/cmux-server/src/b.rs": "b\n"},
                                author=("Erin", "erin@example.com"))
        github = FakeGitHub(commit_pulls={first: [
            merged_pull(70, "2" * 40, "frank", base="main", merged_at="2026-10-20T00:00:00Z"),  # a backport elsewhere
            merged_pull(56, last, "erin"),  # the rebase merge: only its last commit is the merge_commit_sha
        ]})
        result = self.attribute(self.culprit(first), github)
        self.assertEqual((result.pull.number, result.pull.found_by, result.assignee), (56, "contains", "erin"))
        self.assertEqual(attribution.publish(result, github=github, repo=REPO).target, 56)

    def test_direct_push_falls_back_to_the_author_and_comments_on_the_issue(self) -> None:
        sha = self.repo.commit("perf: direct push to the big branch", {"src/a.rs": "a\n"},
                               author=("Carol", "carol@example.com"))
        github = FakeGitHub(commits={sha: {"author": {"login": "carol"}}})
        result = self.attribute(self.culprit(sha), github)
        self.assertIsNone(result.pull)
        self.assertEqual((result.assignee, result.areas), ("carol", ()))
        published = attribution.publish(result, github=github, repo=REPO)
        self.assertEqual((published.target, published.comment), (900, "created"))
        [comment] = github.marked(900)
        self.assertIn("No pull request merged this commit (direct push). Author: Carol.", comment["body"])

    def test_a_pr_merged_into_another_branch_is_not_the_culprit_pr(self) -> None:
        sha = self.repo.commit("perf: cherry-pick", {"src/b.rs": "b\n"}, author=("Dan", "dan@example.com"))
        github = FakeGitHub(commit_pulls={sha: [merged_pull(5, "1" * 40, "erin", base="main")]},
                            commits={sha: {"author": None}})
        result = self.attribute(self.culprit(sha), github)
        self.assertEqual((result.pull, result.assignee), (None, None))
        attribution.publish(result, github=github, repo=REPO)
        self.assertIn("no assignee found: the sheriff assigns it.", github.marked(900)[0]["body"])
        self.assertFalse([w for w in github.writes if w[0] == "assign"])

    def test_a_bot_author_is_never_the_assignee(self) -> None:
        sha = self.repo.commit("chore: regen (#40)", {"gen.json": "{}\n"}, author=("bot", "bot@example.com"))
        github = FakeGitHub(commit_pulls={sha: [merged_pull(40, sha, "cmux-autofix[bot]")]},
                            commits={sha: {"author": {"login": "github-actions[bot]"}}})
        self.assertIsNone(self.attribute(self.culprit(sha), github).assignee)

    def test_one_comment_per_culprit_across_runs_and_groups(self) -> None:
        sha = self.squash()
        github = FakeGitHub(commit_pulls={sha: [merged_pull(12, sha, "alice")]})
        for index in range(3):
            github.add_comment(12, f"chatter {index}")
        culprit = self.culprit(sha)
        first = attribution.publish(self.attribute(culprit, github), github=github, repo=REPO)
        again = attribution.publish(self.attribute(culprit, github), github=github, repo=REPO)
        self.assertEqual((first.comment, again.comment), ("created", "unchanged"))
        self.assertEqual(again.comment_url, first.comment_url)
        # Another alert group with the same culprit is another culprit record: its own comment.
        other = self.culprit(sha, issue=901)
        self.assertEqual(attribution.publish(self.attribute(other, github), github=github, repo=REPO).comment,
                         "created")
        self.assertEqual(len(github.marked(12)), 2)
        self.assertEqual(sum(1 for w in github.writes if w[0] == "comment"), 2)

    def test_a_changed_magnitude_edits_the_same_comment(self) -> None:
        sha = self.squash()
        github = FakeGitHub(commit_pulls={sha: [merged_pull(12, sha, "alice")]})
        culprit = self.culprit(sha)
        attribution.publish(self.attribute(culprit, github), github=github, repo=REPO)
        moved = attribution.Magnitude(**{**culprit.magnitude.__dict__, "culprit_p50": 14.42})
        changed = attribution.Culprit(**{**culprit.__dict__, "magnitude": moved})
        self.assertEqual(attribution.publish(self.attribute(changed, github), github=github, repo=REPO).comment,
                         "updated")
        self.assertEqual(len(github.marked(12)), 1)
        self.assertIn("| 14.4 ms | +40.0 % |", github.marked(12)[0]["body"])

    def test_dry_run_writes_nothing(self) -> None:
        sha = self.squash()
        github = FakeGitHub(commits={sha: {}})
        published = attribution.publish(self.attribute(self.culprit(sha), github), github=github, repo=REPO,
                                        dry_run=True)
        self.assertEqual(published.comment, "dry-run")
        self.assertEqual(github.writes, [])

    def test_unverified_or_issue_less_culprits_are_refused(self) -> None:
        sha = self.squash()
        with self.assertRaisesRegex(attribution.AttributionError, "unverified"):
            self.attribute(self.culprit(sha, samples=(BASE, BASE)), FakeGitHub())
        with self.assertRaisesRegex(attribution.AttributionError, "no issue"):
            self.attribute(self.culprit(sha, issue=None), FakeGitHub())
        with self.assertRaisesRegex(attribution.AttributionError, "no alert group 99"):
            attribution.load_culprit(self.lab.path, 99)
        with self.assertRaisesRegex(attribution.AttributionError, "no lab store"):
            attribution.load_culprit(Path(self._tmp.name) / "missing.sqlite", 1)

    def test_the_real_owners_file_parses(self) -> None:
        owners = (LAB.parent.parent / attribution.OWNERS_PATH).read_text()
        areas = attribution.owned_areas(["cmux-tui/crates/cmux-holder/src/lib.rs"], owners)
        self.assertEqual(len(areas), 1)
        self.assertIn("holder", areas[0].area.lower())

    def test_cli_dry_run_prints_the_attribution(self) -> None:
        sha = self.squash()
        self.lab.group(1, self.repo.parent(sha), sha)
        (self.repo.root / "plans/cmux-next").mkdir(parents=True)
        (self.repo.root / attribution.OWNERS_PATH).write_text(OWNERS)
        self.repo.git("add", attribution.OWNERS_PATH)
        self.repo.git("commit", "-q", "-m", "owners")
        github = FakeGitHub(commits={sha: {"author": {"login": "alice"}}})
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            code = attribution.main(["--repo", REPO, "--db", str(self.lab.path), "--group", "1",
                                     "--checkout", str(self.repo.root), "--dry-run"], github=github)
        self.assertEqual(code, 0)
        self.assertEqual(github.writes, [])
        printed = json.loads(out.getvalue())
        self.assertEqual(printed["published"], {"target": 900, "comment": "dry-run", "comment_url": None,
                                                "assigned": "alice"})
        self.assertEqual(printed["attribution"]["areas"][0]["owner"], "PL-daemon")


class GhCliTests(unittest.TestCase):
    def result(self, code: int, stdout: str = "", stderr: str = "") -> subprocess.CompletedProcess:
        return subprocess.CompletedProcess([], code, stdout, stderr)

    def test_comments_are_read_through_glaeda_gh(self) -> None:
        calls = []

        def runner(argv, **kwargs):
            calls.append(argv)
            return self.result(0, json.dumps({"comments": [
                {"body": "a", "url": f"https://github.com/{REPO}/pull/7#issuecomment-123"},
                {"id": 9, "body": "b", "html_url": "u"}]}))

        client = attribution.GhCli(REPO, runner=runner, sleep=lambda s: None)
        self.assertEqual(client.issue_comments(7), [
            {"id": 123, "body": "a", "html_url": f"https://github.com/{REPO}/pull/7#issuecomment-123"},
            {"id": 9, "body": "b", "html_url": "u"}])
        self.assertEqual(calls, [["glaeda-gh", "status", "comment", f"{REPO}#7", "--json"]])

    def test_daemon_down_is_an_error_not_a_fallback(self) -> None:
        client = attribution.GhCli(REPO, runner=lambda argv, **kw: self.result(3), sleep=lambda s: None)
        with self.assertRaisesRegex(attribution.AttributionError, "daemon is down"):
            client.issue_comments(7)

    def test_a_rate_limited_assignee_write_backs_off_and_retries(self) -> None:
        replies = [self.result(1, stderr="HTTP 429"), self.result(1, stderr="API rate limit exceeded"),
                   self.result(0, "{}")]
        sleeps, calls = [], []

        def runner(argv, **kwargs):
            calls.append((argv, json.loads(kwargs["input"])))
            return replies.pop(0)

        client = attribution.GhCli(REPO, runner=runner, sleep=sleeps.append, base_delay_s=2.0)
        client.add_assignee(900, "alice")
        self.assertEqual(sleeps, [2.0, 4.0])
        self.assertEqual(calls[0], (["gh", "api", "--method", "POST", f"repos/{REPO}/issues/900/assignees",
                                     "--input", "-"], {"assignees": ["alice"]}))

    def test_a_server_error_on_a_comment_post_is_not_retried(self) -> None:
        calls = []

        def runner(argv, **kwargs):
            calls.append(argv)
            return self.result(1, stderr="HTTP 502")

        client = attribution.GhCli(REPO, runner=runner, sleep=lambda s: None)
        with self.assertRaises(attribution.AttributionError):
            client.create_comment(7, "x")
        self.assertEqual(len(calls), 1)

    def test_reads_take_no_input(self) -> None:
        calls = []

        def runner(argv, **kwargs):
            calls.append((argv, kwargs["input"]))
            return self.result(0, "[]")

        attribution.GhCli(REPO, runner=runner, sleep=lambda s: None).commit_pulls("a" * 40)
        self.assertEqual(calls, [(["gh", "api", "--method", "GET", f"repos/{REPO}/commits/{'a' * 40}/pulls"], None)])


if __name__ == "__main__":
    unittest.main()
