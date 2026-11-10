#!/usr/bin/env python3
"""Whether the app FFI's C headers at NEW keep every declaration they had at OLD.

    python3 -I scripts/cmux-next/app_ffi_additive.py OLD NEW -- PATH...

PATH... are the FFI inputs (scripts/cmux-next/check-app-ffi-pin.sh --list-inputs). Every `.h` under them at OLD
must still exist at NEW, and each of its top-level declarations (a prototype, a whole struct or enum, a typedef, a
preprocessor line), comments and whitespace aside, must appear unchanged in the same header at NEW. New headers and
new declarations are fine: the app built against OLD calls only what OLD declared, and NEW still declares it the same
way. A field added to a struct changes that struct's declaration, so it is not additive.

pin-app-ffi-on-base.sh pins a new release straight on feat-cmux-next only when this holds (exit 0). Otherwise (exit
1, naming the first declarations that went) the re-pin pull request carries the pin, so the app compile proves the
Swift side before it lands. Any other failure exits 2, which the caller treats like 1.
"""
from __future__ import annotations

import re
import subprocess
import sys

LIMIT = 10  # declarations named when the headers are not additive


def git(*args: str) -> str:
    return subprocess.run(["git", *args], check=True, capture_output=True, text=True).stdout


def headers(commit: str, paths: list[str]) -> list[str]:
    names = git("ls-tree", "-r", "--name-only", commit, "--", *paths).splitlines()
    return sorted(name for name in names if name.endswith(".h"))


def declarations(text: str) -> set[str]:
    """The top-level declarations of a C header, each with its whitespace collapsed."""
    text = text.replace("\\\n", " ")
    text = re.sub(r"/\*.*?\*/", " ", text, flags=re.S)
    text = re.sub(r"//[^\n]*", " ", text)
    # C++-only lines (the `extern "C" {` and its `}` that cbindgen wraps a header in): Swift imports the header as
    # C, and the brace would otherwise make the whole header one declaration.
    text = re.sub(r"^[ \t]*#[ \t]*if(?:def[ \t]+__cplusplus|[ \t]+defined\(?[ \t]*__cplusplus[ \t]*\)?)[^\n]*\n.*?^[ \t]*#[ \t]*endif[^\n]*$",
                  " ", text, flags=re.S | re.M)
    found: set[str] = set()
    current: list[str] = []
    depth = 0
    for line in text.splitlines():
        if depth == 0 and not "".join(current).strip() and line.strip().startswith("#"):
            found.add(" ".join(line.split()))
            continue
        for ch in line + "\n":
            current.append(ch)
            if ch == "{":
                depth += 1
            elif ch == "}":
                depth = max(depth - 1, 0)
            elif ch == ";" and depth == 0:
                found.add(" ".join("".join(current).split()))
                current = []
    rest = " ".join("".join(current).split())
    if rest:
        found.add(rest)
    return found


def missing(old: str, new: str, paths: list[str]) -> list[str]:
    gone: list[str] = []
    new_headers = set(headers(new, paths))
    for header in headers(old, paths):
        if header not in new_headers:
            gone.append(f"{header}: the header is gone")
            continue
        kept = declarations(git("show", f"{new}:{header}"))
        for declaration in sorted(declarations(git("show", f"{old}:{header}")) - kept):
            gone.append(f"{header}: {declaration[:200]}")
    return gone


def main(argv: list[str]) -> int:
    if len(argv) < 4 or argv[2] != "--":
        print(__doc__.strip().splitlines()[2].strip(), file=sys.stderr)
        return 2
    old, new, paths = argv[0], argv[1], argv[3:]
    try:
        gone = missing(old, new, paths)
    except subprocess.CalledProcessError as error:
        print(f"error: git {' '.join(error.cmd[1:])}: {error.stderr.strip()}", file=sys.stderr)
        return 2
    if gone:
        print(f"the app FFI headers at {new[:12]} drop or change {len(gone)} declaration(s) of {old[:12]}:")
        for line in gone[:LIMIT]:
            print(f"  {line}")
        if len(gone) > LIMIT:
            print(f"  ... and {len(gone) - LIMIT} more")
        return 1
    print(f"the app FFI headers at {new[:12]} keep every declaration of {old[:12]}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
