#!/usr/bin/env python3
"""Download the newest cmux NEXT NIGHTLY DMG from the feed, the build a person installs.

  nightly.py OUT_DIR [--feed URL] [--build N]   prints "BUILD URL PATH" and exits 0

The feed is the one the app updates from (nightly-next-launch-smoke.yml reads the same). The DMG's
own signature and notarization are what Gatekeeper checks in the guest when the person opens it,
so a damaged download fails there, in the run, as it would for a person.
"""
import argparse, os, re, shutil, sys, urllib.request

FEED = "https://files-next.cmux.com/nightly-next/next/appcast-arm64.xml"
UA = {"User-Agent": "cmux-onboarding-e2e"}

p = argparse.ArgumentParser()
p.add_argument("out")
p.add_argument("--feed", default=FEED)
p.add_argument("--build", help="this feed build (digits) instead of the newest")
a = p.parse_args()
xml = urllib.request.urlopen(urllib.request.Request(a.feed, headers=UA), timeout=30).read().decode()
items = []
for item in re.findall(r"<item>.*?</item>", xml, re.S):
    build = re.search(r"<sparkle:version>(.*?)<", item) or re.search(r'sparkle:version="([^"]+)"', item)
    url = re.search(r'<enclosure[^>]*url="([^"]+\.dmg)"', item)
    if build and url:
        items.append((build.group(1), url.group(1)))
if not items:
    sys.exit("no DMG in the feed")
if a.build:
    items = [i for i in items if i[0] == a.build] or sys.exit(f"build {a.build} is not in the feed")
build, url = max(items, key=lambda i: int(i[0]) if i[0].isdigit() else 0)
os.makedirs(a.out, exist_ok=True)
path = os.path.join(a.out, "cmux-NEXT-nightly.dmg")
with urllib.request.urlopen(urllib.request.Request(url, headers=UA), timeout=900) as r, open(path, "wb") as f:
    shutil.copyfileobj(r, f, 1 << 20)
print(build, url, path)
