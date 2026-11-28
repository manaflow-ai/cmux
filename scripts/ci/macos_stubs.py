#!/usr/bin/env python3
"""Framework link stubs for the macOS cross build on Linux (no Apple SDK).

The Linux link of the daemon family (cmux-tui, cmux-tui-hook, acpmux,
chatmux-relay) needs a stub for each Apple framework it links. No SDK file is
used: each stub is a text-based dylib stub (.tbd v4) that this script writes
from the imports of our own Mac-built binaries. A stub holds only the install
name, the two version numbers and the symbol names that our binaries import.
libSystem and libiconv come from the sysroot (scripts/ci/macos-cross.sh).

  macos_stubs.py generate <stub-dir> <mac-binary>...   write one .tbd per framework
  macos_stubs.py check <stub-dir> <mac-binary>...      exit 1 when a stub lacks an import
  macos_stubs.py install <stub-dir> <sysroot>          place the stubs where the linker looks
  macos_stubs.py merge <stub-dir> <newer-stub-dir>     add the newer dir's symbols (and stubs) to stub-dir
  macos_stubs.py sys-crates <stub-dir> <Cargo.lock>    add every extern the locked Apple -sys crates declare
  macos_stubs.py lock-scan <stub-dir> <Cargo.lock> [--rescan]
                                                       the same for every other locked crates.io package

`sys-crates` covers what the Mac binaries do not import yet. The stubs come from
binaries built before a change, so the first call into a locked binding crate
(#54956's security_framework::item search, 2026-11-27) failed every Linux link
of cmux-tui: "undefined symbol: kSecMatchSearchList" and 19 more. For each crate
in SYS_CRATES at the version cmux-tui/Cargo.lock pins, it adds every name the
crate's `extern "C"` blocks declare to that framework's stub and records the
version in sys-crates.txt; tests/test_ci_macos_stubs.py fails when the lock
pins a version that file does not list. Sources: SYS_CRATES_SRC, then
~/.cargo/registry/src, then static.crates.io.

MACOS_STUBS_SYSTEM_TBD names the sysroot's libSystem.tbd: routines it exports
need no framework stub (scripts/ci/macos-cross.sh sets it).

`check` is the drift guard: a dependency bump that imports a new framework
symbol also fails the Linux link loudly (undefined symbol), and `check` names
the stub to regenerate. Regenerate from the Mac-built binaries of one commit:
  scripts/ci/macos-cross.sh fetch-refs <sha>
  scripts/ci/macos_stubs.py generate scripts/ci/macos-stubs "$XC_ROOT"/ref/*-apple-darwin

Tools: LLVM_BIN (default /usr/lib/llvm-19/bin) for llvm-nm and llvm-objdump.
"""
from __future__ import annotations

import os
import re
import shutil
import subprocess
import sys
from pathlib import Path

# The sysroot provides these (Zig's libSystem stub, the libiconv install-name stub).
SYSROOT_DYLIBS = {"/usr/lib/libSystem.B.dylib", "/usr/lib/libiconv.2.dylib"}
TARGETS = "[ x86_64-macos, arm64-macos ]"
FROM = re.compile(r"\(undefined\) (?:weak )?external (\S+) \(from ([^)]+)\)")
DYLIB = re.compile(r"^\s*(\S.*?) \(compatibility version ([0-9.]+), current version ([0-9.]+)(, weak)?\)")


def _tool(name: str) -> str:
    return os.path.join(os.environ.get("LLVM_BIN", "/usr/lib/llvm-19/bin"), name)


def _run(*args: str) -> str:
    return subprocess.run(list(args), capture_output=True, text=True, check=True).stdout


def short_name(install_name: str) -> str:
    """The name llvm-nm -m prints after `from`: the leaf without extension or version."""
    return Path(install_name).name.split(".")[0]


