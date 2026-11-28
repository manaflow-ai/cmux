#!/usr/bin/env python3
"""DaemonWireTypesPlugin's pick-python.sh finds a 3.10+ Python the way a plugin run sees the host.

Xcode and SwiftPM run the plugin's `/bin/sh pick-python.sh` with PATH=/usr/bin:/bin. A Homebrew python installed as
another formula's dependency links only bin/python3.13, never bin/python3, so the script before 7b1ef3fb, which
looked only at the unversioned names in its fixed folders and then PATH, failed every build on aws-m4pro-1..3
(2026-11-27). This runs the script text of cmux-tui/bindings/codegen/swift_app/pick-python.sh under /bin/sh with an empty PATH and its absolute prefixes
(/opt/homebrew, /usr/local, /Library/Frameworks) moved under a temporary root, so no host's own Python can answer:
each case plants fake interpreters there and checks which one the script runs. No Swift build, no Python 3.10; runs
on macOS and Linux.

    python3 scripts/cmux-next/tests/test_daemon_wire_types_pick_python.py
"""

from __future__ import annotations

import os
import re
import shlex
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
PLUGIN = ROOT / "Packages/macOS/CmuxNext/Plugins/DaemonWireTypesPlugin/plugin.swift"
PICK = ROOT / "cmux-tui/bindings/codegen/swift_app/pick-python.sh"
PREFIXES = ("/opt/homebrew", "/usr/local", "/Library/Frameworks")
# The start of an absolute path in the script: a slash no name, variable or version runs into.
ABSOLUTE = re.compile(r"(?<![\w.}@$-])(?<!\$dir\")/(?=\w)")
HOST_PATHS = {"/dev/null"}  # the probe's 2>/dev/null


def pick_python_script() -> str:
    """pick-python.sh less its comments (they name host paths the script never reads)."""
    return "\n".join(line for line in PICK.read_text().split("\n") if not line.lstrip().startswith("#"))


def rooted(script: str, root: Path) -> str:
    for prefix in PREFIXES:
        script = script.replace(prefix, f"{root}{prefix}")
    return script


def fake_python(path: Path, label: str, supported: bool, record: Path) -> None:
    """An interpreter that passes (or fails) the 3.10 probe and records the generator run it was exec'd for."""
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("#!/bin/sh\n"
                    f'if [ "$1" = -I ] && [ "$2" = -c ]; then exit {0 if supported else 1}; fi\n'
                    f"printf '%s\\n' {shlex.quote(label)} \"$@\" > {shlex.quote(str(record))}\n")
    path.chmod(0o755)


