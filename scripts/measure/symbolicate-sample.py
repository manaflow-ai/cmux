#!/usr/bin/env python3
"""Names the cmux-tui frames of a macOS `sample` of a stripped NIGHTLY binary (`cmux acp daemon`, `cmux-tui`, acpmux).

The app strips `Contents/Resources/bin/cmux` (scripts/strip-release-bundle.sh), so `sample` prints only
`???  (in cmux)  load address A + 0xOFF`. Its line-table dSYM goes to Sentry, which a person or an agent on
the Mac cannot read without a token. The tree-addressed binary the nightly installed is published whole,
symbol table and all, at https://files.cmux.com/cmux-tui/<commit>/cmux-tui-aarch64-apple-darwin (the same
image: the same LC_UUID). This fetches it once (kept under ~/.cache/cmux-symbols), checks the UUID against
the sample's, and prints the sample with each such frame named, plus the hottest named frames.

  scripts/measure/symbolicate-sample.py SAMPLE.txt [--commit SHA] [--binary PATH] [--top N]

--commit: the cmux-tui commit, the first hash `cmux --version` prints (`cmux 1.0.0 (<commit>; ...)`); without
it the sample's binary is run with --version. --binary: an unstripped binary already at hand.
Found 2026-11-23: acpmux at 144% of a core on Leo's Mac (`Hub::bg_list_as` → `bg_run::read_output`).
"""

from __future__ import annotations

import argparse
import bisect
import collections
import os
import re
import subprocess
import sys
import urllib.request
from pathlib import Path

FRAME = re.compile(r"\?\?\?  \(in (?P<image>[^)]+)\)  load address (?P<load>0x[0-9a-f]+) \+ (?P<off>0x[0-9a-f]+)")
CACHE = Path(os.environ.get("XDG_CACHE_HOME", Path.home() / ".cache")) / "cmux-symbols"


def sample_binary(text: str) -> tuple[str, str, str]:
    """The sampled process's path, image name and UUID from the sample's header and Binary Images."""
    path = re.search(r"^Path:\s+(.+)$", text, re.M).group(1).strip()
    name = os.path.basename(path)
    uuid = re.search(r"\+%s \([^)]*\) <([0-9A-F-]+)>" % re.escape(name), text)
    return path, name, uuid.group(1) if uuid else ""


def binary_uuid(binary: Path) -> str:
    out = subprocess.run(["dwarfdump", "--uuid", str(binary)], capture_output=True, text=True).stdout
    found = re.search(r"UUID: ([0-9A-F-]+) \(arm64\)", out)
    return found.group(1) if found else ""


def fetch(commit: str) -> Path:
    dest = CACHE / commit / "cmux-tui-aarch64-apple-darwin"
    if not dest.exists():
        dest.parent.mkdir(parents=True, exist_ok=True)
        url = f"https://files.cmux.com/cmux-tui/{commit}/cmux-tui-aarch64-apple-darwin"
        print(f"fetching {url}", file=sys.stderr)
        part = dest.with_suffix(".part")
        urllib.request.urlretrieve(url, part)
        part.rename(dest)
    return dest


def symbols(binary: Path) -> tuple[list[int], list[str]]:
    """The binary's text symbols by address, demangled (c++filt reads Rust's legacy mangling)."""
    nm = subprocess.run(["nm", "-n", str(binary)], capture_output=True, text=True, check=True).stdout
    addrs, raw = [], []
    for line in nm.splitlines():
        parts = line.split(None, 2)
        if len(parts) == 3 and parts[1] in ("t", "T"):
            addrs.append(int(parts[0], 16))
            raw.append(parts[2][1:] if parts[2].startswith("_") else parts[2])
    names = subprocess.run(["c++filt"], input="\n".join(raw), capture_output=True, text=True).stdout.splitlines()
    # Drop rustc's `::h<16 hex>` disambiguator: it only adds noise to a profile.
    return addrs, [re.sub(r"::h[0-9a-f]{16}$", "", n) for n in names]


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("sample")
    ap.add_argument("--commit")
    ap.add_argument("--binary")
    ap.add_argument("--top", type=int, default=25)
    args = ap.parse_args()
    text = Path(args.sample).read_text(errors="replace")
    path, image, uuid = sample_binary(text)
    if args.binary:
        binary = Path(args.binary)
    else:
        commit = args.commit
        if not commit:
            version = subprocess.run([path, "--version"], capture_output=True, text=True).stdout
            commit = re.search(r"\(([0-9a-f]{40});", version).group(1)
        binary = fetch(commit)
    have = binary_uuid(binary)
    if uuid and have and have != uuid:
        print(f"UUID mismatch: sample {uuid}, {binary} {have}; pass the right --commit", file=sys.stderr)
        return 1
    addrs, names = symbols(binary)
    base = 0x100000000  # __TEXT's vmaddr in an arm64 executable.

    def name(off: int) -> str:
        i = bisect.bisect_right(addrs, base + off) - 1
        return names[i] if i >= 0 else hex(off)

    self_time: collections.Counter[str] = collections.Counter()
    out = []
    in_top = False
    for line in text.splitlines():
        in_top = in_top or line.startswith("Sort by top of stack")
        m = FRAME.search(line)
        if m and m.group("image") == image:
            named = name(int(m.group("off"), 16))
            line = line[: m.start()] + f"{named}  (in {image}) + {m.group('off')}" + line[m.end() :]
        out.append(line)
        top = re.match(r"^\s+(.+?)\s{2,}(\d+)$", line)
        if top and in_top:
            self_time[top.group(1)] += int(top.group(2))
    print("\n".join(out))
    if self_time:
        print(f"\n== top of stack, named ({binary}):")
        for frame, count in self_time.most_common(args.top):
            print(f"{count:8d}  {frame}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
