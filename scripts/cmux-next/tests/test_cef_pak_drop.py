#!/usr/bin/env python3
"""Tests of scripts/cmux-next/cef-pak-drop.py: which entries leave resources.pak, and that every
other resource and alias reads back the same."""

from __future__ import annotations

import importlib.util
import os
import struct
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
SCRIPT = ROOT / "scripts/cmux-next/cef-pak-drop.py"
spec = importlib.util.spec_from_file_location("cef_pak_drop", SCRIPT)
tool = importlib.util.module_from_spec(spec)
spec.loader.exec_module(tool)

HEADER = """\
#define IDR_ABOUT_UI_CREDITS_CSS 14000
#define IDR_INTRO_SOUND_ALL_SET_FLAC 15500
#define IDR_INTRO_SOUND_LOGO_FLAC 15504
#define IDR_AUDIO_SPATIALIZATION_COMPOSITE 47379
"""


def pak(resources: list[tuple[int, bytes]], aliases: list[tuple[int, int]] = ()) -> bytes:
    """A format 5 pak of (id, data) resources and (alias id, entry index) aliases."""
    offset = 12 + 6 * (len(resources) + 1) + 4 * len(aliases)
    out = struct.pack("<IB3xHH", 5, 1, len(resources), len(aliases))
    for rid, data in resources:
        out += struct.pack("<HI", rid, offset)
        offset += len(data)
    out += struct.pack("<HI", 0, offset)
    for rid, idx in aliases:
        out += struct.pack("<HH", rid, idx)
    return out + b"".join(data for _, data in resources)


def read(data: bytes) -> dict[int, bytes]:
    """Every id (aliases included) to its bytes, as Chromium's DataPack resolves them."""
    _, count, aliases = struct.unpack_from("<IxxxxHH", data, 0)
    entries = [struct.unpack_from("<HI", data, 12 + 6 * i) for i in range(count + 1)]
    out = {entries[i][0]: data[entries[i][1]:entries[i + 1][1]] for i in range(count)}
    at = 12 + 6 * (count + 1)
    for i in range(aliases):
        rid, idx = struct.unpack_from("<HH", data, at + 4 * i)
        out[rid] = data[entries[idx][1]:entries[idx + 1][1]]
    return out


SOURCE = pak(
    [(14000, b"body{}"), (15500, b"fLaC" + b"a" * 40), (15504, b"fLaC" + b"b" * 9), (20000, b"<html>"),
     (47379, b"fLaC" + b"hrtf")],
    [(14001, 0), (15501, 1), (20001, 3)],
)


def test_drops_only_the_named_flac_entries():
    new, dropped = tool.drop(SOURCE, tool.intro_sound_ids(HEADER))
    assert sorted(dropped) == [15500, 15504]
    before, after = read(SOURCE), read(new)
    assert set(after) == {14000, 14001, 20000, 20001, 47379}
    for rid in after:
        assert after[rid] == before[rid], rid
    assert len(SOURCE) - len(new) == 44 + 13 + 2 * 6 + 4


def test_an_id_whose_data_is_not_flac_stays():
    source = pak([(15500, b"not audio"), (20000, b"x")])
    new, dropped = tool.drop(source, {15500: "IDR_INTRO_SOUND_ALL_SET_FLAC"})
    assert dropped == [] and new == source


def test_only_intro_sound_names_are_read():
    assert tool.intro_sound_ids(HEADER) == {15500: "IDR_INTRO_SOUND_ALL_SET_FLAC", 15504: "IDR_INTRO_SOUND_LOGO_FLAC"}


def test_refuses_other_formats_and_bad_offsets():
    for bad in (struct.pack("<I", 4) + SOURCE[4:], SOURCE[:-3]):
        try:
            tool.drop(bad, {15500: "x"})
        except ValueError:
            continue
        raise AssertionError("accepted a pak it cannot rewrite")


