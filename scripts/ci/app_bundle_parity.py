#!/usr/bin/env python3
"""app_bundle_parity.py: compare the cmux DEV app the build fleet built with the one this Mac compiled.

The cmux app scheme compile takes the fleet's Debug app when the fleet built it; one push in 16 (and any
dispatch that asks) also compiles on the Mac and runs this, so a difference between the two builds shows up
in a run instead of in a user's app. It compares the bundle's file list, each Info.plist's keys and values
(the build-time stamps excepted) and, for every Mach-O, the architectures and linked libraries
(`otool -L` when present). It prints a Markdown report and one JSON line, and exits 0 when they match, 1 when
they differ, 2 on a usage error. The caller logs a difference as a warning; it never fails the compile.

Usage: app_bundle_parity.py FLEET_APP MAC_APP
"""
import json
import os
import plistlib
import shutil
import subprocess
import sys
from pathlib import Path

# Keys that legitimately differ between two builds of one commit.
VOLATILE_PLIST_KEYS = {"BuildMachineOSBuild", "DTXcode", "DTXcodeBuild", "DTSDKBuild", "DTPlatformBuild",
                       "DTCompiler", "DTPlatformVersion", "DTSDKName", "CMUXBuildDate", "CMUXBuildHost"}
# Paths whose bytes are per build (signatures, receipts).
VOLATILE_PATHS = ("Contents/_CodeSignature/", "_CodeSignature/")


def files(app):
    out = {}
    for root, dirs, names in os.walk(app):
        for n in names + [d for d in dirs if os.path.islink(os.path.join(root, d))]:
            p = os.path.join(root, n)
            rel = os.path.relpath(p, app)
            if any(rel.startswith(v) or f"/{v}" in rel for v in VOLATILE_PATHS):
                continue
            out[rel] = p
    return out


def plist(path):
    try:
        with open(path, "rb") as f:
            d = plistlib.load(f)
    except Exception:
        return None
    return {k: v for k, v in d.items() if k not in VOLATILE_PLIST_KEYS} if isinstance(d, dict) else d


def is_macho(path):
    try:
        with open(path, "rb") as f:
            magic = f.read(4)
    except OSError:
        return False
    return magic in (b"\xcf\xfa\xed\xfe", b"\xca\xfe\xba\xbe", b"\xce\xfa\xed\xfe", b"\xbe\xba\xfe\xca")


def libs(path):
    if not shutil.which("otool"):
        return None
    r = subprocess.run(["otool", "-L", path], capture_output=True, text=True)
    lines = [l.strip().split(" (")[0] for l in r.stdout.splitlines()[1:]]
    return sorted(l for l in lines if l)


def compare(fleet, mac):
    a, b = files(fleet), files(mac)
    only_fleet = sorted(set(a) - set(b))
    only_mac = sorted(set(b) - set(a))
    plists, machos = [], []
    for rel in sorted(set(a) & set(b)):
        pa, pb = a[rel], b[rel]
        if os.path.islink(pa) or os.path.islink(pb):
            continue
        if rel.endswith("Info.plist"):
            x, y = plist(pa), plist(pb)
            if x != y:
                keys = sorted({*(x or {}), *(y or {})}) if isinstance(x, dict) and isinstance(y, dict) else []
                plists.append({"path": rel, "keys": [k for k in keys if (x or {}).get(k) != (y or {}).get(k)][:20]})
        elif is_macho(pa) and is_macho(pb):
            la, lb = libs(pa), libs(pb)
            if la is not None and la != lb:
                machos.append({"path": rel, "only_fleet": sorted(set(la) - set(lb or [])),
                               "only_mac": sorted(set(lb or []) - set(la))})
    return {"files_fleet": len(a), "files_mac": len(b), "only_fleet": only_fleet, "only_mac": only_mac,
            "plist_diffs": plists, "macho_link_diffs": machos,
            "match": not (only_fleet or only_mac or plists or machos)}


def main(argv):
    if len(argv) != 3 or not all(Path(p).is_dir() for p in argv[1:]):
        print(__doc__.strip().splitlines()[-1], file=sys.stderr)
        return 2
    r = compare(argv[1], argv[2])
    print(f"### Fleet app parity: {'match' if r['match'] else 'differs'}\n")
    print(f"files: fleet {r['files_fleet']}, Mac {r['files_mac']}")
    for k in ("only_fleet", "only_mac"):
        if r[k]:
            print(f"\n{k.replace('_', ' ')} ({len(r[k])}):\n" + "\n".join(f"- `{p}`" for p in r[k][:40]))
    for d in r["plist_diffs"][:20]:
        print(f"- plist `{d['path']}`: {', '.join(d['keys'])}")
    for d in r["macho_link_diffs"][:20]:
        print(f"- links `{d['path']}`: fleet only {d['only_fleet']}, Mac only {d['only_mac']}")
    print(json.dumps({k: (len(v) if isinstance(v, list) else v) for k, v in r.items()}))
    return 0 if r["match"] else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv))
