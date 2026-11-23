#!/usr/bin/env python3
"""Hot swap out: a first-red commit's pieces come out one at a time, never the whole commit (scripts/ci/piece_swap.py).

Leo, 2026-11-22 08:53Z: "the partial revert, not all the way back, but to individual pieces ... if we can hot swap
in, then we should be able to hot swap out. we should be able to neutralize and drill down into individual pieces."
"""

from __future__ import annotations

import datetime as dt
import json
import subprocess
import sys
import tempfile
import unittest
from unittest import mock
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts" / "ci"))

import piece_swap  # noqa: E402
import post_merge_batch as batch  # noqa: E402
# tests/git_fixture_env.py, loaded by path: `python3 -I` puts no script folder on sys.path.
import importlib.util as _git_fixture_importlib  # noqa: E402
from os import path as _git_fixture_path  # noqa: E402
_git_fixture_spec = _git_fixture_importlib.spec_from_file_location(
    "git_fixture_env", _git_fixture_path.join(_git_fixture_path.dirname(_git_fixture_path.abspath(__file__)), "git_fixture_env.py"))
git_fixture_env = _git_fixture_importlib.module_from_spec(_git_fixture_spec)
_git_fixture_spec.loader.exec_module(git_fixture_env)

DRILL_RED = ".github/post-merge-drill-red"
DRILL_KEEP = ".github/post-merge-drill/keep"


class ClassifierTest(unittest.TestCase):
    def setUp(self):
        self.c = piece_swap.load_classifier()

    def test_classes_by_path(self):
        cases = {
            DRILL_RED: "drill",
            DRILL_KEEP: "drill",
            "cmux.release.entitlements": "signing-release",
            ".github/workflows/cmux-next-nightly.yml": "signing-release",
            "backend/db/migrations/0001_init.sql": "migrations",
            "Packages/macOS/CmuxNext/Package.swift": "published-builds",
            "webviews/src/agent-pane/composer/Composer.tsx": "web-ui",
            "cmux-tui/crates/cmux-customize/src/lib.rs": "rust-core",
            "scripts/ci/post_merge_batch.py": "tools",
            "docs/ci/landing.md": "docs",
            "Native/Thing.swift": "other",
        }
        for path, want in cases.items():
            self.assertEqual(self.c.classify(path)["name"], want, path)

    def test_every_class_says_how_it_swaps(self):
        for cls in self.c.classes:
            self.assertIn(cls["swap"], piece_swap.SWAPS, cls["name"])
        self.assertEqual(self.c.classify("Native/Thing.swift")["swap"], "never")

    def test_the_brief_classes_exist(self):
        names = {c["name"] for c in self.c.classes}
        for want in ("docs", "tools", "web-ui", "rust-core", "signing-release", "migrations", "published-builds", "drill"):
            self.assertIn(want, names)

    def test_pieces_split_on_feature_roots(self):
        files = [
            "webviews/src/agent-pane/composer/Composer.tsx",
            "webviews/src/agent-pane/composer/composer.css",
            "webviews/src/agent-pane/turns/turns.ts",
            "cmux-tui/crates/cmux-customize/src/lib.rs",
            DRILL_RED,
        ]
        pieces = piece_swap.split(files, self.c)
        ids = [p.id for p in pieces]
        self.assertEqual(ids, sorted(ids))
        self.assertIn("webviews/src/agent-pane/composer", ids)
        self.assertIn("webviews/src/agent-pane/turns", ids)
        self.assertIn("cmux-tui/crates/cmux-customize", ids)
        self.assertIn(DRILL_RED, ids)  # under no root: a piece of its own
        composer = next(p for p in pieces if p.id == "webviews/src/agent-pane/composer")
        self.assertEqual(len(composer.files), 2)
        self.assertEqual(composer.cls, "web-ui")


