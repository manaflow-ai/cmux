#!/usr/bin/env python3
"""Compare a Mac-built and a Linux-built Mach-O artifact (executable or static archive).

The macOS cross-compile shadow (scripts/ci/macos-cross.sh) builds artifacts on
Linux beside the Mac build and replaces nothing. This script is its verdict:

  macho_parity.py <name> <mac-file> <linux-file>   prints one JSON report
  exit 0 = parity holds, 1 = a parity check failed, 2 = usage or tool error

Checks: architectures, deployment target (LC_BUILD_VERSION platform and minos,
or LC_VERSION_MIN_MACOSX), linked dylibs, imported (undefined) symbols,
exported (global defined) symbols (an executable: its C-named ones, see
interface()), unexpected load commands, and an ad-hoc
signature on arm64 executables. Accepted differences are listed below with
their reason; anything else fails.

Tools: LLVM_BIN (default /usr/lib/llvm-19/bin) for llvm-objdump, llvm-lipo and
llvm-size; LLVM_NM overrides llvm-nm (rustc's llvm-tools nm reads the bitcode
sections in Rust static archives that an older llvm-nm rejects).
"""
from __future__ import annotations

import json
import os
import re
import subprocess
import sys

# Linker-only load commands: they depend on the linker, not on the code.
# LC_SOURCE_VERSION: Apple ld64 writes it, ld64.lld does not.
ACCEPTED_LOAD_COMMAND_DIFFS = {
    "LC_DYLD_CHAINED_FIXUPS", "LC_DYLD_EXPORTS_TRIE", "LC_DYLD_INFO", "LC_DYLD_INFO_ONLY",
    "LC_SOURCE_VERSION", "LC_DATA_IN_CODE", "LC_FUNCTION_STARTS", "LC_UUID",
}
# Apple clang probes large C stack frames by calling ___chkstk_darwin. Upstream
# clang with -fstack-clash-protection probes the same frames inline, so the
# Linux build does not import it. Accepted only as a Mac-only import.
ACCEPTED_MAC_ONLY_IMPORTS = {"___chkstk_darwin", "____chkstk_darwin"}
RUST_HASH = re.compile(r"17h[0-9a-f]{16}E$")


def normalize_symbol(name: str) -> str:
    """Drop the Rust legacy-mangling hash: it hashes the build environment."""
    return RUST_HASH.sub("E", name)


def _tool(name: str) -> str:
    if name == "llvm-nm" and os.environ.get("LLVM_NM"):
        return os.environ["LLVM_NM"]
    return os.path.join(os.environ.get("LLVM_BIN", "/usr/lib/llvm-19/bin"), name)


def _run(name: str, *args: str) -> str:
    return subprocess.run([_tool(name), *args], capture_output=True, text=True, check=True).stdout


def _build_versions(headers: str) -> list[str]:
    found = set()
    for block in headers.split("Load command")[1:]:
        if "cmd LC_BUILD_VERSION" in block:
            platform = re.search(r"platform (\S+)", block)
            minos = re.search(r"minos (\S+)", block)
            sdk = re.search(r"\bsdk (\S+)", block)
            found.add(f"platform={platform and platform.group(1)} minos={minos and minos.group(1)} "
                      f"sdk={sdk and sdk.group(1)}")
        elif "cmd LC_VERSION_MIN_MACOSX" in block:
            version = re.search(r"\bversion (\S+)", block)
            found.add(f"LC_VERSION_MIN_MACOSX {version and version.group(1)}")
    return sorted(found)


def _symbols(path: str, *flags: str) -> list[str]:
    out = _run("llvm-nm", "--just-symbol-name", *flags, path)
    names = (normalize_symbol(line.strip()) for line in out.splitlines())
    return sorted({n for n in names if n and not n.endswith(":")})


