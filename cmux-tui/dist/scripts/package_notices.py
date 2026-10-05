#!/usr/bin/env python3
# Copyright 2026 Manaflow, Inc.
# SPDX-License-Identifier: GPL-3.0-or-later
"""THIRD_PARTY_LICENSES.md for each cmux-tui npm package and PyPI wheel.

  package_notices.py generate --out-dir DIR --source-tag SHA [--cache DIR]
                              [--target RUST_TARGET ...]
  package_notices.py check-data
  package_notices.py check-windows-toolchain [--gcc GCC]
  package_notices.py check-windows-binary BINARY [BINARY ...]
  package_notices.py check-darwin-binary BINARY [BINARY ...]

`generate` writes DIR/<kind>-<rust target>.md for kind `cmux-tui` (bin/cmux-tui
and bin/cmux-tui-hook: npm cmux-tui-<os>-<cpu>, every wheel) and `relay`
(bin/chatmux-relay and bin/cmux-tui: npm cmux-relay-<os>-<cpu>). package_npm.py
and package_pypi.py copy them into the packages; validate_package_contract.py
fails a package without its notice or with a different one.

Each notice names everything the static binaries link, for that target:
  - the Rust crates of the exact target closure (rust_notices.py, with the
    license texts; first-party crates point at --source-tag),
  - the Rust standard library: rustc's COPYRIGHT-library.html for the
    cmux-tui/rust-toolchain.toml version (toolchains.json),
  - Zig's std and compiler_rt (libghostty-vt): Zig's LICENSE (toolchains.json),
  - libghostty-vt: Ghostty's LICENSE and the texts of every Zig package and
    vendored directory that vt-link-graph.json says the archive links for the
    target (cmux-tui/dist/notices/package-notices.json, owned by the license
    review; the texts must be for the graph's ghostty-next commit),
  - Linux musl targets: musl's COPYRIGHT (package-notices.json),
  - Windows (x86_64-pc-windows-gnu): the static mingw-w64 13.0.0 CRT and the
    GCC 15.2.0 runtime (libgcc_eh, crtbegin) of the one reviewed toolchain,
    and musl's COPYRIGHT for Zig compiler_rt's musl-derived math
    (package-notices.json windows_gnu, independent review of 2026-10-05).
Darwin (aarch64/x86_64-apple-darwin) has no musl text: the real Darwin link has
no musl-derived code (package-notices.json darwin.review). `check-darwin-binary`
(the package job) fails a Darwin binary without a symbol table, with a
compiler_rt module outside the reviewed list, with the libghostty-vt export
that reaches musl-ported std.math.cbrt, or with a musl-ported Zig function.
`check-windows-toolchain` (the Windows build job, before linking) fails when
the MinGW gcc that rustc links with is not the reviewed build (GCC version and
build string, mingw-w64 version, UCRT); `check-windows-binary` (the package
job) fails a binary that names another GCC build. A new toolchain needs a new
review of its static runtime.

Crate sources come from fetch_crates.py's CARGO_HOME-shaped cache (network on
first use; no cargo). Python 3.11+ standard library only.
"""

from __future__ import annotations

import argparse
import dataclasses
import hashlib
import json
import os
from pathlib import Path
import re
import struct
import subprocess
import sys
import tempfile

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[2]
NOTICES = HERE.parent / "notices"
BUILD_SUPPORT = ROOT / "cmux-tui/build-support/notices"
GHOSTTY_PINNED = BUILD_SUPPORT / "ghostty/pinned-licenses"
VT_GRAPH = ROOT / "scripts/cmux-next/notices/vt-link-graph.json"
NOTICE_FILE = "THIRD_PARTY_LICENSES.md"

sys.path.insert(0, str(BUILD_SUPPORT / "toolchains"))
import toolchain_notices  # noqa: E402

