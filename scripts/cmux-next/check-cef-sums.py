#!/usr/bin/env python3
"""Strict SHA256SUMS check for a CEF fork release (cmux-next-cef-publish.yml).

  check-cef-sums.py names SHA256SUMS ASSET_NAMES_FILE
      every asset of the release whose name contains .tar.xz (one name per
      line) is listed, and every listed archive is an asset
  check-cef-sums.py files SHA256SUMS DIR
      DIR holds exactly SHA256SUMS and the listed archives, each with its
      listed sha256

Every non-empty line must be `<64 lowercase hex><space><space or *><name>`,
with a plain file name ending in .tar.xz and no name twice; anything else
(a malformed line, trailing space, a path, another file type) is refused, so
no archive is uploaded without its digest being checked.
"""
import hashlib
import os
import re
import sys

LINE = re.compile(r"^([0-9a-f]{64}) [ *]([A-Za-z0-9][A-Za-z0-9._+-]*\.tar\.xz)$")


def fail(message):
    print(f"check-cef-sums: {message}", file=sys.stderr)
    sys.exit(1)


def parse(path):
    sums = {}
    with open(path, "rb") as f:
        data = f.read()
    try:
        text = data.decode("ascii")
    except UnicodeDecodeError:
        fail("SHA256SUMS is not ASCII")
    for number, line in enumerate(text.split("\n"), 1):
        if line == "":
            continue
        match = LINE.match(line)
        if not match:
            fail(f"SHA256SUMS line {number} is malformed: {line!r}")
        digest, name = match.groups()
        if name in sums:
            fail(f"{name} is listed twice")
        sums[name] = digest
    if not sums:
        fail("SHA256SUMS lists no .tar.xz archive")
    return sums


def main(argv):
    if len(argv) != 4 or argv[1] not in ("names", "files"):
        fail(__doc__.strip().splitlines()[2].strip())
    mode, sums_path, other = argv[1:]
    sums = parse(sums_path)
    if mode == "names":
        with open(other, encoding="utf-8") as f:
            # Any asset that looks like an archive, also with trailing junk.
            present = {n for n in f.read().split("\n") if ".tar.xz" in n}
    else:
        # Everything in the directory but SHA256SUMS itself.
        present = {n for n in os.listdir(other) if n != "SHA256SUMS"}
        if any(not os.path.isfile(os.path.join(other, n)) or os.path.islink(os.path.join(other, n)) for n in present):
            fail("a file in the asset directory is not a regular file")
    if present != set(sums):
        fail(f"archives {sorted(present)} are not exactly those listed {sorted(sums)}")
    if mode == "files":
        for name, digest in sorted(sums.items()):
            h = hashlib.sha256()
            with open(os.path.join(other, name), "rb") as f:
                for chunk in iter(lambda: f.read(1 << 20), b""):
                    h.update(chunk)
            if h.hexdigest() != digest:
                fail(f"{name} has sha256 {h.hexdigest()}, SHA256SUMS lists {digest}")
    for name in sorted(sums):
        print(f"{name} {sums[name]}")


if __name__ == "__main__":
    main(sys.argv)
