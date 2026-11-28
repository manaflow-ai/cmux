#!/usr/bin/env python3
"""Turn a link order probe's first calls into the framework's linker order file.

The probe (Packages/macOS/CmuxNext/Sources/CmuxNextLinkOrder) writes one line per function, in the order a launch
first ran it: `IMAGE<TAB>OFFSET_HEX`, the offset from the image's Mach-O header. This maps each offset in the
CmuxNextApp framework to its symbol with `nm -n` and writes those symbols, first call first, one per line, the
format `ld -order_file` reads. A symbol a later build no longer has costs nothing: ld only warns about it.

    python3 -I scripts/cmux-next/link-order.py --calls first-calls.tsv --binary PATH/CmuxNextApp \
        --out Packages/macOS/CmuxNext/LinkOrder/CmuxNextApp.order
    python3 -I scripts/cmux-next/link-order.py --self-test
"""
from __future__ import annotations

import argparse
import bisect
import os
import subprocess
import sys
import tempfile

HEADER_SYMBOLS = ("__mh_dylib_header", "__mh_execute_header")
HEADER = "# cmux NEXT cold launch order (scripts/measure/link-order.sh); first call first.\n"


def parse_nm(text):
    """(header address, sorted [(address, name)]) for the text symbols in `nm -n` output (pure)."""
    base = 0
    symbols = []
    for line in text.splitlines():
        parts = line.split(" ", 2)
        if len(parts) != 3 or not parts[0]:
            continue
        address, kind, name = parts
        try:
            value = int(address, 16)
        except ValueError:
            continue
        if name in HEADER_SYMBOLS:
            base = value
        elif kind in ("t", "T"):
            symbols.append((value, name))
    symbols.sort()
    return base, symbols


def order(calls, image, base, symbols):
    """The symbols IMAGE's first calls land in, deduped, first call first (pure)."""
    addresses = [address for address, _ in symbols]
    seen = set()
    names = []
    for line in calls.splitlines():
        parts = line.rstrip("\n").split("\t")
        if len(parts) != 2 or os.path.basename(parts[0]) != image:
            continue
        try:
            pc = base + int(parts[1], 16)
        except ValueError:
            continue
        at = bisect.bisect_right(addresses, pc) - 1
        if at < 0:
            continue
        name = symbols[at][1]
        if name not in seen:
            seen.add(name)
            names.append(name)
    return names


def self_test():
    nm = ("0000000000000000 T __mh_dylib_header\n0000000000001000 t _a\n0000000000001010 T _b\n"
          "0000000000001040 T _c\n0000000000002000 D _data\n                 U _undef\n")
    base, symbols = parse_nm(nm)
    assert base == 0 and [n for _, n in symbols] == ["_a", "_b", "_c"], symbols
    calls = "/x/CmuxNextApp\t1044\n/x/CmuxNextApp\t1004\n/x/Other\t1010\n/x/CmuxNextApp\t1048\nbad\n/x/CmuxNextApp\t1012\n"
    assert order(calls, "CmuxNextApp", base, symbols) == ["_c", "_a", "_b"]
    base, symbols = parse_nm("0000000100000000 T __mh_execute_header\n0000000100000400 T _main\n")
    assert order("/x/stub\t400\n", "stub", base, symbols) == ["_main"]
    print("link-order self-test ok")


def main(argv):
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("--calls")
    parser.add_argument("--binary")
    parser.add_argument("--out")
    parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args(argv)
    if args.self_test:
        self_test()
        return 0
    if not (args.calls and args.binary and args.out):
        parser.error("--calls, --binary and --out are required")
    nm = subprocess.run(["nm", "-n", args.binary], check=True, capture_output=True, text=True).stdout
    base, symbols = parse_nm(nm)
    with open(args.calls, encoding="utf-8", errors="replace") as handle:
        names = order(handle.read(), os.path.basename(args.binary), base, symbols)
    if not names:
        print(f"link-order: no first call landed in {args.binary}", file=sys.stderr)
        return 1
    folder = os.path.dirname(os.path.abspath(args.out))
    with tempfile.NamedTemporaryFile("w", dir=folder, delete=False, encoding="utf-8") as handle:
        handle.write(HEADER + "".join(name + "\n" for name in names))
    os.replace(handle.name, args.out)
    print(f"link-order: {len(names)} symbols of {len(symbols)} -> {args.out}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
