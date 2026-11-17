#!/usr/bin/env python3
"""Linux stand-ins for the macOS tools cmux-next-dev-daily.yml's sign job used.

  dev_app_linux.py unzip ARCHIVE DEST     ditto -x -k
  dev_app_linux.py zip APP ARCHIVE        ditto -c -k --keepParent
  dev_app_linux.py identity PLIST BUNDLE_ID NAME COMMIT
  dev_app_linux.py stamp PLIST BUILD FEED_URL PUBLIC_KEY
  dev_app_linux.py sparkle-public-key ENV_NAME

A zip entry keeps its Unix mode in the high 16 bits of external_attr, and a
symlink is an entry with S_IFLNK whose data is the link target. ditto writes
and reads both, so framework links (Versions/Current, the top-level links) and
exec bits survive this round trip; the verify job's codesign --verify --deep
--strict on a ditto unpack fails when they do not. unzip creates every link
after every file and directory, so no entry is written through a link, and it
refuses a link that resolves (realpath, through other links) outside DEST. AppleDouble data ditto stores beside a
file (._NAME, __MACOSX/) holds extended attributes: ditto -x folds it back into
attributes, so it is dropped here instead of becoming a bundle file.

identity and stamp make the PlistBuddy edits (Delete then Add, Set on an entry
that must exist) and keep the plist's format. sparkle-public-key derives the
Ed25519 public key of the base64 Sparkle private key in the named variable
(a 32-byte seed, or the old 96-byte key whose last 32 bytes are the public key)
like derive_sparkle_public_key.swift; the key goes to openssl on stdin.
"""

from __future__ import annotations

import base64
import os
import plistlib
import stat
import subprocess
import sys
import zipfile
from pathlib import PurePosixPath


def fail(message: str) -> None:
    sys.exit(f"error: {message}")


