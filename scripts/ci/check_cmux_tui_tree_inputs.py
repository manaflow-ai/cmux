#!/usr/bin/env python3
"""Fail when a cmux-tui crate embeds a file that the tree key does not cover.

The published cmux-tui binary is reused by every commit with the same tree key
(scripts/ci/cmux_tui_tree_key.py over scripts/cmux-next/cmux-tui-tree-inputs.txt).
A file that a crate compiles in with include_str!/include_bytes! but that the key
does not cover lets a commit that changes only that file reuse a binary built
from the old file (cx-t3e5, 2026-10-08: plans/cmux-next/action-surfaces.json,
schemas/*, skills/cmux-browser/*). This check resolves every embed in
cmux-tui/**/*.rs (a literal path, concat!(env!("CARGO_MANIFEST_DIR"), ...), or a
concat! whose first literal names a directory, across lines) and requires each
target to lie under a `tree` or `gitlink` input or to be a `blob` input.
OUT_DIR embeds are the crate's own build output; build.rs files are skipped (the
code they generate embeds build outputs). An embed form it cannot resolve fails.

Usage: check_cmux_tui_tree_inputs.py [--root DIR]   (exit 1 lists what to add)
"""
from __future__ import annotations

import argparse
import os
import re
import subprocess
import sys
from pathlib import Path

CALL = re.compile(r"include_(?:str|bytes)!\s*\(", re.S)
LITERAL = re.compile(r'\s*"([^"]+)"\s*\)', re.S)
MANIFEST_DIR = re.compile(r'\s*concat!\s*\(\s*env!\s*\(\s*"CARGO_MANIFEST_DIR"\s*\)\s*,\s*"([^"]+)"\s*\)\s*\)', re.S)
OUT_DIR = re.compile(r'\s*concat!\s*\(\s*env!\s*\(\s*"OUT_DIR"\s*\)', re.S)
CONCAT_PREFIX = re.compile(r'\s*concat!\s*\(\s*"([^"]+)"', re.S)


def inputs(root: Path) -> tuple[list[str], set[str]]:
    dirs, blobs = [], set()
    for raw in (root / "scripts/cmux-next/cmux-tui-tree-inputs.txt").read_text().splitlines():
        raw = raw.strip()
        if not raw or raw.startswith("#"):
            continue
        kind, path = raw.split(maxsplit=1)
        (blobs.add(path) if kind == "blob" else dirs.append(path))
    return dirs, blobs


def embeds(root: Path) -> tuple[set[str], list[str]]:
    files = subprocess.run(["git", "-C", str(root), "ls-files", "-z", "--", "cmux-tui/*.rs"],
                           capture_output=True, check=True).stdout.decode().split("\0")
    manifests = {os.path.dirname(p) for p in subprocess.run(
        ["git", "-C", str(root), "ls-files", "--", "cmux-tui/*Cargo.toml"],
        capture_output=True, text=True, check=True).stdout.splitlines()}

    def crate_dir(path: str) -> str:
        d = os.path.dirname(path)
        while d and d not in manifests:
            d = os.path.dirname(d)
        return d

    targets, problems = set(), []
    for path in files:
        if not path or os.path.basename(path) == "build.rs":
            continue
        text = (root / path).read_text(encoding="utf-8", errors="replace")
        if "include_" not in text:
            continue
        for call in CALL.finditer(text):
            rest = text[call.end():call.end() + 400]
            line = text.count("\n", 0, call.start()) + 1
            if (m := LITERAL.match(rest)):
                target = os.path.normpath(os.path.join(os.path.dirname(path), m.group(1)))
            elif (m := MANIFEST_DIR.match(rest)):
                target = os.path.normpath(os.path.join(crate_dir(path), m.group(1).lstrip("/")))
            elif OUT_DIR.match(rest):
                continue
            elif (m := CONCAT_PREFIX.match(rest)) and "/" in m.group(1):
                target = os.path.normpath(os.path.join(os.path.dirname(path), m.group(1).rsplit("/", 1)[0]))
            else:
                problems.append(f"{path}:{line}: an include_str!/include_bytes! form this check cannot resolve")
                continue
            if target == ".." or target.startswith("../"):
                problems.append(f"{path}:{line}: embeds {target}, outside the repository")
            else:
                targets.add(target)
    return targets, problems


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--root", default=str(Path(__file__).resolve().parents[2]))
    root = Path(ap.parse_args().root)
    dirs, blobs = inputs(root)
    targets, problems = embeds(root)
    missing = sorted(t for t in targets
                     if t not in blobs and not any(t == d or t.startswith(d + "/") for d in dirs))
    for p in problems:
        print(f"error: {p}", file=sys.stderr)
    if missing:
        print("error: cmux-tui crates embed files the cmux-tui tree key does not cover. Add these lines to "
              "scripts/cmux-next/cmux-tui-tree-inputs.txt and the same paths to the pull_request_target "
              "paths of .github/workflows/cmux-tui-artifacts.yml:", file=sys.stderr)
        for t in missing:
            kind = "tree" if (root / t).is_dir() else "blob"
            print(f"{kind} {t}", file=sys.stderr)
    if problems or missing:
        return 1
    print(f"cmux-tui tree key covers all {len(targets)} embedded files")
    return 0


if __name__ == "__main__":
    sys.exit(main())
