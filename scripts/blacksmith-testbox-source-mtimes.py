#!/usr/bin/env python3
"""Carry source mtimes across Testboxes that share the warm target sticky disk.

Cargo decides freshness of workspace crates and build scripts by mtime: a
source newer than the recorded build output is dirty. Every Testbox checks the
repository out fresh, so every source file looks new and the warm target dir
from the sticky disk would rebuild every workspace crate and rerun the Ghostty
zig build anyway.

`record` runs on the box that is about to commit the disk. It writes the git
blob id and mtime of every file under the Cargo-relevant source dirs, and the
entry-list hash and mtime of every directory there (Cargo's
`rerun-if-changed` on a directory compares directory mtimes too), into the
target dir, next to the artifacts those mtimes describe.

`restore` runs on the next box after checkout. A file whose content is
byte-identical to the recorded one, or a directory whose entry names are
identical, gets its recorded mtime back, which is the exact state the
committed artifacts were built against. Anything changed, added, or missing
from the manifest keeps its fresh mtime, so Cargo rebuilds it. Correctness therefore never depends on the manifest: a wrong or
hostile manifest can only make a file look as old as an identical file did.

Both commands also handle CPU-specific build output. ghostty-vt-sys builds
libghostty-vt for zig's native CPU, so a warm target dir written on one
Blacksmith host CPU makes every binary that links it die with SIGILL on
another. `record` stores a CPU fingerprint next to the manifest. `restore`
removes those packages' build and fingerprint dirs when the fingerprint is
missing or different, and Cargo then reruns their build scripts.

The manifest comes from a disk that candidate code wrote, so restore parses it
strictly, touches only regular files inside the repository, and never follows
a symlink.
"""

import hashlib
import os
import shutil
import sys

SOURCE_DIRS = ("cmux-tui", "ghostty", "ghostty-next")
SKIP_DIRS = {".git", "target", ".zig-cache", "zig-cache", "zig-out", "node_modules"}
MANIFEST_VERSION = "cmux-testbox-source-mtimes-v2"
CPU_RECORD = ".cmux-testbox-cpu"
# Packages whose build script compiles for the host CPU (zig native target).
NATIVE_CPU_PACKAGES = ("ghostty-vt-sys",)


def cpu_fingerprint() -> str:
    """Hash of the CPU model and feature flags: what zig's native target uses."""
    path = os.environ.get("CMUX_TESTBOX_CPUINFO", "/proc/cpuinfo")
    model = flags = ""
    try:
        with open(path, encoding="utf-8", errors="replace") as handle:
            for line in handle:
                key, _, value = line.partition(":")
                key = key.strip()
                if key == "model name" and not model:
                    model = value.strip()
                elif key == "flags" and not flags:
                    flags = " ".join(sorted(value.split()))
                if model and flags:
                    break
    except OSError:
        return ""
    if not flags:
        return ""
    return hashlib.sha256(f"{model}\n{flags}".encode()).hexdigest()


def native_output_dirs(target: str):
    """Build and fingerprint dirs of NATIVE_CPU_PACKAGES at any profile depth."""
    for dirpath, dirnames, _ in os.walk(target):
        depth = os.path.relpath(dirpath, target).count(os.sep)
        if os.path.basename(dirpath) in ("build", ".fingerprint"):
            for name in dirnames:
                if any(name.startswith(package + "-") for package in NATIVE_CPU_PACKAGES):
                    path = os.path.join(dirpath, name)
                    if not os.path.islink(path):
                        yield path
            dirnames[:] = []
        elif depth >= 2 or os.path.islink(dirpath):
            dirnames[:] = []
        else:
            dirnames[:] = [
                name for name in dirnames
                if not os.path.islink(os.path.join(dirpath, name))
                and name not in ("deps", "incremental", "examples")
            ]


def drop_foreign_cpu_outputs(target: str) -> None:
    if not os.path.isdir(target) or os.path.islink(target):
        return
    current = cpu_fingerprint()
    record = os.path.join(target, CPU_RECORD)
    recorded = ""
    if os.path.isfile(record) and not os.path.islink(record):
        with open(record, encoding="utf-8", errors="replace") as handle:
            recorded = handle.read().strip()
    if current and recorded == current:
        print("source-mtimes: same CPU as the snapshot; native build output kept")
        return
    removed = 0
    for path in list(native_output_dirs(target)):
        shutil.rmtree(path)
        removed += 1
    print(
        f"source-mtimes: CPU differs from the snapshot (or is unknown); removed "
        f"{removed} native-CPU build dirs ({', '.join(NATIVE_CPU_PACKAGES)})"
    )


def write_cpu_record(target: str) -> None:
    record = os.path.join(target, CPU_RECORD)
    try:
        os.unlink(record)
    except FileNotFoundError:
        pass
    current = cpu_fingerprint()
    if not current:
        return
    descriptor = os.open(record, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o644)
    with os.fdopen(descriptor, "w", encoding="utf-8") as out:
        out.write(current + "\n")


