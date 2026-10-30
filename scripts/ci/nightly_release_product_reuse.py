#!/usr/bin/env python3
"""Reuse the compiled, unsigned cmux NEXT Nightly app when nothing it is built from changed.

nightly.yml's build-nightly-app (track nightly-next, push runs on branch nightly-next only) keys its
products with `job_input_fingerprint.py nightly-release-product`: the git object ids of every tree
path that can reach the app (the DEV product's closure), the whole nightly.yml, `decide`'s outputs
that reach the build (job_input_fingerprint.NIGHTLY_PRODUCT_FLAGS), Xcode, the SDK, the arch, the
cmux-tui tree it bundles and RECIPE. The key is content only: no branch, commit or path.

The products are the unsigned app exactly as the job hands it on (after the Computer Use helper,
the Iroh stub drop and the strip) plus the dSYMs xcodebuild wrote beside it. Nothing in them names
the run: the version, build number and CMUXCommit are stamped by build-sign-notarize-nightly, and
signing, notarization and publication always run fresh at the exact SHA.

The record and lookup logic is dev_release_product_reuse.py's, in a lane of its own (NIGHTLY): its
own record and product artifact names, workflow, branch and events, so a DEV record is never a
nightly record, and the reverse. A record is taken only from this repository's own push run of
nightly.yml on nightly-next whose build-nightly-app finished successfully, and the archive's SHA-256
must match it. Every problem is a miss with a reason, and the job compiles.

Commands (lookup and record as in dev_release_product_reuse.py):
  lookup --key K --out DIR --products DIR  a hit also unpacks the products into --products
  record --key K --sha SHA --archive A --out manifest.json
  pack --products DIR --out ARCHIVE        archive= (empty with reason= when the app is incomplete)
  builder --derived-data DIR --out FILE    the builder's facts; recordable=true only on a fresh VM
                                           whose DerivedData and compilation cache start empty

Records come only from fresh VMs (GitHub-hosted or Blacksmith) that start from an empty
DerivedData: an owned runner keeps a compilation cache, Rust target directories and helper caches
between jobs, which the key does not name and which other jobs on that user can write.
"""

from __future__ import annotations

import argparse
import gzip
import io
import json
import os
import shutil
import sys
import tarfile
import tempfile
import unicodedata
from contextlib import redirect_stdout
from pathlib import Path, PurePosixPath

sys.path.insert(0, str(Path(__file__).resolve().parent))
import dev_release_product_reuse as reuse  # noqa: E402

RECIPE = reuse.NIGHTLY_NEXT_RECIPE
NIGHTLY = reuse.NIGHTLY_NEXT
APP = "cmux.app"
# A build whose optional inputs were unreadable (ensure-cef.sh --optional,
# ensure-remote-browser-host.sh --optional) ships without them; it is never recorded, so a reuse
# never carries a missing engine forward.
# Bounds on what an archive may unpack to (the real products are about 1.5 GB in about 30,000
# entries): past them the archive is refused, never unpacked.
MAX_MEMBERS = 400_000
MAX_EXPANDED_BYTES = 12 * 1024**3
REQUIRED = ("Contents/Frameworks/Chromium Embedded Framework.framework",
            "Contents/Helpers/cmux-remote-browser-host.app")


def product_members(products: Path) -> list[str]:
    """cmux.app and every dSYM outside it, relative to the products directory."""
    members = [APP]
    for path in sorted(products.rglob("*.dSYM")):
        rel = path.relative_to(products)
        if rel.parts[0] == APP or any(part.endswith(".dSYM") for part in rel.parts[:-1]):
            continue
        members.append(str(rel))
    return members


class _ForgetInodes(dict):
    """tarfile's inode table, kept empty, so it never writes a hard link member."""

    def __setitem__(self, key, value) -> None:
        return None


def pack(products: Path, out: Path) -> dict[str, str]:
    app = products / APP
    if not app.is_dir() or app.is_symlink():
        return {"archive": "", "reason": f"no {APP} directory in {products}"}
    missing = [part for part in REQUIRED if not (app / part).exists()]
    if missing:
        return {"archive": "", "reason": f"the app lacks {', '.join(missing)}; not recorded"}
    out.parent.mkdir(parents=True, exist_ok=True)
    members = product_members(products)
    try:
        # gzip level 1: most of the bytes are the Chromium engine, which barely compresses.
        with tarfile.open(out, "w:gz", compresslevel=1, format=tarfile.PAX_FORMAT) as archive:
            # Store a file with several hard links once per name: unpack refuses hard links.
            archive.inodes = _ForgetInodes()
            for member in members:
                archive.add(products / member, arcname=member)  # symlinks stay symlinks
    except OSError as error:
        out.unlink(missing_ok=True)
        return {"archive": "", "reason": f"packing failed: {error}"}
    return {"archive": str(out), "members": str(len(members))}


