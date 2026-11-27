#!/usr/bin/env python3
"""The darwin cross leg makes its own room on a pool host before it builds.

Run 45793848138 (2026-11-26): "build aarch64-apple-darwin" started on a pool VM at 31.5 GiB free,
over the pool start hook's in-line clean (17 GiB) and under its floor, so the hook only pruned the
cheap steps in the background; the build hit "No space left on device". scripts/ci/pool-make-room.sh
runs the hook's beside-a-job prune in line with the step's own need as floor and reserve.

This pins:
- the script runs the hook in child mode with the need as floor, reserve and job need, and a lock wait;
- it does nothing with the need already free, or off a pool host (no hook);
- it never fails the step, even when the hook fails or the disk stays short;
- the workflow runs it on the darwin pool leg before the R2 cargo restore and the build.

Run: python3 tests/test_ci_pool_make_room.py
"""

from __future__ import annotations

import os
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SCRIPT = ROOT / "scripts/ci/pool-make-room.sh"
WORKFLOW = ROOT / ".github/workflows/cmux-tui-build-package.yml"


class PoolMakeRoom(unittest.TestCase):
    def run_script(self, need: int, hook: str | None, exit_code: int = 0) -> tuple[subprocess.CompletedProcess, Path]:
        tmp = Path(tempfile.mkdtemp())
        record = tmp / "record"
        env = dict(os.environ)
        env["CMUX_POOL_MAKE_ROOM_PATH"] = str(tmp)
        if hook is None:
            env["CMUX_POOL_DISK_FLOOR_HOOK"] = str(tmp / "absent")
        else:
            fake = tmp / "hook.sh"
            fake.write_text(
                "#!/bin/bash\n"
                f'{{ echo "phase=$1"; env | grep -E "^CMUX_DISK_" | sort; }} > "{record}"\n'
                f"exit {exit_code}\n"
            )
            fake.chmod(0o755)
            env["CMUX_POOL_DISK_FLOOR_HOOK"] = str(fake)
        proc = subprocess.run(
            ["bash", str(SCRIPT), str(need), "5"], env=env, capture_output=True, text=True, timeout=60
        )
        return proc, record

    def test_a_short_disk_runs_the_hook_prune_in_line_with_the_need(self) -> None:
        need = 1 << 62  # more than any disk has
        proc, record = self.run_script(need, "hook")
        self.assertEqual(proc.returncode, 0, proc.stderr)
        got = record.read_text()
        self.assertIn("phase=room", got)
        for name in ("CMUX_DISK_FLOOR_BYTES", "CMUX_DISK_RESERVE_BYTES", "CMUX_DISK_JOB_BYTES"):
            self.assertIn(f"{name}={need}", got)
        self.assertIn("CMUX_DISK_FLOOR_CHILD=1", got)
        self.assertIn("CMUX_DISK_FLOOR_LOCK_WAIT=5", got)
        self.assertIn("still under the step's need", proc.stdout)

    def test_enough_free_does_nothing(self) -> None:
        proc, record = self.run_script(1, "hook")
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertFalse(record.exists())
        self.assertIn("nothing to do", proc.stdout)

    def test_off_the_pool_does_nothing(self) -> None:
        proc, _ = self.run_script(1 << 62, None)
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertIn("no pool disk hook", proc.stdout)

    def test_a_failing_hook_never_fails_the_step(self) -> None:
        proc, record = self.run_script(1 << 62, "hook", exit_code=3)
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertTrue(record.exists())

    def test_the_darwin_pool_leg_makes_room_before_the_cargo_restore_and_build(self) -> None:
        text = WORKFLOW.read_text()
        room = text.index("- name: Make room on the pool host (aarch64 macOS on Linux)")
        step = text[room : text.index("\n      - name:", room + 1)]
        self.assertIn("scripts/ci/pool-make-room.sh", step)
        self.assertIn("startsWith(runner.name, 'cmux-runner-pool-')", step)
        self.assertIn("matrix.darwin_on_linux", step)
        self.assertIn("continue-on-error: true", step)
        self.assertLess(room, text.index("- name: Restore the cargo build from R2"))
        self.assertLess(room, text.index("- name: Build the macOS binaries on Linux (no Apple SDK)"))


if __name__ == "__main__":
    unittest.main()
