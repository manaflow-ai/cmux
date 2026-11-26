#!/usr/bin/env python3
"""scripts/ci/ios_kit_base_red.py: a new red on feat-cmux-next's kit tells the landings behind it.

  python3 tests/test_ci_ios_kit_base_red.py
"""
from __future__ import annotations

import io
import json
import os
import sys
import unittest
from contextlib import redirect_stdout
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "scripts" / "ci"))
import ios_kit_base_red as kbr  # noqa: E402

REPO = "o/r"
STAMP = "2026-11-25T02:21:11.6497680Z "


def log(*reds: tuple[str, str]) -> str:
    lines = ["◇ Test run started."]
    for name, site in reds:
        lines.append(f"{STAMP}✘ Test {name}() recorded an issue at {site}:12:9: Expectation failed: x")
        lines.append(f"{STAMP}✘ Test {name}() failed after 0.1 seconds with 1 issue.")
    lines.append(f"{STAMP}✘ Test run with 10 tests in 2 suites failed after 1.0 seconds with {len(reds)} issues.")
    return "\n".join(lines)


class Fake:
    def __init__(self, runs: list[dict], logs: dict[int, str | None], comments: dict[int, str] | None = None):
        self.runs, self.logs, self.comments = runs, logs, comments or {}

    def get(self, path: str) -> str:
        if path.startswith(f"repos/{REPO}/actions/workflows/"):
            return json.dumps({"workflow_runs": self.runs})
        if "/jobs?" in path:
            run = int(path.split("/runs/")[1].split("/")[0])
            text = self.logs.get(run)
            conclusion = "failure" if text and "✘" in text else ("success" if text is not None else "cancelled")
            return json.dumps({"jobs": [{"id": run * 10, "name": kbr.JOB, "conclusion": conclusion},
                                        {"id": 1, "name": "runner", "conclusion": "success"}]})
        if "/actions/jobs/" in path:
            return self.logs[int(path.split("/jobs/")[1].split("/")[0]) // 10] or ""
        if "/actions/runs/" in path:
            run = int(path.rsplit("/", 1)[1])
            return json.dumps(next(r for r in self.runs if r["id"] == run))
        if "/comments" in path:
            return self.comments.get(int(path.split("/issues/")[1].split("/")[0]), "[]")
        raise AssertionError(path)


def run(rid: int, sha: str, when: str, conclusion: str) -> dict:
    return {"id": rid, "head_sha": sha, "created_at": when, "conclusion": conclusion,
            "html_url": f"https://github.com/{REPO}/actions/runs/{rid}"}


LOG = {
    "log --first-parent --format=%H%x09%s base000000..head000000":
        "c3\tios: chat words (#3)\nc2\tdocs only (#2)\nc1\tiOS cache team rows (#1)\nc0\tMerge branch x\n",
    "diff-tree --no-commit-id --name-only -r c3": "cmux-next-ios/CmuxMobileKit/Sources/Chat/AgentChatStore.swift\n",
    "diff-tree --no-commit-id --name-only -r c2": "docs/x.md\n",
    "diff-tree --no-commit-id --name-only -r c1":
        "cmux-next-ios/CmuxMobileKit/Tests/CmuxMobileLiveTests/WorkspacesCacheTests.swift\n",
}


def fake_git(*args: str) -> str:
    return LOG.get(" ".join(args), "")


class BaseRed(unittest.TestCase):
    def main(self, fake: Fake, *extra: str) -> tuple[list[tuple[int, str]], str]:
        posted: list[tuple[int, str]] = []
        out = io.StringIO()
        with redirect_stdout(out):
            kbr.main(["--repo", REPO, "--run", "200", *extra], get=fake.get, run_git=fake_git,
                     post=lambda n, b: posted.append((n, b)))
        return posted, out.getvalue()

    def runs(self, prev_conclusion: str = "success") -> list[dict]:
        return [run(200, "head000000", "2026-11-25T02:29:00Z", "failure"),
                run(150, "skip000000", "2026-11-25T02:20:00Z", "cancelled"),
                run(100, "base000000", "2026-11-25T01:00:00Z", prev_conclusion),
                run(50, "old0000000", "2026-11-25T00:00:00Z", "failure")]

    def test_a_new_red_tells_each_kit_landing_in_range_likely_first(self):
        fake = Fake(self.runs(), {200: log(("eachTeamKeepsItsOwnRows", "WorkspacesCacheTests.swift")), 100: ""})
        posted, out = self.main(fake)
        self.assertEqual([n for n, _ in posted], [1, 3], "the landing that touched the red's file first; docs skipped")
        self.assertIn("eachTeamKeepsItsOwnRows", posted[0][1])
        self.assertIn("it changed WorkspacesCacheTests.swift", posted[0][1])
        self.assertIn("Other landings in the range that changed the kit: #3", posted[0][1])
        self.assertTrue(posted[0][1].startswith("<!-- ios-kit-base-red:200 -->"))
        self.assertIn("#1 (likely)", out)

    def test_a_red_that_already_failed_at_the_previous_run_tells_nobody(self):
        red = log(("everyFrameDrawsTheReferenceScreen", "AgentCLIHybridProofTests.swift"))
        fake = Fake(self.runs("failure"), {200: red, 100: red})
        posted, out = self.main(fake)
        self.assertEqual(posted, [])
        self.assertIn("nothing new", out)

    def test_only_the_new_red_is_named_when_the_previous_run_was_red_too(self):
        old = ("everyFrameDrawsTheReferenceScreen", "AgentCLIHybridProofTests.swift")
        fake = Fake(self.runs("failure"), {200: log(old, ("aSlowHistoryShowsOnlyItsSpinner", "StartingAgentSourceTests.swift")),
                                           100: log(old)})
        posted, out = self.main(fake)
        self.assertEqual([n for n, _ in posted], [3, 1], "no landing touched the new red's file: range order")
        self.assertNotIn("likely", out, "the old red's file points at nobody")
        self.assertIn("aSlowHistoryShowsOnlyItsSpinner", posted[0][1])
        self.assertNotIn("everyFrameDrawsTheReferenceScreen", posted[0][1])

    def test_a_landing_already_told_for_this_run_is_not_told_again(self):
        fake = Fake(self.runs(), {200: log(("x", "WorkspacesCacheTests.swift")), 100: ""},
                    comments={1: json.dumps([{"body": "<!-- ios-kit-base-red:200 -->"}])})
        posted, _ = self.main(fake)
        self.assertEqual([n for n, _ in posted], [3])

    def test_dry_run_posts_nothing(self):
        fake = Fake(self.runs(), {200: log(("x", "WorkspacesCacheTests.swift")), 100: ""})
        posted, out = self.main(fake, "--dry-run")
        self.assertEqual(posted, [])
        self.assertIn("#1 (likely)", out)

    def test_a_red_with_no_named_test_tells_nobody(self):
        fake = Fake(self.runs(), {200: f"{STAMP}error: build failed\n##[error]Process completed with exit code 1.", 100: ""})
        posted, out = self.main(fake)
        self.assertEqual(posted, [])
        self.assertIn("no failing test named", out)


class Wiring(unittest.TestCase):
    def test_the_kit_workflow_runs_it_on_a_red_push_only(self):
        text = (ROOT / ".github" / "workflows" / "cmux-next-ios-kit.yml").read_text()
        self.assertIn("python3 scripts/ci/ios_kit_base_red.py", text)
        block = text.split("  base-red-notice:", 1)[1].split("\n  # ", 1)[0]
        self.assertIn("github.event_name == 'push'", block)
        self.assertIn("needs.kit-tests.result == 'failure'", block)
        self.assertIn("pull-requests: write", block)
        self.assertIn(f'name: {kbr.JOB}', text, "JOB must match the kit job's name")


if __name__ == "__main__":
    unittest.main()
