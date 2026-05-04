#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
from pathlib import Path

from package_manifest import MANIFEST_RELATIVE_PATH, PACKAGE_DISTRIBUTIONS, build_manifest


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Write the cmux Linux package manifest.")
    parser.add_argument("staging_dir", type=Path, help="Path to the package staging directory.")
    parser.add_argument(
        "--remote-daemon-included",
        action="store_true",
        help="Record bin/cmuxd-remote as included in the artifact.",
    )
    parser.add_argument(
        "--swift-cli-included",
        action="store_true",
        help="Record the Swift cmux CLI auth bridge as included in the artifact.",
    )
    parser.add_argument(
        "--distribution",
        choices=PACKAGE_DISTRIBUTIONS,
        default="tarball",
        help="Record the package artifact format that owns this manifest.",
    )
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    manifest_path = args.staging_dir / MANIFEST_RELATIVE_PATH
    manifest_path.parent.mkdir(parents=True, exist_ok=True)
    manifest = build_manifest(
        remote_daemon_included=args.remote_daemon_included,
        swift_cli_included=args.swift_cli_included,
        distribution=args.distribution,
    )
    manifest_path.write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
