#!/usr/bin/env python3
"""Fail when a production web bundle still reads `import.meta.env`.

A bundler that is not told what `import.meta.env` is leaves it as written, and in the
app's pages it is undefined at run time: the agent pane's `import.meta.env.DEV` threw
on every handshake and the pane sat on "Reconnecting..." (cmux#50616, fixed by
cmux#51194). The production builds substitute it (webviews/scripts/productionDefine.mjs,
Vite's own build); this check runs on what they wrote, so any builder that misses it
fails the build. `import.meta.url` and other `import.meta` reads are fine.

    check-bundle-import-meta-env.py PATH...   # files or directories, scanned recursively

Scans .js, .mjs, .cjs and .html files (source maps hold the original source and are
skipped). Exits 1 naming each file, line and a snippet; 0 when there is none.
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

# `<define:import.meta.env>` is the name esbuild gives the module a define injects, as a source
# map or chunks/frame-sites.js lists it: a string, not a read.
PATTERN = re.compile(r"(?<!<define:)\bimport\s*\.\s*meta\s*(?:\?\.|\.)\s*env\b")
SUFFIXES = {".js", ".mjs", ".cjs", ".html"}


def files(paths: list[str]) -> list[Path]:
    out: list[Path] = []
    for arg in paths:
        path = Path(arg)
        if path.is_dir():
            out.extend(sorted(p for p in path.rglob("*") if p.is_file() and p.suffix in SUFFIXES))
        elif path.is_file():
            out.append(path)
        else:
            raise SystemExit(f"error: no such file or directory: {arg}")
    return out


def findings(path: Path) -> list[str]:
    text = path.read_text(encoding="utf-8", errors="replace")
    found = []
    for match in PATTERN.finditer(text):
        line = text.count("\n", 0, match.start()) + 1
        snippet = text[max(0, match.start() - 40) : match.end() + 40].replace("\n", " ")
        found.append(f"{path}:{line}: {snippet}")
    return found


def main(argv: list[str]) -> int:
    if not argv:
        print("usage: check-bundle-import-meta-env.py PATH...", file=sys.stderr)
        return 2
    problems = [finding for path in files(argv) for finding in findings(path)]
    if not problems:
        return 0
    print(
        "error: a production web bundle still reads import.meta.env, which is undefined at run time "
        "(cmux#50616). Give its builder webviews/scripts/productionDefine.mjs's define:",
        file=sys.stderr,
    )
    for problem in problems:
        print(f"  {problem}", file=sys.stderr)
    return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