def inspect(path: str) -> dict:
    headers = _run("llvm-objdump", "--macho", "--private-headers", path)
    dylibs = []
    for line in _run("llvm-objdump", "--macho", "--dylibs-used", path).splitlines()[1:]:
        line = line.strip()
        if line and not line.endswith(":"):
            dylibs.append(re.sub(r"\s*\(compatibility version.*$", "", line))
    try:
        archs = sorted(_run("llvm-lipo", "-archs", path).split())
    except subprocess.CalledProcessError:
        archs = []
    text = sum(int(m) for m in re.findall(r"Section __text: (\d+)", _run("llvm-size", "-m", path)))
    return {
        "bytes": os.path.getsize(path),
        "text_bytes": text,
        "archs": archs,
        "build_version": _build_versions(headers),
        "load_commands": sorted(set(re.findall(r"cmd (LC_[A-Z0-9_]+)", headers))),
        "dylibs": sorted(set(dylibs)),
        "undefined": _symbols(path, "-u"),
        "exported": _symbols(path, "-g", "--defined-only"),
    }


def _diff(mac: list[str], linux: list[str], limit: int = 15) -> dict:
    only_mac, only_linux = set(mac) - set(linux), set(linux) - set(mac)
    return {"only_mac": sorted(only_mac)[:limit], "only_linux": sorted(only_linux)[:limit],
            "only_mac_count": len(only_mac), "only_linux_count": len(only_linux),
            "common": len(set(mac) & set(linux))}


def _deployment(versions: list[str]) -> list[str]:
    """Platform and minos only. The SDK version is metadata of the build host."""
    return [re.sub(r" sdk=\S+", "", v) for v in versions]


def interface(info: dict) -> list[str]:
    """The exports another image can bind to. For an executable (LC_MAIN) that
    is its C-named symbols: which of two identical Rust functions keeps its
    global name is a linker choice (ld64 and ld64.lld choose differently), and
    nothing binds to an executable's Rust symbols. Archives keep every export."""
    if "LC_MAIN" not in info["load_commands"]:
        return info["exported"]
    return [s for s in info["exported"] if not s.startswith(("__ZN", "__R"))]


def evaluate(name: str, mac: dict, linux: dict) -> dict:
    load_commands = _diff(mac["load_commands"], linux["load_commands"])
    unexpected_lc = (set(mac["load_commands"]) ^ set(linux["load_commands"])) - ACCEPTED_LOAD_COMMAND_DIFFS
    mac_imports, linux_imports = set(mac["undefined"]), set(linux["undefined"])
    checks = {
        "archs": mac["archs"] == linux["archs"],
        "deployment_target": _deployment(mac["build_version"]) == _deployment(linux["build_version"]),
        "dylibs": mac["dylibs"] == linux["dylibs"],
        "undefined_symbols": not (linux_imports - mac_imports)
        and not ((mac_imports - linux_imports) - ACCEPTED_MAC_ONLY_IMPORTS),
        "exported_symbols": interface(mac) == interface(linux),
        "load_commands_unexpected": not unexpected_lc,
        # ld64 signs arm64 executables ad hoc; the Linux link must too.
        "code_signature_if_arm64_exe": not ("LC_MAIN" in mac["load_commands"]
                                            and "LC_CODE_SIGNATURE" in mac["load_commands"]
                                            and "LC_CODE_SIGNATURE" not in linux["load_commands"]),
    }
    keys = ("bytes", "text_bytes", "archs", "build_version", "dylibs")
    return {
        "name": name,
        "pass": all(checks.values()),
        "checks": checks,
        "mac": {k: mac[k] for k in keys},
        "linux": {k: linux[k] for k in keys},
        "size_ratio_linux_over_mac": round(linux["bytes"] / mac["bytes"], 3) if mac["bytes"] else None,
        "text_ratio_linux_over_mac": round(linux["text_bytes"] / mac["text_bytes"], 3) if mac["text_bytes"] else None,
        "load_commands": load_commands,
        "undefined": _diff(mac["undefined"], linux["undefined"]),
        "exported": _diff(mac["exported"], linux["exported"]),
    }


def main(argv: list[str]) -> int:
    if len(argv) != 4:
        print(__doc__, file=sys.stderr)
        return 2
    name, mac_path, linux_path = argv[1:]
    try:
        report = evaluate(name, inspect(mac_path), inspect(linux_path))
    except (OSError, subprocess.CalledProcessError) as error:
        print(f"macho_parity: {name}: {error}", file=sys.stderr)
        return 2
    print(json.dumps(report, indent=1))
    return 0 if report["pass"] else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv))
