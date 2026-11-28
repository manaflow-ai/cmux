#!/usr/bin/env python3
"""Byte ceilings preserve window denominators and compaction boundaries."""
import importlib.util
import json
from pathlib import Path
import tempfile
from types import SimpleNamespace
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / "scripts/measure/hook-context-dedup-bound.py"
spec = importlib.util.spec_from_file_location("bound", SCRIPT)
bound = importlib.util.module_from_spec(spec)
spec.loader.exec_module(bound)
METER = SimpleNamespace(COMPACT_MARK='"compact_boundary"',
                        is_prompt=lambda e: e.get("type") == "user" and not e.get("isSidechain"),
                        entry_time=lambda e: e.get("timestamp"),
                        blocks=lambda text: [("test", text)] if text else [])


def prompt(at):
    return {"type": "user", "timestamp": at}


def context(text, at=0, **extra):
    return {"timestamp": at, "attachment": {"type": "hook_additional_context", "content": text}, **extra}


class BoundTests(unittest.TestCase):
    def report(self, entries, since=10):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "fixture.jsonl"
            path.write_text("".join(json.dumps(e) + "\n" for e in entries))
            return bound.summarize(bound.count_file(path, METER, since))

    def test_prefix_primes_both_scopes_without_counting_old_turn(self):
        result = self.report([prompt(1), context("old"), prompt(10), context("old")])
        self.assertEqual(result["turns"], 1)
        self.assertEqual(result["total_bytes"], 3)
        self.assertEqual(result["epoch"]["duplicate_bytes"], 3)

    def test_compaction_resets_epoch_but_not_session(self):
        result = self.report([prompt(1), context("same"), {"type": "compact_boundary"},
                              prompt(10), context("same"), context("changed")])
        self.assertEqual(result["epoch"]["duplicate_bytes"], 0)
        self.assertEqual(result["session"]["duplicate_bytes"], 4)
        self.assertEqual(result["session"]["optimistic_mean_bytes_per_turn"], 7)

    def test_startup_context_belongs_to_first_prompt_and_counts_utf8(self):
        result = self.report([context("é", 1), prompt(10), context("é")])
        self.assertEqual(result["turns"], 1)
        self.assertEqual(result["total_bytes"], 4)
        self.assertEqual(result["session"]["duplicate_bytes"], 2)

    def test_empty_turn_counts_sidechain_does_not_prime_seen(self):
        result = self.report([prompt(10), context("x", isSidechain=True), prompt(11), context("x")])
        self.assertEqual(result["turns"], 2)
        self.assertEqual(result["total_bytes"], 1)
        self.assertEqual(result["session"]["duplicate_bytes"], 0)

    def test_no_turn_has_no_invented_mean(self):
        self.assertIsNone(self.report([])["mean_bytes_per_turn"])

    def test_receipt_validation_rejects_tampered_transcript(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            tools = root / "workspace/tools"
            tools.mkdir(parents=True)
            meter = tools / "hook_context_bytes.py"
            meter.write_text('COMPACT_MARK = \'"compact_boundary"\'\n'
                             'def is_prompt(e): return e.get("type") == "user"\n'
                             'def entry_time(e): return e.get("timestamp")\n'
                             'def blocks(text): return [("test", text)]\n')
            snapshot = root / "snapshot"
            (snapshot / "transcripts").mkdir(parents=True)
            data = "".join(json.dumps(e) + "\n" for e in [prompt(10), context("same"), context("same")]).encode()
            transcript = snapshot / "transcripts/opaque.jsonl"
            transcript.write_bytes(data)
            manifest = json.dumps([{"file": "opaque.jsonl", "selected": True,
                                    "bytes": len(data), "sha256": bound.digest(data)}]).encode()
            (snapshot / "manifest.json").write_bytes(manifest)
            receipt = {"schema": "hook-context-window/v1", "manifest_sha256": bound.digest(manifest),
                       "meter_sha256": bound.digest(meter.read_bytes()), "window_start": 10, "window_end": 20,
                       "reports": {"recorded": {"turns": 1, "total_bytes": 8, "repeat_bytes": 4}}}
            (snapshot / "receipt.json").write_text(json.dumps(receipt))
            result = bound.measure(snapshot, root / "workspace")
            self.assertEqual(result["session"]["duplicate_bytes"], 4)
            self.assertFalse(result["conservation_claim"])
            transcript.write_bytes(data + b"{}\n")
            with self.assertRaisesRegex(ValueError, "transcript hash mismatch"):
                bound.measure(snapshot, root / "workspace")


if __name__ == "__main__":
    unittest.main()
