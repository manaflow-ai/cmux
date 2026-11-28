#!/usr/bin/env python3
"""What a running cmux NEXT app could take from a change without a new build (try-pr.sh).

    live_apply.py [--repo DIR] [--json] BASE HEAD
    live_apply.py --paths-from FILE     (`-` for stdin; prints JSON)

`--paths-from` classifies `STATUS<TAB>PATH` lines (git diff --name-status) by path alone, with no
Swift diff, so a Swift file never reads as live there. nightly.yml uses it on the GitHub compare
file list to skip a nightly-next rebuild whose changes are all `no-app` or `web-live`.

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

# The path rules live in docs/benches/relevance-map.toml's [[live_rule]] table, the same map `cmux-bench for-paths`
# reads (one table, two consumers); the block below is generated from it and a test fails when they differ.
# ---- generated from docs/benches/relevance-map.toml [[live_rule]] by `cmux-bench for-paths --write` ----
IOS = re.compile(r"^(ios|cmux-next-ios|Packages/iOS)/")
# Folders and files that never ship in the app, checked before everything but IOS. images/ is the Cloud
# machine image (its bot's image rolls); ci-target-graph.json is CI's test-target map. Root examples/ holds
# sample extensions only a lint reads; cmux-tui/bindings/examples/ is built into the app, so the rule is anchored.
# A *-gallery.html page is a design gallery. The root .gitattributes only sets merge drivers and Linguist
# labels; evals/ (cueval's computer-use tasks) and Native/*/evals/ (the Chief's eval cases, which only its tests,
# examples and backend/scripts read: no include_str! in src/, nothing in build.rs) are eval inputs; dogfood/ held
# scenario files whose runner is gone. design/ holds the sources generators read (design/icons, design/agent-icons:
# their outputs are committed where the app reads them, cmux-icons.json, AgentBrandCatalog+Generated.swift, brand.rs)
# and design pages. vault/ is the cmux-vault Go service (its own go.mod; the app's Rust uses cmux-vault-egress);
# capture-scratch/ holds screenshot replay output. No Xcode phase, Package.swift resource or build script copies any of them.
NOAPP_PATH = re.compile(r"(^|/)(docs?|plans|research|\.github|tests?|Tests|UITests|scripts|skills|release-notes|schemas|fixtures|bench|benchmarks|tools|build-fleet)(/|$)|^(web|backend|workers|services|images|examples|cmux-tui/relays|evals|dogfood|design|vault|capture-scratch)/|^Native/.+/evals/|^\.gitattributes$|(^|/)ci-target-graph\.json$|-gallery\.html$|(^|/)CHANGELOG|LICENSE|\.gitignore$|\.test\.(ts|tsx)$|\.gallery\.(ts|tsx|css)$|/gallery/")
# clients/ts and config/vite-plus hold TypeScript that only the web bundles import (the Cloud page's wire types,
# clients/ts/cloud/src/generated.ts) or lint with: nothing native reads them (cmux_next_route.py BUNDLE_INPUTS).
WEB = re.compile(r"^(webviews|cmux-tui/frontends/web|clients/ts|config/vite-plus)/")
# String catalogs: gen-strings.mjs builds the web pages' strings from them, and a Swift string shows its source
# text without the compiled table, so trying the change needs no build; only the translations do.
STRINGS = re.compile(r"\.xcstrings$")
# C, Objective-C and Zig sources need a new app, except under cmux-tui/: the cmux-tui tree build compiles those (a
# companion's shim, the Zig binding), so they are daemon, as hot-apply.py applies them; its linked_rust still leaves
# an app FFI crate's to the ffi part (hot-apply-more-kinds.md in cmuxterm-hq docs/design).
REBUILD_FILE = re.compile(r"\.(strings|xcassets|plist|entitlements|pbxproj|xcconfig|storyboard|xib|metal|png|pdf|car|icns)$|(^|/)Package\.(swift|resolved)$|Contents\.json$|\.xcodeproj/|/Resources/|^ghostty|^(?!cmux-tui/).*\.(c|h|m|mm|zig)$")
RUST = re.compile(r"\.rs$|(^|/)Cargo\.toml$|^cmux-tui/|^acpmux/")
# Extensions that change nothing in the app, checked after the web, resource and Rust rules, so a
# Cargo.lock, a bundled Resources/x.sh or webviews' vite.config.mjs still counts.
NOAPP_EXT = re.compile(r"\.(md|txt|yml|yaml|toml|lock|sh|py|mjs)$")
# (regex, class, rebuild reason), checked in this order; the first match decides a path's class.
PATH_RULES = [
    (IOS, "ios-only", None),
    (NOAPP_PATH, "no-app", None),
    (WEB, "web-live", None),
    (STRINGS, "strings", None),
    (REBUILD_FILE, "rebuild", "resource or manifest"),
    (RUST, "daemon", None),
    (NOAPP_EXT, "no-app", None),
]
# ---- end of generated live rules ----
COMMENT = re.compile(r"^\s*(//|/\*|\*|\*/)")
STORED = re.compile(r"^(\s*)(@\w+(\([^)]*\))?\s+)*((public|private|fileprivate|internal|package|open|final|static|nonisolated|lazy|weak|unowned|override)(\([^)]*\))?\s+)*(let|var)\s+\w+[^{]*$")
FUNC = re.compile(r"^\s*(@\w+(\([^)]*\))?\s+)*((public|private|fileprivate|internal|package|open|final|static|class|override|mutating|nonisolated|required|convenience)(\([^)]*\))?\s+)*(func\s+\w+|init[?!]?\s*[(<]|subscript\s*[(<])")
TYPE_DECL = re.compile(r"^\s*(@\w+(\([^)]*\))?\s+)*((public|private|fileprivate|internal|package|open|final|indirect)\s+)*(struct|class|enum|actor|protocol|extension)\s+\w+")
# A constant with an initializer that belongs to no instance: `static let x = ...` (any access, `nonisolated(unsafe)`
# and the like) or a file-level `let x = ...` (indent 0). It changes no type's size, so a patch can carry it: the patch
# defines the variable and its addressor, the app repoints the addressor, and every caller (patched or not) reaches the
# patch's copy. Only `let`: a `static var` is state a patch would reset, and an instance property changes the layout.
STATIC_LET = re.compile(r"^(\s*)(@\w+(\([^)]*\))?\s+)*((public|private|fileprivate|internal|package|open|final|nonisolated(\([^)]*\))?)\s+)*"
                        r"(static|class)\s+((public|private|fileprivate|internal|package|open|final|nonisolated(\([^)]*\))?)\s+)*let\s+\w+[^{]*=")
FILE_LET = re.compile(r"^((public|private|fileprivate|internal|package|nonisolated(\([^)]*\))?)\s+)*let\s+\w+[^{]*=")
ENTRY = re.compile(r"^\s*(@\w+(\([^)]*\))?\s+)*@main\b")
# The modules a patch can replace code in: the app's live code build makes every CmuxNext module's
# symbols interposable (live_code_targets in scripts/live-code/lib/xcodebuild-args.sh: the
# CmuxNext targets of Packages/macOS/CmuxNext/Package.swift, and MessagesLabHome, the Home transcript
# CmuxNextHome links from Packages/Shared/CmuxMessagesLab), and the view shell's inject.sh patches
# its own module. Third-party modules are linked into the app as they were built.
LIVE_MODULE = re.compile(r"^(CmuxNext[A-Za-z0-9_]*|MessagesLabHome|ViewShell)$")
LIVE_PACKAGE = re.compile(r"(?:^|/)Packages/macOS/CmuxNext/Sources/|(?:^|/)Packages/Shared/CmuxMessagesLab/Sources/MessagesLabHome/"
                          r"|(?:^|/)Prototypes/ViewShell/Sources/")
SWIFT_MODULE = re.compile(r"(?:^|/)Sources/([^/]+)/")
CASE = re.compile(r"^ {4}(\t)?case\s+\w+|^\tcase\s+\w+")

# Heaviest first: a change takes the verdict of its heaviest file.
ORDER = ["rebuild", "swift-live", "daemon", "web-live", "strings", "ios-only", "no-app"]


# The keyword and name of a type declaration (TYPE_DECL's line): `struct Reply`, `extension CloudWait.State`.
TYPE_NAME = re.compile(r"^(?:@[\w.]+(?:\([^)]*\))?\s+)*(?:(?:public|private|fileprivate|internal|package|open|final|"
                       r"indirect|nonisolated|sealed|@\w+)(?:\(set\))?\s+)*"
                       r"(struct|class|enum|actor|protocol|extension)\s+([A-Za-z_][\w.]*)")
# A head line that only continues the one above it (`where T: P`, `) -> X`, `: Equatable`).
CONTINUES = re.compile(r"^(where\b|[:,&)>]|->|throws\b|async\b|rethrows\b)")
NOT_TYPE_NAMES = {"func", "var", "let", "subscript", "init", "override", "final", "private", "fileprivate", "public",
                  "internal", "package", "open", "static", "nonisolated", "required", "convenience"}


def _scope_of(head):
    """The scope a `{` opens, from the code since the last `{`, `}` or `;`: ("type", kind, name) for a type's or
    extension's body, else ("code", head line): a function, initializer, computed property, accessor or closure."""
    lines = [line.strip() for line in head.split("\n") if line.strip()]
    while len(lines) > 1 and CONTINUES.match(lines[-1]):
        lines.pop()
    last = lines[-1] if lines else ""
    named = TYPE_NAME.search(last)
    if named and named.group(2) not in NOT_TYPE_NAMES:
        return ("type", named.group(1), named.group(2), ":" in last[named.end():] or " where " in last[named.end():],
                bool(re.search(r"\bfinal\b", last[:named.start(1)])))
    return ("code", " ".join(last.split()))