class DecideTest(unittest.TestCase):
    def setUp(self):
        self.c = piece_swap.load_classifier()
        self.config = piece_swap.load_config()

    def test_ships_with_only_the_drill_class(self):
        self.assertEqual(self.config["classes"], ["drill"])

    def test_drill_commit_swaps(self):
        ok, why = piece_swap.decide(piece_swap.split([DRILL_RED, DRILL_KEEP], self.c), self.config, {})
        self.assertTrue(ok, why)

    def test_a_class_not_listed_keeps_the_whole_revert(self):
        ok, why = piece_swap.decide(piece_swap.split([DRILL_RED, "docs/x.md"], self.c), self.config, {})
        self.assertFalse(ok)
        self.assertIn("docs", why)

    def test_one_switch_stops_it(self):
        ok, why = piece_swap.decide(piece_swap.split([DRILL_RED], self.c), self.config, {"NEXT_PIECE_SWAP": "0"})
        self.assertFalse(ok)
        self.assertIn("NEXT_PIECE_SWAP", why)

    def test_never_class_never_swaps_even_when_listed(self):
        config = {**self.config, "classes": ["drill", "migrations"]}
        ok, _ = piece_swap.decide(piece_swap.split(["backend/db/migrations/1.sql"], self.c), config, {})
        self.assertFalse(ok)

    def test_never_takes_back_a_take_back(self):
        for subject in ('Revert "x (#1)"', "revert: x", "Swap out webviews/src/a/b of #12 (post-merge batch)"):
            self.assertTrue(piece_swap.is_take_back(subject), subject)
        self.assertFalse(piece_swap.is_take_back("agent pane: fold prompts (#49052)"))

    def test_breaker(self):
        now = dt.datetime(2026, 11, 22, 10, 0, tzinfo=dt.timezone.utc)
        recent = [now - dt.timedelta(minutes=m) for m in (5, 20, 50)]
        self.assertTrue(piece_swap.breaker_open(recent, now, 3))
        self.assertFalse(piece_swap.breaker_open(recent[:2] + [now - dt.timedelta(minutes=70)], now, 3))

    def test_branch_is_keyed_by_job_and_first_red(self):
        a = piece_swap.branch_name("a" * 40, "drill / drill", "49052")
        self.assertEqual(a, piece_swap.branch_name("a" * 40, "drill / drill", "49052"))
        self.assertNotEqual(a, piece_swap.branch_name("b" * 40, "drill / drill", "49052"))
        self.assertNotEqual(a, piece_swap.branch_name("a" * 40, "web / lint", "49052"))
        self.assertTrue(a.startswith("swapout/"))


class DrillDownTest(unittest.TestCase):
    def test_static_narrowing_by_the_red_suite_paths(self):
        c = piece_swap.load_classifier()
        pieces = piece_swap.split([DRILL_RED, DRILL_KEEP, "docs/ci/landing.md"], c)
        got = [p.id for p in piece_swap.suspects(pieces, [DRILL_RED])]
        self.assertEqual(got, [DRILL_RED])
        self.assertEqual(len(piece_swap.suspects(pieces, [])), 3)  # a suite with no paths reads everything

    def test_halves_find_the_one_piece(self):
        ids = [f"p{i:02d}" for i in range(11)]
        for bad in ids:
            candidates, probes = list(ids), 0
            while len(candidates) > 1:
                out = piece_swap.halve(candidates)
                self.assertTrue(0 < len(out) < len(candidates))
                conclusion = "success" if bad in out else "failure"  # red goes away when the bad piece is out
                candidates = piece_swap.narrow(candidates, out, conclusion)
                probes += 1
            self.assertEqual(candidates, [bad])
            self.assertLessEqual(probes, 4)

    def test_no_verdict_narrows_nothing(self):
        self.assertIsNone(piece_swap.narrow(["a", "b"], ["a"], "cancelled"))

    def test_state_round_trips_through_a_workflow_input(self):
        state = piece_swap.State("c" * 40, ["a", "b"], ["a"], 1)
        self.assertEqual(piece_swap.State.parse(state.dump()), state)
        self.assertIsNone(piece_swap.State.parse(""))
        with self.assertRaises(ValueError):
            piece_swap.State.parse('{"culprit": "nope"}')


