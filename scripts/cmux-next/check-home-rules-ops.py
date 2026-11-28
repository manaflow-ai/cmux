#!/usr/bin/env python3
"""Every home rules op the macOS app calls by name is one cmux-home-rules answers.

The app calls the Rust home rules (cmux-tui/crates/cmux-home-rules) through cmux_home_call with an op
name, `AREA.NAME` (ops.rs `call`). A name the table does not list answers unknownOp, and a debug build
stops on it: #59517 (104f8860, 2026-11-28) called the Hosted Chief's ops by bare name (`chiefs_tab`),
every debug build crashed at launch, and every Mac perf bench that launches the app read 0 rows until
#64336 added the `cloud.` prefix. Nothing failed in CI: the Swift compiles, and the Rust tests call the
ops by their right names.

This reads both sides from source:
- Rust: ops.rs AREAS, and each area module's `pub const OPS` (plus `ops.list`).
- Swift: every string literal passed to HomeRules.call / HomeRules.callJSON, and to any static wrapper
  that forwards its op parameter to one of those (directly or through another wrapper), with the
  wrapper's prefix (`area + op` with `static let area = "cloud."`, `"chief_home." + name`,
  `"compose.\\(name)"`, or none).

Instance wrappers (ChiefHomeRules, HomeComposeRules) are not followed: their callers hold the wrapper
in a variable. Run: python3 scripts/cmux-next/check-home-rules-ops.py [--root DIR] [--self-test]
"""
from __future__ import annotations

import argparse
import os
import re
import sys
import tempfile

RULES = "cmux-tui/crates/cmux-home-rules/src"
SWIFT = "Packages/macOS/CmuxNext/Sources"
BASE_CALLERS = {("HomeRules", "call"): "", ("HomeRules", "callJSON"): ""}

STRING_RE = re.compile(r'"((?:[^"\\]|\\.)*)"')
LINE_COMMENT_RE = re.compile(r"//[^\n]*")


def const_strings(text: str, name: str) -> list[str]:
    """The strings of `pub const NAME: &[&str] = &[ ... ];` in text, comments dropped."""
    m = re.search(r"pub const " + name + r"\s*:\s*&\[&str\]\s*=\s*&\[(.*?)\];", text, re.S)
    if not m:
        return []
    return STRING_RE.findall(LINE_COMMENT_RE.sub("", m.group(1)))


def rust_ops(root: str) -> set[str]:
    src = os.path.join(root, RULES)
    with open(os.path.join(src, "ops.rs"), encoding="utf-8") as f:
        areas = const_strings(f.read(), "AREAS")
    if not areas:
        raise SystemExit(f"check-home-rules-ops: no AREAS in {RULES}/ops.rs")
    names = {"ops.list"}
    for area in areas:
        for path in (os.path.join(src, area + ".rs"), os.path.join(src, area, "mod.rs")):
            if os.path.exists(path):
                with open(path, encoding="utf-8") as f:
                    ops = const_strings(f.read(), "OPS")
                if not ops:
                    raise SystemExit(f"check-home-rules-ops: no OPS in {os.path.relpath(path, root)}")
                names.update(f"{area}.{op}" for op in ops)
                break
        else:
            raise SystemExit(f"check-home-rules-ops: area {area} has no module under {RULES}")
    return names


def swift_files(root: str) -> dict[str, str]:
    out = {}
    for dirpath, _, files in os.walk(os.path.join(root, SWIFT)):
        for name in files:
            if name.endswith(".swift"):
                path = os.path.join(dirpath, name)
                with open(path, encoding="utf-8", errors="replace") as f:
                    out[os.path.relpath(path, root)] = f.read()
    return out


TYPE_RE = re.compile(r"\b(?:enum|struct|class|actor|extension)\s+(\w+)")
STATIC_FUNC_RE = re.compile(r"\bstatic\s+func\s+(\w+)\s*(?:<[^>]*>)?\s*\(\s*_\s+(\w+)\s*:\s*String")


def enclosing_type(text: str, at: int) -> str | None:
    found = None
    for m in TYPE_RE.finditer(text, 0, at):
        found = m.group(1)
    return found


def prefix_of(expr: str, param: str, text: str) -> str | None:
    """The fixed prefix the wrapper adds to its op parameter, or None when expr is not one we read."""
    expr = expr.strip()
    if expr == param:
        return ""
    m = re.fullmatch(r'"([^"\\]*)"\s*\+\s*' + re.escape(param), expr)
    if m:
        return m.group(1)
    m = re.fullmatch(r'"([^"\\]*)\\\(\s*' + re.escape(param) + r'\s*\)"', expr)
    if m:
        return m.group(1)
    m = re.fullmatch(r"(?:Self\.)?(\w+)\s*\+\s*" + re.escape(param), expr)
    if m:
        lit = re.search(r"\bstatic\s+let\s+" + re.escape(m.group(1)) + r'\s*(?::\s*String\s*)?=\s*"([^"\\]*)"', text)
        return lit.group(1) if lit else None
    return None