def imports(binary: str) -> dict[str, dict]:
    """{install name: {"current": v, "compat": v, "symbols": set}} for one Mach-O binary."""
    libs: dict[str, dict] = {}
    by_short: dict[str, str] = {}
    for line in _run(_tool("llvm-objdump"), "--macho", "--dylibs-used", binary).splitlines()[1:]:
        match = DYLIB.match(line)
        if match:
            install = match.group(1)
            libs[install] = {"current": match.group(3), "compat": match.group(2), "symbols": set()}
            by_short[short_name(install)] = install
    for line in _run(_tool("llvm-nm"), "-m", "-u", binary).splitlines():
        match = FROM.search(line)
        if not match:
            continue
        symbol, source = match.groups()
        if source not in by_short:
            raise SystemExit(f"{binary}: {symbol} comes from {source}, which no LC_LOAD_DYLIB names")
        libs[by_short[source]]["symbols"].add(symbol)
    return libs


def tbd_symbols(path: Path | None) -> set[str]:
    """Every quoted or bare `_name` a .tbd file lists (a libSystem stub here)."""
    if path is None:
        return set()
    return set(re.findall(r"(?<![A-Za-z0-9_$])_[A-Za-z0-9_$.]+", path.read_text()))


def merged_imports(binaries: list[str], system: Path | None = None) -> dict[str, dict]:
    """Framework imports of the binaries. A routine that libSystem exports needs
    no stub: the Linux link binds it to libSystem, whichever umbrella framework
    a Mac link bound it to (macOS 15 SDK: CoreServices for log2)."""
    exported_by_system = tbd_symbols(system)
    merged: dict[str, dict] = {}
    for binary in binaries:
        for install, lib in imports(binary).items():
            if install in SYSROOT_DYLIBS:
                continue
            entry = merged.setdefault(install, {"current": lib["current"], "compat": lib["compat"], "symbols": set()})
            if (entry["current"], entry["compat"]) != (lib["current"], lib["compat"]):
                raise SystemExit(f"{install}: two versions in the inputs ({entry['current']} and {lib['current']});"
                                 " generate from the binaries of one commit")
            entry["symbols"] |= lib["symbols"] - exported_by_system
    return merged


def render(install: str, lib: dict) -> str:
    symbols = "".join(f"\n                       '{s}'," for s in sorted(lib["symbols"])).rstrip(",")
    return (
        "--- !tapi-tbd\n"
        "tbd-version:     4\n"
        f"targets:         {TARGETS}\n"
        f"install-name:    '{install}'\n"
        f"current-version: {lib['current']}\n"
        f"compatibility-version: {lib['compat']}\n"
        "exports:\n"
        f"  - targets:         {TARGETS}\n"
        f"    symbols:         [{symbols} ]\n"
        "...\n"
    )


def stub_file(stub_dir: Path, install: str) -> Path:
    return stub_dir / f"{short_name(install)}.tbd"


def read_stub(path: Path) -> tuple[str, set[str]]:
    text = path.read_text()
    install = re.search(r"^install-name:\s+'([^']+)'", text, re.M)
    if not install:
        raise SystemExit(f"{path}: no install-name")
    return install.group(1), set(re.findall(r"'(_[^']*)'", text))


def cmd_generate(stub_dir: Path, binaries: list[str], system: Path | None = None) -> int:
    stub_dir.mkdir(parents=True, exist_ok=True)
    for old in stub_dir.glob("*.tbd"):
        old.unlink()
    for install, lib in sorted(merged_imports(binaries, system).items()):
        stub_file(stub_dir, install).write_text(render(install, lib))
        print(f"stub {short_name(install)}: {len(lib['symbols'])} symbols, current {lib['current']}")
    return 0


def cmd_check(stub_dir: Path, binaries: list[str], system: Path | None = None) -> int:
    status = 0
    for install, lib in sorted(merged_imports(binaries, system).items()):
        path = stub_file(stub_dir, install)
        if not path.exists():
            print(f"FAIL stubs: {install} has no stub ({path})")
            status = 1
            continue
        stub_install, symbols = read_stub(path)
        missing = sorted(lib["symbols"] - symbols)
        if stub_install != install or missing:
            print(f"FAIL stubs: {path.name}: install-name {stub_install}, missing {len(missing)}: {missing[:8]}")
            status = 1
        else:
            print(f"PASS stubs: {path.name} covers {len(lib['symbols'])} imports")
    return status


