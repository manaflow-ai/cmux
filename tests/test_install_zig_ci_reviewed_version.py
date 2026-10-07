#!/usr/bin/env python3
"""install-zig-ci.sh installs only a Zig version that the license review
recorded: the shipped one (toolchains.json zig ci_version, whose LICENSE the app
and packages ship) or the Zig SDK conformance version
(cmux-tui/bindings/zig/build.zig.zon). Any other version stops the job before it
downloads anything."""

from __future__ import annotations

import json
import os
from pathlib import Path
import re
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts/install-zig-ci.sh"
TOOLCHAINS = ROOT / "cmux-tui/build-support/notices/toolchains/toolchains.json"


def fake_zig(directory: Path, version: str) -> None:
    lib = directory / "lib"
    (lib / "compiler").mkdir(parents=True)
    (lib / "compiler/build_runner.zig").write_text("// fixture\n")
    zig = directory / "zig"
    zig.write_text(
        "#!/bin/sh\n"
        f'if [ "$1" = version ]; then echo {version}; exit 0; fi\n'
        f'if [ "$1" = env ]; then echo \'{{"lib_dir": "{lib}"}}\'; exit 0; fi\n'
        "exit 1\n"
    )
    zig.chmod(0o755)


def run(version: str, fake: str | None = None) -> subprocess.CompletedProcess[str]:
    with tempfile.TemporaryDirectory() as raw:
        tmp = Path(raw)
        fake_zig(tmp, fake or version)
        env = {**os.environ, "ZIG_REQUIRED": version, "PATH": f"{tmp}:{os.environ['PATH']}",
               "ZIG_INDEX_URL": "http://127.0.0.1:9/unreachable", "GITHUB_PATH": "", "GITHUB_ENV": ""}
        return subprocess.run(["bash", str(SCRIPT)], cwd=ROOT, env=env, capture_output=True, text=True, timeout=60)


class ReviewedZigVersionTest(unittest.TestCase):
    def test_the_reviewed_ci_version_is_accepted(self) -> None:
        [zig] = json.loads(TOOLCHAINS.read_text())["zig"]
        result = run(zig["ci_version"])
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_the_sdk_conformance_version_is_accepted(self) -> None:
        zon = (ROOT / "cmux-tui/bindings/zig/build.zig.zon").read_text()
        version = re.search(r'\.minimum_zig_version\s*=\s*"([^"]+)"', zon).group(1)
        result = run(version)
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_another_version_stops_before_download(self) -> None:
        result = run("0.16.1")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("toolchains.json", result.stderr)
        self.assertIn("0.16.1", result.stderr)


if __name__ == "__main__":
    unittest.main()