def wrappers(files: dict[str, str]) -> tuple[dict[tuple[str, str], str], dict[tuple[str, str], str]]:
    """(caller -> prefix, caller -> declaring file): HomeRules' own calls and every static wrapper that
    forwards its op parameter to a known caller, to a fixed point."""
    callers = dict(BASE_CALLERS)
    where: dict[tuple[str, str], str] = {}
    changed = True
    while changed:
        changed = False
        for path, text in files.items():
            for m in STATIC_FUNC_RE.finditer(text):
                func, param = m.group(1), m.group(2)
                owner = enclosing_type(text, m.start())
                if not owner or (owner, func) in callers:
                    continue
                body = text[m.end(): m.end() + 600]
                for (ctype, cfunc), cprefix in list(callers.items()):
                    call = re.search(r"\b" + ctype + r"\." + cfunc + r"\(\s*([^,()]+(?:\\\([^)]*\))?[^,()]*)\s*,", body)
                    if not call:
                        continue
                    own = prefix_of(call.group(1), param, text)
                    if own is None:
                        continue
                    callers[(owner, func)] = cprefix + own
                    where[(owner, func)] = path
                    changed = True
                    break
    return callers, where


def called_ops(files: dict[str, str]) -> list[tuple[str, int, str, str]]:
    """(file, line, op as called, caller) for every literal op name passed to a known caller."""
    callers, where = wrappers(files)
    out = []
    for path, text in files.items():
        for (ctype, cfunc), prefix in callers.items():
            names = [ctype] + (["Self"] if where.get((ctype, cfunc)) == path else [])
            for name in names:
                for m in re.finditer(r"\b" + name + r"\." + cfunc + r'\(\s*"((?:[^"\\]|\\.)*)"\s*[,)]', text):
                    literal = m.group(1)
                    if "\\(" in literal:
                        continue  # an interpolated name: not a fixed op
                    line = text.count("\n", 0, m.start()) + 1
                    out.append((path, line, prefix + literal, f"{ctype}.{cfunc}"))
    return out


def check(root: str) -> int:
    ops = rust_ops(root)
    calls = called_ops(swift_files(root))
    bad = [c for c in calls if c[2] not in ops]
    for path, line, op, caller in sorted(bad):
        print(f"{path}:{line}: {caller} calls home rules op {op!r}, which cmux-home-rules does not list "
              f"(ops.rs answers unknownOp; a debug build stops at it)")
    print(f"check-home-rules-ops: {len(calls)} calls, {len(ops)} ops, {len(bad)} unknown")
    return 1 if bad else 0


def self_test() -> int:
    """The #59517 shape fails, the #64336 shape passes."""
    rust = {"ops.rs": 'pub const AREAS: &[&str] = &[\n    "cloud",\n];\n',
            "cloud/mod.rs": 'pub const OPS: &[&str] = &[\n    // tabs\n    "chiefs_tab",\n];\n'}
    model = ('public struct HomeRules {\n    public static func call<In, Out>(_ op: String, _ input: In) throws -> Out {}\n}\n'
             'func f() { let _: X = try HomeRules.call("cloud.chiefs_tab", 1) }\n')
    engine = 'struct HomeEngineRules {\n    static func call<In, Out>(_ op: String, _ input: In) throws -> Out {\n        try HomeRules.call(op, input)\n    }\n}\n'
    bare = ('enum ChiefRules {\n    static func rule<In, Out>(_ op: String, _ input: In, else f: Out) -> Out {\n'
            '        return try HomeEngineRules.call(op, input)\n    }\n}\n'
            'func g() { ChiefRules.rule("chiefs_tab", 1, else: 2) }\n')
    fixed = bare.replace("HomeEngineRules.call(op, input)", "HomeEngineRules.call(area + op, input)").replace(
        "enum ChiefRules {\n", 'enum ChiefRules {\n    static let area = "cloud."\n')
    results = []
    for chief, want in ((bare, 1), (fixed, 0)):
        with tempfile.TemporaryDirectory() as root:
            for rel, body in rust.items():
                path = os.path.join(root, RULES, rel)
                os.makedirs(os.path.dirname(path), exist_ok=True)
                with open(path, "w") as f:
                    f.write(body)
            for rel, body in (("A/HomeRules.swift", model), ("B/Engine.swift", engine), ("C/Chief.swift", chief)):
                path = os.path.join(root, SWIFT, rel)
                os.makedirs(os.path.dirname(path), exist_ok=True)
                with open(path, "w") as f:
                    f.write(body)
            results.append(check(root) == want)
    print("check-home-rules-ops self-test:", "ok" if all(results) else f"FAILED {results}")
    return 0 if all(results) else 1


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--root", default=os.path.normpath(os.path.join(os.path.dirname(__file__), "..", "..")))
    parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args()
    if args.self_test:
        return self_test()
    return check(args.root)


if __name__ == "__main__":
    sys.exit(main())