# A PAX or GNU long-name header holds one path or a few attributes; tarfile reads it whole.
MAX_EXTENSION_HEADER_BYTES = 64 * 1024
MAX_SYMLINK_HOPS = 40


def prescan(archive: Path) -> None:
    """Walk the raw tar headers (streamed, constant memory) before tarfile parses any of them, so
    an extension header past its bound, too many entries or too many bytes is a miss, not a
    memory or disk exhaustion."""
    entries = 0
    expanded = 0
    try:
        with gzip.open(archive, "rb") as stream:
            while True:
                header = stream.read(512)
                if len(header) < 512:
                    raise reuse.Miss("the archive ends inside a tar header")
                if header == b"\0" * 512:
                    return
                field = header[124:136]
                if field[0] & 0x80:  # base-256: never needed for a member under 8 GiB
                    raise reuse.Miss("the archive has a base-256 size field")
                try:
                    size = int(field.split(b"\0", 1)[0].strip() or b"0", 8)
                except ValueError as error:
                    raise reuse.Miss("the archive has an unreadable tar header") from error
                kind = header[156:157]
                if kind in (b"x", b"g", b"L", b"K") and size > MAX_EXTENSION_HEADER_BYTES:
                    raise reuse.Miss(f"the archive has a {size}-byte extension header")
                entries += 1
                expanded += size
                if entries > MAX_MEMBERS * 2:  # each member may carry one extension header
                    raise reuse.Miss(f"the archive has more than {MAX_MEMBERS} members")
                if expanded > MAX_EXPANDED_BYTES:
                    raise reuse.Miss(f"the archive unpacks to more than {MAX_EXPANDED_BYTES} bytes")
                left = (size + 511) // 512 * 512
                while left:
                    chunk = stream.read(min(left, 1 << 20))
                    if not chunk:
                        raise reuse.Miss("the archive ends inside a member")
                    left -= len(chunk)
    except (OSError, EOFError) as error:
        raise reuse.Miss(f"the archive is not a readable gzip tar: {error}") from error


def fold(name: str) -> str:
    """A path as APFS, where the app is unpacked, compares it: insensitive to letter case and to
    Unicode normalization (Unicode canonical caseless matching, NFD(casefold(NFD(name)))). The
    checks below run on exact and on folded names, so an archive is refused when either a
    case-sensitive or an APFS volume would let it out, on every OS."""
    return unicodedata.normalize("NFD", unicodedata.normalize("NFD", name).casefold())


def same(name: str) -> str:
    return name


def resolve(parts: list[str], links: dict[str, str], key=same) -> None:
    """Follow `parts` from the products root through every symlink in the archive (`links` is keyed
    by key(name): exact or folded names); raise Miss when the walk ever leaves the root (a chain
    like a -> . then b -> a/../..) or loops."""
    position: list[str] = []
    queue = list(parts)
    hops = 0
    while queue:
        part = queue.pop(0)
        if part in ("", "."):
            continue
        if part == "..":
            if not position:
                raise reuse.Miss(f"a symlink in the archive leads outside it ({'/'.join(parts)})")
            position.pop()
            continue
        name = "/".join(position + [part])
        if key(name) in links:
            hops += 1
            if hops > MAX_SYMLINK_HOPS or links[key(name)].startswith("/"):
                raise reuse.Miss(f"the archive's symlink {name!r} loops or is absolute")
            queue = links[key(name)].split("/") + queue
            continue
        position.append(part)


