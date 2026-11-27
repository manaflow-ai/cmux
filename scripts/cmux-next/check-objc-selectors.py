#!/usr/bin/env python3
"""Stops the "unrecognized selector sent to instance" crash class in cmux-next.

Two nightly crashes on 2026-10-20 were Objective-C messages to an object whose
class does not implement them:

- `super.draggingEnded(sender)` in a WKWebView subclass. NSDraggingDestination
  methods are optional and WKWebView has no `draggingEnded:`, yet Swift
  compiles the `super` call (PR 22770).
- Chromium sent `-cancelTerminate:` to NSApp, which is cmux's
  `CmuxApplication`, not Chromium's `BrowserCrApplication` (PR 22745).

This check runs on Linux from checked-in data, so CI blocks on it without a
Mac (cmux-next-crash-class.yml). Every Swift `super.<member>` in the scanned
sources must reach an implementation. The class's ancestors in the scanned
sources are walked first (a declaration there answers); otherwise the first
framework class (NSView, WKWebView, ...) must answer the selector on every
macOS that recorded it in scripts/cmux-next/objc-selector-table.json (a key
probed on one macOS only is held to that macOS; probe every macOS you can). A `super` call
the table does not know fails with "probe needed": run `--probe --write` on a
Mac (every macOS you can) and commit the table. A selector a framework class
lacks fails unless the call is guarded: the statement, or one of the three
lines above it, checks `responds(to:)` / `instancesRespond(to:)`, or reads a
`static let` of the same file that does, or carries a reviewed
`// selector-allow: <reason>` comment.

`--probe` (macOS only) asks the Objective-C runtime of this Mac for every key
the sources need (`--write` merges the answers into the table
under this macOS version and drops keys no call needs; without it, a key the table says is answered but
this Mac does not answer fails). `--list` prints every `super` call with its
key and verdict.

The Swift parsing is lexical (comments and strings blanked, braces counted),
and the selector match is by Objective-C name prefix and argument count, so it
is a heuristic with a reviewed escape hatch, not a compiler.

Usage: scripts/cmux-next/check-objc-selectors.py [--root REPO] [--source DIR ...]
                                                 [--probe [--write]] [--list]
"""

from __future__ import annotations

import argparse
import json
import platform
import re
import sys
from collections import defaultdict
from dataclasses import dataclass, field
from pathlib import Path

TABLE = "scripts/cmux-next/objc-selector-table.json"
DEFAULT_SOURCES = ["Packages/macOS/CmuxNext/Sources"]
ALLOW = re.compile(r"//\s*selector-allow:\s*\S")
# The selector a `responds(to:)` check names: `#selector(T.member(_:))` or an expression up to `)`.
GUARD_ARG = re.compile(r"\b(?:responds|instancesRespond)\s*\(\s*to:\s*(#selector\((?:[^()]|\([^()]*\))*\)|[^)]*)")
# Swift generic framework classes have no Objective-C class name to probe;
# their nearest Objective-C ancestor answers for them (they add methods, never
# remove them).
ALIASES = {
    "NSHostingView": "NSView",
    "NSHostingController": "NSViewController",
    "NSHostingMenu": "NSMenu",
}
# Members every class has through Swift, never a message to probe.
SKIP_MEMBERS = {"init", "deinit", "self", "description", "debugDescription", "hash", "isEqual"}


# MARK: - Swift lexing

HASHES = re.compile(r"#*")
RAW_OPEN = re.compile(r'#+"')


def _string_end(text: str, i: int) -> int:
    """Index after the string literal that starts at `i` (plain, multiline or raw), interpolations included."""
    n = len(text)
    hashes = len(HASHES.match(text, i).group(0))
    start = i + hashes
    multi = text.startswith('"""', start)
    close = ('"""' if multi else '"') + "#" * hashes
    escape = "\\" + "#" * hashes
    j = start + (3 if multi else 1)
    while j < n:
        if text.startswith(close, j):
            return j + len(close)
        if text.startswith(escape, j):
            k = j + len(escape)
            if text.startswith("(", k):
                j = _code_end(text, k + 1)
            else:
                j = k + 1
            continue
        if text[j] == "\n" and not multi:
            return j  # unterminated: stop before the newline
        j += 1
    return n


