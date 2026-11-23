#!/usr/bin/env python3
"""Fail when the host ops the web calls change without a web ABI bump.

Usage: web_abi_gate.py --base BASE --head HEAD [--repo DIR]

`webviews/src/web-abi.json` holds the native interface version the web bundles need. An app serves a
web update, a dev overlay or a customization layer only when its `abi` equals the app's own
(plans/cmux-next/web-ota.md "Native interface"), so a change that makes the web call a host op an
app at the same `abi` lacks must bump it. RFD 0038 (customizations across updates, cmuxterm-hq
docs/rfd) found it bumped by hand with no check: host ops were added and removed for days at abi 7.

A host op here is a `cmux.<area>.<name>` string literal that both the web (webviews/src, outside tests
and the gallery) and the native app (Packages/macOS/CmuxNext/Sources) name. Between BASE and HEAD,
with the same `abi`, this fails on:
  added    an op HEAD's web and app share that BASE's app never named: a web update built at HEAD
           would call it on an app built at BASE, which lacks it;
  removed  an op BASE's web and app shared that HEAD's app no longer names: a layer or overlay built
           at BASE would call it on an app built at HEAD.
A web-only change that starts calling an op the app already served, and a native-only literal, pass.
Ops are matched by name, so a changed op's arguments are not seen; a renamed op is an add and a remove.

The fast gates run it on every pull request into feat-cmux-next (scripts/ci/cmux_next_fast_gates.py).
Fix: bump `abi` in webviews/src/web-abi.json in the same change.
"""
from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
from pathlib import Path

ABI_FILE = "webviews/src/web-abi.json"
LITERAL = r"""["'`]cmux\.[A-Za-z0-9_]+(\.[A-Za-z0-9_]+)+["'`]"""
NAME = re.compile(r"""["'`](cmux\.[A-Za-z0-9_]+(?:\.[A-Za-z0-9_]+)+)["'`]""")
WEB = ("webviews/src/*.ts", "webviews/src/*.tsx", ":!*.test.ts", ":!*.test.tsx", ":!*.gallery.ts",
       ":!*.gallery.tsx", ":!webviews/src/gallery/*")
NATIVE = ("Packages/macOS/CmuxNext/Sources/*.swift",)


def names(repo: Path, rev: str, paths: tuple[str, ...]) -> set[str]:
    """Every `cmux.a.b` string literal in REV's files under PATHS."""
    result = subprocess.run(["git", "-C", str(repo), "grep", "-h", "-I", "-o", "-E", LITERAL, rev, "--", *paths],
                            capture_output=True, text=True)
    if result.returncode not in (0, 1):  # 1: no match
        raise SystemExit(f"web-abi gate: git grep at {rev} failed: {result.stderr.strip()}")
    return {m.group(1) for m in NAME.finditer(result.stdout)}


def abi(repo: Path, rev: str) -> int | None:
    shown = subprocess.run(["git", "-C", str(repo), "show", f"{rev}:{ABI_FILE}"], capture_output=True, text=True)
    return int(json.loads(shown.stdout)["abi"]) if shown.returncode == 0 else None


def changes(repo: Path, base: str, head: str) -> tuple[set[str], set[str]]:
    """(added, removed) host ops between BASE and HEAD (module docstring)."""
    base_web, base_app = names(repo, base, WEB), names(repo, base, NATIVE)
    head_web, head_app = names(repo, head, WEB), names(repo, head, NATIVE)
    added = (head_web & head_app) - base_app
    removed = (base_web & base_app) - head_app
    return added, removed


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n", 1)[0])
    parser.add_argument("--base", required=True)
    parser.add_argument("--head", required=True)
    parser.add_argument("--repo", type=Path, default=Path("."))
    args = parser.parse_args(argv)
    base_abi, head_abi = abi(args.repo, args.base), abi(args.repo, args.head)
    if head_abi is None:
        print(f"web-abi gate: no {ABI_FILE} at {args.head}; nothing to check")
        return 0
    added, removed = changes(args.repo, args.base, args.head)
    if not added and not removed:
        print(f"web-abi gate: host ops unchanged (abi {head_abi})")
        return 0
    lines = [f"  added: {op}" for op in sorted(added)] + [f"  removed: {op}" for op in sorted(removed)]
    if base_abi != head_abi:
        print(f"web-abi gate: host ops changed with abi {base_abi} -> {head_abi}:\n" + "\n".join(lines))
        return 0
    print(f"::error title=web ABI not bumped::host ops the web calls changed and {ABI_FILE} stayed at abi {head_abi}. "
          f"Bump abi in {ABI_FILE} in this change (plans/cmux-next/web-ota.md, Native interface): a web update, "
          "overlay or customization layer at the same abi would call an op the other app lacks.", flush=True)
    print("\n".join(lines))
    return 1


if __name__ == "__main__":
    sys.exit(main())
