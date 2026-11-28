#!/usr/bin/env python3
"""scripts/ci/pattern_download_layout_hint.py: flags exactly the pattern downloads a lone match can flatten."""

from __future__ import annotations

import importlib.util
import io
import tempfile
import unittest
from contextlib import redirect_stdout
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location(
    "pattern_download_layout_hint", ROOT / "scripts" / "ci" / "pattern_download_layout_hint.py"
)
hint = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(hint)

WORKFLOW = """\
name: t
on: push
jobs:
  join:
    runs-on: ubuntu-latest
    steps:
      - name: Flattens when one shard matches
        uses: actions/download-artifact@v8
        with:
          pattern: shard-*
          path: shards
      - name: Merged is always flat
        uses: actions/download-artifact@v8
        with:
          pattern: dur-*
          path: dur
          merge-multiple: true
      # lone-artifact: four fixed artifacts, the job needs all of them
      - name: Reviewed
        uses: actions/download-artifact@v8
        with:
          pattern: parity-*
          path: signed
      - name: Exact name
        uses: actions/download-artifact@v8
        with:
          name: one
          path: one
      - name: Explicitly not merged
        uses: actions/download-artifact@v8
        with:
          pattern: verified-*
          path: verified
          merge-multiple: false
      - run: ls shards
"""


class PatternDownloadLayoutHint(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.dir = Path(self.tmp.name)
        (self.dir / "w.yml").write_text(WORKFLOW, encoding="utf-8")

    def tearDown(self) -> None:
        self.tmp.cleanup()

    def test_flags_only_unmerged_unreviewed_pattern_downloads(self) -> None:
        lines = [line for _, line in hint.findings(self.dir)]
        text = WORKFLOW.splitlines()
        self.assertEqual([text[n - 1].strip() for n in lines], [
            "- name: Flattens when one shard matches",
            "- name: Explicitly not merged",
        ])

    def test_hint_never_fails_and_annotates(self) -> None:
        buf = io.StringIO()
        with redirect_stdout(buf):
            rc = hint.main(["x", str(self.dir)])
        self.assertEqual(rc, 0)
        self.assertEqual(buf.getvalue().count("::warning file="), 2)
        self.assertIn("2 unreviewed", buf.getvalue())

    def test_repo_workflows_parse(self) -> None:
        # The real tree runs clean through the scanner; every finding points at a download step.
        wf = ROOT / ".github" / "workflows"
        for path, line in hint.findings(wf):
            block = path.read_text(encoding="utf-8").splitlines()[line - 1 : line + 12]
            self.assertTrue(any("download-artifact" in b for b in block), f"{path}:{line}")


if __name__ == "__main__":
    unittest.main()
