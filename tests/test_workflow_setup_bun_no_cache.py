#!/usr/bin/env python3
"""Every oven-sh/setup-bun step sets `no-cache: true`.

setup-bun's own cache saves bun's install directory under one key for a bun
version, and actions/cache stores the path relative to the job's workspace.
Our jobs run on runner pools whose workspaces sit at different depths
(/home/runner/work/cmux/cmux on hosted-style runners,
/home/runner/actions-runner/_work/cmux/cmux on the cmux-fleet-linux runners),
so an entry one pool saved restores bun beside the other pool's home and
setup-bun stops with "Unable to locate executable file: /home/runner/.bun/bin/bun".
2026-11-20: every react-apps-check shard of PR runs 44662346961, 44659532656
and 44655274499 failed that way in about a minute. Downloading bun is a few
seconds; a shared cache entry that breaks a whole pool is not worth it.
"""
from __future__ import annotations

from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parents[1]
GITHUB = ROOT / ".github"
USES = re.compile(r"^(\s*)(-\s+)?uses:\s*oven-sh/setup-bun@")


def steps_without_no_cache(text: str) -> list[int]:
    """1-based line numbers of setup-bun `uses:` lines whose step sets no `no-cache: true`."""
    lines = text.splitlines()
    missing = []
    for i, line in enumerate(lines):
        m = USES.match(line)
        if not m:
            continue
        key_indent = len(m.group(1)) + len(m.group(2) or "")
        found = False
        for nxt in lines[i + 1:]:
            stripped = nxt.strip()
            if not stripped or stripped.startswith("#"):
                if not stripped:
                    break
                continue
            indent = len(nxt) - len(nxt.lstrip())
            if indent < key_indent or stripped.startswith("- ") and indent <= key_indent:
                break
            if re.fullmatch(r"no-cache:\s*true", stripped):
                found = True
        if not found:
            missing.append(i + 1)
    return missing


class SetupBunNoCacheTest(unittest.TestCase):
    def test_every_setup_bun_step_sets_no_cache(self):
        files = sorted(p for p in GITHUB.rglob("*.y*ml") if p.is_file())
        self.assertTrue(files)
        missing = {
            f"{p.relative_to(ROOT)}:{n}": "setup-bun without no-cache: true"
            for p in files
            for n in steps_without_no_cache(p.read_text(encoding="utf-8"))
        }
        # Classic-frozen workflows are not changed from NEXT work (.github/classic-frozen.txt).
        frozen = {
            line.split()[0]
            for line in (GITHUB / "classic-frozen.txt").read_text(encoding="utf-8").splitlines()
            if line.startswith(".github/")
        }
        # A workflow whose schedule runs main's copy changes on main first (prepush-gate "Production journey workflow
        # matches main's").
        main_copy = {".github/workflows/cloud-journey-prod.yml"}
        missing = {k: v for k, v in missing.items() if k.rsplit(":", 1)[0] not in frozen | main_copy}
        self.assertEqual(missing, {}, "add `no-cache: true` to the step's `with:` (this file's docstring says why)")

    def test_the_reader_sees_a_step_with_and_without_it(self):
        good = "      - uses: oven-sh/setup-bun@abc # v2\n        with:\n          bun-version: 1\n          no-cache: true\n"
        bad = "      - name: Setup Bun\n        uses: oven-sh/setup-bun@abc # v2\n        with:\n          bun-version: 1\n\n      - run: bun x\n"
        self.assertEqual(steps_without_no_cache(good), [])
        self.assertEqual(steps_without_no_cache(bad), [2])


if __name__ == "__main__":
    unittest.main()
