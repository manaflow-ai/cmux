#!/usr/bin/env bash
# Stages the pinned full uBlock Origin (Manifest V2, GPL-3.0) for cmux-next's
# built-in copy and prints the staged directory.
#
#   scripts/cmux-next/fetch-ublock.sh [--print-path]
#
# Source: gorhill's GitHub release ZIP, checked against the pinned SHA-256.
# The Web Store public key is written into the manifest, so the copy keeps the
# Web Store id (cjpalhdlnbpafiamejdnhcphjbkeiagm): a profile imported from
# Chrome and the built-in copy are the same extension, and its settings and
# disabled state survive version changes. The staged folder also carries the
# license, a source receipt (.cmux-extension-source.json) and SOURCE.txt with
# the corresponding-source link (GPL-3.0 section 6).
#
# Cache: ${CMUX_UBLOCK_CACHE:-~/Library/Caches/cmux-next/ublock}/<version>.
# A cached copy is reused only when its receipt matches the pins. No build
# tool runs here; it only downloads, checks and unpacks.
set -euo pipefail

UBLOCK_VERSION="1.75.0"
UBLOCK_ID="cjpalhdlnbpafiamejdnhcphjbkeiagm"
UBLOCK_ZIP_URL="https://github.com/gorhill/uBlock/releases/download/${UBLOCK_VERSION}/uBlock0_${UBLOCK_VERSION}.chromium.zip"
UBLOCK_ZIP_SHA256="393cf95709d1074d4022970e9014e434395c53a822387f1e25f43be97cf4b582"
UBLOCK_SOURCE_URL="https://github.com/gorhill/uBlock/archive/refs/tags/${UBLOCK_VERSION}.tar.gz"
# SHA-256 of the staged manifest.json (with the key). CEFBuiltInExtensions
# .adBlockerManifestSHA256 pins the same value: the agent extension guard
# trusts only a built-in copy whose manifest matches it.
UBLOCK_MANIFEST_SHA256="8736fdbd889f05a37c62b98da88ad3e9e2ae72a067f0909e18bc051792ab161d"
UBLOCK_SOURCE_SHA256="a518c7d6e6b3f81d1a738befeb617abba59f93bd6b1e626da079a1003e9db52b"
# The Web Store listing's public key (same value cmux-browser pins).
UBLOCK_PUBLIC_KEY_BASE64="MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEAmJNzUNVjS6Q1qe0NRqpmfX/oSJdgauSZNdfeb5RV1Hji21vX0TivpP5gq0fadwmvmVCtUpOaNUopgejiUFm/iKHPs0o3x7hyKk/eX0t2QT3OZGdXkPiYpTEC0f0p86SQaLoA2eHaOG4uCGi7sxLJmAXc6IsxGKVklh7cCoLUgWEMnj8ZNG2Y8UKG3gBdrpES5hk7QyFDMraO79NmSlWRNgoJHX6XRoY66oYThFQad8KL8q3pf3Oe8uBLKywohU0ZrDPViWHIszXoE9HEvPTFAbHZ1umINni4W/YVs+fhqHtzRJcaKJtsTaYy+cholu5mAYeTZqtHf6bcwJ8t9i2afwIDAQAB"

cache_root="${CMUX_UBLOCK_CACHE:-$HOME/Library/Caches/cmux-next/ublock}"
target="$cache_root/$UBLOCK_VERSION"

