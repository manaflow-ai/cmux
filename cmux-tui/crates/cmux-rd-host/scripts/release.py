#!/usr/bin/env python3
# Copyright 2026 Manaflow, Inc.
# SPDX-License-Identifier: GPL-3.0-or-later
"""Release helpers for cmux-rd, the remote desktop host (.github/workflows/cmux-rd-release.yml).

  release.py version [TAG]
      print the crate version; with TAG (cmux-rd-vX.Y.Z), exit 1 unless the tag names it.
  release.py crates [--target T] [--metadata FILE]
      print the crates a release cmux-rd links for target T, one `name vVERSION` line each:
      the closure of cmux-rd-host's normal dependencies in `cargo metadata`'s resolve graph for
      the release features (RELEASE_FEATURES) on T, without dev or build dependencies and
      without proc macros, which run in the compiler and are not linked. --metadata reads that
      JSON from FILE instead of running cargo. The license gate and the notices both read this
      list (linked_crates), so they cannot name different crates.
  release.py license-gate [--target T] [--metadata FILE] [--out FILE]
      print a table of every linked crate not under permissive licenses only, and exit 1 when
      one is not this repository's own (OWN_CRATES, by name, from a path) and can only be taken
      under the GPL, LGPL or AGPL, or declares no license. --out also writes the table.
  release.py notices (--out FILE | --list) [--cache DIR] [--target T] [--ref REF] [--metadata FILE]
      run the license gate, then write THIRD_PARTY_LICENSES.md for bin/cmux-rd: the crates of
      `release.py crates` with every license text (build-support/notices/rust_notices.py), the
      Rust standard library, Zig's compiler_rt (cargo-zigbuild links with Zig), glibc, and what
      the archive leaves out: Cisco's OpenH264, which `cmux-rd openh264-install` downloads from
      Cisco on the machine, and x264, which a release never links.
      --list runs the gate and prints the crates the notices would document, writing nothing.
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
# The features of every release build: scripts/build-channel.sh (the files.cmux.com channel)
# and cmux-rd-release.yml (tests/release_features.rs checks both name these).
RELEASE_FEATURES = "openh264,link"
# This repository's own crates in a release cmux-rd, all GPL-3.0-or-later. A crate passes as
# one only by name and from a path, never from a registry.
OWN_CRATES = frozenset((
    "cmux-braid-class", "cmux-braid-path", "cmux-encode", "cmux-file-lock", "cmux-hub-host", "cmux-process",
    "cmux-rd-core", "cmux-rd-engine",
    "cmux-rd-host", "cmux-rd-link", "cmux-rd-proto", "cmux-transport", "cmux-wg",
))
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


def cargo_metadata(target: str) -> dict:
    """`cargo metadata` of cmux-rd-host with the release features, resolved for `target`."""
    result = subprocess.run(
        [os.environ.get("CARGO", "cargo"), "metadata", "--format-version", "1", "--locked",
         "--manifest-path", str(CRATE / "Cargo.toml"), "--no-default-features",
         "--features", RELEASE_FEATURES, "--filter-platform", target],
        capture_output=True, text=True,
    )
    if result.returncode != 0:
        raise SystemExit(f"cargo metadata for {target} failed:\n{result.stderr}")
    return json.loads(result.stdout)


def linked_crates(metadata: dict) -> list[dict]:
    """The packages linked into cmux-rd: the root's closure over normal dependency edges.

    An edge counts when one of its dep_kinds is normal (kind null): a dev-only or build-only
    edge is not linked. A proc macro runs in the compiler, so it and what only it reaches are
    left out. `cargo metadata` resolves features for every platform at once and keeps cfg edges
    it cannot rule out, so this can name a few crates `cargo tree -e normal,no-proc-macro
    --target T` leaves out (ecdsa, signature and errno on 2026-11-17): the gate then judges, and
    the notices credit, a little more than the binary links, never less
    (tests/release_features.rs checks that).
    """
    packages = {pkg["id"]: pkg for pkg in metadata["packages"]}
    nodes = {node["id"]: node for node in metadata["resolve"]["nodes"]}
    root = metadata["resolve"]["root"]
    if root is None:
        raise SystemExit("cargo metadata has no resolve root (expected cmux-rd-host)")

    def proc_macro(pkg_id: str) -> bool:
        return any("proc-macro" in t.get("kind", []) for t in packages[pkg_id].get("targets", []))

    seen = {root}
    queue = [root]
    while queue:
        node = nodes[queue.pop()]
        for dep in node.get("deps", []):
            linked = any(kind.get("kind") is None for kind in dep.get("dep_kinds", []))
            if linked and dep["pkg"] not in seen and not proc_macro(dep["pkg"]):
                seen.add(dep["pkg"])
                queue.append(dep["pkg"])
    return sorted(
        ({"name": packages[i]["name"], "version": packages[i]["version"],
          "license": packages[i].get("license"), "source": packages[i].get("source")} for i in seen),
        key=lambda c: (c["name"], c["version"]),
    )


def crate_lines(crates: list[dict]) -> str:
    """The crates as `name vVERSION` lines, the form rust_notices.py --cargo-tree reads."""
    return "".join(f"{c['name']} v{c['version']}\n" for c in crates)


def crates_markdown(cargo_tree: Path, cache: Path, tag: str, target: str = TARGET) -> str:
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
            "--root", "cmux-rd-host", "--target", target, "--cargo-tree", str(cargo_tree),
            "--workspace", str(ROOT / "cmux-tui"), "--repo-root", str(ROOT),
            "--first-party", "cmux-tui/crates/*",
            "--first-party-license", str(LICENSE),
            "--reviewed", str(tmpdir / "reviewed.json"),
            "--source-tag", tag,
            "--format", "markdown", "--section-id", "rust-crates",
            "--title", f"Rust crates ({target})",
            "--out", str(out),
        ]
        result = subprocess.run(command, env={**os.environ, "CARGO_HOME": str(cache)}, capture_output=True, text=True)
        if result.returncode != 0:
            raise SystemExit(f"rust_notices.py failed:\n{result.stderr}")
        return out.read_text(encoding="utf-8")


def notices(out: Path | None, cache: Path, target: str = TARGET, ref: str | None = None, metadata: dict | None = None, list_only: bool = False) -> None:
    crates_linked = linked_crates(metadata if metadata is not None else cargo_metadata(target))
    code, report = license_gate(crates_linked)
    if code != 0:
        raise SystemExit(report + "release.py: the license gate stops this release; no notices written")
    if list_only:
        # The crates these notices document, exactly the list the gate passed.
        print(crate_lines(crates_linked), end="")
        return
    sys.path.insert(0, str(NOTICES / "toolchains"))
    import toolchain_notices

    version = crate_version()
    tag = ref or f"cmux-rd-v{version}"
    channel = re.search(r'^\s*channel\s*=\s*"([^"]+)"', (ROOT / "cmux-tui/rust-toolchain.toml").read_text(), re.M)
    toolchains = toolchain_notices.load()
    rust = next((r for r in toolchains.rust if channel and r.version == channel.group(1)), None)
    if rust is None:
        raise SystemExit("toolchains.json has no text for the rustc of cmux-tui/rust-toolchain.toml")
    # The release links with the Zig of ghostty-next (GHOSTTY_ZIG_SOURCE in cmux-rd-release.yml);
    # toolchains.json lists one Zig per Ghostty source.
    zig = toolchains.zig_for("ghostty-next")
    package_notices = ROOT / "cmux-tui/dist/notices"
    musl = json.loads((package_notices / "package-notices.json").read_text(encoding="utf-8"))["musl"]
    cache.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory() as tmp:
        cargo_tree = Path(tmp) / "crates.txt"
        cargo_tree.write_text(crate_lines(crates_linked), encoding="utf-8")
        crates = crates_markdown(cargo_tree, cache, tag, target)
    text = "".join([
        f"# Third-party notices: bin/cmux-rd {version} ({target})\n\n",
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


# SPDX identifiers that ask nothing past keeping their notice.
PERMISSIVE = frozenset((
    "MIT", "MIT-0", "Apache-2.0", "Apache-2.0 WITH LLVM-exception", "BSD-2-Clause", "BSD-3-Clause",
    "ISC", "Zlib", "0BSD", "BSL-1.0", "CC0-1.0", "Unlicense", "Unicode-3.0", "Unicode-DFS-2016",
    "CDLA-Permissive-2.0", "bzip2-1.0.6",
))
# Copyleft that reaches a program it is linked into statically.
STRONG_COPYLEFT = re.compile(r"\b(?:A|L)?GPL-")


def _alternatives(expression: str) -> list[list[str]]:
    """The ways a crate may be taken: alternatives (OR) of terms that all apply (AND).

    Cargo's `license` field: `A OR B`, `A AND B`, the old `A/B` for OR, and parentheses
    (`(A OR B) AND C`). A parenthesized group is expanded one alternative at a time; an
    alternative is only ANDs, which bind tightest, so it goes in without parentheses.
    """
    text = " ".join(expression.replace("/", " OR ").split())
    group = re.fullmatch(r"(.*?)\(([^()]+)\)(.*)", text)
    if group is not None:
        before, inner, after = group.groups()
        out: list[list[str]] = []
        for alt in _alternatives(inner):
            out.extend(_alternatives(before + " AND ".join(alt) + after))
        return out
    return [
        [term.strip() for term in re.split(r"\s+AND\s+", alternative) if term.strip()]
        for alternative in re.split(r"\s+OR\s+", text)
        if alternative.strip()
    ]


def license_class(expression: str | None) -> str:
    """permissive; strong (every way to take it includes the GPL, LGPL or AGPL); else weak
    (file-level copyleft such as MPL-2.0, an attribution license, or no license field)."""
    if not expression:
        return "weak"
    alternatives = _alternatives(expression)
    if any(alt and all(term in PERMISSIVE for term in alt) for alt in alternatives):
        return "permissive"
    if alternatives and all(any(STRONG_COPYLEFT.search(term) for term in alt) for alt in alternatives):
        return "strong"
    return "weak"


def own_crate(crate: dict) -> bool:
    """This repository's own crate: named in OWN_CRATES and built from a path, not a registry."""
    return crate["name"] in OWN_CRATES and crate.get("source") is None