class PickPython(unittest.TestCase):
    def setUp(self):
        self.script = pick_python_script()
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(os.path.realpath(self.tmp.name))
        self.empty_bin = self.root / "empty-bin"
        self.empty_bin.mkdir()
        self.record = self.root / "ran.txt"
        self.generator = self.root / "gen.py"
        self.out = self.root / "out"

    def plant(self, relative: str, label: str, supported: bool = True) -> None:
        fake_python(self.root / relative.lstrip("/"), label, supported, self.record)

    def run_script(self, path: Path | str | None = None, home: Path | None = None) -> subprocess.CompletedProcess[str]:
        # The whole environment: an empty or fixture PATH (and HOME when a case sets one), nothing else (`env -i`).
        argv = ["/bin/sh", "-c", rooted(self.script, self.root), "sh", str(self.generator), str(self.out)]
        env = {"PATH": str(path or self.empty_bin)} | ({"HOME": str(home)} if home else {})
        return subprocess.run(argv, env=env, stdin=subprocess.DEVNULL,
                              capture_output=True, text=True, timeout=60)

    def assert_ran(self, result: subprocess.CompletedProcess[str], label: str) -> None:
        detail = f"exit {result.returncode}, stderr: {result.stderr.strip()!r}"
        self.assertEqual(result.returncode, 0, detail)
        self.assertTrue(self.record.exists(), f"no interpreter ran the generator ({detail})")
        self.assertEqual(self.record.read_text().split("\n")[:-1],
                         [label, "-I", "-B", str(self.generator), "--out", str(self.out)])

    def test_the_script_is_hermetic_once_rooted(self):
        for prefix in PREFIXES:
            self.assertIn(prefix, self.script, f"pick-python.sh no longer names {prefix}; update PREFIXES")
        moved = rooted(self.script, self.root)
        strays = sorted({moved[m.start():].split()[0] for m in ABSOLUTE.finditer(moved)
                         if not moved.startswith(str(self.root), m.start())} - HOST_PATHS)
        self.assertEqual(strays, [], "an absolute path this test does not move under its root reads the host")

    def test_homebrew_python_linked_only_by_its_versioned_name(self):
        # aws-m4pro-1..3: python@3.13 came in as a dependency, so only bin/python3.13 is linked.
        self.plant("/opt/homebrew/bin/python3.13", "brew-3.13")
        self.assert_ran(self.run_script(), "brew-3.13")

    def test_usr_local_python_linked_only_by_its_versioned_name(self):
        self.plant("/usr/local/bin/python3.12", "local-3.12")
        self.assert_ran(self.run_script(), "local-3.12")

    def test_python_org_current_with_only_a_versioned_name(self):
        self.plant("/Library/Frameworks/Python.framework/Versions/Current/bin/python3.11", "org-3.11")
        self.assert_ran(self.run_script(), "org-3.11")

    def test_an_old_python3_is_passed_over_for_a_versioned_one(self):
        self.plant("/opt/homebrew/bin/python3", "brew-3.9", supported=False)
        self.plant("/opt/homebrew/bin/python3.12", "brew-3.12")
        self.assert_ran(self.run_script(), "brew-3.12")

    def test_absolute_paths_come_before_path(self):
        self.plant("/opt/homebrew/bin/python3.13", "brew-3.13")
        self.plant("/path-bin/python3", "path-python3")
        self.assert_ran(self.run_script(self.root / "path-bin"), "brew-3.13")

    def test_path_is_the_fallback(self):
        self.plant("/path-bin/python3.12", "path-3.12")
        self.assert_ran(self.run_script(self.root / "path-bin"), "path-3.12")

    def test_a_python_newer_than_any_listed_name(self):
        # Leo 2026-11-23: "we need to not have old pythons and bullshit like that anywhere": a host with only a
        # newer Python than the pick ever listed (uv's python3.15) must still build.
        self.plant("/opt/homebrew/bin/python3.15", "brew-3.15")
        self.assert_ran(self.run_script(), "brew-3.15")

    def test_uv_python_in_home_local_bin(self):
        # leo-workspace tools/py links uv's pinned Python as ~/.local/bin/python3.15 on every host.
        self.plant("/home-dir/.local/bin/python3.15", "uv-3.15")
        self.assert_ran(self.run_script(home=self.root / "home-dir"), "uv-3.15")

    def test_every_path_entry_is_read_with_versioned_names(self):
        self.plant("/path-a/python3", "old-3.9", supported=False)
        self.plant("/path-b/python3.15", "path-3.15")
        self.assert_ran(self.run_script(f"{self.root}/path-a:{self.root}/path-b"), "path-3.15")

    def test_the_echoed_command_carries_no_error_text(self):
        # SwiftPM prints a failed prebuild command's arguments; any error text in them is quoted in every
        # plugin failure (bb23166636a: a codegen error read as "needs Python 3.10+").
        arguments = re.search(r"arguments: \[(.*?)\]", PLUGIN.read_text(), re.S)
        self.assertIsNotNone(arguments, f"no prebuild `arguments: [...]` in {PLUGIN}")
        self.assertEqual(re.findall(r"(\w+)\.path\(", arguments.group(1)), ["pick", "script", "out"])

    def test_no_python_fails_naming_the_fix(self):
        self.plant("/usr/local/bin/python3", "brew-3.9", supported=False)
        result = self.run_script()
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertIn("needs Python 3.10+", result.stderr)
        self.assertFalse(self.record.exists(), "an unsupported Python ran the generator")


if __name__ == "__main__":
    unittest.main()
