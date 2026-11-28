#!/usr/bin/env python3
"""Generate the release manifest after parallel remote-daemon builds finish."""

import json
import sys
import urllib.parse
from pathlib import Path


def main() -> None:
    (
        version,
        release_tag,
        repo,
        checksums_asset_name,
        checksums_path,
        manifest_path,
        entries_file,
    ) = sys.argv[1:]

    quoted_tag = urllib.parse.quote(release_tag, safe="")
    release_url = f"https://github.com/{repo}/releases/download/{quoted_tag}"
    checksums_url = (
        f"{release_url}/{urllib.parse.quote(checksums_asset_name, safe='')}"
    )

    entries = []
    for line in Path(entries_file).read_text(encoding="utf-8").splitlines():
        if not line.strip():
            continue
        go_os, go_arch, asset_name, sha256 = line.split("\t")
        entries.append(
            {
                "goOS": go_os,
                "goArch": go_arch,
                "assetName": asset_name,
                "downloadURL": (
                    f"{release_url}/{urllib.parse.quote(asset_name, safe='')}"
                ),
                "sha256": sha256,
            }
        )

    manifest = {
        "schemaVersion": 1,
        "appVersion": version,
        "releaseTag": release_tag,
        "releaseURL": release_url,
        "checksumsAssetName": checksums_asset_name,
        "checksumsURL": checksums_url,
        "entries": entries,
    }
    Path(manifest_path).write_text(
        json.dumps(manifest, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )


if __name__ == "__main__":
    if len(sys.argv) != 8:
        raise SystemExit(
            "usage: generate_remote_daemon_release_manifest.py "
            "<version> <release-tag> <repo> <checksums-asset-name> "
            "<checksums-path> <manifest-path> <entries-file>"
        )
    main()