def cmd_install(stub_dir: Path, sysroot: Path) -> int:
    headers = stub_dir / "include"
    if headers.is_dir():
        shutil.copytree(headers, sysroot / "usr/include", dirs_exist_ok=True)
    for path in sorted(stub_dir.glob("*.tbd")):
        install, _ = read_stub(path)
        framework = re.match(r"^/System/Library/Frameworks/([^/]+)\.framework/", install)
        if framework:
            dest = sysroot / "System/Library/Frameworks" / f"{framework.group(1)}.framework" / f"{framework.group(1)}.tbd"
        elif install.startswith("/usr/lib/"):
            dest = sysroot / "usr/lib" / (Path(install).name.split(".")[0] + ".tbd")
        else:
            raise SystemExit(f"{path}: unsupported install name {install}")
        dest.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(path, dest)
        print(f"installed {path.name} -> {dest.relative_to(sysroot)}")
    return 0


def cmd_merge(stub_dir: Path, newer: Path) -> int:
    """Union the newer stubs into stub_dir, so a head built on older stubs links what the base branch added."""
    for path in sorted(newer.glob("*.tbd")):
        install, symbols = read_stub(path)
        dest = stub_dir / path.name
        if dest.exists():
            old_install, old = read_stub(dest)
            if old_install != install:
                raise SystemExit(f"{dest}: install-name {old_install} differs from {install}")
            added = symbols - old
            if not added:
                continue
            text = path.read_text()
            cur = re.search(r"^current-version:\s+(\S+)", text, re.M)
            compat = re.search(r"^compatibility-version:\s+(\S+)", text, re.M)
            dest.write_text(render(install, {"current": cur.group(1), "compat": compat.group(1), "symbols": old | symbols}))
            print(f"merged {dest.name}: +{len(added)} symbols")
        else:
            shutil.copyfile(path, dest)
            print(f"merged {dest.name}: new stub")
    headers = newer / "include"
    if headers.is_dir():
        shutil.copytree(headers, stub_dir / "include", dirs_exist_ok=True)
    return 0


# The binding crates whose `extern "C"` items link one framework each. A name
# they declare is a symbol of that framework (core-foundation-sys links
# CoreFoundation in lib.rs, security-framework-sys Security in lib.rs,
# system-configuration-sys SystemConfiguration from build.rs).
SYS_CRATES = {
    "core-foundation-sys": "CoreFoundation",
    # objc2's runtime FFI (objc2::ffi): the Mac binaries import only the calls they already make, so a
    # first objc_alloc or class_getName (2026-11-28, every Linux link of cmux-tui) found no stub.
    "objc2": "libobjc",
    # netwatch (iroh, #56513) links these two; neither framework had a stub, so every
    # Linux link of the daemon failed "framework not found for -framework CoreWLAN".
    "objc2-core-wlan": "CoreWLAN",
    "objc2-security-foundation": "SecurityFoundation",
    "security-framework-sys": "Security",
    "system-configuration-sys": "SystemConfiguration",
}
# Every other objc2 binding crate the lock pins. A crate links its framework (`#[link(kind = "framework")]`)
# whenever it is built, so a new one fails the Linux link unless its framework has a stub:
# tests/test_ci_macos_stubs.py fails until a new crate is put in SYS_CRATES or here.
OBJC2_STUBBED_FROM_BINARIES = {  # the framework's stub comes from our Mac binaries' imports
    "objc2-encode": "none", "objc2-app-kit": "AppKit",
    "objc2-core-foundation": "CoreFoundation", "objc2-core-graphics": "CoreGraphics",
    "objc2-foundation": "Foundation", "objc2-security": "Security",
    "objc2-system-configuration": "SystemConfiguration",
}
OBJC2_NOT_IN_DAEMON_BUILD = {  # locked for a feature or target the daemon family does not build
    "objc2-cloud-kit", "objc2-core-data", "objc2-core-image", "objc2-core-text",
    "objc2-core-video", "objc2-io-surface", "objc2-quartz-core",
}
NEW_FRAMEWORK_INSTALL = "/System/Library/Frameworks/{0}.framework/Versions/A/{0}"
SYS_CRATES_FILE = "sys-crates.txt"
# objc2 declares its runtime calls in its own extern_c! and extern_c_unwind! blocks (objc2::ffi), not a bare
# `extern "C" {`: reading only the bare form found 10 of its externs and left objc_alloc out.
EXTERN_BLOCK = re.compile(r'(?:extern\s+"C(?:-unwind)?"|\bextern_c(?:_unwind)?!)\s*\{')
EXTERN_ITEM = re.compile(r"\b(?:static(?:\s+mut)?|fn)\s+([A-Za-z_][A-Za-z0-9_]*)")
LOCKED = re.compile(r'^\[\[package\]\]\nname = "([^"]+)"\nversion = "([^"]+)"', re.M)


