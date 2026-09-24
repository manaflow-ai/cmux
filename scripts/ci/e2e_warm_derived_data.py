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

Directories are inputs too. Xcode signs a folder input such as
`Assets.xcassets` by the times of everything in it, the directories included,
so a checkout-time directory reruns the asset catalog, regenerates
`GeneratedAssetSymbols.swift` and recompiles every `cmuxTests` file: 241 s
against 50 s for an app source edit, measured on #14235. `record` also keeps
each directory's time under `<path>/`, beside a digest of its entry names, and
`replay` restores it only where those names are unchanged. Every file in it
still carries its own replayed time, so a changed file inside keeps the folder
out of date.

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

import parallel_artifact_download as transport

WORKFLOW_PATH = ".github/workflows/test-e2e.yml"
ARCHIVE = "derived-data.tar.gz"
MANIFEST = "cmux-e2e-input-mtimes.json"
PREFIX = "e2e-derived-data-v1-"
# Never walk into build outputs or git metadata: they are not inputs, and
# DerivedData lives inside the workspace on every runner pool.
SKIPPED_DIRECTORIES = frozenset({".git", "DerivedData"})


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


def directories(workspace: Path):
    """Each directory `inputs` walks, keyed `<path>/` (the workspace is `./`)."""
    for root, children, _ in os.walk(workspace):
        children[:] = sorted(
            d for d in children if d not in SKIPPED_DIRECTORIES and not Path(root, d).is_symlink()
        )
        path = Path(root)
        if path.is_symlink():
            continue
        yield path.relative_to(workspace).as_posix() + "/", path


def listing(path: Path) -> str:
    """Digest of a directory's entry names, which is what moves its time."""
    return hashlib.sha256("\n".join(sorted(os.listdir(path))).encode()).hexdigest()


def record(workspace: Path) -> dict[str, list]:
    recorded = {
        relative: [digest(path), path.stat().st_mtime_ns]
        for relative, path in inputs(workspace)
    }
    for key, path in directories(workspace):
        recorded[key] = [listing(path), path.stat().st_mtime_ns]
    return recorded


def replay(workspace: Path, recorded: dict[str, list]) -> tuple[int, int]:
    """Replay recorded times; the counts are files only.

    A manifest recorded before directories were kept has no `<path>/` keys,
    and its directories keep the checkout time, as they always did.
    """
    restored = changed = 0
    for relative, path in inputs(workspace):
        entry = recorded.get(relative)
        if entry is None or entry[0] != digest(path):
            os.utime(path)
            changed += 1
            continue
        os.utime(path, ns=(entry[1], entry[1]))
        restored += 1
    # Setting a file's time never moves its directory's, so order is free.
    for key, path in directories(workspace):
        entry = recorded.get(key)
        if entry is not None and entry[0] == listing(path):
            os.utime(path, ns=(entry[1], entry[1]))
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


def candidates(repository: str, key: str):
    """Trusted DerivedData artifacts for KEY, newest first."""
    listing = api(f"repos/{repository}/actions/artifacts?name={PREFIX}{key}&per_page=20")
    ordered = sorted(listing.get("artifacts", []), key=lambda a: a.get("created_at", ""), reverse=True)
    return (a for a in ordered if trusted(a, repository))


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


# Changes under these compile nothing into the app host; at most a resource
# is copied, and replay restamps it. A difference anywhere else, most often in
# a package every app file imports, recompiles the whole app target on top of
# adopted DerivedData, so the download only adds its own time (runs
# 35942257134, 35942449623).
OUTSIDE_THE_APP_BUILD = (
    "cmuxTests/", "cmuxUITests/", ".github/", "docs/", "scripts/ci/", "skills/", "tests/", "web/",
)
COMPARE_FILE_LIMIT = 300
# Each candidate costs three API reads; past a few, the newest seeds are all
# too far away and the build should start.
CANDIDATE_LIMIT = 4


def built_revision(run: dict) -> str | None:
    """The commit a producer run compiled, from its `… @ <ref>` title."""
    ref = str(run.get("display_title") or "").rpartition(" @ ")[2].split(" ", 1)[0]
    if len(ref) == 40 and all(c in "0123456789abcdef" for c in ref):
        return ref
    if ref == "main":
        return run.get("head_sha")
    return None


def outside_the_app_build(path: str) -> bool:
    return path.startswith(OUTSIDE_THE_APP_BUILD) or path.endswith(".md")


def app_build_changes(repository: str, producer: str, tested: str) -> list[str] | None:
    """Files between the two revisions that feed the app build, or None if unknown."""
    changed: set[str] = set()
    for base, head in ((producer, tested), (tested, producer)):
        comparison = api(f"repos/{repository}/compare/{base}...{head}")
        files = comparison.get("files") or []
        if len(files) >= COMPARE_FILE_LIMIT:
            return None
        for entry in files:
            changed.update(filter(None, (entry.get("filename"), entry.get("previous_filename"))))
    return sorted(path for path in changed if not outside_the_app_build(path))


def tested_revision(workspace: Path) -> str:
    return subprocess.run(
        ["git", "-C", str(workspace), "rev-parse", "HEAD"], check=True, capture_output=True, text=True,
    ).stdout.strip()


def near_producer(repository: str, artifact: dict, tested: str) -> tuple[str | None, str]:
    """The producer's revision and an empty reason if adopting it can save compile time."""
    run = api(f"repos/{repository}/actions/runs/{artifact['workflow_run']['id']}")
    producer = built_revision(run)
    if producer is None:
        return None, "producer-revision-unknown"
    if producer == tested:
        return producer, ""
    changes = app_build_changes(repository, producer, tested)
    if changes is None:
        return producer, "producer-too-far"
    if changes:
        return producer, f"app-build-changed-since-producer ({len(changes)} files, e.g. {changes[0]})"
    return producer, ""


def restore(workspace: Path, derived: Path, key: str) -> dict[str, object]:
    repository = os.environ["GITHUB_REPOSITORY"]
    tested = tested_revision(workspace)
    artifact = producer = None
    reason = "no-main-derived-data"
    for index, candidate in enumerate(candidates(repository, key)):
        if index == CANDIDATE_LIMIT:
            break
        # An older seed whose app sources match beats a newer one that differs.
        producer, reason = near_producer(repository, candidate, tested)
        if not reason:
            artifact = candidate
            break
    if artifact is None:
        return {"hit": "false", "reason": reason}
    if int(artifact.get("size_in_bytes") or 0) > transport.MAX_BYTES:
        return {"hit": "false", "reason": "derived-data-too-large"}
    expected = str(artifact.get("digest") or "")
    if not expected.startswith("sha256:"):
        return {"hit": "false", "reason": "derived-data-without-digest"}
    with tempfile.TemporaryDirectory() as staging:
        # One connection to the blob store sustains about 2 MB/s on the macOS
        # fleet, which took more than the step's 10 minutes for a 1.9 GB
        # archive (run 35896881813). Ranged requests read the same blob.
        bundle = Path(staging, "artifact.zip")
        transport.download_zip(repository, artifact["id"], bundle, artifact["size_in_bytes"])
        if transport.sha256_file(bundle) != expected.removeprefix("sha256:"):
            raise ValueError("DerivedData artifact does not match its provider digest")
        with zipfile.ZipFile(bundle) as archive:
            archive.extractall(staging)
        extract(Path(staging, ARCHIVE), derived)
    recorded = json.loads((derived / MANIFEST).read_text())
    restored, changed = replay(workspace, recorded)
    return {
        "hit": "true",
        "producer_run_id": str(artifact["workflow_run"]["id"]),
        "producer_revision": producer,
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
