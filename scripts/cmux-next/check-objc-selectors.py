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

Private API lookups (p10-stability-193). `--lookups` judges every runtime lookup in
`Packages/**/Sources`: NSClassFromString / objc_getClass / NSProtocolFromString / dlsym
and class_getInstanceMethod (nil when the OS lacks the name), NSSelectorFromString /
Selector("...") (raises when sent unanswered), value(forKey:) / setValue(_:forKey:) with a
literal key (raises on an unknown key) and swizzles (method_exchangeImplementations,
method_setImplementation, class_replaceMethod, class_addMethod). Each needs a guard, as
Chromium guards its SPI with respondsToSelector: and its swizzles with a found method
(base/apple/scoped_objc_class_swizzler.mm):
- a nil lookup is never force-unwrapped, `as!`-cast or bit-cast before a nil check;
- a selector is checked with responds(to:) / instancesRespond(to:) /
  class_respondsToSelector / class_getInstanceMethod in its function (its file for a
  stored one), or only goes where an unanswered selector is safe (`action:`, doCommand(by:));
- a literal KVC key's accessor (key, setKey:, _key, _setKey:, isKey, getKey) is checked so
  in its function before the call;
- a swizzle follows a class_getInstanceMethod / class_getClassMethod or a responds check in
  its function.
