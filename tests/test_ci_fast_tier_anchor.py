#!/usr/bin/env python3
"""A feat-cmux-next push routes its fast tier from the last FINISHED fast tier.

scripts/ci/fast_tier_anchor.py. The sequence that let c5dd001a (#27931) land
untested: two pushes whose fast tier was cancelled, then a push whose own
change (against the previous push) reaches no Mac tier. Routed from the last
finished fast tier, that third push still runs it, for the first push's Swift.
A docs-only push right after a finished fast tier still skips it.
"""

from __future__ import annotations

import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts" / "ci"))

import fast_tier_anchor  # noqa: E402
from cmux_next_route import outputs, route  # noqa: E402
from fast_tier_anchor import MARKER, Git, Skip, decide, markers_from  # noqa: E402

SWIFT = "Packages/macOS/CmuxNext/Sources/CmuxNextSettings/Schema/SettingsSchema+Subsessions.generated.swift"
DOCS = "docs/ci/cmux-next-tiers.md"
REPO_ID = 1234


class History:
    """A throwaway repository: one commit per push."""

    def __init__(self, root: Path) -> None:
        self.root = root
        self.git("init", "--quiet", "--initial-branch=feat-cmux-next")
        self.git("config", "user.email", "ci@example.com")
        self.git("config", "user.name", "ci")
        self.git("config", "commit.gpgsign", "false")

    def git(self, *args: str) -> str:
        env = {**os.environ, "GIT_CONFIG_GLOBAL": os.devnull, "GIT_CONFIG_SYSTEM": os.devnull}
        return subprocess.run(["git", *args], cwd=self.root, check=True, capture_output=True,
                              text=True, env=env).stdout.strip()

    def push(self, path: str, text: str) -> str:
        file = self.root / path
        file.parent.mkdir(parents=True, exist_ok=True)
        file.write_text(text, encoding="utf-8")
        self.git("add", path)
        self.git("commit", "--quiet", "-m", f"change {path}")
        return self.git("rev-parse", "HEAD")


class LocalGit(Git):
    """A full local history: nothing to fetch."""

    def deepen(self, head: str) -> None:
        return None


def artifact(sha: str, run_id: int, created: str, *, branch: str = "feat-cmux-next",
             repository_id: int = REPO_ID, name: str = MARKER) -> dict:
    return {"name": name, "created_at": created, "workflow_run": {
        "id": run_id, "head_sha": sha, "head_branch": branch,
        "repository_id": repository_id, "head_repository_id": repository_id}}


