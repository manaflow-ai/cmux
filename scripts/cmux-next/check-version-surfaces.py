#!/usr/bin/env python3
"""Body of check-version-surfaces.sh: check-version-surfaces.py <app> <expected version>."""
import os, plistlib, re, subprocess, sys

app, expected = sys.argv[1], sys.argv[2]
bad = []
checked = []

plist_path = os.path.join(app, "Contents", "Info.plist")
try:
    with open(plist_path, "rb") as f:
        short = plistlib.load(f).get("CFBundleShortVersionString")
except (OSError, plistlib.InvalidFileException) as error:
    short = None
    bad.append(f"Contents/Info.plist: unreadable ({error})")
if short is not None:
    base = str(short).split("-", 1)[0]
    if base != expected:
        bad.append(f"Contents/Info.plist CFBundleShortVersionString is {short!r}, want {expected} or {expected}-<channel>.<build>")
    else:
        checked.append(f"CFBundleShortVersionString {short}")

bin_dir = os.path.join(app, "Contents", "Resources", "bin")
# (binary, program name its --version line starts with, required)
surfaces = [
    ("cmux", "cmux", True),
    ("cmux-tui", "cmux", False),
    ("acpmux", "acpmux", False),
    ("cmux-browser-host", "cmux-browser-host", False),
]
for name, program, required in surfaces:
    path = os.path.join(bin_dir, name)
    if not os.access(path, os.X_OK):
        if required:
            bad.append(f"Contents/Resources/bin/{name}: missing")
        continue
    try:
        out = subprocess.run([path, "--version"], stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=20).stdout
    except (OSError, subprocess.TimeoutExpired) as error:
        bad.append(f"Contents/Resources/bin/{name} --version: {error}")
        continue
    line = out.strip().splitlines()[0] if out.strip() else ""
    match = re.match(rf"^{re.escape(program)} (\S+)", line)
    if not match:
        bad.append(f"Contents/Resources/bin/{name} --version printed {line!r}, want '{program} {expected} …'")
    elif match.group(1) != expected:
        bad.append(f"Contents/Resources/bin/{name} --version says {match.group(1)}, want {expected} ({line})")
    else:
        checked.append(f"bin/{name} {match.group(1)}")

if bad:
    print(f"check-version-surfaces: the app's versions disagree with the cmux-next version {expected} (cmux-tui/Cargo.toml [workspace.package]):", file=sys.stderr)
    for line in bad:
        print(f"  {line}", file=sys.stderr)
    sys.exit(1)
print(f"check-version-surfaces: {expected} everywhere ({'; '.join(checked)})")