def test_cli_rewrites_in_place_and_leaves_it_without_a_header():
    with tempfile.TemporaryDirectory() as tmp:
        path, header = os.path.join(tmp, "resources.pak"), os.path.join(tmp, "cef_pack_resources.h")
        Path(path).write_bytes(SOURCE)
        missing = subprocess.run([sys.executable, "-I", str(SCRIPT), path, header], capture_output=True, text=True)
        assert missing.returncode == 0 and "warning:" in missing.stdout
        assert Path(path).read_bytes() == SOURCE
        Path(header).write_text(HEADER)
        done = subprocess.run([sys.executable, "-I", str(SCRIPT), path, header], capture_output=True, text=True)
        assert done.returncode == 0, done.stderr
        assert "IDR_INTRO_SOUND_ALL_SET_FLAC" in done.stdout
        assert 15500 not in read(Path(path).read_bytes())
        assert not os.path.exists(path + ".tmp")


# --- locale.pak strings ---------------------------------------------------------------------

STRINGS_HEADER = """\
#define IDS_DEFAULT_TAB_TITLE 320
#define IDS_NTP_TITLE 900
#define IDS_NTP_CUSTOMIZE_DEFAULT_LABEL 901
#define IDS_GLIC_WINDOW_TITLE 902
#define IDS_GLIC_SHARED 903
#define IDS_COMPOSE_SUGGESTION_MAIN_TEXT 904
#define IDS_SETTINGS_TITLE 905
"""

LOCALE = pak(
    [(320, b"Untitled"), (900, b"New Tab"), (901, b"Default"), (902, b"Assistant"), (903, b"Shared"),
     (904, b"Help me write"), (905, b"Settings")],
    # 906 is a kept string whose text is the same as 903's, so the pak aliases it.
    [(906, 4)],
)


def test_string_ids_are_the_trimmed_features_less_what_kept_pages_read():
    ids = tool.string_ids(STRINGS_HEADER)
    assert ids == {900: "IDS_NTP_TITLE", 902: "IDS_GLIC_WINDOW_TITLE", 903: "IDS_GLIC_SHARED"}


def test_trimmed_strings_read_empty_and_keep_their_ids():
    new, emptied = tool.empty_strings(LOCALE, tool.string_ids(STRINGS_HEADER))
    # 903 stays: kept id 906 aliases its data.
    assert sorted(emptied) == [900, 902]
    before, after = read(LOCALE), read(new)
    assert set(after) == set(before)
    assert after[900] == b"" and after[902] == b""
    for rid in after:
        if rid not in (900, 902):
            assert after[rid] == before[rid], rid
    assert len(LOCALE) - len(new) == len(b"New Tab") + len(b"Assistant")
    assert tool.empty_strings(new, tool.string_ids(STRINGS_HEADER)) == (new, [])


def test_cli_trims_every_locale_pak_and_leaves_them_without_a_header():
    with tempfile.TemporaryDirectory() as tmp:
        paks = [os.path.join(tmp, f"{lang}.pak") for lang in ("en", "fr")]
        for path in paks:
            Path(path).write_bytes(LOCALE)
        header = os.path.join(tmp, "cef_pack_strings.h")
        missing = subprocess.run([sys.executable, "-I", str(SCRIPT), "--strings", header, *paks],
                                 capture_output=True, text=True)
        assert missing.returncode == 0 and "warning:" in missing.stdout
        assert all(Path(path).read_bytes() == LOCALE for path in paks)
        Path(header).write_text(STRINGS_HEADER)
        done = subprocess.run([sys.executable, "-I", str(SCRIPT), "--strings", header, *paks, paks[0] + ".gone"],
                              capture_output=True, text=True)
        assert done.returncode == 0, done.stderr
        assert "warning:" in done.stdout  # the missing pak
        for path in paks:
            assert read(Path(path).read_bytes())[900] == b""
            assert not os.path.exists(path + ".tmp")


# --- WebUI resource maps ----------------------------------------------------------------------