def license_gate(crates: list[dict]) -> tuple[int, str]:
    """1 and the report when a linked crate that is not our own is GPL, LGPL or AGPL only, or
    declares no license; else 0. The report lists every crate not under permissive licenses only."""
    rows: list[tuple[str, str, str, str]] = []
    stop: list[str] = []
    for crate in crates:
        name, version, expression = crate["name"], crate["version"], crate.get("license")
        if own_crate(crate):
            verdict = "this repository's own crate (GPL-3.0-or-later)"
        elif not expression:
            verdict = "STOP: no license field"
            stop.append(f"{name} {version} (no license)")
        else:
            cls = license_class(expression)
            if cls == "permissive":
                continue
            if cls == "strong":
                verdict = "STOP: GPL, LGPL or AGPL only, linked statically"
                stop.append(f"{name} {version} ({expression})")
            else:
                verdict = "listed, no stop: not GPL, LGPL or AGPL only"
        rows.append((name, version, expression or "(none)", verdict))
    report = (
        f"{len(crates)} crates; {len(rows)} not under permissive licenses only; {len(stop)} stop the release.\n\n"
        "| Crate | Version | License | Verdict |\n|---|---|---|---|\n"
        + "".join(f"| {n} | {v} | {e} | {d} |\n" for n, v, e, d in rows)
    )
    if stop:
        report += "\nrelease.py: cmux-rd would link, statically: " + "; ".join(stop) + "\n"
    return (1 if stop else 0), report


