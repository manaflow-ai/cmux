#!/usr/bin/env python3
"""Fetch the browsers xbench.py compares, as vendor-signed copies in a worker cache.

  fetch_browsers.py [--cache DIR] NAME...   NAME: chrome helium ardia dia cmux-nightly

Prints one `NAME=BUNDLE` line per browser it has. Each copy comes from the
vendor's own DMG (Chrome: Google's universal DMG; Helium and Ardia: their
latest GitHub release; Dia: diabrowser.com; cmux-nightly: the nightly-next
appcast's DMG), must pass `codesign --verify --deep --strict` and is made
read-only, so an updater cannot replace it mid-run. Never the installed apps.
"""
from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time
import urllib.request

UA = {"User-Agent": "cmux-perf-bench (+https://github.com/manaflow-ai/cmux)"}


def get(url: str, timeout: float = 60) -> bytes:
    with urllib.request.urlopen(urllib.request.Request(url, headers=UA), timeout=timeout) as response:
        return response.read()


def github_dmg(repo: str, pattern: str) -> tuple[str, str]:
    release = json.loads(get(f"https://api.github.com/repos/{repo}/releases/latest"))
    for asset in release.get("assets", []):
        if re.search(pattern, asset["name"]):
            return release["tag_name"], asset["browser_download_url"]
    raise RuntimeError(f"{repo} {release.get('tag_name')}: no asset matching {pattern}")


def source(name: str) -> tuple[str, str]:
    """(version key, DMG URL) for a browser."""
    if name == "chrome":
        return time.strftime("%Y-%m-%d"), "https://dl.google.com/chrome/mac/universal/stable/GGRO/googlechrome.dmg"
    if name == "helium":
        return github_dmg("imputnet/helium-macos", r"_arm64-macos\.dmg$")
    if name == "ardia":
        return github_dmg("mantrakp04/ardia", r"^Ardia-.*\.dmg$")
    if name == "dia":
        return time.strftime("%Y-%m-%d"), "https://releases.diabrowser.com/release/Dia-latest.dmg"
    if name == "cmux-nightly":
        feed = get("https://files-next.cmux.com/nightly-next/next/appcast-arm64.xml").decode()
        url = re.search(r'enclosure url="([^"]+\.dmg)"', feed).group(1)
        return url.rsplit("-", 1)[-1].removesuffix(".dmg"), url
    raise SystemExit(f"fetch_browsers: unknown browser {name}")


def install(name: str, url: str, dest: str):
    work = tempfile.mkdtemp(prefix=f"xbench-{name}-")
    try:
        dmg = os.path.join(work, "app.dmg")
        subprocess.run(["curl", "-fsSL", "--retry", "3", "-o", dmg, url], check=True, timeout=1800)
        mount = os.path.join(work, "mnt")
        os.makedirs(mount)
        subprocess.run(["hdiutil", "attach", "-nobrowse", "-readonly", "-noautoopen", "-mountpoint", mount, dmg],
                       check=True, capture_output=True, timeout=300)
        try:
            apps = [entry for entry in os.listdir(mount) if entry.endswith(".app")]
            if not apps:
                raise RuntimeError(f"{name}: no .app in {url}")
            shutil.rmtree(dest, ignore_errors=True)
            os.makedirs(dest)
            subprocess.run(["ditto", os.path.join(mount, apps[0]), os.path.join(dest, apps[0])], check=True, timeout=600)
        finally:
            subprocess.run(["hdiutil", "detach", "-force", mount], capture_output=True, timeout=120)
        bundle = os.path.join(dest, apps[0])
        subprocess.run(["xattr", "-cr", bundle], capture_output=True)
        verified = subprocess.run(["codesign", "--verify", "--deep", "--strict", bundle], capture_output=True, text=True)
        if verified.returncode != 0:
            raise RuntimeError(f"{name}: codesign verify failed: {verified.stderr.strip()[:300]}")
        subprocess.run(["chmod", "-R", "a-w", bundle], check=True)
    finally:
        shutil.rmtree(work, ignore_errors=True)


def bundle_in(dest: str) -> str | None:
    if not os.path.isdir(dest):
        return None
    apps = [entry for entry in os.listdir(dest) if entry.endswith(".app")]
    return os.path.join(dest, apps[0]) if apps else None


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("names", nargs="+")
    parser.add_argument("--cache", default=os.path.expanduser("~/Library/Caches/cmux-perf-bench/apps"))
    args = parser.parse_args()
    for name in args.names:
        try:
            version, url = source(name)
            dest = os.path.join(args.cache, name, re.sub(r"[^A-Za-z0-9._-]", "_", version))
            bundle = bundle_in(dest)
            if bundle is None:
                print(f"fetch_browsers: {name} {version} from {url}", file=sys.stderr)
                parent = os.path.dirname(dest)
                if os.path.isdir(parent):  # older versions: writable again, then gone
                    subprocess.run(["chmod", "-R", "u+w", parent], capture_output=True)
                    for old in os.listdir(parent):
                        shutil.rmtree(os.path.join(parent, old), ignore_errors=True)
                install(name, url, dest)
                bundle = bundle_in(dest)
            print(f"{name}={bundle}", flush=True)
        except Exception as error:  # noqa: BLE001 - one missing browser skips its column, not the run
            print(f"fetch_browsers: {name} unavailable: {error}", file=sys.stderr)


if __name__ == "__main__":
    main()