# rust target -> zig target of libghostty-vt (ghostty-vt-sys build_support.rs).
TARGETS = {
    "aarch64-apple-darwin": "aarch64-macos",
    "x86_64-apple-darwin": "x86_64-macos",
    "x86_64-unknown-linux-musl": "x86_64-linux-musl",
    "aarch64-unknown-linux-musl": "aarch64-linux-musl",
    "x86_64-pc-windows-gnu": "x86_64-windows-gnu",
}
GCC_IDENT = re.compile(rb"GCC: \([^)\x00]*\) [0-9][0-9A-Za-z.\-]*")
KINDS = {
    "cmux-tui": {"roots": ("cmux-tui",), "binaries": ("bin/cmux-tui", "bin/cmux-tui-hook")},
    "relay": {"roots": ("chatmux-relay", "cmux-tui"), "binaries": ("bin/chatmux-relay", "bin/cmux-tui")},
}


class NoticeError(RuntimeError):
    pass


@dataclasses.dataclass
class Inputs:
    data: dict
    graph: dict
    toolchains: "toolchain_notices.Manifest"
    rust_version: str
    vendored: dict
    pinned: dict


def notice_name(kind: str, rust_target: str) -> str:
    return f"{kind}-{rust_target}.md"


def load_inputs() -> Inputs:
    toolchains = toolchain_notices.load()
    channel = re.search(r'^\s*channel\s*=\s*"([^"]+)"', (ROOT / "cmux-tui/rust-toolchain.toml").read_text(), re.M)
    pinned_manifest = json.loads((GHOSTTY_PINNED / "MANIFEST.json").read_text(encoding="utf-8"))
    return Inputs(
        data=json.loads((NOTICES / "package-notices.json").read_text(encoding="utf-8")),
        graph=json.loads(VT_GRAPH.read_text(encoding="utf-8")),
        toolchains=toolchains,
        rust_version=channel.group(1) if channel else "",
        vendored=pinned_manifest.get("vendored", {}),
        pinned=pinned_manifest.get("packages", {}),
    )


def _read(path: Path, sha256: str, label: str) -> str:
    data = path.read_bytes()
    if hashlib.sha256(data).hexdigest() != sha256:
        raise NoticeError(f"{label}: {path} does not match its sha256")
    return data.decode("utf-8")


def _fence(text: str) -> str:
    longest = max((len(m) for m in re.findall(r"`+", text)), default=0)
    return "`" * max(3, longest + 1)


def _block(title: str, text: str, lang: str = "text") -> str:
    fence = _fence(text)
    return f"#### {title}\n\n{fence}{lang}\n{text.rstrip(chr(10))}\n{fence}\n\n"


def _vt_owner_texts(inputs: Inputs, owner: str) -> tuple[str, list[tuple[str, str]]]:
    """(display name, [(title, text)]) for a libghostty-vt owner: a Zig package
    hash, `ghostty-next`, or a vendored directory resolved through the Ghostty
    vendored review (covered_by ghostty / zig-dependency:<name> / pinned:<name>)."""
    owners = inputs.data["libghostty_vt"]["owners"]
    if owner in owners:
        entry = owners[owner]
        return entry["name"], [
            (f"{entry['name']}: {Path(f['file']).name} ({f['source']})", _read(NOTICES / f["file"], f["sha256"], owner))
            for f in entry["files"]
        ]
    review = inputs.vendored.get(owner)
    if review is None:
        raise NoticeError(f"libghostty-vt links {owner}, which has no texts in package-notices.json and no vendored review")
    covered = review.get("covered_by", "")
    if covered == "ghostty":
        return owner, []  # Ghostty's own code: Ghostty's LICENSE
    if covered.startswith("zig-dependency:"):
        name = covered.split(":", 1)[1]
        if not any(entry["name"] == name for entry in owners.values()):
            raise NoticeError(f"{owner} is covered by the Zig package {name}, which has no texts in package-notices.json")
        return owner, []
    if covered.startswith("pinned:"):
        name = covered.split(":", 1)[1]
        files = inputs.pinned.get(name, {}).get("files", [])
        if not files:
            raise NoticeError(f"{owner} is covered by pinned:{name}, which has no pinned texts")
        return name, [
            (f"{name}: {f['filename']} ({f['upstream']})", _read(GHOSTTY_PINNED / f["path"], f["sha256"], name))
            for f in files
        ]
    raise NoticeError(f"{owner}: unknown vendored coverage {covered!r}")


