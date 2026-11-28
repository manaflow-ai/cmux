#!/usr/bin/env python3
"""guest-start.sh waits for the guest's login session before it restarts tccd, and exits 5 when there is
none, so cu-driver-bench.sh restarts the VM once instead of losing the suite run. 2026-11-27: a fresh
clone on a loaded host still sat at loginwindow 4 minutes after SSH answered; tcc-grant.sh had already
restarted the system tccd, every bootstrap failed with 125, and the whole nightly suite run was invalid.
Runs the real script with pgrep, sudo, sleep and the tree's tcc-grant.sh stubbed.
"""
from __future__ import annotations

import os
import re
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
SCRIPT = ROOT / "scripts/measure/cu-driver-eval/guest-start.sh"
BENCH = ROOT / "scripts/measure/cu-driver-bench.sh"


def stub(path: Path, body: str) -> None:
    path.write_text("#!/bin/bash\n" + body + "\n")
    path.chmod(0o755)


class GuestStartSession(unittest.TestCase):
    def run_start(self, dock: bool) -> tuple[int, str, list[str]]:
        with tempfile.TemporaryDirectory() as tmp:
            home, bin_dir = Path(tmp) / "home", Path(tmp) / "bin"
            tree = home / "cu-eval/scripts/measure/cu-driver-eval"
            tree.mkdir(parents=True)
            bin_dir.mkdir()
            calls = Path(tmp) / "calls"
            stub(tree / "tcc-grant.sh", f'echo "tcc-grant $*" >>{calls}')
            stub(bin_dir / "pgrep", f'[[ " $* " == *" Dock"* ]] && exit {0 if dock else 1}; exit 0')
            stub(bin_dir / "sudo", f'echo "sudo $*" >>{calls}; [[ "$*" == *"print gui/"*"/com.cmux.cu-eval"* ]] && exit 1; exit 0')
            stub(bin_dir / "sleep", "exit 0")
            env = {**os.environ, "HOME": str(home), "PATH": f"{bin_dir}:{os.environ['PATH']}"}
            got = subprocess.run(["bash", str(SCRIPT), "r" * 40, "1", "cmux-cu"], env=env, capture_output=True,
                                 text=True, timeout=60)
            lines = calls.read_text().splitlines() if calls.exists() else []
            return got.returncode, got.stderr, lines

    def test_no_session_exits_5_before_restarting_tccd(self) -> None:
        code, err, calls = self.run_start(dock=False)
        self.assertEqual(code, 5, err)
        self.assertIn("login session ready: no", err)
        self.assertFalse([c for c in calls if c.startswith("tcc-grant")], "tccd was restarted with no session")
        self.assertFalse([c for c in calls if "bootstrap" in c])

    def test_a_session_grants_then_bootstraps(self) -> None:
        code, err, calls = self.run_start(dock=True)
        self.assertEqual(code, 0, err)
        grant = next(i for i, c in enumerate(calls) if c.startswith("tcc-grant"))
        boot = next(i for i, c in enumerate(calls) if "launchctl bootstrap" in c)
        self.assertLess(grant, boot)

    def test_the_bench_restarts_the_vm_once_on_exit_5(self) -> None:
        text = BENCH.read_text(encoding="utf-8")
        self.assertRegex(text, r"if \[\[ \$start_status == 5 \]\]; then")
        block = text.split("if [[ $start_status == 5 ]]; then", 1)[1].split("\nfi\n", 1)[0]
        self.assertEqual(len(re.findall(r"^\s*start_ab \|\| start_status=\$\?", block, re.M)), 1)
        self.assertIn('run "$vm" --no-display', block)


if __name__ == "__main__":
    sys.exit(unittest.main())
