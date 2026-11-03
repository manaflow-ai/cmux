#!/usr/bin/env python3
"""A toast's button never sends the person to Settings in place of what the toast is about.

Leo, 2026-10-29: "the details are stupid because it takes you to settings"; 2026-11-01:
"clicking details on the bottom toast still only sends me to settings for no reason". A toast's
action opens what the toast names (the session, the PR, the error or the log, or the detail in the
toast itself, `CmuxToast.Action.details`), never Settings as a stand-in.

  swift  CmuxNext sources: a toast handle's `onAction` closure (its body, up to the closing brace
         at its own indent) that opens Settings (`settingsWindow.show(`, `perform("openSettings"`).

A toast that is about a setting (a refused value, say) may open that setting: mark the `onAction`
line `toast-target-allow: <reason>`. Exits 1 with one line per hit; 0 when clean.

  python3 scripts/cmux-next/check-toast-targets.py [--root DIR]
"""
import argparse
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.abspath(os.path.join(HERE, "..", ".."))
SWIFT_TREE = "Packages/macOS/CmuxNext/Sources"

ON_ACTION = re.compile(r"\bonAction\s*=\s*\{")
OPENS_SETTINGS = re.compile(r"settingsWindow\s*\.\s*show\s*\(|perform\(\s*\"openSettings\"")
ALLOW = "toast-target-allow:"


def closure_body(lines, start):
    """The lines of the closure opened on `lines[start]`, through its closing brace."""
    depth = 0
    body = []
    for line in lines[start:]:
        body.append(line)
        depth += line.count("{") - line.count("}")
        if depth <= 0:
            break
    return body


def scan_swift(text, path):
    hits = []
    lines = text.splitlines()
    for index, line in enumerate(lines):
        if not ON_ACTION.search(line) or ALLOW in line:
            continue
        for offset, body_line in enumerate(closure_body(lines, index)):
            if OPENS_SETTINGS.search(body_line):
                hits.append(f"{path}:{index + offset + 1}: a toast's action opens Settings instead of what the toast names")
                break
    return hits


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--root", default=REPO)
    args = parser.parse_args(argv)
    tree = os.path.join(args.root, SWIFT_TREE)
    if not os.path.isdir(tree):
        print(f"check-toast-targets: no {SWIFT_TREE} under {args.root}", file=sys.stderr)
        return 2
    hits = []
    for folder, _, files in os.walk(tree):
        for name in sorted(files):
            if not name.endswith(".swift"):
                continue
            full = os.path.join(folder, name)
            with open(full, encoding="utf-8") as handle:
                hits += scan_swift(handle.read(), os.path.relpath(full, args.root))
    if hits:
        print("\n".join(sorted(hits)))
        print(
            f"check-toast-targets: {len(hits)} toast action(s) open Settings. A toast's button opens what the toast"
            f" names (its session, PR, error or log, or the detail in the toast: CmuxToast.Action.details), never"
            f" Settings as a stand-in. A toast about a setting marks its onAction `{ALLOW} <reason>`."
        )
        return 1
    print("check-toast-targets: no toast action opens Settings")
    return 0


if __name__ == "__main__":
    sys.exit(main())
