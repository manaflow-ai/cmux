#!/usr/bin/env python3
"""Synthetic fixed-window measurement tests; no private transcripts or network."""
import importlib.util
import json
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts/measure/hook-context-window.py"
spec = importlib.util.spec_from_file_location("window", SCRIPT)
window = importlib.util.module_from_spec(spec)
spec.loader.exec_module(window)


def row(second=None, **extra):
    if second is not None:
        extra["timestamp"] = "2026-11-27T00:00:%02dZ" % second
    return (json.dumps(extra) + "\n").encode()


class WindowTests(unittest.TestCase):
    start = window.timestamp("2026-11-27T00:00:10Z")
    end = window.timestamp("2026-11-27T00:00:20Z")

    def freeze(self, data):
        return window.freeze(data, self.start, self.end)

    def test_prefix_and_inclusive_upper_boundary(self):
        prefix = row(1, type="user")
        body = row(10) + row(20)
        frozen, selected, counts = self.freeze(prefix + body + row(21))
        self.assertEqual(frozen, prefix + body)
        self.assertTrue(selected)
        self.assertEqual(counts["excluded_future_records"], 1)

    def test_out_of_order_window_record_survives_future_record(self):
        frozen, selected, counts = self.freeze(row(1) + row(30) + row(15))
        self.assertEqual(frozen, row(1) + row(15))
        self.assertTrue(selected)
        self.assertEqual(counts["out_of_order_records"], 1)

    def test_untimed_compaction_has_explicit_boundary_policy(self):
        compact = row(type="compact_boundary")
        data = compact + row(1) + compact + row(15) + row(30) + compact + row(16) + compact
        frozen, _, counts = self.freeze(data)
        self.assertEqual(frozen, compact + row(1) + compact + row(15) + row(16))
        self.assertEqual(counts["omitted_untimed_compactions"], 2)

    def test_future_appends_do_not_change_selected_bytes(self):
        original = row(1) + row(15) + row(type="compact_boundary")
        self.assertEqual(self.freeze(original)[0], self.freeze(original + row(30) + row(40))[0])

    def test_malformed_diagnostics_contain_no_payload(self):
        data = b'SECRET\n' + b'[]\n' + row(timestamp="not-a-time") + b'{"secret":"partial"'
        frozen, _, counts = self.freeze(data)
        self.assertEqual(frozen, b"")
        self.assertEqual(counts["malformed_json"], 1)
        self.assertEqual(counts["non_object_records"], 1)
        self.assertEqual(counts["malformed_timestamps"], 1)
        self.assertEqual(counts["incomplete_records"], 1)
        self.assertNotIn("SECRET", json.dumps(counts))

    def test_naive_timestamps_refused(self):
        with self.assertRaises(ValueError):
            window.timestamp("2026-11-27T00:00:10")

    def test_receipt_hashes_reports_and_overwrite_refusal(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            workspace = root / "workspace"
            tools = workspace / "tools"
            tools.mkdir(parents=True)
            meter = tools / "hook_context_bytes.py"
            meter.write_text('def report(files, after=False, since=None):\n'
                             '    return {"after": after, "since": since, "files": len(files)}\n')
            subprocess.run(["git", "init", "-q", str(workspace)], check=True)
            subprocess.run(["git", "-C", str(workspace), "add", "."], check=True)
            subprocess.run(["git", "-C", str(workspace), "-c", "core.hooksPath=/dev/null",
                            "-c", "user.name=Test", "-c", "user.email=test@example.invalid",
                            "commit", "-qm", "fixture"], check=True)
            transcripts = root / "input"
            transcripts.mkdir()
            source = transcripts / "private-session.jsonl"
            source.write_bytes(row(1) + row(15))
            output = root / "frozen"
            receipt, code = window.measure(workspace, transcripts, output, self.end, 10 / 3600)
            self.assertEqual(code, 0)
            self.assertEqual(receipt["meter_sha256"], window.sha256(meter.read_bytes()))
            self.assertEqual(receipt["manifest_sha256"], window.sha256((output / "manifest.json").read_bytes()))
            self.assertFalse(receipt["reports"]["recorded"]["after"])
            self.assertTrue(receipt["reports"]["replay"]["after"])
            self.assertEqual(receipt["reports"]["replay"]["since"], self.start)
            self.assertFalse(receipt["conservation_claim"])
            self.assertNotIn("private-session", (output / "manifest.json").read_text())
            original = (output / "receipt.json").read_bytes()
            source.write_bytes(source.read_bytes() + row(30))
            with self.assertRaises(FileExistsError):
                window.measure(workspace, transcripts, output, self.end, 10 / 3600)
            self.assertEqual(original, (output / "receipt.json").read_bytes())
            self.assertEqual(output.stat().st_mode & 0o777, 0o700)


if __name__ == "__main__":
    unittest.main()
