#!/usr/bin/env python3
"""The cmux NEXT NIGHTLY a person installs: pick it from the feed and download its DMG.

  nightly.py --resolve [--build N]     prints the build number only (os-matrix.sh keys its step on it)
  nightly.py OUT_DIR [--build N]       downloads it and prints "BUILD URL PATH"

The pick is the launch smoke's (scripts/ci/nightly_next_launch_smoke.py `pick`, copied here because
the Tart host runs only this reviewed runner directory): the newest item offered to Nightly apps
(never a Dev-ring or Canary-only build), its DMG under a nightly-next download prefix, and the
downloaded size must be the feed's length. The host never opens the DMG (vm.sh copies it into the
guest unopened for this suite); the guest's Gatekeeper checks its signature and notarization when
the person opens it, so a bad download fails in the run, as it would for a person.
"""
import argparse, os, re, shutil, sys, urllib.request

FEED = "https://files-next.cmux.com/nightly-next/next/appcast-arm64.xml"
UA = {"User-Agent": "cmux-onboarding-e2e"}
ITEM = re.compile(r"<item>.*?</item>", re.S)
VERSION = re.compile(r"<sparkle:version>\s*(\d+)\s*</sparkle:version>")
CHANNEL = re.compile(r"<sparkle:channel>\s*([^<]*?)\s*</sparkle:channel>")
NIGHTLY_CHANNELS = (None, "cmux-next-stable", "cmux-next")
ENCLOSURE = re.compile(r'<enclosure\s[^>]*?url="([^"]+\.dmg)"[^>]*?length="(\d+)"[^>]*>')
DMG_PREFIXES = ("https://github.com/manaflow-ai/cmux/releases/download/nightly-next/",
                "https://files-next.cmux.com/nightly-next/next/")


def pick(text, wanted=""):
    items = []
    for item in ITEM.findall(text):
        version, enclosure, channel = VERSION.search(item), ENCLOSURE.search(item), CHANNEL.search(item)
        if version and enclosure:
            offered = (channel.group(1) if channel else None) in NIGHTLY_CHANNELS
            items.append((int(version.group(1)), enclosure.group(1), int(enclosure.group(2)), offered))
    if wanted:
        items = [i for i in items if str(i[0]) == wanted]
        if items and not items[0][3]:
            sys.exit(f"build {wanted} is not offered to Nightly apps (a Dev or Canary ring build)")
    items = [i for i in items if i[3]]
    if not items:
        sys.exit("no Nightly feed item" + (f" for build {wanted}" if wanted else " with a DMG"))
    build, url, length, _ = max(items)
    if not url.startswith(DMG_PREFIXES):
        sys.exit(f"{url} is not a nightly-next download")
    return build, url, length


p = argparse.ArgumentParser()
p.add_argument("out", nargs="?")
p.add_argument("--resolve", action="store_true")
p.add_argument("--build", default="", help="this feed build (digits) instead of the newest")
p.add_argument("--feed", default=FEED)
a = p.parse_args()
if a.build and not a.build.isdigit():
    sys.exit("--build takes digits")
feed = urllib.request.urlopen(urllib.request.Request(a.feed, headers=UA), timeout=30).read().decode()
build, url, length = pick(feed, a.build)
if a.resolve:
    print(build)
    sys.exit(0)
if not a.out:
    sys.exit("nightly.py OUT_DIR or --resolve")
os.makedirs(a.out, exist_ok=True)
path = os.path.join(a.out, f"cmux-NEXT-{build}.dmg")
with urllib.request.urlopen(urllib.request.Request(url, headers=UA), timeout=900) as r, open(path, "wb") as f:
    shutil.copyfileobj(r, f, 1 << 20)
if os.path.getsize(path) != length:
    sys.exit(f"downloaded {os.path.getsize(path)} bytes, the feed says {length}")
print(build, url, path)
