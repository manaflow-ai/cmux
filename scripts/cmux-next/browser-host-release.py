#!/usr/bin/env python3
"""Release helpers for cmux-browser-host (plans/cmux-next/browser-host.md 6d).

  browser-host-release.py version TAG CARGO_TOML
      print the version a cmux-browser-host-vX.Y.Z tag names; exit 1 when the
      tag is malformed or differs from the crate's [package] version.
  browser-host-release.py package BINARY VERSION TARGET OUTDIR
      write OUTDIR/cmux-browser-host-VERSION-TARGET.tar.gz holding
      bin/cmux-browser-host (fixed owner, mode and mtime, so the same binary
      gives the same archive bytes) and print its path.
  browser-host-release.py entries BASE_URL VERSION ARCHIVE...
      print the channel-manifest package entries (vm-image.md 4.5 schema 1:
      name, version, url, sha256, size, roles) for the archives, one per target,
      with the target as an extra field. Unsigned: signing is the channel's step.
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
VERSION_RE = re.compile(r"[0-9]+\.[0-9]+\.[0-9]+")


def tag_version(tag: str, cargo_toml: str) -> str:
    match = re.fullmatch(rf"{NAME}-v({VERSION_RE.pattern})", tag)
    if not match:
        raise SystemExit(f"tag must be {NAME}-vX.Y.Z (got {tag!r})")
    crate = tomllib.loads(Path(cargo_toml).read_text())["package"]["version"]
    if crate != match.group(1):
        raise SystemExit(f"tag {tag} names {match.group(1)} but {cargo_toml} says {crate}")
    return crate


def package(binary: str, version: str, target: str, outdir: str) -> Path:
    if not VERSION_RE.fullmatch(version) or target not in TARGETS:
        raise SystemExit(f"bad version {version!r} or target {target!r}")
    data = Path(binary).read_bytes()
    raw = io.BytesIO()
    with tarfile.open(fileobj=raw, mode="w", format=tarfile.PAX_FORMAT) as tar:
        for name, mode, payload in (("bin", 0o755, None), (f"bin/{NAME}", 0o755, data)):
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


def entries(base_url: str, version: str, archives: list[str]) -> list[dict]:
    out = []
    for archive in archives:
        path = Path(archive)
        match = re.fullmatch(rf"{NAME}-{re.escape(version)}-({'|'.join(TARGETS)})\.tar\.gz", path.name)
        if not match:
            raise SystemExit(f"unexpected archive name {path.name}")
        data = path.read_bytes()
        out.append({"name": NAME, "version": version, "url": f"{base_url.rstrip('/')}/{path.name}",
                    "sha256": hashlib.sha256(data).hexdigest(), "size": len(data), "roles": ["all"],
                    "target": match.group(1)})
    if sorted(e["target"] for e in out) != sorted(TARGETS):
        raise SystemExit(f"need one archive per target {TARGETS}, got {[e['target'] for e in out]}")
    return out


def main(argv: list[str]) -> int:
    if len(argv) == 3 and argv[0] == "version":
        print(tag_version(argv[1], argv[2]))
    elif len(argv) == 5 and argv[0] == "package":
        print(package(*argv[1:]))
    elif len(argv) >= 4 and argv[0] == "entries":
        print(json.dumps(entries(argv[1], argv[2], argv[3:]), indent=2))
    else:
        print(__doc__, file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
