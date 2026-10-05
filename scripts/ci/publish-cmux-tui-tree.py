#!/usr/bin/env python3
"""Complete an immutable cmux-tui tree publication.

The tree object is write-once.  A publication can therefore be interrupted
after source.json or the daemon has been written.  This helper verifies the
commit manifest for every companion, writes only missing objects, and records
completion separately so legacy source metadata is never overwritten.

The caller supplies the uploader from a trusted checkout.  In particular, a
pull_request_target job must pass the uploader checked out from its base ref;
the assets are opaque build outputs and are never executed here.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
from typing import Any


COMPANION_NAMES = (
    "cmux-tui-aarch64-apple-darwin",
    "cmux-tui-app-host-aarch64-apple-darwin",
    "cmux-tui-cloud-server-aarch64-apple-darwin",
)
REPAIR_POINTER = "cmuxterm-hq REPAIR.md#cmux-tui-tree-publication"


class PublicationError(RuntimeError):
    pass


def _sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def _load_json(path: Path, description: str) -> dict[str, Any]:
    try:
        value = json.loads(path.read_text())
    except (OSError, json.JSONDecodeError) as error:
        raise PublicationError(f"cannot read {description} {path}: {error}") from error
    if not isinstance(value, dict):
        raise PublicationError(f"{description} must be a JSON object: {path}")
    return value


def _require_sha(value: Any, label: str) -> str:
    if not isinstance(value, str) or len(value) != 64 or any(
        character not in "0123456789abcdef" for character in value
    ):
        raise PublicationError(f"{label} is not a lowercase SHA-256 digest")
    return value


def _upload(
    uploader: Path,
    file: Path,
    *,
    endpoint_url: str,
    bucket: str,
    key: str,
    cache_control: str,
) -> None:
    command = [
        sys.executable,
        str(uploader),
        "--write-once",
        "--file",
        str(file),
        "--endpoint-url",
        endpoint_url,
        "--bucket",
        bucket,
        "--key",
        key,
        "--cache-control",
        cache_control,
    ]
    try:
        result = subprocess.run(command, check=False, text=True, capture_output=True)
    except OSError as error:
        raise PublicationError(f"could not execute trusted uploader {uploader}: {error}") from error
    if result.returncode:
        detail = (result.stderr or result.stdout).strip()
        raise PublicationError(
            f"uploader failed for {key} (exit {result.returncode}): {detail or 'no output'}"
        )
    if result.stdout.strip():
        print(result.stdout.strip())


def publish_tree(
    *,
    key: str,
    source_commit: str,
    assets_dir: Path,
    uploader: Path,
    endpoint_url: str,
    bucket: str,
    manifest_file: Path,
    source_file: Path | None = None,
    publish_source: bool = False,
) -> dict[str, str]:
    """Validate and publish all arm64 tree companions.

    ``manifest_file`` is the immutable commit-addressed manifest that attests
    the bytes.  ``source_file`` is an existing tree source.json, when present;
    it is retained as-is for repairs.  A new publisher may set
    ``publish_source`` to write its generated source metadata once.
    """
    if len(key) != 40 or any(character not in "0123456789abcdef" for character in key):
        raise PublicationError(f"invalid tree key {key!r}")
    if len(source_commit) != 40 or any(
        character not in "0123456789abcdef" for character in source_commit
    ):
        raise PublicationError(f"invalid source commit {source_commit!r}")
    if not uploader.is_file():
        raise PublicationError(f"trusted uploader does not exist: {uploader}")
    if not assets_dir.is_dir():
        raise PublicationError(f"assets directory does not exist: {assets_dir}")

    manifest = _load_json(manifest_file, "commit manifest")
    manifest_commit = manifest.get("commit", manifest.get("sourceCommit"))
    if manifest_commit != source_commit:
        raise PublicationError(
            f"commit manifest source {manifest_commit!r} does not match {source_commit}"
        )
    binaries = manifest.get("binaries")
    if not isinstance(binaries, dict):
        raise PublicationError("commit manifest has no binaries object")

    digests: dict[str, str] = {}
    for name in COMPANION_NAMES:
        expected = _require_sha(binaries.get(name), f"manifest binary {name}")
        path = assets_dir / name
        if not path.is_file():
            raise PublicationError(f"missing companion {name} in {assets_dir}")
        actual = _sha256(path)
        if actual != expected:
            raise PublicationError(
                f"companion {name} digest {actual} does not match commit manifest {expected}"
            )
        digests[name] = actual

    if publish_source:
        if source_file is None or not source_file.is_file():
            raise PublicationError("--publish-source requires a source metadata file")
    if source_file is not None:
        metadata = _load_json(source_file, "tree source metadata")
        if metadata.get("key") != key:
            raise PublicationError("tree source metadata key does not match requested key")
        metadata_commit = metadata.get("commit")
        if metadata_commit != source_commit:
            raise PublicationError(
                f"tree source metadata commit {metadata_commit!r} does not match {source_commit}"
            )
        metadata_binaries = metadata.get("binaries", {})
        if not isinstance(metadata_binaries, dict):
            raise PublicationError("tree source metadata binaries must be an object")
        for name, digest in metadata_binaries.items():
            if name in digests and digest != digests[name]:
                raise PublicationError(
                    f"tree source metadata digest for {name} does not match commit manifest"
                )

    cache = "public, max-age=31536000, immutable"
    prefix = f"cmux-tui/tree/{key}"
    if publish_source and source_file is not None:
        _upload(
            uploader,
            source_file,
            endpoint_url=endpoint_url,
            bucket=bucket,
            key=f"{prefix}/source.json",
            cache_control=cache,
        )

    with tempfile.TemporaryDirectory(prefix="cmux-tui-tree-") as temporary:
        temporary_dir = Path(temporary)
        for name, digest in digests.items():
            binary = assets_dir / name
            _upload(
                uploader,
                binary,
                endpoint_url=endpoint_url,
                bucket=bucket,
                key=f"{prefix}/{name}",
                cache_control=cache,
            )
            checksum = temporary_dir / f"{name}.sha256"
            checksum.write_text(f"{digest}  {name}\n")
            _upload(
                uploader,
                checksum,
                endpoint_url=endpoint_url,
                bucket=bucket,
                key=f"{prefix}/{name}.sha256",
                cache_control=cache,
            )

        completion = {
            "schemaVersion": 1,
            "key": key,
            "sourceCommit": source_commit,
            "binaries": digests,
        }
        if source_file is not None and source_file.is_file():
            completion["sourceSha256"] = _sha256(source_file)
        completion_file = temporary_dir / "completion.json"
        completion_file.write_text(json.dumps(completion, indent=2, sort_keys=True) + "\n")
        _upload(
            uploader,
            completion_file,
            endpoint_url=endpoint_url,
            bucket=bucket,
            key=f"{prefix}/completion.json",
            cache_control=cache,
        )
    return digests


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--key", required=True)
    parser.add_argument("--source-commit", required=True)
    parser.add_argument("--assets-dir", type=Path, required=True)
    parser.add_argument("--manifest-file", type=Path, required=True)
    parser.add_argument("--source-file", type=Path)
    parser.add_argument("--publish-source", action="store_true")
    parser.add_argument("--uploader", type=Path, required=True)
    parser.add_argument("--endpoint-url", required=True)
    parser.add_argument("--bucket", required=True)
    args = parser.parse_args(argv)
    try:
        digests = publish_tree(
            key=args.key,
            source_commit=args.source_commit,
            assets_dir=args.assets_dir,
            uploader=args.uploader,
            endpoint_url=args.endpoint_url,
            bucket=args.bucket,
            manifest_file=args.manifest_file,
            source_file=args.source_file,
            publish_source=args.publish_source,
        )
    except (OSError, PublicationError, ValueError) as error:
        print(f"cmux-tui tree publication failed: {error}; see {REPAIR_POINTER}", file=sys.stderr)
        return 1
    print(f"Completed cmux-tui tree {args.key}: {', '.join(sorted(digests))}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