def locked_versions(lock_text: str) -> dict[str, list[str]]:
    """{crate in SYS_CRATES: sorted versions} that a Cargo.lock pins."""
    out: dict[str, list[str]] = {}
    for name, version in LOCKED.findall(lock_text):
        if name in SYS_CRATES:
            out.setdefault(name, []).append(version)
    return {name: sorted(set(versions)) for name, versions in out.items()}


def declared_externs(src: Path) -> set[str]:
    """Every item name (as a Mach-O symbol, `_name`) in a crate's `extern "C"` blocks."""
    names: set[str] = set()
    for path in sorted(src.rglob("*.rs")):
        text = path.read_text(errors="replace")
        for match in EXTERN_BLOCK.finditer(text):
            depth, end = 1, match.end()
            while depth and end < len(text):
                depth += {"{": 1, "}": -1}.get(text[end], 0)
                end += 1
            # A comment is no declaration: objc2's doc examples ("fn some_external_function") and prose ("static
            # and", "the linker") made stub symbols of words.
            body = re.sub(r"//[^\n]*", "", text[match.end():end - 1])
            names |= {f"_{name}" for name in EXTERN_ITEM.findall(body)}
    return names


def crate_source(name: str, version: str, scratch: Path) -> Path:
    leaf = f"{name}-{version}"
    roots = [Path(os.environ["SYS_CRATES_SRC"])] if os.environ.get("SYS_CRATES_SRC") else []
    roots += sorted((Path.home() / ".cargo/registry/src").glob("*"))
    for root in roots:
        if (root / leaf / "src").is_dir():
            return root / leaf
    import tarfile
    import urllib.request
    archive = scratch / f"{leaf}.crate"
    with urllib.request.urlopen(f"https://static.crates.io/crates/{name}/{leaf}.crate", timeout=60) as response:
        archive.write_bytes(response.read())
    with tarfile.open(archive) as tar:
        tar.extractall(scratch, filter="data")
    return scratch / leaf


def cmd_sys_crates(stub_dir: Path, lock: Path, system: Path | None = None) -> int:
    import tempfile
    exported_by_system = tbd_symbols(system)
    rows = []
    with tempfile.TemporaryDirectory() as scratch:
        for name, versions in sorted(locked_versions(lock.read_text()).items()):
            framework = SYS_CRATES[name]
            path = stub_dir / f"{framework}.tbd"
            if not path.exists():  # a framework no Mac binary imports yet: start its stub
                path.write_text(render(NEW_FRAMEWORK_INSTALL.format(framework),
                                       {"current": "1.0.0", "compat": "1.0.0", "symbols": set()}))
            install, held = read_stub(path)
            text = path.read_text()
            cur = re.search(r"^current-version:\s+(\S+)", text, re.M).group(1)
            compat = re.search(r"^compatibility-version:\s+(\S+)", text, re.M).group(1)
            for version in versions:
                declared = declared_externs(crate_source(name, version, Path(scratch)) / "src") - exported_by_system
                added = declared - held
                held |= declared
                rows.append(f"{name} {version} {framework} {len(declared)}")
                print(f"sys-crates {name} {version}: {len(declared)} declared, +{len(added)} in {path.name}")
            path.write_text(render(install, {"current": cur, "compat": compat, "symbols": held}))
    (stub_dir / SYS_CRATES_FILE).write_text(
        "# crate version framework declared-symbols: the binding crates whose every extern is in the stubs\n"
        "# (scripts/ci/macos_stubs.py sys-crates scripts/ci/macos-stubs cmux-tui/Cargo.lock)\n"
        + "".join(f"{row}\n" for row in rows))
    return 0


