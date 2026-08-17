#!/usr/bin/env python3
"""Verify a published cmux-tui raw-artifact manifest.

The raw-artifact lane is separate from npm and PyPI publication.  This check
is used after R2 uploads to prove that the immutable manifest (and, on main,
the rolling ``latest`` manifest) points at the exact build and contains every
artifact required by the public installers.
"""

from __future__ import annotations

import argparse
import http.client
import json
import re
import sys
import urllib.error
import urllib.request
from pathlib import Path
from typing import Any, Iterable
from urllib.parse import urlsplit


SHA256_RE = re.compile(r"^[0-9a-fA-F]{64}$")


class ManifestError(ValueError):
    """The manifest does not satisfy the raw-artifact contract."""


def _decode_manifest(payload: bytes, source: str) -> dict[str, Any]:
    try:
        document = json.loads(payload)
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise ManifestError(f"{source} is not valid JSON: {error}") from error
    if not isinstance(document, dict):
        raise ManifestError(f"{source} must contain a JSON object")
    return document


def _validate_manifest(
    document: dict[str, Any],
    *,
    source: str,
    expected_commit: str,
    required_artifacts: Iterable[str],
) -> None:
    commit = document.get("commit")
    if commit != expected_commit:
        raise ManifestError(
            f"{source} commit mismatch: expected {expected_commit}, got {commit!r}"
        )

    binaries = document.get("binaries")
    if not isinstance(binaries, dict):
        raise ManifestError(f"{source} must contain a binaries object")

    for artifact, digest in binaries.items():
        if not isinstance(artifact, str) or not isinstance(digest, str):
            raise ManifestError(f"{source} contains a malformed binary digest")
        if not SHA256_RE.fullmatch(digest):
            raise ManifestError(f"{source} has invalid SHA-256 for artifact {artifact}")

    for artifact in required_artifacts:
        digest = binaries.get(artifact)
        if digest is None:
            raise ManifestError(f"{source} missing required artifact {artifact}")


def _read_url(url: str) -> bytes:
    # The post-publish latest check uses a ``?verify=<commit>`` cache-buster,
    # so queries are allowed. Fragments are rejected because HTTP never sends
    # them to the origin and they cannot identify the verified document.
    try:
        parsed = urlsplit(url)
        hostname = parsed.hostname
    except ValueError as error:
        raise ManifestError("manifest URL is malformed") from error
    if (
        parsed.scheme.casefold() != "https"
        or not parsed.netloc
        or not hostname
        or parsed.username is not None
        or parsed.password is not None
        or parsed.fragment
    ):
        raise ManifestError("manifest URL must use HTTPS without credentials")
    request = urllib.request.Request(
        url,
        headers={
            "Accept": "application/json",
            "Cache-Control": "no-cache",
            "User-Agent": "cmux-tui-manifest-verifier/1 (https://github.com/manaflow-ai/cmux)",
        },
    )
    try:
        with urlopen(request, timeout=30) as response:
            return response.read()
    except (OSError, ValueError, http.client.HTTPException, urllib.error.URLError) as error:
        raise ManifestError("could not fetch published manifest") from error


# Keep this name patchable in the unit tests and consistent with the other
# small network-verification helpers in cmux-tui.
urlopen = urllib.request.urlopen


def verify_manifest(
    url: str,
    *,
    expected_commit: str,
    required_artifacts: Iterable[str],
) -> None:
    """Fetch and validate one published manifest from a public URL."""

    document = _decode_manifest(_read_url(url), "published manifest")
    _validate_manifest(
        document,
        source="published manifest",
        expected_commit=expected_commit,
        required_artifacts=required_artifacts,
    )


def verify_manifest_file(
    path: Path,
    *,
    expected_commit: str,
    required_artifacts: Iterable[str],
) -> None:
    """Validate the manifest generated before any R2 upload occurs."""

    try:
        payload = path.read_bytes()
    except OSError as error:
        raise ManifestError(f"could not read {path}: {error}") from error
    document = _decode_manifest(payload, str(path))
    _validate_manifest(
        document,
        source=str(path),
        expected_commit=expected_commit,
        required_artifacts=required_artifacts,
    )


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Verify a cmux-tui raw-artifact manifest after publication."
    )
    source = parser.add_mutually_exclusive_group(required=True)
    source.add_argument("--manifest-url", help="Public manifest URL to fetch")
    source.add_argument(
        "--manifest-file",
        type=Path,
        help="Manifest generated locally before upload",
    )
    parser.add_argument(
        "--expected-commit",
        required=True,
        help="Exact commit SHA recorded in the manifest",
    )
    parser.add_argument(
        "--require-artifact",
        action="append",
        dest="required_artifacts",
        default=[],
        help="Artifact name that must have a valid SHA-256 digest (repeatable)",
    )
    return parser


def main(argv: list[str] | None = None) -> int:
    args = _parser().parse_args(argv)
    try:
        if args.manifest_url:
            verify_manifest(
                args.manifest_url,
                expected_commit=args.expected_commit,
                required_artifacts=args.required_artifacts,
            )
        else:
            assert args.manifest_file is not None
            verify_manifest_file(
                args.manifest_file,
                expected_commit=args.expected_commit,
                required_artifacts=args.required_artifacts,
            )
    except ManifestError:
        print("cmux-tui manifest verification failed", file=sys.stderr)
        return 1

    print("Verified cmux-tui manifest")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
