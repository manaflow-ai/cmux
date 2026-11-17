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

# Folders and files that never ship in the app, checked before everything else. images/ is the Cloud
# machine image (its bot's image rolls); ci-target-graph.json is CI's test-target map. Root examples/ holds
# sample extensions only a lint reads; cmux-tui/bindings/examples/ is built into the app, so the rule is anchored.
# A *-gallery.html page is a design gallery.
NOAPP_PATH = re.compile(r"(^|/)(docs?|plans|research|\.github|tests?|Tests|UITests|scripts|skills|release-notes|schemas|fixtures|bench|benchmarks|tools|build-fleet)(/|$)|^(web|backend|workers|services|images|examples|cmux-tui/relays)/|(^|/)ci-target-graph\.json$|-gallery\.html$|(^|/)CHANGELOG|LICENSE|\.gitignore$|\.test\.(ts|tsx)$|\.gallery\.(ts|tsx|css)$|/gallery/")
# Extensions that change nothing in the app, checked after the web, resource and Rust rules, so a
# Cargo.lock, a bundled Resources/x.sh or webviews' vite.config.mjs still counts.
NOAPP_EXT = re.compile(r"\.(md|txt|yml|yaml|toml|lock|sh|py|mjs)$")
WEB = re.compile(r"^(webviews|cmux-tui/frontends/web)/")
RUST = re.compile(r"\.rs$|(^|/)Cargo\.toml$|^cmux-tui/|^acpmux/")
IOS = re.compile(r"^(ios|cmux-next-ios|Packages/iOS)/")
# C, Objective-C and Zig sources need a new app, except under cmux-tui/: the cmux-tui tree build compiles those (a
# companion's shim, the Zig binding), so they are daemon, as hot-apply.py applies them; its linked_rust still leaves
# an app FFI crate's to the ffi part (hot-apply-more-kinds.md in cmuxterm-hq docs/design).
REBUILD_FILE = re.compile(r"\.(xcstrings|strings|xcassets|plist|entitlements|pbxproj|xcconfig|storyboard|xib|metal|png|pdf|car|icns)$|(^|/)Package\.(swift|resolved)$|Contents\.json$|\.xcodeproj/|/Resources/|^ghostty|^(?!cmux-tui/).*\.(c|h|m|mm|zig)$")
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


# T1 of leo-workspace research/2026-11-04-hot-swap-architecture.md, what a patch carries with no app change:
# - a type, extension or conformance the PR adds whole: new symbols, and conformance records the runtime
#   reads from the patch's image when it loads;
# - a `static let` or global `let` the PR adds: storage only the patch's code reads;
# - a changed signature: a new symbol that the patch's callers call. It is live when no file outside the PR
#   names the function, and no vtable, witness table or Objective-C lookup reaches it (not an override,
#   `@objc`, `dynamic` or `required`, not a protocol requirement, not a member of a class that is not final).
DECL = re.compile(r"^(\s*)(?:@[\w.]+(?:\([^)]*\))?\s+)*(?:(?:public|private|fileprivate|internal|package|open|final|indirect|nonisolated)(?:\([^)]*\))?\s+)*(struct|class|enum|actor|protocol|extension)\s+([\w.]+)")
FUNC_NAME = re.compile(r"\bfunc\s+([^\s(<]+)|\b(init)[?!]?\s*[(<]|\b(subscript)\s*[(<]")
VTABLE = re.compile(r"\b(override|required|dynamic)\b|@objc\b|@IBAction\b")
PRIVATE = re.compile(r"\b(private|fileprivate)\b")
NEW_LET = re.compile(r"^\s*(?:@\w+(?:\([^)]*\))?\s+)*(?:(?:public|private|fileprivate|internal|package|nonisolated)(?:\([^)]*\))?\s+)*(static\s+(?:(?:public|private|fileprivate|internal|package|nonisolated)\s+)*)?let\s+(\w+)")
STRING_LITERAL = re.compile(r'"(?:\\.|[^"\\])*"')


def _pair(item):
    """A diff line as (sign, text, line number or None): parse_diff numbers its lines, hand-made pairs do not."""
    return (item[0], item[1], item[2] if len(item) > 2 else None)


def enclosing(source, number, indent):
    """The nearest declaration above line `number` (1-based) of `source` (a file's lines) indented less than
    `indent`, as (kind, final): ("class", True) for a final class, ("global", False) at file level, or None
    when the file is not known."""
    if not source or not number:
        return None
    for line in reversed(source[:number - 1]):
        match = DECL.match(line)
        if match and len(match.group(1)) < indent:
            kind = match.group(2)
            return kind, kind == "class" and re.search(r"\bfinal\b", line[:match.end()]) is not None
    return ("global", False)