def _code_end(text: str, i: int) -> int:
    """Index after the `)` that closes an interpolation whose code starts at `i`."""
    depth, n = 1, len(text)
    while i < n:
        c = text[i]
        if c == '"' or (c == "#" and RAW_OPEN.match(text, i)):
            i = _string_end(text, i)
            continue
        if c == "(":
            depth += 1
        elif c == ")":
            depth -= 1
            if depth == 0:
                return i + 1
        i += 1
    return n


def blank_comments_and_strings(text: str) -> str:
    """The source with comments and string literals (interpolations included) blanked; newlines kept."""
    out = []
    i, n = 0, len(text)
    while i < n:
        c = text[i]
        if text.startswith("//", i):
            j = text.find("\n", i)
            j = n if j < 0 else j
            out.append(" " * (j - i))
            i = j
        elif text.startswith("/*", i):
            depth, j = 1, i + 2
            while j < n and depth:
                if text.startswith("/*", j):
                    depth, j = depth + 1, j + 2
                elif text.startswith("*/", j):
                    depth, j = depth - 1, j + 2
                else:
                    j += 1
            out.append(re.sub(r"[^\n]", " ", text[i:j]))
            i = j
        elif c == '"' or (c == "#" and RAW_OPEN.match(text, i)):
            j = _string_end(text, i)
            out.append(text[i] + re.sub(r"[^\n]", " ", text[i + 1:j]))
            i = j
        else:
            out.append(c)
            i += 1
    return "".join(out)


DECL = re.compile(
    r"\b(class|extension|struct|enum|actor|protocol)\s+"
    r"(?!func\b|var\b|let\b|subscript\b|override\b|final\b|private\b|fileprivate\b|public\b|internal\b|open\b|static\b)"
    r"([A-Za-z_][\w.]*)(\s*<[^{}]*?>)?\s*(:[^{}]*?)?(?:\bwhere\b[^{}]*)?\{"
)
TYPEALIAS = re.compile(r"\btypealias\s+(\w+)\s*=\s*([\w.]+)")
MEMBER = re.compile(r"\b(?:func|var|let)\s+`?([A-Za-z_]\w*)`?")
STATIC_BEFORE = re.compile(r"\b(?:static|class)\s+(?:\w+\s+)*$")


@dataclass
class TypeInfo:
    name: str
    kind: str
    module: str
    supers: list[str] = field(default_factory=list)
    members: set[str] = field(default_factory=set)


@dataclass
class SuperCall:
    path: str
    line: int
    owner: str  # the enclosing class (or extended type)
    module: str
    member: str
    kind: str  # call, get, set
    args: int
    labels: list[str]  # argument labels 2..n (`_` when unlabeled)
    statement: str
    context: list[str]
    clean: list[str]  # the same lines, comments and strings blanked


TYPE_ALIASES: dict[str, str] = {}


def module_of(path: Path, root: Path) -> str:
    parts = path.relative_to(root).parts
    return parts[parts.index("Sources") + 1] if "Sources" in parts else parts[0]


def parse_args(clean: str, open_index: int) -> tuple[int, list[str]]:
    """(argument count, labels of arguments 2..n) for a call whose `(` is at `open_index`."""
    depth, i, args, current = 0, open_index, [], []
    while i < len(clean):
        c = clean[i]
        if c in "([{":
            depth += 1
            if depth == 1:
                i += 1
                continue
        elif c in ")]}":
            depth -= 1
            if depth == 0:
                args.append("".join(current))
                break
        elif c == "," and depth == 1:
            args.append("".join(current))
            current = []
            i += 1
            continue
        if depth >= 1:
            current.append(c)
        i += 1
    args = [a for a in args if a.strip()]
    labels = []
    for a in args[1:]:
        m = re.match(r"\s*([A-Za-z_]\w*)\s*:(?!:)", a)
        labels.append(m.group(1) if m else "_")
    return len(args), labels


