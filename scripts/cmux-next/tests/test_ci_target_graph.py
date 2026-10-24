#!/usr/bin/env python3
"""ci-target-graph.py: a test target's literal reads are the same in a clone and in a worktree.

A fixture's ".git/config" literal resolved against the repository root in a clone (.git is a
directory there) and not in a worktree (.git is a file), so the generated graph differed between
the two and agents in worktrees hand-restored the row after each regeneration (review of
ns-check-concurrency-thinscroller, 2026-10-23). Git's own metadata is not a repository read.
"""

import importlib.util
import sys
import tempfile
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
SCRIPT = HERE.parent / "ci-target-graph.py"
SPEC = importlib.util.spec_from_file_location("ci_target_graph", SCRIPT)
assert SPEC and SPEC.loader
graph = importlib.util.module_from_spec(SPEC)
sys.modules["ci_target_graph"] = graph
SPEC.loader.exec_module(graph)

SOURCE = 'let config = ".git/config"\nlet plan = "plans/cmux-next/idle-wakeups.md"\n'


class LiteralReadsTests(unittest.TestCase):
    def reads(self, make_git) -> list[str]:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp).resolve()
            make_git(root)
            (root / "plans/cmux-next").mkdir(parents=True)
            (root / "plans/cmux-next/idle-wakeups.md").write_text("plan\n", encoding="utf-8")
            package = root / "Packages/macOS/CmuxNext"
            tests = package / "Tests/SomeTests"
            tests.mkdir(parents=True)
            (tests / "SomeTests.swift").write_text(SOURCE, encoding="utf-8")
            saved = (graph.ROOT, graph.PACKAGE)
            graph.ROOT, graph.PACKAGE = root, package
            graph.directory_names.cache_clear()
            try:
                return graph.literal_reads(tests)
            finally:
                graph.ROOT, graph.PACKAGE = saved
                graph.directory_names.cache_clear()

    def test_a_clone_does_not_count_git_metadata(self):
        def clone(root: Path) -> None:
            (root / ".git").mkdir()
            (root / ".git/config").write_text("[core]\n", encoding="utf-8")

        self.assertEqual(self.reads(clone), ["plans/cmux-next/idle-wakeups.md"])

    def test_a_worktree_gives_the_same_reads(self):
        def worktree(root: Path) -> None:
            (root / ".git").write_text("gitdir: /elsewhere/.git/worktrees/x\n", encoding="utf-8")

        self.assertEqual(self.reads(worktree), ["plans/cmux-next/idle-wakeups.md"])


if __name__ == "__main__":
    unittest.main()