def _block_end(pairs, start, sign):
    """The index of the line that closes the declaration at `start`, when every line through it has
    `sign` (the hunk adds or removes it whole); else None."""
    depth, opened = 0, False
    for index in range(start, len(pairs)):
        if pairs[index][0] != sign:
            return None
        code = STRING_LITERAL.sub('""', pairs[index][1]).split("//")[0]
        depth += code.count("{") - code.count("}")
        opened = opened or "{" in code
        if opened and depth <= 0:
            return index
    return None


def _slid_block_end(pairs, start, sign, source):
    """The diff slid a whole declaration by one closing brace: it shows the brace above the declaration
    as the changed line and leaves the declaration's own brace as context. Returns the index of the
    hunk's last line when that is so (from the file's lines, `source`), else None."""
    number = pairs[start][2]
    if not source or not number:
        return None
    depth, opened, close = 0, False, None
    for offset, line in enumerate(source[number - 1:]):
        code = STRING_LITERAL.sub('""', line).split("//")[0]
        depth += code.count("{") - code.count("}")
        opened = opened or "{" in code
        if opened and depth <= 0:
            close = number + offset  # the declaration's closing line, 1-based
            break
    run = start
    while run + 1 < len(pairs) and pairs[run + 1][0] == sign:
        run += 1
    before = start
    while before > 0 and pairs[before - 1][0] == sign and not pairs[before - 1][1].strip():
        before -= 1
    if (close is None or pairs[run][2] != close - 1 or before == 0 or pairs[before - 1][0] != sign
            or pairs[before - 1][1].rstrip() != source[close - 1].rstrip()):
        return None
    return run


def whole_blocks(pairs, old=None, new=None):
    """The indexes of the lines inside declarations one hunk adds or removes whole, and each one's
    (sign, kind, name). `old` and `new` (the file's lines) let it see a declaration the diff slid."""
    inside, blocks, index = set(), [], 0
    while index < len(pairs):
        sign, text, _ = pairs[index]
        match = DECL.match(text) if sign in "+-" else None
        end = _block_end(pairs, index, sign) if match else None
        if match and end is None:
            end = _slid_block_end(pairs, index, sign, new if sign == "+" else old)
        if end is None:
            index += 1
            continue
        inside.update(range(index, end + 1))
        blocks.append((sign, match.group(2), match.group(3)))
        index = end + 1
    return inside, blocks


def swift_reasons(lines, added_file, old=None, new=None, named_outside=None):
    """Why a Swift file's change needs a rebuild; empty when a patch carries it.
    `lines` are the diff's ("+" or "-", text[, line number]) pairs; an ("@", header) pair starts a hunk.
    `old` and `new` are the file's lines before and after (classify_range reads them): they tell a member of
    a final class from one a vtable reaches. Without them, a changed signature needs a rebuild.
    `named_outside(name)` is true when a Swift file the change leaves alone names `name`."""
    if added_file:
        # Its types and functions are new symbols that live only in the patch, with the edited
        # files that use them; the running build has nothing of them to replace. An entry point
        # is the one thing a patch cannot add.
        return ["new entry point"] if any(item[0] == "+" and ENTRY.match(item[1]) for item in lines) else []
    reasons = set()
    hunks = [[]]
    for item in lines:
        if item[0] == "@":
            hunks.append([])
        else:
            hunks[-1].append(_pair(item))
    removed, added, lets = {}, {}, {"+": set(), "-": set()}
    whole = set()
    for pairs in hunks:
        inside, blocks = whole_blocks(pairs, old, new)
        whole.update((sign, name) for sign, kind, name in blocks if kind != "extension")
        for index, (sign, line, number) in enumerate(pairs):
            if index in inside:
                continue
            body = line.rstrip()
            if not body.strip() or COMMENT.match(body):
                continue
            indent = len(body) - len(body.lstrip(" "))
            if ENTRY.match(body) and sign == "+":
                reasons.add("new entry point")
            elif TYPE_DECL.match(body):
                reasons.add("type or conformance")  # an existing type's header changed
            elif STORED.match(body) and indent <= 4 and not body.endswith("{"):
                let = NEW_LET.match(body)
                if let and (let.group(1) or indent == 0):
                    lets[sign].add(let.group(2))  # a `static let` or global `let`: storage, not layout
                else:
                    reasons.add("stored property")  # member level (one indent) or a global
            elif CASE.match(body) and indent == 4:
                reasons.add("enum case")
            elif FUNC.match(body):
                # The declaration up to its body: a one-line function's body edit is not a new signature.
                sig = re.sub(r"\s+", " ", STRING_LITERAL.sub('""', body).split("{", 1)[0].strip())
                place = enclosing(old if sign == "-" else new, number, max(indent, 1))
                (removed if sign == "-" else added).setdefault(sig, place)
    if any((("-" if sign == "+" else "+"), name) in whole for sign, name in whole):
        reasons.add("type or conformance")  # one type removed and added again: its layout may differ
    if lets["-"]:
        reasons.add("stored property")  # a changed or removed one: callers outside the patch keep the build's
    for sig, place in added.items():
        if sig not in removed and place and place == ("class", False):
            reasons.add("signature")  # a new member of a class that is not final adds a vtable slot
    for sig, place in removed.items():
        if sig in added:
            continue
        found = FUNC_NAME.search(sig)
        name = next((group for group in found.groups() if group), None) if found else None
        if (place is None or place == ("class", False) or place[0] == "protocol" or VTABLE.search(sig)
                or name in (None, "init", "subscript")):
            reasons.add("signature")
        elif PRIVATE.search(sig):
            continue  # every caller is in this file, which the patch compiles
        elif named_outside is None or named_outside(name.strip("`")):
            reasons.add("signature")  # a file the patch does not compile may call the old one
    return sorted(reasons)


