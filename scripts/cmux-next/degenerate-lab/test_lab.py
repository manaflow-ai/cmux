#!/usr/bin/env python3
"""Tests of the degenerate lab's own logic: the transcript generator's shape and determinism, and
the god-small rows the nightly report reads. `python3 -I test_lab.py`."""

from __future__ import annotations

import importlib.util
import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent


def load(name: str):
    spec = importlib.util.spec_from_file_location(name, HERE / f"{name}.py")
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


gen = load("gen_transcript")
lab = load("lab")


def generate(tmp: Path, scale: float, seed: int, fmt: str = "claude") -> tuple[Path, dict]:
    out = tmp / f"{fmt}-{scale}-{seed}.jsonl"
    text = subprocess.run([sys.executable, "-I", str(HERE / "gen_transcript.py"), "--out", str(out), "--scale", str(scale),
                           "--seed", str(seed), "--format", fmt], check=True, capture_output=True, text=True).stdout
    return out, json.loads(text)


class Transcript(unittest.TestCase):
    def test_every_line_is_json_with_the_measured_type_counts(self):
        with tempfile.TemporaryDirectory() as tmp:
            out, summary = generate(Path(tmp), 0.02, 3)
            types: dict[str, int] = {}
            for line in out.read_text().splitlines():
                types[json.loads(line)["type"]] = types.get(json.loads(line)["type"], 0) + 1
            for kind, shape in gen.SHAPE.items():
                self.assertEqual(types.get(kind, 0), round(shape[0] * 0.02), kind)
            self.assertEqual(summary["lines"], sum(types.values()))

    def test_tool_results_answer_tool_uses(self):
        with tempfile.TemporaryDirectory() as tmp:
            out, _ = generate(Path(tmp), 0.02, 4)
            uses, answered = set(), 0
            for line in out.read_text().splitlines():
                d = json.loads(line)
                for block in (d.get("message") or {}).get("content") or []:
                    if isinstance(block, dict) and block.get("type") == "tool_use":
                        uses.add(block["id"])
                    if isinstance(block, dict) and block.get("type") == "tool_result" and block["tool_use_id"] in uses:
                        answered += 1
            self.assertGreater(answered, 0.8 * len(uses))

    def test_the_same_seed_writes_the_same_bytes(self):
        with tempfile.TemporaryDirectory() as tmp:
            a, _ = generate(Path(tmp) / "a", 0.01, 7)
            b, _ = generate(Path(tmp) / "b", 0.01, 7)
            self.assertEqual(a.read_bytes(), b.read_bytes())

    def test_sizes_follow_the_quantiles(self):
        import random

        sizes = sorted(gen.quantile_sizes(random.Random(1), 20000, 1378, 4639, 83785, 4154812, 265647059 * 20000 // 34646))
        self.assertAlmostEqual(sizes[10000] / 1378, 1, delta=0.1)
        self.assertAlmostEqual(sizes[18000] / 4639, 1, delta=0.1)
        self.assertEqual(sizes[-1], 4154812)

    def test_codex_lines_are_json(self):
        with tempfile.TemporaryDirectory() as tmp:
            out, _ = generate(Path(tmp), 0.01, 5, "codex")
            kinds = {json.loads(line)["type"] for line in out.read_text().splitlines()}
            self.assertLessEqual({"session_meta", "response_item", "event_msg"}, kinds)


class GodSmall(unittest.TestCase):
    def test_daemon_runs_become_rows_the_report_reads(self):
        small = {"firstListMs": 100, "peersMs": 200, "attachUs": {"p95": 900}, "sendFirstTokenUs": {"p95": 5000}, "rss": 10}
        god = {"firstListMs": 400, "peersMs": 210, "attachUs": {"p95": 1000}, "sendFirstTokenUs": None, "rss": 30}
        rows = lab.god_small_rows([{"part": "daemon", "scale": 1.0, "load": "idle", "runs": [small, god]}])
        names = {r["name"]: r for r in rows}
        self.assertEqual(names["daemon.first_list_ms.idle.x1"], {"name": "daemon.first_list_ms.idle.x1", "small_p95": 100, "god_p95": 400})
        self.assertNotIn("daemon.send_first_token_us.idle.x1", names)
        self.assertIn("over 1.2x", lab.summary_md([], rows))

    def test_webview_rows_carry_their_load(self):
        report = {"rows": [{"name": "degenerate.scroll.interval_p95_ms", "small_p95": 8, "god_p95": 9}]}
        rows = lab.god_small_rows([{"part": "webview", "scale": 1.0, "load": "cpu", "report": report}])
        self.assertEqual(rows[0]["name"], "degenerate.scroll.interval_p95_ms.cpu")


if __name__ == "__main__":
    unittest.main()
