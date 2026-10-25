#!/usr/bin/env python3
"""attribution.py: squash merge, merge commit and direct push (author fallback) fixtures in a temp git repo,
OWNERS areas, and one idempotent comment per culprit against a fake GitHub.

  python3 -m unittest scripts/perf-lab/tests/test_attribution.py
"""
from __future__ import annotations

import contextlib
import copy
import importlib.util
import io
import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ATTRIBUTION_PY = Path(__file__).resolve().parent.parent / "attribution.py"
_SPEC = importlib.util.spec_from_file_location("perf_lab_attribution", ATTRIBUTION_PY)
attribution = importlib.util.module_from_spec(_SPEC)
sys.modules[_SPEC.name] = attribution
_SPEC.loader.exec_module(attribution)

REPO = "manaflow-ai/cmux"
OWNERS = """\
| Area | Paths | Owner | Read first |
|---|---|---|---|
| cmux-tui daemon | `cmux-tui/crates/cmux-server/` | PL-daemon | [perf-lead.md](perf-lead.md) |
| PTY holder | `cmux-tui/crates/cmux-server/src/holder/` | PL-holder | [pty-holder.md](pty-holder.md) |
| Layout motion | `Packages/macOS/CmuxNext/Sources/CmuxNextLayout/Views/ScreenContentView+Motion*.swift` | PL-motion-core | `motion.md` |
"""
SESSION_A = "https://cmux.com/deeplink/agent?harness=claude&session=aaaa&host=big-red"
SESSION_B = "https://cmux.com/deeplink/agent?harness=codex&session=bbbb&host=cosmic-gray"


def verification(sha: str, **changes) -> dict:
    record = {"group_id": 7, "culprit_sha": sha, "state": "verified", "story": "terminal.key-frame.light",
              "metric": "key_to_frame_ms", "host_class": "apple-m4-pro/24gb/120hz", "unit": "ms", "better": "lower",
              "base": {"p50": 8.0, "p99": 12.0}, "head": {"p50": 10.0, "p99": 18.0}, "p_value": 0.0004,
              "attempts": 20, "issue_number": 900, "job_id": "pp-42"}
    record.update(changes)
    return record


class FakeGitHub:
    """Serves canned reads and keeps the issue comments it is given, like GitHub's REST API."""

    def __init__(self, reads: dict[str, object] | None = None) -> None:
        self.reads = dict(reads or {})
        self.comments: dict[int, list[dict]] = {}
        self.writes: list[tuple[str, str, dict]] = []
        self._next_id = 1

    def add_comment(self, number: int, body: str) -> dict:
        comment = {"id": self._next_id, "body": body, "html_url": f"https://github.com/{REPO}/issues/{number}#c{self._next_id}"}
        self._next_id += 1
        self.comments.setdefault(number, []).append(comment)
        return comment

    def get(self, path: str) -> object:
        prefix = f"repos/{REPO}/issues/"
        if path.startswith(prefix) and "/comments?" in path:
            number = int(path[len(prefix):].split("/")[0])
            query = dict(part.split("=") for part in path.split("?")[1].split("&"))
            size, page = int(query["per_page"]), int(query["page"])
            return copy.deepcopy(self.comments.get(number, [])[(page - 1) * size: page * size])
        if path not in self.reads:
            raise AssertionError(f"unexpected read {path}")
        return copy.deepcopy(self.reads[path])

    def post(self, path: str, body: dict) -> object:
        self.writes.append(("POST", path, body))
        if path.endswith("/comments"):
            return self.add_comment(int(path.split("/")[-2]), body["body"])
        return {}

    def patch(self, path: str, body: dict) -> object:
        self.writes.append(("PATCH", path, body))
        comment_id = int(path.split("/")[-1])
        for comments in self.comments.values():
            for comment in comments:
                if comment["id"] == comment_id:
                    comment["body"] = body["body"]
                    return comment
        raise AssertionError(f"no comment {comment_id}")

    def marked(self, number: int) -> list[dict]:
        return [c for c in self.comments.get(number, []) if c["body"].startswith("<!-- perf-lab-culprit ")]