def macho(strings: list[str], maps: list[list[tuple[str, int]]], stride: int = 32) -> bytes:
    """A 64-bit Mach-O with a __TEXT,__cstring of strings and a __DATA_CONST,__const of maps:
    entries of (chained-fixup rebase to the path, id), one map after another."""
    header_size = 32 + 72 + 80 + 72 + 80
    cstring = b"".join(s.encode() + b"\0" for s in strings)
    at = {s: header_size + cstring.index(s.encode() + b"\0") for s in strings}
    data = bytearray()
    for run in maps:
        for path, rid in run:
            entry = struct.pack("<QiI", (1 << 62) | at[path], rid, 0)
            data += entry + b"\0" * (stride - len(entry))
        data += b"\0" * stride  # a gap between maps
    data_at = header_size + len(cstring)
    out = struct.pack("<IiiIIIII", 0xFEEDFACF, 0x0100000C, 0, 6, 2, 72 * 2 + 80 * 2, 0, 0)
    for segment, section, offset, body in (("__TEXT", "__cstring", header_size, cstring),
                                           ("__DATA_CONST", "__const", data_at, data)):
        out += struct.pack("<II16sQQQQiiII", 0x19, 152, segment.encode(), offset, len(body), offset,
                           len(body), 3, 3, 1, 0)
        out += struct.pack("<16s16sQQIIIIIIII", section.encode(), segment.encode(), offset, len(body),
                           offset, 0, 0, 0, 0, 0, 0, 0)
    assert len(out) == header_size
    return out + cstring + bytes(data)


PAGES = [("new_tab_page.html", 20540), ("new_tab_page.js", 20541), ("shared.rollup.js", 20542)]
SETTINGS = [("settings.html", 22276), ("settings.js", 22277), ("shared.rollup.js", 22278)]
# A map whose top-level pages are a dropped group plus another page: not that group.
MIXED = [("history.html", 20060), ("history.js", 20061), ("other.html", 20062)]
# Another map also serves 20541, so it stays.
SHARED = [("new_tab_page.js", 20541)]
MAPS = [PAGES, SETTINGS, MIXED, SHARED]
BINARY = macho(sorted({p for run in MAPS for p, _ in run}), MAPS)
IDS = {rid for run in MAPS for _, rid in run} | {15500}


def test_resource_maps_read_back_each_map():
    for stride in (16, 32):
        maps = tool.resource_maps(macho(sorted({p for run in MAPS for p, _ in run}), MAPS, stride), IDS)
        assert maps == MAPS, maps


def test_a_page_group_goes_and_what_others_list_or_the_header_names_stays():
    pages, found = tool.webui_ids(tool.resource_maps(BINARY, IDS), {20542: "IDR_NAMED"})
    assert found == ["New Tab page"]
    assert pages == {20540: "New Tab page"}


def test_universal_binary_reads_its_arm64_slice():
    fat = struct.pack(">II", 0xCAFEBABE, 2)
    first = 8 + 20 * 2
    fat += struct.pack(">iiIII", 0x01000007, 3, first, 4, 2)
    fat += struct.pack(">iiIII", 0x0100000C, 0, first + 4, len(BINARY), 2)
    assert tool.macho_slice(fat + b"x86!" + BINARY) == BINARY
    for bad in (b"\0" * 64, struct.pack(">II", 0xCAFEBABE, 0)):
        try:
            tool.macho_slice(bad)
        except ValueError:
            continue
        raise AssertionError("accepted a binary it cannot read")


def test_cli_drops_pages_and_sounds_and_leaves_pages_without_maps():
    source = pak([(15500, b"fLaC" + b"s" * 30)] + [(rid, b"<%d>" % rid) for run in MAPS for _, rid in run
                                                    if rid != 20541] + [(20541, b"ntp.js")])
    source = pak(sorted(read(source).items()))
    with tempfile.TemporaryDirectory() as tmp:
        path, header, binary = (os.path.join(tmp, n) for n in ("resources.pak", "cef_pack_resources.h", "CEF"))
        Path(header).write_text(HEADER)
        Path(binary).write_bytes(b"not a binary")
        Path(path).write_bytes(source)
        args = [sys.executable, "-I", str(SCRIPT), path, header, "--webui", binary]
        done = subprocess.run(args, capture_output=True, text=True)
        assert done.returncode == 0 and "warning:" in done.stdout, done
        assert set(read(Path(path).read_bytes())) == set(read(source)) - {15500}
        Path(binary).write_bytes(BINARY)
        Path(path).write_bytes(source)
        done = subprocess.run(args, capture_output=True, text=True)
        assert done.returncode == 0, done.stderr
        assert "New Tab page" in done.stdout
        after = read(Path(path).read_bytes())
        assert set(after) == set(read(source)) - {15500, 20540, 20542}
        assert all(after[rid] == data for rid, data in read(source).items() if rid in after)