def safe_members(archive: tarfile.TarFile) -> list[tarfile.TarInfo]:
    """Every member, refusing anything that could land outside the products directory (a path
    with `..`, a symlink chain that leaves it, a member under a symlink), a duplicate, a symlink
    in place of the app, and an archive past MAX_MEMBERS or MAX_EXPANDED_BYTES."""
    members: list[tarfile.TarInfo] = []
    expanded = 0
    for member in archive:  # the headers are bounded by prescan
        members.append(member)
        if len(members) > MAX_MEMBERS:
            raise reuse.Miss(f"the archive has more than {MAX_MEMBERS} members")
        expanded += max(member.size, 0)
        if expanded > MAX_EXPANDED_BYTES:
            raise reuse.Miss(f"the archive unpacks to more than {MAX_EXPANDED_BYTES} bytes")
        path = PurePosixPath(member.name)
        if path.is_absolute() or ".." in path.parts or not path.parts:
            raise reuse.Miss(f"the archive has an unsafe member {member.name!r}")
        if path.parts[0] != APP and not any(part.endswith(".dSYM") for part in path.parts):
            raise reuse.Miss(f"the archive member {member.name!r} is neither the app nor a dSYM")
        if not (member.isfile() or member.isdir() or member.issym()):
            raise reuse.Miss(f"the archive member {member.name!r} is not a file, directory or symlink")
        if member.issym() and len(path.parts) == 1:
            raise reuse.Miss(f"the archive's top-level {member.name!r} is a symlink")
        member.mode &= 0o755  # no setuid, setgid or world-writable bits
    names = [str(PurePosixPath(member.name)) for member in members]
    if len({fold(name) for name in names}) != len(names):
        raise reuse.Miss("the archive names a member twice (letter case ignored)")
    links = {name: member.linkname for member, name in zip(members, names) if member.issym()}
    folded = {fold(name): link for name, link in links.items()}
    for member, name in zip(members, names):
        parts = name.split("/")
        # pack() adds directories without following links, so nothing is ever stored under one.
        for depth in range(1, len(parts)):
            if fold("/".join(parts[:depth])) in folded:
                raise reuse.Miss(f"the archive member {name!r} lies under a symlink")
        if member.issym():
            if not member.linkname or member.linkname.startswith("/"):
                raise reuse.Miss(f"the archive's symlink {name!r} is absolute or empty")
            resolve(parts[:-1] + member.linkname.split("/"), links)
            resolve(parts[:-1] + member.linkname.split("/"), folded, fold)
    return members


def inside(root: str, path: str) -> bool:
    return path == root or path.startswith(root + os.sep)


def extract(source: tarfile.TarFile, members: list[tarfile.TarInfo], staging: Path) -> None:
    """Every file and directory first, then the symlinks, so nothing is ever written through a
    link (the names are checked case-sensitively, the volume may not be). Each write's directory,
    and then each link, is resolved by the filesystem itself and must stay inside staging."""
    root = os.path.realpath(staging)
    links = [member for member in members if member.issym()]
    for member in [member for member in members if not member.issym()]:
        parent = os.path.realpath(os.path.join(root, os.path.dirname(member.name)))
        if not inside(root, parent):
            raise reuse.Miss(f"the archive member {member.name!r} would land outside it")
        source.extract(member, root, set_attrs=member.isfile())  # noqa: S202 - checked above
    for member in links:
        parent = os.path.realpath(os.path.join(root, os.path.dirname(member.name)))
        if not inside(root, parent):
            raise reuse.Miss(f"the archive's symlink {member.name!r} would land outside it")
        os.symlink(member.linkname, os.path.join(parent, os.path.basename(member.name)))
    for member in links:
        if not inside(root, os.path.realpath(os.path.join(root, member.name))):
            raise reuse.Miss(f"the archive's symlink {member.name!r} points outside it")


def unpack(archive: Path, products: Path) -> None:
    """Unpack verified bytes into an empty products directory, or raise Miss (leaving it empty)."""
    if products.exists() and any(products.iterdir()):
        raise reuse.Miss(f"{products} is not empty; not unpacking over a build")
    products.parent.mkdir(parents=True, exist_ok=True)
    # Unpack beside it and rename into place: an unpack cut short never leaves a partial app where
    # a compile would then merge into it.
    staging = Path(tempfile.mkdtemp(prefix=f".{products.name}.unpack-", dir=products.parent))
    try:
        prescan(archive)
        with tarfile.open(archive, "r:gz") as source:
            extract(source, safe_members(source), staging)
        app = staging / APP
        if app.is_symlink() or not app.is_dir() or (app / "Contents").is_symlink() \
                or not (app / "Contents/Info.plist").is_file():
            raise reuse.Miss(f"the archive holds no {APP}")
        if products.exists():
            products.rmdir()
        staging.rename(products)
    except (reuse.Miss, tarfile.TarError, OSError, EOFError) as why:
        shutil.rmtree(staging, ignore_errors=True)
        raise reuse.Miss(f"unpacking the archive failed: {why}") from why


