#!/usr/bin/env python3
"""Remove profile-only capabilities that are unsupported on the iOS app."""

from __future__ import annotations

import argparse
import plistlib
import sys
from pathlib import Path


UNSUPPORTED_IOS_MAIN_APP_ENTITLEMENTS = (
    "com.apple.developer.networking.networkextension",
    "com.apple.developer.networking.vpn.api",
)


def filter_app_store_entitlements(entitlements: dict) -> tuple[dict, list[str]]:
    """Return the signed iOS app entitlements and keys removed from them."""
    filtered = dict(entitlements)
    removed = []
    for key in UNSUPPORTED_IOS_MAIN_APP_ENTITLEMENTS:
        if key in filtered:
            del filtered[key]
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
    args = parser.parse_args(argv)

    try:
        entitlements = load_entitlements(args.path)
    except (OSError, plistlib.InvalidFileException, ValueError) as exc:
        print(f"error: could not read entitlements: {exc}", file=sys.stderr)
        return 2

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
