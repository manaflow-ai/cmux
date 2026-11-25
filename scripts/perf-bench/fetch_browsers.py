#!/usr/bin/env python3
"""Fetch the browsers xbench.py compares, as vendor-signed copies in a worker cache.

  fetch_browsers.py [--cache DIR] NAME...   NAME: chrome edge helium ardia dia slack claude codex t3code zed cmux-nightly

Prints one `NAME=BUNDLE` line per browser it has. Each copy comes from the
vendor's own DMG (Chrome: Google's universal DMG; Edge: Microsoft's stable universal DMG; Helium and Ardia: their
latest GitHub release; Dia: diabrowser.com; cmux-nightly: the nightly-next
appcast's DMG). The agent apps rivals.py compares come the same way: Slack's universal DMG (slack.com),
Claude's universal zip (its RELEASES.json feed), Codex's DMG (OpenAI's download), T3 Code's arm64 DMG (its
latest GitHub release), Zed's arm64 DMG (its latest stable GitHub release; previews are pre-releases). Each must pass `codesign --verify --deep --strict` and is made
read-only, so an updater cannot replace it mid-run. Never the installed apps.
"""
from __future__ import annotations

import argparse
import json
import os
import platform
import plistlib
import pwd
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
    """(tag, URL) of the newest release's asset matching PATTERN, read from github.com's release pages, not the REST
    API: a bench Mac shares one address with the fleet, and the API's 60/h anonymous limit refused two of them
    (HTTP 403, cmux-ci step ae86578f9527fb43dc8ffcb2)."""
    request = urllib.request.Request(f"https://github.com/{repo}/releases/latest", headers=UA)
    with urllib.request.urlopen(request, timeout=60) as response:
        tag = response.geturl().rstrip("/").rsplit("/", 1)[-1]
    page = get(f"https://github.com/{repo}/releases/expanded_assets/{tag}").decode("utf-8", "replace")
    for path in re.findall(r'href="(/[^"]+/releases/download/[^"]+)"', page):
        if re.search(pattern, path.rsplit("/", 1)[-1]):
            return tag, "https://github.com" + path
    raise RuntimeError(f"{repo} {tag}: no asset matching {pattern}")


def source(name: str) -> tuple[str, str]:
    """(version key, DMG URL) for a browser."""
    if name == "chrome":
        return time.strftime("%Y-%m-%d"), "https://dl.google.com/chrome/mac/universal/stable/GGRO/googlechrome.dmg"
    if name == "edge":
        # Microsoft's stable channel, universal (arm64 and x86_64). linkid=2069148 is the Intel-only
        # package, which an arm64 Mac without Rosetta refuses ("incorrect executable format").
        return "universal-" + time.strftime("%Y-%m-%d"), "https://go.microsoft.com/fwlink/?linkid=2093504"
    if name == "helium":
        return github_dmg("imputnet/helium-macos", r"_arm64-macos\.dmg$")
    if name == "ardia":
        return github_dmg("mantrakp04/ardia", r"^Ardia-.*\.dmg$")
    if name == "dia":
        return time.strftime("%Y-%m-%d"), "https://releases.diabrowser.com/release/Dia-latest.dmg"
    if name == "slack":
        return time.strftime("%Y-%m-%d"), "https://slack.com/ssb/download-osx-universal"
    if name == "claude":
        feed = json.loads(get("https://downloads.claude.ai/releases/darwin/universal/RELEASES.json"))
        current = feed.get("currentRelease")
        for release in feed.get("releases") or []:
            if release.get("version") == current or current is None:
                return str(release["version"]), release["updateTo"]["url"]
        raise RuntimeError(f"claude: RELEASES.json names no release {current}")
    if name == "codex":
        return time.strftime("%Y-%m-%d"), "https://persistent.oaistatic.com/codex-app-prod/Codex.dmg"
    if name == "t3code":
        return github_dmg("pingdotgg/t3code", r"-arm64\.dmg$")
    if name == "zed":
        return github_dmg("zed-industries/zed", r"^Zed-aarch64\.dmg$")
    if name == "cmux-nightly":
        feed = get("https://files-next.cmux.com/nightly-next/appcast-arm64.xml").decode()
        url = re.search(r'enclosure url="([^"]+\.dmg)"', feed).group(1)
        return url.rsplit("-", 1)[-1].removesuffix(".dmg"), url
    raise SystemExit(f"fetch_browsers: unknown browser {name}")


def install(name: str, url: str, dest: str):
    work = tempfile.mkdtemp(prefix=f"xbench-{name}-")
    try:
        dmg = os.path.join(work, "app.dmg")
        subprocess.run(["curl", "-fsSL", "--connect-timeout", "20", "--retry", "5", "--retry-all-errors", "--retry-delay", "5",
                        "-C", "-", "-o", dmg, url], check=True, timeout=1800)
        with open(dmg, "rb") as handle:
            magic = handle.read(4)
        if magic == b"xar!":  # Edge ships a flat installer package, not a disk image
            install_pkg(name, dmg, dest, work)
            return
        if magic == b"PK\x03\x04":  # Claude ships a zip of the app
            install_zip(name, dmg, dest, work)
            return
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


