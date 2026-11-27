"""autocloud-repo-ready: the harness's Markdown table becomes repo_ready, from_github and speedup rows per arm."""
from __future__ import annotations

import sys
import tempfile
import unittest
from pathlib import Path

BENCH_DIR = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(BENCH_DIR))

from benchlib.bench import Context  # noqa: E402
from benchlib.registry import load_all  # noqa: E402

FIXTURE = BENCH_DIR / "tests" / "fixtures" / "autocloud-repo-ready" / "gcp-lane-vm.txt"


def ingest(text: str):
    bench = load_all()["autocloud-repo-ready"]
    ctx = Context(bench=bench, build={"channel": "local", "version": "", "sha": "a" * 40}, host_role="anywhere",
                  host={"name": "vm", "role": "anywhere", "os": "Linux", "chip": "x86_64"})
    with tempfile.TemporaryDirectory() as d:
        path = Path(d) / "out.txt"
        path.write_text(text)
        bench.ingest(ctx, path)
    return ctx, {(r["metric"], r["labels"]["arm"]): r for r in ctx.rows}


class AutocloudRepoReady(unittest.TestCase):
    def test_registered_anywhere(self):
        bench = load_all()["autocloud-repo-ready"]
        self.assertEqual(bench.hosts, ("anywhere",))
        self.assertEqual(bench.harness, "scripts/measure/autocloud-repo-ready.sh")

    def test_rows_per_arm_and_speedup(self):
        text = "\n".join([
            "Duress: load 1.0 1.0 1.0 cores 16 git version 2.56.1 remote R branch main",
            "| row | run | repo-ready s | from GitHub MB | clean+upstream |", "|---|---|---|---|---|",
            "| before | 1 | 60.00 | 1000.0 | ok |", "| before | 2 | 70.00 | 1000.0 | ok |",
            "| after-cold | 1 | 30.00 | 300.0 | ok |", "| after-cold | 2 | 40.00 | 300.0 | BAD |",
            "| after-warm | 1 | 2.00 | 0.1 | ok |", "| after-warm | 2 | 3.00 | -0.0 | ok |"])
        ctx, got = ingest(text)
        self.assertEqual(got[("repo_ready", "before")]["value"], 65.0)
        self.assertEqual(got[("repo_ready", "after-cold")]["n"], 1, "a BAD run records no number")
        self.assertEqual(got[("from_github", "after-warm")]["unit"], "MB")
        self.assertAlmostEqual(got[("speedup", "after-warm")]["value"], 26.0)
        self.assertEqual(got[("speedup", "after-warm")]["better"], "higher")
        self.assertTrue(any("checkout BAD" in n for n in ctx.notes))

    def test_real_run_fixture(self):
        if not FIXTURE.exists():
            self.skipTest("no fixture")
        _, got = ingest(FIXTURE.read_text())
        for arm in ("before", "after-cold", "after-warm"):
            self.assertIn(("repo_ready", arm), got)
        self.assertGreater(got[("speedup", "after-warm")]["value"], 1.0)


if __name__ == "__main__":
    unittest.main()