# Every other crates.io package cmux-tui/Cargo.lock pins. Any crate can declare framework externs of its own
# (`#[link(name = "X", kind = "framework")] extern "C" { ... }`, or `cargo:rustc-link-lib=framework=X` in build.rs),
# and a first call into one fails the Linux link the way #54956's keychain search did, from a crate no list above
# names. `lock-scan` reads each locked package once, writes the frameworks and names it declares to lock-scan.txt
# (one line per crate and framework, `-` for none) and adds the names to the framework's stub; the parity test
# fails when the lock pins a package the file lacks that declares a framework, or a recorded name is not in its
# stub. SYS_CRATES and the objc2 crates are covered above and skipped here.
LOCK_SCAN_FILE = "lock-scan.txt"
REGISTRY_PACKAGE = re.compile(r'^\[\[package\]\]\nname = "([^"]+)"\nversion = "([^"]+)"\nsource = "registry\+', re.M)
FRAMEWORK_LINK = re.compile(r'link\(\s*name\s*=\s*"([A-Za-z0-9_]+)"\s*,\s*kind\s*=\s*"framework"[^)]*\)')
BLOCK_AFTER_LINK = re.compile(r'\)?\]\s*(?:#\[[^\]]*\]\s*)*(?:pub(?:\([^)]*\))?\s+)?(?:unsafe\s+)?'
                              r'extern\s+"C(?:-unwind)?"\s*\{')
BUILD_FRAMEWORK = re.compile(r"rustc-link-lib=framework=([A-Za-z0-9_]+)")


def lock_scan_packages(lock_text: str) -> list[tuple[str, str]]:
    """The crates.io packages lock-scan covers: every one but SYS_CRATES and the objc2 crates."""
    return sorted({(name, version) for name, version in REGISTRY_PACKAGE.findall(lock_text)
                   if name not in SYS_CRATES and not name.startswith("objc2")})


def framework_declarations(crate: Path) -> dict[str, set[str]]:
    """{framework: `_name`s} a crate's source declares: the items of each framework-linked extern block, and a
    framework its build script links (no names known: an empty set, which still needs the framework's stub)."""
    out: dict[str, set[str]] = {}
    for path in sorted(crate.rglob("*.rs")):
        text = path.read_text(errors="replace")
        for framework in BUILD_FRAMEWORK.findall(text):
            out.setdefault(framework, set())
        for match in FRAMEWORK_LINK.finditer(text):
            names = out.setdefault(match.group(1), set())
            block = BLOCK_AFTER_LINK.match(text, match.end())
            if not block:
                continue
            depth, end = 1, block.end()
            while depth and end < len(text):
                depth += {"{": 1, "}": -1}.get(text[end], 0)
                end += 1
            body = re.sub(r"//[^\n]*", "", text[block.end():end - 1])  # a comment is no declaration (#64246)
            names |= {f"_{name}" for name in EXTERN_ITEM.findall(body)}
    return out


def read_lock_scan(path: Path) -> dict[tuple[str, str], dict[str, set[str]]]:
    """lock-scan.txt as {(crate, version): {framework: names}}; a `-` line is a crate that declares none."""
    record: dict[tuple[str, str], dict[str, set[str]]] = {}
    if not path.exists():
        return record
    for line in path.read_text().splitlines():
        if not line or line.startswith("#"):
            continue
        name, version, framework, *names = line.split()
        entry = record.setdefault((name, version), {})
        if framework != "-":
            entry.setdefault(framework, set()).update(names)
    return record


