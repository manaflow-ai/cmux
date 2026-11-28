#!/usr/bin/env python3
"""Download the newest immutable nightly DMGs of one track for Sparkle delta generation.

    fetch-previous-nightly-dmgs.py --repo manaflow-ai/cmux --release-tag nightly \
        --variant arm64 --exclude-build 3371353821401 --count 2 --out previous-nightlies

Assets are matched by name (cmux-nightly-macos-<variant>-<build>.dmg), ordered by
build number, and the newest <count> below --exclude-build are downloaded by the
asset API URL from that same listing, then checked against the listed digest.
`gh release download --pattern` is not used: it resolves names against the REST
release object, whose embedded asset list is incomplete on a release holding
~1000 assets, so a DMG present in the paginated listing could be "not found".

Deltas are optional. No matching asset, a failed download, or a digest mismatch
skips that build with a warning; the publish ships without that delta.
"""
from __future__ import annotations

import argparse
import hashlib
import json
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
    parser.add_argument("--out", required=True)
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
    out = Path(args.out)
    out.mkdir(parents=True, exist_ok=True)
    fetched = 0
    for build, asset in chosen:
        name = asset["name"]
        print(f"downloading previous {args.variant} build {build}: {name}")
        if download_asset(asset, out / name):
            fetched += 1
    print(f"fetched {fetched} of {len(chosen)} previous {args.variant} build(s) into {out}")
    return 0


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
