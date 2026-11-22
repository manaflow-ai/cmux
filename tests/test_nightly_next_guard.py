#!/usr/bin/env python3
"""The cmux-next track guard refuses every path into main's NIGHTLY.

Runs scripts/ci/nightly-next-guard.py with the environment nightly.yml sets
and checks that it allows the cmux-next feed, appcast and objects and refuses
main's feeds, main's bucket and other release downloads.
"""

import os
import re
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
GUARD = ROOT / "scripts" / "ci" / "nightly-next-guard.py"
WORKFLOW = ROOT / ".github" / "workflows" / "nightly.yml"


def workflow_env():
    text = WORKFLOW.read_text()
    env = {}
    for name in ("NIGHTLY_NEXT_FEED_BASE", "NIGHTLY_NEXT_R2_BUCKET", "NIGHTLY_NEXT_R2_PREFIX"):
        match = re.search(rf"^  {name}: (\S+)$", text, re.MULTILINE)
        assert match, f"nightly.yml must set {name} at workflow level"
        env[name] = match.group(1)
    return env


ENV = {**os.environ, **workflow_env()}


def guard(*args, env=None):
    return subprocess.run([sys.executable, str(GUARD), *args], env=env or ENV,
                          capture_output=True, text=True).returncode


def appcast(*urls, channel="cmux-next"):
    tag = f"<sparkle:channel>{channel}</sparkle:channel>" if channel else ""
    items = "".join(
        f'<item>{tag}<enclosure url="{u}" sparkle:version="1"/></item>' for u in urls)
    handle = tempfile.NamedTemporaryFile("w", suffix=".xml", delete=False)
    handle.write('<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">'
                 f"<channel>{items}</channel></rss>")
    handle.close()
    return handle.name


NEXT = "https://github.com/manaflow-ai/cmux/releases/download/nightly-next/"
MAIN = "https://github.com/manaflow-ai/cmux/releases/download/nightly/"
failures = []


def expect(code, *args, env=None):
    got = guard(*args, env=env)
    if got != code:
        failures.append(f"{args}: exit {got}, want {code}")


base = ENV["NIGHTLY_NEXT_FEED_BASE"]
expect(0, "feed-url", f"{base}/appcast.xml")
expect(0, "feed-url", f"{base}/appcast-arm64.xml")
expect(1, "feed-url", "https://files.cmux.com/nightly/appcast.xml")
expect(1, "feed-url", "https://files.cmux.com/nightly/appcast-arm64.xml")
expect(1, "feed-url", "https://files.cmux.com/rc/appcast.xml")
expect(1, "feed-url", "https://github.com/manaflow-ai/cmux/releases/latest/download/appcast.xml")
# A workflow edit that points the base at main's feed is refused too.
expect(1, "feed-url", "https://files.cmux.com/nightly/appcast.xml",
       env={**ENV, "NIGHTLY_NEXT_FEED_BASE": "https://files.cmux.com/nightly"})

expect(0, "appcast", appcast(f"{NEXT}cmux-nightly-next-macos-arm64-123.dmg",
                             f"{NEXT}cmux-nightly-next-macos-arm64-123-120.delta"))
expect(1, "appcast", appcast(f"{MAIN}cmux-nightly-macos-arm64-123.dmg"))
expect(1, "appcast", appcast(f"{NEXT}cmux-nightly-next-macos-arm64-123.dmg",
                             f"{MAIN}cmux-nightly-macos-arm64-120.dmg"))
expect(1, "appcast", appcast(f"{NEXT}cmux-nightly-macos-arm64-123.dmg"))
expect(1, "appcast", appcast())
# Untagged or differently tagged items would be offered to main's NIGHTLY.
expect(1, "appcast", appcast(f"{NEXT}cmux-nightly-next-macos-arm64-123.dmg", channel=None))
expect(1, "appcast", appcast(f"{NEXT}cmux-nightly-next-macos-arm64-123.dmg", channel="nightly"))

bucket, prefix = ENV["NIGHTLY_NEXT_R2_BUCKET"], ENV["NIGHTLY_NEXT_R2_PREFIX"]
expect(0, "r2-key", bucket, f"{prefix}appcast.xml")
expect(1, "r2-key", "cmux-binaries", "nightly/appcast.xml")
expect(1, "r2-key", "cmux-binaries", f"{prefix}appcast.xml")
expect(1, "r2-key", bucket, "nightly/appcast.xml")
expect(1, "r2-key", bucket, f"{prefix}../nightly/appcast.xml")

if failures:
    print("FAIL: nightly-next guard\n  " + "\n  ".join(failures))
    sys.exit(1)
print("PASS: nightly-next guard")
