#!/usr/bin/env python3
"""Check a signed cmux NEXT DEV app with codesign -d, on a Mac and without secrets.

  scripts/ci/verify_signed_dev_app.py <app> <app-entitlements>

cmux-next-dev-daily.yml signs on Linux (scripts/ci/rcodesign-sign-bundle-dev.sh),
where codesign cannot run, so its verify job makes the checks
scripts/sign-cmux-bundle.sh (feat-cmux-next's, the DEV app's source) makes
after signing: the app carries every entitlement the file asks for, the
personal-information ones enabled, and no NetworkExtension entitlement or
system extension (cmux-next ships none); the Mach-O helpers in Resources/bin
and libexec and the nested Computer Use app carry no application-identifier;
bin/cmux-tui and bin/acpmux stay links to cmux. It also checks that each of
them is Developer ID signed with the hardened runtime. Runs no code from the app.
CODESIGN names the codesign to run (default /usr/bin/codesign; the tests set a fake).
"""

from __future__ import annotations

import os
import plistlib
import re
import subprocess
import sys
from pathlib import Path

PERSONAL_INFORMATION = ("addressbook", "calendars", "location", "photos-library")
# Thin 32/64-bit Mach-O in either byte order. Universal (fat) files start with
# cafebabe (or bebafeca, fat64 cafebabf), which is also a Java class file's
# magic: a fat header is told apart by its architecture count, a big-endian
# uint32 that is small (a few arches), where a class file has its minor and
# major version there (major >= 45, so the count would be >= 45).
THIN_MAGIC = {bytes.fromhex(m) for m in ("feedface", "feedfacf", "cefaedfe", "cffaedfe")}
FAT_MAGIC = {bytes.fromhex(m) for m in ("cafebabe", "cafebabf", "bebafeca", "bfbafeca")}
MAX_FAT_ARCHES = 20


def codesign(*args: str) -> subprocess.CompletedProcess:
    return subprocess.run([os.environ.get("CODESIGN", "/usr/bin/codesign"), *args], capture_output=True)


def entitlements(path: Path) -> dict:
    result = codesign("-d", "--entitlements", ":-", str(path))
    if result.returncode:
        sys.exit(f"error: unable to read the signed entitlements of {path}")
    return plistlib.loads(result.stdout) if result.stdout.strip() else {}


def macho(path: Path) -> bool:
    if path.is_symlink() or not path.is_file() or not os.access(path, os.X_OK):
        return False
    with path.open("rb") as handle:
        head = handle.read(8)
    if head[:4] in THIN_MAGIC:
        return True
    if head[:4] in FAT_MAGIC and len(head) == 8:
        order = "big" if head[:2] == b"\xca\xfe" else "little"
        return 0 < int.from_bytes(head[4:8], order) <= MAX_FAT_ARCHES
    return False


def main(app: Path, wanted_file: str) -> list[str]:
    errors = []
    wanted = plistlib.loads(Path(wanted_file).read_bytes())
    signed = entitlements(app)
    for key, value in wanted.items():
        if signed.get(key) != value:
            errors.append(f"signed app has {key} = {signed.get(key)!r}; {wanted_file} asks for {value!r}")
    for kind in PERSONAL_INFORMATION:
        if signed.get(f"com.apple.security.personal-information.{kind}") is not True:
            errors.append(f"signed app missing enabled com.apple.security.personal-information.{kind}")
    if any("com.apple.developer.networking.networkextension" in key for key in signed):
        errors.append("signed app carries a NetworkExtension entitlement; cmux-next ships no Cloud tunnel system extension")
    if (app / "Contents/Library/SystemExtensions").exists():
        errors.append("Contents/Library/SystemExtensions exists; cmux-next ships no system extension")
    for alias in ("cmux-tui", "acpmux"):
        path = app / "Contents/Resources/bin" / alias
        if (path.exists() or path.is_symlink()) and not (path.is_symlink() and os.readlink(path) == "cmux"):
            errors.append(f"bin/{alias} is not a symlink to cmux")

    nested = [p for d in ("bin", "libexec") for p in sorted((app / "Contents/Resources" / d).glob("*")) if macho(p)]
    computer_use = app / "Contents/Library/cmux Computer Use.app"
    if computer_use.is_dir():
        nested.append(computer_use)
        if codesign("--verify", "--strict", "--verbose=2", str(computer_use)).returncode:
            errors.append("the nested Computer Use app fails codesign --verify --strict")
    for code in (app, *nested):
        shown = codesign("-d", "--verbose=4", str(code))
        if shown.returncode:
            errors.append(f"codesign -d failed on {code.name} (exit {shown.returncode})")
            continue
        details = shown.stderr.decode(errors="replace")
        if not re.search(r"flags=0x[0-9a-f]+\([^)]*runtime", details):
            errors.append(f"{code.name} is not signed with the hardened runtime")
        if "Authority=Developer ID Application:" not in details:
            errors.append(f"{code.name} is not Developer ID signed")
        if code != app and any("application-identifier" in key for key in entitlements(code)):
            errors.append(f"{code.name} unexpectedly carries application-identifier")
    return errors


if __name__ == "__main__":
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    problems = main(Path(sys.argv[1]), sys.argv[2])
    for problem in problems:
        print(f"error: {problem}", file=sys.stderr)
    if problems:
        sys.exit(1)
    print(f"==> signature checks OK: {sys.argv[1]}")