def install_zip(name: str, archive: str, dest: str, work: str):
    """Unzips an app zip (ditto -x -k, as Finder does) and keeps its one app, verified and read-only as a DMG's."""
    unpacked = os.path.join(work, "zip")
    subprocess.run(["ditto", "-x", "-k", archive, unpacked], check=True, capture_output=True, timeout=900)
    apps = sorted(entry for entry in os.listdir(unpacked) if entry.endswith(".app"))
    if not apps:
        raise RuntimeError(f"{name}: no .app in the zip")
    shutil.rmtree(dest, ignore_errors=True)
    os.makedirs(dest)
    bundle = os.path.join(dest, apps[0])
    subprocess.run(["ditto", os.path.join(unpacked, apps[0]), bundle], check=True, timeout=600)
    subprocess.run(["xattr", "-cr", bundle], capture_output=True)
    verified = subprocess.run(["codesign", "--verify", "--deep", "--strict", bundle], capture_output=True, text=True)
    if verified.returncode != 0:
        raise RuntimeError(f"{name}: codesign verify failed: {verified.stderr.strip()[:300]}")
    subprocess.run(["chmod", "-R", "a-w", bundle], check=True)


def install_pkg(name: str, pkg: str, dest: str, work: str):
    """Unpacks a flat .pkg's payload (pkgutil --expand-full, no installer run, nothing in /Applications)
    and keeps its one app, verified and read-only as a DMG's."""
    expanded = os.path.join(work, "pkg")
    subprocess.run(["pkgutil", "--expand-full", pkg, expanded], check=True, capture_output=True, timeout=900)
    found = []
    for root, dirs, _files in os.walk(expanded):
        for entry in list(dirs):
            if entry.endswith(".app"):
                found.append(os.path.join(root, entry))
                dirs.remove(entry)  # an app's own helper apps are not candidates
    found.sort(key=lambda path: path.count(os.sep))
    if not found:
        raise RuntimeError(f"{name}: no .app in the package")
    shutil.rmtree(dest, ignore_errors=True)
    os.makedirs(dest)
    bundle = os.path.join(dest, os.path.basename(found[0]))
    subprocess.run(["ditto", found[0], bundle], check=True, timeout=600)
    subprocess.run(["xattr", "-cr", bundle], capture_output=True)
    verified = subprocess.run(["codesign", "--verify", "--deep", "--strict", bundle], capture_output=True, text=True)
    if verified.returncode != 0:
        raise RuntimeError(f"{name}: codesign verify failed: {verified.stderr.strip()[:300]}")
    subprocess.run(["chmod", "-R", "a-w", bundle], check=True)


def runs_here(bundle: str) -> bool:
    """Whether the bundle's main executable has a slice for this Mac's architecture (no Rosetta
    on the bench workers, so an Intel-only copy cannot launch)."""
    try:
        with open(os.path.join(bundle, "Contents", "Info.plist"), "rb") as handle:
            executable = plistlib.load(handle)["CFBundleExecutable"]
        archs = subprocess.run(["lipo", "-archs", os.path.join(bundle, "Contents", "MacOS", executable)],
                               capture_output=True, text=True, timeout=30).stdout.split()
    except Exception:  # noqa: BLE001 - unreadable means unusable
        return False
    return platform.machine() in archs


def bundle_in(dest: str) -> str | None:
    if not os.path.isdir(dest):
        return None
    apps = [entry for entry in os.listdir(dest) if entry.endswith(".app")]
    return os.path.join(dest, apps[0]) if apps else None


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("names", nargs="+")
    # The account's own home, not $HOME: fleet steps get a per-step HOME that the worker deletes
    # afterwards, and macOS App Management refuses to delete files inside an app bundle that has
    # been launched (EPERM even for its owner), so a per-step copy breaks the step's cleanup.
    home = pwd.getpwuid(os.getuid()).pw_dir
    parser.add_argument("--cache", default=os.path.join(home, "Library/Caches/cmux-perf-bench/apps"))
    args = parser.parse_args()
    for name in args.names:
        try:
            version, url = source(name)
            dest = os.path.join(args.cache, name, re.sub(r"[^A-Za-z0-9._-]", "_", version))
            bundle = bundle_in(dest)
            if bundle is not None and not runs_here(bundle):
                print(f"fetch_browsers: {name} cached copy has no {platform.machine()} slice; fetching again",
                      file=sys.stderr)
                bundle = None
                subprocess.run(["chmod", "-R", "u+w", dest], capture_output=True)
                shutil.rmtree(dest, ignore_errors=True)
            if bundle is None:
                print(f"fetch_browsers: {name} {version} from {url}", file=sys.stderr)
                parent = os.path.dirname(dest)
                if os.path.isdir(parent):  # older versions: writable again, then gone
                    subprocess.run(["chmod", "-R", "u+w", parent], capture_output=True)
                    for old in os.listdir(parent):
                        shutil.rmtree(os.path.join(parent, old), ignore_errors=True)
                install(name, url, dest)
                bundle = bundle_in(dest)
                if bundle is None or not runs_here(bundle):
                    raise RuntimeError(f"no {platform.machine()} slice in the downloaded app ({url})")
            print(f"{name}={bundle}", flush=True)
        except Exception as error:  # noqa: BLE001 - one missing browser skips its column, not the run
            print(f"fetch_browsers: {name} unavailable: {error}", file=sys.stderr)


if __name__ == "__main__":
    main()