PNG = b"\x89PNG\r\n\x1a\n" + b"\0\0\0\rIHDR" + b"p" * 20
# The omnibox popup's map lists images/create_images.png (id 20900), which Chromium's
# native code also loads as a bitmap at startup: dropping it LOG(FATAL)s "Unable to
# load bitmap image with id 20900" (cef-157.0.0-cmux.48, PR 42293).
BITMAP_MAP = [("omnibox_popup.html", 20901), ("omnibox_popup_aim.html", 20902),
              ("omnibox_popup_full.html", 20903), ("images/create_images.png", 20904),
              ("images/gz.png", 20905), ("animations/native.json", 20906), ("popup.js", 20907)]


def test_bitmaps_and_native_lottie_of_a_dropped_page_stay():
    import gzip
    binary = macho(sorted(p for p, _ in BITMAP_MAP), [BITMAP_MAP])
    data = {20901: b"<html>", 20902: b"<html2>", 20903: b"<html3>", 20904: PNG,
            20905: gzip.compress(PNG), 20906: b"LOTTIE" + b"{}" * 8, 20907: b"js()"}
    source = pak(sorted(data.items()))
    with tempfile.TemporaryDirectory() as tmp:
        path, header, fw = (os.path.join(tmp, n) for n in ("resources.pak", "cef_pack_resources.h", "CEF"))
        Path(header).write_text(HEADER)
        Path(fw).write_bytes(binary)
        Path(path).write_bytes(source)
        done = subprocess.run([sys.executable, "-I", str(SCRIPT), path, header, "--webui", fw],
                              capture_output=True, text=True)
        assert done.returncode == 0, done
        assert "omnibox popup" in done.stdout, done.stdout
        after = read(Path(path).read_bytes())
        assert set(after) == {20904, 20905, 20906}, sorted(after)
        assert all(after[rid] == data[rid] for rid in after)


def test_the_build_guard_names_a_lost_image():
    before = pak([(1, PNG), (2, b"js()"), (3, b"\x1e\x9b" + b"br" * 4)], [(4, 0)])
    after = pak([(2, b"js()")])
    assert tool.lost_images(before, after) == [1, 3, 4]
    assert tool.lost_images(before, before) == []


def test_an_alias_a_kept_page_lists_keeps_the_entry_it_points_to():
    # grit dedupes equal files: Settings' shared.js (30011) can be an alias of the New Tab
    # page's entry (30002). Dropping that entry must not take the kept page's id with it.
    dropped_map = [("new_tab_page.html", 30001), ("ntp_shared.js", 30002)]
    kept_map = [("settings.html", 30010), ("shared.js", 30011)]
    binary = macho(sorted(p for run in (dropped_map, kept_map) for p, _ in run), [dropped_map, kept_map])
    source = pak([(30001, b"<ntp>"), (30002, b"shared()"), (30010, b"<settings>")], [(30011, 1)])
    with tempfile.TemporaryDirectory() as tmp:
        path, header, fw = (os.path.join(tmp, n) for n in ("resources.pak", "cef_pack_resources.h", "CEF"))
        Path(header).write_text(HEADER)
        Path(fw).write_bytes(binary)
        Path(path).write_bytes(source)
        done = subprocess.run([sys.executable, "-I", str(SCRIPT), path, header, "--webui", fw],
                              capture_output=True, text=True)
        assert done.returncode == 0, done
        after = read(Path(path).read_bytes())
        assert 30001 not in after, sorted(after)
        assert after.get(30011) == b"shared()" and after[30010] == b"<settings>", after


if __name__ == "__main__":
    tests = [value for name, value in sorted(globals().items()) if name.startswith("test_")]
    for test in tests:
        test()
    print(f"cef-pak-drop tests: {len(tests)} ok")
