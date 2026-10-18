#!/usr/bin/env python3
"""Find every Mach-O in an app bundle that cannot load on the bundle's macOS floor.

cmux-next declares LSMinimumSystemVersion 14.0. The bundle also carries Rust,
Zig, C++ and CEF binaries that are built outside Xcode, so the Xcode
deployment target alone does not prove they load on macOS 14. dyld refuses a
binary whose LC_BUILD_VERSION minos is newer than the running OS, and a strong
(non-weak) load of a system library that the OS does not have stops the
process before main.

  macho_minos.py scan APP [--floor 14.0] [--json]
      Walk APP, parse every Mach-O (thin or fat, every slice) with no external
      tool, and fail when:
        - a slice's minos (LC_BUILD_VERSION, or LC_VERSION_MIN_MACOSX) is newer
          than the floor, or a slice has no deployment target at all;
        - a slice strong-loads a system library in NEWER_THAN_14 (a library
          that macOS 14 does not ship; a weak load is fine);
        - the bundle's or a nested bundle's Info.plist LSMinimumSystemVersion
          is newer than the floor (LaunchServices refuses to start it).
      The floor defaults to the outer bundle's LSMinimumSystemVersion.
      exit 0 = every file loads on the floor, 1 = offenders, 2 = usage error.

Pure Python (stdlib only): it runs on a Linux build host as well as on a Mac.
"""

from __future__ import annotations

import argparse
import json
import os
import plistlib
import struct
import sys
from pathlib import Path

MH_MAGIC_64 = 0xFEEDFACF
MH_MAGIC = 0xFEEDFACE
FAT_MAGIC = 0xCAFEBABE
FAT_MAGIC_64 = 0xCAFEBABF
LC_REQ_DYLD = 0x80000000
LC_LOAD_DYLIB = 0x0C
LC_LOAD_WEAK_DYLIB = 0x18 | LC_REQ_DYLD
LC_REEXPORT_DYLIB = 0x1F | LC_REQ_DYLD
LC_LAZY_LOAD_DYLIB = 0x20
LC_LOAD_UPWARD_DYLIB = 0x23 | LC_REQ_DYLD
LC_VERSION_MIN_MACOSX = 0x24
LC_BUILD_VERSION = 0x32
PLATFORM_MACOS = 1
PLATFORM_MACCATALYST = 6
FILE_TYPES = {1: "object", 2: "execute", 6: "dylib", 8: "bundle", 9: "dylib_stub", 10: "dsym", 11: "kext_bundle"}
CPU_TYPES = {0x01000007: "x86_64", 0x0100000C: "arm64", 7: "i386", 12: "arm"}

# System libraries that macOS 14 does not have. A strong load of any of them
# stops the process on macOS 14 before main ("Library not loaded"). Add a
# library here when the SDK gains one that cmux links; weak-link it (Swift:
# `-weak_framework`, or let the compiler weak-link under `#available`).
# /usr/lib/swift sources (MacOSX27.sdk usr/lib/swift, checked 2026-10-18): a
# library whose .tbd sends older targets to another install name with
# `$ld$previous$<old>$$1$<from>$<to>$` first exists at <to> (the Darwin split:
# libswift_errno ... libswiftunistd at 15.0, libswift_DarwinFoundation1-3 at
# 26.0, libswiftCompatibilitySpan in /usr/lib/swift at 26.0); a library with no
# redirect takes its module's availability (Synchronization 15.0, Runtime 26.0)
# or its Swift release (_Volatile and System_Foundation are Swift 6.2, macOS 26).
# A binary built with minos 14 links the old names; a minos 15+ binary (the
# cx-sisy8 dev helper) links the new ones, so the minos check fires as well.
NEWER_THAN_14 = {
    # macOS 15
    "/System/Library/Frameworks/SwiftUICore.framework/Versions/A/SwiftUICore": "15.0",
    "/System/Library/Frameworks/CoreHID.framework/Versions/A/CoreHID": "15.0",
    "/System/Library/Frameworks/MediaExtension.framework/Versions/A/MediaExtension": "15.0",
    "/System/Library/Frameworks/TranslationUIProvider.framework/Versions/A/TranslationUIProvider": "15.0",
    "/System/Library/Frameworks/DeviceDiscoveryUI.framework/Versions/A/DeviceDiscoveryUI": "15.0",
    "/System/Library/Frameworks/ExtensionFoundation.framework/Versions/A/ExtensionFoundation": "15.0",
    "/System/Library/Frameworks/ExtensionKit.framework/Versions/A/ExtensionKit": "13.0",
    "/usr/lib/swift/libswiftSynchronization.dylib": "15.0",
    "/usr/lib/swift/libswift_Builtin_float.dylib": "15.0",
    "/usr/lib/swift/libswift_errno.dylib": "15.0",
    "/usr/lib/swift/libswift_math.dylib": "15.0",
    "/usr/lib/swift/libswift_signal.dylib": "15.0",
    "/usr/lib/swift/libswift_stdio.dylib": "15.0",
    "/usr/lib/swift/libswift_time.dylib": "15.0",
    "/usr/lib/swift/libswiftsys_time.dylib": "15.0",
    "/usr/lib/swift/libswiftunistd.dylib": "15.0",
    # macOS 26
    "/usr/lib/swift/libswift_DarwinFoundation1.dylib": "26.0",
    "/usr/lib/swift/libswift_DarwinFoundation2.dylib": "26.0",
    "/usr/lib/swift/libswift_DarwinFoundation3.dylib": "26.0",
    "/usr/lib/swift/libswiftCompatibilitySpan.dylib": "26.0",
    "/usr/lib/swift/libswiftRuntime.dylib": "26.0",
    "/usr/lib/swift/libswift_Volatile.dylib": "26.0",
    "/usr/lib/swift/libswiftSystem_Foundation.dylib": "26.0",
    "/System/Library/Frameworks/FoundationModels.framework/Versions/A/FoundationModels": "26.0",
    "/System/Library/Frameworks/AlarmKit.framework/Versions/A/AlarmKit": "26.0",
    "/System/Library/Frameworks/SpeechAnalyzer.framework/Versions/A/SpeechAnalyzer": "26.0",
}


