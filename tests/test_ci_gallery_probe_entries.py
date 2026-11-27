#!/usr/bin/env python3
"""scripts/ci/gallery_probe_entries.py: a post-merge bisect probe renders only its origin run's own red entries."""
from __future__ import annotations

import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts/ci"))
import gallery_probe_entries as probe  # noqa: E402

SCRIPT = ROOT / "scripts/ci/gallery_probe_entries.py"
WAIT = "did not render: waited 30000ms for the page"


def health(fresh=(), known=(), **extra):
    return json.dumps({"fresh": [{"state": s, "reason": r} for s, r in fresh],
                       "known": [{"state": s, "reason": r} for s, r in known], "fixed": [], "slow": [],
                       "lower": [], **extra})


class GalleryProbeEntriesTest(unittest.TestCase):
    def run_dir(self, shards: dict) -> Path:
        holder = tempfile.TemporaryDirectory()
        self.addCleanup(holder.cleanup)
        tmp = Path(holder.name)
        for name, files in shards.items():
            for rel, text in files.items():
                path = tmp / name / rel
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text(text)
        return tmp

    def test_the_head_reds_entries_minus_the_bases_same_reds(self):
        root = self.run_dir({
            "gallery-health-0": {"health.json": health(fresh=[("agent-pane.narrow#model-menu", WAIT),
                                                              ("sidebar#collapsed", "overflows its frame")]),
                                 "base/1/health.json": health(fresh=[("sidebar#collapsed", "overflows its frame")]),
                                 "base/2/health.json": health()},
            "gallery-health-1": {"health.json": health()},
            "gallery-health-2": {"health.json": health(fresh=[("settings#dark", "overflows its frame")])},
        })
        self.assertEqual(probe.own_entries(root), ["agent-pane.narrow", "settings"])

    def test_a_base_red_another_way_excuses_nothing(self):
        root = self.run_dir({"gallery-health-0": {
            "health.json": health(fresh=[("sidebar#collapsed", "overflows its frame")]),
            "base/1/health.json": health(fresh=[("sidebar#collapsed", WAIT)])}})
        self.assertEqual(probe.own_entries(root), ["sidebar"])

    def test_any_doubt_renders_everything(self):
        cases = {
            "no shard": {},
            "a missing health.json": {"gallery-health-0": {"other.txt": "x"}},
            "an unrenderable shard": {"gallery-health-0": {"health.json": json.dumps({"error": "browser launch"})}},
            "a crash": {"gallery-health-0": {"health.json": health(
                fresh=[("a#b", "did not render: page crashed (Target crashed)")])}},
            "only shared reds": {"gallery-health-0": {"health.json": health(fresh=[("a#b", WAIT)]),
                                                      "base/1/health.json": health(fresh=[("a#b", WAIT)])}},
            "no red": {"gallery-health-0": {"health.json": health()}},
        }
        for why, shards in cases.items():
            with self.subTest(why=why):
                self.assertIsNone(probe.own_entries(self.run_dir(shards)))

    def test_the_cli_prints_the_entries_comma_joined_or_nothing(self):
        root = self.run_dir({"gallery-health-0": {"health.json": health(fresh=[("b#x", WAIT), ("a#y", WAIT)])}})
        done = subprocess.run([sys.executable, str(SCRIPT), str(root)], capture_output=True, text=True)
        self.assertEqual((done.returncode, done.stdout.strip()), (0, "a,b"), done.stderr)
        done = subprocess.run([sys.executable, str(SCRIPT), str(self.run_dir({}))], capture_output=True, text=True)
        self.assertEqual((done.returncode, done.stdout.strip()), (0, ""), done.stderr)

    def test_the_workflows_wire_the_probes_origin(self):
        gallery = (ROOT / ".github/workflows/gallery-health.yml").read_text()
        self.assertIn("python3 scripts/ci/gallery_probe_entries.py", gallery)
        self.assertIn("all: ${{ steps.size.outputs.all }}", gallery)
        self.assertIn("ids: ${{ steps.size.outputs.ids }}", gallery)
        post = (ROOT / ".github/workflows/cmux-next-post-merge.yml").read_text()
        self.assertIn("origin: ${{ inputs.mode == 'probe' && inputs.origin || '' }}", post)


if __name__ == "__main__":
    unittest.main()