def swift_scopes(text):
    """For each line of a Swift file (index 0 is line 1): (the scopes open where it starts, the scopes it opens).
    A scope is a `_scope_of` tuple. Braces inside comments and string literals are skipped; a string's
    interpolation is read as part of the string. A sketch of Swift's grammar, not a parser: it only has to tell
    a type's body from code, which a brace and the declaration before it do."""
    starts, opens = [()], [[]]
    stack, head = [], []
    i, n = 0, len(text)
    while i < n:
        c = text[i]
        if c == "\n":
            head.append(c)
            starts.append(tuple(stack))
            opens.append([])
            i += 1
        elif text.startswith("//", i):
            j = text.find("\n", i)
            i = n if j < 0 else j
        elif text.startswith("/*", i):
            depth, i = 1, i + 2
            while i < n and depth:
                if text.startswith("/*", i):
                    depth, i = depth + 1, i + 2
                elif text.startswith("*/", i):
                    depth, i = depth - 1, i + 2
                else:
                    if text[i] == "\n":
                        starts.append(tuple(stack))
                        opens.append([])
                    i += 1
        elif c == '"' or (c == "#" and text.startswith('#"', i)):
            hashes = 0
            while text.startswith("#", i + hashes):
                hashes += 1
            j = i + hashes
            quote = '"""' if text.startswith('"""', j) else '"'
            close = quote + "#" * hashes
            j += len(quote)
            while j < n and not text.startswith(close, j):
                if text[j] == "\\" and not hashes:
                    j += 1
                elif text[j] == "\n":
                    if quote == '"':
                        break  # an unclosed one-line string: stop at its line's end
                    starts.append(tuple(stack))
                    opens.append([])
                j += 1
            head.append("_")
            i = j + (len(close) if text.startswith(close, j) else 0)
        elif c == "{":
            scope = _scope_of("".join(head))
            stack.append(scope)
            opens[-1].append(tuple(stack))
            head = []
            i += 1
        elif c == "}":
            if stack:
                stack.pop()
            head = []
            i += 1
        elif c == ";":
            head = []
            i += 1
        else:
            head.append(c)
            i += 1
    return list(zip(starts, opens))


