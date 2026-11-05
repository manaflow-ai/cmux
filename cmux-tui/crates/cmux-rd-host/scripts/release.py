#!/usr/bin/env python3
# Copyright 2026 Manaflow, Inc.
# SPDX-License-Identifier: GPL-3.0-or-later
"""Release helpers for cmux-rd, the remote desktop host (.github/workflows/cmux-rd-release.yml).

  release.py version [TAG]
      print the crate version; with TAG (cmux-rd-vX.Y.Z), exit 1 unless the tag names it.
  release.py notices --cargo-tree FILE --out FILE [--cache DIR]
      write THIRD_PARTY_LICENSES.md for bin/cmux-rd: the Rust crates the release binary
      links (exactly the crates of FILE, the output of `cargo tree -e normal,no-proc-macro --target
      x86_64-unknown-linux-gnu --prefix none -f "{p}"` for the release features), with every
      license text (build-support/notices/rust_notices.py), the Rust standard library, Zig's
      compiler_rt (cargo-zigbuild links with Zig), glibc, and what the archive leaves out:
      Cisco's OpenH264, which `cmux-rd openh264-install` downloads from Cisco on the machine,
      and x264, which a release never links.
  release.py package BINARY NOTICES VERSION OUTDIR
      write OUTDIR/cmux-rd-VERSION-x86_64-unknown-linux-gnu.tar.gz holding bin/cmux-rd,
      LICENSE (GPL-3.0-or-later) and THIRD_PARTY_LICENSES.md, with fixed owner, mode and
      mtime, and print its path.

Python 3.11+ standard library only.
"""

from __future__ import annotations

import argparse
import gzip
import io
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tarfile
import tempfile
import tomllib

HERE = Path(__file__).resolve().parent
CRATE = HERE.parent
ROOT = CRATE.parents[2]
NOTICES = ROOT / "cmux-tui/build-support/notices"
LICENSE = ROOT / "cmux-tui/dist/npm/cmux/LICENSE"
LOCK = CRATE / "Cargo.lock"
TARGET = "x86_64-unknown-linux-gnu"
NAME = "cmux-rd"
VERSION_RE = re.compile(r"[0-9]+\.[0-9]+\.[0-9]+(?:-[0-9A-Za-z.]+)?")
# Review choices for crates that only this binary links, on top of the shared
# build-support/notices/reviewed.json (which stays the one review of the app's notices).
EXTRA_REVIEW = {
    "extra_license_files": {
        # The Rust bindings ship no license file of their own (BSD-2-Clause, like Cisco's
        # OpenH264); the .crate carries Cisco's BSD-2-Clause LICENSE of the vendored
        # OpenH264 source in upstream/. The release build loads Cisco's binary at run time
        # (feature libloading) and compiles none of that C source.
        "openh264-sys2 0.9.8": ["upstream/LICENSE"],
    },
}


def crate_version() -> str:
    version = tomllib.loads((CRATE / "Cargo.toml").read_text(encoding="utf-8"))["package"]["version"]
    if not isinstance(version, str) or not VERSION_RE.fullmatch(version):
        raise SystemExit(f"cannot read the cmux-rd-host version (got {version!r})")
    return version


def tag_version(tag: str) -> str:
    match = re.fullmatch(r"cmux-rd-v(.+)", tag)
    version = crate_version()
    if match is None or match.group(1) != version:
        raise SystemExit(f"tag {tag} does not name cmux-rd-host {version} (expected cmux-rd-v{version})")
    return version


def _block(title: str, text: str, lang: str = "text") -> str:
    longest = max((len(m) for m in re.findall(r"`+", text)), default=0)
    fence = "`" * max(3, longest + 1)
    return f"#### {title}\n\n{fence}{lang}\n{text.rstrip(chr(10))}\n{fence}\n\n"


