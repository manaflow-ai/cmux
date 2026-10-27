#!/usr/bin/env python3
"""live_appcast_build.py reads the newest build an appcast lists, and the
classic publication guards refuse a build older than the live feed's."""

from __future__ import annotations

import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts" / "ci" / "live_appcast_build.py"
WORKFLOW = (ROOT / ".github" / "workflows" / "auto-resume-nightly-notarization.yml").read_text(encoding="utf-8")

FEED = """<?xml version="1.0"?>
<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" version="2.0"><channel>
<item><title>new</title><sparkle:version>2026102712345601</sparkle:version></item>
<item><title>old</title><enclosure url="x" sparkle:version="2026102612345601"/></item>
</channel></rss>
"""


def run(source: str) -> subprocess.CompletedProcess[str]:
    return subprocess.run([sys.executable, str(SCRIPT), source], capture_output=True, text=True, check=False)


def test_reads_the_newest_build() -> None:
    with tempfile.NamedTemporaryFile("w", suffix=".xml", delete=False) as feed:
        feed.write(FEED)
    out = run(feed.name)
    assert out.returncode == 0 and out.stdout.strip() == "2026102712345601", out


def test_an_unreadable_or_empty_feed_is_unknown() -> None:
    assert run("/nonexistent/appcast.xml").returncode == 1
    with tempfile.NamedTemporaryFile("w", suffix=".xml", delete=False) as feed:
        feed.write("<rss><channel></channel></rss>")
    assert run(feed.name).returncode == 1


def test_the_publication_guards_read_the_live_feed() -> None:
    assert "(( live_build > NIGHTLY_BUILD ))" in WORKFLOW
    assert 'live_appcast_build.py "https://files.cmux.com/${RELEASE_TAG}/appcast-arm64.xml"' in WORKFLOW
    assert '[ "$live_build" != "$own_build" ]' in WORKFLOW


if __name__ == "__main__":
    for name, value in list(globals().items()):
        if name.startswith("test_"):
            value()
    print("PASS: live appcast build guard")