def _path(stack):
    """A scope stack as a type's place: a type by its name alone (`struct Foo { struct Bar }` and
    `extension Foo { struct Bar }` both hold Foo.Bar), code by its head line (`struct Reply` in `func load()` is
    another type than `struct Reply` in `func save()`)."""
    return tuple(("type", s[2]) if s[0] == "type" else s for s in stack)


def type_paths(text):
    """The places of every type and extension a Swift file declares (see _path)."""
    return {_path(stack[:k + 1]) for start, opened in swift_scopes(text) for stack in [start, *opened]
            for k in range(len(stack)) if stack[k][0] == "type"}


def line_kinds(old_text, new_text, old_types=None):
    """(old kinds, new kinds), one per line, for swift_reasons: "new" (in or opening a type no pre-image has, given
    as `old_types`, every changed file's type_paths before the change; default: this file's), "code" (inside a
    function body, initializer, accessor or closure), "local" (a member of a type declared inside code), or
    "member" (a type's member or a file-level declaration). A removed type is never "new": the build may still
    define it in another file (a type moved into generated code keeps its name and the loader compares it)."""
    old_types = type_paths(old_text) if old_types is None else old_types

    def kinds(scopes, others):
        out = []
        texts = text_lines[0 if others is None else 1]
        for number, (start, opened) in enumerate(scopes):
            fresh = others is not None and any(
                _path(stack[:k + 1]) not in others for stack in [start, *opened]
                for k in range(len(stack)) if stack[k][0] == "type" and stack[k][1] != "extension")
            if fresh:
                out.append("new")
            elif start and start[-1][0] == "code":
                out.append("code")
            elif any(s[0] == "code" for s in start):
                out.append("local")
            elif start and start[-1][0] == "type" and start[-1][1] in ("class", "actor") and not start[-1][4]:
                out.append("class member")  # a method of a class that can be subclassed: its vtable slot is the build's
            elif number and OBJC_ATTRIBUTE.search(texts[number - 1]) and texts[number - 1].strip().startswith("@"):
                out.append("objc member")  # its attribute line above: a selector the running class registered
            else:
                out.append("member")
        return out
    text_lines = (old_text.split("\n"), new_text.split("\n"))
    return kinds(swift_scopes(old_text), None), kinds(swift_scopes(new_text), old_types)


