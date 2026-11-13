#!/usr/bin/env python3
"""Drops Chromium's first-run intro sounds from an embedded CEF resources.pak.

  cef-pak-drop.py <resources.pak> <cef_pack_resources.h>

Chromium's resources.pak carries six FLAC tracks, IDR_INTRO_SOUND_*, 4.8 MB
that do not compress, so they cost the same in the DMG. They are the sounds
of Chrome's own first-run intro and welcome screens, which CEF never shows.
The ids differ between CEF builds, so they are read by name from the
framework's own include/cef_pack_resources.h, and an entry is dropped only
when its bytes start with the FLAC magic.

The pak is rewritten in place (format 5: header, entry table, alias table,
data); every other resource keeps its bytes. With no header, no matching
names or a pak in another format it prints a warning and leaves the file
as it is. A missing id simply has no entry: Chromium's resource bundle
answers an empty resource for it.
"""
import os
import re
import struct
import sys

PREFIX = "IDR_INTRO_SOUND_"
MAGIC = b"fLaC"


def intro_sound_ids(header_text):
    """{id: name} of the #define IDR_INTRO_SOUND_* lines of cef_pack_resources.h."""
    found = {}
    for name, value in re.findall(r"^\s*#define\s+(" + PREFIX + r"\w+)\s+(\d+)\s*$", header_text, re.M):
        found[int(value)] = name
    return found


def drop(pak, ids):
    """(new pak bytes, [dropped ids]) without the entries of ids whose data is FLAC."""
    version, = struct.unpack_from("<I", pak, 0)
    if version != 5:
        raise ValueError(f"pak format {version}, not 5")
    encoding, count, aliases = struct.unpack_from("<B3xHH", pak, 4)
    table = 12
    entries = [struct.unpack_from("<HI", pak, table + 6 * i) for i in range(count + 1)]
    alias_at = table + 6 * (count + 1)
    alias_list = [struct.unpack_from("<HH", pak, alias_at + 4 * i) for i in range(aliases)]
    if entries[-1][1] != len(pak) or any(a[1] > b[1] for a, b in zip(entries, entries[1:])):
        raise ValueError("entry offsets do not match the file")
    kept, dropped, index_map = [], [], {}
    for i in range(count):
        rid, start = entries[i]
        data = pak[start:entries[i + 1][1]]
        if rid in ids and data.startswith(MAGIC):
            dropped.append(rid)
            continue
        index_map[i] = len(kept)
        kept.append((rid, data))
    if not dropped:
        return pak, []
    new_aliases = [(rid, index_map[idx]) for rid, idx in alias_list if idx in index_map]
    offset = table + 6 * (len(kept) + 1) + 4 * len(new_aliases)
    out = bytearray(struct.pack("<IB3xHH", 5, encoding, len(kept), len(new_aliases)))
    for rid, data in kept:
        out += struct.pack("<HI", rid, offset)
        offset += len(data)
    out += struct.pack("<HI", 0, offset)
    for rid, idx in new_aliases:
        out += struct.pack("<HH", rid, idx)
    for _, data in kept:
        out += data
    return bytes(out), dropped


def main(argv):
    if len(argv) != 2:
        print(__doc__, file=sys.stderr)
        return 2
    pak_path, header_path = argv
    try:
        with open(header_path) as f:
            ids = intro_sound_ids(f.read())
    except OSError as error:
        print(f"warning: cef-pak-drop: cannot read {header_path} ({error}); resources.pak keeps its intro sounds")
        return 0
    if not ids:
        print(f"warning: cef-pak-drop: {header_path} names no {PREFIX}*; resources.pak keeps its intro sounds")
        return 0
    with open(pak_path, "rb") as f:
        pak = f.read()
    try:
        new, dropped = drop(pak, ids)
    except (ValueError, struct.error) as error:
        print(f"warning: cef-pak-drop: {pak_path}: {error}; left as it is")
        return 0
    if not dropped:
        print(f"note: cef-pak-drop: no FLAC entry for {PREFIX}* in {pak_path}")
        return 0
    tmp = pak_path + ".tmp"
    with open(tmp, "wb") as f:
        f.write(new)
    os.replace(tmp, pak_path)
    names = ", ".join(ids[rid] for rid in dropped)
    print(f"note: cef-pak-drop: dropped {len(pak) - len(new)} bytes from resources.pak ({names})")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