def _read(path: Path, sha256: str) -> str:
    import hashlib

    data = path.read_bytes()
    if hashlib.sha256(data).hexdigest() != sha256:
        raise SystemExit(f"{path} does not match its sha256")
    return data.decode("utf-8")


def crates_markdown(cargo_tree: Path, cache: Path, tag: str) -> str:
    fetch = subprocess.run(
        [sys.executable, str(NOTICES / "fetch_crates.py"), "--cache", str(cache), "--lock", str(LOCK)],
        capture_output=True, text=True,
    )
    if fetch.returncode != 0:
        raise SystemExit(f"fetch_crates.py failed:\n{fetch.stderr}")
    shared = json.loads((NOTICES / "reviewed.json").read_text(encoding="utf-8"))
    with tempfile.TemporaryDirectory() as tmp:
        tmpdir = Path(tmp)
        merged = dict(shared)
        for key, extra in EXTRA_REVIEW.items():
            merged[key] = {**shared.get(key, {}), **extra}
        # license_texts paths are relative to the review file's directory.
        (tmpdir / "texts").symlink_to(NOTICES / "texts", target_is_directory=True)
        (tmpdir / "reviewed.json").write_text(json.dumps(merged, indent=2), encoding="utf-8")
        out = tmpdir / "crates.md"
        command = [
            sys.executable, str(NOTICES / "rust_notices.py"),
            "--lock", str(LOCK), "--lock-label", "cmux-tui/crates/cmux-rd-host/Cargo.lock",
            "--root", "cmux-rd-host", "--target", TARGET, "--cargo-tree", str(cargo_tree),
            "--workspace", str(ROOT / "cmux-tui"), "--repo-root", str(ROOT),
            "--first-party", "cmux-tui/crates/*",
            "--first-party-license", str(LICENSE),
            "--reviewed", str(tmpdir / "reviewed.json"),
            "--source-tag", tag,
            "--format", "markdown", "--section-id", "rust-crates",
            "--title", f"Rust crates ({TARGET})",
            "--out", str(out),
        ]
        result = subprocess.run(command, env={**os.environ, "CARGO_HOME": str(cache)}, capture_output=True, text=True)
        if result.returncode != 0:
            raise SystemExit(f"rust_notices.py failed:\n{result.stderr}")
        return out.read_text(encoding="utf-8")