def scan_packages(packages: list[tuple[str, str]], scratch: Path) -> dict[tuple[str, str], dict[str, set[str]]]:
    from concurrent.futures import ThreadPoolExecutor

    def one(package: tuple[str, str]) -> tuple[tuple[str, str], dict[str, set[str]]]:
        folder = scratch / f"{package[0]}-{package[1]}"
        folder.mkdir()
        return package, framework_declarations(crate_source(*package, folder))

    with ThreadPoolExecutor(max_workers=16) as pool:
        return dict(pool.map(one, packages))


def add_to_stub(stub_dir: Path, framework: str, names: set[str]) -> int:
    """Put NAMES in FRAMEWORK's stub (started when no Mac binary imports the framework yet); how many were new."""
    path = stub_dir / f"{framework}.tbd"
    if not path.exists():
        path.write_text(render(NEW_FRAMEWORK_INSTALL.format(framework),
                               {"current": "1.0.0", "compat": "1.0.0", "symbols": set()}))
    install, held = read_stub(path)
    added = names - held
    if added:
        text = path.read_text()
        cur = re.search(r"^current-version:\s+(\S+)", text, re.M).group(1)
        compat = re.search(r"^compatibility-version:\s+(\S+)", text, re.M).group(1)
        path.write_text(render(install, {"current": cur, "compat": compat, "symbols": held | names}))
    return len(added)


def cmd_lock_scan(stub_dir: Path, lock: Path, system: Path | None = None, rescan: bool = False) -> int:
    import tempfile
    exported_by_system = tbd_symbols(system)
    record = read_lock_scan(stub_dir / LOCK_SCAN_FILE)
    packages = lock_scan_packages(lock.read_text())
    todo = [package for package in packages if rescan or package not in record]
    with tempfile.TemporaryDirectory() as scratch:
        record.update(scan_packages(todo, Path(scratch)))
    lines = []
    for package in packages:
        declared = record[package]
        for framework, names in sorted(declared.items()):
            names = names - exported_by_system
            added = add_to_stub(stub_dir, framework, names)
            if package in todo:
                print(f"lock-scan {package[0]} {package[1]}: {framework} {len(names)} declared, +{added}")
            lines.append(" ".join([*package, framework, *sorted(names)]))
        if not declared:
            lines.append(f"{package[0]} {package[1]} -")
    (stub_dir / LOCK_SCAN_FILE).write_text(
        "# crate version framework names...: what each locked crates.io package declares against an Apple framework\n"
        "# (`-`: none). scripts/ci/macos_stubs.py lock-scan scripts/ci/macos-stubs cmux-tui/Cargo.lock\n"
        + "".join(f"{line}\n" for line in lines))
    print(f"lock-scan: {len(packages)} packages, {len(todo)} read, "
          f"{sum(1 for p in packages if record[p])} declare a framework")
    return 0


def main(argv: list[str]) -> int:
    if len(argv) < 4 or argv[1] not in {"generate", "check", "install", "merge", "sys-crates", "lock-scan"}:
        print(__doc__, file=sys.stderr)
        return 2
    command, stub_dir = argv[1], Path(argv[2])
    if command == "install":
        return cmd_install(stub_dir, Path(argv[3]))
    if command == "merge":
        return cmd_merge(stub_dir, Path(argv[3]))
    system = Path(os.environ["MACOS_STUBS_SYSTEM_TBD"]) if os.environ.get("MACOS_STUBS_SYSTEM_TBD") else None
    if command == "sys-crates":
        return cmd_sys_crates(stub_dir, Path(argv[3]), system)
    if command == "lock-scan":
        return cmd_lock_scan(stub_dir, Path(argv[3]), system, rescan="--rescan" in argv[4:])
    return (cmd_generate if command == "generate" else cmd_check)(stub_dir, argv[3:], system)


if __name__ == "__main__":
    sys.exit(main(sys.argv))
