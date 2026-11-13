#!/usr/bin/env python3
"""Tests of scripts/cmux-next/fetch-nightly-dmg.py: the appcast pick, the UDIF decoder and its limits,
and the checks on what 7-Zip extracted."""

from __future__ import annotations

import importlib.util
import lzma
import os
import plistlib
import struct
import subprocess
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
        assert "not a valid UDIF image: no koly trailer" in str(e), e
    else:
        raise AssertionError("decoded a file with no koly trailer")


def test_picks_the_newest_item_of_the_feed(tmp: Path) -> None:
    feed = b"""<?xml version="1.0"?><rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel>
<item><sparkle:version>200</sparkle:version><enclosure url="https://x/new.dmg" length="20"/></item>
<item><sparkle:version>100</sparkle:version><enclosure url="https://x/old.dmg" length="10"/></item>
<item><sparkle:version>beta</sparkle:version><enclosure url="https://x/bad.dmg" length="1"/></item>
</channel></rss>"""
    assert tool.newest_enclosure(feed) == ("200", "https://x/new.dmg", 20)


def refused(fn, *args) -> str:
    try:
        fn(*args)
    except SystemExit as e:
        return str(e)
    raise AssertionError(f"{fn.__name__}{args} was accepted")


def test_refuses_a_chunk_that_inflates_past_its_sectors(tmp: Path) -> None:
    src = tmp / "x.dmg"
    # The table says one sector; the zlib stream holds 1 MiB.
    src.write_bytes(udif_with_payload(zlib.compress(b"\0" * (1 << 20)), sectors=1))
    assert "inflates past the 512 bytes" in refused(tool.decode_udif, src, tmp / "disk.img")


def udif_with_payload(stored: bytes, sectors: int, kind: int = 0x80000005, clen: int | None = None) -> bytes:
    """A one-chunk UDIF image whose chunk claims sectors and holds stored (clen: the length it claims)."""
    entries = struct.pack(">IIQQQQ", kind, 0, 0, sectors, 0, len(stored) if clen is None else clen)
    entries += struct.pack(">IIQQQQ", 0xFFFFFFFF, 0, sectors, 0, len(stored), 0)
    mish = b"mish" + struct.pack(">IQQQI", 1, 0, sectors, 0, 0) + b"\0" * (200 - 36) + struct.pack(">I", 2) + entries
    xml = plistlib.dumps({"resource-fork": {"blkx": [{"Data": mish, "Name": "disk", "Attributes": "0x0050"}]}})
    koly = bytearray(512)
    koly[0:4] = b"koly"
    struct.pack_into(">QQ", koly, 216, len(stored), len(xml))
    return stored + xml + bytes(koly)


def test_refuses_offsets_outside_the_file_and_a_disk_over_the_cap(tmp: Path) -> None:
    src = tmp / "x.dmg"
    src.write_bytes(udif_with_payload(b"A" * 512, sectors=1, kind=0x1, clen=1 << 30))
    assert "a chunk lies outside the file" in refused(tool.decode_udif, src, tmp / "disk.img")
    src.write_bytes(udif_with_payload(b"A" * 512, sectors=1 << 30, kind=0x1))
    assert "its disk is over 4096 bytes" in refused(tool.decode_udif, src, tmp / "disk.img", 4096)
    blob = bytearray(udif_with_payload(b"A" * 512, sectors=1, kind=0x1))
    struct.pack_into(">QQ", blob, len(blob) - 512 + 216, 0, 1 << 40)
    src.write_bytes(bytes(blob))
    assert "its resource list lies outside the file" in refused(tool.decode_udif, src, tmp / "disk.img")


def test_the_volume_keeps_one_app_and_no_link_out(tmp: Path) -> None:
    vol = tmp / "volume"
    (vol / "cmux NIGHTLY.app/Contents/Frameworks").mkdir(parents=True)
    (tmp / "secret").write_text("x")
    os.symlink("../Frameworks", vol / "cmux NIGHTLY.app/Contents/Inside")
    os.symlink("/Applications", vol / "Applications")  # the DMG's drag target
    os.symlink("../../../../secret", vol / "cmux NIGHTLY.app/Contents/Frameworks/Out")
    os.symlink("Loop", vol / "Loop")
    app, removed = tool.check_volume(vol)
    assert app == vol / "cmux NIGHTLY.app"
    assert sorted(removed) == ["Applications", "cmux NIGHTLY.app/Contents/Frameworks/Out"], removed
    assert (vol / "cmux NIGHTLY.app/Contents/Inside").is_symlink() and (tmp / "secret").exists()
    (vol / "Other.app").mkdir()
    assert "holds 2 .app folders" in refused(tool.check_volume, vol)


def test_7zip_exit_2_passes_only_for_refused_links(tmp: Path) -> None:
    link = ("ERROR: Dangerous symbolic link path was ignored : x.app/Contents/Helpers/h.app/Contents/Frameworks/F"
            " : ../../../../Frameworks/F")
    real_run, real_which = tool.subprocess.run, tool.shutil.which

    def fake(rc: int, out: str):
        def run(cmd, **_kw):
            dest = Path(next(a for a in cmd if a.startswith("-o"))[2:])
            (dest / "x.app").mkdir()
            return subprocess.CompletedProcess(cmd, rc, out, "")
        return run

    tool.shutil.which = lambda _n: "/usr/bin/7z"
    try:
        tool.subprocess.run = fake(2, link + "\nSub items Errors: 1\n")
        app, links, removed = tool.extract(tmp / "disk.img", tmp / "v1")
        assert app.name == "x.app" and links == [link.split(" : ", 1)[1]] and removed == [], links
        tool.subprocess.run = fake(2, link + "\nERROR: Data Error : x.app/Contents/MacOS/x\n")
        assert "7-Zip exit 2" in refused(tool.extract, tmp / "disk.img", tmp / "v2")
        tool.subprocess.run = fake(2, "Sub items Errors: 1\n")
        assert "7-Zip exit 2" in refused(tool.extract, tmp / "disk.img", tmp / "v3")
        tool.subprocess.run = fake(1, "")
        assert "7-Zip exit 1" in refused(tool.extract, tmp / "disk.img", tmp / "v4")
    finally:
        tool.subprocess.run, tool.shutil.which = real_run, real_which


def test_requests_name_their_user_agent(tmp: Path) -> None:
    # The file server refuses Python's default User-Agent with 403 (2026-11-12).
    seen = []
    real = tool.urllib.request.urlopen

    def fake(req, timeout=None):
        seen.append(req.get_header("User-agent"))
        raise SystemExit("stop")

    tool.urllib.request.urlopen = fake
    try:
        refused(tool.download, "https://example.invalid/x.dmg", tmp / "x.dmg", 10)
    finally:
        tool.urllib.request.urlopen = real
    assert seen == [tool.USER_AGENT] and not seen[0].startswith("Python-urllib"), seen


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