def scan_file(path: Path, root: Path, types: dict[str, list[TypeInfo]], calls: list[SuperCall]) -> None:
    text = path.read_text(encoding="utf-8", errors="replace")
    clean = blank_comments_and_strings(text)
    raw_lines = text.split("\n")
    clean_lines = clean.split("\n")
    module = module_of(path, root)
    decl_at = {m.end() - 1: m for m in DECL.finditer(clean)}
    for m in TYPEALIAS.finditer(clean):
        TYPE_ALIASES[m.group(1)] = m.group(2).split(".")[-1]
    stack: list[TypeInfo | None] = []
    line = 1
    super_re = re.compile(r"\bsuper\s*\.\s*([A-Za-z_]\w*)")
    i = 0
    while i < len(clean):
        c = clean[i]
        if c == "\n":
            line += 1
        elif c == "{":
            m = decl_at.get(i)
            if m:
                kind, name = m.group(1), m.group(2).split(".")[-1]
                info = TypeInfo(name, kind, module)
                if m.group(4):
                    info.supers = [re.sub(r"@\w+(\([^)]*\))?|<.*", "", s).strip().split(".")[-1]
                                   for s in m.group(4)[1:].split(",") if s.strip()]
                types[name].append(info)
                stack.append(info)
            else:
                stack.append(None)
        elif c == "}":
            if stack:
                stack.pop()
        elif c == "s" and clean.startswith("super", i):
            m = super_re.match(clean, i)
            if m and (i == 0 or not (clean[i - 1].isalnum() or clean[i - 1] == "_")):
                member = m.group(1)
                owner = next((t for t in reversed(stack) if t is not None), None)
                if owner and owner.kind in ("class", "extension") and member not in SKIP_MEMBERS:
                    j = m.end()
                    while j < len(clean) and clean[j] in " \t":
                        j += 1
                    labels: list[str] = []
                    if j < len(clean) and clean[j] == "(":
                        kind, (args, labels) = "call", parse_args(clean, j)
                    elif re.match(r"(?:[-+*/%|&^]|<<|>>)?=(?!=)", clean[j:j + 4]):
                        kind, args = "set", 1  # `super.x = y` and `super.x += y` both call the setter
                    else:
                        kind, args = "get", 0
                    at = line + clean.count("\n", i, m.start(1))
                    calls.append(SuperCall(
                        str(path.relative_to(root)), at, owner.name, module, member, kind, args, labels,
                        raw_lines[at - 1], raw_lines[max(0, at - 4):at - 1],
                        clean_lines[max(0, at - 4):at]))
                line += clean.count("\n", i, m.end())
                i = m.end()
                continue
        # members of the innermost type (top level of its body only)
        if stack and stack[-1] is not None and c in "fvl" and (i == 0 or not (clean[i - 1].isalnum() or clean[i - 1] == "_")):
            mm = MEMBER.match(clean, i)
            if mm and not STATIC_BEFORE.search(clean[clean.rfind("\n", 0, i) + 1:i]):
                stack[-1].members.add(mm.group(1))
        i += 1


# MARK: - Resolution


