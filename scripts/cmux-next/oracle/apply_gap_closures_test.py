#!/usr/bin/env python3
"""Tests for apply_gap_closures.py (p15-oracle-087).

Run: python3 -I scripts/cmux-next/oracle/apply_gap_closures_test.py (stdlib unittest, no app, Linux too).
"""

from __future__ import annotations

import io
import json
import sys
import tempfile
import unittest
from contextlib import redirect_stderr, redirect_stdout
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

import apply_gap_closures as gc  # noqa: E402

BASELINE = {"_doc": "d", "excluded": {"quit": "ends or restarts the app"},
            "gaps": {"a.one": "needs context x", "a.two": "needs context x", "b.one": "needs a y argument",
                     "c.one": "unavailable here"}}
CATALOG = frozenset({"quit", "a.one", "a.two", "b.one", "c.one"})


def record(family, closed=None, reasoned=None):
    return gc.Record(Path(f"{family}.json"), family, closed or {}, reasoned or {})


class ApplyTests(unittest.TestCase):
    def test_closed_ids_leave_and_reasoned_ids_get_their_reason(self):
        applied = gc.apply(BASELINE, [record("a", {"a.one": "fixture", "a.two": "fixture"}),
                                      record("misc", reasoned={"c.one": "why it stays"})], CATALOG, frozenset({"a"}))
        self.assertEqual(applied.baseline["gaps"], {"b.one": "needs a y argument", "c.one": "why it stays"})
        self.assertEqual(applied.baseline["excluded"], BASELINE["excluded"])
        self.assertEqual((applied.dropped, applied.reasons), (("a.one", "a.two"), ("c.one",)))
        self.assertEqual(BASELINE["gaps"]["a.one"], "needs context x")  # the input is not changed

    def test_applying_twice_changes_nothing(self):
        records = [record("a", {"a.one": "f"}), record("misc", reasoned={"c.one": "why"})]
        once = gc.apply(BASELINE, records, CATALOG)
        twice = gc.apply(once.baseline, records, CATALOG)
        self.assertFalse(twice.changed)
        self.assertEqual(twice.baseline, once.baseline)

    def test_conflicts_are_refused(self):
        cases = {
            "is also in": [record("a", {"a.one": "f"}), record("b", {"a.one": "g"})],
            "not an action of the catalog": [record("a", {"a.gone": "f"})],
            "reviewed `excluded` list": [record("a", {"quit": "f"})],
            "the record is stale": [record("misc", reasoned={"a.gone.from.gaps": "why"})],
            "no fixture in oracle/action_fixtures": [record("z", {"a.one": "f"})],
        }
        catalog = CATALOG | {"a.gone.from.gaps"}
        for words, records in cases.items():
            with self.subTest(words=words), self.assertRaises(gc.ClosureError) as raised:
                gc.apply(BASELINE, records, catalog, frozenset({"a", "b"}))
            self.assertIn(words, str(raised.exception))

    def test_a_record_with_only_reasons_needs_no_fixture(self):
        applied = gc.apply(BASELINE, [record("notes", reasoned={"b.one": "why"})], CATALOG, frozenset())
        self.assertEqual(applied.baseline["gaps"]["b.one"], "why")


class RecordTests(unittest.TestCase):
    def write(self, directory, name, body):
        (directory / name).write_text(json.dumps(body))

    def test_a_record_is_checked_for_its_shape(self):
        bad = {"x.json": {"family": "y", "closed": {}},
               "a.json": {"family": "a"},
               "b.json": {"family": "b", "closed": {"id": ""}},
               "c.json": {"family": "c", "closed": {}, "reasoned": ["id"]}}
        for name, body in bad.items():
            with self.subTest(name=name), tempfile.TemporaryDirectory() as tmp:
                self.write(Path(tmp), name, body)
                with self.assertRaises(gc.ClosureError):
                    gc.load_records(Path(tmp))


class CheckedInTests(unittest.TestCase):
    def test_the_baseline_is_every_record_applied(self):
        # Every gap-closures record is applied: the checked-in baseline is a fixed point, written as the sweep writes.
        with redirect_stdout(io.StringIO()), redirect_stderr(io.StringIO()):
            self.assertEqual(gc.main(["--check"]), 0)
        self.assertEqual(gc.dump(json.loads(gc.GAPS.read_text())), gc.GAPS.read_text())

    def test_at_most_20_gaps_remain_each_with_a_reason(self):
        # p15-oracle-087's acceptance with every gap-closures record in the tree applied: <= 20 gaps, each with its
        # reason. A record that lands later can only close or reason gaps, so this stays on.
        gaps = json.loads(gc.GAPS.read_text())["gaps"]
        self.assertLessEqual(len(gaps), 20, sorted(gaps))
        self.assertEqual([i for i, why in gaps.items() if not why.strip()], [])


if __name__ == "__main__":
    unittest.main()
