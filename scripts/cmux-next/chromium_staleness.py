#!/usr/bin/env python3
"""Warns when cmux-next's pinned Chromium is more than one stable release behind Chrome.

cmux-next ships its own Chromium (the CEF fork pinned in
scripts/cmux-next/cef-manifest.json, field "chromium"). Chrome's stable channel
gets a new major release about every four weeks, and most security fixes ship
only on the newest one. This check compares the pinned major with the newest
Chrome stable for macOS (Google's Version History API) and fails when the pin
is more than ``--max-behind`` majors behind (default 1: the newest stable or the
one before it passes).

    python3 scripts/cmux-next/chromium_staleness.py [--manifest PATH]
        [--max-behind N] [--stable-json PATH]

Exit codes: 0 current enough, 1 stale (report on stdout), 3 the stable version
could not be read (network; reported, the workflow treats it as no verdict).
The workflow (.github/workflows/cmux-next-chromium-staleness.yml) keeps one
issue up to date instead of a red check. The fix is a fork rebase and a new
pin (plans/cmux-next/browser.md, "Chromium security updates"), never a change
here.
"""
from __future__ import annotations

import argparse
import json
import sys
import urllib.request
from pathlib import Path

STABLE_URL = (
    "https://versionhistory.googleapis.com/v1/chrome/platforms/mac/channels/stable/versions"
    "?pageSize=20"
)
DEFAULT_MANIFEST = Path(__file__).resolve().parent / "cef-manifest.json"


def parse_version(text: str) -> tuple[int, int, int, int]:
    parts = text.strip().split(".")
    if len(parts) != 4 or not all(p.isdigit() for p in parts):
        raise ValueError(f"not a Chromium version: {text!r}")
    return tuple(int(p) for p in parts)  # type: ignore[return-value]


def newest_stable(payload: dict) -> str:
    """The highest version in a Version History API answer."""
    versions = [v["version"] for v in payload.get("versions", []) if "version" in v]
    if not versions:
        raise ValueError("the stable channel lists no versions")
    return max(versions, key=parse_version)


def verdict(pinned: str, stable: str, max_behind: int = 1) -> tuple[bool, str]:
    """(stale, report) for a pinned Chromium against the newest Chrome stable."""
    pin, top = parse_version(pinned), parse_version(stable)
    behind = top[0] - pin[0]
    if behind > max_behind:
        return True, (
            f"cmux-next pins Chromium {pinned}, {behind} stable releases behind Chrome "
            f"{stable} (allowed: {max_behind}). Security fixes since Chromium {pin[0]} "
            f"are not in cmux-next's browser."
        )
    if behind <= 0:
        note = "the newest stable major"
    else:
        note = f"{behind} stable release behind Chrome {stable}, within the allowed {max_behind}"
    return False, f"cmux-next pins Chromium {pinned}: {note}."


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--manifest", type=Path, default=DEFAULT_MANIFEST)
    parser.add_argument("--max-behind", type=int, default=1)
    parser.add_argument("--stable-json", type=Path, help="a saved API answer (tests)")
    args = parser.parse_args(argv)

    pinned = json.loads(args.manifest.read_text())["chromium"]
    try:
        if args.stable_json:
            payload = json.loads(args.stable_json.read_text())
        else:
            req = urllib.request.Request(STABLE_URL, headers={"User-Agent": "cmux-chromium-staleness"})
            with urllib.request.urlopen(req, timeout=30) as resp:
                payload = json.load(resp)
        stable = newest_stable(payload)
    except Exception as error:  # noqa: BLE001: any failure here is "no verdict"
        print(f"cannot read the Chrome stable version: {error}")
        return 3
    stale, report = verdict(pinned, stable, args.max_behind)
    print(report)
    return 1 if stale else 0


if __name__ == "__main__":
    sys.exit(main())
