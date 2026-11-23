#!/usr/bin/env python3
"""setup-cmux-tui-rust does not move ~/.cargo/bin ahead of tools the job set up before it.

macos-cross-parity.yml at dd16a4c8 (run 44982697930, 2026-11-22): both Mac builds on cmux10s
failed in ghostty-vt-sys with "Your Zig version v0.16.0 does not meet the required build version
of v0.17.0". mlugg/setup-zig had put Zig 0.17.0 first on PATH; then "Ensure rustup is available"
wrote ~/.cargo/bin to GITHUB_PATH, which goes in front of everything, and cmux10s keeps an old
zig 0.16 symlink in ~/.cargo/bin. cmux11s has none there, so the same job passed on it at 57ecf374.
The runner's own PATH already held ~/.cargo/bin; the step only needs to add it when it is not
on PATH (a fresh rustup install, or an image that keeps rustup there off PATH).
"""

from __future__ import annotations

import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]
ACTION = ROOT / ".github" / "actions" / "setup-cmux-tui-rust" / "action.yml"


def ensure_rustup_script() -> str:
    action = yaml.safe_load(ACTION.read_text(encoding="utf-8"))
    for step in action["runs"]["steps"]:
        if step.get("name") == "Ensure rustup is available":
            return step["run"]
    raise AssertionError("no 'Ensure rustup is available' step")


def fake_tool(directory: Path, name: str, output: str) -> None:
    directory.mkdir(parents=True, exist_ok=True)
    path = directory / name
    path.write_text(f"#!/bin/sh\necho {output}\n", encoding="utf-8")
    path.chmod(0o755)


class EnsureRustupKeepsPathOrder(unittest.TestCase):
    def run_step(self, home: Path, path: str) -> list[str]:
        github_path = home / "github_path"
        github_path.write_text("", encoding="utf-8")
        env = {"HOME": str(home), "PATH": path, "GITHUB_PATH": str(github_path)}
        subprocess.run(
            [shutil.which("bash") or "/bin/bash", "-c", ensure_rustup_script()],
            check=True,
            env=env,
            capture_output=True,
            text=True,
        )
        return [line for line in github_path.read_text(encoding="utf-8").splitlines() if line]

    def test_cargo_bin_already_on_path_is_not_moved_ahead_of_setup_zig(self):
        with tempfile.TemporaryDirectory() as tmp:
            home = Path(tmp)
            cargo_bin = home / ".cargo" / "bin"
            setup_zig = home / "tool" / "zig" / "0.17.0"
            fake_tool(cargo_bin, "zig", "0.16.0")
            fake_tool(cargo_bin, "rustup", "rustup")
            fake_tool(setup_zig, "zig", "0.17.0")
            added = self.run_step(home, f"{setup_zig}:{cargo_bin}:/usr/bin:/bin")
            job_path = os.pathsep.join([*reversed(added), str(setup_zig), str(cargo_bin), "/usr/bin", "/bin"])
            zig = shutil.which("zig", path=job_path)
            self.assertEqual(zig, str(setup_zig / "zig"), f"GITHUB_PATH got {added}")

    def test_cargo_bin_off_path_is_added_for_rustup(self):
        with tempfile.TemporaryDirectory() as tmp:
            home = Path(tmp)
            cargo_bin = home / ".cargo" / "bin"
            fake_tool(cargo_bin, "rustup", "rustup")
            added = self.run_step(home, "/usr/bin:/bin")
            self.assertEqual(added, [str(cargo_bin)])


if __name__ == "__main__":
    unittest.main()
