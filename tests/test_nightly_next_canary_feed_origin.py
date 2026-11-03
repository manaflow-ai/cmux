"""The nightly-next canary takes the newest build from the feed's own origin.

Since #25656 the cmux NEXT feed's enclosures point at its R2 origin
(files-next.cmux.com/nightly-next/next/), and the GitHub release copy follows
later. The canary's pick refused every URL that was not a GitHub release
asset, so from 2026-10-27 05:24Z every scheduled canary failed at "Read the
feed". No build got a verdict and none moved from Dev (cmux-next-dev) to
Nightly (cmux-next), so the NIGHTLY app was offered nothing new. This test runs
the pick's own script against feeds of each shape.
"""

import pathlib
import re
import subprocess
import sys
import tempfile
import textwrap
import unittest

WORKFLOW = pathlib.Path(__file__).resolve().parents[1] / ".github/workflows/nightly-next-canary.yml"
R2 = "https://files-next.cmux.com/nightly-next/next/"
GITHUB = "https://github.com/manaflow-ai/cmux/releases/download/nightly-next/"


def pick_script() -> str:
    text = WORKFLOW.read_text(encoding="utf-8")
    match = re.search(r"python3 - feed\.xml \"\$BUILD\" >> \"\$GITHUB_OUTPUT\" <<'PY'\n(.*?)\n\s*PY\n", text, re.S)
    if not match:
        raise AssertionError("the canary's Read the feed step no longer has its inline pick script")
    return textwrap.dedent(match.group(1))


def item(build: int, url: str, channel: str = "cmux-next-dev") -> str:
    return (f"<item><sparkle:version>{build}</sparkle:version><sparkle:channel>{channel}</sparkle:channel>"
            f'<enclosure url="{url}cmux-nightly-next-macos-arm64-{build}.dmg" length="123" type="application/octet-stream"/></item>')


def run_pick(items: list[str], wanted: str = "") -> subprocess.CompletedProcess[str]:
    with tempfile.TemporaryDirectory() as tmp:
        feed = pathlib.Path(tmp, "feed.xml")
        feed.write_text("<rss><channel>" + "".join(items) + "</channel></rss>", encoding="utf-8")
        return subprocess.run([sys.executable, "-I", "-", str(feed), wanted], input=pick_script(),
                              capture_output=True, text=True, check=False)


class CanaryFeedOrigin(unittest.TestCase):
    def test_r2_origin_newest_build_is_picked(self) -> None:
        result = run_pick([item(4038033920301, GITHUB, "cmux-next"), item(4045248345901, R2)])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("build=4045248345901", result.stdout)
        self.assertIn(f"url={R2}cmux-nightly-next-macos-arm64-4045248345901.dmg", result.stdout)

    def test_github_release_asset_still_accepted(self) -> None:
        result = run_pick([item(4038033920301, GITHUB, "cmux-next")])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("build=4038033920301", result.stdout)

    def test_requested_build_is_found_on_r2(self) -> None:
        result = run_pick([item(4045227375101, R2), item(4045248345901, R2)], "4045227375101")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("build=4045227375101", result.stdout)

    def test_other_origins_are_refused(self) -> None:
        for url in ("https://files-next.cmux.com/other/", "https://example.com/nightly-next/next/",
                    "https://files-next.cmux.com.example.com/nightly-next/next/"):
            result = run_pick([item(4045248345901, url)])
            self.assertNotEqual(result.returncode, 0, url)


if __name__ == "__main__":
    unittest.main()