# A function only its own file calls (`private`, `fileprivate`), which the patch compiles whole: its callers come
# with its new signature and the build's copy goes unused. Not one the Objective-C runtime or a subclass reaches by
# name, which the patch does not register again.
FILE_ONLY = re.compile(r"\b(private|fileprivate)\s")
OBJC_ATTRIBUTE = re.compile(r"@(objc|IBAction|IBOutlet|IBInspectable|NSManaged|_dynamicReplacement)\b|\b(dynamic|override)\s")


FUNC_NAME = re.compile(r"\bfunc\s+([A-Za-z_]\w*)")


def swift_reasons(lines, added_file, confined=None):
    """Why a Swift file's change needs a rebuild; empty when it only changes function bodies.
    `lines` are the diff's ("+" or "-", text) pairs."""
    if added_file:
        # Its types and functions are new symbols that live only in the patch, with the edited
        # files that use them; the running build has nothing of them to replace. An entry point
        # is the one thing a patch cannot add.
        return ["new entry point"] if any(sign == "+" and ENTRY.match(text) for sign, text in lines) else []
    reasons = set()
    removed, added = [], []
    for sign, line, *where in lines:
        kind = where[0] if where else "member"  # see line_kinds; a pair without one is read as before
        body = line.rstrip()
        if not body.strip() or COMMENT.match(body):
            continue
        indent = len(body) - len(body.lstrip(" "))
        if ENTRY.match(body) and sign == "+":
            reasons.add("new entry point")
        elif kind in ("new", "code"):
            continue  # a type only the patch has, or a function's body: the patch carries both
        elif kind == "local":
            # A member of a type declared in a function: only that function (patched whole) uses it, but the loader
            # still compares a type's layout when the build defines it too.
            if STORED.match(body) and not body.endswith("{"):
                reasons.add("stored property")
            elif CASE.match(body.lstrip(" ").rjust(len(body.lstrip(" ")) + 4)):
                reasons.add("enum case")
            elif TYPE_DECL.match(body):
                reasons.add("type or conformance")
        elif TYPE_DECL.match(body):
            reasons.add("type or conformance")
        elif (STATIC_LET.match(body) and indent <= 4) or (FILE_LET.match(body) and indent == 0):
            continue  # a constant of no instance: the patch carries it (see STATIC_LET)
        elif STORED.match(body) and indent <= 4 and not body.endswith("{"):
            reasons.add("stored property")  # member level (one indent) or a global
        elif CASE.match(body) and indent == 4:
            reasons.add("enum case")
        elif FUNC.match(body):
            # A one-line func carries its body after the signature (`func f() -> Bool { x }`): compare only up to the body's brace.
            sig = re.sub(r"\s+", " ", re.split(r"\{", body.strip(), maxsplit=1)[0].strip())
            static = kind == "class member" and re.search(r"\b(static|final)\s", sig.split("(")[0])
            if where and (kind == "member" or static) and not OBJC_ATTRIBUTE.search(sig):
                if FILE_ONLY.search(sig.split("(")[0]):
                    continue  # see FILE_ONLY; read only with line_kinds, which looks at the attribute line above
                name = FUNC_NAME.search(sig)
                if sign == "-" and name and confined and confined(name.group(1)):
                    continue  # every file that names it is in the patch: see classify_range
            (removed if sign == "-" else added).append(sig)
    if set(removed) - set(added):
        reasons.add("signature")  # one went away or changed; a new function alone is fine
    return sorted(reasons)