def data_problems(inputs: Inputs) -> list[str]:
    """Pinned texts match; the libghostty-vt texts cover the graph's linked set."""
    problems = []
    musl = inputs.data["musl"]
    try:
        _read(NOTICES / musl["file"], musl["sha256"], "musl")
    except (OSError, NoticeError) as error:
        problems.append(f"{musl['file']}: {error}")
    for entry in inputs.data["windows_gnu"]["files"]:
        try:
            _read(NOTICES / entry["file"], entry["sha256"], "windows_gnu")
        except (OSError, NoticeError) as error:
            problems.append(f"{entry['file']}: {error}")
    vt = inputs.data["libghostty_vt"]
    if (inputs.graph.get("source"), inputs.graph.get("commit")) != (vt["source"], vt["commit"]):
        problems.append(
            f"package-notices.json has libghostty-vt texts for {vt['source']} {vt['commit']}, but vt-link-graph.json "
            f"is for {inputs.graph.get('source')} {inputs.graph.get('commit')}; copy the texts of the linked packages "
            "from that commit's collected license tree"
        )
    linked = set()
    for entry in inputs.graph.get("targets", {}).values():
        linked.update(entry.get("packages", []))
        linked.update(entry.get("vendored", {}))
    for owner in ["ghostty-next", *sorted(linked)]:
        try:
            _vt_owner_texts(inputs, owner)
        except (OSError, NoticeError) as error:
            problems.append(str(error))
    darwin = inputs.data["darwin"]
    zig_versions = [zig.version for zig in inputs.toolchains.zig]
    if darwin["zig"] not in zig_versions:
        problems.append(
            f"package-notices.json darwin reviews the Darwin link for Zig {darwin['zig']}, but the toolchain is Zig "
            f"{', '.join(zig_versions)}: review the new Zig's musl-ported compiler_rt and std code in the real "
            "Darwin binaries, then update darwin"
        )
    problems += toolchain_notices.text_problems(inputs.toolchains)
    return problems


def _reviewed_windows(inputs: Inputs) -> tuple[dict, str]:
    win = inputs.data["windows_gnu"]
    return win, f"({win['gcc_build']}) {win['gcc_version']}"


def windows_toolchain_problems(gcc_version: str, predefined_macros: str, inputs: Inputs) -> list[str]:
    """The linker's `gcc --version` and `gcc -dM -E` of <_mingw.h> must be the
    reviewed toolchain: its static mingw-w64 CRT and libgcc are what
    windows_gnu's texts cover."""
    win, reviewed = _reviewed_windows(inputs)
    problems = []
    first = gcc_version.splitlines()[0].strip() if gcc_version.strip() else ""
    if not first.endswith(" " + reviewed):
        problems.append(
            f"the MinGW gcc is '{first or 'missing'}', but the reviewed Windows runtime notices cover only "
            f"'{reviewed}' (package-notices.json windows_gnu): review the new toolchain's mingw-w64 and GCC runtime first"
        )
    macros = dict(re.findall(r"^#define (\S+) ?(.*)$", predefined_macros, re.M))
    version = ".".join(macros.get(f"__MINGW64_VERSION_{part}", "?") for part in ("MAJOR", "MINOR", "BUGFIX"))
    if version != win["mingw_w64_version"]:
        problems.append(
            f"the MinGW gcc links mingw-w64 {version}, but the reviewed notices are for mingw-w64 "
            f"{win['mingw_w64_version']} (package-notices.json windows_gnu)"
        )
    if "_UCRT" not in macros:
        problems.append("the MinGW gcc targets msvcrt, but the reviewed Windows runtime is the UCRT build")
    return problems


