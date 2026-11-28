"""projection-scale: a real smoke run's rows (lane VM, 2026-11-24) -> rows; the harness's git matrix end to end."""
from __future__ import annotations

import importlib.util
import json
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

BENCH_DIR = Path(__file__).resolve().parents[1]
fixture_spec = importlib.util.spec_from_file_location("git_fixture_env", BENCH_DIR.parents[1] / "tests" / "git_fixture_env.py")
git_fixture_env = importlib.util.module_from_spec(fixture_spec)
fixture_spec.loader.exec_module(git_fixture_env)

sys.path.insert(0, str(BENCH_DIR))

from benchlib.bench import BenchError, Context  # noqa: E402
from benches.projection_scale import BENCH  # noqa: E402

FIXTURES = Path(__file__).resolve().parent / "fixtures" / "projection-scale"
HARNESS = BENCH_DIR.parents[1] / "scripts" / "measure" / "projection-scale" / "measure.py"


def ingest(path):
    ctx = Context(bench=BENCH, build={"channel": "sha", "version": None, "sha": "d" * 40}, host_role="anywhere",
                  host={"name": "lane", "role": "anywhere", "os": "Linux", "chip": "x86_64"},
                  timestamp="2026-11-24T00:00:00Z")
    BENCH.ingest(ctx, path)
    return ctx


def harness():
    spec = importlib.util.spec_from_file_location("projection_scale_measure", HARNESS)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class ProjectionScaleTest(unittest.TestCase):
    def test_fixture_rows(self):
        rows = ingest(FIXTURES / "rows.jsonl").rows
        got = {(r["metric"], r["labels"]["mode"], r["labels"]["profile"]): r["value"] for r in rows}
        self.assertEqual(got[("rg_cold", "folder", "local")], 1.835)
        self.assertEqual(got[("rg_cold_down", "folder", "local")], 742611)
        self.assertEqual(got[("rg_cold_asks", "folder", "local")], 8)
        self.assertEqual(got[("clone_down", "sparse", "local")], 3112)
        self.assertEqual(got[("widen_down", "sparse", "local")], 201207)
        self.assertEqual(got[("clone_status1", "gitzst", "local")], 0.036)
        self.assertIn(("rg_cold", "folder", "github-v4-good"), got)
        self.assertNotIn(("clone_asks", "depth1", "local"), got)  # git rows have no ask count

    def test_failed_row_is_a_note_and_empty_file_refused(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "rows.jsonl"
            path.write_text(json.dumps({"kind": "git", "mode": "overlay", "phase": "clone", "wall_s": 0.1, "rc": 1,
                                        "note": "no sudo"}) + "\n")
            with self.assertRaises(BenchError):
                ingest(path)

    def test_projected_seconds(self):
        m = harness()
        row = {"profile": "local", "phase": "rg_cold", "wall_s": 1.0, "down_bytes": 14_000_000, "asks": 10, "rc": 0}
        self.assertEqual(m.projected(row, "github-v4-bad"), 1.0 + 100.0 + 0.67)
        self.assertIsNone(m.projected({**row, "profile": "store-v6-8"}, "github-v4-bad"))
        self.assertIsNone(m.projected({**row, "phase": "serve_start"}, "github-v4-bad"))
        table = m.render([row], ["store-v6-8"], markdown=True).splitlines()
        self.assertEqual(table[0].count("|"), len(m.COLUMNS) + 2)

    @unittest.skipUnless(shutil.which("git") and shutil.which("zstd"), "needs git and zstd")
    def test_git_matrix_on_a_small_repo(self):
        with tempfile.TemporaryDirectory() as tmp:
            repo = Path(tmp) / "src"
            (repo / "a").mkdir(parents=True)
            (repo / "b").mkdir()
            for i in range(20):
                (repo / "a" / f"{i}.txt").write_text("the quick brown fox\n" * 50)
                (repo / "b" / f"{i}.txt").write_text("jumps over the dog\n" * 50)
            git = ["git", "-C", str(repo), "-c", "user.name=m", "-c", "user.email=m@example.com"]
            git_fixture_env.init_repo(repo, "-b", "main")
            subprocess.run(git + ["add", "-A"], check=True)
            subprocess.run(git + ["commit", "-qm", "one"], check=True)
            out = Path(tmp) / "out"
            got = subprocess.run([sys.executable, str(HARNESS), "git", str(repo), "--options", "depth1,sparse,gitzst",
                                  "--cone", "a", "--out", str(out), "--scratch", tmp], capture_output=True, text=True,
                                 timeout=300)
            self.assertEqual(got.returncode, 0, got.stderr)
            rows = {(r["mode"], r["phase"]): r for r in map(json.loads, (out / "rows.jsonl").read_text().splitlines())}
            self.assertEqual({r["rc"] for r in rows.values()}, {0})
            self.assertGreater(rows[("depth1", "clone")]["down_bytes"], 0)
            self.assertLess(rows[("sparse", "clone")]["down_bytes"], rows[("depth1", "clone")]["down_bytes"])
            self.assertGreater(rows[("sparse", "widen")]["down_bytes"], 0)
            self.assertEqual(rows[("gitzst", "clone")]["tree_bytes"], rows[("depth1", "clone")]["tree_bytes"])
            self.assertIn("s@github-v4-bad", got.stdout.splitlines()[0])
            ctx = ingest(out / "rows.jsonl")
            self.assertTrue(any(r["metric"] == "widen_down" for r in ctx.rows))


if __name__ == "__main__":
    unittest.main()