def classify(files, diffs, confined=None):
    """`files`: (status letter, path) pairs, as `git diff --name-status --no-renames`.
    `diffs`: path -> ("+" or "-", text) pairs of that Swift file's `-U0` diff.
    Returns {"verdict", "reasons": {reason: [paths]}, "files": {kind: [paths]}}."""
    kinds, reasons = {}, {}

    def note(kind, path, why=None):
        kinds.setdefault(kind, []).append(path)
        if why:
            reasons.setdefault(why, []).append(path)

    for status, path in files:
        rule = next((r for r in PATH_RULES if r[0].search(path)), None)
        if rule:
            note(rule[1], path, rule[2])
        elif path.endswith(".swift"):
            # A deleted file's code stays in the running binary, and nothing calls it any more.
            why = [] if status == "D" else swift_reasons(diffs.get(path, []), status == "A", confined)
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


HUNK = re.compile(r"^@@ -(\d+)(?:,\d+)? \+(\d+)(?:,\d+)? @@")


def parse_diff(text, numbered=False):
    """path -> ("+" or "-", text) pairs, from a unified diff; with `numbered`, (sign, text, line number in that
    side) triples."""
    diffs, current, numbers = {}, None, {"-": 0, "+": 0}
    for line in text.splitlines():
        if line.startswith("+++ "):
            current = line[6:] if line.startswith("+++ b/") else None
            if current:
                diffs.setdefault(current, [])
        elif line.startswith("--- "):
            continue
        elif current and (hunk := HUNK.match(line)):
            numbers = {"-": int(hunk.group(1)), "+": int(hunk.group(2))}
        elif current and line[:1] in ("+", "-"):
            sign = line[0]
            diffs[current].append((sign, line[1:], numbers[sign]) if numbered else (sign, line[1:]))
            numbers[sign] += 1
        elif current and line[:1] == " ":
            numbers["-"] += 1
            numbers["+"] += 1
    return diffs


