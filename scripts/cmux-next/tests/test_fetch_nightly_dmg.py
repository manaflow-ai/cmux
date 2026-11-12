#!/usr/bin/env python3
"""Tests of scripts/cmux-next/fetch-nightly-dmg.py: the appcast pick and the UDIF decoder."""

from __future__ import annotations

import importlib.util
import lzma
import plistlib
import struct
import sys
import tempfile
import zlib
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
spec = importlib.util.spec_from_file_location("fetch_nightly_dmg", ROOT / "scripts/cmux-next/fetch-nightly-dmg.py")
tool = importlib.util.module_from_spec(spec)
spec.loader.exec_module(tool)


def udif(chunks: list[tuple[int, bytes]]) -> tuple[bytes, bytes]:
    """A UDIF image of (kind, raw sector data) chunks; returns (dmg bytes, the raw disk)."""
    data = b""
    entries = b""
    disk = b""
    sector = 0
    for kind, raw in chunks:
        sectors = len(raw) // 512
        stored = {0x1: raw, 0x80000005: zlib.compress(raw), 0x80000008: lzma.compress(raw), 0x2: b""}[kind]
        entries += struct.pack(">IIQQQQ", kind, 0, sector, sectors, len(data), len(stored))
        data += stored
        disk += raw if kind != 0x2 else b"\0" * len(raw)
        sector += sectors
    entries += struct.pack(">IIQQQQ", 0xFFFFFFFF, 0, sector, 0, len(data), 0)
    count = len(chunks) + 1
    mish = b"mish" + struct.pack(">IQQQI", 1, 0, sector, 0, 0) + b"\0" * (200 - 36) + struct.pack(">I", count) + entries
    xml = plistlib.dumps({"resource-fork": {"blkx": [{"Data": mish, "Name": "disk", "Attributes": "0x0050"}]}})
    koly = bytearray(512)
    koly[0:4] = b"koly"
    struct.pack_into(">Q", koly, 24, 0)  # data fork offset
    struct.pack_into(">QQ", koly, 216, len(data), len(xml))
    return data + xml + bytes(koly), disk


def test_decodes_raw_zlib_lzma_and_zero_chunks(tmp: Path) -> None:
    a, b, c, z = b"A" * 1024, bytes(range(256)) * 8, b"C" * 512, b"\0" * 1536
    dmg, disk = udif([(0x1, a), (0x80000005, b), (0x2, z), (0x80000008, c)])
    src, dst = tmp / "x.dmg", tmp / "disk.img"
    src.write_bytes(dmg)
    tool.decode_udif(src, dst)
    assert dst.read_bytes() == disk


def test_rejects_a_file_that_is_not_udif(tmp: Path) -> None:
    src = tmp / "x.dmg"
    src.write_bytes(b"\0" * 1024)
    try:
        tool.decode_udif(src, tmp / "disk.img")
    except SystemExit as e:
        assert "not a UDIF image" in str(e)
    else:
        raise AssertionError("decoded a file with no koly trailer")


def test_picks_the_newest_item_of_the_feed(tmp: Path) -> None:
    feed = b"""<?xml version="1.0"?><rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel>
<item><sparkle:version>200</sparkle:version><enclosure url="https://x/new.dmg" length="20"/></item>
<item><sparkle:version>100</sparkle:version><enclosure url="https://x/old.dmg" length="10"/></item>
<item><sparkle:version>beta</sparkle:version><enclosure url="https://x/bad.dmg" length="1"/></item>
</channel></rss>"""
    assert tool.newest_enclosure(feed) == ("200", "https://x/new.dmg", 20)


def main() -> int:
    tests = [v for k, v in sorted(globals().items()) if k.startswith("test_")]
    failed = 0
    for t in tests:
        with tempfile.TemporaryDirectory() as d:
            try:
                t(Path(d))
                print(f"ok {t.__name__}")
            except AssertionError as e:
                failed += 1
                print(f"FAIL {t.__name__}: {e}")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
