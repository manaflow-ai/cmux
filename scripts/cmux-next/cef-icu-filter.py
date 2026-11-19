#!/usr/bin/env python3
"""Filters Chromium's ICU data file (icudtl.dat) to the languages cmux ships.

  cef-icu-filter.py <icudtl.dat> <language>[,<language>...]

icudtl.dat is an ICU common data package ('CmnD'): a header, a table of
contents (item names in sorted order, each with an offset) and the items, each
aligned to 16 bytes. The per-locale resource bundles (the main locale data and
the coll, curr, lang, region, unit, zone, rbnf and brkitr trees) of a language
not in the list are removed; root, the pools, supplemental data, converters,
normalization, the break rules and dictionaries stay, so every language still
renders, breaks lines and converts, and a removed locale formats with its
root (English-like) data. Every kept item keeps its bytes.

Known gap: res_index.res still lists the removed locales as installed, so
Intl.*.supportedLocalesOf() reports them while their data falls back to root.

The file is rewritten in place. With a file in another format it prints a
warning and leaves it as it is.
"""
import os
import re
import struct
import sys

LOCALE_TREES = {"", "coll", "curr", "lang", "region", "unit", "zone", "rbnf", "brkitr"}
SHARED = {"root.res", "pool.res", "res_index.res"}
LOCALE_ITEM = re.compile(r"^([a-z]{2,3})(_[A-Za-z0-9]+)*\.res$")


def parse(data):
    """(header bytes, [(name, item bytes)]) of an ICU common data package."""
    header_size, magic1, magic2 = struct.unpack_from("<HBB", data, 0)
    if (magic1, magic2) != (0xDA, 0x27) or data[12:16] != b"CmnD":
        raise ValueError("not an ICU common data package")
    if data[8] != 0:
        raise ValueError("big-endian ICU data")
    toc = header_size
    count, = struct.unpack_from("<I", data, toc)
    entries = [struct.unpack_from("<II", data, toc + 4 + 8 * i) for i in range(count)]
    offsets = [toc + d for _, d in entries] + [len(data)]
    if any(a > b for a, b in zip(offsets, offsets[1:])):
        raise ValueError("table of contents does not match the file")
    items = []
    for i, (name_offset, _) in enumerate(entries):
        start = toc + name_offset
        name = data[start:data.index(b"\0", start)].decode("ascii")
        items.append((name, data[offsets[i]:offsets[i + 1]]))
    return data[:header_size], items


def build(header, items):
    """Package bytes of header and [(name, item bytes)], items in the given (sorted) order."""
    table = 4 + 8 * len(items)
    names = b"".join(name.encode("ascii") + b"\0" for name, _ in items)
    data_start = table + len(names)
    data_start += -(len(header) + data_start) % 16
    out = bytearray(header) + struct.pack("<I", len(items))
    name_at, data_at = table, data_start
    for name, body in items:
        out += struct.pack("<II", name_at, data_at)
        name_at += len(name) + 1
        data_at += len(body) + (-len(body) % 16)
    out += names
    out += b"\0" * (len(header) + data_start - len(out))
    for _, body in items:
        out += body + b"\0" * (-len(body) % 16)
    return bytes(out)


def keep(name, languages):
    parts = name.split("/")[1:]
    tree, leaf = ("/".join(parts[:-1]), parts[-1]) if parts else ("", name)
    if tree not in LOCALE_TREES or leaf in SHARED:
        return True
    match = LOCALE_ITEM.match(leaf)
    return not match or match.group(1) in languages


def main(argv):
    if len(argv) != 2:
        print(__doc__, file=sys.stderr)
        return 2
    path, languages = argv[0], set(argv[1].split(","))
    try:
        with open(path, "rb") as f:
            data = f.read()
        header, items = parse(data)
    except (OSError, ValueError, struct.error) as error:
        print(f"warning: cef-icu-filter: {path}: {error}; left as it is")
        return 0
    kept = [(name, body) for name, body in items if keep(name, languages)]
    if len(kept) == len(items):
        print(f"note: cef-icu-filter: nothing to drop in {path}")
        return 0
    new = build(header, kept)
    _, check = parse(new)
    if check != kept:
        print(f"error: cef-icu-filter: the rebuilt {path} does not read back", file=sys.stderr)
        return 1
    tmp = path + ".tmp"
    with open(tmp, "wb") as f:
        f.write(new)
    os.replace(tmp, path)
    print(f"note: cef-icu-filter: dropped {len(items) - len(kept)} locale items, {len(data) - len(new)} bytes from {path}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