def resolve(call: SuperCall, types: dict[str, list[TypeInfo]]) -> tuple[str | None, str]:
    """(framework class to probe, how) for a super call; (None, why) when a scanned ancestor answers."""
    def pick(name: str) -> list[TypeInfo]:
        cands = types.get(name, []) + types.get(TYPE_ALIASES.get(name, ""), [])
        same = [t for t in cands if t.module == call.module]
        return same or cands

    def superclass(name: str) -> str | None:
        for t in pick(name):
            if t.kind == "class" and t.supers:
                return t.supers[0]
        return None

    def members(name: str) -> set[str]:
        out: set[str] = set()
        for t in pick(name):
            out |= t.members
        return out

    owner_classes = [t for t in pick(call.owner) if t.kind == "class"]
    if not owner_classes:
        # An extension of a framework type: its superclass is the runtime's.
        return "^" + call.owner, "extension of a framework type"
    seen = set()
    current = superclass(call.owner)
    while current and current not in seen:
        seen.add(current)
        if any(t.kind == "class" for t in pick(current)):
            names = members(current)
            if call.member in names:
                return None, f"declared in {current}"
            current = superclass(current)
            continue
        if any(t.kind == "protocol" for t in pick(current)):
            return None, f"{current} is a protocol (no superclass)"
        return ALIASES.get(current, current), "framework class"
    return None, "no superclass found"


def key_for(cls: str, call: SuperCall) -> str:
    labels = ":" + ",".join(call.labels) if call.labels else ""
    return f"{cls} {call.kind}:{call.member}/{call.args}{labels}"


def guarded(call: SuperCall, file_clean: str) -> bool:
    """A reviewed allow comment, or a `responds(to:)` check of this member in the code nearby."""
    if any(ALLOW.search(line) for line in call.context + [call.statement]):
        return True
    member = re.compile(r"\b%s\b" % re.escape(call.member))
    if any(member.search(arg) for line in call.clean for arg in GUARD_ARG.findall(line)):
        return True
    # `Flags.name ? super.x(...) : ...` where `static let name = ...instancesRespond(to: #selector(...x...))`
    statics = {name for name, rest in re.findall(
        r"static\s+let\s+(\w+)\s*=\s*([^\n]*\b(?:responds|instancesRespond)\s*\(\s*to:[^\n]*)", file_clean)
        if member.search(rest)}
    return any(re.search(r"\b\w+\.(%s)\b" % re.escape(n), line) for n in statics for line in call.clean)


# MARK: - Runtime probe (macOS)


