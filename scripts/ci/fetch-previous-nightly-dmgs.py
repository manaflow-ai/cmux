#!/usr/bin/env python3
"""Download the newest immutable nightly DMGs of one track for Sparkle delta generation.

    fetch-previous-nightly-dmgs.py --repo manaflow-ai/cmux --release-tag nightly \
        --variant arm64 --exclude-build 3371353821401 --count 2 --out previous-nightlies

Assets are matched by name (cmux-nightly-macos-<variant>-<build>.dmg), ordered by
build number, and the newest <count> below --exclude-build are downloaded with
`gh release download`. No matching asset is not an error: the first per-track
publish simply ships without deltas.
"""
from __future__ import annotations

import argparse
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
    parser.add_argument("--exclude-build", type=int, default=0)
    parser.add_argument("--count", type=int, default=2)
    parser.add_argument("--out", required=True)
    args = parser.parse_args()

    pattern = re.compile(rf"^cmux-nightly-macos-{re.escape(args.variant)}-(?P<build>\d+)\.dmg$")
    proc = subprocess.run(
        ["gh", "release", "view", args.release_tag, "--repo", args.repo, "--json", "assets"],
        capture_output=True,
        text=True,
    )
    if proc.returncode != 0:
        print(f"warning: could not list release assets: {proc.stderr.strip()}", file=sys.stderr)
        return 0
    candidates: list[tuple[int, str]] = []
    for asset in json.loads(proc.stdout or "{}").get("assets", []):
        match = pattern.match(asset["name"])
        if not match:
            continue
        build = int(match.group("build"))
        if args.exclude_build and build >= args.exclude_build:
            continue
        candidates.append((build, asset["name"]))
    candidates.sort(reverse=True)
    chosen = candidates[: args.count]
    out = Path(args.out)
    out.mkdir(parents=True, exist_ok=True)
    for build, name in chosen:
        print(f"downloading previous {args.variant} build {build}: {name}")
        subprocess.run(
            ["gh", "release", "download", args.release_tag, "--repo", args.repo, "--pattern", name, "--dir", str(out), "--clobber"],
            check=True,
        )
    print(f"fetched {len(chosen)} previous {args.variant} build(s) into {out}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
