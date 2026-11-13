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


if __name__ == "__main__":
    tests = [value for name, value in sorted(globals().items()) if name.startswith("test_")]
    for test in tests:
        test()
    print(f"cef-pak-drop tests: {len(tests)} ok")
