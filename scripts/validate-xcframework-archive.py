#!/usr/bin/env python3

from pathlib import PurePosixPath
import sys
import tarfile


ROOT = "GhosttyKit.xcframework"


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
        saw_root = False
        for member in tar.getmembers():
            name = normalize(member.name)
            if not is_safe_member(name):
                raise SystemExit(f"unsafe archive entry: {member.name}")
            if name != ROOT and not name.startswith(ROOT + "/"):
                raise SystemExit(f"unexpected archive entry: {member.name}")
            if name == ROOT or name == ROOT + "/":
                saw_root = True
            if member.islnk() or member.issym():
                target = normalize(member.linkname)
                if not target or not is_safe_member(target):
                    raise SystemExit(f"unsafe archive link target: {member.linkname}")
            elif not (member.isfile() or member.isdir()):
                raise SystemExit(f"unsupported archive member: {member.name}")

        if not saw_root:
            raise SystemExit(f"archive missing {ROOT}")


if __name__ == "__main__":
    main()
