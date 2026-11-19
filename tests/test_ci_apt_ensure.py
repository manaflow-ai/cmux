#!/usr/bin/env python3
"""The cmux-tui tree jobs install Debian packages only when they are missing.

Run 44363923089 (2026-11-18): the three build legs placed on our own GCP build lanes failed in
15 s at "Install Linux build dependencies". The step ran `sudo apt-get update` and `sudo apt-get
install -y ...` unconditionally; the runner user there has no sudo, and every package was already
installed. scripts/ci/apt-ensure.sh asks dpkg first, installs only what is missing, takes sudo only
then, and fails naming the missing packages when it cannot install them.

This runs the script against stub dpkg-query, sudo and apt-get, and checks that no step of the
tree path's workflows calls apt-get with sudo directly any more.
"""

from __future__ import annotations

import os
import re
import stat
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts" / "ci" / "apt-ensure.sh"
TREE_WORKFLOWS = (
    "cmux-tui-artifacts.yml",
    "cmux-tui-build-package.yml",
    "cmux-tui-tree-request.yml",
)


def write_stub(directory: Path, name: str, body: str) -> None:
    path = directory / name
    path.write_text("#!/usr/bin/env bash\n" + body, encoding="utf-8")
    path.chmod(path.stat().st_mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)


class AptEnsureTest(unittest.TestCase):
    def run_script(self, installed: set[str], sudo: bool, *packages: str) -> tuple[subprocess.CompletedProcess, list[str]]:
        with tempfile.TemporaryDirectory() as tmp:
            stubs = Path(tmp) / "bin"
            stubs.mkdir()
            calls = Path(tmp) / "calls"
            state = Path(tmp) / "installed"
            state.write_text("\n".join(sorted(installed)) + "\n", encoding="utf-8")
            # dpkg-query -W -f=FORMAT PACKAGE: "installed" for a package in the state file.
            write_stub(stubs, "dpkg-query",
                       f'grep -qx -- "${{@: -1}}" {state} && printf installed || exit 1\n')
            # apt-get install -y P...: records the call and marks each package installed.
            write_stub(stubs, "apt-get",
                       f'echo "apt-get $*" >> {calls}\n'
                       f'if [ "$1" = install ]; then shift 2; printf "%s\\n" "$@" >> {state}; fi\n')
            write_stub(stubs, "sudo",
                       f'echo "sudo $*" >> {calls}\n'
                       + ('[ "$1" = -n ] && shift; [ "$1" = true ] && exit 0; exec "$@"\n' if sudo else "exit 1\n"))
            write_stub(stubs, "id", '[ "$1" = -u ] && echo 1010 || echo ghrun\n')
            env = {**os.environ, "PATH": f"{stubs}:/usr/bin:/bin", "RUNNER_NAME": "lane-build-1"}
            result = subprocess.run(["bash", str(SCRIPT), *packages], env=env, text=True,
                                    capture_output=True, check=False)
            log = calls.read_text(encoding="utf-8").splitlines() if calls.exists() else []
            return result, log

    def test_nothing_missing_runs_no_sudo_and_no_apt(self) -> None:
        packages = ("binutils", "clang", "libclang-dev", "musl-tools", "pkg-config")
        result, calls = self.run_script(set(packages), False, *packages)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(calls, [])

    def test_missing_without_sudo_fails_naming_the_packages(self) -> None:
        result, calls = self.run_script({"clang", "binutils"}, False, "binutils", "clang", "musl-tools", "pkg-config")
        self.assertEqual(result.returncode, 1)
        self.assertIn("lane-build-1 is missing musl-tools pkg-config", result.stdout)
        self.assertIn("no passwordless sudo", result.stdout)
        self.assertFalse([call for call in calls if "apt-get" in call], calls)

    def test_missing_with_sudo_installs_only_the_missing_ones(self) -> None:
        result, calls = self.run_script({"clang-19"}, True, "clang-19", "lld-19", "llvm-19")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("apt-get install -y lld-19 llvm-19", calls)
        self.assertNotIn("clang-19", " ".join(call for call in calls if "install" in call))

    def test_the_tree_workflows_never_run_apt_get_under_sudo(self) -> None:
        for name in TREE_WORKFLOWS:
            text = (ROOT / ".github" / "workflows" / name).read_text(encoding="utf-8")
            with self.subTest(workflow=name):
                self.assertIsNone(re.search(r"sudo\s+(-\S+\s+)*apt(-get)?\s", text))


if __name__ == "__main__":
    unittest.main()
