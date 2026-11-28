#!/usr/bin/env python3
"""Every Cargo.toml whose release profile strips keeps proc-macros unstripped.

Xcode 27's `strip -S` leaves proc-macro dylibs that dyld refuses ("mis-aligned LINKEDIT string
pool", rust-lang/rust#157750), so rustc reports E0463 "can't find crate" for a crate it just
built. That broke every app FFI release on feat-cmux-next from 2026-11-27 08:32Z. A
`[profile.release.build-override] strip = false` keeps host units (proc-macros, build scripts)
loadable while shipped artifacts stay stripped.
"""
from __future__ import annotations

import subprocess
import sys
import tomllib
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent


def offenders() -> list[str]:
    files = subprocess.run(
        ["git", "ls-files", "*Cargo.toml"], cwd=ROOT, check=True, capture_output=True, text=True
    ).stdout.split()
    bad = []
    for rel in files:
        path = ROOT / rel
        if not path.is_file():
            continue
        release = tomllib.loads(path.read_text()).get("profile", {}).get("release", {})
        strip = release.get("strip", False)
        if strip in (False, "none"):
            continue
        override = release.get("build-override", {}).get("strip")
        if override not in (False, "none"):
            bad.append(f"{rel}: [profile.release] strip = {strip!r} without "
                       "[profile.release.build-override] strip = false")
    return bad


def main() -> int:
    bad = offenders()
    for line in bad:
        print(line, file=sys.stderr)
    if bad:
        print("add `[profile.release.build-override]\\nstrip = false` (see "
              "cmux-tui/crates/cmux-app-ffi/Cargo.toml)", file=sys.stderr)
        return 1
    print("ok: every stripping release profile keeps proc-macros unstripped")
    return 0


if __name__ == "__main__":
    sys.exit(main())
