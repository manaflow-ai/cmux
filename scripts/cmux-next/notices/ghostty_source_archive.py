#!/usr/bin/env python3
# Copyright 2026 Manaflow, Inc.
# SPDX-License-Identifier: GPL-3.0-or-later
"""The cmux-next release source archive for Ghostty and its Zig packages.

  ghostty_source_archive.py build --ghostty-source DIR --zig-cache DIR
      --license-manifest SOURCE-MANIFEST.json --revision SHA
      --cmux-commit SHA --tag TAG --out ARCHIVE.tar.gz
      [--next-name NAME --next-source DIR --next-license-manifest M --next-revision SHA]
  ghostty_source_archive.py verify --archive ARCHIVE.tar.gz
      --license-manifest SOURCE-MANIFEST.json --revision SHA
      [--next-name NAME --next-license-manifest M --next-revision SHA]
  ghostty_source_archive.py offer
      prints the --release-source-offer line for collect-ghostty-licenses.py

The archive holds Ghostty's tracked files at the build's revision and every
Zig package in the license collector's zig_packages index, from
<ghostty>/zig-pkg/ (Zig 0.16) or <zig cache>/p/ (older Zig), plus
CORRESPONDING-SOURCE.json (the cmux commit, its public tag, the Ghostty
revision, each package's dependency name and URL). The MPL-2.0 source offer
then names this archive and the tag; it does not rely on upstream URLs.

--next-*: a second Ghostty tree, the libghostty-vt source of bin/cmux
(ghostty-next, resolved from the cmux tree by check_ghostty_vt_notices.py),
goes in as <root>/<next name>/ with its own collected license manifest; its
Zig packages join zig-packages/ (directories are content hashes) and
CORRESPONDING-SOURCE.json records it under "ghostty_next".

Deterministic: entries sorted by path, mtime 0, uid/gid 0, no user or group
names, modes 0644/0755 (directories 0755), symlinks kept as links, gzip
header without a name or time. The same input gives the same bytes.
Python 3.11+ standard library and git only.
"""

from __future__ import annotations

import argparse
import gzip
import io
import json
from pathlib import Path
import subprocess
import sys
import tarfile

REPOSITORY = "https://github.com/manaflow-ai/cmux"
RELEASE = "nightly-next"
ASSET = "cmux-next-source-<build>.tar.gz"
TAG = "cmux-next-src-<commit, 11 characters>"


def prefix(cmux_commit: str) -> str:
    return f"cmux-next-source-{cmux_commit[:11]}"


def offer_line() -> str:
    return (
        f"the cmux release source archive {ASSET}, published with this release at "
        f"{REPOSITORY}/releases/download/{RELEASE}/ (<build> is the build number in the "
        f"app's version), and the cmux source of this build at its public tag "
        f"{REPOSITORY}/tree/{TAG}. The archive contains Ghostty at the revision this "
        "build uses and every Ghostty Zig package archive, including this one."
    )


class ArchiveError(RuntimeError):
    pass


def _info(name: str, kind: bytes, mode: int, size: int = 0, link: str = "") -> tarfile.TarInfo:
    info = tarfile.TarInfo(name)
    info.type = kind
    info.mode = mode
    info.size = size
    info.linkname = link
    info.mtime = 0
    info.uid = info.gid = 0
    info.uname = info.gname = ""
    return info


def _tree_entries(root: Path, archive_root: str, paths: list[str]) -> dict[str, tuple]:
    """archive path -> (kind, mode, data, link) for files under root."""
    entries: dict[str, tuple] = {}
    for rel in paths:
        path = root / rel
        name = f"{archive_root}/{rel}"
        for parent in Path(rel).parents:
            if parent != Path("."):
                entries.setdefault(f"{archive_root}/{parent.as_posix()}", (tarfile.DIRTYPE, 0o755, b"", ""))
        if path.is_symlink():
            entries[name] = (tarfile.SYMTYPE, 0o777, b"", str(path.readlink()))
        elif path.is_file():
            mode = 0o755 if path.stat().st_mode & 0o111 else 0o644
            entries[name] = (tarfile.REGTYPE, mode, path.read_bytes(), "")
    return entries


