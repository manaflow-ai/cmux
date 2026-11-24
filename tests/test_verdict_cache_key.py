#!/usr/bin/env python3
"""scripts/ci/verdict_cache_key.py: the key changes with every input the check reads and nothing else."""

from __future__ import annotations

import contextlib
import importlib.util
import io
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("verdict_cache_key", ROOT / "scripts" / "ci" / "verdict_cache_key.py")
assert spec and spec.loader
vck = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = vck
spec.loader.exec_module(vck)

HEAD = "a" * 40
INPUTS = ["scripts/ci/language_boundaries.py", ".github/language-boundaries.toml"]


def key(root: Path, *extra: str, head: str = HEAD) -> str:
    out = io.StringIO()
    with contextlib.redirect_stdout(out), contextlib.redirect_stderr(io.StringIO()):
        vck.main(["--check", "language-boundaries", "--head", head, "--inputs", *INPUTS,
                  "--approval-labels", "leo-approved-port,react-port-ok", *extra], root=root)
    return out.getvalue().strip().removeprefix("key=")


class KeyTests(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        for rel in INPUTS:
            (self.root / rel).parent.mkdir(parents=True, exist_ok=True)
            (self.root / rel).write_text(f"{rel}\n", encoding="utf-8")

    def tearDown(self) -> None:
        self.tmp.cleanup()

    def test_blob_id_is_gits(self) -> None:
        path = self.root / INPUTS[0]
        want = subprocess.check_output(["git", "hash-object", str(path)], text=True).strip()
        self.assertEqual(vck.blob_id(path.read_bytes()), want)

    def test_same_inputs_same_key(self) -> None:
        first = key(self.root)
        self.assertRegex(first, r"^[0-9a-f]{64}$")
        self.assertEqual(first, key(self.root))
        # A label the check does not read changes nothing.
        self.assertEqual(first, key(self.root, "--labels-json", '["ci-fast", "media-tour"]'))

    def test_each_input_changes_the_key(self) -> None:
        first = key(self.root)
        self.assertNotEqual(first, key(self.root, head="b" * 40))
        (self.root / INPUTS[1]).write_text("changed\n", encoding="utf-8")
        second = key(self.root)
        self.assertNotEqual(first, second)
        (self.root / INPUTS[1]).unlink()  # an absent input keys as null, not as the old bytes
        self.assertNotIn(key(self.root), (first, second, ""))

    def test_python_version_is_in_the_key(self) -> None:
        ids = vck.input_ids(self.root, INPUTS)
        self.assertNotEqual(vck.verdict_key("language-boundaries", HEAD, ids, "3.12.0"),
                            vck.verdict_key("language-boundaries", HEAD, ids, "3.13.0"))

    def test_approval_label_means_no_key(self) -> None:
        self.assertEqual(key(self.root, "--labels-json", '["leo-approved-port"]'), "")
        self.assertEqual(key(self.root, "--labels-json", '["react-port-ok"]'), "")

    def test_bad_head_means_no_key(self) -> None:
        self.assertEqual(key(self.root, head="main"), "")

    def test_output_file(self) -> None:
        out = self.root / "out"
        key(self.root, "--output", str(out))
        self.assertRegex(out.read_text(encoding="utf-8"), r"^key=[0-9a-f]{64}\n$")


class WorkflowTests(unittest.TestCase):
    def test_workflow_replays_and_stores_under_one_key(self) -> None:
        text = (ROOT / ".github" / "workflows" / "language-boundaries.yml").read_text(encoding="utf-8")
        self.assertIn("scripts/ci/verdict_cache_key.py", text)
        self.assertIn("vars.CI_INPUT_RECEIPT_SKIP != 'off'", text)
        self.assertEqual(text.count("key: language-boundaries-verdict-v1-${{ steps.key.outputs.key }}"), 2)


if __name__ == "__main__":
    unittest.main()
