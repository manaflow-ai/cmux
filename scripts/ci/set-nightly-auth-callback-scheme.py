#!/usr/bin/env python3
"""Replace the auth callback scheme in a built macOS app plist.

The URL-type array is not an API: Xcode or a future plist edit may reorder it.
Resolve the auth entry by its semantic name (or the previous callback scheme)
instead of relying on a numeric index, then update only that entry.
"""

from __future__ import annotations

import argparse
import os
import plistlib
import stat
import sys
import tempfile
from pathlib import Path
from typing import Any, Optional


AUTH_NAME_SUFFIX = ".auth"


def _normalized_scheme(value: Any) -> str:
    return value.strip().lower() if isinstance(value, str) else ""


def _is_auth_url_type(entry: dict[str, Any], base_scheme: str) -> bool:
    name = entry.get("CFBundleURLName")
    if isinstance(name, str) and name.strip().lower().endswith(AUTH_NAME_SUFFIX):
        return True

    if not base_scheme:
        return False
    schemes = entry.get("CFBundleURLSchemes")
    return isinstance(schemes, list) and any(
        _normalized_scheme(scheme) == base_scheme for scheme in schemes
    )


def _auth_url_type_index(url_types: list[Any], base_scheme: str) -> int:
    matches = [
        index
        for index, value in enumerate(url_types)
        if isinstance(value, dict) and _is_auth_url_type(value, base_scheme)
    ]
    if len(matches) != 1:
        raise ValueError(
            "expected exactly one auth callback URL type identified by "
            f"name '*{AUTH_NAME_SUFFIX}' or scheme '{base_scheme}', found {len(matches)}"
        )
    return matches[0]


def _write_plist_atomically(path: Path, plist: dict[str, Any], fmt: str, mode: int) -> None:
    temporary_path: Optional[Path] = None
    try:
        with tempfile.NamedTemporaryFile(
            dir=path.parent,
            prefix=f".{path.name}.",
            suffix=".tmp",
            delete=False,
        ) as temporary:
            temporary_path = Path(temporary.name)
            plistlib.dump(plist, temporary, fmt=fmt, sort_keys=False)
            temporary.flush()
            os.fsync(temporary.fileno())
        os.chmod(temporary_path, mode)
        os.replace(temporary_path, path)
        temporary_path = None
    finally:
        if temporary_path is not None:
            temporary_path.unlink(missing_ok=True)


def set_auth_callback_scheme(path: Path, callback_scheme: str, base_scheme: str = "cmux") -> int:
    normalized_callback = _normalized_scheme(callback_scheme)
    if not normalized_callback:
        raise ValueError("callback scheme must not be empty")

    raw = path.read_bytes()
    plist = plistlib.loads(raw)
    if not isinstance(plist, dict):
        raise ValueError("plist root must be a dictionary")
    url_types = plist.get("CFBundleURLTypes")
    if not isinstance(url_types, list):
        raise ValueError("plist is missing a CFBundleURLTypes array")

    index = _auth_url_type_index(url_types, _normalized_scheme(base_scheme))
    entry = url_types[index]
    assert isinstance(entry, dict)
    schemes = entry.get("CFBundleURLSchemes")
    if not isinstance(schemes, list) or not schemes:
        raise ValueError(f"auth URL type at index {index} has no URL scheme")

    schemes[0] = callback_scheme
    fmt = plistlib.FMT_BINARY if raw.startswith(b"bplist") else plistlib.FMT_XML
    mode = stat.S_IMODE(path.stat().st_mode)
    _write_plist_atomically(path, plist, fmt, mode)
    return index


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("plist", type=Path)
    parser.add_argument("callback_scheme")
    parser.add_argument("--base-scheme", default="cmux")
    args = parser.parse_args()

    try:
        index = set_auth_callback_scheme(args.plist, args.callback_scheme, args.base_scheme)
    except (OSError, plistlib.InvalidFileException, ValueError) as error:
        print(f"nightly plist auth callback update failed: {error}", file=sys.stderr)
        return 1

    print(f"Updated auth callback URL type at index {index} to {args.callback_scheme}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
