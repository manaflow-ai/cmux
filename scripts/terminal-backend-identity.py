#!/usr/bin/env python3
"""Derive the app-scoped terminal backend identity used by Swift and shell."""

from __future__ import annotations

import argparse
import base64
import hashlib
import json
import pathlib
import re
import sys


PRODUCTION_BUNDLE_ID = "com.cmuxterm.app"
SAFE_BUNDLE_ID = re.compile(r"^[a-z0-9._-]+$")
DEFAULT_VECTORS = (
    pathlib.Path(__file__).resolve().parents[1]
    / "Packages/macOS/CmuxTerminalBackendService/Tests/Fixtures/backend-service-identity-vectors.json"
)


def derive(bundle_id: str) -> dict[str, str]:
    normalized = bundle_id.strip().lower()
    if not normalized or not SAFE_BUNDLE_ID.fullmatch(normalized):
        raise ValueError(f"unsafe bundle identifier: {bundle_id}")

    token = base64.b32encode(
        hashlib.sha256(normalized.encode("ascii")).digest()[:16]
    ).decode("ascii").rstrip("=").lower()
    session = "cmux" if normalized == PRODUCTION_BUNDLE_ID else f"cmux-{token}"
    label = f"{normalized}.terminal-backend"
    return {
        "normalizedBundleIdentifier": normalized,
        "identityToken": token,
        "serviceLabel": label,
        "propertyListName": f"{label}.plist",
        "sessionName": session,
        "socketFileName": f"{session}.sock",
        "stateNamespace": session,
    }


def check_vectors(path: pathlib.Path) -> None:
    vectors = json.loads(path.read_text(encoding="utf-8"))
    for vector in vectors:
        actual = derive(vector["bundleIdentifier"])
        expected = {key: value for key, value in vector.items() if key != "bundleIdentifier"}
        if actual != expected:
            raise ValueError(
                f"identity vector mismatch for {vector['bundleIdentifier']}: "
                f"expected {expected}, got {actual}"
            )


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--bundle-id")
    parser.add_argument("--field", choices=[
        "normalizedBundleIdentifier",
        "identityToken",
        "serviceLabel",
        "propertyListName",
        "sessionName",
        "socketFileName",
        "stateNamespace",
    ])
    parser.add_argument("--format", choices=["json", "tsv"], default="json")
    parser.add_argument("--check-vectors", nargs="?", const=str(DEFAULT_VECTORS))
    args = parser.parse_args()

    try:
        if args.check_vectors:
            check_vectors(pathlib.Path(args.check_vectors))
            print("terminal backend identity vectors verified")
            return 0
        if args.bundle_id is None:
            parser.error("--bundle-id is required unless --check-vectors is used")
        identity = derive(args.bundle_id)
    except (OSError, ValueError, json.JSONDecodeError) as error:
        print(f"error: {error}", file=sys.stderr)
        return 2

    if args.field:
        print(identity[args.field])
    elif args.format == "tsv":
        print("\t".join(identity.values()))
    else:
        print(json.dumps(identity, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
