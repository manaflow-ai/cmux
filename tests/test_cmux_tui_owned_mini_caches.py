#!/usr/bin/env python3
"""cmux-tui's macOS job keeps owned minis out of caches that never come back.

Measured 2026-10-29 on eight sampled `macOS lint and tests` jobs on owned minis:

* setup-go's Actions cache never restored (8 of 8). The mini keeps its own
  read-only ~/go/pkg/mod, so untarring the ~590 MB cache over it failed with
  "Permission denied". Each job still downloaded the tarball (about 63 s) and
  then tried to save it again.
* rust-cache restored 0 of 8. Each branch save cost about 155 s and 0.6-0.9 GB
  of the 10 GB GitHub cache store, and those saves filled most of the store.

So on an owned mini (a runner name containing `-glaeda`), setup-go gets no
Actions cache, and rust-cache saves only from feat-cmux-next. Blacksmith VMs
start empty, so they keep both caches.
"""

from __future__ import annotations

import sys
import unittest
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]
WORKFLOW = ROOT / ".github/workflows/cmux-tui.yml"
OWNED = "contains(runner.name, '-glaeda')"


def macos_steps() -> list[dict]:
    workflow = yaml.safe_load(WORKFLOW.read_text(encoding="utf-8"))
    return list(workflow["jobs"]["macos"]["steps"])


def step_using(steps: list[dict], action: str) -> dict:
    found = [step for step in steps if str(step.get("uses", "")).lower().startswith(action)]
    if len(found) != 1:
        raise AssertionError(f"expected one {action} step in the macOS job, found {len(found)}")
    return found[0]


def squash(value: object) -> str:
    return " ".join(str(value).split())


class OwnedMiniCaches(unittest.TestCase):
    def setUp(self) -> None:
        self.steps = macos_steps()

    def test_setup_go_has_no_actions_cache_on_an_owned_mini(self) -> None:
        step = step_using(self.steps, "actions/setup-go@")
        cache = squash((step.get("with") or {}).get("cache", ""))
        self.assertEqual(cache, "${{ !" + OWNED + " }}", f"setup-go cache is {cache!r}")

    def test_rust_cache_saves_from_an_owned_mini_only_on_feat_cmux_next(self) -> None:
        step = step_using(self.steps, "swatinem/rust-cache@")
        save_if = squash((step.get("with") or {}).get("save-if", ""))
        self.assertEqual(
            save_if,
            "${{ !" + OWNED + " || github.ref == 'refs/heads/feat-cmux-next' }}",
            f"rust-cache save-if is {save_if!r}",
        )


if __name__ == "__main__":
    sys.exit(0 if unittest.main(exit=False).result.wasSuccessful() else 1)