def windows_binary_problems(binary: bytes, inputs: Inputs) -> list[str]:
    """Every GCC ident in a packaged Windows binary (from C objects that gcc
    compiled) must be the reviewed toolchain's; a binary may have none."""
    _, reviewed = _reviewed_windows(inputs)
    found = sorted({m.decode("utf-8", "replace") for m in GCC_IDENT.findall(binary)})
    other = [ident for ident in found if ident != f"GCC: {reviewed}"]
    if not other:
        return []
    return [
        f"the binary contains code built by {', '.join(other)}; the reviewed Windows runtime notices cover only "
        f"'GCC: {reviewed}' (package-notices.json windows_gnu)"
    ]


def macho_symbols(binary: bytes) -> tuple[set[str], set[str]] | None:
    """(defined, undefined) symbol names of a 64-bit Mach-O or of every slice of a
    universal one; None when it is not a Mach-O or has no symbols."""
    if binary[:4] == b"\xca\xfe\xba\xbe":
        (count,) = struct.unpack_from(">I", binary, 4)
        defined, undefined = set(), set()
        for index in range(count):
            _, _, offset, size, _ = struct.unpack_from(">iiIII", binary, 8 + 20 * index)
            symbols = macho_symbols(binary[offset:offset + size])
            if symbols is None:
                return None
            defined |= symbols[0]
            undefined |= symbols[1]
        return defined, undefined
    if binary[:4] != b"\xcf\xfa\xed\xfe":
        return None
    ncmds, offset = struct.unpack_from("<I", binary, 16)[0], 32
    for _ in range(ncmds):
        command, size = struct.unpack_from("<II", binary, offset)
        if command == 0x2:  # LC_SYMTAB
            symoff, nsyms, stroff, strsize = struct.unpack_from("<IIII", binary, offset + 8)
            strings = binary[stroff:stroff + strsize]
            defined, undefined = set(), set()
            for index in range(nsyms):
                strx, kind, _, _, _ = struct.unpack_from("<IBBHQ", binary, symoff + 16 * index)
                if kind & 0xE0:  # stab (debug map) entries
                    continue
                name = strings[strx:strings.index(b"\0", strx)].decode("utf-8", "replace")
                (defined if kind & 0x0E == 0x0E else undefined).add(name)
            return (defined, undefined) if defined else None
        offset += size
    return None


def darwin_binary_problems(binary: bytes, inputs: Inputs) -> list[str]:
    """A Darwin package binary must keep its symbols and link no musl-derived code
    (package-notices.json darwin): the Darwin notices carry no musl text."""
    darwin = inputs.data["darwin"]
    symbols = macho_symbols(binary)
    if symbols is None:
        return ["not a Mach-O with a symbol table (stripped?): the musl-free Darwin link cannot be checked"]
    defined, undefined = symbols
    problems = []
    if any(name.startswith("_ghostty_") for name in defined) and not any(name.startswith("_terminal.") for name in defined):
        problems.append(
            "links libghostty-vt but has no local Zig symbols (terminal.*): local symbols were stripped, so the "
            "musl-free Darwin link cannot be checked"
        )
    modules = sorted({m.group(1) for name in defined if (m := re.match(r"_?compiler_rt\.([A-Za-z0-9_]+)\.", name))})
    other = [module for module in modules if module not in darwin["compiler_rt_modules"]]
    if other:
        problems.append(
            f"links Zig compiler_rt.{', compiler_rt.'.join(other)}, which the Darwin review does not cover "
            "(several compiler_rt math files are ported from musl): review them, then add musl's COPYRIGHT to the "
            "Darwin notices or add the module to package-notices.json darwin.compiler_rt_modules"
        )
    entries = sorted(set(darwin["musl_entry_symbols"]) & (defined | undefined))
    if entries:
        problems.append(
            f"links {', '.join(entries)}, which reaches Zig code ported from musl (std.math.cbrt): the Darwin "
            "notices then need musl's COPYRIGHT (package-notices.json darwin)"
        )
    ported = sorted(name for name in defined if any(re.match(p, name) for p in darwin["musl_ported_symbol_patterns"]))
    if ported:
        problems.append(
            f"contains Zig code ported from musl ({', '.join(ported[:5])}): the Darwin notices then need musl's "
            "COPYRIGHT (package-notices.json darwin)"
        )
    return problems


