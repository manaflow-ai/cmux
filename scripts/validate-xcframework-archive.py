#!/usr/bin/env python3

from pathlib import PurePosixPath
import sys
import tarfile


ROOTS = {
    "GhosttyKit.xcframework",
    "GhosttySceneRendererKit.xcframework",
}


def normalize(name: str) -> str:
    while name.startswith("./"):
        name = name[2:]
    return name


def is_safe_member(name: str) -> bool:
    path = PurePosixPath(name)
    return not path.is_absolute() and ".." not in path.parts


def main() -> None:
    if len(sys.argv) != 2:
        raise SystemExit("usage: validate-xcframework-archive.py <archive>")

    archive = sys.argv[1]
    with tarfile.open(archive, "r:gz") as tar:
        saw_roots: set[str] = set()
        for member in tar.getmembers():
            name = normalize(member.name)
            if not is_safe_member(name):
                raise SystemExit(f"unsafe archive entry: {member.name}")
            root = next(
                (
                    candidate
                    for candidate in ROOTS
                    if name == candidate or name.startswith(candidate + "/")
                ),
                None,
            )
            if root is None:
                raise SystemExit(f"unexpected archive entry: {member.name}")
            if name == root or name == root + "/":
                saw_roots.add(root)
            if member.islnk() or member.issym():
                target = normalize(member.linkname)
                if not target or not is_safe_member(target):
                    raise SystemExit(f"unsafe archive link target: {member.linkname}")
            elif not (member.isfile() or member.isdir()):
                raise SystemExit(f"unsupported archive member: {member.name}")

        missing = ROOTS - saw_roots
        if missing:
            raise SystemExit(f"archive missing {', '.join(sorted(missing))}")


if __name__ == "__main__":
    main()
