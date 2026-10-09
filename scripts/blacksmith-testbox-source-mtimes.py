#!/usr/bin/env python3
"""Carry source mtimes across Testboxes that share the warm target sticky disk.

Cargo decides freshness of workspace crates and build scripts by mtime: a
source newer than the recorded build output is dirty. Every Testbox checks the
repository out fresh, so every source file looks new and the warm target dir
from the sticky disk would rebuild every workspace crate and rerun the Ghostty
zig build anyway.

`record` runs on the box that is about to commit the disk. It writes the git
blob id and mtime of every file under the Cargo-relevant source dirs into the
target dir, next to the artifacts those mtimes describe.

`restore` runs on the next box after checkout. A file whose content is
byte-identical to the recorded one gets its recorded mtime back, which is the
exact state the committed artifacts were built against. A file with different
content, or a file missing from the manifest, keeps its fresh mtime, so Cargo
rebuilds it. Correctness therefore never depends on the manifest: a wrong or
hostile manifest can only make a file look as old as an identical file did.

The manifest comes from a disk that candidate code wrote, so restore parses it
strictly, touches only regular files inside the repository, and never follows
a symlink.
"""

import hashlib
import os
import sys

SOURCE_DIRS = ("cmux-tui", "ghostty", "ghostty-next")
SKIP_DIRS = {".git", "target", ".zig-cache", "zig-cache", "zig-out", "node_modules"}
MANIFEST_VERSION = "cmux-testbox-source-mtimes-v1"


def blob_id(path: str) -> str:
    with open(path, "rb") as handle:
        data = handle.read()
    digest = hashlib.sha1()
    digest.update(b"blob %d\0" % len(data))
    digest.update(data)
    return digest.hexdigest()


def source_files(repo: str):
    for top in SOURCE_DIRS:
        root = os.path.join(repo, top)
        if not os.path.isdir(root) or os.path.islink(root):
            continue
        for dirpath, dirnames, filenames in os.walk(root):
            dirnames[:] = [name for name in dirnames if name not in SKIP_DIRS]
            for name in filenames:
                path = os.path.join(dirpath, name)
                if os.path.islink(path) or not os.path.isfile(path):
                    continue
                if "\t" in path or "\n" in path:
                    continue
                yield path


def record(repo: str, manifest: str) -> int:
    repo = os.path.realpath(repo)
    count = 0
    temporary = manifest + ".tmp"
    with open(temporary, "w", encoding="utf-8") as out:
        out.write(MANIFEST_VERSION + "\n")
        for path in source_files(repo):
            stat = os.lstat(path)
            relative = os.path.relpath(path, repo)
            out.write(f"{blob_id(path)}\t{stat.st_mtime_ns}\t{relative}\n")
            count += 1
    os.replace(temporary, manifest)
    print(f"source-mtimes: recorded {count} files")
    return 0


def restore(repo: str, manifest: str) -> int:
    repo = os.path.realpath(repo)
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
            if len(parts) != 3:
                skipped += 1
                continue
            blob, mtime_ns, relative = parts
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
            if not path.startswith(repo + os.sep):
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
            if not safe or not os.path.isfile(path):
                skipped += 1
                continue
            if blob_id(path) != blob:
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
        f"source-mtimes: restored {restored} files, {changed} changed since the "
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
