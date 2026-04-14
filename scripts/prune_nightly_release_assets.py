#!/usr/bin/env python3

import argparse
import json
import subprocess
import sys
from collections import defaultdict
from dataclasses import dataclass
import re


IMMUTABLE_ASSET_PATTERNS = [
    re.compile(r"^cmux-nightly-macos-(?P<build>\d+)\.dmg$"),
    re.compile(r"^cmux-nightly-universal-macos-(?P<build>\d+)\.dmg$"),
    re.compile(r"^cmuxd-remote-(?:darwin-arm64|darwin-amd64|linux-arm64|linux-amd64)-(?P<build>\d+)$"),
    re.compile(r"^cmuxd-remote-checksums-(?P<build>\d+)\.txt$"),
    re.compile(r"^cmuxd-remote-manifest-(?P<build>\d+)\.json$"),
]


@dataclass(frozen=True)
class ReleaseAsset:
    asset_id: int
    name: str
    build: int


def log(message: str) -> None:
    print(message, flush=True)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Prune old immutable assets from the nightly GitHub release."
    )
    parser.add_argument("--repo", required=True, help="owner/repo, for example manaflow-ai/cmux")
    parser.add_argument("--release-tag", default="nightly", help="GitHub release tag to prune")
    parser.add_argument(
        "--keep-builds",
        type=int,
        default=100,
        help="Number of newest immutable nightly builds to keep",
    )
    parser.add_argument(
        "--execute",
        action="store_true",
        help="Delete assets instead of printing a dry-run plan",
    )
    return parser.parse_args()


def gh_json(*args: str) -> dict:
    proc = subprocess.run(
        ["gh", *args],
        capture_output=True,
        text=True,
    )
    if proc.returncode != 0:
        stderr = (proc.stderr or proc.stdout).strip()
        raise subprocess.CalledProcessError(proc.returncode, proc.args, output=proc.stdout, stderr=stderr)
    return json.loads(proc.stdout)


def load_release(repo: str, release_tag: str) -> dict | None:
    try:
        return gh_json("api", f"repos/{repo}/releases/tags/{release_tag}")
    except subprocess.CalledProcessError as exc:
        message = (exc.stderr or exc.output or "").lower()
        if "404" in message or "not found" in message:
            return None
        raise


def extract_build(name: str) -> int | None:
    for pattern in IMMUTABLE_ASSET_PATTERNS:
        match = pattern.match(name)
        if match:
            return int(match.group("build"))
    return None


def collect_immutable_assets(release: dict) -> tuple[list[ReleaseAsset], int]:
    immutable_assets: list[ReleaseAsset] = []
    ignored_assets = 0
    for asset in release.get("assets", []):
        build = extract_build(asset["name"])
        if build is None:
            ignored_assets += 1
            continue
        immutable_assets.append(
            ReleaseAsset(
                asset_id=asset["id"],
                name=asset["name"],
                build=build,
            )
        )
    return immutable_assets, ignored_assets


def partition_assets(assets: list[ReleaseAsset], keep_builds: int) -> tuple[list[ReleaseAsset], list[int]]:
    assets_by_build: dict[int, list[ReleaseAsset]] = defaultdict(list)
    for asset in assets:
        assets_by_build[asset.build].append(asset)

    ordered_builds = sorted(assets_by_build, reverse=True)
    builds_to_keep = set(ordered_builds[:keep_builds])

    to_delete: list[ReleaseAsset] = []
    for build in ordered_builds[keep_builds:]:
        to_delete.extend(sorted(assets_by_build[build], key=lambda asset: asset.name))

    return to_delete, ordered_builds


def delete_assets(repo: str, assets: list[ReleaseAsset]) -> None:
    total = len(assets)
    for index, asset in enumerate(assets, start=1):
        log(f"[{index}/{total}] deleting {asset.name}")
        subprocess.run(
            [
                "gh",
                "api",
                "-X",
                "DELETE",
                f"repos/{repo}/releases/assets/{asset.asset_id}",
            ],
            check=True,
        )


def main() -> int:
    args = parse_args()
    if args.keep_builds < 1:
        print("--keep-builds must be at least 1", file=sys.stderr)
        return 2

    release = load_release(args.repo, args.release_tag)
    if release is None:
        log(f"Release {args.release_tag!r} does not exist yet, nothing to prune.")
        return 0

    immutable_assets, ignored_assets = collect_immutable_assets(release)
    to_delete, ordered_builds = partition_assets(immutable_assets, args.keep_builds)

    total_assets = len(release.get("assets", []))
    kept_builds = min(args.keep_builds, len(ordered_builds))
    log(
        f"Release {args.release_tag!r} has {total_assets} assets total, "
        f"{len(immutable_assets)} immutable assets across {len(ordered_builds)} builds, "
        f"and {ignored_assets} non-immutable alias assets."
    )
    log(
        f"Keeping the newest {kept_builds} builds and "
        f"{len(immutable_assets) - len(to_delete)} immutable assets."
    )

    if not to_delete:
        log("Nothing to prune.")
        return 0

    oldest_deleted = min(asset.build for asset in to_delete)
    newest_deleted = max(asset.build for asset in to_delete)
    log(
        f"{'Deleting' if args.execute else 'Would delete'} {len(to_delete)} immutable assets "
        f"from builds {oldest_deleted} through {newest_deleted}."
    )

    preview = to_delete[:20]
    for asset in preview:
        log(f"  {asset.name}")
    if len(to_delete) > len(preview):
        log(f"  ... and {len(to_delete) - len(preview)} more")

    if not args.execute:
        log("Dry run only. Re-run with --execute to delete assets.")
        return 0

    delete_assets(args.repo, to_delete)
    log("Prune complete.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
