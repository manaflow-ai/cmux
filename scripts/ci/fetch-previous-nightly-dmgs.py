#!/usr/bin/env python3
"""Download the newest immutable nightly DMGs of one track for Sparkle delta generation.

    fetch-previous-nightly-dmgs.py --repo manaflow-ai/cmux --release-tag nightly \
        --variant arm64 --exclude-build 3371353821401 --count 2 --out previous-nightlies

Assets are matched by name (cmux-nightly-macos-<variant>-<build>.dmg), ordered by
build number, and the newest <count> below --exclude-build are chosen. Each
--older-than-hours H adds the newest build uploaded at least H hours ago (when
it is not chosen yet), so a Mac that was offline for a day still finds a delta.
The chosen builds are downloaded by the asset API URL from that same listing,
then checked against the listed digest.
--dates-out FILE writes {"<build>": "<upload time, ISO 8601>"} for every fetched
build, and each DMG's modification time is set to that upload time:
generate_appcast dates an item by its archive's mtime, so without this every
earlier item would get the time of this delta run (scripts/ci/appcast_keep_pubdates.py).
`gh release download --pattern` is not used: it resolves names against the REST
release object, whose embedded asset list is incomplete on a release holding
~1000 assets, so a DMG present in the paginated listing could be "not found".

Deltas are optional. No matching asset, a failed download, or a digest mismatch
skips that build with a warning; the publish ships without that delta.
"""
from __future__ import annotations

import argparse
from datetime import datetime, timedelta, timezone
import hashlib
import json
import os
import re
import subprocess
import sys
from pathlib import Path


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("--repo", required=True)
    parser.add_argument("--release-tag", required=True)
    parser.add_argument("--variant", required=True)
    parser.add_argument(
        "--name-prefix",
        default="cmux-nightly-macos-",
        help="Immutable DMG name prefix before <variant>-<build>.dmg (e.g. cmux-rc-macos-)",
    )
    parser.add_argument("--exclude-build", type=int, default=0)
    parser.add_argument("--count", type=int, default=2)
    parser.add_argument("--older-than-hours", type=float, action="append", default=[])
    parser.add_argument("--out", required=True)
    parser.add_argument("--dates-out", help="JSON file mapping each fetched build to its upload time")
    args = parser.parse_args()

    pattern = re.compile(
        rf"^{re.escape(args.name_prefix)}{re.escape(args.variant)}-(?P<build>\d+)\.dmg$"
    )
    proc = subprocess.run(
        ["gh", "release", "view", args.release_tag, "--repo", args.repo, "--json", "assets"],
        capture_output=True,
        text=True,
    )
    if proc.returncode != 0:
        print(f"warning: could not list release assets: {proc.stderr.strip()}", file=sys.stderr)
        return 0
    candidates: list[tuple[int, dict]] = []
    for asset in json.loads(proc.stdout or "{}").get("assets", []):
        match = pattern.match(asset["name"])
        if not match or asset.get("state", "uploaded") != "uploaded":
            continue
        build = int(match.group("build"))
        if args.exclude_build and build >= args.exclude_build:
            continue
        candidates.append((build, asset))
    candidates.sort(key=lambda item: item[0], reverse=True)
    chosen = candidates[: args.count]
    now = datetime.now(timezone.utc)
    for hours in sorted(args.older_than_hours):
        cutoff = now - timedelta(hours=hours)
        older = next((c for c in candidates if uploaded_at(c[1]) and uploaded_at(c[1]) <= cutoff), None)
        if older and older not in chosen:
            chosen.append(older)
    out = Path(args.out)
    out.mkdir(parents=True, exist_ok=True)
    fetched = 0
    dates: dict[str, str] = {}
    for build, asset in chosen:
        name = asset["name"]
        print(f"downloading previous {args.variant} build {build}: {name}")
        if download_asset(asset, out / name):
            fetched += 1
            uploaded = uploaded_at(asset)
            if uploaded:
                os.utime(out / name, (uploaded.timestamp(), uploaded.timestamp()))
                dates[str(build)] = uploaded.isoformat()
    if args.dates_out:
        Path(args.dates_out).write_text(json.dumps(dates, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    print(f"fetched {fetched} of {len(chosen)} previous {args.variant} build(s) into {out}")
    return 0


def uploaded_at(asset: dict) -> datetime | None:
    try:
        return datetime.fromisoformat(asset["createdAt"].replace("Z", "+00:00"))
    except (KeyError, AttributeError, ValueError):
        return None


def download_asset(asset: dict, destination: Path) -> bool:
    """Download one listed asset by its API URL; keep it only if the digest matches."""
    name = asset["name"]
    api_url = asset.get("apiUrl")
    if not api_url:
        print(f"warning: skipping {name}: the listing has no asset API URL", file=sys.stderr)
        return False
    partial = destination.with_name(f".{destination.name}.partial")
    try:
        with partial.open("wb") as stream:
            proc = subprocess.run(
                ["gh", "api", "-H", "Accept: application/octet-stream", api_url],
                stdout=stream,
                stderr=subprocess.PIPE,
                text=False,
            )
        if proc.returncode != 0:
            detail = proc.stderr.decode("utf-8", errors="replace").strip()
            print(f"warning: skipping {name}: download failed: {detail}", file=sys.stderr)
            return False
        expected = asset.get("digest") or ""
        if expected.startswith("sha256:"):
            hasher = hashlib.sha256()
            with partial.open("rb") as stream:
                for block in iter(lambda: stream.read(1 << 20), b""):
                    hasher.update(block)
            actual = "sha256:" + hasher.hexdigest()
            if actual != expected:
                print(f"warning: skipping {name}: digest {actual} does not match listed {expected}", file=sys.stderr)
                return False
        partial.replace(destination)
        return True
    finally:
        partial.unlink(missing_ok=True)


if __name__ == "__main__":
    sys.exit(main())
