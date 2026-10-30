#!/usr/bin/env python3
"""The full-DMG item of the cmux NEXT DEV tip feed, written on Linux.

    tip_appcast_linux.py ENV_NAME DMG ARCHIVE APP_NAME URL_PREFIX NOTES_URL BUILD OUT

Writes OUT: the appcast Sparkle's generate_appcast writes for DMG alone (no
previous archives, so no deltas), with the same fields and layout. The values
come from the Info.plist inside ARCHIVE (the signed app zip the DMG was built
from; its digest is checked by the caller), the Sparkle EdDSA signature from
the base64 private key in the variable ENV_NAME (a 32-byte seed, or the old
96-byte key: the 64-byte expanded key and then the public key), never argv.

Ed25519 signatures are deterministic, so the signature here is the one
generate_appcast makes for the same key and bytes: tip-deltas regenerates the
item with generate_appcast on a Mac, and tip_feed.py add-deltas refuses it
unless url, length and signature match the item tip published.

Fails unless the app's CFBundleVersion is BUILD and its SUPublicEDKey is the
key's public half (an app that trusts another key would refuse the feed), and
unless openssl verifies the signature with that public key.
"""

from __future__ import annotations

import base64
import datetime
import email.utils
import hashlib
import os
import plistlib
import subprocess
import sys
import tempfile
import zipfile
from xml.sax.saxutils import escape, quoteattr

# RFC 8032 Ed25519, signing only.
P = 2**255 - 19
Q = 2**252 + 27742317777372353535851937790883648493
D = -121665 * pow(121666, P - 2, P) % P
GY = 4 * pow(5, P - 2, P) % P


