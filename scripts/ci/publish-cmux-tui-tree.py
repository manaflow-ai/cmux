#!/usr/bin/env python3
"""Complete an immutable cmux-tui tree publication.

The tree object is write-once.  A publication can therefore be interrupted
after source.json or the daemon has been written.  This helper verifies the
commit manifest for every companion, writes only missing objects, and records
completion separately so legacy source metadata is never overwritten.

The caller supplies the uploader from a trusted checkout; the assets are
opaque build outputs and are never executed here.
"""

from __future__ import annotations

import argparse
from concurrent.futures import ThreadPoolExecutor, as_completed
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
from typing import Any


# Every binary a tree carries. The macOS arm64 three come first: the cmux-next
# app bundles them, and the tree completeness checks in cmux-tui-artifacts.yml
# read only them (trees published before the Linux targets stay complete).
# Linux daemon mode fetches the musl daemon and its app host
# (scripts/cmux-next/pin-cmux-tui.sh fetch picks the host's target). The
# workflow reads this list with --list-companions.
COMPANION_NAMES = (
    "cmux-tui-aarch64-apple-darwin",
    "cmux-tui-app-host-aarch64-apple-darwin",
    "cmux-tui-cloud-server-aarch64-apple-darwin",
    "cmux-tui-x86_64-unknown-linux-musl",
    "cmux-tui-aarch64-unknown-linux-musl",
    "cmux-tui-app-host-x86_64-unknown-linux-musl",
    "cmux-tui-app-host-aarch64-unknown-linux-musl",
)
# completion.json attests these (unchanged since before the Linux targets, so a
# republication of an older tree writes byte-identical immutable metadata);
# completion-linux.json attests the rest. An older tree gains its Linux
# binaries on its next republication without an immutable conflict.
GATE_NAMES = COMPANION_NAMES[:3]
# The Windows daemon (GPUI Windows daemon mode; unsigned, sha256-pinned, decision
# of 2026-10-08), fetched by pin-cmux-tui.sh on Windows hosts. It has its own
# attestation, completion-windows.json, because a tree published before the
# Windows target keeps the source commit that built it, and that commit's
# manifest has no Windows binary: the republication that adds it uses a newer
# commit's build of the same tree, and completion-windows.json names that
# commit. The workflow reads this list with --list-windows-companions.
WINDOWS_NAMES = ("cmux-tui-x86_64-pc-windows-gnu.exe",)
# The small per-terminal host the Windows daemon spawns beside itself
# (cx-1vlzr; fetched as cmux-tui-host.exe next to cmux-tui.exe). Optional:
# published when the Windows commit manifest attests it, skipped when that
# manifest predates it, so republishing an older tree writes the same
# completion-windows.json bytes. --list-windows-optional-companions lists it.
# acpmux for GPUI on Windows (cx-ephhf; scripts/fetch-acpmux.sh in cmux-gpui)
# is optional the same way: its own build job may fail, and Windows builds
# from before it have none.
WINDOWS_OPTIONAL_NAMES = (
    "cmux-tui-host-x86_64-pc-windows-gnu.exe",
    "cmux-tui-acpmux-x86_64-pc-windows-gnu.exe",
)
# acpmux for GPUI on Linux and macOS (hq-1f; the Windows build is a Windows
# companion above). The cmux-tui build makes it for every Unix target and the
# commit manifest attests it, so a tree carries each one that manifest attests
# (a pull request tree's manifest, built from its downloaded artifacts, has
# none). completion.json attests them: a new tree's completion.json lists
# them beside GATE_NAMES. A republication of a tree whose completion.json
# exists keeps that file's names (existing_completion_file), so a tree
# published before acpmux writes the same immutable bytes and gets no acpmux.
# The workflow reads this list with --list-acpmux-companions.
ACPMUX_NAMES = (
    "cmux-tui-acpmux-x86_64-unknown-linux-musl",
    "cmux-tui-acpmux-aarch64-unknown-linux-musl",
    "cmux-tui-acpmux-aarch64-apple-darwin",
    "cmux-tui-acpmux-x86_64-apple-darwin",
)
REPAIR_POINTER = "cmuxterm-hq REPAIR.md#cmux-tui-tree-publication"


class PublicationError(RuntimeError):
    pass


