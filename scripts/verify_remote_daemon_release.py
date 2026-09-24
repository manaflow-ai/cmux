#!/usr/bin/env python3
"""Keep the SSH client's embedded manifest and published daemon assets together.

Run with --embed before signing, then without it against the signed bundle.
No app is launched and no network access or daemon cache is needed.
"""

import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import subprocess
import sys
import zlib
from urllib.parse import quote


MANIFEST_KEY = "CMUXRemoteDaemonManifestJSON"
TARGETS = {("darwin", "arm64"), ("darwin", "amd64"),
           ("linux", "arm64"), ("linux", "amd64")}


def require(condition, message):
    if not condition:
        raise ValueError(message)


def asset_path(directory, name):
    require(isinstance(name, str) and name not in ("", ".", "..")
            and Path(name).name == name, f"invalid asset name: {name!r}")
    path = directory / name
    require(path.is_file() and path.stat().st_size > 0, f"missing or empty asset: {name}")
    return path


def verify_assets(manifest_path, directory):
    manifest = json.loads(manifest_path.read_text())
    require(manifest["schemaVersion"] == 1, "unsupported daemon manifest schema")
    require(isinstance(manifest["appVersion"], str) and manifest["appVersion"], "missing app version")
    require(isinstance(manifest["releaseTag"], str) and manifest["releaseTag"], "missing release tag")
    release_url = manifest["releaseURL"]
    require(isinstance(release_url, str) and re.fullmatch(
        r"https://github\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+/releases/download/"
        + re.escape(quote(manifest["releaseTag"], safe="")), release_url),
        "unexpected daemon release URL")
    entries = manifest["entries"]
    require(len(entries) == len(TARGETS)
            and {(e["goOS"], e["goArch"]) for e in entries} == TARGETS,
            "daemon manifest must contain each supported platform exactly once")
    suffix = ""
    if manifest["releaseTag"] == "nightly":
        version_parts = manifest["appVersion"].rsplit("-nightly.", 1)
        require(len(version_parts) == 2 and version_parts[1].isdigit(), "invalid nightly daemon version")
        suffix = "-" + version_parts[1]
    elif manifest["releaseTag"] == "rc":
        # A release candidate carries the plain stable version (its bits become
        # the stable release), so the immutable asset suffix is the build number
        # carried in the manifest filename rather than a version suffix.
        require(re.fullmatch(r"\d+\.\d+\.\d+", manifest["appVersion"]), "invalid rc daemon version")
        match = re.fullmatch(r"cmuxd-remote-manifest-(\d+)\.json", manifest_path.name)
        require(match is not None, "rc daemon manifest must carry a build-number suffix")
        suffix = "-" + match.group(1)
    require(manifest_path.name == f"cmuxd-remote-manifest{suffix}.json", "unexpected manifest filename")
    require(manifest["checksumsAssetName"] == f"cmuxd-remote-checksums{suffix}.txt",
            "unexpected checksums filename")
    checksum_path = asset_path(directory, manifest["checksumsAssetName"])
    require(manifest["checksumsURL"] == f"{release_url}/{checksum_path.name}", "unexpected checksums URL")
    checksum_lines = [line.split() for line in checksum_path.read_text().splitlines() if line.strip()]
    require(len(checksum_lines) == len(TARGETS) and all(len(line) == 2 for line in checksum_lines),
            "checksums must contain exactly one line per platform")
    checksums = {name: digest for digest, name in checksum_lines}
    expected_names = set()
    for entry in entries:
        name = f"cmuxd-remote-{entry['goOS']}-{entry['goArch']}{suffix}"
        expected_names.add(name)
        require(entry["assetName"] == name, f"unexpected asset name for {name}")
        require(entry["downloadURL"] == f"{release_url}/{name}", f"unexpected download URL for {name}")
        digest = hashlib.sha256(asset_path(directory, name).read_bytes()).hexdigest()
        require(entry["sha256"] == digest and checksums.get(name) == digest,
                f"daemon checksum mismatch: {name}")
    require(set(checksums) == expected_names, "checksums and manifest assets differ")
    return manifest