def _recover_x(y: int) -> int:
    x2 = (y * y - 1) * pow(D * y * y + 1, P - 2, P) % P
    x = pow(x2, (P + 3) // 8, P)
    if (x * x - x2) % P:
        x = x * pow(2, (P - 1) // 4, P) % P
    return P - x if x & 1 else x


G = (_recover_x(GY), GY, 1, _recover_x(GY) * GY % P)


def _add(a: tuple, b: tuple) -> tuple:
    x1, y1, z1, t1 = a
    x2, y2, z2, t2 = b
    aa = (y1 - x1) * (y2 - x2) % P
    bb = (y1 + x1) * (y2 + x2) % P
    cc = 2 * t1 * t2 * D % P
    dd = 2 * z1 * z2 % P
    e, f, g, h = bb - aa, dd - cc, dd + cc, bb + aa
    return (e * f % P, g * h % P, f * g % P, e * h % P)


def _mul(s: int, point: tuple) -> tuple:
    result = (0, 1, 1, 0)
    while s:
        if s & 1:
            result = _add(result, point)
        point = _add(point, point)
        s >>= 1
    return result


def _encode(point: tuple) -> bytes:
    x, y, z, _ = point
    zi = pow(z, P - 2, P)
    x, y = x * zi % P, y * zi % P
    return (y | ((x & 1) << 255)).to_bytes(32, "little")


def _hash_file(prefix: bytes, path: str) -> int:
    digest = hashlib.sha512(prefix)
    with open(path, "rb") as stream:
        for chunk in iter(lambda: stream.read(1 << 20), b""):
            digest.update(chunk)
    return int.from_bytes(digest.digest(), "little") % Q


def expanded_key(raw: bytes) -> tuple[int, bytes]:
    """The secret scalar and the nonce prefix of a Sparkle private key."""
    if len(raw) == 32:
        h = hashlib.sha512(raw).digest()
        scalar = bytearray(h[:32])
        scalar[0] &= 248
        scalar[31] &= 63
        scalar[31] |= 64
        return int.from_bytes(scalar, "little"), h[32:]
    if len(raw) == 96:
        return int.from_bytes(raw[:32], "little"), raw[32:64]
    raise ValueError(f"the Sparkle key has {len(raw)} bytes, not 32 or 96")


def sign_file(raw: bytes, path: str) -> tuple[bytes, bytes]:
    """(signature, public key) of the file's bytes."""
    a, prefix = expanded_key(raw)
    public = _encode(_mul(a, G))
    r = _hash_file(prefix, path)
    big_r = _encode(_mul(r, G))
    k = _hash_file(big_r + public, path)
    s = (r + k * a) % Q
    return big_r + s.to_bytes(32, "little"), public


def openssl_verify(public: bytes, signature: bytes, path: str) -> bool:
    spki = bytes.fromhex("302a300506032b6570032100") + public
    with tempfile.TemporaryDirectory() as tmp:
        key, sig = os.path.join(tmp, "key.der"), os.path.join(tmp, "sig")
        with open(key, "wb") as out:
            out.write(spki)
        with open(sig, "wb") as out:
            out.write(signature)
        done = subprocess.run(["openssl", "pkeyutl", "-verify", "-pubin", "-keyform", "DER", "-inkey", key,
                               "-rawin", "-in", path, "-sigfile", sig], capture_output=True, text=True)
        return done.returncode == 0 and "Success" in done.stdout


def app_plist(archive: str, app_name: str) -> dict:
    name = f"{app_name}.app/Contents/Info.plist"
    with zipfile.ZipFile(archive) as zf:
        return plistlib.loads(zf.read(name))


def appcast(title: str, plist: dict, url: str, length: int, signature: str, notes_url: str, date: str) -> str:
    short = str(plist.get("CFBundleShortVersionString") or plist["CFBundleVersion"])
    lines = [
        '<?xml version="1.0" standalone="yes"?>',
        '<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" version="2.0">',
        "    <channel>",
        f"        <title>{escape(title)}</title>",
        "        <item>",
        f"            <title>{escape(short)}</title>",
        f"            <pubDate>{date}</pubDate>",
        f"            <sparkle:fullReleaseNotesLink>{escape(notes_url)}</sparkle:fullReleaseNotesLink>",
        f"            <sparkle:version>{escape(str(plist['CFBundleVersion']))}</sparkle:version>",
        f"            <sparkle:shortVersionString>{escape(short)}</sparkle:shortVersionString>",
    ]
    if plist.get("LSMinimumSystemVersion"):
        lines.append(f"            <sparkle:minimumSystemVersion>{escape(str(plist['LSMinimumSystemVersion']))}"
                     "</sparkle:minimumSystemVersion>")
    lines += [
        f"            <enclosure url={quoteattr(url)} length=\"{length}\" type=\"application/octet-stream\""
        f" sparkle:edSignature={quoteattr(signature)}/>",
        "        </item>",
        "    </channel>",
        "</rss>",
        "",
    ]
    return "\n".join(lines)


def main(argv: list[str]) -> int:
    if len(argv) != 8:
        sys.exit(__doc__)
    env_name, dmg, archive, app_name, url_prefix, notes_url, build, out = argv
    encoded = os.environ.get(env_name, "").strip()
    if not encoded:
        sys.exit(f"error: {env_name} is empty")
    raw = base64.b64decode(encoded + "=" * (-len(encoded) % 4), validate=True)
    plist = app_plist(archive, app_name)
    if str(plist.get("CFBundleVersion")) != build:
        sys.exit(f"error: the app is build {plist.get('CFBundleVersion')}, not {build}")
    signature, public = sign_file(raw, dmg)
    public_b64 = base64.b64encode(public).decode()
    if len(raw) == 96 and raw[64:] != public:
        sys.exit("error: the 96-byte Sparkle key's public half does not match its private half")
    if plist.get("SUPublicEDKey") != public_b64:
        sys.exit(f"error: the app trusts {plist.get('SUPublicEDKey')}, but the feed would be signed by {public_b64}")
    if not openssl_verify(public, signature, dmg):
        sys.exit("error: openssl does not verify the DMG's EdDSA signature")
    url = url_prefix + os.path.basename(dmg)
    date = email.utils.format_datetime(datetime.datetime.now(datetime.timezone.utc).replace(microsecond=0))
    title = str(plist.get("CFBundleName") or app_name)
    with open(out, "w", encoding="utf-8") as stream:
        stream.write(appcast(title, plist, url, os.path.getsize(dmg), base64.b64encode(signature).decode(),
                             notes_url, date))
    print(f"appcast for build {build}: {url}, {os.path.getsize(dmg)} bytes, key {public_b64}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