class SwapOutCommitTest(unittest.TestCase):
    def git(self, *args):
        return subprocess.run(["git", *args], cwd=self.repo, check=True, capture_output=True, text=True,
                              env=git_fixture_env.fixture_env()).stdout.strip()

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.repo = Path(self.tmp.name) / "r"
        git_fixture_env.init_repo(self.repo, "-q", "-b", "main")
        self.git("config", "user.name", "t")
        self.git("config", "user.email", "t@example.com")
        (self.repo / "base.txt").write_text("base\n")
        self.git("add", "-A")
        self.git("commit", "-qm", "base")
        (self.repo / ".github/post-merge-drill").mkdir(parents=True)
        (self.repo / DRILL_RED).write_text("red\n")
        (self.repo / DRILL_KEEP).write_text("keep\n")
        (self.repo / "base.txt").write_text("base\nmore\n")
        self.git("add", "-A")
        self.git("commit", "-qm", "drill: two pieces")
        self.culprit = self.git("rev-parse", "HEAD")

    def tearDown(self):
        self.tmp.cleanup()

    def test_one_piece_out_the_rest_stays(self):
        sha = piece_swap.swap_out_commit(self.culprit, self.culprit, [DRILL_RED], "swap out the red", cwd=self.repo)
        files = self.git("ls-tree", "-r", "--name-only", sha).splitlines()
        self.assertNotIn(DRILL_RED, files)
        self.assertIn(DRILL_KEEP, files)
        self.assertEqual(self.git("show", f"{sha}:base.txt"), "base\nmore")
        self.assertEqual(self.git("rev-parse", f"{sha}^"), self.culprit)
        self.assertEqual(self.git("rev-parse", "HEAD"), self.culprit)  # no worktree or branch moved

    def test_a_runner_with_no_git_identity_still_gets_the_commit(self):
        """The judge job rebuilds a piece probe's commit to compare trees, on a runner with no user.name
        (cmux run 45046212800, job 137282347168: "Author identity unknown", so no swap-out followed)."""
        self.git("config", "--unset", "user.name")
        self.git("config", "--unset", "user.email")
        self.git("config", "user.useConfigOnly", "true")  # as a runner whose account has no name
        clean = {k: v for k, v in git_fixture_env.fixture_env().items()
                 if not k.startswith(("GIT_AUTHOR_", "GIT_COMMITTER_")) and k != "EMAIL"}
        clean.update(GIT_CONFIG_GLOBAL="/dev/null", GIT_CONFIG_NOSYSTEM="1")  # no identity from this machine either
        with mock.patch.dict(piece_swap.os.environ, clean, clear=True):
            sha = piece_swap.swap_out_commit(self.culprit, self.culprit, [DRILL_RED], "expected probe", cwd=self.repo)
        self.assertIsNotNone(sha)
        self.assertNotIn(DRILL_RED, self.git("ls-tree", "-r", "--name-only", sha).splitlines())

    def test_onto_a_later_tip(self):
        (self.repo / "later.txt").write_text("later\n")
        self.git("add", "-A")
        self.git("commit", "-qm", "later")
        tip = self.git("rev-parse", "HEAD")
        sha = piece_swap.swap_out_commit(tip, self.culprit, [DRILL_RED], "swap out", cwd=self.repo)
        files = self.git("ls-tree", "-r", "--name-only", sha).splitlines()
        self.assertIn("later.txt", files)
        self.assertNotIn(DRILL_RED, files)

    def test_a_conflict_is_none(self):
        (self.repo / "base.txt").write_text("rewritten\n")
        self.git("add", "-A")
        self.git("commit", "-qm", "rewrite")
        tip = self.git("rev-parse", "HEAD")
        self.assertIsNone(piece_swap.swap_out_commit(tip, self.culprit, ["base.txt"], "swap out", cwd=self.repo))

    def test_manifest(self):
        m = piece_swap.manifest(self.culprit, piece_swap.load_classifier(), cwd=self.repo)
        self.assertEqual(m["culprit"], self.culprit)
        ids = [p["id"] for p in m["pieces"]]
        self.assertIn(DRILL_RED, ids)
        self.assertIn(DRILL_KEEP, ids)
        self.assertIn("base.txt", ids)

    def test_whole_revert_is_only_proposed(self):
        cmd = piece_swap.whole_revert_command(self.culprit, "feat-cmux-next", parents=1)
        self.assertIn(self.culprit, cmd)
        self.assertIn("git revert", cmd)
        self.assertIn("-m 1", piece_swap.whole_revert_command(self.culprit, "feat-cmux-next", parents=2))


