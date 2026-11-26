#!/usr/bin/env python3
"""No key in the agent pane's string catalog goes unused.

A key whose last use was deleted stays in `webviews/src/agent-session/acpmux/Localizable.xcstrings.d/` (one file per key)
with its text in every language: translators keep paying for it, a search for a sentence finds a
string nothing shows, and an audit of what the chat says reads text a person never sees (the
2026-11-17 ceremony audit found 190 such keys, among them error text whose screen was gone).

A key counts as used when any tracked source file outside string catalogs names it in quotes
(`"key"`, `'key'` or a backtick string), or when a template literal builds it from a named prefix
(`t(\\`tools.harness.${stem}.done\\`)` uses every `tools.harness.` key). Galleries and tests count.

Exits 1 with one line per unused key; 0 when every key is named.

  python3 scripts/cmux-next/check-catalog-unused-keys.py [--root DIR]
"""
from __future__ import annotations

import argparse
import os
import re
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.abspath(os.path.join(HERE, "..", ".."))
CATALOG = "webviews/src/agent-session/acpmux/Localizable.xcstrings.d"
ENTRY = ".xcstrings"
SOURCE_SUFFIXES = (".ts", ".tsx", ".mts", ".js", ".mjs", ".swift", ".rs")
QUOTED = re.compile(r"[\"'`]([A-Za-z][\w-]*(?:\.[\w-]+)*)[\"'`]")
TEMPLATE_PREFIX = re.compile(r"`([A-Za-z][\w-]*(?:\.[\w-]+)*\.)\$\{")
PLURAL = {"zero", "one", "two", "few", "many", "other"}


def sources(root: str) -> list[str]:
    out = subprocess.run(
        ["git", "-C", root, "ls-files", "-z", "--", "webviews", "Packages", "Sources", "cmux-tui/crates"],
        check=True,
        capture_output=True,
    ).stdout
    return [p for p in out.decode().split("\0") if p.endswith(SOURCE_SUFFIXES) and "/node_modules/" not in p]


def unused_keys(root: str) -> list[str]:
    # One file per key (scripts/cmux-next/string_catalogs.py): a key is its file's name.
    keys = [name[: -len(ENTRY)] for name in os.listdir(os.path.join(root, CATALOG)) if name.endswith(ENTRY)]
    named: set[str] = set()
    prefixes: set[str] = set()
    for rel in sources(root):
        try:
            with open(os.path.join(root, rel), encoding="utf-8") as f:
                text = f.read()
        except (OSError, UnicodeDecodeError):
            continue
        named.update(QUOTED.findall(text))
        prefixes.update(TEMPLATE_PREFIX.findall(text))
    unused = []
    for key in keys:
        if key in named or any(key.startswith(prefix) for prefix in prefixes):
            continue
        parent, _, last = key.rpartition(".")
        if last in PLURAL and parent in named:
            continue
        unused.append(key)
    return sorted(unused)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--root", default=REPO)
    root = parser.parse_args().root
    unused = unused_keys(root)
    for key in unused:
        print(f"{CATALOG}/{key}{ENTRY}: key {key} is named by no source file; delete its file with its last use")
    return 1 if unused else 0


if __name__ == "__main__":
    sys.exit(main())