class PublicationConflict(PublicationError):
    """Another publisher wrote this tree's source.json first, with other bytes.

    Raised only with --conflict-exit-code, and only for source.json, which a
    publication writes first: the caller then waits for that publication to
    complete and keeps it (two runs of one tree key at once). A conflict on
    any later object stays a hard failure.
    """


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
    conflict_exit_code: int | None = None,
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
    if conflict_exit_code is not None:
        command += ["--conflict-exit-code", str(conflict_exit_code)]
    try:
        result = subprocess.run(command, check=False, text=True, capture_output=True)
    except OSError as error:
        raise PublicationError(f"could not execute trusted uploader {uploader}: {error}") from error
    if conflict_exit_code is not None and result.returncode == conflict_exit_code:
        raise PublicationConflict(
            f"another publisher wrote {key} first with other bytes: "
            f"{(result.stderr or result.stdout).strip() or 'no output'}"
        )
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
    windows_manifest_file: Path | None = None,
    windows_source_commit: str | None = None,
    existing_completion_file: Path | None = None,
    conflict_exit_code: int | None = None,
) -> dict[str, str]:
    """Validate and publish all tree companions (COMPANION_NAMES).

    ``manifest_file`` is the immutable commit-addressed manifest that attests
    the bytes.  ``source_file`` is an existing tree source.json, when present;
    it is retained as-is for repairs.  A new publisher may set
    ``publish_source`` to write its generated source metadata once.

    ``windows_manifest_file`` and ``windows_source_commit`` (together) also
    publish WINDOWS_NAMES from ``assets_dir``, attested by that commit's
    manifest, and record them in completion-windows.json.

    ACPMUX_NAMES that ``manifest_file`` attests are published too and listed
    in completion.json. ``existing_completion_file`` is the tree's published
    completion.json, when there is one: completion.json is write-once, so the
    publication then lists exactly that file's names again (and publishes no
    acpmux that it does not list).
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

    existing_gate: set[str] | None = None
    if existing_completion_file is not None:
        existing = _load_json(existing_completion_file, "published completion.json")
        if existing.get("key") != key:
            raise PublicationError("published completion.json key does not match requested key")
        existing_binaries = existing.get("binaries")
        if not isinstance(existing_binaries, dict):
            raise PublicationError("published completion.json has no binaries object")
        existing_gate = set(existing_binaries)
        unknown = existing_gate - set(GATE_NAMES) - set(ACPMUX_NAMES)
        if unknown:
            raise PublicationError(
                f"published completion.json lists binaries this publisher does not know: {sorted(unknown)}"
            )
    for name in ACPMUX_NAMES:
        if binaries.get(name) is None:
            if existing_gate is not None and name in existing_gate:
                raise PublicationError(
                    f"published completion.json lists {name}, which the commit manifest does not attest"
                )
            continue
        if existing_gate is not None and name not in existing_gate:
            continue
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
    gate_names = set(GATE_NAMES) | (set(digests) & set(ACPMUX_NAMES))
    if existing_gate is not None and existing_gate != gate_names:
        raise PublicationError(
            f"published completion.json lists {sorted(existing_gate)}, this publication {sorted(gate_names)}"
        )

    windows_digests: dict[str, str] = {}
    if (windows_manifest_file is None) != (windows_source_commit is None):
        raise PublicationError("--windows-manifest-file and --windows-source-commit go together")
    if windows_manifest_file is not None and windows_source_commit is not None:
        if len(windows_source_commit) != 40 or any(
            character not in "0123456789abcdef" for character in windows_source_commit
        ):
            raise PublicationError(f"invalid Windows source commit {windows_source_commit!r}")
        windows_manifest = _load_json(windows_manifest_file, "Windows commit manifest")
        windows_commit = windows_manifest.get("commit", windows_manifest.get("sourceCommit"))
        if windows_commit != windows_source_commit:
            raise PublicationError(
                f"Windows commit manifest source {windows_commit!r} does not match {windows_source_commit}"
            )
        windows_binaries = windows_manifest.get("binaries")
        if not isinstance(windows_binaries, dict):
            raise PublicationError("Windows commit manifest has no binaries object")
        for name in WINDOWS_NAMES:
            expected = _require_sha(windows_binaries.get(name), f"Windows manifest binary {name}")
            path = assets_dir / name
            if not path.is_file():
                raise PublicationError(f"missing companion {name} in {assets_dir}")
            actual = _sha256(path)
            if actual != expected:
                raise PublicationError(
                    f"companion {name} digest {actual} does not match commit manifest {expected}"
                )
            windows_digests[name] = actual
        for name in WINDOWS_OPTIONAL_NAMES:
            if windows_binaries.get(name) is None:
                continue
            expected = _require_sha(windows_binaries.get(name), f"Windows manifest binary {name}")
            path = assets_dir / name
            if not path.is_file():
                raise PublicationError(f"missing companion {name} in {assets_dir}")
            actual = _sha256(path)
            if actual != expected:
                raise PublicationError(
                    f"companion {name} digest {actual} does not match commit manifest {expected}"
                )
            windows_digests[name] = actual

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
            conflict_exit_code=conflict_exit_code,
        )

    with tempfile.TemporaryDirectory(prefix="cmux-tui-tree-") as temporary:
        temporary_dir = Path(temporary)
        upload_files: list[tuple[Path, str]] = []
        for name, digest in {**digests, **windows_digests}.items():
            binary = assets_dir / name
            checksum = temporary_dir / f"{name}.sha256"
            checksum.write_text(f"{digest}  {name}\n")
            upload_files.extend(((binary, name), (checksum, f"{name}.sha256")))

        # The source object stays first and completion.json stays last, but
        # binary/checksum objects are independent immutable writes. Upload
        # them together so a tree's required companions do not serialize on
        # the R2 round-trip (the old loop was the second-longest tree leg).
        def upload_file(item: tuple[Path, str]) -> None:
            file, name = item
            _upload(
                uploader,
                file,
                endpoint_url=endpoint_url,
                bucket=bucket,
                key=f"{prefix}/{name}",
                cache_control=cache,
            )

        workers = min(8, max(1, len(upload_files)))
        with ThreadPoolExecutor(max_workers=workers, thread_name_prefix="cmux-tree-upload") as pool:
            futures = [pool.submit(upload_file, item) for item in upload_files]
            for future in as_completed(futures):
                future.result()

        def write_completion(
            name: str, binaries: dict[str, str], commit: str = source_commit
        ) -> None:
            completion: dict[str, Any] = {
                "schemaVersion": 1,
                "key": key,
                "sourceCommit": commit,
                "binaries": binaries,
            }
            if commit == source_commit and source_file is not None and source_file.is_file():
                completion["sourceSha256"] = _sha256(source_file)
            completion_file = temporary_dir / name
            completion_file.write_text(json.dumps(completion, indent=2, sort_keys=True) + "\n")
            _upload(
                uploader,
                completion_file,
                endpoint_url=endpoint_url,
                bucket=bucket,
                key=f"{prefix}/{name}",
                cache_control=cache,
            )

        if windows_digests and windows_source_commit is not None:
            write_completion("completion-windows.json", windows_digests, windows_source_commit)
        write_completion("completion-linux.json", {n: d for n, d in digests.items() if n not in gate_names})
        # Last: the cmux-next gate reads completion.json as "the tree is complete".
        write_completion("completion.json", {n: d for n, d in digests.items() if n in gate_names})
    return {**digests, **windows_digests}


def main(argv: list[str] | None = None) -> int:
    argv = sys.argv[1:] if argv is None else argv
    if argv == ["--list-companions"]:
        print("\n".join(COMPANION_NAMES))
        return 0
    if argv == ["--list-windows-companions"]:
        print("\n".join(WINDOWS_NAMES))
        return 0
    if argv == ["--list-windows-optional-companions"]:
        print("\n".join(WINDOWS_OPTIONAL_NAMES))
        return 0
    if argv == ["--list-acpmux-companions"]:
        print("\n".join(ACPMUX_NAMES))
        return 0
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--list-companions", action="store_true",
                        help="print the companion names, one per line, and exit")
    parser.add_argument("--list-windows-companions", action="store_true",
                        help="print the Windows companion names, one per line, and exit")
    parser.add_argument("--list-windows-optional-companions", action="store_true",
                        help="print the optional Windows companion names, one per line, and exit")
    parser.add_argument("--list-acpmux-companions", action="store_true",
                        help="print the acpmux companion names, one per line, and exit")
    parser.add_argument("--key", required=True)
    parser.add_argument("--source-commit", required=True)
    parser.add_argument("--assets-dir", type=Path, required=True)
    parser.add_argument("--manifest-file", type=Path, required=True)
    parser.add_argument("--source-file", type=Path)
    parser.add_argument("--publish-source", action="store_true")
    parser.add_argument("--windows-manifest-file", type=Path,
                        help="the commit manifest that attests the Windows companions")
    parser.add_argument("--windows-source-commit",
                        help="the commit whose build the Windows companions are")
    parser.add_argument("--existing-completion-file", type=Path,
                        help="the tree's published completion.json: this publication lists the same names")
    parser.add_argument("--uploader", type=Path, required=True)
    parser.add_argument("--endpoint-url", required=True)
    parser.add_argument("--bucket", required=True)
    parser.add_argument("--conflict-exit-code", type=int,
                        help="exit with this code, with no immutable-r2-conflict annotation, when another "
                             "publisher wrote source.json first; the caller waits for that publication")
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
            windows_manifest_file=args.windows_manifest_file,
            windows_source_commit=args.windows_source_commit,
            existing_completion_file=args.existing_completion_file,
            conflict_exit_code=args.conflict_exit_code,
        )
    except PublicationConflict as error:
        print(f"cmux-tui tree {args.key}: {error}", file=sys.stderr)
        return args.conflict_exit_code
    except (OSError, PublicationError, ValueError) as error:
        print(f"cmux-tui tree publication failed: {error}; see {REPAIR_POINTER}", file=sys.stderr)
        return 1
    print(f"Completed cmux-tui tree {args.key}: {', '.join(sorted(digests))}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