def compose(kind: str, rust_target: str, crates_markdown: str, inputs: Inputs) -> str:
    if rust_target not in TARGETS:
        raise NoticeError(f"unknown target {rust_target}")
    zig_target = TARGETS[rust_target]
    spec = KINDS[kind]
    rust = next((r for r in inputs.toolchains.rust if r.version == inputs.rust_version), None)
    if rust is None:
        raise NoticeError(f"toolchains.json has no Rust {inputs.rust_version} (cmux-tui/rust-toolchain.toml)")
    [zig] = inputs.toolchains.zig
    graph = inputs.graph["targets"].get(zig_target)
    if graph is None:
        raise NoticeError(f"vt-link-graph.json has no {zig_target}")
    out = [
        f"# Third-party notices: {', '.join(spec['binaries'])} ({rust_target})\n\n",
        "<!-- Generated by cmux-tui/dist/scripts/package_notices.py; do not edit. -->\n\n",
        f"The binaries of this package ({', '.join(spec['binaries'])}) are cmux, licensed under "
        "GPL-3.0-or-later (LICENSE). They are statically linked and contain the third-party code below.\n\n",
        f"## Rust standard library (rustc {rust.version})\n\n",
        "std, core, alloc, compiler_builtins and the crates they vendor, as the Rust project lists them in "
        f"COPYRIGHT-library.html of rustc {rust.version} ({rust.source}):\n\n",
        _block(f"COPYRIGHT-library.html (rustc {rust.version})", _read(rust.path, rust.sha256, "rust"), "html"),
        f"## Zig {zig.version} standard library and compiler_rt\n\n",
        "libghostty-vt is built with Zig, which links its std and compiler_rt into the archive "
        f"(MIT License (Expat); {zig.source}):\n\n",
        _block(f"Zig {zig.version} LICENSE", _read(zig.path, zig.sha256, "zig")),
    ]
    vt = inputs.data["libghostty_vt"]
    packages, vendored = list(graph["packages"]), list(graph.get("vendored", {}))
    if zig_target.endswith("-windows-gnu"):
        # The Windows archive carries CodeView, whose file checksums name only
        # files with line records: a package used only through inlined code or
        # comptime tables (uucode on 2026-10-05) is missing. Name every package
        # any target links, so the Windows notice is never smaller than the truth.
        for entry in inputs.graph["targets"].values():
            packages += [p for p in entry.get("packages", []) if p not in packages]
            vendored += [v for v in entry.get("vendored", {}) if v not in vendored]
    owners = ["ghostty-next", *packages, *vendored]
    out.append(f"## libghostty-vt ({vt['source']} {vt['commit']})\n\n")
    out.append(
        "Ghostty's terminal library and the Zig packages and vendored directories whose code its archive "
        f"contains for {zig_target} (vt-link-graph.json):\n\n"
    )
    for owner in owners:
        name, texts = _vt_owner_texts(inputs, owner)
        out.append(f"### {name}{'' if name == owner else f' ({owner})'}\n\n")
        if not texts:
            out.append("Covered by the texts above (Ghostty's own code or its Zig package).\n\n")
        for title, text in texts:
            out.append(_block(title, text))
    if rust_target.endswith("-linux-musl"):
        musl = inputs.data["musl"]
        out.append(f"## musl libc {musl['version']}\n\n")
        out.append(f"The Linux binaries are statically linked with musl ({musl['source']}):\n\n")
        out.append(_block(f"musl {musl['version']} COPYRIGHT", _read(NOTICES / musl["file"], musl["sha256"], "musl")))
    if rust_target.endswith("-windows-gnu"):
        win = inputs.data["windows_gnu"]
        out.append(f"## Windows runtime: mingw-w64 {win['mingw_w64_version']} and GCC {win['gcc_version']}\n\n")
        out.append(
            f"The Windows binaries are linked with {win['toolchain']} They statically contain the mingw-w64 "
            "C runtime startup and support code (crt2.o, libmingw32, libmingwex, the libucrt wrappers; almost "
            "all linked files are in the public domain, see DISCLAIMER.PD, and the rest fall under the runtime "
            "license below) and GCC's runtime (crtbegin.o and the "
            "libgcc_eh SEH unwinder; GPL-3.0-or-later WITH GCC-exception-3.1, see LICENSE for the GPL text). "
            "They import the Universal C Runtime from Windows. winpthreads, libstdc++, LLVM compiler-rt and "
            "LLVM libunwind are not linked.\n\n"
        )
        for entry in win["files"]:
            out.append(_block(f"{entry['title']} ({entry['source']})", _read(NOTICES / entry["file"], entry["sha256"], "windows_gnu")))
        musl = inputs.data["musl"]
        out.append("## musl-derived math in Zig compiler_rt\n\n")
        out.append(
            f"Zig {zig.version}'s compiler_rt, linked through libghostty-vt, provides math functions "
            "(ceil, floor, exp, log, log2, round, trunc and their float forms) ported from musl, which is "
            "licensed under the MIT license:\n\n"
        )
        out.append(_block(f"musl {musl['version']} COPYRIGHT", _read(NOTICES / musl["file"], musl["sha256"], "musl")))
    out.append(crates_markdown.rstrip("\n") + "\n")
    return "".join(out)


