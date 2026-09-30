#!/usr/bin/env python3
"""Audit the signed app and every embedded Mach-O slice before distribution."""

import plistlib
import re
import subprocess
import sys
from pathlib import Path

RELAXATIONS = {
    "com.apple.security.cs.disable-library-validation",
    "com.apple.security.cs.allow-unsigned-executable-memory",
    "com.apple.security.cs.allow-jit",
}
MACHO_MAGIC = {
    bytes.fromhex(value)
    for value in ("feedface", "cefaedfe", "feedfacf", "cffaedfe",
                  "cafebabe", "bebafeca", "cafebabf", "bfbafeca")
}


def audit(app):
    subprocess.run(["/usr/bin/codesign", "--verify", "--deep", "--strict", str(app)], check=True)
    info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
    main = (app / "Contents/MacOS" / info["CFBundleExecutable"]).resolve()
    inspected = set()
    count = 0
    for path in sorted(app.rglob("*")):
        if path.is_symlink() or not path.is_file():
            continue
        with path.open("rb") as handle:
            if handle.read(4) not in MACHO_MAGIC:
                continue
        inspected.add(path.resolve())
        architectures = subprocess.check_output(["/usr/bin/lipo", "-archs", str(path)], text=True).split()
        if not architectures:
            raise ValueError(f"no architectures in {path}")
        for architecture in architectures:
            result = subprocess.run([
                "/usr/bin/codesign", "--display", "--verbose=4", "--arch", architecture,
                "--entitlements", ":-", "--xml", str(path),
            ], check=True, capture_output=True)
            entitlements = plistlib.loads(result.stdout) if result.stdout.strip() else {}
            if not isinstance(entitlements, dict):
                raise ValueError(f"invalid signed entitlements: {path} ({architecture})")
            forbidden = RELAXATIONS.intersection(entitlements)
            relative = path.relative_to(app).as_posix()
            requires_runtime = path.resolve() == main or relative.startswith((
                "Contents/Resources/bin/", "Contents/Resources/libexec/",
                "Contents/Library/cmux Computer Use.app/Contents/MacOS/",
            ))
            if requires_runtime and not re.search(rb"flags=0x[0-9a-f]+\([^\n]*\bruntime\b", result.stderr):
                raise ValueError(f"missing hardened runtime: {path} ({architecture})")
            if path.resolve() == main:
                if entitlements.get("com.apple.security.cs.allow-jit") is not True:
                    raise ValueError(f"missing JavaScriptCore JIT entitlement: {path} ({architecture})")
                forbidden.discard("com.apple.security.cs.allow-jit")
            if forbidden:
                raise ValueError(f"unsupported runtime relaxations in {path} ({architecture}): "
                                 + ", ".join(sorted(forbidden)))
            count += 1
    if main not in inspected:
        raise ValueError(f"main executable was not audited: {main}")
    return count


if __name__ == "__main__":
    if len(sys.argv) != 2:
        sys.exit(f"usage: {sys.argv[0]} <signed-app>")
    try:
        count = audit(Path(sys.argv[1]))
    except (OSError, ValueError, KeyError, subprocess.CalledProcessError) as error:
        sys.exit(f"error: hardened-runtime audit failed: {error}")
    print(f"Hardened-runtime audit passed: {count} signed Mach-O slices")