def unzip(archive: str, dest: str) -> None:
    # A fresh destination: nothing in it can be a link an entry is written through.
    os.makedirs(dest, exist_ok=True)
    if os.listdir(dest):
        fail(f"{dest} is not empty")
    root = os.path.realpath(dest)

    def inside(path: str) -> bool:
        return os.path.realpath(path).startswith(root + os.sep)

    def safe_parent(target: str) -> None:
        # Every existing directory between root and target is a real directory inside root (no link),
        # so a file or directory is never created through a link, whatever made it.
        parent = os.path.dirname(target)
        os.makedirs(parent, exist_ok=True)
        rel = os.path.relpath(parent, root)
        cur = root
        for part in ([] if rel == "." else rel.split(os.sep)):
            cur = os.path.join(cur, part)
            if os.path.islink(cur) or not os.path.isdir(cur):
                fail(f"archive entry {target} would be written through {cur}")
        if not inside(target) and os.path.realpath(parent) != root:
            fail(f"archive entry {target} leaves the archive")

    links, dirs = [], []
    with zipfile.ZipFile(archive, metadata_encoding="utf-8") as zf:
        names = {info.filename.rstrip("/") for info in zf.infolist()}
        for info in zf.infolist():
            path = PurePosixPath(info.filename)
            if path.is_absolute() or ".." in path.parts or "\\" in info.filename:
                fail(f"unsafe archive entry {info.filename!r}")
            if path.parts[0] == "__MACOSX" or (path.name.startswith("._") and str(path.with_name(path.name[2:])) in names):
                continue
            target = os.path.join(root, *path.parts)
            mode = info.external_attr >> 16
            if stat.S_ISLNK(mode):
                links.append((target, zf.read(info).decode()))
            elif info.is_dir():
                safe_parent(target)
                if os.path.islink(target):
                    fail(f"archive entry {target} would be written through a link")
                os.makedirs(target, exist_ok=True)
                dirs.append((target, stat.S_IMODE(mode) or 0o755))
            else:
                safe_parent(target)
                fd = os.open(target, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
                with zf.open(info) as src, os.fdopen(fd, "wb") as out:
                    while chunk := src.read(1 << 20):
                        out.write(chunk)
                os.chmod(target, (stat.S_IMODE(mode) & 0o777) or 0o644)
    for target, link in links:
        if os.path.isabs(link):
            fail(f"symlink {target} -> {link} leaves the archive")
        safe_parent(target)
        if os.path.lexists(target):
            fail(f"symlink {target} would replace another archive entry")
        os.symlink(link, target)
        if not inside(target):
            fail(f"symlink {target} -> {link} leaves the archive")
    # Again once all exist: a later link can change where an earlier one points.
    for target, link in links:
        if not inside(target):
            fail(f"symlink {target} -> {link} leaves the archive")
    for target, mode in sorted(dirs, reverse=True):
        os.chmod(target, mode & 0o777)


def zip_app(app: str, archive: str) -> None:
    app = os.path.abspath(app.rstrip("/"))
    parent = os.path.dirname(app)
    with zipfile.ZipFile(archive, "w", zipfile.ZIP_DEFLATED, strict_timestamps=False) as zf:
        zf.write(app, os.path.relpath(app, parent))
        for top, subdirs, files in os.walk(app):
            subdirs.sort()
            for name in subdirs + sorted(files):
                path = os.path.join(top, name)
                arcname = os.path.relpath(path, parent)
                st = os.lstat(path)
                if stat.S_ISLNK(st.st_mode):
                    info = zipfile.ZipInfo(arcname, (1980, 1, 1, 0, 0, 0))
                    info.create_system = 3
                    info.external_attr = st.st_mode << 16
                    zf.writestr(info, os.readlink(path), zipfile.ZIP_STORED)
                elif stat.S_ISDIR(st.st_mode) or stat.S_ISREG(st.st_mode):
                    zf.write(path, arcname)
                else:
                    fail(f"{path} is not a file, directory or symlink")


def edit_plist(path: str, edit) -> None:
    with open(path, "rb") as handle:
        data = handle.read()
    fmt = plistlib.FMT_BINARY if data.startswith(b"bplist00") else plistlib.FMT_XML
    plist = plistlib.loads(data)
    edit(plist)
    with open(path, "wb") as handle:
        plistlib.dump(plist, handle, fmt=fmt, sort_keys=False)


def identity(path: str, bundle_id: str, name: str, commit: str) -> None:
    def edit(plist: dict) -> None:
        if plist.get("CFBundleIdentifier") != bundle_id:
            fail(f"unexpected bundle id: {plist.get('CFBundleIdentifier')}")
        if plist.get("CFBundleName") != name:
            fail(f"unexpected app name: {plist.get('CFBundleName')}")
        plist.pop("CMUXCommit", None)
        plist["CMUXCommit"] = commit
    edit_plist(path, edit)


def stamp(path: str, build: str, feed: str, key: str) -> None:
    def edit(plist: dict) -> None:
        for entry in ("CFBundleVersion", "CFBundleShortVersionString"):
            if not isinstance(plist.get(entry), str):
                fail(f"{path} has no string {entry}")
        plist["CFBundleVersion"] = build
        plist["CFBundleShortVersionString"] = f"{plist['CFBundleShortVersionString'].split('-', 1)[0]}-tip.{build}"
        for entry, value in (("SUFeedURL", feed), ("SUPublicEDKey", key)):
            plist.pop(entry, None)
            plist[entry] = value
    edit_plist(path, edit)


def sparkle_public_key(env_name: str) -> str:
    encoded = os.environ.get(env_name, "").strip()
    try:
        raw = base64.b64decode(encoded + "=" * (-len(encoded) % 4), validate=True)
    except ValueError:
        fail(f"{env_name} is not base64")
    if len(raw) == 96:
        return base64.b64encode(raw[64:]).decode()
    if len(raw) != 32:
        fail(f"{env_name} has {len(raw)} bytes, not 32 or 96")
    pkcs8 = bytes.fromhex("302e020100300506032b657004220420") + raw
    spki = subprocess.run(["openssl", "pkey", "-inform", "DER", "-pubout", "-outform", "DER"],
                          input=pkcs8, capture_output=True, check=True).stdout
    if len(spki) != 44 or not spki.startswith(bytes.fromhex("302a300506032b6570032100")):
        fail("openssl returned no Ed25519 public key")
    return base64.b64encode(spki[12:]).decode()


COMMANDS = {"unzip": (unzip, 2), "zip": (zip_app, 2), "identity": (identity, 4), "stamp": (stamp, 4),
            "sparkle-public-key": (lambda name: print(sparkle_public_key(name)), 1)}

if __name__ == "__main__":
    if len(sys.argv) < 2 or sys.argv[1] not in COMMANDS or len(sys.argv) - 2 != COMMANDS[sys.argv[1]][1]:
        sys.exit(__doc__)
    COMMANDS[sys.argv[1]][0](*sys.argv[2:])
