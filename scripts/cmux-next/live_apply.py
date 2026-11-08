#!/usr/bin/env python3
"""What a running cmux NEXT app could take from a change without a new build (try-pr.sh).

    live_apply.py [--repo DIR] [--json] BASE HEAD

Reads `git diff BASE HEAD` (no GitHub API) and prints the verdict of the heaviest change in it:

  no-app      docs, CI, tests, scripts, website and backend only: nothing in the app changes
  web-live    plus the app's web bundles (webviews/): hot-swapped into the running app
  daemon      plus Rust (cmux-tui, acpmux): a daemon or CLI restart with the change's binary
  swift-live  plus app Swift changed only inside function bodies and computed properties, or new
              Swift files (the patch carries them: Prototypes/ViewShell/inject.sh), in a module the
              live code build patches (LIVE_MODULE)
  rebuild     a new binary: a stored property, a changed signature, a new type, conformance or
              enum case in an existing file, a new entry point (`@main`), a resource, manifest,
              plist or entitlement, or Swift in a module live code does not patch
  ios-only    iOS only: the Mac app does not change

The rules are regular expressions over the diff lines, checked by hand on 20 merged PRs (19 right):
leo-workspace research/2026-11-04-try-pr-live-apply.md. A miss in either direction is about 3
points, so a `swift-live` verdict is a hint for a person, never a license to load a patch blind.
"""
import argparse
import json
import os
import re
import subprocess
import sys

# Folders and files that never ship in the app, checked before everything else.
NOAPP_PATH = re.compile(r"(^|/)(docs?|plans|research|\.github|tests?|Tests|UITests|scripts|skills|release-notes|schemas|fixtures|bench|benchmarks|tools|build-fleet)(/|$)|^(web|backend|workers|services|cmux-tui/relays)/|(^|/)CHANGELOG|LICENSE|\.gitignore$|\.test\.(ts|tsx)$|\.gallery\.(ts|tsx|css)$|/gallery/")
# Extensions that change nothing in the app, checked after the web, resource and Rust rules, so a
# Cargo.lock, a bundled Resources/x.sh or webviews' vite.config.mjs still counts.
NOAPP_EXT = re.compile(r"\.(md|txt|yml|yaml|toml|lock|sh|py|mjs)$")
WEB = re.compile(r"^(webviews|cmux-tui/frontends/web)/")
RUST = re.compile(r"\.rs$|(^|/)Cargo\.toml$|^cmux-tui/|^acpmux/")
IOS = re.compile(r"^(ios|cmux-next-ios|Packages/iOS)/")
REBUILD_FILE = re.compile(r"\.(xcstrings|strings|xcassets|plist|entitlements|pbxproj|xcconfig|storyboard|xib|metal|png|pdf|car|icns)$|(^|/)Package\.(swift|resolved)$|Contents\.json$|\.xcodeproj/|/Resources/|^ghostty|\.(c|h|m|mm|zig)$")
COMMENT = re.compile(r"^\s*(//|/\*|\*|\*/)")
STORED = re.compile(r"^(\s*)(@\w+(\([^)]*\))?\s+)*((public|private|fileprivate|internal|package|open|final|static|nonisolated|lazy|weak|unowned|override)(\([^)]*\))?\s+)*(let|var)\s+\w+[^{]*$")
FUNC = re.compile(r"^\s*(@\w+(\([^)]*\))?\s+)*((public|private|fileprivate|internal|package|open|final|static|class|override|mutating|nonisolated|required|convenience)(\([^)]*\))?\s+)*(func\s+\w+|init[?!]?\s*[(<]|subscript\s*[(<])")
TYPE_DECL = re.compile(r"^\s*(@\w+(\([^)]*\))?\s+)*((public|private|fileprivate|internal|package|open|final|indirect)\s+)*(struct|class|enum|actor|protocol|extension)\s+\w+")
ENTRY = re.compile(r"^\s*(@\w+(\([^)]*\))?\s+)*@main\b")
# The modules a patch can replace code in: the app's live code build makes every CmuxNext module's
# symbols interposable (live_code_targets in scripts/live-code/lib/xcodebuild-args.sh: the
# CmuxNext targets of Packages/macOS/CmuxNext/Package.swift), and the view shell's inject.sh patches
# its own module. Third-party modules are linked into the app as they were built.
LIVE_MODULE = re.compile(r"^(CmuxNext[A-Za-z0-9_]*|ViewShell)$")
LIVE_PACKAGE = re.compile(r"(?:^|/)Packages/macOS/CmuxNext/Sources/|(?:^|/)Prototypes/ViewShell/Sources/")
SWIFT_MODULE = re.compile(r"(?:^|/)Sources/([^/]+)/")
CASE = re.compile(r"^ {4}(\t)?case\s+\w+|^\tcase\s+\w+")

# Heaviest first: a change takes the verdict of its heaviest file.
ORDER = ["rebuild", "swift-live", "daemon", "web-live", "ios-only", "no-app"]


