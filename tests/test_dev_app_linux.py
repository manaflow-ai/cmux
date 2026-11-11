#!/usr/bin/env python3
"""scripts/ci/dev_app_linux.py: the Linux sign job's ditto, PlistBuddy and
Sparkle key stand-ins (cmux-next-dev-daily.yml)."""

from __future__ import annotations

import base64
import hashlib
import os
import plistlib
import stat
import subprocess
import sys
import tempfile
import warnings
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts/ci/dev_app_linux.py"
failures = []
warnings.filterwarnings("ignore", "Duplicate name")  # the "shadow" archive repeats a name on purpose


def run(*args, env=None):
    return subprocess.run([sys.executable, str(SCRIPT), *map(str, args)], capture_output=True, text=True,
                          env={**os.environ, **(env or {})})


def tree(root: Path):
    def body(p: Path):
        if p.is_symlink():
            return "-> " + os.readlink(p)
        return hashlib.sha256(p.read_bytes()).hexdigest() if p.is_file() else ""
    return sorted((str(p.relative_to(root)), oct(p.lstat().st_mode), body(p)) for p in root.rglob("*"))


def link_zip(path: Path, *entries):
    """(name, str) is a symlink to str; (name, bytes) is a regular file holding bytes."""
    with zipfile.ZipFile(path, "w") as zf:
        for name, target in entries:
            info = zipfile.ZipInfo(name)
            kind = stat.S_IFLNK | 0o755 if isinstance(target, str) else stat.S_IFREG | 0o644
            info.create_system, info.external_attr = 3, kind << 16
            zf.writestr(info, target)