def notices(cargo_tree: Path, out: Path, cache: Path) -> None:
    sys.path.insert(0, str(NOTICES / "toolchains"))
    import toolchain_notices

    version = crate_version()
    tag = f"cmux-rd-v{version}"
    channel = re.search(r'^\s*channel\s*=\s*"([^"]+)"', (ROOT / "cmux-tui/rust-toolchain.toml").read_text(), re.M)
    toolchains = toolchain_notices.load()
    rust = next((r for r in toolchains.rust if channel and r.version == channel.group(1)), None)
    if rust is None:
        raise SystemExit("toolchains.json has no text for the rustc of cmux-tui/rust-toolchain.toml")
    [zig] = toolchains.zig
    package_notices = ROOT / "cmux-tui/dist/notices"
    musl = json.loads((package_notices / "package-notices.json").read_text(encoding="utf-8"))["musl"]
    cache.mkdir(parents=True, exist_ok=True)
    crates = crates_markdown(cargo_tree, cache, tag)
    text = "".join([
        f"# Third-party notices: bin/cmux-rd {version} ({TARGET})\n\n",
        "<!-- Generated by cmux-tui/crates/cmux-rd-host/scripts/release.py; do not edit. -->\n\n",
        "bin/cmux-rd is cmux, licensed under GPL-3.0-or-later (LICENSE in this archive). Its source is "
        f"https://github.com/manaflow-ai/cmux/tree/{tag}/cmux-tui/crates/cmux-rd-host. "
        "The binary contains the third-party code below.\n\n",
        "## Not in this archive: H.264 codecs\n\n",
        "- **OpenH264** (Cisco Systems, BSD-2-Clause). The archive holds no OpenH264 code or library. "
        "`cmux-rd openh264-install` downloads Cisco's prebuilt OpenH264 2.6.0 from "
        "https://ciscobinary.openh264.org/ on the machine itself and loads it only after its pinned SHA-256 "
        "matches; Cisco's binary license and its H.264 patent license cover that download. "
        "\"OpenH264 Video Codec provided by Cisco Systems, Inc.\"\n",
        "- **x264** is never linked into a release build.\n\n",
        f"## Rust standard library (rustc {rust.version})\n\n",
        "std, core, alloc, compiler_builtins and the crates they vendor, as the Rust project lists them in "
        f"COPYRIGHT-library.html of rustc {rust.version} ({rust.source}):\n\n",
        _block(f"COPYRIGHT-library.html (rustc {rust.version})", _read(rust.path, rust.sha256), "html"),
        f"## Zig {zig.version} compiler_rt and libunwind\n\n",
        "The binary is linked with Zig (cargo-zigbuild, glibc floor 2.31), which links its compiler_rt "
        f"(Zig's MIT License, Expat; {zig.source}) into the binary:\n\n",
        _block(f"Zig {zig.version} LICENSE", _read(zig.path, zig.sha256)),
        "Several compiler_rt math files say 'Ported from musl', which is licensed under the MIT license:\n\n",
        _block(f"musl {musl['version']} COPYRIGHT", _read(package_notices / musl["file"], musl["sha256"])),
        "Zig also links LLVM libunwind into the binary (Apache-2.0 WITH LLVM-exception; the exception needs no "
        "notice for code embedded in object form).\n\n",
        "## glibc\n\n",
        "The binary links the GNU C Library dynamically (libc.so.6, libm.so.6; glibc 2.31 or later). The small "
        "glibc start files and libc_nonshared code that the link adds are under the GNU Lesser General Public "
        "License 2.1 or later with the exception that gives unlimited permission to link the compiled files into "
        "other programs.\n\n",
        crates.rstrip("\n") + "\n",
    ])
    out.write_text(text, encoding="utf-8")
    print(f"release.py: wrote {out} ({len(text)} bytes)")


def package(binary: Path, notices_file: Path, version: str, outdir: Path) -> Path:
    if not VERSION_RE.fullmatch(version):
        raise SystemExit(f"bad version {version!r}")
    members = (
        ("LICENSE", 0o644, LICENSE.read_bytes()),
        ("THIRD_PARTY_LICENSES.md", 0o644, notices_file.read_bytes()),
        ("bin", 0o755, None),
        (f"bin/{NAME}", 0o755, binary.read_bytes()),
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
    out = outdir / f"{NAME}-{version}-{TARGET}.tar.gz"
    out.parent.mkdir(parents=True, exist_ok=True)
    with open(out, "wb") as f, gzip.GzipFile(filename="", mode="wb", fileobj=f, mtime=0) as gz:
        gz.write(raw.getvalue())
    print(out)
    return out


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="cmd", required=True)
    v = sub.add_parser("version")
    v.add_argument("tag", nargs="?")
    n = sub.add_parser("notices")
    n.add_argument("--cargo-tree", type=Path, required=True)
    n.add_argument("--out", type=Path, required=True)
    n.add_argument("--cache", type=Path, default=Path(os.environ.get("CMUX_NOTICES_CACHE", Path.home() / ".cache/cmux-notices")))
    p = sub.add_parser("package")
    p.add_argument("binary", type=Path)
    p.add_argument("notices", type=Path)
    p.add_argument("version")
    p.add_argument("outdir", type=Path)
    args = parser.parse_args(argv)
    if args.cmd == "version":
        print(tag_version(args.tag) if args.tag else crate_version())
    elif args.cmd == "notices":
        notices(args.cargo_tree, args.out, args.cache)
    else:
        package(args.binary, args.notices, args.version, args.outdir)
    return 0


if __name__ == "__main__":
    sys.exit(main())
