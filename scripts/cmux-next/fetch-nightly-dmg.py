#!/usr/bin/env python3
"""Downloads the newest cmux NEXT nightly DMG from its appcast and unpacks the app, on Linux or macOS.

    fetch-nightly-dmg.py OUT_DIR [--feed URL] [--dmg FILE]

Writes OUT_DIR/<dmg name> (the DMG as published, its length checked against the
appcast), OUT_DIR/disk.img (the decoded raw image) and OUT_DIR/volume/ (the
volume, extracted by 7-Zip, which reads APFS), then prints one JSON line:
{"version", "dmg", "dmg_bytes", "app"}. --dmg unpacks a DMG already on disk
instead of downloading one. scripts/cmux-next/bundle-size.py tree measures the
app; cmuxterm-hq docs/perf/bundle-size.md is the attribution it feeds.

The decoder handles the UDIF chunk kinds hdiutil writes (raw, zero, zlib,
bzip2, LZMA); an LZFSE or ADC chunk stops it with the chunk's kind. The DMG is
untrusted input: nothing in it runs, and 7-Zip writes only under OUT_DIR.
"""

from __future__ import annotations

import argparse
import bz2
import json
import lzma
import plistlib
import shutil
import struct
import subprocess
import sys
import urllib.request
import xml.etree.ElementTree as ET
import zlib
from pathlib import Path

DEFAULT_FEED = "https://files-next.cmux.com/nightly-next/appcast-arm64.xml"
SPARKLE = "{http://www.andymatuschak.org/xml-namespaces/sparkle}"


def newest_enclosure(feed: bytes) -> tuple[str, str, int]:
    """(version, url, length) of the feed's newest item: the highest sparkle:version."""
    items = []
    for item in ET.fromstring(feed).iter("item"):
        enc = item.find("enclosure")
        ver = item.findtext(f"{SPARKLE}version") or ""
        if enc is None or not ver.isdigit():
            continue
        items.append((int(ver), enc.get("url", ""), int(enc.get("length", "0"))))
    if not items:
        raise SystemExit("fetch-nightly-dmg: the feed lists no item with a version and an enclosure")
    ver, url, length = max(items)
    return str(ver), url, length


def download(url: str, dest: Path) -> None:
    tmp = dest.with_suffix(dest.suffix + ".partial")
    with urllib.request.urlopen(url, timeout=60) as r, open(tmp, "wb") as f:
        shutil.copyfileobj(r, f, 4 * 1024 * 1024)
    tmp.replace(dest)


def decode_udif(src: Path, dst: Path) -> None:
    """Writes the UDIF image's raw disk to dst (sparse where the image has zero runs)."""
    with open(src, "rb") as f:
        f.seek(-512, 2)
        koly = f.read(512)
        if koly[:4] != b"koly":
            raise SystemExit(f"fetch-nightly-dmg: {src} is not a UDIF image (no koly trailer)")
        data_off = struct.unpack(">Q", koly[24:32])[0]
        xml_off, xml_len = struct.unpack(">QQ", koly[216:232])
        f.seek(xml_off)
        blkx = plistlib.loads(f.read(xml_len))["resource-fork"]["blkx"]
        end = 0
        with open(dst, "wb") as out:
            for blk in blkx:
                m = blk["Data"]
                if m[:4] != b"mish":
                    raise SystemExit("fetch-nightly-dmg: a blkx entry has no mish table")
                first_sector = struct.unpack(">Q", m[8:16])[0]
                base = struct.unpack(">Q", m[24:32])[0]
                count = struct.unpack(">I", m[200:204])[0]
                for i in range(count):
                    kind, _c, sector, sectors, coff, clen = struct.unpack(">IIQQQQ", m[204 + 40 * i: 244 + 40 * i])
                    end = max(end, (first_sector + sector + sectors) * 512)
                    if kind in (0x0, 0x2, 0x7FFFFFFE):  # zero, ignored, comment
                        continue
                    if kind == 0xFFFFFFFF:  # end of table
                        break
                    f.seek(data_off + base + coff)
                    raw = f.read(clen)
                    if kind == 0x1:
                        buf = raw
                    elif kind == 0x80000005:
                        buf = zlib.decompress(raw)
                    elif kind == 0x80000006:
                        buf = bz2.decompress(raw)
                    elif kind == 0x80000008:
                        buf = lzma.decompress(raw)
                    else:
                        raise SystemExit(f"fetch-nightly-dmg: unsupported UDIF chunk kind {kind:#x}")
                    out.seek((first_sector + sector) * 512)
                    out.write(buf)
            out.truncate(end)


def extract(img: Path, dest: Path) -> Path:
    """Extracts the image's volume with 7-Zip and returns the one .app in it."""
    seven = shutil.which("7zz") or shutil.which("7z")
    if not seven:
        raise SystemExit("fetch-nightly-dmg: 7-Zip (7z or 7zz, 20 or newer for APFS) is required")
    if dest.exists():
        shutil.rmtree(dest)
    dest.mkdir(parents=True)
    # Exit 2 is "errors": 7-Zip reports the GPT's unnamed partitions so, after it wrote the volume.
    r = subprocess.run([seven, "x", "-y", f"-o{dest}", str(img)], capture_output=True, text=True)
    apps = sorted(dest.glob("*.app")) + sorted(dest.glob("*/*.app"))
    if not apps:
        raise SystemExit(f"fetch-nightly-dmg: no .app in the volume (7-Zip exit {r.returncode}):\n{r.stdout[-2000:]}{r.stderr[-2000:]}")
    return apps[0]


def main(argv: list[str]) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("out", type=Path)
    ap.add_argument("--feed", default=DEFAULT_FEED)
    ap.add_argument("--dmg", type=Path, help="a DMG already on disk: unpack it, download nothing")
    a = ap.parse_args(argv)
    a.out.mkdir(parents=True, exist_ok=True)
    version = None
    if a.dmg:
        dmg = a.dmg
    else:
        with urllib.request.urlopen(a.feed, timeout=60) as r:
            version, url, length = newest_enclosure(r.read())
        dmg = a.out / url.rsplit("/", 1)[-1]
        if not dmg.exists() or dmg.stat().st_size != length:
            download(url, dmg)
        if dmg.stat().st_size != length:
            raise SystemExit(f"fetch-nightly-dmg: {dmg.name} is {dmg.stat().st_size} bytes, the feed says {length}")
    img = a.out / "disk.img"
    decode_udif(dmg, img)
    app = extract(img, a.out / "volume")
    print(json.dumps({"version": version, "dmg": str(dmg), "dmg_bytes": dmg.stat().st_size, "app": str(app)}))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