class Runtime:
    FRAMEWORKS = ["Foundation", "AppKit", "WebKit", "QuartzCore", "Quartz", "PDFKit", "AVKit", "MapKit",
                  "SwiftUI", "SceneKit", "SpriteKit", "MetalKit", "QuickLookUI", "AuthenticationServices",
                  "UniformTypeIdentifiers", "ScreenCaptureKit", "UserNotifications"]

    def __init__(self) -> None:
        import ctypes
        self.c = ctypes
        objc = ctypes.cdll.LoadLibrary("/usr/lib/libobjc.A.dylib")
        for fw in self.FRAMEWORKS:
            try:
                ctypes.cdll.LoadLibrary(f"/System/Library/Frameworks/{fw}.framework/{fw}")
            except OSError:
                pass
        vp, cp = ctypes.c_void_p, ctypes.c_char_p
        objc.objc_getClass.restype, objc.objc_getClass.argtypes = vp, [cp]
        objc.class_getSuperclass.restype, objc.class_getSuperclass.argtypes = vp, [vp]
        objc.class_getName.restype, objc.class_getName.argtypes = cp, [vp]
        objc.sel_registerName.restype, objc.sel_registerName.argtypes = vp, [cp]
        objc.class_respondsToSelector.restype, objc.class_respondsToSelector.argtypes = ctypes.c_bool, [vp, vp]
        objc.class_copyMethodList.restype = ctypes.POINTER(vp)
        objc.class_copyMethodList.argtypes = [vp, ctypes.POINTER(ctypes.c_uint)]
        objc.method_getName.restype, objc.method_getName.argtypes = vp, [vp]
        objc.sel_getName.restype, objc.sel_getName.argtypes = cp, [vp]
        self.objc = objc
        self.cache: dict[int, set[str]] = {}

    def cls(self, name: str) -> int | None:
        if name.startswith("^"):
            base = self.cls(name[1:])
            return self.objc.class_getSuperclass(base) if base else None
        return self.objc.objc_getClass(name.encode()) or None

    def selectors(self, cls: int) -> set[str]:
        if cls in self.cache:
            return self.cache[cls]
        names: set[str] = set()
        current = cls
        while current:
            count = self.c.c_uint()
            methods = self.objc.class_copyMethodList(current, self.c.byref(count))
            for k in range(count.value):
                names.add(self.objc.sel_getName(self.objc.method_getName(methods[k])).decode("utf-8", "replace"))
            current = self.objc.class_getSuperclass(current)
        self.cache[cls] = names
        return names

    def type_words(self, cls: int) -> set[str]:
        """CamelCase tails of the class names up the chain, without the prefix (NSWindow: Window)."""
        words: set[str] = set()
        current = cls
        while current:
            name = re.sub(r"^[A-Z]{2,}(?=[A-Z][a-z])", "", self.objc.class_getName(current).decode())
            parts = re.findall(r"[A-Z][a-z0-9]*", name)
            words |= {"".join(parts[k:]) for k in range(len(parts))}
            current = self.objc.class_getSuperclass(current)
        return words

    def answers(self, key: str) -> bool | None:
        cls_name, spec = key.split(" ", 1)
        cls = self.cls(cls_name)
        if not cls:
            return None
        kind, rest = spec.split(":", 1)
        member, tail = rest.split("/", 1)
        count, _, label_text = tail.partition(":")
        args, labels = int(count), (label_text.split(",") if label_text else [])
        sels = self.selectors(cls)
        if kind == "get":
            return member in sels
        if kind == "set":
            stem = member[2:] if member.startswith("is") and member[2:3].isupper() else member
            return any(s in sels for s in (f"set{member[0].upper()}{member[1:]}:", f"set{stem[0].upper()}{stem[1:]}:"))
        if args == 0:
            # Swift drops a trailing word that repeats the type (`makeKeyWindow` is `makeKey()`).
            return member in sels or any(member + word in sels for word in self.type_words(cls))
        for s in sels:
            if s.count(":") != args:
                continue
            pieces = s.split(":")[:-1]
            # Labels 2..n are selector pieces 2..n (Swift may drop a trailing type word: `with` is `withEvent`).
            if not all(label == "_" or piece == label or (piece.startswith(label) and piece[len(label):len(label) + 1].isupper())
                       for label, piece in zip(labels, pieces[1:])):
                continue
            head = pieces[0]
            # Swift also drops a type word inside the name (`scrollRectToVisible:` is
            # `scrollToVisible(_:)`), so the head may miss one CamelCase word.
            words = re.findall(r"^[a-z0-9_]+|[A-Z][a-z0-9]*", head)
            forms = {head} | {"".join(words[:k] + words[k + 1:]) for k in range(1, len(words))}
            for form in forms:
                if form == member or (form.startswith(member) and form[len(member):len(member) + 1].isupper()):
                    return True
        return False


def macos_version() -> str:
    return platform.mac_ver()[0] or "unknown"