def _package_files(package: Path) -> list[str]:
    files = []
    for path in sorted(package.rglob("*")):
        rel = path.relative_to(package)
        if ".git" in rel.parts:
            continue
        if path.is_symlink() or path.is_file():
            files.append(rel.as_posix())
    return files


def _zig_packages(manifest: Path, revision: str) -> dict[str, dict]:
    data = json.loads(manifest.read_text(encoding="utf-8"))
    if data.get("ghostty_revision") != revision:
        raise ArchiveError(f"{manifest} is for Ghostty {data.get('ghostty_revision')}, not {revision}")
    if data.get("unresolved_packages"):
        raise ArchiveError(f"{manifest} has unresolved packages: {data['unresolved_packages']}")
    return data.get("zig_packages", {})


def _add_tree(entries: dict, root: str, name: str, source: Path, zig_cache: Path, packages: dict, revision: str) -> dict:
    """Tracked files of one Ghostty tree and its Zig packages; returns its index."""
    head = subprocess.run(["git", "-C", str(source), "rev-parse", "HEAD"], check=True, capture_output=True, text=True).stdout.strip()
    if head != revision:
        raise ArchiveError(f"{source} is at {head}, not {revision}")
    tracked = subprocess.run(["git", "-C", str(source), "ls-files", "-z"], check=True, capture_output=True).stdout.decode().split("\0")
    entries.update(_tree_entries(source, f"{root}/{name}", [p for p in tracked if p]))
    index = {}
    for directory in sorted(packages):
        candidates = [source / "zig-pkg" / directory, zig_cache / "p" / directory]
        found = next((c for c in candidates if c.is_dir()), None)
        if found is None:
            raise ArchiveError(f"Zig package {directory} ({packages[directory].get('dependency')}) of {name} is not in zig-pkg/ or the cache; fetch it first")
        files = _package_files(found)
        entries.update(_tree_entries(found, f"{root}/zig-packages/{directory}", files))
        index[directory] = {**packages[directory], "files": len(files)}
    return index


def _next_args(args: argparse.Namespace, build: bool) -> bool:
    names = ["next_name", "next_license_manifest", "next_revision"] + (["next_source"] if build else [])
    given = [getattr(args, n) is not None for n in names]
    if any(given) and not all(given):
        raise ArchiveError("--next-* options go together: " + ", ".join("--" + n.replace("_", "-") for n in names))
    if all(given) and args.next_name in ("ghostty", "zig-packages", "CORRESPONDING-SOURCE.json"):
        raise ArchiveError(f"--next-name {args.next_name} collides with the archive layout")
    return all(given)


def build(args: argparse.Namespace) -> None:
    packages = _zig_packages(args.license_manifest, args.revision)
    root = prefix(args.cmux_commit)
    entries: dict[str, tuple] = {}
    index = _add_tree(entries, root, "ghostty", args.ghostty_source, args.zig_cache, packages, args.revision)
    meta = {
        "schema": 1,
        "cmux_commit": args.cmux_commit,
        "tag": args.tag,
        "tag_url": f"{REPOSITORY}/tree/{args.tag}",
        "ghostty_revision": args.revision,
        "zig_packages": index,
    }
    if _next_args(args, build=True):
        next_packages = _zig_packages(args.next_license_manifest, args.next_revision)
        meta["ghostty_next"] = {
            "path": args.next_name,
            "revision": args.next_revision,
            "zig_packages": _add_tree(entries, root, args.next_name, args.next_source, args.zig_cache, next_packages, args.next_revision),
        }
    data = (json.dumps(meta, indent=2, sort_keys=True) + "\n").encode()
    entries[f"{root}/CORRESPONDING-SOURCE.json"] = (tarfile.REGTYPE, 0o644, data, "")
    entries.setdefault(root, (tarfile.DIRTYPE, 0o755, b"", ""))
    raw = io.BytesIO()
    with tarfile.open(fileobj=raw, mode="w", format=tarfile.PAX_FORMAT) as tar:
        for name in sorted(entries):
            kind, mode, content, link = entries[name]
            info = _info(name, kind, mode, len(content), link)
            tar.addfile(info, io.BytesIO(content) if kind == tarfile.REGTYPE else None)
    args.out.parent.mkdir(parents=True, exist_ok=True)
    with args.out.open("wb") as handle, gzip.GzipFile(filename="", mode="wb", fileobj=handle, mtime=0, compresslevel=9) as gz:
        gz.write(raw.getvalue())
    extra = f", {args.next_name} {args.next_revision[:11]} ({len(meta['ghostty_next']['zig_packages'])} Zig packages)" if "ghostty_next" in meta else ""
    print(f"wrote {args.out}: Ghostty {args.revision[:11]}, {len(index)} Zig packages{extra}, {len(entries)} entries")


