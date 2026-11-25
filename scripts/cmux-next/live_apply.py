#!/usr/bin/env python3
"""What a running cmux NEXT app could take from a change without a new build (try-pr.sh).

    live_apply.py [--repo DIR] [--json] BASE HEAD

Reads `git diff BASE HEAD` (no GitHub API) and prints the verdict of the heaviest change in it:

  no-app      docs, CI, tests, scripts, website and backend only: nothing in the app changes
  web-live    plus the app's web bundles (webviews/, and the TypeScript outside it they import:
              clients/ts, config/vite-plus): hot-swapped into the running app
  strings     plus string catalogs (.xcstrings): a copy of the NIGHTLY shows the change's web pages
              (gen-strings.mjs reads the catalogs) and Swift's source strings; Swift's translations
              wait for the next build
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

# The rules live in live-apply-rules.json beside this file, one copy: the cmux-tui daemon's save
# router (`cmux live auto`, cmux-tui-core src/live_auto/rules.rs) classifies each save with the same file.
# What each rule is for:
# NOAPP_PATH: folders and files that never ship in the app, checked before everything else. images/ is the Cloud
# machine image (its bot's image rolls); ci-target-graph.json is CI's test-target map. Root examples/ holds
# sample extensions only a lint reads; cmux-tui/bindings/examples/ is built into the app, so the rule is anchored.
# A *-gallery.html page is a design gallery. The root .gitattributes only sets merge drivers and Linguist
# labels; evals/ (cueval's computer-use tasks) and Native/*/evals/ (the Chief's eval cases, which only its tests,
# examples and backend/scripts read: no include_str! in src/, nothing in build.rs) are eval inputs; dogfood/ held
# scenario files whose runner is gone. design/ holds the sources generators read (design/icons, design/agent-icons:
# their outputs are committed where the app reads them, cmux-icons.json, AgentBrandCatalog+Generated.swift, brand.rs)
# and design pages. vault/ is the cmux-vault Go service (its own go.mod; the app's Rust uses cmux-vault-egress);
# capture-scratch/ holds screenshot replay output. No Xcode phase, Package.swift resource or build script copies any of them.
# NOAPP_EXT: extensions that change nothing in the app, checked after the web, resource and Rust rules, so a
# Cargo.lock, a bundled Resources/x.sh or webviews' vite.config.mjs still counts.
# WEB: the web bundles. clients/ts and config/vite-plus hold TypeScript that only the web bundles import (the Cloud page's wire types,
# clients/ts/cloud/src/generated.ts) or lint with: nothing native reads them (cmux_next_route.py BUNDLE_INPUTS).
# STRINGS: string catalogs. gen-strings.mjs builds the web pages' strings from them, and a Swift string shows its source
# text without the compiled table, so trying the change needs no build; only the translations do.
# REBUILD_FILE, NATIVE_SOURCE, NATIVE_EXEMPT: resources and manifests need a new app, and so do C, Objective-C
# and Zig sources, except under cmux-tui/: the cmux-tui tree build compiles those (a
# companion's shim, the Zig binding), so they are daemon, as hot-apply.py applies them; its linked_rust still leaves
# an app FFI crate's to the ffi part (hot-apply-more-kinds.md in cmuxterm-hq docs/design).
# LIVE_MODULE, LIVE_PACKAGE: the modules a patch can replace code in: the app's live code build makes every CmuxNext module's
# symbols interposable (live_code_targets in scripts/live-code/lib/xcodebuild-args.sh: the
# CmuxNext targets of Packages/macOS/CmuxNext/Package.swift, and MessagesLabHome, the Home transcript
# CmuxNextHome links from Packages/Shared/CmuxMessagesLab), and the view shell's inject.sh patches
# its own module. Third-party modules are linked into the app as they were built.
# ORDER: heaviest first, a change takes the verdict of its heaviest file.
RULES_FILE = os.path.join(os.path.dirname(os.path.abspath(__file__)), "live-apply-rules.json")
with open(RULES_FILE) as _rules_file:
    RULES = json.load(_rules_file)
NOAPP_PATH = re.compile(RULES["noapp_path"])
NOAPP_EXT = re.compile(RULES["noapp_ext"])
WEB = re.compile(RULES["web"])
STRINGS = re.compile(RULES["strings"])
RUST = re.compile(RULES["rust"])
IOS = re.compile(RULES["ios"])
REBUILD_FILE = re.compile(RULES["rebuild_file"])
NATIVE_SOURCE = re.compile(RULES["native_source"])
NATIVE_EXEMPT = re.compile(RULES["native_exempt"])
COMMENT = re.compile(RULES["comment"])
STORED = re.compile(RULES["stored"])
FUNC = re.compile(RULES["func"])
TYPE_DECL = re.compile(RULES["type_decl"])
# A constant with an initializer that belongs to no instance: `static let x = ...` (any access, `nonisolated(unsafe)`
# and the like) or a file-level `let x = ...` (indent 0). It changes no type's size, so a patch can carry it: the patch
# defines the variable and its addressor, the app repoints the addressor, and every caller (patched or not) reaches the
# patch's copy. Only `let`: a `static var` is state a patch would reset, and an instance property changes the layout.
STATIC_LET = re.compile(RULES["static_let"])
FILE_LET = re.compile(RULES["file_let"])
ENTRY = re.compile(RULES["entry"])
LIVE_MODULE = re.compile(RULES["live_module"])
LIVE_PACKAGE = re.compile(RULES["live_package"])
SWIFT_MODULE = re.compile(RULES["swift_module"])
CASE = re.compile(RULES["case"])
ORDER = list(RULES["order"])


def rebuild_file(path):
    """A resource, manifest or native source the app is built from."""
    return bool(REBUILD_FILE.search(path) or (NATIVE_SOURCE.search(path) and not NATIVE_EXEMPT.search(path)))


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
        elif (STATIC_LET.match(body) and indent <= 4) or (FILE_LET.match(body) and indent == 0):
            continue  # a constant of no instance: the patch carries it (see STATIC_LET)
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
        elif STRINGS.search(path):
            note("strings", path)
        elif rebuild_file(path):
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
        elif status == "D":
            # A deleted file of no known kind: the running app keeps what it had, and nothing that ships reads
            # it any more (that reader's own change would be in the diff). A root stray such as OUTPUT or summary.
            note("no-app", path)
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


def ffi_closure(repo):
    """The app FFI archive's inputs and the folders under them Cargo never builds into it."""
    from pathlib import Path  # noqa: PLC0415
    sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "ci"))
    import cmux_next_route  # noqa: PLC0415 - scripts/ci
    root = Path(repo).resolve()
    return {"inputs": list(cmux_next_route.app_ffi_inputs(root)),
            "excluded": list(cmux_next_route.app_ffi_excluded(root))}


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--repo", default=os.getcwd())
    parser.add_argument("--json", action="store_true")
    parser.add_argument("--ffi-closure", action="store_true",
                        help="print {inputs, excluded}: the paths the app FFI archive is built from "
                             "(cmux_next_route.app_ffi_inputs, app_ffi_excluded), for the daemon's save router")
    parser.add_argument("base", nargs="?")
    parser.add_argument("head", nargs="?")
    args = parser.parse_args(argv)
    if args.ffi_closure:
        print(json.dumps(ffi_closure(args.repo)))
        return 0
    if not (args.base and args.head):
        parser.error("BASE and HEAD are required")
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