`// selector-allow: <reason>` (or the crash ratchet's `// crash-allow:`) on the line or the
three above escapes one. The guardrail `objc-private-lookup` refuses an unguarded lookup a
push adds (the local tier); CI does not run `--lookups`, which fails for an unguarded site
missing from the table's reviewed `lookup_baseline` (`--lookups --write` rewrites it). The literal names are probed per macOS major into the table's `lookups`:
`--probe --write` on a Mac, and in Tart VMs `--write-probe` (regenerates
scripts/fuzz/macos-matrix/probes/objc-lookups.swift), then `scripts/cmux-next/os-matrix.sh
--build JOB --os 14,15,26,27 --suite exec:objc-lookups --out DIR` and `--record DIR --write`.
Without --write, --probe and --record fail when a name the table records on that major is gone.

Usage: scripts/cmux-next/check-objc-selectors.py [--root REPO] [--source DIR ...]
                                                 [--probe [--write]] [--list]
                                                 [--lookups] [--write-probe] [--record DIR [--write]]
"""

from __future__ import annotations

import argparse
import bisect
import collections
import hashlib
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


    def lookup_present(self, plans: dict[str, tuple[str, list[str], list[str]]]) -> dict[str, bool]:
        """{key: whether this Mac has the name} for each probe_plan(); the same answers as PROBE_FILE's."""
        c, objc = self.c, self.objc
        for library in PROBE_LIBRARIES:
            try:
                c.CDLL(library, mode=c.RTLD_GLOBAL)
            except OSError:
                pass
        libc = c.CDLL("/usr/lib/libSystem.B.dylib")
        libc.dlsym.restype, libc.dlsym.argtypes = c.c_void_p, [c.c_void_p, c.c_char_p]
        vp, cp = c.c_void_p, c.c_char_p
        objc.objc_getProtocol.restype, objc.objc_getProtocol.argtypes = vp, [cp]
        objc.objc_copyClassList.restype, objc.objc_copyClassList.argtypes = c.POINTER(vp), [c.POINTER(c.c_uint)]
        objc.object_getClass.restype, objc.object_getClass.argtypes = vp, [vp]
        objc.class_copyIvarList.restype = c.POINTER(vp)
        objc.class_copyIvarList.argtypes = [vp, c.POINTER(c.c_uint)]
        objc.ivar_getName.restype, objc.ivar_getName.argtypes = cp, [vp]
        wanted_methods = {n for kind, names, _ in plans.values() if kind == "method" for n in names}
        wanted_ivars = {n for kind, _, ivars in plans.values() if kind == "method" for n in ivars}
        methods_found: set[str] = set()
        ivars_found: set[str] = set()
        if wanted_methods or wanted_ivars:
            count = c.c_uint()
            classes = objc.objc_copyClassList(c.byref(count))
            for k in range(count.value):
                cls = classes[k]
                for owner in (cls, objc.object_getClass(cls)):
                    n = c.c_uint()
                    methods = objc.class_copyMethodList(owner, c.byref(n))
                    for m in range(n.value):
                        name = objc.sel_getName(objc.method_getName(methods[m])).decode("utf-8", "replace")
                        if name in wanted_methods:
                            methods_found.add(name)
                n = c.c_uint()
                ivars = objc.class_copyIvarList(cls, c.byref(n))
                for m in range(n.value):
                    name = (objc.ivar_getName(ivars[m]) or b"").decode("utf-8", "replace")
                    if name in wanted_ivars:
                        ivars_found.add(name)
        answers = {}
        for key, (kind, names, ivars) in plans.items():
            if kind == "class":
                answers[key] = any(objc.objc_getClass(n.encode()) for n in names)
            elif kind == "protocol":
                answers[key] = any(objc.objc_getProtocol(n.encode()) for n in names)
            elif kind == "symbol":
                answers[key] = any(libc.dlsym(c.c_void_p(-2), n.encode()) for n in names)
            else:
                answers[key] = any(n in methods_found for n in names) or any(n in ivars_found for n in ivars)
        return answers


def macos_version() -> str:
    return platform.mac_ver()[0] or "unknown"


# MARK: - Private API lookups (p10-stability-193)

LOOKUP_SOURCES = ["Packages"]  # every package; only files under a `Sources` folder
PROBE_NAME = "objc-lookups"
PROBE_FILE = f"scripts/fuzz/macos-matrix/probes/{PROBE_NAME}.swift"
# The libraries the probes load before they answer (dlsym searches every image loaded RTLD_GLOBAL).
PROBE_LIBRARIES = [f"/System/Library/Frameworks/{fw}.framework/{fw}" for fw in Runtime.FRAMEWORKS] + [
    "/usr/lib/swift/libswift_Concurrency.dylib"]
# Lookups that answer nil when the OS lacks the name: (kind, the name's argument index).
NIL_LOOKUPS = {
    "NSClassFromString": ("class", 0), "objc_getClass": ("class", 0), "objc_lookUpClass": ("class", 0),
    "objc_getMetaClass": ("class", 0), "NSProtocolFromString": ("protocol", 0), "objc_getProtocol": ("protocol", 0),
    "dlsym": ("symbol", 1), "class_getInstanceMethod": ("method", None), "class_getClassMethod": ("method", None),
}
SELECTOR_LOOKUPS = ("NSSelectorFromString", "Selector", "sel_registerName", "sel_getUid")
SWIZZLES = ("method_exchangeImplementations", "method_setImplementation", "class_replaceMethod", "class_addMethod")
KVC_CALLS = ("value", "setValue")
LOOKUP_CALL = re.compile(r"(?<![\w#$])(%s)\s*\(" % "|".join([*NIL_LOOKUPS, *SELECTOR_LOOKUPS, *SWIZZLES, *KVC_CALLS]))
LOOKUP_HINT = re.compile(r"%s|forKey" % "|".join([*NIL_LOOKUPS, *SELECTOR_LOOKUPS, *SWIZZLES]))
# The checks that answer whether a selector is implemented, and which argument holds the selector.
# `to:` or, for an injected seam (`responds(Self.selector)`), the unlabeled first argument.
SELECTOR_CHECKS = {"responds": ("to", 0), "instancesRespond": ("to", 0), "class_respondsToSelector": (None, 1),
                   "class_getInstanceMethod": (None, 1), "class_getClassMethod": (None, 1)}
SELECTOR_CHECK = re.compile(r"(?<![\w$])(%s)\s*\(" % "|".join(SELECTOR_CHECKS))
CHECK_OPEN = re.compile(r"(?:\b(?:responds|instancesRespond)\s*\(\s*(?:to:)?|\b(?:class_respondsToSelector|"
                        r"class_getInstanceMethod|class_getClassMethod)\s*\([^()]*,)\s*(?:unsafe\s+)?$")
# Where an unanswered selector is safe: the responder chain and NSTextView check it before sending.
# A selector only compared (`case Self.action:`, `item.action == sel`) is never sent.
SAFE_CONSUMER = (r"(?:\baction:|\.action\s*=(?!=)|\bdoCommand\s*\(\s*by:|\btryToPerform\s*\(|\bsendAction\s*\(|\bcase\s+|"
                 r"[!=]==?\s*)\s*(?:unsafe\s+)?")
SAFE_OPEN = re.compile(SAFE_CONSUMER + "$")
# The reviewed escapes of a lookup: this check's, or the crash ratchet's for its dynamic_dispatch class.
LOOKUP_ALLOW = re.compile(r"//\s*(?:selector|crash)-allow:\s*\S")
SWIZZLE_GUARD = re.compile(r"\b(?:class_getInstanceMethod|class_getClassMethod|class_respondsToSelector)\s*\(|"
                           r"\b(?:responds|instancesRespond)\s*\(\s*to:")
BINDING = re.compile(r"\b(?:let|var)\s+([A-Za-z_]\w*)\s*(?::[^=\n]*)?=\s*(?:unsafe\s+)?(?:try[?!]?\s+)?$")
CONDITION = re.compile(r"\b(?:if|guard|while|case)\b")
# A string literal argument, in `Selector(("name"))`'s extra parentheses too.
LITERAL = re.compile(r'\s*(\(\s*)?"([^"\\\n]*)"\s*(?(1)\))\s*$')
SELECTOR_LITERAL = re.compile(
    r'(?:NSSelectorFromString|Selector|sel_registerName|sel_getUid)\(\s*(\(\s*)?"([^"\\\n]*)"\s*(?(1)\))\s*\)')
PROBE_KEY = re.compile(r"^[A-Za-z0-9_$.:]+$")
# A function, initializer, accessor or computed property: the line before its `{` (lexical, like DECL above).
FUNC_HEAD = re.compile(
    r"^[ \t]*(?:@[\w.]+(?:\([^()\n]*\))?[ \t]+)*(?:(?:public|private|fileprivate|internal|package|open|static|class|"
    r"final|override|mutating|nonmutating|nonisolated|convenience|required|dynamic|lazy)(?:\([^()\n]*\))?[ \t]+)*"
    r"(?:func\b|init\b|init[?!]|deinit\b|subscript\b|(?:get|set|willSet|didSet)\b|var[ \t]+\w+[ \t]*:[^=\n]*$)",
    re.M)


@dataclass
class Lookup:
    path: str
    line: int
    call: str
    kind: str  # class, protocol, symbol, method, selector, kvc-get, kvc-set, swizzle
    key: str | None  # the probed name ("class CABackdropLayer"); None for a computed name, a method or a swizzle
    guarded: bool
    how: str  # the guard, or what is missing
    text: str = ""  # the line, stripped (the baseline's key with the path)


def split_args(clean: str, open_index: int) -> tuple[list[tuple[str | None, int, int]], int]:
    """([(label, value start, value end)], the closing paren's index) of the call whose `(` is at OPEN_INDEX."""
    depth, i, start, spans = 0, open_index, open_index + 1, []
    while i < len(clean):
        c = clean[i]
        if c in "([{":
            depth += 1
        elif c in ")]}":
            depth -= 1
            if depth == 0:
                spans.append((start, i))
                break
        elif c == "," and depth == 1:
            spans.append((start, i))
            start = i + 1
        i += 1
    args = []
    for s, e in spans:
        m = re.match(r"\s*([A-Za-z_]\w*)\s*:(?!:)", clean[s:e])
        args.append((m.group(1), s + m.end(), e) if m else (None, s, e))
    if len(args) == 1 and not clean[args[0][1]:args[0][2]].strip():
        args = []
    return args, i


def function_spans(clean: str) -> list[tuple[int, int]]:
    """(`{` offset, `}` offset) of every function, initializer, accessor and computed property body."""
    spans, stack, boundary = [], [], 0
    for i, c in enumerate(clean):
        if c == "{":
            stack.append((i, FUNC_HEAD.search(clean, boundary, i) is not None))
            boundary = i + 1
        elif c == "}":
            if stack:
                start, is_function = stack.pop()
                if is_function:
                    spans.append((start, i))
            boundary = i + 1
        elif c == ";":
            boundary = i + 1
    return spans


def normalized(text: str) -> str:
    return re.sub(r"\s+", " ", re.sub(r"^\s*unsafe\s+", "", text)).strip()


def last_name(text: str) -> str | None:
    """`selector` for `selector`, `Self.selector` or `Flags.selector`; None for any other expression."""
    m = re.fullmatch(r"(?:[A-Za-z_]\w*\s*\.\s*)*([A-Za-z_]\w*)", text)
    return m.group(1) if m else None


def kvc_forms(key: str) -> set[str]:
    """The selectors KVC sends for KEY (Key-Value Coding Programming Guide, accessor search patterns)."""
    cap = key[:1].upper() + key[1:]
    return {key, f"get{cap}", f"is{cap}", f"_{key}", f"set{cap}:", f"_set{cap}:"}


def probe_plan(key: str) -> tuple[str, list[str], list[str]]:
    """(how to probe, the names any of which answers, the ivars any of which answers) for a lookup key."""
    kind, name = key.split(" ", 1)
    if kind in ("class", "protocol", "symbol"):
        return kind, [name], []
    if kind == "selector":
        return "method", [name], []
    cap = name[:1].upper() + name[1:]
    ivars = [f"_{name}", f"_is{cap}", name, f"is{cap}"]
    if kind == "kvc-get":
        return "method", [f"get{cap}", name, f"is{cap}", f"_{name}"], ivars
    return "method", [f"set{cap}:", f"_set{cap}:"], ivars


def scan_lookups(text: str, path: str = "") -> list[Lookup]:
    """Every private API lookup in one Swift file, judged."""
    if not LOOKUP_HINT.search(text):
        return []
    clean = blank_comments_and_strings(text)
    raw_lines = text.split("\n")
    clean_lines = clean.split("\n")
    starts = [0] + [i + 1 for i, c in enumerate(clean) if c == "\n"]
    spans = function_spans(clean)

    def line_of(pos: int) -> int:
        return bisect.bisect_right(starts, pos)

    def scope(pos: int) -> tuple[int, int]:
        inner = [(s, e) for s, e in spans if s < pos < e]
        return max(inner) if inner else (0, len(clean))

    def checked_selectors(start: int, end: int) -> list[str]:
        """The selector argument of every responds-style check in clean[start:end], as written."""
        found = []
        for m in SELECTOR_CHECK.finditer(clean, start, end):
            args, _ = split_args(clean, m.end() - 1)
            label, index = SELECTOR_CHECKS[m.group(1)]
            arg = next((a for a in args if label and a[0] == label), None) or (
                args[index] if len(args) > index and args[index][0] is None else None)
            if arg:
                found.append(normalized(text[arg[1]:arg[2]]))
        return found

    calls = []
    for m in LOOKUP_CALL.finditer(clean):
        name, pos = m.group(1), m.start(1)
        before = clean[starts[line_of(pos) - 1]:pos]
        if re.search(r"\bfunc\s+$", before):
            continue
        args, close = split_args(clean, m.end() - 1)
        calls.append((name, pos, args, close, before))

    # Names bound to a literal selector anywhere in the file: `let sel = NSSelectorFromString("_foo:")`.
    bound_literals: dict[str, set[str]] = defaultdict(set)
    for name, pos, args, close, before in calls:
        b = BINDING.search(before)
        if name in SELECTOR_LOOKUPS and b and args and (lit := LITERAL.match(text[args[0][1]:args[0][2]])):
            bound_literals[b.group(1)].add(lit.group(2))

    def literal_selectors(start: int, end: int) -> set[str]:
        out: set[str] = set()
        for arg in checked_selectors(start, end):
            if m := SELECTOR_LITERAL.fullmatch(arg):
                out.add(m.group(2))
            elif m := re.fullmatch(r"#selector\(\s*(getter|setter)\s*:\s*(?:[\w.]*\.)?(\w+)\s*\)", arg):
                out |= {m.group(2)} if m.group(1) == "getter" else {f"set{m.group(2)[:1].upper()}{m.group(2)[1:]}:"}
            elif (n := last_name(arg)) is not None:
                out |= bound_literals.get(n, set())
        return out

    found = []
    for name, pos, args, close, before in calls:
        line = line_of(pos)
        lo, hi = scope(pos)
        allowed = any(LOOKUP_ALLOW.search(raw) for raw in raw_lines[max(0, line - 4):line])

        def record(kind: str, key: str | None, guarded: bool, how: str) -> None:
            if allowed and not guarded:
                guarded, how = True, "a reviewed allow comment"
            found.append(Lookup(path, line, name, kind, key, guarded, how, normalized(raw_lines[line - 1])))

        def arg_literal(index: int) -> str | None:
            if len(args) <= index:
                return None
            lit = LITERAL.match(text[args[index][1]:args[index][2]])
            return lit.group(2) if lit else None

        binding = BINDING.search(before)
        conditional = binding is not None and (
            CONDITION.search(before[:binding.start()]) is not None
            or (not before[:binding.start()].strip() and line >= 2 and clean_lines[line - 2].rstrip().endswith(",")))
        if name in NIL_LOOKUPS:
            kind, index = NIL_LOOKUPS[name]
            literal = arg_literal(index) if index is not None else None
            key = f"{kind} {literal}" if literal and PROBE_KEY.match(literal) else None
            after = clean[close + 1:close + 8]
            if re.match(r"\s*(?:!(?!=)|as!)", after):
                record(kind, key, False, "force-unwrapped or `as!`-cast where the OS may answer nil")
            elif re.search(r"\bunsafeBitCast\s*\(\s*(?:unsafe\s+)?$", before):
                record(kind, key, False, "bit-cast before a nil check")
            elif binding and not conditional:
                var = re.escape(binding.group(1))
                rest = clean[close:hi]
                force = re.search(rf"\b{var}!(?!=)|\bunsafeBitCast\s*\(\s*(?:unsafe\s+)?{var}\b|\b{var}\s+as!", rest)
                check = re.search(rf"\b(?:if|guard|while)\b[^\n]*\blet\s+(?:{var}\b(?!\s*=)|\w+\s*=\s*(?:unsafe\s+)?{var}\b)"
                                  rf"|\b{var}\s*[!=]=\s*nil\b|\bnil\s*[!=]=\s*{var}\b", rest)
                if force and not (check and check.start() < force.start()):
                    record(kind, key, False, f"`{binding.group(1)}` is forced at line "
                                             f"{line_of(close + force.start())} before a nil check")
                else:
                    record(kind, key, True, "optional kept")
            else:
                record(kind, key, True, "optional kept")
        elif name in SELECTOR_LOOKUPS:
            if name == "Selector" and arg_literal(0) is None:
                continue  # Selector(someSelector): a conversion, not a lookup
            literal = arg_literal(0)
            key = f"selector {literal}" if literal and PROBE_KEY.match(literal) else None
            if CHECK_OPEN.search(before) or SAFE_OPEN.search(before):
                record("selector", key, True, "checked where it is looked up")
                continue
            if binding and not conditional:
                var = binding.group(1)
                # A stored selector (a property or a global: no function scope) is checked anywhere in its file.
                names = {last_name(a) for a in checked_selectors(lo, hi)}
                safe = re.search(SAFE_CONSUMER + rf"(?:[\w.]*\.)?{re.escape(var)}\b", clean[lo:hi])
                record("selector", key, var in names or safe is not None,
                       f"`{var}` is checked before a send" if var in names else
                       f"`{var}` is only an action or compared" if safe else
                       f"`{var}` is never checked with responds(to:) / instancesRespond(to:)")
            else:
                own = normalized(text[pos:close + 1])
                ok = own in checked_selectors(lo, hi)
                record("selector", key, ok, "the same lookup is checked" if ok else
                       "sent without a responds(to:) check")
        elif name in KVC_CALLS:
            if name == "value" and not (len(args) == 1 and args[0][0] in ("forKey", "forKeyPath")):
                continue
            if name == "setValue" and not (len(args) == 2 and args[1][0] in ("forKey", "forKeyPath")):
                continue
            key = arg_literal(len(args) - 1)
            if key is None or "." in key or not PROBE_KEY.match(key):
                continue  # a computed key or a key path: not one private name to probe
            kind = "kvc-get" if name == "value" else "kvc-set"
            ok = bool(kvc_forms(key) & literal_selectors(lo, pos))
            record(kind, f"{kind} {key}", ok, "its accessor is checked" if ok else
                   f"no responds(to:) check of `{key}` (or its setter) before it in its function")
        elif name in ("method_exchangeImplementations", "method_setImplementation"):
            record("swizzle", None, True, "a Method is non-optional in Swift: it came from a lookup that was checked")
        else:
            ok = SWIZZLE_GUARD.search(clean, lo, pos) is not None
            record("swizzle", None, ok, "the method was looked up first" if ok else
                   "no class_getInstanceMethod / responds(to:) check before it in its function")
    return found


def unguarded_lines(text: str) -> dict[int, str]:
    """{1-based line: why} of every unguarded lookup in one Swift file (the guardrail objc-private-lookup)."""
    out: dict[int, str] = {}
    for lookup in scan_lookups(text):
        if not lookup.guarded:
            out.setdefault(lookup.line, f"{lookup.call}: {lookup.how}")
    return out


def lookup_files(root: Path, sources: list[str]) -> list[Path]:
    return [p for src in sources for p in sorted((root / src).rglob("*.swift"))
            if "Sources" in p.relative_to(root).parts]


def keyset_id(keys: list[str]) -> str:
    return hashlib.sha256("\n".join(keys + ["--"] + PROBE_LIBRARIES).encode()).hexdigest()[:16]


def probe_source(keys: list[str]) -> str:
    """PROBE_FILE for KEYS: a self-contained Swift program that answers each key on the OS it runs on."""
    def swift(items: list[str]) -> str:
        return "[" + ", ".join(json.dumps(i) for i in items) + "]"

    rows = []
    for key in keys:
        kind, names, ivars = probe_plan(key)
        rows.append(f"    ({json.dumps(key)}, {json.dumps(kind)}, {swift(names)}, {swift(ivars)}),")
    generated = "\n".join([
        "// BEGIN GENERATED (scripts/cmux-next/check-objc-selectors.py --write-probe)",
        f"let keySet = {json.dumps(keyset_id(keys))}",
        "let libraries: [String] = [",
        *[f"    {json.dumps(lib)}," for lib in PROBE_LIBRARIES],
        "]",
        "let plan: [(key: String, kind: String, names: [String], ivars: [String])] = [",
        *rows,
        "]",
        "// END GENERATED",
    ])
    return PROBE_HEAD + generated + "\n" + PROBE_BODY


PROBE_HEAD = """\
// OS probe (vm.sh --suite exec --probe objc-lookups), p10-stability-193: which private names cmux looks up at run
// time (classes, protocols, symbols, selectors, KVC accessors) this macOS has. Generated by
// scripts/cmux-next/check-objc-selectors.py --write-probe, whose --record reads the output of
// `os-matrix.sh --suite exec:objc-lookups` into objc-selector-table.json per macOS major. Prints "ABSENT <key>" per
// missing name, then the summary line, and exits 0 when it ran (the answers are the data, not a verdict); 2 when
// the runtime could not be read. Self-contained, no package.
import Darwin
import Foundation

"""
PROBE_BODY = r"""
typealias CString = UnsafePointer<CChar>
typealias ByName = @convention(c) (CString) -> UnsafeRawPointer?
typealias CopyClassList = @convention(c) (UnsafeMutablePointer<UInt32>?) -> UnsafeMutablePointer<UnsafeRawPointer?>?
typealias CopyList = @convention(c) (UnsafeRawPointer?, UnsafeMutablePointer<UInt32>?) -> UnsafeMutablePointer<OpaquePointer?>?
typealias NameOf = @convention(c) (OpaquePointer) -> CString?
typealias SelectorOf = @convention(c) (OpaquePointer) -> OpaquePointer?
typealias ClassOf = @convention(c) (UnsafeRawPointer?) -> UnsafeRawPointer?

let defaultHandle = UnsafeMutableRawPointer(bitPattern: -2)

/// A runtime function with raw pointer types: a class held as AnyObject would be retained, and a retain messages
/// the class, which runs its +initialize.
func runtime<T>(_ name: String, as type: T.Type) -> T {
    guard let address = dlsym(defaultHandle, name) else {
        print("objc-lookups: the runtime has no \(name)")
        exit(2)
    }
    return unsafeBitCast(address, to: type)
}

for library in libraries { _ = dlopen(library, RTLD_LAZY | RTLD_GLOBAL) }
let getClass = runtime("objc_getClass", as: ByName.self)
let getProtocol = runtime("objc_getProtocol", as: ByName.self)
let copyClassList = runtime("objc_copyClassList", as: CopyClassList.self)
let copyMethodList = runtime("class_copyMethodList", as: CopyList.self)
let copyIvarList = runtime("class_copyIvarList", as: CopyList.self)
let methodName = runtime("method_getName", as: SelectorOf.self)
let selectorName = runtime("sel_getName", as: NameOf.self)
let ivarName = runtime("ivar_getName", as: NameOf.self)
let classOf = runtime("object_getClass", as: ClassOf.self)

var wantedMethods = Set<String>()
var wantedIvars = Set<String>()
for entry in plan where entry.kind == "method" {
    wantedMethods.formUnion(entry.names)
    wantedIvars.formUnion(entry.ivars)
}
var foundMethods = Set<String>()
var foundIvars = Set<String>()

/// The names in a runtime list of COUNT methods or ivars that WANTED holds; frees the list.
func matches(_ list: UnsafeMutablePointer<OpaquePointer?>?, _ count: UInt32, _ wanted: Set<String>,
             _ name: (OpaquePointer) -> CString?) -> [String] {
    guard let list else { return [] }
    defer { free(list) }
    var out: [String] = []
    for index in 0..<Int(count) {
        guard let item = list[index], let cName = name(item) else { continue }
        let text = String(cString: cName)
        if wanted.contains(text) { out.append(text) }
    }
    return out
}

if !wantedMethods.isEmpty || !wantedIvars.isEmpty {
    var classCount: UInt32 = 0
    guard let classes = copyClassList(&classCount) else {
        print("objc-lookups: objc_copyClassList answered nil")
        exit(2)
    }
    for index in 0..<Int(classCount) {
        guard let cls = classes[index] else { continue }
        for owner in [cls, classOf(cls)] {
            var count: UInt32 = 0
            let list = copyMethodList(owner, &count)
            foundMethods.formUnion(matches(list, count, wantedMethods) { method in
                methodName(method).flatMap { selectorName($0) }
            })
        }
        var count: UInt32 = 0
        let list = copyIvarList(cls, &count)
        foundIvars.formUnion(matches(list, count, wantedIvars) { ivarName($0) })
    }
    free(classes)
}

var absent: [String] = []
for entry in plan {
    let present: Bool
    switch entry.kind {
    case "class": present = entry.names.contains { name in name.withCString { getClass($0) } != nil }
    case "protocol": present = entry.names.contains { name in name.withCString { getProtocol($0) } != nil }
    case "symbol": present = entry.names.contains { dlsym(defaultHandle, $0) != nil }
    case "method": present = entry.names.contains { foundMethods.contains($0) } || entry.ivars.contains { foundIvars.contains($0) }
    default:
        print("objc-lookups: unknown kind \(entry.kind)")
        exit(2)
    }
    if !present { absent.append(entry.key) }
}
for key in absent { print("ABSENT \(key)") }
let os = ProcessInfo.processInfo.operatingSystemVersion
print("objc-lookups macOS \(os.majorVersion).\(os.minorVersion).\(os.patchVersion) keyset \(keySet): \(plan.count) keys, \(absent.count) absent")
exit(0)
"""
PROBE_ROW = re.compile(r'^\s*\("([^"]+)",', re.M)
PROBE_KEYSET = re.compile(r'^let keySet = "(\w+)"', re.M)
PROBE_SUMMARY = re.compile(r"^objc-lookups macOS (\S+) keyset (\w+): (\d+) keys, (\d+) absent\s*$", re.M)


def parse_probe_source(text: str) -> tuple[str, list[str]]:
    """(key set id, keys) of a generated PROBE_FILE; ValueError when its rows are not the ones its id names."""
    block = text.split("// BEGIN GENERATED", 1)[-1].split("// END GENERATED", 1)[0]
    keyset = PROBE_KEYSET.search(block)
    keys = PROBE_ROW.findall(block)
    if not keyset or keyset.group(1) != keyset_id(keys):
        raise ValueError(f"{PROBE_FILE} was edited by hand (its keySet does not match its rows); run --write-probe")
    return keyset.group(1), keys


def parse_probe_output(stdout: str, keyset: str, keys: list[str]) -> tuple[str, dict[str, bool]]:
    """(the guest's macOS version, {key: present}) from the probe's output; ValueError when it is not whole."""
    summaries = PROBE_SUMMARY.findall(stdout)
    if not summaries:
        raise ValueError("no summary line (the probe did not finish)")
    version, got, count, absent_count = summaries[-1]
    if got != keyset:
        raise ValueError(f"the probe ran key set {got}, {PROBE_FILE} has {keyset}: land --write-probe's file and rerun")
    absent = set(re.findall(r"^ABSENT (\S.*?)\s*$", stdout, re.M))
    if int(count) != len(keys) or len(absent) != int(absent_count):
        raise ValueError(f"{len(absent)} ABSENT lines for {absent_count} absent (the output was cut)")
    return version, {k: k not in absent for k in keys}


def major_of(version: str) -> str:
    return version.split(".")[0]


def record_lookups(table: dict, major: str, answers: dict[str, bool], needed: set[str]) -> None:
    """Merges ANSWERS under MAJOR into the table's lookups and drops the keys no source needs."""
    majors = set(table.get("lookup_majors", [])) | {major}
    table["lookup_majors"] = sorted(majors, key=lambda v: int(v) if v.isdigit() else 0)
    lookups = table.setdefault("lookups", {})
    for key, present in answers.items():
        if key in needed:
            lookups.setdefault(key, {})[major] = present
    table["lookups"] = {k: dict(sorted(v.items(), key=lambda kv: int(kv[0]) if kv[0].isdigit() else 0))
                        for k, v in sorted(lookups.items()) if k in needed}


def lookup_regressions(table: dict, major: str, answers: dict[str, bool]) -> list[str]:
    """The keys the table records as present on MAJOR that ANSWERS says are gone."""
    lookups = table.get("lookups", {})
    return [f"macOS {major} no longer has {key}, which the table records as present there"
            for key, present in sorted(answers.items()) if not present and lookups.get(key, {}).get(major) is True]


def read_matrix(out: Path, keyset: str, keys: list[str]) -> tuple[dict[str, dict[str, bool]], list[str]]:
    """({major: answers}, problems) from an os-matrix --suite exec:objc-lookups results folder."""
    found: dict[str, dict[str, bool]] = {}
    problems = []
    for result in sorted(out.glob("*/result.json")):
        try:
            data = json.loads(result.read_text())
        except (OSError, ValueError) as error:
            problems.append(f"{result}: unreadable ({error})")
            continue
        if data.get("probe") != PROBE_NAME:
            problems.append(f"{result}: not the {PROBE_NAME} probe ({data.get('probe')!r})")
            continue
        if data.get("verdict") != "PASS":
            problems.append(f"{result}: no answers on macOS {data.get('os')} ({data.get('verdict')}, exit "
                            f"{data.get('exit_code')})")
            continue
        stdout_file = result.parent / "probe.stdout"
        stdout = stdout_file.read_text(errors="replace") if stdout_file.exists() else data.get("stdout", "")
        try:
            version, answers = parse_probe_output(stdout, keyset, keys)
        except ValueError as error:
            problems.append(f"{result}: {error}")
            continue
        found[major_of(version)] = answers
    if not found and not problems:
        problems.append(f"{out}: no <major>/result.json")
    return found, problems


def lookup_presence(table: dict, key: str | None) -> str:
    if key is None:
        return "-"
    rec = table.get("lookups", {}).get(key)
    if not rec:
        return "unprobed"
    absent = [m for m, present in rec.items() if not present]
    return "absent on " + ",".join(absent) if absent else "present on " + ",".join(rec)


# MARK: - Main


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parents[2])
    parser.add_argument("--source", action="append", help="source dir relative to the root (repeatable)")
    parser.add_argument("--probe", action="store_true", help="ask this Mac's Objective-C runtime (macOS only)")
    parser.add_argument("--write", action="store_true", help="with --probe: merge the answers into the table")
    parser.add_argument("--list", action="store_true", help="print every super call with its key and verdict")
    parser.add_argument("--lookups", action="store_true",
                        help="judge every private API lookup in Packages/**/Sources (the local tier, not CI)")
    parser.add_argument("--write-probe", action="store_true", help=f"regenerate {PROBE_FILE} from the lookups")
    parser.add_argument("--record", type=Path, metavar="DIR",
                        help="read an os-matrix --suite exec:objc-lookups results folder (with --write: into the table)")
    opts = parser.parse_args()
    root = opts.root.resolve()
    if opts.lookups or opts.write_probe or opts.record:
        return lookups_main(opts, root)

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
        else:
            for key, value in answers.items():
                recorded = table["keys"].get(key, {})
                if value is False and recorded and all(recorded.values()):
                    failures.append(f"macOS {version} does not answer {key}, which the table records as answered")
        # The private API lookups' names, under this macOS's major (p10-stability-193).
        lookup_needed = needed_lookup_keys(root, opts.source or LOOKUP_SOURCES)
        present = runtime.lookup_present({k: probe_plan(k) for k in sorted(lookup_needed)})
        if opts.write:
            record_lookups(table, major_of(version), present, lookup_needed)
            table_path.write_text(json.dumps(table, indent=1, sort_keys=False) + "\n")
            print(f"check-objc-selectors: wrote {len(answers)} keys and {len(present)} lookups for macOS {version} "
                  f"to {TABLE}")
        else:
            failures += lookup_regressions(table, major_of(version), present)

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