class Repo:
    """A throwaway git repository with fixed identities and no user config."""

    def __init__(self, root: Path) -> None:
        self.root = root
        self.env = {**os.environ, "GIT_CONFIG_GLOBAL": os.devnull, "GIT_CONFIG_NOSYSTEM": "1",
                    "GIT_COMMITTER_NAME": "GitHub", "GIT_COMMITTER_EMAIL": "noreply@github.com"}
        self.git("init", "-q", "-b", "main")
        self.commit("seed", {"README.md": "seed\n"}, author=("Seed", "seed@example.com"))

    def git(self, *args: str, author: tuple[str, str] | None = None) -> str:
        env = dict(self.env)
        if author:
            env.update(GIT_AUTHOR_NAME=author[0], GIT_AUTHOR_EMAIL=author[1])
        else:
            env.update(GIT_AUTHOR_NAME="Seed", GIT_AUTHOR_EMAIL="seed@example.com")
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


class AttributionTests(unittest.TestCase):
    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.repo = Repo(Path(self._tmp.name))
        self.git = attribution.Git(self.repo.root)

    def tearDown(self) -> None:
        self._tmp.cleanup()

    def attribute(self, sha: str, github: FakeGitHub, **changes):
        culprit = attribution.Culprit.from_json(verification(sha, **changes))
        return attribution.attribute(culprit, git=self.git, github=github, repo=REPO, owners_text=OWNERS)

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

    def test_squash_merge_maps_to_its_pr_author_trailers_and_owners(self) -> None:
        sha = self.squash()
        github = FakeGitHub({f"repos/{REPO}/commits/{sha}/pulls": [
            # A stacked PR that also holds the commit but did not merge it.
            {"number": 11, "html_url": "https://github.com/x/11", "merged_at": None, "merge_commit_sha": "0" * 40,
             "user": {"login": "zed"}},
            {"number": 12, "html_url": f"https://github.com/{REPO}/pull/12", "merged_at": "2026-10-25T10:00:00Z",
             "merge_commit_sha": sha, "user": {"login": "alice"}},
        ]})
        result = self.attribute(sha, github)
        self.assertEqual(result.pull, attribution.PullRequest(12, f"https://github.com/{REPO}/pull/12", "alice",
                                                              "commits-pulls"))
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
        self.assertIn("| p50 | 8 ms | 10 ms | +25.0 % |", body)
        self.assertIn("| p99 | 12 ms | 18 ms | +50.0 % |", body)
        self.assertIn("p = 0.0004, 20 ABBA attempts per side, job pp-42.", body)
        self.assertIn("Issue: #900, assigned to @alice.", body)
        self.assertIn("Co-authors: Claude, Bob Two.", body)
        self.assertIn(f"[1]({SESSION_A})", body)
        self.assertIn("owner PL-holder", body)
        self.assertNotIn("alice@example.com", body)
        self.assertIn(("POST", f"repos/{REPO}/issues/900/assignees", {"assignees": ["alice"]}), github.writes)

    def test_merge_commit_names_its_pr_and_collects_the_branch_people(self) -> None:
        self.repo.git("checkout", "-q", "-b", "bob/fix")
        self.repo.commit("perf(motion): spring step\n\nCo-authored-by: Codex <codex@openai.com>\n"
                         f"Agent-Session: {SESSION_B}\n",
                         {"Packages/macOS/CmuxNext/Sources/CmuxNextLayout/Views/ScreenContentView+Motion.swift": "x\n"},
                         author=("Bob Two", "bob@example.com"))
        self.repo.commit(f"perf(motion): tidy\n\nAgent-Session: {SESSION_B}\n", {"notes/a.md": "a\n"},
                         author=("Bob Two", "bob@example.com"))
        self.repo.git("checkout", "-q", "main")
        self.repo.commit("unrelated main change", {"cmux-tui/crates/cmux-server/src/other.rs": "x\n"},
                         author=("Carol", "carol@example.com"))
        self.repo.git("merge", "-q", "--no-ff", "bob/fix", "-m", "Merge pull request #34 from bob/fix\n\nSpring step",
                      author=("Merger", "merger@example.com"))
        sha = self.repo.git("rev-parse", "HEAD")
        github = FakeGitHub({f"repos/{REPO}/pulls/34": {
            "number": 34, "html_url": f"https://github.com/{REPO}/pull/34", "user": {"login": "bob"}}})
        result = self.attribute(sha, github)
        self.assertEqual((result.pull.number, result.pull.found_by, result.assignee), (34, "merge-commit", "bob"))
        self.assertEqual(result.commit.author.name, "Merger")
        self.assertEqual({p.email for p in result.commit.co_authors}, {"bob@example.com", "codex@openai.com"})
        self.assertEqual(result.commit.sessions, (SESSION_B,))
        # Only the first-parent diff: main's own change is not the culprit's.
        self.assertEqual(set(result.commit.files), {
            "Packages/macOS/CmuxNext/Sources/CmuxNextLayout/Views/ScreenContentView+Motion.swift", "notes/a.md"})
        self.assertEqual([a.owner for a in result.areas], ["PL-motion-core"])
        self.assertEqual(attribution.publish(result, github=github, repo=REPO).target, 34)
        self.assertEqual(len(github.marked(34)), 1)

    def test_direct_push_falls_back_to_the_author_and_comments_on_the_issue(self) -> None:
        sha = self.repo.commit("perf: direct push to the big branch", {"src/a.rs": "a\n"},
                               author=("Carol", "carol@example.com"))
        github = FakeGitHub({f"repos/{REPO}/commits/{sha}/pulls": [],
                             f"repos/{REPO}/commits/{sha}": {"author": {"login": "carol"}}})
        result = self.attribute(sha, github)
        self.assertIsNone(result.pull)
        self.assertEqual((result.assignee, result.areas), ("carol", ()))
        published = attribution.publish(result, github=github, repo=REPO)
        self.assertEqual((published.target, published.comment), (900, "created"))
        [comment] = github.marked(900)
        self.assertIn("No pull request merged this commit (direct push). Author: Carol.", comment["body"])

    def test_a_pr_that_holds_but_did_not_merge_the_sha_is_not_the_culprit_pr(self) -> None:
        sha = self.repo.commit("perf: cherry-pick", {"src/b.rs": "b\n"}, author=("Dan", "dan@example.com"))
        github = FakeGitHub({f"repos/{REPO}/commits/{sha}/pulls": [
            {"number": 5, "html_url": "u", "merged_at": "2026-10-01T00:00:00Z", "merge_commit_sha": "1" * 40,
             "user": {"login": "erin"}}],
            f"repos/{REPO}/commits/{sha}": {"author": None}})
        result = self.attribute(sha, github)
        self.assertEqual((result.pull, result.assignee), (None, None))
        attribution.publish(result, github=github, repo=REPO)
        self.assertIn("no assignee found: the sheriff assigns it.", github.marked(900)[0]["body"])
        self.assertFalse([w for w in github.writes if w[1].endswith("/assignees")])

    def test_a_bot_author_is_never_the_assignee(self) -> None:
        sha = self.repo.commit("chore: regen (#40)", {"gen.json": "{}\n"}, author=("bot", "bot@example.com"))
        github = FakeGitHub({f"repos/{REPO}/commits/{sha}/pulls": [
            {"number": 40, "html_url": "u", "merged_at": "t", "merge_commit_sha": sha,
             "user": {"login": "cmux-autofix[bot]"}}],
            f"repos/{REPO}/commits/{sha}": {"author": {"login": "github-actions[bot]"}}})
        self.assertIsNone(self.attribute(sha, github).assignee)

    def test_one_comment_per_culprit_across_runs_and_groups(self) -> None:
        sha = self.squash()
        github = FakeGitHub({f"repos/{REPO}/commits/{sha}/pulls": [
            {"number": 12, "html_url": "u", "merged_at": "t", "merge_commit_sha": sha, "user": {"login": "alice"}}]})
        for index in range(150):  # the marker comment lands on the second page
            github.add_comment(12, f"chatter {index}")
        first = attribution.publish(self.attribute(sha, github), github=github, repo=REPO)
        again = attribution.publish(self.attribute(sha, github), github=github, repo=REPO)
        self.assertEqual((first.comment, again.comment), ("created", "unchanged"))
        self.assertEqual(again.comment_url, first.comment_url)
        # A re-verified magnitude edits the same comment.
        changed = self.attribute(sha, github, head={"p50": 11.0, "p99": 18.0})
        self.assertEqual(attribution.publish(changed, github=github, repo=REPO).comment, "updated")
        self.assertEqual(len(github.marked(12)), 1)
        self.assertIn("+37.5 %", github.marked(12)[0]["body"])
        # Another alert group with the same culprit is another culprit record: its own comment.
        other = self.attribute(sha, github, group_id=8, issue_number=901)
        self.assertEqual(attribution.publish(other, github=github, repo=REPO).comment, "created")
        self.assertEqual(len(github.marked(12)), 2)
        self.assertEqual(sum(1 for w in github.writes if w[0] == "POST" and w[1].endswith("/comments")), 2)

    def test_dry_run_writes_nothing(self) -> None:
        sha = self.squash()
        github = FakeGitHub({f"repos/{REPO}/commits/{sha}/pulls": [], f"repos/{REPO}/commits/{sha}": {}})
        published = attribution.publish(self.attribute(sha, github), github=github, repo=REPO, dry_run=True)
        self.assertEqual(published.comment, "dry-run")
        self.assertEqual(github.writes, [])

    def test_unverified_or_issue_less_culprits_are_refused(self) -> None:
        sha = self.squash()
        with self.assertRaisesRegex(attribution.AttributionError, "unverified"):
            self.attribute(sha, FakeGitHub(), state="unverified")
        with self.assertRaisesRegex(attribution.AttributionError, "no issue"):
            self.attribute(sha, FakeGitHub(), issue_number=None)
        with self.assertRaisesRegex(attribution.AttributionError, "not a full sha"):
            attribution.Culprit.from_json(verification(sha[:12]))
        with self.assertRaisesRegex(attribution.AttributionError, "incomplete"):
            attribution.Culprit.from_json({"group_id": 1})

    def test_the_real_owners_file_parses(self) -> None:
        owners = (ATTRIBUTION_PY.parent.parent.parent / attribution.OWNERS_PATH).read_text()
        areas = attribution.owned_areas(["cmux-tui/crates/cmux-holder/src/lib.rs"], owners)
        self.assertEqual(len(areas), 1)
        self.assertIn("holder", areas[0].area.lower())

    def test_cli_dry_run_prints_the_attribution(self) -> None:
        sha = self.squash()
        record = Path(self._tmp.name) / "verify.json"
        record.write_text(json.dumps(verification(sha)))
        (self.repo.root / "plans/cmux-next").mkdir(parents=True)
        (self.repo.root / attribution.OWNERS_PATH).write_text(OWNERS)
        self.repo.git("add", attribution.OWNERS_PATH)
        self.repo.git("commit", "-q", "-m", "owners")
        github = FakeGitHub({f"repos/{REPO}/commits/{sha}/pulls": [],
                             f"repos/{REPO}/commits/{sha}": {"author": {"login": "alice"}}})
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            code = attribution.main(["--repo", REPO, "--culprit", str(record), "--checkout", str(self.repo.root),
                                     "--dry-run"], github=github)
        self.assertEqual(code, 0)
        self.assertEqual(github.writes, [])
        printed = json.loads(out.getvalue())
        self.assertEqual(printed["published"], {"target": 900, "comment": "dry-run", "comment_url": None,
                                                "assigned": "alice"})
        self.assertEqual(printed["attribution"]["areas"][0]["owner"], "PL-daemon")


if __name__ == "__main__":
    unittest.main()