class WebPiecesTest(unittest.TestCase):
    def test_web_piece_ids_use_the_bundle_form(self):
        cls = piece_swap.load_classifier()
        pieces = piece_swap.split(["webviews/src/pages/settings/Row.tsx", "webviews/src/kit/Button.tsx", "docs/a.md"], cls)
        ids = {p.id: piece_swap.web_piece_id(p) for p in pieces}
        self.assertEqual(ids["webviews/src/pages/settings"], "pages/settings")
        self.assertIsNone(ids["webviews/src/kit"])
        sw = piece_swap.web_switches(pieces, "cmux#1 red")
        self.assertEqual(sw, {"pages/settings": {"serve": "last-good", "reason": "cmux#1 red"}})


class WorkflowTest(unittest.TestCase):
    def test_probe_carries_piece_state(self):
        probe = batch.Probe("drill", "drill / drill", "drill", "a" * 40, "b" * 40, "a" * 40, "1", pieces='{"x":1}')
        self.assertEqual(probe.inputs()["pieces"], '{"x":1}')
        self.assertNotIn("pieces", batch.Probe("drill", "drill / drill", "drill", "a" * 40, "b" * 40, "", "1").inputs())

    def test_workflow_takes_the_pieces_input(self):
        text = (ROOT / ".github" / "workflows" / "cmux-next-post-merge.yml").read_text()
        self.assertIn("pieces:", text)
        self.assertIn("NEXT_PIECE_SWAP", text)

    def test_pieces_drill_branch_plans_only_the_drill_suite(self):
        suites = batch.load_manifest()
        plan = batch.plan_batch("a" * 40, [], suites, lambda base: [], branch="lane/post-merge-drill-pieces-1")
        self.assertEqual(plan["suites"], ["drill"])
        plan = batch.plan_batch("a" * 40, [], suites, lambda base: [], branch="feat-cmux-next")
        self.assertEqual(len(plan["suites"]), len(suites))

    def test_pieces_drill_branch_stays_drill_only_after_its_green_batch(self):
        """Run 45037084940: the red batch planned web and rust-workspaces too, and its judge waited 85 minutes
        on web shards before it could name the drill's red."""
        suites = batch.load_manifest()
        green = [{"id": 1, "event": "push", "status": "completed", "head_sha": "b" * 40, "display_title": "batch push", "name": "batch push"}]
        self.assertTrue(batch.is_batch(green[0]))
        plan = batch.plan_batch("a" * 40, green, suites, lambda base: [DRILL_RED, DRILL_KEEP], branch="lane/post-merge-drill-pieces-4")
        self.assertEqual(plan["suites"], ["drill"])
        self.assertEqual(plan["base"], "b" * 40)

    def test_drill_suite_reads_both_drill_pieces(self):
        drill = batch.load_manifest()["drill"]
        self.assertTrue(drill.reached([DRILL_RED]))
        self.assertTrue(drill.reached([DRILL_KEEP]))


if __name__ == "__main__":
    unittest.main()