def needed_lookup_keys(root: Path, sources: list[str]) -> set[str]:
    return {lookup.key for path in lookup_files(root, sources)
            for lookup in scan_lookups(path.read_text(encoding="utf-8", errors="replace"))
            if lookup.key is not None}


def baseline_entry(lookup: Lookup) -> str:
    return f"{lookup.path}: {lookup.text}"


def lookups_main(opts: argparse.Namespace, root: Path) -> int:
    """--lookups, --write-probe and --record."""
    sources = opts.source or LOOKUP_SOURCES
    lookups: list[Lookup] = []
    for path in lookup_files(root, sources):
        lookups += scan_lookups(path.read_text(encoding="utf-8", errors="replace"), str(path.relative_to(root)))
    needed = {lookup.key for lookup in lookups if lookup.key is not None}
    keys = sorted(needed)
    table_path = root / TABLE
    table = json.loads(table_path.read_text()) if table_path.exists() else {"macos": [], "keys": {}}
    probe_path = root / PROBE_FILE
    failures: list[str] = []

    if opts.write_probe:
        probe_path.write_text(probe_source(keys))
        print(f"check-objc-selectors: wrote {PROBE_FILE} ({len(keys)} keys, key set {keyset_id(keys)})")

    if opts.record:
        try:
            keyset, probe_keys = parse_probe_source(probe_path.read_text())
        except (OSError, ValueError) as error:
            print(f"objc-lookups: {error}", file=sys.stderr)
            return 2
        found, problems = read_matrix(opts.record, keyset, probe_keys)
        for problem in problems:
            print(f"objc-lookups: {problem}", file=sys.stderr)
        if not found:
            return 2
        for major, answers in sorted(found.items()):
            absent = sorted(k for k, present in answers.items() if not present)
            print(f"check-objc-selectors: macOS {major}: {len(answers)} keys, {len(absent)} absent"
                  + "".join(f"\n  absent: {k}" for k in absent))
            if opts.write:
                record_lookups(table, major, answers, needed)
            else:
                failures += lookup_regressions(table, major, answers)
        if opts.write:
            table_path.write_text(json.dumps(table, indent=1, sort_keys=False) + "\n")
            print(f"check-objc-selectors: wrote the lookups of macOS {', '.join(sorted(found))} to {TABLE}")

    if opts.lookups:
        # The unguarded sites older than this check, reviewed: each is fixed when its file is next edited (the
        # guardrail objc-private-lookup refuses a new one before a push).
        baseline = collections.Counter(table.get("lookup_baseline", []))
        if opts.write:
            table["lookup_baseline"] = sorted(baseline_entry(lookup) for lookup in lookups if not lookup.guarded)
            table_path.write_text(json.dumps(table, indent=1, sort_keys=False) + "\n")
            print(f"check-objc-selectors: wrote {len(table['lookup_baseline'])} unguarded sites to {TABLE}'s "
                  "lookup_baseline")
            baseline = collections.Counter(table["lookup_baseline"])
        for lookup in lookups:
            in_baseline = not lookup.guarded and baseline[baseline_entry(lookup)] > 0
            if in_baseline:
                baseline[baseline_entry(lookup)] -= 1
            if opts.list:
                verdict = "ok" if lookup.guarded else "baseline" if in_baseline else "UNGUARDED"
                print(f"{lookup.path}:{lookup.line}\t{lookup.call}\t{lookup.key or '-'}\t"
                      f"{verdict}\t{lookup.how}\t{lookup_presence(table, lookup.key)}")
            if not lookup.guarded and not in_baseline:
                failures.append(f"{lookup.path}:{lookup.line}: {lookup.call} ({lookup.key or lookup.kind}) is not "
                                f"guarded: {lookup.how}. Check nil / responds(to:) first, or a reviewed "
                                f"// selector-allow: <reason>")
        try:
            current = parse_probe_source(probe_path.read_text())[1] == keys
        except (OSError, ValueError):
            current = False
        if not current:
            failures.append(f"{PROBE_FILE} does not probe the current lookups: run "
                            f"scripts/cmux-next/check-objc-selectors.py --write-probe and commit it")
        unprobed = [k for k in keys if k not in table.get("lookups", {})]
        majors = ", ".join(table.get("lookup_majors", [])) or "none"
        print(f"check-objc-selectors: {len(lookups)} lookups, {len(keys)} probe keys ({len(unprobed)} unprobed; "
              f"majors recorded: {majors})")

    for failure in failures:
        print(f"objc-lookups: {failure}", file=sys.stderr)
    print(f"check-objc-selectors: {len(failures)} lookup failure(s)")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
