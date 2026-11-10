#!/usr/bin/env python3
"""Whether the app FFI at NEW only adds to the app FFI at OLD, as the Swift build sees it.

    python3 -I scripts/cmux-next/app_ffi_additive.py OLD NEW -- PATH...

PATH... are the FFI inputs (scripts/cmux-next/check-app-ffi-pin.sh --list-inputs). Additive means all of:

- Packaging is unchanged: the files that decide which headers ship, under which module names and module maps, and how
  the archive is built (PACKAGING: build-app-ffi.sh, the mtime stamp and the toolchain, and any module map or cbindgen.toml under PATH...) are the same at OLD and NEW. A
  module map edit in build-app-ffi.sh keeps every header and still breaks every Swift `import`.
- Every `.h` under PATH... at OLD still exists at NEW.
- Each such header has the same preprocessor directives at NEW, in the same order and under the same conditionals
  (`#define`, `#include`, `#pragma` and the `#if` lines themselves): a directive can change what an unchanged
  declaration means (a `#pragma pack`, a macro, a new condition).
- Each top-level declaration of OLD (a prototype, a whole struct or enum, a typedef), comments and whitespace runs
  aside, appears at NEW unchanged, under the same enclosing conditionals and after the same directives. Wrapping an
  existing prototype in `#if defined(X)` moves it, so it is not additive; a field added to a struct changes that
  struct's declaration, so it is not additive either.

New headers and new declarations are fine: the app built against OLD calls only what OLD declared, and NEW still
declares it the same way, in the same place, through the same modules.

pin-app-ffi-on-base.sh pins a new release straight on feat-cmux-next only when this holds (exit 0). Otherwise (exit
1, naming the first differences) the re-pin pull request carries the pin, so the app compile proves the Swift side
before it lands. Any other failure exits 2, which the caller treats like 1.
"""
from __future__ import annotations

import re
import subprocess
import sys

LIMIT = 10  # differences named when the FFI is not additive
# How the archive and its modules are made, wherever the FFI inputs are. build-app-ffi.sh names every shipped header
# and writes the module maps. Not app-ffi-release.yml: most of its edits are push paths for a new crate, and its
# assemble step only checks, stamps and zips what build-app-ffi.sh made.
PACKAGING = (
    "scripts/cmux-next/build-app-ffi.sh",
    "scripts/cmux-next/stamp-app-ffi-mtimes.sh",
    "cmux-tui/rust-toolchain.toml",
)
PACKAGING_NAMES = ("*.modulemap", "module.map", "cbindgen.toml")
CONDITIONAL = re.compile(r"#\s*(if|ifdef|ifndef|elif|elifdef|elifndef|else|endif)\b")


def git(*args: str) -> str:
    return subprocess.run(["git", *args], check=True, capture_output=True, text=True).stdout


def headers(commit: str, paths: list[str]) -> list[str]:
    names = git("ls-tree", "-r", "--name-only", commit, "--", *paths).splitlines()
    return sorted(name for name in names if name.endswith(".h"))


def packaging_changes(old: str, new: str, paths: list[str]) -> list[str]:
    specs = list(PACKAGING) + [f":(glob){path.rstrip('/')}/**/{name}" for path in paths for name in PACKAGING_NAMES]
    return sorted(set(git("diff", "--name-only", old, new, "--", *specs).splitlines()))


def strip(text: str) -> str:
    text = text.replace("\\\n", " ")
    text = re.sub(r"/\*.*?\*/", " ", text, flags=re.S)
    text = re.sub(r"//[^\n]*", " ", text)
    # C++-only lines (the `extern "C" {` and its `}` that cbindgen wraps a header in): Swift imports the header as
    # C, and the brace would otherwise make the whole header one declaration.
    return re.sub(r"^[ \t]*#[ \t]*if(?:def[ \t]+__cplusplus|[ \t]+defined\(?[ \t]*__cplusplus[ \t]*\)?)[^\n]*\n.*?"
                  r"^[ \t]*#[ \t]*endif[^\n]*$", " ", text, flags=re.S | re.M)


def parse(text: str) -> tuple[list[tuple[tuple[str, ...], str]], set[tuple[tuple[str, ...], int, str]]]:
    """(directives, declarations) of a C header. A directive is (its enclosing conditionals, its text), in order. A
    declaration is (its enclosing conditionals, how many directives come before it, its text)."""
    directives: list[tuple[tuple[str, ...], str]] = []
    found: set[tuple[tuple[str, ...], int, str]] = set()
    stack: list[str] = []
    current: list[str] = []
    depth = 0
    for line in strip(text).splitlines():
        if depth == 0 and not "".join(current).strip() and line.strip().startswith("#"):
            directive = " ".join(line.split())
            directives.append((tuple(stack), directive))
            kind = CONDITIONAL.match(directive)
            if kind and kind.group(1) in ("if", "ifdef", "ifndef"):
                stack.append(directive)
            elif kind and kind.group(1) == "endif":
                if stack:
                    stack.pop()
            elif kind and stack:  # elif, else: the same block, another branch
                stack[-1] = f"{stack[-1]} | {directive}"
            continue
        for ch in line + "\n":
            current.append(ch)
            if ch == "{":
                depth += 1
            elif ch == "}":
                depth = max(depth - 1, 0)
            elif ch == ";" and depth == 0:
                found.add((tuple(stack), len(directives), " ".join("".join(current).split())))
                current = []
    rest = " ".join("".join(current).split())
    if rest:
        found.add((tuple(stack), len(directives), rest))
    return directives, found


def where(stack: tuple[str, ...]) -> str:
    return f" (under {' > '.join(stack)})" if stack else ""


def differences(old: str, new: str, paths: list[str]) -> list[str]:
    found = [f"{path}: packaging changed" for path in packaging_changes(old, new, paths)]
    new_headers = set(headers(new, paths))
    for header in headers(old, paths):
        if header not in new_headers:
            found.append(f"{header}: the header is gone")
            continue
        old_directives, old_declarations = parse(git("show", f"{old}:{header}"))
        new_directives, new_declarations = parse(git("show", f"{new}:{header}"))
        if old_directives != new_directives:
            changed = next((i for i, pair in enumerate(zip(old_directives, new_directives)) if pair[0] != pair[1]),
                           min(len(old_directives), len(new_directives)))
            was = old_directives[changed][1] if changed < len(old_directives) else "(none)"
            now = new_directives[changed][1] if changed < len(new_directives) else "(none)"
            found.append(f"{header}: preprocessor directives changed, first at #{changed + 1}: {was!r} -> {now!r}")
            continue
        for stack, _, declaration in sorted(old_declarations - new_declarations):
            found.append(f"{header}: {declaration[:200]}{where(stack)}")
    return found


def main(argv: list[str]) -> int:
    if len(argv) < 4 or argv[2] != "--":
        print(__doc__.strip().splitlines()[2].strip(), file=sys.stderr)
        return 2
    old, new, paths = argv[0], argv[1], argv[3:]
    try:
        found = differences(old, new, paths)
    except subprocess.CalledProcessError as error:
        print(f"error: git {' '.join(error.cmd[1:])}: {error.stderr.strip()}", file=sys.stderr)
        return 2
    if found:
        print(f"the app FFI at {new[:12]} drops or changes {len(found)} thing(s) of {old[:12]}:")
        for line in found[:LIMIT]:
            print(f"  {line}")
        if len(found) > LIMIT:
            print(f"  ... and {len(found) - LIMIT} more")
        return 1
    print(f"the app FFI at {new[:12]} keeps every declaration, directive and packaging input of {old[:12]}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