HOT_APPLY_KINDS = {"no-app", "web-live"}


def classify_paths(files):
    """Path-only verdict: Swift reads as `rebuild` (no diff to prove it live). `hot_apply_only` is true
    when every change is no-app or web-live: the signed web update pointer delivers it with no new build."""
    files = list(files)
    result = classify(files, {})
    for path in result["files"].pop("swift-live", []):
        result["files"].setdefault("rebuild", []).append(path)
        result["reasons"].setdefault("Swift without a diff", []).append(path)
    result["verdict"] = next((v for v in ORDER if v in result["files"]), "no-app")
    result["hot_apply_only"] = bool(files) and set(result["files"]) <= HOT_APPLY_KINDS
    return result


def classify_range(repo, base, head):
    def git(*args):
        return subprocess.run(["git", "-C", repo, *args], check=True, capture_output=True, text=True,
                              errors="replace").stdout
    files = parse_name_status(git("diff", "--name-status", "--no-renames", base, head))
    swift = [p for s, p in files if p.endswith(".swift") and s != "D"]
    diffs = parse_diff(git("diff", "-U0", "--no-renames", base, head, "--", *swift), numbered=True) if swift else {}
    changed = {p for s, p in files if s == "M" and p in diffs}
    before, old_types = {}, set()
    for path in [p for s, p in files if p.endswith(".swift") and s in ("M", "D")]:
        try:
            before[path] = git("show", f"{base}:{path}")
        except subprocess.CalledProcessError:
            continue
        old_types |= type_paths(before[path])
    for path, lines in diffs.items():
        kinds = None
        if path in changed and path in before:
            try:
                kinds = line_kinds(before[path], git("show", f"{head}:{path}"), old_types)
            except subprocess.CalledProcessError:
                pass
        diffs[path] = with_kinds(lines, kinds)

    seen = {}

    def confined(name):
        """Whether every Swift file that names `name` at `head` (a word match, app code and packages, tests aside)
        is one this change patches (modified): then every caller of its old signature is replaced too."""
        if name not in seen:
            hits = subprocess.run(["git", "-C", repo, "grep", "-lw", name, head, "--", "*.swift"],
                                  capture_output=True, text=True).stdout.split()
            paths = {hit.split(":", 1)[1] for hit in hits}
            seen[name] = all(p in changed or "/Tests/" in p or p.startswith("Tests/") for p in paths)
        return seen[name]
    return classify(files, diffs, confined)


def with_kinds(lines, kinds):
    """parse_diff(numbered=True)'s triples as swift_reasons reads them: (sign, text, line_kinds' kind of that line in
    its side), or pairs when the files could not be read."""
    if kinds is None:
        return [(sign, text) for sign, text, _ in lines]
    old, new = kinds
    side = {"-": old, "+": new}
    return [(sign, text, side[sign][number - 1] if 0 < number <= len(side[sign]) else "member")
            for sign, text, number in lines]


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--repo", default=os.getcwd())
    parser.add_argument("--json", action="store_true")
    parser.add_argument("--paths-from", help="classify STATUS<TAB>PATH lines by path alone; prints JSON")
    parser.add_argument("base", nargs="?")
    parser.add_argument("head", nargs="?")
    args = parser.parse_args(argv)
    if args.paths_from:
        text = sys.stdin.read() if args.paths_from == "-" else open(args.paths_from).read()
        print(json.dumps(classify_paths(parse_name_status(text))))
        return 0
    if not (args.base and args.head):
        parser.error("BASE and HEAD are required without --paths-from")
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