def crates_markdown(kind: str, rust_target: str, cache: Path, source_tag: str) -> str:
    with tempfile.TemporaryDirectory() as tmp:
        out = Path(tmp) / "crates.md"
        command = [
            sys.executable, str(BUILD_SUPPORT / "rust_notices.py"),
            "--lock", str(ROOT / "cmux-tui/Cargo.lock"), "--lock-label", "cmux-tui/Cargo.lock",
            "--workspace", str(ROOT / "cmux-tui"), "--repo-root", str(ROOT),
            "--first-party", "cmux-tui/crates/*", "--first-party", "cmux-tui/bindings/*",
            "--first-party-license", str(ROOT / "cmux-tui/dist/npm/cmux/LICENSE"),
            "--reviewed", str(BUILD_SUPPORT / "reviewed.json"),
            "--source-tag", source_tag, "--target", rust_target,
            "--format", "markdown", "--section-id", "rust-crates", "--title", f"Rust crates ({rust_target})",
            "--out", str(out),
        ]
        for root in KINDS[kind]["roots"]:
            command += ["--root", root]
        result = subprocess.run(command, env={**os.environ, "CARGO_HOME": str(cache)}, capture_output=True, text=True)
        if result.returncode != 0:
            raise NoticeError(f"rust_notices.py failed for {kind} {rust_target}:\n{result.stderr}")
        return out.read_text(encoding="utf-8")


