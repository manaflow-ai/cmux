"""tests/nightly_workflow_text.py writes every reused step out in full, and the copy must stay valid YAML.

A copy keeps one anchor per name: a nested `key: &name` anchor (#42267) and a scalar `key: &name value`
anchor (the Chromium engine fetch's `&r2a ${{ secrets... }}`, #45938) are both dropped from the copy. A
scalar anchor that stayed made the expansion's YAML fail ("found duplicate anchor 'r2a'") and with it
ci-guards' "Validate universal nightly workflow" on every feat-cmux-next push from 2026-11-17.
"""
from __future__ import annotations

import sys
import unittest
from pathlib import Path

import yaml

sys.path.insert(0, str(Path(__file__).resolve().parent))
import nightly_workflow_text  # noqa: E402

FIXTURE = """\
jobs:
  a:
    steps:
      - &fetch
        name: Fetch
        env: &lease
          ACCOUNT: &acct ${{ secrets.ACCOUNT }}
          KEY: *acct
        run: echo fetch
  b:
    steps:
      - *fetch
      - name: Reuse
        env:
          ACCOUNT: *acct
          LEASE: x
"""


class WrittenOutAnchors(unittest.TestCase):
    def test_a_written_out_step_drops_scalar_and_nested_anchors(self) -> None:
        text = nightly_workflow_text.write_out_step_aliases(FIXTURE)
        data = yaml.safe_load(text)
        self.assertEqual(text.count("&acct"), 1, text)
        self.assertEqual(text.count("&lease"), 1, text)
        self.assertEqual([s["name"] for s in data["jobs"]["b"]["steps"]], ["Fetch", "Reuse"])
        self.assertEqual(data["jobs"]["b"]["steps"][0]["env"]["ACCOUNT"], "${{ secrets.ACCOUNT }}")
        self.assertEqual(data["jobs"]["b"]["steps"][1]["env"]["ACCOUNT"], "${{ secrets.ACCOUNT }}")

    def test_the_real_expansion_is_valid_yaml(self) -> None:
        yaml.safe_load(nightly_workflow_text.write_out_step_aliases(nightly_workflow_text.nightly_text()))


if __name__ == "__main__":
    unittest.main()
