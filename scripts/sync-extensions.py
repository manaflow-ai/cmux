#!/usr/bin/env python3
"""
Sync extensions and global packages to their latest versions.

This script:
1. Reads the current versions from scripts/sync-extensions.json
2. Fetches the latest versions from VS Code Marketplace and npm
3. Updates the JSON file with the latest versions
4. Optionally updates Dockerfile and snapshot.py to use the new versions

Usage:
    uv run ./scripts/sync-extensions.py           # Update all versions to latest
    uv run ./scripts/sync-extensions.py --dry-run # Show what would be updated
    uv run ./scripts/sync-extensions.py --check   # Exit with error if updates available
"""

from __future__ import annotations

import argparse
import json
import sys
from dataclasses import dataclass
from pathlib import Path

import httpx

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

SCRIPT_DIR = Path(__file__).resolve().parent
SYNC_EXTENSIONS_JSON = SCRIPT_DIR / "sync-extensions.json"

NPM_REGISTRY_URL = "https://registry.npmjs.org"
VSCODE_MARKETPLACE_URL = "https://marketplace.visualstudio.com/_apis/public/gallery/extensionquery"


# ---------------------------------------------------------------------------
# Types
# ---------------------------------------------------------------------------


@dataclass
class Extension:
    publisher: str
    name: str
    version: str


@dataclass
class GlobalPackage:
    name: str
    version: str | None
    version_command: str | None


@dataclass
class SyncConfig:
    extensions: list[Extension]
    global_packages: list[GlobalPackage]


# ---------------------------------------------------------------------------
# Load/Save config
# ---------------------------------------------------------------------------


def load_config() -> SyncConfig:
    with open(SYNC_EXTENSIONS_JSON, "r") as f:
        data = json.load(f)

    extensions = [
        Extension(
            publisher=ext["publisher"],
            name=ext["name"],
            version=ext["version"],
        )
        for ext in data.get("extensions", [])
    ]

    global_packages = [
        GlobalPackage(
            name=pkg["name"],
            version=pkg.get("version"),
            version_command=pkg.get("versionCommand"),
        )
        for pkg in data.get("globalPackages", [])
    ]

    return SyncConfig(extensions=extensions, global_packages=global_packages)


def save_config(config: SyncConfig) -> None:
    data = {
        "$schema": "./sync-extensions.schema.json",
        "extensions": [
            {
                "publisher": ext.publisher,
                "name": ext.name,
                "version": ext.version,
            }
            for ext in config.extensions
        ],
        "globalPackages": [
            {
                "name": pkg.name,
                "version": pkg.version,
                "versionCommand": pkg.version_command,
            }
            for pkg in config.global_packages
        ],
    }
    with open(SYNC_EXTENSIONS_JSON, "w") as f:
        json.dump(data, f, indent=2)
        f.write("\n")


# ---------------------------------------------------------------------------
# Version fetching
# ---------------------------------------------------------------------------


def fetch_npm_latest_version(package_name: str) -> str | None:
    """Fetch the latest version of a package from npm registry."""
    try:
        url = f"{NPM_REGISTRY_URL}/{package_name}/latest"
        with httpx.Client(timeout=30.0) as client:
            response = client.get(url)
            if response.status_code == 200:
                data = response.json()
                return data.get("version")
            else:
                print(f"  Warning: Failed to fetch {package_name} from npm: HTTP {response.status_code}", file=sys.stderr)
                return None
    except Exception as e:
        print(f"  Warning: Error fetching {package_name} from npm: {e}", file=sys.stderr)
        return None


def fetch_vscode_extension_latest_version(publisher: str, name: str) -> str | None:
    """Fetch the latest version of a VS Code extension from the Marketplace."""
    try:
        # Use the VS Code Marketplace API
        payload = {
            "filters": [
                {
                    "criteria": [
                        {"filterType": 7, "value": f"{publisher}.{name}"}
                    ]
                }
            ],
            "flags": 0x200  # IncludeLatestVersionOnly
        }
        headers = {
            "Content-Type": "application/json",
            "Accept": "application/json;api-version=3.0-preview.1",
        }
        with httpx.Client(timeout=30.0) as client:
            response = client.post(VSCODE_MARKETPLACE_URL, json=payload, headers=headers)
            if response.status_code == 200:
                data = response.json()
                results = data.get("results", [])
                if results:
                    extensions = results[0].get("extensions", [])
                    if extensions:
                        versions = extensions[0].get("versions", [])
                        if versions:
                            return versions[0].get("version")
            print(f"  Warning: Failed to fetch {publisher}.{name} from VS Code Marketplace", file=sys.stderr)
            return None
    except Exception as e:
        print(f"  Warning: Error fetching {publisher}.{name} from VS Code Marketplace: {e}", file=sys.stderr)
        return None


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Sync extensions and global packages to their latest versions"
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Show what would be updated without making changes",
    )
    parser.add_argument(
        "--check",
        action="store_true",
        help="Exit with error code if updates are available",
    )
    args = parser.parse_args()

    print("Loading current configuration...")
    config = load_config()

    updates_available = False

    # Update extensions
    print("\nChecking VS Code extensions...")
    for ext in config.extensions:
        latest = fetch_vscode_extension_latest_version(ext.publisher, ext.name)
        if latest and latest != ext.version:
            print(f"  {ext.publisher}.{ext.name}: {ext.version} -> {latest}")
            updates_available = True
            if not args.dry_run and not args.check:
                ext.version = latest
        else:
            print(f"  {ext.publisher}.{ext.name}: {ext.version} (up to date)")

    # Update npm packages
    print("\nChecking npm packages...")
    for pkg in config.global_packages:
        latest = fetch_npm_latest_version(pkg.name)
        if latest:
            current = pkg.version or "(unpinned)"
            if latest != pkg.version:
                print(f"  {pkg.name}: {current} -> {latest}")
                updates_available = True
                if not args.dry_run and not args.check:
                    pkg.version = latest
            else:
                print(f"  {pkg.name}: {current} (up to date)")
        else:
            print(f"  {pkg.name}: could not fetch latest version")

    if args.check:
        if updates_available:
            print("\nUpdates are available. Run without --check to update.")
            return 1
        else:
            print("\nAll packages are up to date.")
            return 0

    if args.dry_run:
        print("\nDry run complete. No changes made.")
        return 0

    # Save updated config
    print("\nSaving updated configuration...")
    save_config(config)
    print(f"  Updated {SYNC_EXTENSIONS_JSON}")

    print("\nNote: Dockerfile and snapshot.py read directly from sync-extensions.json via jq.")
    print("No additional file updates needed.")

    print("\nDone!")
    return 0


if __name__ == "__main__":
    sys.exit(main())
