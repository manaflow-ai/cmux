#!/usr/bin/env python3
"""stability-lab.py signatures (p10-stability-195): a lane's artifacts become stability_issues.py findings.

    python3 -I scripts/cmux-next/tests/test_stability_lab_signatures.py
"""

from __future__ import annotations

import contextlib
import importlib.util
import io
import json
import shutil
import sys
import tempfile
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
FIXTURES = HERE / "fixtures" / "signature"
SCRIPT = HERE.parent / "stability-lab.py"


def load(name: str, path: Path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module  # dataclasses resolve annotations through sys.modules
    spec.loader.exec_module(module)
    return module


lab = load("stability_lab", SCRIPT)
issues = load("stability_issues", HERE.parent / "stability_issues.py")


class LaneArtifacts(unittest.TestCase):
    def setUp(self):
        self.root = Path(tempfile.mkdtemp(prefix="stability-lab-sig-"))
        self.addCleanup(shutil.rmtree, self.root)
        (self.root / "owner").mkdir()
        (self.root / "journal").mkdir()
        shutil.copy(FIXTURES / "trap-build-a.ips", self.root / "cmux-NEXT-2026-10-26.ips")
        shutil.copy(FIXTURES / "rust-hangs-build-a.jsonl", self.root / "owner" / "owner-hangs-main.jsonl")
        shutil.copy(FIXTURES / "slow-polls.jsonl", self.root / "owner" / "hangs.jsonl")
        shutil.copy(FIXTURES / "bad-messages.log", self.root / "app-stderr.log")
        shutil.copy(FIXTURES / "error-journal-segment.ndjson", self.root / "journal" / "segment-3.ndjson")
        shutil.copy(FIXTURES / "invariant-events.jsonl", self.root / "invariant-sink.jsonl")
        (self.root / "screenshot.png").write_bytes(b"\x89PNG\r\n\x1a\n" + b"bad message: line_too_long")
        (self.root / "lane-result.json").write_text('{"message": "lane passed", "status": "ok"}\n', encoding="utf-8")

    def test_findings_cover_crashes_and_every_non_crash_kind(self):
        findings = lab.lane_findings([self.root], lane="smoke", major="26", sha="a" * 40)
        kinds = {finding["kind"] for finding in findings}
        self.assertEqual(kinds, {"crash", "rust-hang", "slow-poll", "rust-blocking", "bad-message", "invariant",
                                 "page-js-error", "error-fault"})
        by_source = {finding["source"] for finding in findings}
        self.assertIn("owner/owner-hangs-main.jsonl", by_source)
        self.assertIn("journal/segment-3.ndjson", by_source)
        self.assertNotIn("screenshot.png", by_source)
        self.assertNotIn("lane-result.json", by_source)
        for finding in findings:
            self.assertEqual((finding["lane"], finding["major"], finding["sha"]), ("smoke", "26", "a" * 40))

    def test_findings_are_a_valid_run_for_stability_issues(self):
        findings = lab.lane_findings([self.root], lane="smoke", major="26")
        run = {"schema": issues.RUN_SCHEMA, "run": "tick-1", "tip": "b" * 40,
               "lanes": [{"lane": "smoke", "major": "26"}], "findings": findings}
        issues.validate_run(run)
        tracked, _ = issues.plan_sync([], run, lambda fix, sha: None)
        # One issue per distinct bug: the slow-poll site found twice, the line_too_long close found twice and
        # the invariant from two lines are one issue each.
        self.assertEqual(len(tracked), len({finding["hash12"] for finding in findings}))
        self.assertLess(len(tracked), len(findings))

    def test_a_journal_entry_in_two_segments_is_one_finding_from_the_newer(self):
        # ErrorSegmentStore keeps appending to the newest segment; an older one can still hold a stale snapshot.
        newer = json.dumps({"count": 9, "fp": "3a1b2c3d4e5f6071", "level": "fault", "source": "app",
                            "sample": "session journal write failed at offset 8192",
                            "template": "session journal write failed at offset <n>"})
        (self.root / "journal" / "segment-10.ndjson").write_text(newer + "\n", encoding="utf-8")
        faults = [finding for finding in lab.lane_findings([self.root]) if finding["kind"] == "error-fault"]
        self.assertEqual([(finding["source"], finding["journal_count"]) for finding in faults],
                         [("journal/segment-10.ndjson", 9)])

    def test_the_same_artifacts_give_the_same_hashes(self):
        first = [finding["hash12"] for finding in lab.lane_findings([self.root])]
        again = [finding["hash12"] for finding in lab.lane_findings([self.root])]
        self.assertEqual(first, again)

    def test_cli_prints_one_finding_a_line_and_writes_json_out(self):
        out_path = self.root / "out" / "findings.json"
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            status = lab.main(["signatures", str(self.root / "app-stderr.log"), "--lane", "chaos",
                               "--json-out", str(out_path)])
        self.assertEqual(status, 0)
        lines = [json.loads(line) for line in out.getvalue().splitlines()]
        self.assertEqual([line["kind"] for line in lines], ["bad-message"] * 6)
        self.assertEqual({line["source"] for line in lines}, {"app-stderr.log"})
        self.assertEqual(json.loads(out_path.read_text(encoding="utf-8"))["findings"], lines)

    def test_missing_directory_is_a_lab_error(self):
        err = io.StringIO()
        with contextlib.redirect_stderr(err):
            status = lab.main(["signatures", str(self.root / "nope")])
        self.assertEqual(status, 2)
        self.assertIn("artifact directory not found", err.getvalue())


if __name__ == "__main__":
    unittest.main()