stage() {
  /usr/bin/python3 -I - "$@" <<'PY'
import base64, hashlib, json, os, shutil, stat, sys, tempfile, urllib.request, zipfile
from pathlib import Path, PurePosixPath

(target, version, ext_id, zip_url, zip_sha, source_url, key_b64, source_sha, manifest_sha) = sys.argv[1:10]
target = Path(target)

def ext_id_for(key: bytes) -> str:
    d = hashlib.sha256(key).digest()[:16]
    return "".join(chr(97 + (b >> 4)) + chr(97 + (b & 15)) for b in d)

def receipt_ok(root: Path) -> bool:
    try:
        r = json.loads((root / ".cmux-extension-source.json").read_text())
        m = json.loads((root / "manifest.json").read_text())
    except (OSError, ValueError):
        return False
    if hashlib.sha256((root / "manifest.json").read_bytes()).hexdigest() != manifest_sha:
        return False
    return (r.get("zip_sha256") == zip_sha and r.get("version") == version and m.get("version") == version
            and m.get("manifest_version") == 2 and ext_id_for(base64.b64decode(m.get("key", ""))) == ext_id)

if receipt_ok(target):
    print(target)
    sys.exit(0)

key = base64.b64decode(key_b64, validate=True)
if ext_id_for(key) != ext_id:
    sys.exit(f"pinned public key gives {ext_id_for(key)}, not {ext_id}")

work = Path(tempfile.mkdtemp(prefix="cmux-ublock-", dir=target.parent if target.parent.exists() else None))
try:
    zip_path = work / "ublock.zip"
    with urllib.request.urlopen(zip_url, timeout=120) as response, zip_path.open("wb") as out:
        shutil.copyfileobj(response, out)
    actual = hashlib.sha256(zip_path.read_bytes()).hexdigest()
    if actual != zip_sha:
        sys.exit(f"uBlock Origin ZIP sha256 {actual} != pinned {zip_sha}")
    unpacked = work / "unpacked"
    unpacked.mkdir()
    with zipfile.ZipFile(zip_path) as archive:
        for info in archive.infolist():
            name = PurePosixPath(info.filename)
            if name.is_absolute() or any(p in ("", ".", "..") for p in name.parts) or "\\" in info.filename:
                sys.exit(f"unsafe member {info.filename!r}")
            kind = stat.S_IFMT((info.external_attr >> 16) & 0o177777)
            if kind not in (0, stat.S_IFREG, stat.S_IFDIR):
                sys.exit(f"non-regular member {info.filename!r}")
        archive.extractall(unpacked)
    roots = [p for p in unpacked.iterdir()]
    root = unpacked if (unpacked / "manifest.json").is_file() else (roots[0] if len(roots) == 1 else None)
    if root is None or not (root / "manifest.json").is_file():
        sys.exit("no manifest.json in the release ZIP")
    manifest = json.loads((root / "manifest.json").read_text())
    if manifest.get("name") != "uBlock Origin" or manifest.get("version") != version or manifest.get("manifest_version") != 2:
        sys.exit(f"unexpected manifest: {manifest.get('name')} {manifest.get('version')} mv{manifest.get('manifest_version')}")
    manifest["key"] = key_b64
    (root / "manifest.json").write_text(json.dumps(manifest, indent=2, ensure_ascii=False) + "\n")
    (root / ".cmux-extension-source.json").write_text(json.dumps({
        "name": "uBlock Origin", "version": version, "id": ext_id, "license": "GPL-3.0-or-later",
        "zip_url": zip_url, "zip_sha256": zip_sha, "source_url": source_url, "source_sha256": source_sha,
        "manifest_key": "Chrome Web Store public key (stable id)"}, indent=2) + "\n")
    (root / "SOURCE.txt").write_text(
        f"uBlock Origin {version} (https://github.com/gorhill/uBlock), GPL-3.0.\n"
        f"Corresponding source: {source_url} (sha256 {source_sha})\n"
        f"Unmodified release build: {zip_url} (sha256 {zip_sha}).\n"
        "cmux changes: the manifest's \"key\" field only (keeps the Chrome Web Store extension id).\n"
        "Bundled libraries (lib/) and filter lists (assets/) keep their own licenses: see the\n"
        "LICENSE files beside them and the source tree above (EasyList and EasyPrivacy are\n"
        "dual-licensed GPL-3.0 / CC BY-SA 3.0; Peter Lowe's list and the URLhaus filter carry\n"
        "their own terms in assets/thirdparties/).\n")
    if not (root / "LICENSE.txt").exists():
        sys.exit("the release ZIP carries no LICENSE.txt")
    # Concurrent builds share this cache: a staged copy moves in with one
    # rename; a valid copy another build put there first wins.
    target.parent.mkdir(parents=True, exist_ok=True)
    if receipt_ok(target):
        print(target)
        sys.exit(0)
    if target.exists():
        os.replace(target, work / "old")
    os.replace(root, target)
finally:
    shutil.rmtree(work, ignore_errors=True)
if not receipt_ok(target):
    sys.exit("staged copy failed its own receipt check")
print(target)
PY
}

mkdir -p "$cache_root"
stage "$target" "$UBLOCK_VERSION" "$UBLOCK_ID" "$UBLOCK_ZIP_URL" "$UBLOCK_ZIP_SHA256" "$UBLOCK_SOURCE_URL" "$UBLOCK_PUBLIC_KEY_BASE64" "$UBLOCK_SOURCE_SHA256" "$UBLOCK_MANIFEST_SHA256"
