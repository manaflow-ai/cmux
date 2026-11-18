"""screen-share bench: screen-stream-eval's results.json and screen-share-vs.py's JSON lines into rows.

Fixtures (fixtures/screen-share/): results.json is the daily screen-stream-eval workflow's artifact of
2026-11-14 (rd and webrtc on one fleet Mac, host name generalised); results-two-macs.json adds an apple-high
target reconstructed from eval.py's schema (no decoded fps or latency, sampled screenshot changes instead);
vs.jsonl is reconstructed from screen-share-vs.py's orchestrator (PR #44065), which has not run on base yet.
"""
from __future__ import annotations

import sys
import unittest
from pathlib import Path

BENCH_DIR = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(BENCH_DIR))

from benchlib.bench import BenchError, Context  # noqa: E402
from benchlib.registry import load_all  # noqa: E402

FIX = Path(__file__).resolve().parent / "fixtures" / "screen-share"


def ingest(name: str) -> Context:
    bench = load_all()["screen-share"]
    ctx = Context(bench=bench, build={"channel": "sha", "version": None, "sha": "3e461a27909c32427fa5fcf7f508bc87d8d3534a"},
                  host_role="fleet", host={"name": "fleet-mini", "role": "fleet", "os": "macOS 27.0.1", "chip": "Apple M4"})
    bench.ingest(ctx, FIX / name)
    return ctx


def find(ctx: Context, metric: str, **labels: str) -> dict:
    hits = [r for r in ctx.rows if r["metric"] == metric and all(r["labels"].get(k) == v for k, v in labels.items())]
    if len(hits) != 1:
        raise AssertionError(f"{metric} {labels}: {len(hits)} rows")
    return hits[0]


class EvalResults(unittest.TestCase):
    def test_rd_and_webrtc(self):
        ctx = ingest("results.json")
        lat = find(ctx, "input_to_frame_ms", target="rd", input="key")
        self.assertAlmostEqual(lat["value"], 34.169)
        self.assertAlmostEqual(lat["p95"], 47.763)
        self.assertEqual(lat["n"], 200)
        self.assertEqual(lat["unit"], "ms")
        self.assertEqual(lat["better"], "lower")
        self.assertEqual(lat["labels"], {"method": "eval", "link": "loopback", "target": "rd", "input": "key"})
        self.assertAlmostEqual(find(ctx, "input_to_frame_ms", target="webrtc", input="pointer")["value"], 41.3, delta=0.1)
        scroll = find(ctx, "kbps", target="rd", phase="scroll")
        self.assertAlmostEqual(scroll["value"], 1617.2)
        self.assertEqual(scroll["unit"], "kbps")
        fps = find(ctx, "fps", target="webrtc", phase="scroll")
        self.assertEqual(fps["better"], "higher")
        self.assertAlmostEqual(fps["value"], 57.0)
        self.assertEqual(find(ctx, "fps", target="rd", phase="idle")["better"], "none")
        self.assertAlmostEqual(find(ctx, "ocr_cer", target="rd")["value"], 4.41)
        self.assertEqual(find(ctx, "input_lost", target="rd", input="pointer")["value"], 0)
        self.assertAlmostEqual(find(ctx, "split_ms", target="rd", input="key", stage="encode")["value"], 7.97)
        self.assertAlmostEqual(find(ctx, "split_ms", target="webrtc", input="typing", stage="decode")["value"], 4.41)
        # webrtc measures no input-to-capture: no row, never a zero.
        self.assertFalse([r for r in ctx.rows if r["metric"] == "split_ms" and r["labels"]["target"] == "webrtc"
                          and r["labels"].get("stage") == "input_to_capture"])
        self.assertEqual({r["labels"]["target"] for r in ctx.rows}, {"rd", "webrtc"})

    def test_apple_target_has_no_invented_fps_or_latency(self):
        ctx = ingest("results-two-macs.json")
        apple = [r for r in ctx.rows if r["labels"].get("target") == "apple-high"]
        self.assertTrue(all(r["labels"]["link"] == "lan" for r in apple))
        self.assertFalse([r for r in apple if r["metric"] in ("input_to_frame_ms", "fps", "first_frame_ms")])
        self.assertAlmostEqual(find(ctx, "kbps", target="apple-high", phase="scroll")["value"], 5120.0)
        changes = find(ctx, "sampled_changes", target="apple-high", phase="typing")
        self.assertEqual(changes["unit"], "per_s")
        self.assertAlmostEqual(changes["value"], 9.1)
        self.assertAlmostEqual(find(ctx, "ocr_cer", target="apple-high")["value"], 6.12)
        self.assertAlmostEqual(find(ctx, "cpu_pct", target="apple-high")["value"], 14.2)


class VsLines(unittest.TestCase):
    def test_vs_table(self):
        ctx = ingest("vs.jsonl")
        self.assertTrue(all(r["labels"]["method"] == "vs" and r["labels"]["link"] == "wired" for r in ctx.rows))
        cmux = find(ctx, "input_to_frame_ms", target="cmux", input="key")
        self.assertEqual((cmux["value"], cmux["p95"], cmux["n"]), (22.4, 31.2, 90))
        apple = find(ctx, "input_to_frame_ms", target="apple", input="key")
        self.assertEqual((apple["value"], apple["n"]), (38.0, 9))
        self.assertEqual(find(ctx, "first_frame_ms", target="apple")["value"], 620.0)
        self.assertEqual(find(ctx, "fps", target="cmux", phase="motion")["value"], 60.0)
        self.assertFalse([r for r in ctx.rows if r["metric"] == "fps" and r["labels"]["target"] == "apple"])
        kbps = find(ctx, "kbps", target="cmux", phase="motion")
        self.assertEqual((kbps["value"], kbps["n"]), (3100.0, 3))
        self.assertEqual(find(ctx, "input_lost", target="cmux")["value"], 1)  # warm-up attempts not counted
        self.assertEqual(find(ctx, "failed_trials", target="apple")["value"], 1)
        self.assertEqual(find(ctx, "key_to_frame_stage_ms", stage="draw")["value"], 12.1)
        self.assertEqual(find(ctx, "first_frame_stage_ms", stage="signal")["value"], 30.0)
        self.assertEqual(find(ctx, "rtt_ms", stat="min")["value"], 0.41)
        self.assertTrue(any("apple fps trial 1" in n for n in ctx.notes))

    def test_unknown_file_is_refused(self):
        with self.assertRaises(BenchError):
            ingest("../newtab/surfaces.log")


if __name__ == "__main__":
    unittest.main()
