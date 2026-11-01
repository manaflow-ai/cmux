#!/usr/bin/env python3
"""The cmux-next track guard refuses every path into main's NIGHTLY.

Runs scripts/ci/nightly-next-guard.py with the environment nightly.yml sets
and checks that it allows the cmux-next feed, appcast and objects and refuses
main's feeds, main's bucket and other release downloads.
"""

import importlib.util
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
# The feed's own R2 base serves the downloads too (publish-nightly-next-r2.py), never main's.
R2 = f"{base}/"
expect(0, "appcast", appcast(f"{R2}cmux-nightly-next-macos-arm64-123.dmg",
                             f"{NEXT}cmux-nightly-next-macos-arm64-120.dmg",
                             f"{R2}cmux-nightly-next-macos-arm64-123-120.delta"))
expect(1, "appcast", appcast(f"{R2}cmux-nightly-macos-arm64-123.dmg"))
expect(1, "appcast", appcast(f"{R2}notes/cmux-nightly-next-macos-arm64-123.dmg"))
expect(1, "appcast", appcast("https://files.cmux.com/nightly/cmux-nightly-next-macos-arm64-123.dmg"))
expect(1, "appcast", appcast("https://files.cmux.com/nightly/cmux-nightly-next-macos-arm64-123.dmg"),
       env={**ENV, "NIGHTLY_NEXT_FEED_BASE": "https://files.cmux.com/nightly"})
expect(1, "appcast", appcast(f"{NEXT}cmux-nightly-next-macos-arm64-123.dmg",
                             f"{MAIN}cmux-nightly-macos-arm64-120.dmg"))
expect(1, "appcast", appcast(f"{NEXT}cmux-nightly-macos-arm64-123.dmg"))
expect(1, "appcast", appcast())
# Untagged or differently tagged items would be offered to main's NIGHTLY.
expect(1, "appcast", appcast(f"{NEXT}cmux-nightly-next-macos-arm64-123.dmg", channel=None))
expect(1, "appcast", appcast(f"{NEXT}cmux-nightly-next-macos-arm64-123.dmg", channel="nightly"))
expect(1, "appcast", appcast(f"{NEXT}cmux-nightly-next-macos-arm64-123.dmg", channel="cmux-next-beta"))
# Every release ring's tag is a cmux-next tag (UpdateRing.sparkleChannel).
for ring in ("cmux-next", "cmux-next-dev", "cmux-next-canary", "cmux-next-stable"):
    expect(0, "appcast", appcast(f"{NEXT}cmux-nightly-next-macos-arm64-123.dmg", channel=ring))
# One tag per item: Sparkle reads only the first.
expect(1, "appcast", appcast(f"{NEXT}cmux-nightly-next-macos-arm64-123.dmg",
                             channel="cmux-next</sparkle:channel><sparkle:channel>cmux-next-dev"))

# The guard, the ring script and the app name the same tags.
guard_tags = re.search(r"^NEXT_SPARKLE_CHANNELS = \(([^)]*)\)$", GUARD.read_text(), re.MULTILINE)
ring_spec = importlib.util.spec_from_file_location("nightly_next_ring", ROOT / "scripts" / "ci" / "nightly_next_ring.py")
ring_module = importlib.util.module_from_spec(ring_spec)
ring_spec.loader.exec_module(ring_module)
swift = (ROOT / "Packages" / "macOS" / "CmuxUpdater" / "Sources" / "CmuxUpdater" / "UpdateRing.swift")
app_tags = set(re.findall(r'case \.\w+: "(cmux-next[^"]*)"', swift.read_text()))
resolver = (swift.parent / "UpdateFeedResolver.swift").read_text()
app_tags |= set(re.findall(r'nightlyNextSparkleChannel = "([^"]+)"', resolver))
if not guard_tags:
    failures.append("NEXT_SPARKLE_CHANNELS not found in the guard")
else:
    guard_set = set(re.findall(r'"([^"]+)"', guard_tags.group(1)))
    ring_set = set(ring_module.RING_CHANNELS)
    if not (guard_set == ring_set == app_tags) or len(app_tags) != 4:
        failures.append(f"ring tags differ: guard {guard_set}, ring script {ring_set}, app {app_tags}")

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
