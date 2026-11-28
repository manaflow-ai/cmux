#!/usr/bin/env python3
"""A pool cargo leg looks up the workspace delta of the dependency entry it actually restored.

The R2 dependency entry is keyed by the Cargo.lock/toolchain inputs and restored by prefix, so a leg
whose own inputs have no entry (a PR that changed a lock, feat-cmux-next before its push saved one)
restores another inputs' entry. The workspace delta was looked up only under the leg's own inputs,
which then has no delta either: "cargo delta: miss" and every workspace crate compiled (machine
channel PR builds, 12-16 min of cargo instead of about 2; job 140359967645).

This pins:
- scripts/ci/cargo-delta-prefix.sh maps the matched key to the delta prefix of its inputs, and to
  nothing for a miss, a foreign key or a malformed suffix;
- every workflow step that applies a delta (cargo-target-delta.sh apply) restores it with the
  matched-entry prefix first and its own inputs' prefix second, from a step keyed on
  r2-cargo-target's cache-matched-key (the detector for this class: a new caller fails here).

Run: python3 tests/test_ci_cargo_delta_matched_entry.py
Why: docs/ci/cmux-next-workflow-notes/2026-11-27-cargo-delta-matched-entry.md
"""

from __future__ import annotations

import subprocess
import unittest
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts/ci/cargo-delta-prefix.sh"
WORKFLOWS = ROOT / ".github/workflows"
TARGET_PREFIX = "cmux-tui-cargo-v1-x86_64-unknown-linux-musl-thin-1a2b3c4d-"
BASE = "cmux-tui-cargo-ws-v1-x86_64-unknown-linux-musl-thin-1a2b3c4d-"


def prefix(*args: str) -> str:
    out = subprocess.run(["bash", str(SCRIPT), *args], check=True, capture_output=True, text=True).stdout
    lines = out.splitlines()
    assert len(lines) == 1 and lines[0].startswith("prefix="), out
    return lines[0].removeprefix("prefix=")


def delta_steps() -> list[tuple[str, str, list[dict]]]:
    """(workflow, job, steps) for every job with a step running cargo-target-delta.sh apply."""
    found = []
    for path in sorted(WORKFLOWS.glob("*.y*ml")):
        doc = yaml.safe_load(path.read_text()) or {}
        for name, job in (doc.get("jobs") or {}).items():
            steps = (job or {}).get("steps") or []
            if any("cargo-target-delta.sh apply" in str(s.get("run", "")) for s in steps):
                found.append((path.name, name, steps))
    return found


class ScriptTest(unittest.TestCase):
    def test_exact_hit_gives_its_own_inputs(self) -> None:
        self.assertEqual(prefix(TARGET_PREFIX + "0123456789abcdef", TARGET_PREFIX, BASE), BASE + "0123456789abcdef-")

    def test_prefix_match_gives_the_restored_entrys_inputs(self) -> None:
        self.assertEqual(prefix(TARGET_PREFIX + "fedcba9876543210", TARGET_PREFIX, BASE), BASE + "fedcba9876543210-")

    def test_miss_gives_nothing(self) -> None:
        self.assertEqual(prefix("", TARGET_PREFIX, BASE), "")
        self.assertEqual(prefix(), "")

    def test_foreign_or_malformed_key_gives_nothing(self) -> None:
        self.assertEqual(prefix("cmux-tui-cargo-v1-other-0123456789abcdef", TARGET_PREFIX, BASE), "")
        self.assertEqual(prefix(TARGET_PREFIX + "0123456789abcdef-x", TARGET_PREFIX, BASE), "")
        self.assertEqual(prefix(TARGET_PREFIX + "0123456789abcdef", TARGET_PREFIX, ""), "")


class WorkflowTest(unittest.TestCase):
    def test_every_delta_caller_is_found(self) -> None:
        names = {(w, j) for w, j, _ in delta_steps()}
        self.assertIn("cmux-tui-build-package.yml", {w for w, _ in names})
        self.assertIn("cmux-next.yml", {w for w, _ in names})

    def test_every_delta_restore_tries_the_matched_entry_first(self) -> None:
        for workflow, job, steps in delta_steps():
            with self.subTest(workflow=workflow, job=job):
                ids = [s.get("id") for s in steps]
                self.assertIn("r2-cargo-ws-base", ids, "no step keys the delta to the restored entry")
                base = steps[ids.index("r2-cargo-ws-base")]
                self.assertLess(ids.index("r2-cargo-target"), ids.index("r2-cargo-ws-base"))
                self.assertIn("cargo-delta-prefix.sh", base["run"])
                self.assertIn("steps.r2-cargo-target.outputs.cache-matched-key", base["env"]["MATCHED"])
                self.assertIn("steps.r2-cargo-key.outputs.target-prefix", base["env"]["TARGET_PREFIX"])
                self.assertIn("steps.r2-cargo-key.outputs.ws-base", base["env"]["WS_BASE"])
                restore = steps[ids.index("r2-cargo-ws")]
                self.assertLess(ids.index("r2-cargo-ws-base"), ids.index("r2-cargo-ws"))
                keys = [k.strip() for k in restore["with"]["restore-keys"].splitlines() if k.strip()]
                self.assertEqual(keys, ["${{ steps.r2-cargo-ws-base.outputs.prefix }}",
                                        "${{ steps.r2-cargo-key.outputs.ws-prefix }}"])

    def test_every_key_step_emits_the_delta_base_of_its_prefix(self) -> None:
        sources = [(WORKFLOWS / "cmux-tui-build-package.yml").read_text(),
                   (ROOT / "scripts/ci/cmux-next-steps/fast-tier-cargo-key-the-cargo-build-in-r2.sh").read_text()]
        for text in sources:
            for line in text.splitlines():
                if 'echo "ws-prefix=' in line:
                    stem = line.split('ws-prefix=', 1)[1].split('$inputs-', 1)[0]
                    self.assertIn(f'echo "ws-base={stem}"', text)


if __name__ == "__main__":
    unittest.main()
