#!/usr/bin/env python3
"""NIGHTLY_NEXT_DEV_RING is read live at publish time (scripts/ci/nightly_next_dev_ring.sh).

2026-10-27: run 40454745365 was created at 05:20Z with the ring on and published on attempt 2 at
08:39Z, after the ring was turned off at 08:28Z. A re-run keeps its `vars` snapshot, so it tagged
both feeds cmux-next-dev again and the shipped cmux NIGHTLY app was offered nothing new. Every
publish step that tags items now reads the switch live; a refused read is off, loudly.
"""
from __future__ import annotations

import os
from pathlib import Path
import re
import stat
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tests"))
from nightly_workflow_text import nightly_text  # noqa: E402

SCRIPT = ROOT / "scripts/ci/nightly_next_dev_ring.sh"
RING = ROOT / "scripts/ci/nightly_next_ring.py"

# A stand-in gh: prints FAKE_VALUE, or fails the way `gh api` does with FAKE_ERROR.
FAKE_GH = """#!/usr/bin/env bash
echo "$GH_TOKEN $*" >> "$FAKE_LOG"
if [ -n "${FAKE_ERROR:-}" ]; then echo "$FAKE_ERROR" >&2; exit 1; fi
echo "$FAKE_VALUE"
"""


class LiveReadTests(unittest.TestCase):
    def read(self, value="", error="", token="app-token"):
        with tempfile.TemporaryDirectory() as tmp:
            gh = Path(tmp) / "gh"
            gh.write_text(FAKE_GH)
            gh.chmod(gh.stat().st_mode | stat.S_IXUSR)
            out, log = Path(tmp) / "out", Path(tmp) / "log"
            out.touch()
            log.touch()
            env = {**os.environ, "PATH": f"{tmp}:{os.environ['PATH']}", "RING_TOKEN": token,
                   "GITHUB_REPOSITORY": "o/r", "FAKE_VALUE": value, "FAKE_ERROR": error, "FAKE_LOG": str(log)}
            result = subprocess.run(["bash", str(SCRIPT), "--github-output", str(out)],
                                    env=env, capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            return out.read_text(), result.stdout, log.read_text()

    def test_on_reads_on(self):
        output, _, calls = self.read("on")
        self.assertEqual(output, "mode=on\n")
        self.assertIn("app-token api repos/o/r/actions/variables/NIGHTLY_NEXT_DEV_RING", calls)

    def test_off_or_anything_else_reads_off(self):
        for value in ("off", "On", "", "yes"):
            self.assertEqual(self.read(value)[0], "mode=off\n", value)
        self.assertEqual(self.read(" on \n")[0], "mode=on\n")

    def test_unset_reads_off_quietly(self):
        output, stdout, _ = self.read(error="gh: Not Found (HTTP 404)")
        self.assertEqual(output, "mode=off\n")
        self.assertNotIn("::warning", stdout)

    def test_a_refused_read_is_off_and_loud(self):
        output, stdout, _ = self.read(error="gh: Resource not accessible by integration (HTTP 403)")
        self.assertEqual(output, "mode=off\n")
        self.assertIn("::warning title=DEV ring::DEV ring: live read refused (gh: Resource not accessible", stdout)
        self.assertIn("using off", stdout)

    def test_no_token_is_off_and_loud_without_a_call(self):
        output, stdout, calls = self.read("on", token="")
        self.assertEqual(output, "mode=off\n")
        self.assertIn("DEV ring: live read refused (no release App token), using off", stdout)
        self.assertEqual(calls, "")


def feed(*items: tuple[str, str]) -> str:
    body = "".join(
        f"<item><sparkle:channel>{channel}</sparkle:channel><sparkle:version>{build}</sparkle:version>"
        f'<enclosure url="https://files-next.cmux.com/nightly-next/next/cmux-nightly-next-macos-arm64-{build}.dmg"/></item>\n'
        for build, channel in items)
    return f'<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel>\n{body}</channel></rss>\n'


class StaleSnapshotTests(unittest.TestCase):
    """A build tagged Dev from a stale snapshot goes out on cmux-next once the live read is off."""

    def retag(self, text: str, mode: str) -> str:
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "appcast-arm64.xml"
            path.write_text(text)
            (Path(tmp) / "verdicts").mkdir()
            result = subprocess.run([sys.executable, str(RING), "retag", "--feed", str(path), "--out", str(path),
                                     "--mode", mode, "--verdicts-base", tmp], capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            return path.read_text()

    def test_the_stale_dev_tag_is_replaced_when_the_ring_reads_off(self):
        out = self.retag(feed(("4045474536502", "cmux-next-dev")), "off")
        self.assertEqual(re.findall(r"<sparkle:channel>([^<]*)</sparkle:channel>", out), ["cmux-next"])
        out = self.retag(feed(("4045474536502", "cmux-next")), "on")
        self.assertEqual(re.findall(r"<sparkle:channel>([^<]*)</sparkle:channel>", out), ["cmux-next-dev"])


class WorkflowTests(unittest.TestCase):
    def job(self, name: str) -> str:
        text = nightly_text()
        start = text.index(f"\n  {name}:")
        following = re.search(r"\n  [a-z0-9-]+:\n", text[start + 1:])
        return text[start:start + 1 + following.start()] if following else text[start:]

    def test_no_publish_step_reads_the_ring_from_the_run_snapshot(self):
        for name in ("publish-nightly", "publish-nightly-identity-legacy", "republish-nightly-deltas"):
            job = self.job(name)
            self.assertNotIn("vars.NIGHTLY_NEXT_DEV_RING", job, name)
            self.assertIn("nightly_next_dev_ring.sh --github-output", job, name)

    def test_publish_nightly_tags_from_the_live_read_before_anything_goes_out(self):
        job = self.job("publish-nightly")
        read = job.index("- name: Read the Dev ring switch live")
        self.assertIn("RING_TOKEN: ${{ steps.writer-token.outputs.token }}", job[read:read + 600])
        tag = job.index("- name: Tag the new build's items from the live Dev ring switch")
        step = job[tag:job.index("\n      - ", tag + 1)]
        self.assertIn("DEV_RING: ${{ steps.ring.outputs.mode || 'off' }}", step)
        self.assertIn('nightly_next_ring.py" retag --feed "nightly-out/$appcast"', step)
        for later in ("- name: Publish the nightly-next download to R2", "- name: Hand the published feed to the GitHub release job",
                      "- name: Upload nightly-next appcasts to R2"):
            self.assertLess(read, tag)
            self.assertLess(tag, job.index(later), later)

    def test_the_old_feed_and_the_delta_feed_use_the_live_read(self):
        for name in ("publish-nightly-identity-legacy", "republish-nightly-deltas"):
            job = self.job(name)
            self.assertIn("RING_TOKEN: ${{ steps.ring-token.outputs.token }}", job, name)
            self.assertIn("DEV_RING: ${{ steps.ring.outputs.mode || 'off' }}", job, name)
            self.assertLess(job.index("- name: Read the Dev ring switch live"), job.index("DEV_RING: ${{ steps.ring.outputs.mode"))
        # The token step mints the App without a permission filter: its Variables: read stays.
        mint = self.job("publish-nightly-identity-legacy")
        mint = mint[mint.index("name: Mint the release App token that reads the Dev ring switch"):]
        mint = mint[:mint.index("\n      - ")]
        self.assertNotIn("permission-", mint)


if __name__ == "__main__":
    unittest.main()
