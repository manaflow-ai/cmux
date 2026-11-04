#!/usr/bin/env python3
"""The rolling nightly-next download is the cmux NIGHTLY build (user msg 20276, a979).

cmux-next ships under the existing nightly bundle id (`com.cmuxterm.app.nightly`),
not cmux NEXT's `com.cmuxterm.app.nightly.cmux-next`. cmux.com/next, the release
body and every "latest" link name the rolling asset
releases/download/nightly-next/cmux-nightly-next-macos-arm64.dmg, so that asset
must hold the cmux NIGHTLY-identity copy, and only its publisher may write it.

The publish step script runs here against a fake `gh`, `curl` and publisher,
and the recorded calls are checked.
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
    def test_names_job_no_longer_writes_the_rolling_name(self):
        names = job(nightly_text(), "publish-nightly-next-github-names")
        self.assertNotIn("--alias", names, "the cmux NEXT DMG must not take the rolling name")

    def test_release_body_names_cmux_nightly(self):
        text = nightly_text()
        step = text[text.index("NOTES_APP_NAME:"):][:400]
        self.assertIn("'cmux NIGHTLY'", step)
        self.assertIn("'com.cmuxterm.app.nightly'", step)

    def test_legacy_publish_writes_the_rolling_name_from_the_nightly_copy(self):
        with tempfile.TemporaryDirectory() as tmp:
            work = Path(tmp)
            bin_dir = work / "bin"
            bin_dir.mkdir()
            log = work / "calls.log"
            (work / "scripts" / "ci").mkdir(parents=True)
            fake(work / "scripts" / "ci", "nightly-next-guard.py", "exit 0\n")
            fake(work / "scripts" / "ci", "upload-r2-object.py", f'echo "r2 $*" >> {log}\n')
            fake(work / "scripts" / "ci", "publish-release-assets.py", f'echo "publish $*" >> {log}\n')
            fake(bin_dir, "python3", 'case "$1" in -I) exec /usr/bin/python3 "$@";; *) exec "$@";; esac\n')
            fake(bin_dir, "gh", f'echo "gh $*" >> {log}\n')
            # The DMG's HEAD check passes; the best-effort notes copy fails, which never blocks the feed.
            fake(bin_dir, "curl", 'case " $* " in *" -fsSIL "*) exit 0;; esac; exit 1\n')
            out = work / "legacy-out"
            out.mkdir()
            build = "4200000000001"
            (out / f"cmux-nightly-next-macos-nightlyid-arm64-{build}.dmg").write_bytes(b"nightly")
            (out / "appcast-arm64.xml").write_text(f"<sparkle:version>{build}</sparkle:version>")
            env = dict(os.environ, PATH=f"{bin_dir}:{os.environ['PATH']}",
                       NIGHTLY_NEXT_LEGACY_FEED_BASE="https://files-next.cmux.com/nightly-next",
                       NIGHTLY_NEXT_FEED_BASE="https://files-next.cmux.com/nightly-next/next",
                       NIGHTLY_NEXT_R2_BUCKET="b", R2_ENDPOINT="https://r2", NIGHTLY_BUILD=build,
                       LEGACY_DMG_PREFIX="cmux-nightly-next-macos-nightlyid-arm64-",
                       LEGACY_APPCAST="appcast-arm64.xml", CHANNEL_RELEASE_TAG="nightly-next",
                       CHANNEL_DMG_PREFIX="cmux-nightly-next-macos", GITHUB_REPOSITORY="manaflow-ai/cmux",
                       GITHUB_STEP_SUMMARY=str(work / "summary.md"))
            env.pop("RELEASE_POKE_URL", None)
            result = subprocess.run(["bash", str(ROOT / "scripts/ci/nightly-steps/legacy-identity-publish.sh")],
                                    cwd=work, env=env, capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            calls = log.read_text()
            publish = [line for line in calls.splitlines() if line.startswith("publish ")]
            self.assertEqual(len(publish), 1, calls)
            self.assertIn(f"--alias legacy-out/{ROLLING}", publish[0])
            self.assertIn(f"--immutable legacy-out/cmux-nightly-next-macos-nightlyid-arm64-{build}.dmg", publish[0])
            self.assertEqual((out / ROLLING).read_bytes(), b"nightly")
            # The feed goes live before the rolling name moves, so the link never runs ahead of it.
            self.assertLess(calls.index("r2 "), calls.index("publish "))


if __name__ == "__main__":
    unittest.main()