def verify_bundle(app, manifest, embed=False, verify_cli=False,
                  bundle_assets_from=None, require_bundled_assets=False):
    plist_path = app / "Contents/Info.plist"
    raw_plist = plist_path.read_bytes()
    info = plistlib.loads(raw_plist)
    require(info["CFBundleShortVersionString"] == manifest["appVersion"],
            "app and daemon manifest versions differ")
    if embed:
        info[MANIFEST_KEY] = json.dumps(manifest, separators=(",", ":"), sort_keys=True)
        plist_format = plistlib.FMT_BINARY if raw_plist.startswith(b"bplist") else plistlib.FMT_XML
        plist_path.write_bytes(plistlib.dumps(info, fmt=plist_format, sort_keys=False))
    require(MANIFEST_KEY in info, "app is missing the SSH daemon manifest")
    require(json.loads(info[MANIFEST_KEY]) == manifest, "embedded and published daemon manifests differ")
    bundled = app / "Contents/Resources/remote-daemons"
    if bundle_assets_from is not None:
        bundled.mkdir(parents=True, exist_ok=True)
        for entry in manifest["entries"]:
            payload = asset_path(bundle_assets_from, entry["assetName"]).read_bytes()
            # Raw DEFLATE is Foundation NSData.CompressionAlgorithm.zlib's format.
            # Resource data is sealed by codesign without rewriting daemon bytes.
            compressor = zlib.compressobj(level=9, wbits=-15)
            (bundled / (entry["assetName"] + ".deflate")).write_bytes(
                compressor.compress(payload) + compressor.flush())
    if require_bundled_assets:
        require(bundled.is_dir(), "app is missing bundled SSH daemon assets")
    if bundled.exists():
        for entry in manifest["entries"]:
            payload = zlib.decompress(
                asset_path(bundled, entry["assetName"] + ".deflate").read_bytes(), wbits=-15)
            require(hashlib.sha256(payload).hexdigest() == entry["sha256"],
                    f"bundled daemon checksum mismatch: {entry['assetName']}")
    if not verify_cli:
        return
    cli = app / "Contents/Resources/bin/cmux"
    # A release check must never be rescued by the developer's local-build override.
    environment = {key: value for key, value in os.environ.items() if not key.startswith("CMUX_")}
    for entry in manifest["entries"]:
        result = subprocess.run(
            [str(cli), "--json", "remote-daemon-status", "--os", entry["goOS"], "--arch", entry["goArch"]],
            capture_output=True, text=True, check=True, timeout=30, env=environment
        )
        status = json.loads(result.stdout)
        expected = {
            "manifest_present": True,
            "app_version": manifest["appVersion"],
            "release_tag": manifest["releaseTag"],
            "asset_name": entry["assetName"],
            "download_url": entry["downloadURL"],
            "expected_sha256": entry["sha256"],
            "checksums_asset_name": manifest["checksumsAssetName"],
            "checksums_url": manifest["checksumsURL"],
            "dev_local_build_fallback": False,
        }
        for key, value in expected.items():
            require(status.get(key) == value, f"bundled CLI {entry['assetName']}: unexpected {key}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--manifest", required=True, type=Path)
    parser.add_argument("--assets-dir", required=True, type=Path)
    parser.add_argument("--app", type=Path)
    parser.add_argument("--embed", action="store_true")
    parser.add_argument("--verify-cli", action="store_true")
    parser.add_argument("--bundle-assets", action="store_true",
                        help="bundle verified daemon bytes for unpublished dogfood apps")
    parser.add_argument("--require-bundled-assets", action="store_true")
    args = parser.parse_args()
    if (args.embed or args.verify_cli or args.bundle_assets or args.require_bundled_assets) and not args.app:
        parser.error("bundle operations require --app")
    try:
        manifest = verify_assets(args.manifest, args.assets_dir)
        if args.app:
            verify_bundle(args.app, manifest, args.embed, args.verify_cli,
                          args.assets_dir if args.bundle_assets else None,
                          args.require_bundled_assets)
    except (OSError, ValueError, KeyError, TypeError, zlib.error, subprocess.SubprocessError) as error:
        print(f"Remote daemon release verification failed: {error}", file=sys.stderr)
        return 1
    print(f"Verified SSH daemon release {manifest['appVersion']} ({len(TARGETS)} platforms)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