def swift_reasons(lines, added_file):
    """Why a Swift file's change needs a rebuild; empty when it only changes function bodies.
    `lines` are the diff's ("+" or "-", text) pairs."""
    if added_file:
        # Its types and functions are new symbols that live only in the patch, with the edited
        # files that use them; the running build has nothing of them to replace. An entry point
        # is the one thing a patch cannot add.
        return ["new entry point"] if any(sign == "+" and ENTRY.match(text) for sign, text in lines) else []
    reasons = set()
    removed, added = [], []
    for sign, line in lines:
        body = line.rstrip()
        if not body.strip() or COMMENT.match(body):
            continue
        indent = len(body) - len(body.lstrip(" "))
        if ENTRY.match(body) and sign == "+":
            reasons.add("new entry point")
        elif TYPE_DECL.match(body):
            reasons.add("type or conformance")
        elif STORED.match(body) and indent <= 4 and not body.endswith("{"):
            reasons.add("stored property")  # member level (one indent) or a global
        elif CASE.match(body) and indent == 4:
            reasons.add("enum case")
        elif FUNC.match(body):
            sig = re.sub(r"\s+", " ", body.strip().rstrip("{").strip())
            (removed if sign == "-" else added).append(sig)
    if set(removed) - set(added):
        reasons.add("signature")  # one went away or changed; a new function alone is fine
    return sorted(reasons)


def classify(files, diffs):
    """`files`: (status letter, path) pairs, as `git diff --name-status --no-renames`.
    `diffs`: path -> ("+" or "-", text) pairs of that Swift file's `-U0` diff.
    Returns {"verdict", "reasons": {reason: [paths]}, "files": {kind: [paths]}}."""
    kinds, reasons = {}, {}

    def note(kind, path, why=None):
        kinds.setdefault(kind, []).append(path)
        if why:
            reasons.setdefault(why, []).append(path)

    for status, path in files:
        if IOS.search(path):
            note("ios-only", path)
        elif NOAPP_PATH.search(path):
            note("no-app", path)
        elif WEB.search(path):
            note("web-live", path)
        elif REBUILD_FILE.search(path):
            note("rebuild", path, "resource or manifest")
        elif RUST.search(path):
            note("daemon", path)
        elif NOAPP_EXT.search(path):
            note("no-app", path)
        elif path.endswith(".swift"):
            # A deleted file's code stays in the running binary, and nothing calls it any more.
            why = [] if status == "D" else swift_reasons(diffs.get(path, []), status == "A")
            if status == "A" and os.path.basename(path) == "main.swift":
                why = ["new entry point"]
            module = SWIFT_MODULE.search(path)
            live = module is not None and LIVE_MODULE.match(module.group(1)) and LIVE_PACKAGE.search(path)
            if status != "D" and not why and not live:
                why = [f"outside the live code modules ({module.group(1) if module else path})"]
            for reason in why:
                note("rebuild", path, reason)
            if not why:
                note("swift-live", path)
        else:
            note("rebuild", path, "other app file")
    verdict = next((v for v in ORDER if v in kinds), "no-app")
    return {"verdict": verdict, "reasons": {k: sorted(set(v)) for k, v in reasons.items()},
            "files": {k: sorted(set(v)) for k, v in kinds.items()}}


def parse_name_status(text):
    files = []
    for line in text.splitlines():
        parts = line.split("\t")
        if len(parts) >= 2 and parts[0]:
            files.append((parts[0][0], parts[-1]))
    return files


def parse_diff(text):
    """path -> ("+" or "-", text) pairs, from a unified diff."""
    diffs, current = {}, None
    for line in text.splitlines():
        if line.startswith("+++ "):
            current = line[6:] if line.startswith("+++ b/") else None
            if current:
                diffs.setdefault(current, [])
        elif line.startswith("--- "):
            continue
        elif current and line[:1] in ("+", "-"):
            diffs[current].append((line[0], line[1:]))
    return diffs


def classify_range(repo, base, head):
    def git(*args):
        return subprocess.run(["git", "-C", repo, *args], check=True, capture_output=True, text=True,
                              errors="replace").stdout
    files = parse_name_status(git("diff", "--name-status", "--no-renames", base, head))
    swift = [p for s, p in files if p.endswith(".swift") and s != "D"]
    diffs = parse_diff(git("diff", "-U0", "--no-renames", base, head, "--", *swift)) if swift else {}
    return classify(files, diffs)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--repo", default=os.getcwd())
    parser.add_argument("--json", action="store_true")
    parser.add_argument("base")
    parser.add_argument("head")
    args = parser.parse_args(argv)
    result = classify_range(args.repo, args.base, args.head)
    if args.json:
        print(json.dumps(result, indent=2))
        return 0
    print(result["verdict"])
    for reason, paths in sorted(result["reasons"].items()):
        print(f"  {reason}: {', '.join(paths[:5])}{' …' if len(paths) > 5 else ''}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