def classify(files, diffs, sources=None, named_outside=None):
    """`files`: (status letter, path) pairs, as `git diff --name-status --no-renames`.
    `diffs`: path -> ("+" or "-", text) pairs of that Swift file's `-U0` diff (parse_diff).
    `sources`: path -> (lines before, lines after), and `named_outside`, as swift_reasons takes them.
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
            why = [] if status == "D" else swift_reasons(diffs.get(path, []), status == "A",
                                                         *(sources or {}).get(path, (None, None)),
                                                         named_outside=named_outside)
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


HUNK = re.compile(r"^@@ -(\d+)(?:,\d+)? \+(\d+)(?:,\d+)? @@")


def parse_diff(text):
    """path -> ("+" or "-", text, line number) triples from a unified diff, with an ("@", header) pair where
    each hunk starts. A removed line's number is in the old file, an added line's in the new one."""
    diffs, current, in_hunk, old, new = {}, None, False, 0, 0
    for line in text.splitlines():
        hunk = HUNK.match(line)
        if line.startswith("diff --git "):
            current, in_hunk = None, False
        elif not in_hunk and line.startswith("+++ "):
            current = line[6:] if line.startswith("+++ b/") else None
            if current:
                diffs.setdefault(current, [])
        elif hunk and current:
            in_hunk, old, new = True, int(hunk.group(1)), int(hunk.group(2))
            diffs[current].append(("@", line))
        elif in_hunk and current and line[:1] == "-":
            diffs[current].append(("-", line[1:], old))
            old += 1
        elif in_hunk and current and line[:1] == "+":
            diffs[current].append(("+", line[1:], new))
            new += 1
        elif in_hunk and line[:1] == " ":
            old, new = old + 1, new + 1
    return diffs


def classify_range(repo, base, head):
    def git(*args, check=True):
        return subprocess.run(["git", "-C", repo, *args], check=check, capture_output=True, text=True,
                              errors="replace").stdout
    files = parse_name_status(git("diff", "--name-status", "--no-renames", base, head))
    swift = [p for s, p in files if p.endswith(".swift") and s != "D"]
    diffs = parse_diff(git("diff", "-U0", "--no-renames", base, head, "--", *swift)) if swift else {}
    sources = {path: (git("show", f"{base}:{path}", check=False).splitlines(),
                      git("show", f"{head}:{path}", check=False).splitlines())
               for status, path in files if status == "M" and path.endswith(".swift")}
    changed = {path for _, path in files}

    def named_outside(name):
        # Any Swift file at HEAD the change leaves alone that has the name as a word: a caller the patch
        # does not compile (or one of the same name, which this cannot tell apart, so it counts).
        found = git("grep", "-l", "-w", "-F", "-e", name, head, "--", "*.swift", check=False)
        return any(line.split(":", 1)[-1] not in changed for line in found.splitlines())
    return classify(files, diffs, sources, named_outside)


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