class MachOError(Exception):
    pass


def parse_version(text: str) -> tuple[int, int, int]:
    parts = text.strip().split(".")
    if not 1 <= len(parts) <= 3 or not all(p.isdigit() for p in parts):
        raise MachOError(f"not a macOS version: {text!r}")
    numbers = [int(p) for p in parts] + [0] * (3 - len(parts))
    return numbers[0], numbers[1], numbers[2]


def decode_version(value: int) -> str:
    major, minor, patch = value >> 16, (value >> 8) & 0xFF, value & 0xFF
    return f"{major}.{minor}" + (f".{patch}" if patch else "")


def _slices(data: bytes) -> list[tuple[int, int]]:
    """(offset, size) of every thin slice; empty when not a Mach-O."""
    if len(data) < 8:
        return []
    magic_be = struct.unpack(">I", data[:4])[0]
    if magic_be in (FAT_MAGIC, FAT_MAGIC_64):
        count = struct.unpack(">I", data[4:8])[0]
        if count == 0 or count > 32:  # Java class files share 0xCAFEBABE
            return []
        out = []
        for i in range(count):
            if magic_be == FAT_MAGIC:
                _, _, offset, size, _ = struct.unpack(">iiIII", data[8 + i * 20 : 28 + i * 20])
            else:
                _, _, offset, size, _, _ = struct.unpack(">iiQQII", data[8 + i * 32 : 40 + i * 32])
            out.append((offset, size))
        return out
    magic_le = struct.unpack("<I", data[:4])[0]
    if magic_le in (MH_MAGIC_64, MH_MAGIC):
        return [(0, len(data))]
    return []


def parse_slice(data: bytes, offset: int) -> dict:
    magic = struct.unpack("<I", data[offset : offset + 4])[0]
    if magic not in (MH_MAGIC_64, MH_MAGIC):
        raise MachOError(f"bad slice magic {magic:#x} at {offset}")
    is64 = magic == MH_MAGIC_64
    cputype, _, filetype, ncmds, _sizeofcmds, _flags = struct.unpack("<iiIIII", data[offset + 4 : offset + 28])
    cursor = offset + (32 if is64 else 28)
    info = {"arch": CPU_TYPES.get(cputype, hex(cputype)), "filetype": FILE_TYPES.get(filetype, str(filetype)),
            "minos": None, "sdk": None, "platform": None, "strong": [], "weak": []}
    for _ in range(ncmds):
        cmd, cmdsize = struct.unpack("<II", data[cursor : cursor + 8])
        if cmdsize < 8:
            raise MachOError("load command size < 8")
        if cmd == LC_BUILD_VERSION:
            platform, minos, sdk = struct.unpack("<III", data[cursor + 8 : cursor + 20])
            # A zippered binary has a macOS and a Mac Catalyst entry: the macOS one counts.
            if info["platform"] is None or platform == PLATFORM_MACOS:
                info.update(platform=platform, minos=decode_version(minos), sdk=decode_version(sdk))
        elif cmd == LC_VERSION_MIN_MACOSX:
            version, sdk = struct.unpack("<II", data[cursor + 8 : cursor + 16])
            info.update(platform=PLATFORM_MACOS, minos=decode_version(version), sdk=decode_version(sdk))
        elif cmd in (LC_LOAD_DYLIB, LC_LOAD_WEAK_DYLIB, LC_REEXPORT_DYLIB, LC_LAZY_LOAD_DYLIB, LC_LOAD_UPWARD_DYLIB):
            name_offset = struct.unpack("<I", data[cursor + 8 : cursor + 12])[0]
            raw = data[cursor + name_offset : cursor + cmdsize]
            name = raw.split(b"\0", 1)[0].decode("utf-8", "replace")
            info["weak" if cmd == LC_LOAD_WEAK_DYLIB else "strong"].append(name)
        cursor += cmdsize
    return info


