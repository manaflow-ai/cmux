#!/usr/bin/env python3
"""The pinned install command (cmuxterm-hq docs/design/linux-signed-packages.md, sections 4 and 8).

- cmux-tui/scripts/install-static-pin.py's check passes on this tree: the immutable
  web/public/tui/install-static/<sha256>.sh equals web/public/tui/install-static.sh, every app and CLI
  site pins that sha256, README.md's commit and sha256 match the script at that commit (git show), and
  no doc or app string offers a bare `curl ... install-static.sh | sh` for cmux.
- The detector finds the bare forms and passes the pinned ones.
- README.md's command runs the script only when it matches the pin (sha256sum on Linux, shasum -a 256
  where sha256sum is missing, as on a Mac), and removes its folder either way.
"""
from __future__ import annotations

import hashlib
import importlib.util
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
TOOL = ROOT / "cmux-tui/scripts/install-static-pin.py"
SCRIPT = ROOT / "web/public/tui/install-static.sh"
README = ROOT / "README.md"
# The pin sites the tool checks (named here so a change to any of them runs this test).
COVERS = (
    "Packages/macOS/CmuxNext/Sources/CmuxNextServer/AddDevice/AddDevicePlatform.swift",
    "cmux-next-ios/CmuxMobileKit/Sources/CmuxMobileModel/MachineInvite.swift",
    "cmux-tui/crates/acpmux/src/cli/pairing.rs",
    "web/app/lib/install-static-pin.ts",
    "web/data/next-docs/pages.ts",
    "web/app/[locale]/(landing)/tui/install-tabs.tsx",
)

spec = importlib.util.spec_from_file_location("install_static_pin", TOOL)
pin = importlib.util.module_from_spec(spec)
spec.loader.exec_module(pin)


class TreeIsPinned(unittest.TestCase):
    def test_the_check_passes(self) -> None:
        run = subprocess.run([sys.executable, "-I", str(TOOL)], capture_output=True, text=True)
        self.assertEqual(run.returncode, 0, run.stderr)

    def test_the_tool_checks_every_site_named_here(self) -> None:
        self.assertTrue(set(pin.SITES) <= set(COVERS))

    def test_the_immutable_copy_is_the_script(self) -> None:
        data = SCRIPT.read_bytes()
        copy = ROOT / pin.ARCHIVE / f"{hashlib.sha256(data).hexdigest()}.sh"
        self.assertEqual(copy.read_bytes(), data)


class Detector(unittest.TestCase):
    # Built from parts so this file is not itself a bare line the check finds.
    PIPE = "| "
    BARE = [
        f"curl -fsSL https://cmux.com/tui/install-static.sh {PIPE}sh",
        f"curl -fsSL https://cmux.com/tui/install.sh {PIPE}sh -s -- --server",
        f"`curl -fsSL https://cmux.com/tui/install-static.sh {PIPE}CMUX_HOST=1 sh`",
        f'"curl -fsSL https://cmux.com/tui/install-static.sh {PIPE}sh && ~/.cmux/bin/cmux pair X"',
        f"curl -fsSL https://raw.githubusercontent.com/manaflow-ai/cmux/main/web/public/tui/install-static.sh {PIPE}bash",
    ]
    PINNED = [
        'd="$(mktemp -d)" && curl -fsSL https://cmux.com/tui/install-static/' + "a" * 64 + '.sh -o "$d/install.sh"'
        ' && echo "' + "a" * 64 + '  $d/install.sh" | $(command -v sha256sum || echo shasum -a 256) -c'
        ' && sh "$d/install.sh"; rm -rf "$d"',
        "curl -fsSL https://claude.ai/install.sh | bash",
        "curl -fsSL https://cmux.com/coderouter/install.sh | sh",
        "the bare https://cmux.com/tui/install-static.sh keeps working",
    ]

    def test_bare_lines_are_found(self) -> None:
        for line in self.BARE:
            self.assertTrue(pin.bare_lines(line), line)

    def test_pinned_and_other_lines_pass(self) -> None:
        for line in self.PINNED:
            self.assertEqual(pin.bare_lines(line), [], line)

    def test_the_readme_pin_reads(self) -> None:
        commit, digest = pin.readme_pin(README.read_text())
        self.assertEqual((len(commit), len(digest)), (40, 64))


