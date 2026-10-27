#!/usr/bin/env python3
"""Offline tests of gen_pane_protocol.py (p15-oracle-213): no build, no runner.

Run: python3 -I scripts/cmux-next/oracle/gen_pane_protocol_test.py
The runners themselves: `cargo run -p cmux-pane-protocol --example conformance` (cmux-tui/),
`bun scripts/pane-protocol-conformance.ts` (webviews/), `PaneProtocolConformanceTests` (fleet).
"""

from __future__ import annotations

import json
import sys
import tempfile
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
if str(HERE) not in sys.path:
    sys.path.insert(0, str(HERE))

import gen_pane_protocol as gen  # noqa: E402


class GenPaneProtocolTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.files = gen.build(gen.REPO)

    def cases(self, category: str):
        return self.files[f"_{category}.json"]["cases"]

    def test_committed_corpus_is_current(self) -> None:
        for name, value in self.files.items():
            path = gen.DEFAULT_OUT / name
            self.assertTrue(path.is_file(), f"{path} is missing: run {gen.GENERATOR}")
            self.assertEqual(path.read_text(encoding="utf-8"), gen.render(value), f"{name} is stale: run {gen.GENERATOR}")

    def test_check_mode_reports_a_stale_file(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            out = Path(tmp)
            self.assertEqual(gen.main(["--out", str(out)]), 0)
            self.assertEqual(gen.main(["--out", str(out), "--check"]), 0)
            (out / "_credit.json").write_text("{}\n", encoding="utf-8")
            self.assertEqual(gen.main(["--out", str(out), "--check"]), 1)
            self.assertEqual((out / "_credit.json").read_text(encoding="utf-8"), "{}\n", "--check writes nothing")

    def test_every_case_has_a_verdict_and_a_category_prefix(self) -> None:
        for category in gen.CATEGORIES:
            for case in self.cases(category):
                self.assertTrue(case["id"].startswith(f"{category}/"), case["id"])
                if category != "credit":
                    self.assertIsInstance(case["verdict"], str, case["id"])

    def test_every_valid_envelope_case_names_its_kind(self) -> None:
        for case in self.cases("envelopes"):
            if case["verdict"] == "valid":
                self.assertIsInstance(case["kind"], str, case["id"])
            if "encoded" in case:
                self.assertEqual(json.loads(case["encoded"])["t"], case["kind"], case["id"])

    def test_sender_sequences_send_what_the_credit_allows(self) -> None:
        for case in self.cases("credit"):
            if case["role"] != "sender":
                continue
            written = credit = 0
            for step in case["steps"]:
                written += step.get("write", 0)
                credit += step.get("credit", 0) + step.get("frame_credit", 0)
                self.assertEqual(step["sent"], min(written, credit), case["id"])

    def test_receiver_sequences_refuse_exactly_the_bytes_over_the_window(self) -> None:
        for case in self.cases("credit"):
            if case["role"] != "receiver":
                continue
            received = 0
            for step in case["steps"]:
                received += step["receive"]
                over = received > case["window"]
                self.assertEqual(step["verdict"], gen.CREDIT_EXCEEDED if over else "ok", case["id"])

    def test_coverage_counts_every_implementation_and_category(self) -> None:
        coverage = self.files["coverage.json"]
        self.assertEqual(coverage["total"], len(gen.IMPLEMENTATIONS) * len(gen.CATEGORIES))
        self.assertEqual(coverage["covered"] + len(coverage["excluded"]), coverage["total"])
        self.assertTrue(all(coverage["excluded"].values()), "every exclusion has a reason")

    def test_a_divergence_naming_no_case_is_an_error(self) -> None:
        saved = gen.DIVERGENCES["ts"]
        gen.DIVERGENCES["ts"] = {"envelopes/no-such-case": {"bug": "p15-oracle-213", "reason": "x"}}
        try:
            with self.assertRaises(gen.GenError):
                gen.build(gen.REPO)
        finally:
            gen.DIVERGENCES["ts"] = saved

    def test_a_violation_before_the_last_receive_is_an_error(self) -> None:
        saved = list(gen.RECEIVER_SEQUENCES)
        gen.RECEIVER_SEQUENCES.append({"name": "bad", "window": 0, "steps": [
            {"receive": 1, "verdict": gen.CREDIT_EXCEEDED}, {"receive": 0, "verdict": "ok"}]})
        try:
            with self.assertRaises(gen.GenError):
                gen.credit_cases()
        finally:
            gen.RECEIVER_SEQUENCES[:] = saved


if __name__ == "__main__":
    unittest.main()
