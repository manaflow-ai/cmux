#!/usr/bin/env python3
"""The rolling nightly-next download is the cmux NIGHTLY build (user msg 20276, a979).

cmux-next ships once, under the existing nightly bundle id (`com.cmuxterm.app.nightly`;
hq#7156). cmux.com/next, the release body and every "latest" link name the rolling
asset releases/download/nightly-next/cmux-nightly-next-macos-arm64.dmg, which
publish-nightly-next-github moves to the build it just uploaded, only while that
build is the feed's newest.

The step script runs here against a fake publisher, and the recorded call is checked.
"""
from __future__ import annotations

import os
import re
import stat
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from nightly_workflow_text import nightly_text  # noqa: E402

ROOT = Path(__file__).resolve().parents[1]
ROLLING = "cmux-nightly-next-macos-arm64.dmg"


def job(text: str, name: str) -> str:
    start = text.index(f"\n  {name}:\n")
    rest = text[start + 1:]
    end = re.search(r"\n  [a-z0-9-]+:\n", rest)
    return rest[: end.start()] if end else rest


def fake(bin_dir: Path, name: str, body: str) -> None:
    path = bin_dir / name
    path.write_text("#!/bin/bash\n" + body)
    path.chmod(path.stat().st_mode | stat.S_IEXEC)


class RollingDmgIdentity(unittest.TestCase):
    def test_release_body_names_cmux_nightly(self):
        text = nightly_text()
        step = text[text.index("NOTES_APP_NAME:"):][:400]
        self.assertIn("'cmux NIGHTLY'", step)
        self.assertIn("'com.cmuxterm.app.nightly'", step)

    def run_names(self, newest: bool) -> tuple[subprocess.CompletedProcess, Path, Path]:
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        work = Path(tmp.name)
        log = work / "calls.log"
        (work / "tooling" / "ci").mkdir(parents=True)
        fake(work / "tooling" / "ci", "publish-release-assets.py", f'echo "publish $*" >> {log}\n')
        fake(work, "still-newest", "exit 0\n" if newest else "exit 1\n")
        bin_dir = work / "bin"
        bin_dir.mkdir()
        fake(bin_dir, "python3", 'exec "$@"\n')
        out = work / "nightly-out"
        out.mkdir()
        build = "4200000000001"
        (out / f"cmux-nightly-next-macos-arm64-{build}.dmg").write_bytes(b"nightly")
        (out / "appcast-arm64.xml").write_text(f"<sparkle:version>{build}</sparkle:version>")
        env = dict(os.environ, PATH=f"{bin_dir}:{os.environ['PATH']}", RUNNER_TEMP=str(work),
                   PUBLISH_TOOLING=str(work / "tooling"), NIGHTLY_FEEDS="appcast-arm64.xml", NIGHTLY_BUILD=build,
                   CHANNEL_RELEASE_TAG="nightly-next", CHANNEL_DMG_PREFIX="cmux-nightly-next-macos",
                   GITHUB_REPOSITORY="manaflow-ai/cmux", GITHUB_OUTPUT=str(work / "output"))
        result = subprocess.run(["bash", str(ROOT / "scripts/ci/nightly-steps/github-names-publish-rolling-name.sh")],
                                cwd=work, env=env, capture_output=True, text=True)
        return result, log, out

    def test_the_names_job_moves_the_rolling_name_to_the_published_build(self):
        result, log, out = self.run_names(newest=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        publish = log.read_text().splitlines()
        self.assertEqual(len(publish), 1, publish)
        self.assertIn(f"--alias nightly-out/{ROLLING}", publish[0])
        self.assertIn("--immutable nightly-out/cmux-nightly-next-macos-arm64-4200000000001.dmg", publish[0])
        self.assertIn("--replace-feeds --feed nightly-out/appcast-arm64.xml", publish[0])
        self.assertEqual((out / ROLLING).read_bytes(), b"nightly")

    def test_a_build_no_longer_newest_moves_nothing(self):
        result, log, out = self.run_names(newest=False)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(log.exists())
        self.assertFalse((out / ROLLING).exists())


if __name__ == "__main__":
    unittest.main()