def inspect(path: Path) -> list[dict] | None:
    """Parsed slices, or None when the file is not a Mach-O."""
    try:
        with path.open("rb") as handle:
            head = handle.read(8)
            magics = (FAT_MAGIC, FAT_MAGIC_64, MH_MAGIC_64, MH_MAGIC)
            if len(head) < 8 or (struct.unpack(">I", head[:4])[0] not in magics[:2]
                                 and struct.unpack("<I", head[:4])[0] not in magics[2:]):
                return None
            handle.seek(0)
            data = handle.read()
    except OSError:
        return None
    slices = _slices(data)
    if not slices:
        return None
    return [parse_slice(data, offset) for offset, _ in slices]


def bundle_floor(app: Path) -> str | None:
    info_path = app / "Contents" / "Info.plist"
    if not info_path.exists():
        return None
    with info_path.open("rb") as handle:
        value = plistlib.load(handle).get("LSMinimumSystemVersion")
    return value.strip() if isinstance(value, str) and value.strip() else None


def scan(app: Path, floor: str) -> dict:
    want = parse_version(floor)
    files, offenders = [], []
    declared = bundle_floor(app)
    if declared and parse_version(declared) > want:
        offenders.append({"file": "Contents/Info.plist", "problem": f"LSMinimumSystemVersion {declared} > {floor}"})
    for root, dirs, names in os.walk(app):
        dirs.sort()
        for name in sorted(names):
            path = Path(root) / name
            if path.is_symlink():
                continue
            rel = str(path.relative_to(app))
            if name == "Info.plist" and rel.endswith("Contents/Info.plist") and rel != "Contents/Info.plist":
                nested = bundle_floor(path.parent.parent)
                if nested and parse_version(nested) > want:
                    offenders.append({"file": rel, "problem": f"LSMinimumSystemVersion {nested} > {floor}"})
                continue
            slices = inspect(path)
            if slices is None:
                continue
            files.append({"file": rel, "slices": slices})
            for s in slices:
                if s["filetype"] in ("object", "dsym"):
                    continue
                if s["minos"] is None:
                    offenders.append({"file": rel, "arch": s["arch"], "problem": "no deployment target (LC_BUILD_VERSION)"})
                elif s["platform"] not in (PLATFORM_MACOS, PLATFORM_MACCATALYST):
                    offenders.append({"file": rel, "arch": s["arch"], "problem": f"platform {s['platform']} is not macOS"})
                elif parse_version(s["minos"]) > want:
                    offenders.append({"file": rel, "arch": s["arch"], "problem": f"minos {s['minos']} > {floor}", "sdk": s["sdk"]})
                for lib in s["strong"]:
                    since = NEWER_THAN_14.get(lib)
                    if since and parse_version(since) > want:
                        offenders.append({"file": rel, "arch": s["arch"], "problem": f"strong load of {lib} (macOS {since}+)"})
    return {"app": str(app), "floor": floor, "macho_count": len(files), "offenders": offenders, "files": files}


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="command", required=True)
    p_scan = sub.add_parser("scan")
    p_scan.add_argument("app", type=Path)
    p_scan.add_argument("--floor")
    p_scan.add_argument("--json", action="store_true", help="print the full per-file report")
    args = parser.parse_args(argv)
    if not args.app.is_dir():
        print(f"error: {args.app} is not a bundle directory", file=sys.stderr)
        return 2
    floor = args.floor or bundle_floor(args.app)
    if not floor:
        print(f"error: {args.app} has no LSMinimumSystemVersion and no --floor was given", file=sys.stderr)
        return 2
    try:
        report = scan(args.app, floor)
    except MachOError as error:
        print(f"error: {error}", file=sys.stderr)
        return 2
    if args.json:
        print(json.dumps(report, indent=1))
    else:
        print(f"{report['macho_count']} Mach-O files in {args.app.name}, floor macOS {floor}")
        for item in report["offenders"]:
            print(f"OFFENDER {item['file']}{' [' + item['arch'] + ']' if item.get('arch') else ''}: {item['problem']}")
        if not report["offenders"]:
            print("every Mach-O loads on the floor")
    return 1 if report["offenders"] else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
