#!/usr/bin/env python3
"""Fails when the Chromium cmux-next ships is too old.

Reads the pinned Chromium version from scripts/cmux-next/cef-manifest.json and
the latest Chrome stable version for macOS (Google's version history API, or
--stable for tests and offline runs). The pin may be at most one stable
milestone behind: Chrome stable 157 accepts Chromium 156 or newer. Chrome's
security fixes ship in stable first; a pin two milestones behind lacks them
(the pwn.ai GPU sandbox escape, CVE-2026-106378, was fixed in 155 while cmux
shipped 154).

A pin may also carry backported fixes ("backports": ["CVE-..."]) in the
manifest; they are printed, never counted as currency.

Exit 0: current enough. Exit 1: too old. Exit 2: the check could not run.
"""
import argparse
import json
import pathlib
import sys
import urllib.request

API = "https://versionhistory.googleapis.com/v1/chrome/platforms/mac/channels/stable/versions?pageSize=1"


def major(version: str) -> int:
    return int(version.split(".", 1)[0])


def latest_stable(timeout: float) -> str:
    with urllib.request.urlopen(API, timeout=timeout) as response:
        data = json.load(response)
    return data["versions"][0]["version"]


def main() -> int:
    root = pathlib.Path(__file__).resolve().parent
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--manifest", default=str(root / "cef-manifest.json"))
    parser.add_argument("--stable", help="latest Chrome stable version (default: ask Google's API)")
    parser.add_argument("--allowed-behind", type=int, default=1)
    parser.add_argument("--timeout", type=float, default=20)
    args = parser.parse_args()

    try:
        manifest = json.loads(pathlib.Path(args.manifest).read_text())
        pinned = manifest["chromium"]
        stable = args.stable or latest_stable(args.timeout)
        behind = major(stable) - major(pinned)
    except Exception as error:  # noqa: BLE001 - report any input failure the same way
        print(f"check-chromium-currency: cannot check: {error}", file=sys.stderr)
        return 2

    backports = manifest.get("backports") or []
    print(f"pinned Chromium {pinned} ({manifest.get('version', '?')}), Chrome stable {stable}: {max(behind, 0)} milestone(s) behind")
    if backports:
        print("backported fixes: " + ", ".join(backports))
    if behind > args.allowed_behind:
        print(
            f"FAIL: Chromium {pinned} is {behind} milestones behind stable {stable} "
            f"(at most {args.allowed_behind} allowed). Move the CEF fork to a newer Chromium branch.",
            file=sys.stderr,
        )
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
