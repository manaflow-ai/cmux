#!/usr/bin/env python3
"""Release helpers for cmux-browser-host (plans/cmux-next/browser-host.md 6d).

  browser-host-release.py version TAG CARGO_TOML
      print the version a cmux-browser-host-vX.Y.Z[-rN] tag names; exit 1 when
      the tag is malformed or differs from the release version.
  browser-host-release.py crate-version CARGO_TOML
      print the release version (the name of push-build archives too): the
      crate's version (`version.workspace = true` resolves to the workspace's
      [workspace.package] version), plus `-rN` when the crate sets
      [package.metadata.cmux-release] revision = N. The binary stays on the one
      cmux-next version (scripts/cmux-next/check-version-surfaces.sh checks the
      copy the macOS app bundles), so a host-only Linux release takes a revision
      instead of a crate bump.
  browser-host-release.py package BINARY VERSION TARGET OUTDIR
      write OUTDIR/cmux-browser-host-VERSION-TARGET.tar.gz holding
      bin/cmux-browser-host, LICENSE (the repository's GPL-3.0-or-later text)
      and THIRD_PARTY_LICENSES.md (the committed Linux notices,
      cmux-tui/build-support/notices/browser-host/THIRD_PARTY_LICENSES.linux.md;
      linux_release_notices.py --check keeps it current) with fixed owner, mode
      and mtime, so the same inputs give the same archive bytes, and print its
      path.
  browser-host-release.py notes VERSION SHA REPOSITORY GLIBC_FLOOR
      print the GitHub release notes; they link the exact source commit
      https://github.com/REPOSITORY/commit/SHA.
  browser-host-release.py entries BASE_URL VERSION ARCHIVE...
      print {"schema": 2, "packages": [...]}: the channel-manifest package
      entries (name, version, url, sha256, size, roles, and the required arch
      and target of schema 2) for the archives, one per target. Unsigned:
      signing is the channel's step.
"""

from __future__ import annotations

import gzip
import hashlib
import io
import json
import re
import sys
import tarfile
import tomllib
from pathlib import Path

NAME = "cmux-browser-host"
TARGETS = ("x86_64-unknown-linux-gnu", "aarch64-unknown-linux-gnu")
# Channel manifest schema 2 (decision MANIFEST-ARCH): arch and target are required per entry.
SCHEMA = 2
VERSION_RE = re.compile(r"[0-9]+\.[0-9]+\.[0-9]+(?:-r[0-9]+)?")
ROOT = Path(__file__).resolve().parents[2]
LICENSE = ROOT / "LICENSE"
NOTICES = ROOT / "cmux-tui/build-support/notices/browser-host/THIRD_PARTY_LICENSES.linux.md"


def crate_version(cargo_toml: Path) -> str:
    """The crate's [package] version; `version.workspace = true` takes the workspace's.

    The workspace is the nearest Cargo.toml with a [workspace] table, starting with the crate's
    own (a crate can be its workspace root), as Cargo finds it. Anything else that is not a plain
    version string is an error, not a mismatch.
    """
    version = tomllib.loads(cargo_toml.read_text())["package"]["version"]
    if version == {"workspace": True}:
        for directory in cargo_toml.resolve().parents:
            manifest = directory / "Cargo.toml"
            if not manifest.is_file():
                continue
            workspace = tomllib.loads(manifest.read_text()).get("workspace")
            if workspace is not None:
                version = (workspace.get("package") or {}).get("version")
                break
    if not isinstance(version, str):
        raise SystemExit(f"{cargo_toml}: cannot read the crate version (got {version!r})")
    return version


def release_version(cargo_toml: Path) -> str:
    """The crate version plus `-rN` for [package.metadata.cmux-release] revision = N."""
    package = tomllib.loads(cargo_toml.read_text())["package"]
    revision = ((package.get("metadata") or {}).get("cmux-release") or {}).get("revision")
    version = crate_version(cargo_toml)
    if revision is None:
        return version
    if not isinstance(revision, int) or isinstance(revision, bool) or revision < 1:
        raise SystemExit(f"{cargo_toml}: [package.metadata.cmux-release] revision must be a positive integer (got {revision!r})")
    return f"{version}-r{revision}"


