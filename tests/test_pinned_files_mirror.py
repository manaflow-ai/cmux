#!/usr/bin/env python3
"""pinned_files_mirror.py copies inputs.lock.json's pinned files to the edge by sha256 (RFD 0056 part 3).

lock.ts pinnedFetchCommand reads https://ci-cache-next.cmux.com/v1/any/pinned/<sha256>;
this pins the writer's key layout, which lock entries count as pinned, and the
workflow's trust.
"""

from __future__ import annotations

import json
import re
import sys
import unittest
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts" / "ci"))
import pinned_files_mirror as mirror  # noqa: E402
import r2_cache_prune as prune  # noqa: E402

DOC = yaml.safe_load((ROOT / ".github/workflows/pinned-files-mirror.yml").read_text())
TRIGGERS = DOC.get("on", DOC.get(True))
LOCK_TS = (ROOT / "web/scripts/cmux-vm-image/lock.ts").read_text()


class PinnedFilesMirror(unittest.TestCase):
    def test_walk_finds_nested_pinned_files_once(self) -> None:
        a, b = "a" * 64, "b" * 64
        lock = {
            "programs": [{"url": "https://x/a", "sha256": a, "size": 3}, {"url": "https://y/a", "sha256": a}],
            "tools": {"syft": {"url": "https://x/s", "sha256": b}},
            "apt": {"url": "https://x/c", "sha256": "notahash"},
            "plain": {"url": "http://insecure/d", "sha256": "c" * 64},
        }
        self.assertEqual(
            mirror.pinned_files(lock),
            [{"sha256": a, "url": "https://x/a", "size": 3}, {"sha256": b, "url": "https://x/s", "size": None}],
        )

    def test_real_lock_has_programs_and_syft(self) -> None:
        lock = json.loads(mirror.LOCK.read_text())
        shas = {entry["sha256"] for entry in mirror.pinned_files(lock)}
        self.assertIn(lock["tools"]["syft"]["sha256"], shas)
        for program in lock["programs"]:
            self.assertIn(program["sha256"], shas)

    def test_reader_and_writer_agree_on_the_key(self) -> None:
        sha = "d" * 64
        reader = re.search(r'export const PINNED_MIRROR = "([^"]+)"', LOCK_TS).group(1)
        self.assertEqual(f"{reader}/{sha}", mirror.edge_url(mirror.PUBLIC_URL, mirror.NAMESPACE, sha))
        self.assertEqual(mirror.object_path("cmux-ci-cache-next", "any", sha), f"cmux-ci-cache-next/v1/any/pinned/{sha}")

    def test_pruner_never_sees_pinned_keys(self) -> None:
        source = (ROOT / "scripts/ci/r2_cache_prune.py").read_text()
        self.assertNotIn("/pinned/", source)
        self.assertTrue(hasattr(prune, "main"))

    def test_workflow_writes_only_from_feat_cmux_next_with_no_token(self) -> None:
        self.assertEqual(DOC["permissions"], {})
        self.assertIn("images/cmux-vm/inputs.lock.json", TRIGGERS["push"]["paths"])
        self.assertEqual(TRIGGERS["push"]["branches"], ["feat-cmux-next"])
        job = DOC["jobs"]["mirror"]
        self.assertIn("github.repository == 'manaflow-ai/cmux'", job["if"])
        self.assertIn("refs/heads/feat-cmux-next", job["if"])
        self.assertEqual(job["permissions"], {"contents": "read"})
        checkout = job["steps"][0]
        self.assertFalse(checkout["with"]["persist-credentials"])
        self.assertEqual(DOC["env"]["CI_CACHE_R2_BUCKET"], "cmux-ci-cache-next")


if __name__ == "__main__":
    unittest.main()