def verify(args: argparse.Namespace) -> None:
    packages = _zig_packages(args.license_manifest, args.revision)
    with tarfile.open(args.archive) as tar:
        names = tar.getnames()
        metas = [n for n in names if n.endswith("/CORRESPONDING-SOURCE.json") and n.count("/") == 1]
        if len(metas) != 1:
            raise ArchiveError("the archive has no CORRESPONDING-SOURCE.json at its root")
        root = metas[0].split("/")[0]
        meta = json.loads(tar.extractfile(metas[0]).read())
    if meta.get("ghostty_revision") != args.revision:
        raise ArchiveError(f"the archive is for Ghostty {meta.get('ghostty_revision')}, not {args.revision}")
    if not meta.get("tag") or not meta.get("tag_url", "").startswith(f"{REPOSITORY}/tree/"):
        raise ArchiveError("the archive names no public cmux tag")
    if f"{root}/ghostty/build.zig.zon" not in names:
        raise ArchiveError("the archive has no Ghostty source")
    present = {n.split("/")[2] for n in names if n.startswith(f"{root}/zig-packages/") and n.count("/") >= 3}
    missing = sorted(set(packages) - present)
    if missing:
        raise ArchiveError("the archive misses Zig packages: " + ", ".join(missing))
    if _next_args(args, build=False):
        next_packages = _zig_packages(args.next_license_manifest, args.next_revision)
        recorded = meta.get("ghostty_next") or {}
        if recorded.get("path") != args.next_name or recorded.get("revision") != args.next_revision:
            raise ArchiveError(f"the archive has no {args.next_name} tree at {args.next_revision}")
        if f"{root}/{args.next_name}/build.zig.zon" not in names:
            raise ArchiveError(f"the archive has no {args.next_name} source")
        missing = sorted(set(next_packages) - present)
        if missing:
            raise ArchiveError(f"the archive misses {args.next_name} Zig packages: " + ", ".join(missing))
    print(f"verified {args.archive}: Ghostty {args.revision[:11]}, {len(packages)} Zig packages, tag {meta['tag']}")


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="command", required=True)
    b = sub.add_parser("build")
    for flag in ("--ghostty-source", "--zig-cache", "--license-manifest", "--out"):
        b.add_argument(flag, type=Path, required=True)
    for flag in ("--revision", "--cmux-commit", "--tag"):
        b.add_argument(flag, required=True)
    v = sub.add_parser("verify")
    v.add_argument("--archive", type=Path, required=True)
    v.add_argument("--license-manifest", type=Path, required=True)
    v.add_argument("--revision", required=True)
    for p in (b, v):
        p.add_argument("--next-name")
        p.add_argument("--next-license-manifest", type=Path)
        p.add_argument("--next-revision")
    b.add_argument("--next-source", type=Path)
    sub.add_parser("offer")
    args = parser.parse_args(argv)
    try:
        if args.command == "build":
            build(args)
        elif args.command == "verify":
            verify(args)
        else:
            print(offer_line())
    except (ArchiveError, OSError, subprocess.CalledProcessError, tarfile.TarError) as error:
        print(f"ghostty_source_archive: error: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
