#!/usr/bin/env python3
"""scripts/ci/ios_placeholder_bounds.py on fixture trees, then on this checkout.

The fixture cases are the ones the check exists for (Leo, 2026-11-24: "wer need to chase all these
placeholders doen and prevent them"): an unbounded stand-in, a bound the inventory does not know, a
bound past the cap, a stale inventory entry. The last case runs the check on the real tree: on the
base before ios-placeholder-bounds it fails (no inventory, no bounds).
"""
from __future__ import annotations

import json
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts" / "ci"))
import ios_placeholder_bounds as bounds  # noqa: E402

PATTERNS = [{"name": "prohibited-sign stand-in", "regex": r'systemName:\s*"nosign"'}]


def tree(files: dict[str, str], placeholders: list[dict], exempt: list[dict] | None = None, cap: int = 2000) -> Path:
    root = Path(tempfile.mkdtemp())
    for rel, text in files.items():
        path = root / rel
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text)
    inv = root / bounds.INVENTORY
    inv.parent.mkdir(parents=True, exist_ok=True)
    inv.write_text(json.dumps({"patterns": PATTERNS, "placeholders": placeholders, "exempt": exempt or [], "max_bound_ms": cap}))
    return root


VIEW = "cmux-next-ios/CmuxMobileKit/Sources/CmuxMobileWorkspaces/Card.swift"


class PlaceholderBoundsTests(unittest.TestCase):
    def test_unbounded_stand_in_fails(self):
        root = tree({VIEW: 'Image(systemName: "nosign")\n'}, [])
        problems = bounds.check(root)
        self.assertEqual(len(problems), 1)
        self.assertIn("Card.swift:1: prohibited-sign stand-in with no .placeholderBound", problems[0])

    def test_bounded_and_listed_passes(self):
        src = 'Image(systemName: "nosign")\n    .placeholderBound("tabgrid.card", .milliseconds(800))\n'
        root = tree({VIEW: src}, [{"id": "tabgrid.card", "file": VIEW, "bound_ms": 800}])
        self.assertEqual(bounds.check(root), [])

    def test_seconds_bound_reads_as_ms(self):
        src = 'Image(systemName: "nosign")\n    .placeholderBound("tabgrid.card", .seconds(1))\n'
        root = tree({VIEW: src}, [{"id": "tabgrid.card", "file": VIEW, "bound_ms": 1000}])
        self.assertEqual(bounds.check(root), [])

    def test_unlisted_id_and_wrong_bound_fail(self):
        src = 'X().placeholderBound("a", .milliseconds(500))\nY().placeholderBound("b", .milliseconds(900))\n'
        root = tree({VIEW: src}, [{"id": "b", "file": VIEW, "bound_ms": 800}])
        problems = "\n".join(bounds.check(root))
        self.assertIn("'a' is not in", problems)
        self.assertIn("'b' bound 900 ms, inventory says 800 ms", problems)

    def test_bound_past_cap_fails(self):
        src = 'X().placeholderBound("slow", .seconds(30))\n'
        root = tree({VIEW: src}, [{"id": "slow", "file": VIEW, "bound_ms": 30000}])
        problems = "\n".join(bounds.check(root))
        self.assertIn("past max_bound_ms 2000", problems)

    def test_stale_inventory_entry_fails(self):
        root = tree({VIEW: "Text(title)\n"}, [{"id": "gone", "file": VIEW, "bound_ms": 500}])
        self.assertIn("gone", "\n".join(bounds.check(root)))

    def test_exempt_line_and_comments_pass(self):
        src = '// Image(systemName: "nosign") was the old stand-in\nLabel("Blocked", systemImage: "nosign")\n'
        exempt = [{"file": VIEW, "text": 'Label("Blocked", systemImage: "nosign")', "reason": "a real blocked state"}]
        root = tree({VIEW: src}, [], exempt)
        self.assertEqual(bounds.check(root), [])

    def test_tests_are_not_scanned(self):
        root = tree({"cmux-next-ios/CmuxMobileKit/Tests/X/T.swift": 'Image(systemName: "nosign")\n'}, [])
        self.assertEqual(bounds.check(root), [])

    def test_missing_inventory_fails(self):
        root = Path(tempfile.mkdtemp())
        self.assertIn("missing", bounds.check(root)[0])

    def test_this_checkout_passes(self):
        problems = bounds.check(ROOT)
        self.assertEqual(problems, [], "\n".join(problems))


if __name__ == "__main__":
    unittest.main()
