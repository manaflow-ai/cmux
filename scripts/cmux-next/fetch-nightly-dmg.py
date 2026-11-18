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
untrusted input: nothing in it runs. Every offset is checked against the file,
a chunk may not inflate past the sectors it claims, the image past
--max-image-bytes (8 GiB) or the download past --max-dmg-bytes (2 GiB). 7-Zip
writes only under OUT_DIR/volume; it must exit 0, or 2 for nothing but the
symbolic links it refused as pointing out of their folder (the nightly's
helper app links the main app's Chromium framework so); a link that resolves
outside the volume is removed (and listed), and the volume must hold exactly
one .app. bundle-size.py counts no link's target, so neither changes a byte.
"""

from __future__ import annotations

import argparse
import bz2
import json
import lzma
import os
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
MAX_DMG_BYTES = 2 << 30
MAX_IMAGE_BYTES = 8 << 30
MAX_PLIST_BYTES = 64 << 20
REFUSED_LINK = "ERROR: Dangerous symbolic link path was ignored : "
# The file server answers 403 to Python's default User-Agent (Python-urllib/3.x); curl's and this get 200.
USER_AGENT = "cmux-fetch-nightly-dmg/1 (scripts/cmux-next/fetch-nightly-dmg.py)"


def get(url: str):
    return urllib.request.urlopen(urllib.request.Request(url, headers={"User-Agent": USER_AGENT}), timeout=60)
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


def download(url: str, dest: Path, limit: int) -> None:
    tmp = dest.with_suffix(dest.suffix + ".partial")
    n = 0
    with get(url) as r, open(tmp, "wb") as f:
        while chunk := r.read(4 * 1024 * 1024):
            n += len(chunk)
            if n > limit:
                raise SystemExit(f"fetch-nightly-dmg: {url} is over {limit} bytes")
            f.write(chunk)
    tmp.replace(dest)


def inflate(kind: int, raw: bytes, limit: int) -> bytes:
    """One chunk, decompressed, refused when it would pass limit bytes."""
    if kind == 0x1:
        buf = raw
    elif kind == 0x80000005:
        d = zlib.decompressobj()
        buf = d.decompress(raw, limit + 1)
    elif kind == 0x80000006:
        d = bz2.BZ2Decompressor()
        buf = d.decompress(raw, limit + 1)
    elif kind == 0x80000008:
        d = lzma.LZMADecompressor()
        buf = d.decompress(raw, limit + 1)
    else:
        raise SystemExit(f"fetch-nightly-dmg: unsupported UDIF chunk kind {kind:#x}")
    if len(buf) > limit:
        raise SystemExit(f"fetch-nightly-dmg: a chunk inflates past the {limit} bytes its sectors hold")
    return buf


def decode_udif(src: Path, dst: Path, max_image: int = MAX_IMAGE_BYTES) -> None:
    """Writes the UDIF image's raw disk to dst (sparse where the image has zero runs)."""
    size = src.stat().st_size

    def bad(why: str) -> SystemExit:
        return SystemExit(f"fetch-nightly-dmg: {src} is not a valid UDIF image: {why}")

    if size < 512:
        raise bad("shorter than its trailer")
    with open(src, "rb") as f:
        f.seek(-512, 2)
        koly = f.read(512)
        if koly[:4] != b"koly":
            raise bad("no koly trailer")
        data_off = struct.unpack(">Q", koly[24:32])[0]
        xml_off, xml_len = struct.unpack(">QQ", koly[216:232])
        if xml_len > MAX_PLIST_BYTES or xml_off + xml_len > size:
            raise bad("its resource list lies outside the file")
        f.seek(xml_off)
        try:
            blkx = plistlib.loads(f.read(xml_len))["resource-fork"]["blkx"]
        except Exception as e:  # noqa: BLE001 - any malformed plist is the same refusal
            raise bad(f"its resource list does not parse ({type(e).__name__})") from None
        end = 0
        with open(dst, "wb") as out:
            for blk in blkx:
                m = blk.get("Data") if isinstance(blk, dict) else None
                if not isinstance(m, bytes) or len(m) < 204 or m[:4] != b"mish":
                    raise bad("a blkx entry has no mish table")
                first_sector = struct.unpack(">Q", m[8:16])[0]
                base = struct.unpack(">Q", m[24:32])[0]
                count = struct.unpack(">I", m[200:204])[0]
                if 204 + 40 * count > len(m):
                    raise bad("a mish table is shorter than its chunk count")
                for i in range(count):
                    kind, _c, sector, sectors, coff, clen = struct.unpack(">IIQQQQ", m[204 + 40 * i: 244 + 40 * i])
                    if kind == 0xFFFFFFFF:  # end of table
                        break
                    start, stop = (first_sector + sector) * 512, (first_sector + sector + sectors) * 512
                    if stop > max_image:
                        raise bad(f"its disk is over {max_image} bytes")
                    end = max(end, stop)
                    if kind in (0x0, 0x2, 0x7FFFFFFE):  # zero, ignored, comment
                        continue
                    if data_off + base + coff + clen > size:
                        raise bad("a chunk lies outside the file")
                    f.seek(data_off + base + coff)
                    buf = inflate(kind, f.read(clen), stop - start)
                    out.seek(start)
                    out.write(buf)
            out.truncate(end)


def refused_links(output: str) -> list[str]:
    """The links 7-Zip reports it refused to write (the link and its target, as 7-Zip prints them)."""
    return [line[len(REFUSED_LINK):] for line in output.splitlines() if line.startswith(REFUSED_LINK)]


def check_volume(dest: Path) -> tuple[Path, list[str]]:
    """The one .app in the extracted volume, and the links removed from it: every link that
    resolves outside the volume (the DMG's /Applications drag target, or a hostile one)."""
    root = Path(os.path.realpath(dest))
    removed = []
    for dirpath, dirs, files in os.walk(dest):
        for name in dirs + files:
            p = Path(dirpath) / name
            if p.is_symlink():
                target = Path(os.path.realpath(p))
                if target != root and root not in target.parents:
                    removed.append(str(p.relative_to(dest)))
                    p.unlink()
    apps = [p for p in sorted(dest.glob("*.app")) + sorted(dest.glob("*/*.app")) if not p.is_symlink()]
    if len(apps) != 1:
        raise SystemExit(f"fetch-nightly-dmg: the volume holds {len(apps)} .app folders, not one: {[str(a) for a in apps]}")
    return apps[0], removed


def extract(img: Path, dest: Path) -> tuple[Path, list[str], list[str]]:
    """Extracts the image's volume with 7-Zip; returns the one .app in it, the links 7-Zip
    refused and the links check_volume removed."""
    seven = shutil.which("7zz") or shutil.which("7z")
    if not seven:
        raise SystemExit("fetch-nightly-dmg: 7-Zip (7z or 7zz, 20 or newer for APFS) is required")
    if dest.exists():
        shutil.rmtree(dest)
    dest.mkdir(parents=True)
    r = subprocess.run([seven, "x", "-y", f"-o{dest}", str(img)], capture_output=True, text=True)
    out = r.stdout + r.stderr
    refused = refused_links(out)
    errors = [line for line in out.splitlines() if line.startswith("ERROR:") and not line.startswith(REFUSED_LINK)]
    # Exit 2 is "errors": accepted only when every error is a refused link (it wrote everything else).
    if r.returncode not in (0, 2) or (r.returncode == 2 and (errors or not refused)):
        raise SystemExit(f"fetch-nightly-dmg: 7-Zip exit {r.returncode}:\n{out[-4000:]}")
    app, removed = check_volume(dest)
    return app, refused, removed


def main(argv: list[str]) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("out", type=Path)
    ap.add_argument("--feed", default=DEFAULT_FEED)
    ap.add_argument("--dmg", type=Path, help="a DMG already on disk: unpack it, download nothing")
    ap.add_argument("--max-dmg-bytes", type=int, default=MAX_DMG_BYTES)
    ap.add_argument("--max-image-bytes", type=int, default=MAX_IMAGE_BYTES)
    a = ap.parse_args(argv)
    a.out.mkdir(parents=True, exist_ok=True)
    version = None
    if a.dmg:
        dmg = a.dmg
    else:
        with get(a.feed) as r:
            version, url, length = newest_enclosure(r.read())
        dmg = a.out / url.rsplit("/", 1)[-1]
        if length > a.max_dmg_bytes:
            raise SystemExit(f"fetch-nightly-dmg: the feed's DMG is {length} bytes, over --max-dmg-bytes")
        if not dmg.exists() or dmg.stat().st_size != length:
            download(url, dmg, a.max_dmg_bytes)
        if dmg.stat().st_size != length:
            raise SystemExit(f"fetch-nightly-dmg: {dmg.name} is {dmg.stat().st_size} bytes, the feed says {length}")
    img = a.out / "disk.img"
    decode_udif(dmg, img, a.max_image_bytes)
    app, refused, removed = extract(img, a.out / "volume")
    print(json.dumps({"version": version, "dmg": str(dmg), "dmg_bytes": dmg.stat().st_size, "app": str(app),
                      "links_not_extracted": refused, "links_out_removed": removed}))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