class ReadmeCommandRuns(unittest.TestCase):
    """README.md's command with its URL and sha256 swapped for a fixture script's."""

    def setUp(self) -> None:
        self.dir = Path(tempfile.mkdtemp(prefix="install-pin-test."))
        self.addCleanup(shutil.rmtree, self.dir)
        self.ran = self.dir / "ran"
        self.fixture = self.dir / "fixture.sh"
        self.fixture.write_text(f": > '{self.ran}'\n")
        self.tmp = self.dir / "tmp"
        self.tmp.mkdir()

    def command(self, digest: str) -> str:
        text = README.read_text()
        commit, readme_digest = pin.readme_pin(text)
        line = next(l for l in text.splitlines() if readme_digest in l and l.startswith('d="$(mktemp -d)"'))
        url = f"https://raw.githubusercontent.com/manaflow-ai/cmux/{commit}/web/public/tui/install-static.sh"
        return line.replace(url, "https://fixture.invalid/install.sh").replace(readme_digest, digest)

    def bin_dir(self, with_sha256sum: bool) -> Path:
        bin_dir = self.dir / ("bin-sum" if with_sha256sum else "bin-shasum")
        bin_dir.mkdir()
        for tool in ("mktemp", "rm", "cp", "sh", "cat"):
            os.symlink(shutil.which(tool), bin_dir / tool)
        curl = bin_dir / "curl"
        curl.write_text(
            '#!/bin/sh\nwhile [ $# -gt 0 ]; do\n  if [ "$1" = -o ]; then cp '
            f"'{self.fixture}'" ' "$2"; shift; fi\n  shift\ndone\n'
        )
        curl.chmod(0o755)
        sha256sum = shutil.which("sha256sum")
        if with_sha256sum:
            os.symlink(sha256sum, bin_dir / "sha256sum")
        else:
            # A Mac has `shasum -a 256` and no sha256sum.
            shasum = bin_dir / "shasum"
            shasum.write_text(f'#!/bin/sh\n[ "$1 $2" = "-a 256" ] || exit 9\nshift 2\nexec {sha256sum} "$@"\n')
            shasum.chmod(0o755)
        return bin_dir

    def run_line(self, digest: str, with_sha256sum: bool) -> int:
        env = {"PATH": str(self.bin_dir(with_sha256sum)), "TMPDIR": str(self.tmp), "HOME": str(self.dir)}
        line = self.command(digest)
        return subprocess.run(["/bin/sh", "-c", line + '; [ -e "' + str(self.ran) + '" ]'], env=env,
                              capture_output=True, text=True).returncode

    def test_a_matching_script_runs(self) -> None:
        for with_sha256sum in (True, False):
            with self.subTest(with_sha256sum=with_sha256sum):
                digest = hashlib.sha256(self.fixture.read_bytes()).hexdigest()
                self.assertEqual(self.run_line(digest, with_sha256sum), 0)
                self.assertTrue(self.ran.exists())
                self.assertEqual(list(self.tmp.iterdir()), [], "the folder stayed")
                self.ran.unlink()
                shutil.rmtree(self.dir / ("bin-sum" if with_sha256sum else "bin-shasum"))

    def test_a_script_off_its_pin_never_runs(self) -> None:
        for with_sha256sum in (True, False):
            with self.subTest(with_sha256sum=with_sha256sum):
                self.assertNotEqual(self.run_line("0" * 64, with_sha256sum), 0)
                self.assertFalse(self.ran.exists(), "the script ran without matching its pin")
                self.assertEqual(list(self.tmp.iterdir()), [], "the folder stayed")
                shutil.rmtree(self.dir / ("bin-sum" if with_sha256sum else "bin-shasum"))


if __name__ == "__main__":
    unittest.main()