def blob_id(path: str) -> str:
    with open(path, "rb") as handle:
        data = handle.read()
    digest = hashlib.sha1()
    digest.update(b"blob %d\0" % len(data))
    digest.update(data)
    return digest.hexdigest()


def listing_id(path: str) -> str:
    """Hash of a directory's entry names and kinds: what its mtime tracks."""
    digest = hashlib.sha1()
    for entry in sorted(os.scandir(path), key=lambda e: e.name):
        kind = "l" if entry.is_symlink() else "d" if entry.is_dir() else "f"
        digest.update(f"{kind}:{entry.name}\0".encode("utf-8", "surrogateescape"))
    return digest.hexdigest()


def source_entries(repo: str):
    """Yield (kind, path): "F" for regular files, "D" for directories."""
    for top in SOURCE_DIRS:
        root = os.path.join(repo, top)
        if not os.path.isdir(root) or os.path.islink(root):
            continue
        for dirpath, dirnames, filenames in os.walk(root):
            if "\t" not in dirpath and "\n" not in dirpath:
                yield "D", dirpath
            dirnames[:] = [name for name in dirnames if name not in SKIP_DIRS]
            for name in filenames:
                path = os.path.join(dirpath, name)
                if os.path.islink(path) or not os.path.isfile(path):
                    continue
                if "\t" in path or "\n" in path:
                    continue
                yield "F", path


def record(repo: str, manifest: str) -> int:
    repo = os.path.realpath(repo)
    count = 0
    temporary = manifest + ".tmp"
    # The manifest dir is a sticky disk that candidate code wrote: never write
    # through a planted symlink.
    try:
        os.unlink(temporary)
    except FileNotFoundError:
        pass
    descriptor = os.open(
        temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o644
    )
    with os.fdopen(descriptor, "w", encoding="utf-8") as out:
        out.write(MANIFEST_VERSION + "\n")
        for kind, path in source_entries(repo):
            stat = os.lstat(path)
            identity = blob_id(path) if kind == "F" else listing_id(path)
            relative = os.path.relpath(path, repo)
            out.write(f"{kind}\t{identity}\t{stat.st_mtime_ns}\t{relative}\n")
            count += 1
    os.replace(temporary, manifest)
    write_cpu_record(os.path.dirname(os.path.abspath(manifest)))
    print(f"source-mtimes: recorded {count} files and directories")
    return 0


def restore(repo: str, manifest: str) -> int:
    repo = os.path.realpath(repo)
    drop_foreign_cpu_outputs(os.path.dirname(os.path.abspath(manifest)))
    if not os.path.isfile(manifest) or os.path.islink(manifest):
        print("source-mtimes: no manifest; every source stays fresh (cold build)")
        return 0
    restored = changed = skipped = 0
    with open(manifest, encoding="utf-8", errors="strict") as handle:
        if handle.readline().rstrip("\n") != MANIFEST_VERSION:
            print("source-mtimes: unknown manifest version; ignoring it")
            return 0
        for line in handle:
            parts = line.rstrip("\n").split("\t")
            if len(parts) != 4 or parts[0] not in ("F", "D"):
                skipped += 1
                continue
            kind, blob, mtime_ns, relative = parts
            if (
                len(blob) != 40
                or any(c not in "0123456789abcdef" for c in blob)
                or not mtime_ns.isdigit()
                or os.path.isabs(relative)
                or relative.split(os.sep)[0] not in SOURCE_DIRS
            ):
                skipped += 1
                continue
            path = os.path.normpath(os.path.join(repo, relative))
            if not path.startswith(repo + os.sep) or relative != os.path.relpath(path, repo):
                skipped += 1
                continue
            # Refuse any symlink on the way, so a path cannot leave the repo.
            parent = repo
            safe = True
            for component in os.path.relpath(path, repo).split(os.sep):
                parent = os.path.join(parent, component)
                if os.path.islink(parent):
                    safe = False
                    break
            exists = os.path.isfile(path) if kind == "F" else os.path.isdir(path)
            if not safe or not exists:
                skipped += 1
                continue
            if (blob_id(path) if kind == "F" else listing_id(path)) != blob:
                changed += 1
                continue
            mtime = int(mtime_ns)
            # Never date a file into the future: that would hide a later edit.
            if mtime > os.lstat(path).st_mtime_ns:
                skipped += 1
                continue
            os.utime(path, ns=(mtime, mtime), follow_symlinks=False)
            restored += 1
    print(
        f"source-mtimes: restored {restored} files and directories, {changed} changed since the "
        f"snapshot stay fresh, {skipped} entries skipped"
    )
    return 0


def main(argv: list[str]) -> int:
    if len(argv) != 4 or argv[1] not in ("record", "restore"):
        print(f"usage: {argv[0]} record|restore <repo> <manifest>", file=sys.stderr)
        return 2
    command, repo, manifest = argv[1:]
    return record(repo, manifest) if command == "record" else restore(repo, manifest)


if __name__ == "__main__":
    sys.exit(main(sys.argv))