def _metadata_arg(args: argparse.Namespace) -> dict:
    if args.metadata is not None:
        return json.loads(args.metadata.read_text(encoding="utf-8"))
    return cargo_metadata(args.target)


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
    n.add_argument("--out", type=Path)
    n.add_argument("--list", action="store_true", help="run the gate, print the crates the notices would document, write nothing")
    n.add_argument("--cache", type=Path, default=Path(os.environ.get("CMUX_NOTICES_CACHE", Path.home() / ".cache/cmux-notices")))
    n.add_argument("--ref", help="the source ref the notices link to (default: the cmux-rd-vX.Y.Z tag)")
    c = sub.add_parser("crates")
    g = sub.add_parser("license-gate")
    g.add_argument("--out", type=Path)
    for parser_ in (n, c, g):
        parser_.add_argument("--target", default=TARGET)
        parser_.add_argument("--metadata", type=Path, help="read `cargo metadata` JSON from this file")
    p = sub.add_parser("package")
    p.add_argument("binary", type=Path)
    p.add_argument("notices", type=Path)
    p.add_argument("version")
    p.add_argument("outdir", type=Path)
    args = parser.parse_args(argv)
    if args.cmd == "version":
        print(tag_version(args.tag) if args.tag else crate_version())
    elif args.cmd == "notices":
        if args.out is None and not args.list:
            parser.error("notices needs --out or --list")
        notices(args.out, args.cache, args.target, args.ref, _metadata_arg(args), args.list)
    elif args.cmd == "crates":
        print(crate_lines(linked_crates(_metadata_arg(args))), end="")
    elif args.cmd == "license-gate":
        code, report = license_gate(linked_crates(_metadata_arg(args)))
        print(report, end="")
        if args.out is not None:
            args.out.write_text(report, encoding="utf-8")
        return code
    else:
        package(args.binary, args.notices, args.version, args.outdir)
    return 0


if __name__ == "__main__":
    sys.exit(main())
