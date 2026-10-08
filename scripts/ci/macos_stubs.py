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


def merged_imports(binaries: list[str]) -> dict[str, dict]:
    merged: dict[str, dict] = {}
    for binary in binaries:
        for install, lib in imports(binary).items():
            if install in SYSROOT_DYLIBS:
                continue
            entry = merged.setdefault(install, {"current": lib["current"], "compat": lib["compat"], "symbols": set()})
            if (entry["current"], entry["compat"]) != (lib["current"], lib["compat"]):
                raise SystemExit(f"{install}: two versions in the inputs ({entry['current']} and {lib['current']});"
                                 " generate from the binaries of one commit")
            entry["symbols"] |= lib["symbols"]
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


def cmd_generate(stub_dir: Path, binaries: list[str]) -> int:
    stub_dir.mkdir(parents=True, exist_ok=True)
    for old in stub_dir.glob("*.tbd"):
        old.unlink()
    for install, lib in sorted(merged_imports(binaries).items()):
        stub_file(stub_dir, install).write_text(render(install, lib))
        print(f"stub {short_name(install)}: {len(lib['symbols'])} symbols, current {lib['current']}")
    return 0


def cmd_check(stub_dir: Path, binaries: list[str]) -> int:
    status = 0
    for install, lib in sorted(merged_imports(binaries).items()):
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


def main(argv: list[str]) -> int:
    if len(argv) < 4 or argv[1] not in {"generate", "check", "install"}:
        print(__doc__, file=sys.stderr)
        return 2
    command, stub_dir = argv[1], Path(argv[2])
    if command == "install":
        return cmd_install(stub_dir, Path(argv[3]))
    return (cmd_generate if command == "generate" else cmd_check)(stub_dir, argv[3:])


if __name__ == "__main__":
    sys.exit(main(sys.argv))
