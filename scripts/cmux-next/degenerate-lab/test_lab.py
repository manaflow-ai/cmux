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

    def test_each_finished_phase_leaves_rows_a_cut_log_keeps(self):
        r = {"part": "daemon", "scale": 0.1, "load": "cpu", "exit": 0,
             "runs": [{"shape": "god", "pad": "x" * 900}], "churnSamples": [{"t": 60, "rssMb": 879}]}
        lines = lab.result_lines(r)
        self.assertTrue(all(len(line) <= lab.LOG_LINE + len("LAB-RESULT+ ") for line in lines))
        whole, part = [], []
        for line in lines:
            tag, _, text = line.partition(" ")
            part.append(text)
            if tag == "LAB-RESULT":
                whole.append(json.loads("".join(part)))
                part = []
        self.assertEqual([w["row"] for w in whole], [r["runs"][0], r["churnSamples"][0]])
        self.assertEqual(whole[1]["load"], "cpu")
        self.assertEqual(len(lab.result_lines({"part": "chat", "load": "idle", "skipped": "no harness"})), 1)


class Jobs(unittest.TestCase):
    def test_a_panic_reaches_the_job_log(self):
        log = "\n".join(["compiling"] * 50 + ["thread 'god_and_small' panicked at tests/god_daemon.rs:1418:9:",
                                                 "god attach p95 over budget", "test result: FAILED. 0 passed; 1 failed"])
        lines = lab.failure_lines(101, log)
        self.assertEqual(lines[0], "exit 101")
        self.assertIn("thread 'god_and_small' panicked at tests/god_daemon.rs:1418:9:", lines)
        self.assertIn("god attach p95 over budget", lines)
        self.assertEqual(lab.failure_lines(0, log), [])
        out = lab.result_lines({"part": "daemon", "scale": 0.1, "load": "idle", "exit": 101, "failure": lines})
        fails = [line for line in out if line.startswith("LAB-FAIL daemon x0.1 idle: ")]
        self.assertIn("LAB-FAIL daemon x0.1 idle: god attach p95 over budget", fails)
        self.assertTrue(all(len(line) <= lab.LOG_LINE for line in fails))

    def test_the_plan_is_one_job_per_part_scale_and_load(self):
        jobs = lab.plan(lab.PRESETS["nightly"])
        names = [j["name"] for j in jobs]
        self.assertEqual(len(names), len(set(names)))
        self.assertIn("daemon-x1-cpu", names)
        self.assertIn("webview-x0.1-mem", names)
        self.assertNotIn("webview-x1-idle", names)
        self.assertEqual(sum(j["part"] == "fixtures" for j in jobs), 2)
        self.assertEqual(len(jobs), 2 + 6 + 6 + 3)
        smoke = lab.plan(lab.PRESETS["smoke"])
        self.assertEqual([j["name"] for j in smoke], ["fixtures-x0.02-idle", "daemon-x0.02-idle", "chat-x0.02-idle", "webview-x0.02-idle"])

    def test_merge_reads_every_jobs_results(self):
        small = {"firstListMs": 100, "peersMs": 200, "attachUs": {"p95": 900}, "sendFirstTokenUs": {"p95": 5000}, "rss": 10}
        with tempfile.TemporaryDirectory() as t:
            t = Path(t)
            for name, rs in (("webview-x0.1-idle", [{"part": "webview", "scale": 0.1, "load": "idle", "exit": 0}]),
                             ("daemon-x0.1-cpu", [{"part": "daemon", "scale": 0.1, "load": "cpu", "exit": 0, "runs": [small, small]},
                                                   {"part": "daemon", "scale": 0.1, "load": "recovered", "exit": 101}])):
                (t / name).mkdir()
                (t / name / "results.json").write_text(json.dumps(rs))
            merged = lab.merge([str(t)], t / "out")
            self.assertEqual([r["part"] for r in merged], ["daemon", "daemon", "webview"])
            out = t / "out"
            out.mkdir()
            lab.write_outputs(merged, out)
            rows = json.loads((out / "god-small.json").read_text())["rows"]
            self.assertIn("daemon.first_list_ms.cpu.x0.1", [r["name"] for r in rows])
            self.assertIn("| daemon | 0.1 | recovered | 101 |", (out / "summary.md").read_text())

    def test_merge_runs_as_the_workflow_calls_it(self):
        # The report job passes --out before the folder; a plain parse_args refused that.
        with tempfile.TemporaryDirectory() as t:
            t = Path(t)
            (t / "jobs" / "chat-x0.02-idle").mkdir(parents=True)
            (t / "jobs" / "chat-x0.02-idle" / "results.json").write_text(
                json.dumps([{"part": "chat", "scale": 0.02, "load": "idle", "exit": 0}]))
            run = subprocess.run([sys.executable, "-I", str(Path(lab.__file__)), "merge", "--out", str(t / "out"), str(t / "jobs")],
                                 capture_output=True, text=True)
            self.assertEqual(run.returncode, 0, run.stderr)
            self.assertTrue((t / "out" / "summary.md").exists())


if __name__ == "__main__":
    unittest.main()