class FastTierAnchorTests(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.history = History(Path(self.tmp.name))
        self.git = LocalGit(Path(self.tmp.name))
        self.history.push(SWIFT, "// base\n")
        self.history.push(DOCS, "base\n")
        self.finished = self.history.push("README.md", "finished\n")

    def test_cancel_cancel_then_path_skip_candidate_runs_for_the_first_pushs_swift(self) -> None:
        first = self.history.push(SWIFT, "// #27931\n")   # fast tier cancelled (run 41012836913)
        second = self.history.push(DOCS, "second\n")       # fast tier cancelled (run 41013125180)
        third = self.history.push(DOCS, "third\n")         # run 41014687570
        # Against the previous push, the third push is a path-skip candidate.
        since_previous = self.git.changed(second, third)
        self.assertEqual(since_previous, [DOCS])
        self.assertEqual(outputs(route(ROOT, "pull_request", since_previous, set()))["macos"], "false")
        # Only the push before the first finished its fast tier; the cancelled
        # ones uploaded no marker.
        markers = markers_from([artifact(self.finished, 41012000000, "2026-10-30T06:00:00Z")], REPO_ID)
        decision = decide(self.git, third, lambda: markers)
        self.assertTrue(decision.fast_tier, decision.reason)
        self.assertEqual(decision.anchor, self.finished)
        self.assertIn(SWIFT, decision.changed)
        self.assertNotEqual(first, decision.anchor)

    def test_docs_only_push_after_a_finished_fast_tier_skips(self) -> None:
        docs = self.history.push(DOCS, "after\n")
        markers = markers_from([artifact(self.finished, 41012000000, "2026-10-30T06:00:00Z")], REPO_ID)
        decision = decide(self.git, docs, lambda: markers)
        self.assertFalse(decision.fast_tier, decision.reason)
        self.assertEqual(decision.changed, [DOCS])

    def test_daemon_only_push_skips_the_swift_fast_tier(self) -> None:
        daemon = self.history.push("cmux-tui/crates/acpmux/src/cli/help_examples/session.rs", "daemon\n")
        markers = markers_from([artifact(self.finished, 1, "2026-10-30T06:00:00Z")], REPO_ID)
        decision = decide(self.git, daemon, lambda: markers)
        self.assertFalse(decision.fast_tier, decision.reason)

    def test_swift_push_after_a_finished_fast_tier_runs(self) -> None:
        swift = self.history.push(SWIFT, "// next\n")
        markers = markers_from([artifact(self.finished, 1, "2026-10-30T06:00:00Z")], REPO_ID)
        self.assertTrue(decide(self.git, swift, lambda: markers).fast_tier)

    def test_newest_marker_on_this_history_is_the_anchor(self) -> None:
        swift = self.history.push(SWIFT, "// tested\n")   # finished later
        docs = self.history.push(DOCS, "after\n")
        markers = markers_from([
            artifact(self.finished, 1, "2026-10-30T06:00:00Z"),
            artifact(swift, 2, "2026-10-30T06:30:00Z"),
            artifact("f" * 40, 3, "2026-10-30T07:00:00Z"),   # not on this history
        ], REPO_ID)
        decision = decide(self.git, docs, lambda: markers)
        self.assertEqual(decision.anchor, swift)
        self.assertFalse(decision.fast_tier, decision.reason)

    def test_no_marker_runs_the_fast_tier(self) -> None:
        docs = self.history.push(DOCS, "after\n")
        with self.assertRaises(Skip):
            decide(self.git, docs, lambda: [])

    def test_marker_off_this_history_runs_the_fast_tier(self) -> None:
        docs = self.history.push(DOCS, "after\n")
        with self.assertRaises(Skip):
            decide(self.git, docs, lambda: [("e" * 40, 9)])

    def test_same_tree_runs_again(self) -> None:
        markers = [(self.finished, 1)]
        self.assertTrue(decide(self.git, self.finished, lambda: markers).fast_tier)

    def test_markers_from_other_branches_repositories_and_names_do_not_count(self) -> None:
        sha = "a" * 40
        self.assertEqual(markers_from([
            artifact(sha, 1, "1", branch="lane/x"),
            artifact(sha, 2, "2", repository_id=99),
            artifact(sha, 3, "3", name="cmux-next-fast-tier-receipt-3-attempt-1"),
            artifact("not-a-sha", 4, "4"),
        ], REPO_ID), [])

    def test_api_failure_fails_open(self) -> None:
        def broken() -> list[tuple[str, int]]:
            raise OSError("HTTP 502")

        output = Path(self.tmp.name) / "out.txt"
        original = fast_tier_anchor.github_markers
        fast_tier_anchor.github_markers = lambda repository, token: broken
        self.addCleanup(setattr, fast_tier_anchor, "github_markers", original)
        old = os.environ.get("GH_TOKEN")
        os.environ["GH_TOKEN"] = "token"
        self.addCleanup(lambda: os.environ.pop("GH_TOKEN") if old is None else os.environ.update(GH_TOKEN=old))
        fast_tier_anchor.main(["--repository", "o/r", "--head", self.finished,
                               "--github-output", str(output), "--summary", ""])
        self.assertIn("fast_tier=true", output.read_text(encoding="utf-8"))

    def test_workflow_gates_the_push_fast_tier_on_the_anchor(self) -> None:
        text = (ROOT / ".github/workflows/cmux-next.yml").read_text(encoding="utf-8")
        job = text[text.index("\n  fast-tier:\n"):text.index("\n  fast-tier-cargo:\n")]
        gate = job[job.index("    if: "):].split("\n", 1)[0]
        self.assertIn("refs/heads/feat-cmux-next' && needs.path_route.outputs.fast_tier != 'false'", gate)
        self.assertIn(f"name: {MARKER}", job)
        self.assertEqual(job.count("always() && !cancelled() && github.event_name == 'push'"), 2)
        route_job = text[text.index("\n  path_route:\n"):text.index("\n  fast-tier:\n")]
        self.assertIn("fast_tier: ${{ steps.route.outputs.fast_tier }}", route_job)
        self.assertIn('|| echo "fast_tier=true" >> "$GITHUB_OUTPUT"', route_job)
        self.assertIn("scripts/ci/fast_tier_anchor.py", route_job)


if __name__ == "__main__":
    unittest.main()
