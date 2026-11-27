#!/usr/bin/env python3
"""Check a one-item nightly-next appcast against its DMG and the pinned key.

    verify_appcast_item.py APPCAST DMG PUBLIC_KEY BUILD

PUBLIC_KEY is the base64 Ed25519 key cmux NEXT pins (SUPublicEDKey,
NIGHTLY_NEXT_SPARKLE_PUBLIC_KEY), so this needs no secret. Fails unless the
appcast has one item for BUILD whose enclosure names the DMG, whose length is
the DMG's size, and whose sparkle:edSignature verifies over the DMG's bytes
with that key, as Sparkle does before it installs an update.

The Ed25519 check is RFC 8032's, in Python, so it needs no OpenSSL 3 (macOS
ships LibreSSL, which cannot verify Ed25519 over a file).
"""

from __future__ import annotations

import base64
import hashlib
import os
import sys
import xml.etree.ElementTree as ET

SPARKLE = "{http://www.andymatuschak.org/xml-namespaces/sparkle}"


# RFC 8032 section 5.1: edwards25519.
P = 2**255 - 19
L = 2**252 + 27742317777372353535851937790883648493
D = -121665 * pow(121666, P - 2, P) % P
SQRT_M1 = pow(2, (P - 1) // 4, P)


def _add(a, b):
    x1, y1, z1, t1 = a
    x2, y2, z2, t2 = b
    aa, bb = (y1 - x1) * (y2 - x2) % P, (y1 + x1) * (y2 + x2) % P
    cc, dd = 2 * t1 * t2 * D % P, 2 * z1 * z2 % P
    e, f, g, h = bb - aa, dd - cc, dd + cc, bb + aa
    return e * f % P, g * h % P, f * g % P, e * h % P


def _mul(k: int, point):
    result = (0, 1, 1, 0)
    while k:
        if k & 1:
            result = _add(result, point)
        point = _add(point, point)
        k >>= 1
    return result


def _equal(a, b) -> bool:
    return (a[0] * b[2] - b[0] * a[2]) % P == 0 and (a[1] * b[2] - b[1] * a[2]) % P == 0


def _decode(raw: bytes):
    y = int.from_bytes(raw, "little")
    sign, y = y >> 255, y & ((1 << 255) - 1)
    if y >= P:
        return None
    u, v = (y * y - 1) % P, (D * y * y + 1) % P
    x = u * pow(v, 3, P) * pow(u * pow(v, 7, P), (P - 5) // 8, P) % P
    if (v * x * x - u) % P:
        x = x * SQRT_M1 % P
        if (v * x * x - u) % P:
            return None
    if x == 0 and sign:
        return None
    if x & 1 != sign:
        x = P - x
    return x, y, 1, x * y % P


BASE = _decode((4 * pow(5, P - 2, P) % P).to_bytes(32, "little"))


def ed25519_verify(public: bytes, signature: bytes, path: str) -> bool:
    """Verify an Ed25519 signature over the file at PATH (read in chunks)."""
    point, r = _decode(public), _decode(signature[:32])
    s = int.from_bytes(signature[32:], "little")
    if point is None or r is None or s >= L:
        return False
    digest = hashlib.sha512(signature[:32] + public)
    with open(path, "rb") as handle:
        for chunk in iter(lambda: handle.read(1 << 20), b""):
            digest.update(chunk)
    k = int.from_bytes(digest.digest(), "little") % L
    return _equal(_mul(s, BASE), _add(r, _mul(k, point)))


def fail(message: str) -> None:
    sys.exit(f"error: {message}")


def main(argv: list[str]) -> int:
    if len(argv) != 4:
        sys.exit(__doc__)
    appcast, dmg, public_b64, build = argv
    items = ET.parse(appcast).getroot().findall("channel/item")
    if len(items) != 1:
        fail(f"{appcast} has {len(items)} items, not 1")
    item = items[0]
    if item.findtext(f"{SPARKLE}version") != build:
        fail(f"the item is build {item.findtext(f'{SPARKLE}version')}, not {build}")
    enclosure = item.find("enclosure")
    if enclosure is None:
        fail("the item has no enclosure")
    url, length, signature = enclosure.get("url", ""), enclosure.get("length", ""), enclosure.get(f"{SPARKLE}edSignature", "")
    if url.rsplit("/", 1)[-1] != os.path.basename(dmg):
        fail(f"the enclosure url {url} does not name {os.path.basename(dmg)}")
    if length != str(os.path.getsize(dmg)):
        fail(f"the enclosure length {length} is not the DMG's size {os.path.getsize(dmg)}")
    try:
        public = base64.b64decode(public_b64, validate=True)
        raw_signature = base64.b64decode(signature, validate=True)
    except ValueError:
        fail("the public key or the edSignature is not base64")
    if len(public) != 32 or len(raw_signature) != 64:
        fail("the public key or the edSignature has the wrong length for Ed25519")
    if not ed25519_verify(public, raw_signature, dmg):
        fail(f"the edSignature does not verify over {os.path.basename(dmg)} with {public_b64}")
    print(f"Sparkle EdDSA signature verified with the pinned key: {os.path.basename(dmg)}, {length} bytes, build {build}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
