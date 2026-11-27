#!/usr/bin/env python3
"""Remove unsupported capability values from the iOS App Store app."""

from __future__ import annotations

import argparse
import plistlib
import sys
from pathlib import Path


NETWORK_EXTENSION_KEY = "com.apple.developer.networking.networkextension"
PERSONAL_VPN_KEY = "com.apple.developer.networking.vpn.api"
UNSUPPORTED_NETWORK_EXTENSION_VALUES = frozenset({"hotspot-provider"})


def filter_app_store_entitlements(entitlements: dict) -> tuple[dict, list[str]]:
    """Return the signed iOS app entitlements and keys removed from them."""
    filtered = dict(entitlements)
    removed = []
    values = filtered.get(NETWORK_EXTENSION_KEY)
    if isinstance(values, list):
        kept = [value for value in values if value not in UNSUPPORTED_NETWORK_EXTENSION_VALUES]
        removed.extend(
            f"{NETWORK_EXTENSION_KEY}[{value}]"
            for value in values
            if value in UNSUPPORTED_NETWORK_EXTENSION_VALUES
        )
        if kept:
            filtered[NETWORK_EXTENSION_KEY] = kept
        else:
            filtered.pop(NETWORK_EXTENSION_KEY, None)
    return filtered, removed


def remove_network_extension_entitlement(entitlements: dict) -> tuple[dict, list[str]]:
    """Remove all Network Extension and Personal VPN permissions from a host app."""
    filtered = dict(entitlements)
    removed = []
    for key in (NETWORK_EXTENSION_KEY, PERSONAL_VPN_KEY):
        values = filtered.pop(key, None)
        if isinstance(values, list):
            removed.extend(f"{key}[{value}]" for value in values)
        elif values is not None:
            removed.append(key)
    return filtered, removed


def load_entitlements(path: Path) -> dict:
    with path.open("rb") as handle:
        entitlements = plistlib.load(handle)
    if not isinstance(entitlements, dict):
        raise ValueError(f"{path} is not a dictionary plist")
    return entitlements


def write_entitlements(path: Path, entitlements: dict) -> None:
    with path.open("wb") as handle:
        plistlib.dump(entitlements, handle)


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("path", type=Path, help="entitlements plist to inspect or rewrite")
    parser.add_argument(
        "--check",
        action="store_true",
        help="fail when an unsupported iOS main-app entitlement is present",
    )
    parser.add_argument(
        "--remove-network-extension",
        action="store_true",
        help="remove all Network Extension permissions from the host app",
    )
    args = parser.parse_args(argv)

    try:
        entitlements = load_entitlements(args.path)
    except (OSError, plistlib.InvalidFileException, ValueError) as exc:
        print(f"error: could not read entitlements: {exc}", file=sys.stderr)
        return 2

    if args.remove_network_extension:
        filtered, removed = remove_network_extension_entitlement(entitlements)
    else:
        filtered, removed = filter_app_store_entitlements(entitlements)
    if args.check:
        if removed:
            print(
                "error: signed App Store iOS app contains unsupported main-app "
                "entitlements: " + ", ".join(removed),
                file=sys.stderr,
            )
            return 1
        return 0

    write_entitlements(args.path, filtered)
    for key in removed:
        print(
            f"removed unsupported iOS main-app entitlement: {key}",
            file=sys.stderr,
        )
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
