#!/usr/bin/env python3
"""Carry source mtimes across Testboxes that share the warm target sticky disk.

Cargo decides freshness of workspace crates and build scripts by mtime: a
source newer than the recorded build output is dirty. Every Testbox checks the
repository out fresh, so every source file looks new and the warm target dir
from the sticky disk would rebuild every workspace crate and rerun the Ghostty
zig build anyway.

`record` runs on the box that is about to commit the disk. It writes the git
blob id and mtime of every file in the checkout (but build output and
dependency stores), and the
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
missing or different, and Cargo then reruns their build scripts. Output built
with CMUX_GHOSTTY_VT_ZIG_CPU=baseline runs on every x86-64 host (hq's
testbox-run.sh sets it on every Testbox command). On a CPU change only the
build script runs that did not record that value are dropped (with their out
dirs); compile units and baseline runs stay. Measured
2026-10-12: 5 of 9 warmups landed on another CPU model (AMD EPYC and Intel
Xeon hosts share the label) and rebuilt ghostty-vt-sys (40-110 s) and all
its dependents.

The manifest comes from a disk that candidate code wrote, so restore parses it
strictly, touches only regular files inside the repository, and never follows
a symlink.
"""

import hashlib
import json
import os
import shutil
import sys

SKIP_DIRS = {".git", "target", ".zig-cache", "zig-cache", "zig-out", "node_modules", ".build", "DerivedData", "testbox-benchmark"}
MANIFEST_VERSION = "cmux-testbox-source-mtimes-v2"
CPU_RECORD = ".cmux-testbox-cpu"
# Packages whose build script compiles for the host CPU (zig native target).
NATIVE_CPU_PACKAGES = ("ghostty-vt-sys",)
# The build script input that makes their output portable, and its value.
PORTABLE_CPU_ENV = ("CMUX_GHOSTTY_VT_ZIG_CPU", "baseline")


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


def fingerprint_kind(path: str):
    """For a .fingerprint/<package>-<hash> dir: "portable" for a build script
    run that recorded PORTABLE_CPU_ENV, "native" for any other run or a dir
    Cargo's records do not explain, "compile" for a compile unit (a lib, a
    test, the build script binary): rustc output, the same on every x86-64
    host."""
    try:
        names = [name for name in os.listdir(path) if name.endswith(".json")]
    except OSError:
        return "native"
    runs = [name for name in names if name.startswith("run-build-script-")]
    if not runs:
        return "compile" if names else "native"
    for name in runs:
        full = os.path.join(path, name)
        value = None
        try:
            if not os.path.islink(full):
                with open(full, encoding="utf-8") as handle:
                    record = json.load(handle)
                for item in record.get("local") or []:
                    env = item.get("RerunIfEnvChanged") if isinstance(item, dict) else None
                    if isinstance(env, dict) and env.get("var") == PORTABLE_CPU_ENV[0]:
                        value = env.get("val")
        except (OSError, ValueError, AttributeError):
            value = None
        if value != PORTABLE_CPU_ENV[1]:
            return "native"
    return "portable"


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
    # Only a build script run's out dir (build/<package>-<hash>, named like its
    # .fingerprint dir) holds code for the host CPU. Drop each run that was
    # not built for the baseline CPU, with its out dir, and every dir Cargo's
    # records do not explain. Cargo reruns those, and their newer output makes
    # the lib that bundles it and everything linking it rebuild. Compile units
    # and baseline runs stay. The out dir must go with its fingerprint dir: the
    # missing build/<hash>/output is what marks the run, and through it the
    # kept lib unit, stale.
    paths = list(native_output_dirs(target))
    kinds = {
        path: fingerprint_kind(path)
        for path in paths
        if os.path.basename(os.path.dirname(path)) == ".fingerprint"
    }
    drop = set()
    for path in paths:
        if path in kinds:
            if kinds[path] == "native":
                drop.add(path)
            continue
        twin = os.path.join(os.path.dirname(os.path.dirname(path)), ".fingerprint", os.path.basename(path))
        if kinds.get(twin, "native") == "native":
            drop.add(path)
    for path in paths:
        if path in drop:
            shutil.rmtree(path)
    print(
        f"source-mtimes: CPU differs from the snapshot (or is unknown); removed "
        f"{len(drop)} native-CPU build dirs ({', '.join(NATIVE_CPU_PACKAGES)}), kept "
        f"{len(paths) - len(drop)} (compile units and runs built with "
        f"{PORTABLE_CPU_ENV[0]}={PORTABLE_CPU_ENV[1]})"
    )
    # Every native output left in target/ is now for this CPU (or absent), so
    # say so at once. Otherwise a failed `record` at release would commit new
    # output beside the old host's record, and a box on that old host would
    # keep the foreign library.
    write_cpu_record(target)


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
    """Yield (kind, path): "F" for regular files, "D" for directories.

    The whole checkout but SKIP_DIRS: cmux-tui crates include_str! files from
    schemas/, backend/, plans/ and skills/, so those are Cargo inputs too
    (about 21,000 files in all)."""
    for dirpath, dirnames, filenames in os.walk(repo):
        if dirpath != repo and "\t" not in dirpath and "\n" not in dirpath:
            yield "D", dirpath
        dirnames[:] = [
            name for name in dirnames
            if name not in SKIP_DIRS and not os.path.islink(os.path.join(dirpath, name))
        ]
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
                or any(part in SKIP_DIRS for part in relative.split(os.sep))
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
