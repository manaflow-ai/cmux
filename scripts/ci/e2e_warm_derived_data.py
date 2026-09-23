#!/usr/bin/env python3
"""Let an E2E build start from the last DerivedData main compiled.

    e2e_warm_derived_data.py record WORKSPACE MANIFEST
    e2e_warm_derived_data.py replay WORKSPACE MANIFEST
    e2e_warm_derived_data.py restore WORKSPACE DERIVED_DATA KEY

The compiled product archive carries Build/Products only. Without the build
database and intermediates next to it, xcodebuild cannot tell what is already
built, so a revision that changes one test file recompiles the whole app host:
691 of the 735 seconds `build-for-testing` spends is the app scheme.

Xcode decides what to rebuild from modification times, and a fresh checkout
stamps every file with the checkout time. `record` writes the content digest
and modification time of every build input before a compile. `replay` restores
the recorded time only onto files whose content is byte-identical, so an
unchanged file looks as old as the build that consumed it, and stamps every
other file with the current time. A changed file cannot keep an old time: files
unpacked from an archive (GhosttyKit, SwiftPM binary artifacts) carry the
archive's times, which may predate the producer's build. Correctness never depends on how close
the adopted DerivedData is to this revision; distance only costs compile time.

`restore` adopts the newest DerivedData archive for KEY that a `main` run of
this workflow published. Any miss, expiry or transfer failure is a cold build.
"""
from __future__ import annotations

import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tarfile
import tempfile
import zipfile

WORKFLOW_PATH = ".github/workflows/test-e2e.yml"
ARCHIVE = "derived-data.tar.gz"
MANIFEST = "cmux-e2e-input-mtimes.json"
PREFIX = "e2e-derived-data-v1-"
# Never walk into build outputs or git metadata: they are not inputs, and
# DerivedData lives inside the workspace on every runner pool.
SKIPPED_DIRECTORIES = frozenset({".git", "DerivedData"})
# Beyond this a download loses to the compile it replaces.
MAX_ARTIFACT_BYTES = 12 * 1024**3


def digest(path: Path) -> str:
    checksum = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            checksum.update(block)
    return checksum.hexdigest()


def inputs(workspace: Path):
    for root, directories, files in os.walk(workspace):
        directories[:] = sorted(d for d in directories if d not in SKIPPED_DIRECTORIES)
        for name in sorted(files):
            path = Path(root, name)
            if path.is_symlink() or not path.is_file():
                continue
            yield path.relative_to(workspace).as_posix(), path


def record(workspace: Path) -> dict[str, list]:
    return {
        relative: [digest(path), path.stat().st_mtime_ns]
        for relative, path in inputs(workspace)
    }


def replay(workspace: Path, recorded: dict[str, list]) -> tuple[int, int]:
    restored = changed = 0
    for relative, path in inputs(workspace):
        entry = recorded.get(relative)
        if entry is None or entry[0] != digest(path):
            os.utime(path)
            changed += 1
            continue
        os.utime(path, ns=(entry[1], entry[1]))
        restored += 1
    return restored, changed


def api(path: str) -> dict:
    output = subprocess.run(["gh", "api", path], check=True, capture_output=True, text=True).stdout
    return json.loads(output)


def trusted(artifact: dict, repository: str) -> bool:
    """Only main's own runs of this workflow may seed a build of another ref."""
    run = artifact.get("workflow_run") or {}
    if artifact.get("expired") or run.get("head_branch") != "main":
        return False
    if run.get("head_repository_id") not in (None, run.get("repository_id")):
        return False
    details = api(f"repos/{repository}/actions/runs/{run['id']}")
    return details.get("path") == WORKFLOW_PATH and details.get("event") == "workflow_dispatch"


def newest(repository: str, key: str) -> dict | None:
    listing = api(f"repos/{repository}/actions/artifacts?name={PREFIX}{key}&per_page=20")
    candidates = sorted(listing.get("artifacts", []), key=lambda a: a.get("created_at", ""), reverse=True)
    return next((a for a in candidates if trusted(a, repository)), None)


def extract(archive: Path, destination: Path) -> None:
    with tarfile.open(archive) as bundle:
        for member in bundle.getmembers():
            target = (destination / member.name).resolve()
            if destination.resolve() not in target.parents and target != destination.resolve():
                raise ValueError(f"archive member escapes DerivedData: {member.name}")
            if member.issym() or member.islnk():
                # Xcode links within DerivedData, sometimes by absolute path;
                # the key pins that path, so it is the same on both sides.
                link = Path(member.linkname)
                base = destination if member.islnk() or link.is_absolute() else target.parent
                resolved = (base / link).resolve()
                if destination.resolve() not in resolved.parents and resolved != destination.resolve():
                    raise ValueError(f"archive link escapes DerivedData: {member.name}")
        if hasattr(tarfile, "tar_filter"):
            # Every member and link target is bounded above. The default
            # `data` filter would also refuse Xcode's absolute in-tree links.
            bundle.extractall(destination, filter="tar")
        else:
            bundle.extractall(destination)


def restore(workspace: Path, derived: Path, key: str) -> dict[str, object]:
    repository = os.environ["GITHUB_REPOSITORY"]
    artifact = newest(repository, key)
    if artifact is None:
        return {"hit": "false", "reason": "no-main-derived-data"}
    if int(artifact.get("size_in_bytes") or 0) > MAX_ARTIFACT_BYTES:
        return {"hit": "false", "reason": "derived-data-too-large"}
    with tempfile.TemporaryDirectory() as staging:
        bundle = Path(staging, "artifact.zip")
        with bundle.open("wb") as stream:
            subprocess.run(
                ["gh", "api", f"repos/{repository}/actions/artifacts/{artifact['id']}/zip"],
                check=True, stdout=stream,
            )
        with zipfile.ZipFile(bundle) as archive:
            archive.extractall(staging)
        extract(Path(staging, ARCHIVE), derived)
    recorded = json.loads((derived / MANIFEST).read_text())
    restored, changed = replay(workspace, recorded)
    return {
        "hit": "true",
        "producer_run_id": str(artifact["workflow_run"]["id"]),
        "unchanged_inputs": str(restored),
        "changed_inputs": str(changed),
    }


def main(argv: list[str]) -> int:
    if len(argv) == 4 and argv[1] in {"record", "replay"}:
        workspace, manifest = Path(argv[2]).resolve(), Path(argv[3])
        if argv[1] == "record":
            manifest.write_text(json.dumps(record(workspace), sort_keys=True))
            print(f"Recorded {len(json.loads(manifest.read_text()))} build inputs")
        else:
            restored, changed = replay(workspace, json.loads(manifest.read_text()))
            print(f"Replayed {restored} unchanged inputs; {changed} changed or new")
        return 0
    if len(argv) == 5 and argv[1] == "restore":
        derived = Path(argv[3])
        try:
            result = restore(Path(argv[2]).resolve(), derived, argv[4])
        except Exception as error:  # noqa: BLE001 - every failure means a cold build
            # A half-extracted DerivedData is worse than none: start cold.
            shutil.rmtree(derived, ignore_errors=True)
            derived.mkdir(parents=True, exist_ok=True)
            result = {"hit": "false", "reason": f"{type(error).__name__}: {error}"[:200]}
        print(json.dumps(result, sort_keys=True))
        if "GITHUB_OUTPUT" in os.environ:
            with open(os.environ["GITHUB_OUTPUT"], "a") as handle:
                for name, value in result.items():
                    handle.write(f"{name}={value}\n")
        return 0
    print(__doc__, file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