def generate(args: argparse.Namespace) -> int:
    if not re.fullmatch(r"[0-9a-f]{40}", args.source_tag):
        raise NoticeError("--source-tag must be the full commit the binaries are built from")
    inputs = load_inputs()
    problems = data_problems(inputs)
    if problems:
        raise NoticeError("\n".join(problems))
    targets = args.target or list(TARGETS)
    for target in targets:
        if target not in TARGETS:
            raise NoticeError(f"unknown target {target}")
    fetch = subprocess.run(
        [sys.executable, str(BUILD_SUPPORT / "fetch_crates.py"), "--cache", str(args.cache), "--lock", str(ROOT / "cmux-tui/Cargo.lock")],
        capture_output=True, text=True,
    )
    if fetch.returncode != 0:
        raise NoticeError(f"fetch_crates.py failed:\n{fetch.stderr}")
    args.out_dir.mkdir(parents=True, exist_ok=True)
    for target in targets:
        for kind in KINDS:
            text = compose(kind, target, crates_markdown(kind, target, args.cache, args.source_tag), inputs)
            (args.out_dir / notice_name(kind, target)).write_text(text, encoding="utf-8")
            print(f"package_notices: wrote {notice_name(kind, target)} ({len(text)} bytes)")
    return 0


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="command", required=True)
    gen = sub.add_parser("generate")
    gen.add_argument("--out-dir", type=Path, required=True)
    gen.add_argument("--source-tag", required=True, help="full commit of the cmux tree the binaries are built from")
    gen.add_argument("--cache", type=Path, default=Path(os.environ.get("CMUX_NOTICES_CACHE", Path.home() / ".cache/cmux-notices")))
    gen.add_argument("--target", action="append")
    sub.add_parser("check-data")
    check_toolchain = sub.add_parser("check-windows-toolchain")
    check_toolchain.add_argument("--gcc", default="x86_64-w64-mingw32-gcc", help="the linker rustc uses for x86_64-pc-windows-gnu")
    check_windows = sub.add_parser("check-windows-binary")
    check_windows.add_argument("binaries", type=Path, nargs="+")
    check_darwin = sub.add_parser("check-darwin-binary")
    check_darwin.add_argument("binaries", type=Path, nargs="+")
    args = parser.parse_args(argv)
    try:
        if args.command == "generate":
            return generate(args)
        if args.command == "check-windows-toolchain":
            version = subprocess.run([args.gcc, "--version"], capture_output=True, text=True, check=True).stdout
            macros = subprocess.run(
                [args.gcc, "-dM", "-E", "-x", "c", "-"], input="#include <_mingw.h>\n",
                capture_output=True, text=True, check=True,
            ).stdout
            problems = windows_toolchain_problems(version, macros, load_inputs())
            for problem in problems:
                print(f"package_notices: error: {problem}", file=sys.stderr)
            if not problems:
                print(f"package_notices: {version.splitlines()[0]} is the reviewed Windows runtime toolchain")
            return 1 if problems else 0
        if args.command == "check-windows-binary":
            inputs = load_inputs()
            failed = False
            for binary in args.binaries:
                for problem in windows_binary_problems(binary.read_bytes(), inputs):
                    print(f"package_notices: error: {binary}: {problem}", file=sys.stderr)
                    failed = True
            if not failed:
                print(f"package_notices: {len(args.binaries)} Windows binaries name no GCC build but the reviewed one")
            return 1 if failed else 0
        if args.command == "check-darwin-binary":
            inputs = load_inputs()
            failed = False
            for binary in args.binaries:
                for problem in darwin_binary_problems(binary.read_bytes(), inputs):
                    print(f"package_notices: error: {binary}: {problem}", file=sys.stderr)
                    failed = True
            if not failed:
                print(f"package_notices: {len(args.binaries)} Darwin binaries link no musl-derived code")
            return 1 if failed else 0
        problems = data_problems(load_inputs())
    except NoticeError as error:
        print(f"package_notices: error: {error}", file=sys.stderr)
        return 1
    for problem in problems:
        print(f"package_notices: error: {problem}", file=sys.stderr)
    if problems:
        return 1
    print("package_notices: package notice data matches vt-link-graph.json and its sha256 values")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
