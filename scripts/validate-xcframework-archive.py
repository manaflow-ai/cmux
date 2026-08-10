#!/usr/bin/env python3

from pathlib import PurePosixPath
import sys
import tarfile
from typing import BinaryIO, Optional, Tuple


GHOSTTY_KIT_ROOT = "GhosttyKit.xcframework"
ROOTS = {
    GHOSTTY_KIT_ROOT,
    "GhosttySceneRendererKit.xcframework",
}
MACOS_LIBRARY_PREFIX = GHOSTTY_KIT_ROOT + "/macos-"
NATIVE_SENTRY_MARKERS = (
    b"sentry-init",
    b"sentry_options_new",
)


def normalize(name: str) -> str:
    while name.startswith("./"):
        name = name[2:]
    return name


def is_safe_member(name: str) -> bool:
    path = PurePosixPath(name)
    return not path.is_absolute() and ".." not in path.parts


def contains_marker(stream: BinaryIO, markers: Tuple[bytes, ...]) -> Optional[bytes]:
    longest_marker = max(len(marker) for marker in markers)
    overlap = b""
    while chunk := stream.read(1024 * 1024):
        data = overlap + chunk
        for marker in markers:
            if marker in data:
                return marker
        overlap = data[-(longest_marker - 1) :]
    return None


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

            if member.isfile() and name.startswith(MACOS_LIBRARY_PREFIX) and name.endswith(".a"):
                stream = tar.extractfile(member)
                if stream is None:
                    raise SystemExit(f"unable to inspect archive member: {member.name}")
                marker = contains_marker(stream, NATIVE_SENTRY_MARKERS)
                if marker is not None:
                    raise SystemExit(
                        "embedded macOS GhosttyKit contains native Sentry marker "
                        f"{marker.decode()!r}: {member.name}"
                    )

        missing = ROOTS - saw_roots
        if missing:
            raise SystemExit(f"archive missing {', '.join(sorted(missing))}")


if __name__ == "__main__":
    main()