def tag_version(tag: str, cargo_toml: str) -> str:
    match = re.fullmatch(rf"{NAME}-v({VERSION_RE.pattern})", tag)
    if not match:
        raise SystemExit(f"tag must be {NAME}-vX.Y.Z or {NAME}-vX.Y.Z-rN (got {tag!r})")
    release = release_version(Path(cargo_toml))
    if release != match.group(1):
        raise SystemExit(f"tag {tag} names {match.group(1)} but {cargo_toml} says {release}")
    return release


def package(binary: str, version: str, target: str, outdir: str) -> Path:
    if not VERSION_RE.fullmatch(version) or target not in TARGETS:
        raise SystemExit(f"bad version {version!r} or target {target!r}")
    data = Path(binary).read_bytes()
    members = (
        ("LICENSE", 0o644, LICENSE.read_bytes()),
        ("THIRD_PARTY_LICENSES.md", 0o644, NOTICES.read_bytes()),
        ("bin", 0o755, None),
        (f"bin/{NAME}", 0o755, data),
    )
    raw = io.BytesIO()
    with tarfile.open(fileobj=raw, mode="w", format=tarfile.PAX_FORMAT) as tar:
        for name, mode, payload in members:
            info = tarfile.TarInfo(name)
            info.mode, info.mtime, info.uid, info.gid, info.uname, info.gname = mode, 0, 0, 0, "", ""
            if payload is None:
                info.type = tarfile.DIRTYPE
                tar.addfile(info)
            else:
                info.size = len(payload)
                tar.addfile(info, io.BytesIO(payload))
    out = Path(outdir) / f"{NAME}-{version}-{target}.tar.gz"
    out.parent.mkdir(parents=True, exist_ok=True)
    with open(out, "wb") as f, gzip.GzipFile(filename="", mode="wb", fileobj=f, mtime=0) as gz:
        gz.write(raw.getvalue())
    return out


def entries(base_url: str, version: str, archives: list[str]) -> dict:
    out = []
    for archive in archives:
        path = Path(archive)
        match = re.fullmatch(rf"{NAME}-{re.escape(version)}-({'|'.join(TARGETS)})\.tar\.gz", path.name)
        if not match:
            raise SystemExit(f"unexpected archive name {path.name}")
        data = path.read_bytes()
        target = match.group(1)
        out.append({"name": NAME, "version": version, "url": f"{base_url.rstrip('/')}/{path.name}",
                    "sha256": hashlib.sha256(data).hexdigest(), "size": len(data), "roles": ["all"],
                    "arch": target.split("-", 1)[0], "target": target})
    if sorted(e["target"] for e in out) != sorted(TARGETS):
        raise SystemExit(f"need one archive per target {TARGETS}, got {[e['target'] for e in out]}")
    return {"schema": SCHEMA, "packages": out}


def notes(version: str, sha: str, repository: str, glibc_floor: str) -> str:
    if not VERSION_RE.fullmatch(version) or not re.fullmatch(r"[0-9a-f]{40}", sha):
        raise SystemExit(f"bad version {version!r} or commit {sha!r} (need the full 40-character sha)")
    return (
        f"cmux-browser-host {version} for Linux (x86_64, aarch64; glibc >= {glibc_floor}).\n\n"
        f"Source commit: https://github.com/{repository}/commit/{sha}\n\n"
        "Each archive holds bin/cmux-browser-host, LICENSE (GPL-3.0-or-later) and "
        "THIRD_PARTY_LICENSES.md (the third-party notices of the binary).\n\n"
        "Channel-manifest entries: manifest-entries.json (unsigned; verify with gh attestation verify).\n"
    )


def main(argv: list[str]) -> int:
    if len(argv) == 3 and argv[0] == "version":
        print(tag_version(argv[1], argv[2]))
    elif len(argv) == 2 and argv[0] == "crate-version":
        print(release_version(Path(argv[1])))
    elif len(argv) == 5 and argv[0] == "package":
        print(package(*argv[1:]))
    elif len(argv) == 5 and argv[0] == "notes":
        print(notes(*argv[1:]), end="")
    elif len(argv) >= 4 and argv[0] == "entries":
        print(json.dumps(entries(argv[1], argv[2], argv[3:]), indent=2))
    else:
        print(__doc__, file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