with tempfile.TemporaryDirectory() as tmp:
    t = Path(tmp)
    fw = t / "a/X.app/Contents/Frameworks/F.framework"
    (fw / "Versions/A/Resources").mkdir(parents=True)
    (fw / "Versions/A/F").write_text("bin")
    (fw / "Versions/A/F").chmod(0o755)
    (fw / "Versions/Current").symlink_to("A")
    (fw / "F").symlink_to("Versions/Current/F")
    (fw / "Resources").symlink_to("Versions/Current/Resources")
    (fw / "Versions/A/Resources/data.bin").write_bytes(bytes(range(256)) * 9)
    (t / "a/X.app/Contents/._Lonely").write_text("no sibling")  # a ._ file with no NAME beside it is kept
    plist = t / "a/X.app/Contents/Info.plist"
    plistlib.dump({"CFBundleIdentifier": "com.x", "CFBundleName": "X", "CFBundleVersion": "108",
                   "CFBundleShortVersionString": "0.1.2-dev.3", "SUFeedURL": "old"}, plist.open("wb"),
                  fmt=plistlib.FMT_BINARY)
    run("zip", t / "a/X.app", t / "x.zip")
    with zipfile.ZipFile(t / "x.zip", "a") as zf:  # what ditto stores for extended attributes
        zf.writestr("X.app/Contents/._Info.plist", "attrs")
        zf.writestr("__MACOSX/X.app/._Contents", "attrs")
    check = run("unzip", t / "x.zip", t / "b")
    failures += [] if check.returncode == 0 and tree(t / "a") == tree(t / "b") else [
        f"zip then unzip must keep links, modes and file bytes and drop AppleDouble data: {check.stderr}"]
    if (t / "b/X.app/Contents/Frameworks/F.framework/Versions/A/Resources/data.bin").read_bytes() != bytes(range(256)) * 9:
        failures.append("unzip must write each regular file's bytes")

    outside = t / "outside"
    outside.mkdir()
    for name, entries in {"escape": [("X.app/e", "../../etc")], "absolute": [("X.app/e", "/etc")],
                          "chain": [("X.app/s", "."), ("X.app/e", "s/s/s/../../..")],
                          "chain-out": [("X.app/p", "q"), ("X.app/q", "r"), ("X.app/r", "../../outside")],
                          # a later regular file written through an earlier link
                          "through-up": [("a", "../outside"), ("a/pwned", b"x")],
                          "through-abs": [("a", str(outside)), ("a/pwned", b"x")],
                          "through-in": [("b/keep", b"k"), ("a", "b"), ("a/pwned", b"x")],
                          "shadow": [("l", "x"), ("l", b"x")]}.items():
        link_zip(t / f"{name}.zip", *entries)
        r = run("unzip", t / f"{name}.zip", t / name)
        if r.returncode == 0:
            failures.append(f"unzip must refuse a symlink that leaves the archive or is written through ({name})")
    link_zip(t / "flat.zip", ("X.app/Contents/MacOS/x", b"bin"))  # no directory entries: unzip makes the parents
    if run("unzip", t / "flat.zip", t / "flat").returncode or (t / "flat/X.app/Contents/MacOS/x").read_bytes() != b"bin":
        failures.append("unzip must create the parent directories of a file entry")
    # DEST must be empty: a link already in it (evil -> outside) is never written through.
    (t / "pre").mkdir()
    (t / "pre/evil").symlink_to(outside)
    link_zip(t / "pre.zip", ("evil/pwned", b"x"))
    pre = run("unzip", t / "pre.zip", t / "pre")
    if pre.returncode == 0 or "is not empty" not in pre.stderr:
        failures.append(f"unzip must refuse a non-empty DEST: {pre.stderr}")
    if list(outside.iterdir()):
        failures.append(f"unzip wrote outside DEST: {list(outside.iterdir())}")
    with zipfile.ZipFile(t / "dots.zip", "w") as zf:
        zf.writestr("../x", "a")
    if run("unzip", t / "dots.zip", t / "dots").returncode == 0:
        failures.append("unzip must refuse an entry outside DEST")

    plist = t / "b/X.app/Contents/Info.plist"
    if run("identity", plist, "com.y", "X", "abc").returncode == 0:
        failures.append("identity must refuse another bundle id")
    run("identity", plist, "com.x", "X", "c" * 40)
    run("stamp", plist, "4242", "https://feed", "KEY=")
    stamped = plistlib.loads(plist.read_bytes())
    want = {"CFBundleVersion": "4242", "CFBundleShortVersionString": "0.1.2-tip.4242", "CMUXCommit": "c" * 40,
            "SUFeedURL": "https://feed", "SUPublicEDKey": "KEY="}
    if not plist.read_bytes().startswith(b"bplist00") or any(stamped.get(k) != v for k, v in want.items()):
        failures.append(f"identity and stamp must make the PlistBuddy edits in the plist's format: {stamped}")
    xml = t / "xml.plist"
    xml.write_bytes(plistlib.dumps({"CFBundleIdentifier": "com.x", "CFBundleName": "X", "CFBundleVersion": "1",
                                    "CFBundleShortVersionString": "0.1.2", "CMUXCommit": "old"}))
    edits = [run("identity", xml, "com.x", "X", "d" * 40), run("stamp", xml, "7", "https://f", "K=")]
    got = plistlib.loads(xml.read_bytes())
    if any(e.returncode for e in edits) or not xml.read_bytes().startswith(b"<?xml") or got != {
            "CFBundleIdentifier": "com.x", "CFBundleName": "X", "CFBundleVersion": "7",
            "CFBundleShortVersionString": "0.1.2-tip.7", "CMUXCommit": "d" * 40, "SUFeedURL": "https://f",
            "SUPublicEDKey": "K="}:
        failures.append(f"identity and stamp must keep an XML plist XML: {got}")

# RFC 8032 test 1; the seed may be stored without padding, and the old 96-byte form carries the public key.
seed = bytes.fromhex("9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60")
public = base64.b64encode(bytes.fromhex("d75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a")).decode()
for key in (base64.b64encode(seed).decode().rstrip("="), base64.b64encode(bytes(64) + base64.b64decode(public)).decode()):
    out = run("sparkle-public-key", "SPARKLE_KEY", env={"SPARKLE_KEY": key})
    if out.stdout.strip() != public:
        failures.append(f"sparkle-public-key derived {out.stdout.strip()!r}: {out.stderr}")

if failures:
    print("FAIL: dev_app_linux.py\n  " + "\n  ".join(failures))
    sys.exit(1)
print("PASS: dev_app_linux.py keeps app archives, plist edits and the Sparkle key exact")