def builder(env: dict[str, str], derived: Path) -> dict:
    """Who builds this job and what its build starts from, measured before it compiles: the kind of
    runner (reuse.builder_kind) and whether DerivedData and the compilation cache in it are empty
    (an owned runner links a kept cache into it). A record is written only when both hold
    (reuse.clean_builder), and a lookup takes only such records."""
    kind = reuse.builder_kind(env.get("RUNNER_NAME", ""), env.get("RUNNER_ENVIRONMENT", ""))
    cache = derived / "CompilationCache.noindex"
    empty = not derived.is_symlink() and (not derived.exists() or (derived.is_dir() and not any(derived.iterdir())))
    return {"runner_name": env.get("RUNNER_NAME", ""), "runner_environment": env.get("RUNNER_ENVIRONMENT", ""),
            "kind": kind, "fresh_vm": kind in reuse.FRESH_RUNNER_GROUPS,
            "start": {"derived_data": "empty" if empty else "kept",
                      "compilation_cache": "empty" if empty or not (cache.exists() or cache.is_symlink()) else "kept"}}


def lookup(argv: list[str], products: Path) -> int:
    """The shared lookup, then the unpack; any failure of either is a miss."""
    buffer = io.StringIO()
    with redirect_stdout(buffer):
        reuse.main(["lookup", *argv], lane=NIGHTLY)
    outputs = dict(line.split("=", 1) for line in buffer.getvalue().splitlines() if "=" in line)
    if outputs.get("hit") == "true":
        try:
            unpack(Path(outputs["archive"]), products)
            Path(outputs["archive"]).unlink(missing_ok=True)
        except (reuse.Miss, OSError, KeyError) as why:
            outputs = {"hit": "false", "reason": " ".join(str(why).split())[:500]}
            print(f"::notice title={NIGHTLY.name} Release product miss::{outputs['reason']}", file=sys.stderr)
    for name, value in outputs.items():
        print(f"{name}={value}")
    return 0


def main(argv: list[str] | None = None) -> int:
    argv = list(sys.argv[1:] if argv is None else argv)
    if argv and argv[0] == "pack":
        parser = argparse.ArgumentParser(prog="nightly_release_product_reuse.py pack")
        parser.add_argument("--products", required=True)
        parser.add_argument("--out", required=True)
        args = parser.parse_args(argv[1:])
        outputs = pack(Path(args.products), Path(args.out))
        if not outputs["archive"]:
            print(f"::notice title={NIGHTLY.name} Release product not recorded::{outputs['reason']}", file=sys.stderr)
        for name, value in outputs.items():
            print(f"{name}={value}")
        return 0
    if argv and argv[0] == "builder":
        parser = argparse.ArgumentParser(prog="nightly_release_product_reuse.py builder")
        parser.add_argument("--derived-data", required=True)
        parser.add_argument("--out", required=True)
        args = parser.parse_args(argv[1:])
        facts = builder(dict(os.environ), Path(args.derived_data))
        Path(args.out).parent.mkdir(parents=True, exist_ok=True)
        Path(args.out).write_text(json.dumps(facts, indent=2, sort_keys=True) + "\n")
        why = reuse.clean_builder(facts)
        print(f"builder={facts['kind']} {facts['runner_name']}")
        print(f"recordable={'false' if why else 'true'}")
        if why:
            print(f"::notice title={NIGHTLY.name} Release product not recorded::{why}", file=sys.stderr)
        return 0
    if argv and argv[0] == "lookup" and "--products" in argv:
        at = argv.index("--products")
        if at + 1 >= len(argv):
            print("lookup: --products needs a directory", file=sys.stderr)
            return 2
        products = Path(argv[at + 1])
        return lookup(argv[1:at] + argv[at + 2:], products)
    if argv and argv[0] == "lookup":
        print("lookup: --products is required for the nightly lane", file=sys.stderr)
        return 2
    return reuse.main(argv, lane=NIGHTLY)


if __name__ == "__main__":
    os.umask(0o022)
    sys.exit(main())