# MARK: - Main


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parents[2])
    parser.add_argument("--source", action="append", help="source dir relative to the root (repeatable)")
    parser.add_argument("--probe", action="store_true", help="ask this Mac's Objective-C runtime (macOS only)")
    parser.add_argument("--write", action="store_true", help="with --probe: merge the answers into the table")
    parser.add_argument("--list", action="store_true", help="print every super call with its key and verdict")
    opts = parser.parse_args()
    root = opts.root.resolve()

    types: dict[str, list[TypeInfo]] = defaultdict(list)
    calls: list[SuperCall] = []
    for src in opts.source or DEFAULT_SOURCES:
        for path in sorted((root / src).rglob("*.swift")):
            scan_file(path, root, types, calls)

    table_path = root / TABLE
    table = json.loads(table_path.read_text()) if table_path.exists() else {"macos": [], "keys": {}}

    resolved: list[tuple[SuperCall, str | None, str]] = []
    needed: set[str] = set()
    for call in calls:
        cls, how = resolve(call, types)
        key = key_for(cls, call) if cls else None
        if key:
            needed.add(key)
        resolved.append((call, key, how))

    failures: list[str] = []

    if opts.probe:
        if sys.platform != "darwin":
            print("check-objc-selectors: --probe needs macOS", file=sys.stderr)
            return 2
        runtime, version = Runtime(), macos_version()
        answers = {key: runtime.answers(key) for key in sorted(needed)}
        if opts.write:
            if version not in table["macos"]:
                table["macos"] = sorted(table["macos"] + [version], key=lambda v: [int(x) for x in v.split(".") if x.isdigit()])
            for key, value in answers.items():
                table["keys"].setdefault(key, {})[version] = value
            # Keys no super call needs any more go.
            table["keys"] = dict(sorted((k, v) for k, v in table["keys"].items() if k in needed))
            table_path.write_text(json.dumps(table, indent=1, sort_keys=False) + "\n")
            print(f"check-objc-selectors: wrote {len(answers)} keys for macOS {version} to {TABLE}")
        else:
            for key, value in answers.items():
                recorded = table["keys"].get(key, {})
                if value is False and recorded and all(recorded.values()):
                    failures.append(f"macOS {version} does not answer {key}, which the table records as answered")

    table_keys: dict[str, dict[str, bool | None]] = table["keys"]

    def answered(key: str) -> str:
        """`no` when a macOS that recorded the key does not answer it, `unprobed`, `unprobeable`
        (no Objective-C class of that name on any macOS: a Swift class or a parse miss), or `yes`."""
        rec = table_keys.get(key)
        if not rec:
            return "unprobed"
        if any(v is False for v in rec.values()):
            return "no"
        return "yes" if any(v is True for v in rec.values()) else "unprobeable"

    texts: dict[str, str] = {}
    for call, key, how in resolved:
        verdict = "ok"
        if key:
            state = answered(key)
            if state == "unprobed":
                verdict = "probe needed"
                failures.append(f"{call.path}:{call.line}: super.{call.member} ({key}): probe needed; "
                                f"run scripts/cmux-next/check-objc-selectors.py --probe --write on a Mac and commit {TABLE}")
            elif state == "unprobeable" and not any(ALLOW.search(line) for line in call.context + [call.statement]):
                verdict = "unprobeable"
                failures.append(f"{call.path}:{call.line}: super.{call.member} ({key}): no macOS has an Objective-C "
                                f"class {key.split(' ')[0]}; add its Objective-C ancestor to ALIASES or a reviewed "
                                f"// selector-allow: <reason>")
            elif state == "no":
                text = texts.setdefault(call.path, blank_comments_and_strings(
                    (root / call.path).read_text(encoding="utf-8", errors="replace")))
                if guarded(call, text):
                    verdict = "guarded"
                else:
                    verdict = "NOT ANSWERED"
                    missing = ", ".join(v for v, ok in table_keys[key].items() if ok is False)
                    failures.append(f"{call.path}:{call.line}: super.{call.member} sends a selector "
                                    f"{key.split(' ')[0]} does not implement on macOS {missing} "
                                    f"(unrecognized selector crash). Guard it with instancesRespond(to:) or drop the super call.")
        if opts.list:
            print(f"{call.path}:{call.line}\t{call.owner}\t{key or '-'}\t{verdict}\t{how}")

    for failure in failures:
        print(f"objc-selectors: {failure}", file=sys.stderr)
    print(f"check-objc-selectors: {len(calls)} super calls, {len(needed)} runtime keys, "
          f"{len(failures)} failure(s)")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
