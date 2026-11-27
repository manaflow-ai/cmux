#!/usr/bin/env python3
"""Ratchet for synchronous Rust bridge calls where they cost the most in CmuxNext.

Leo, 2026-11-27: "can u guys take this thread: https://manaflow-workspace.slack.com/archives/C0CG8V89NER/p1795759419492319".
The thread: cmux#59531 made `ChiefMascotPicks.picked` JSON-encode the whole settings file (`fileRoot`, 157 KB)
for a Rust `welcome.*` op, and the sidebar asked it per Chief per row in `SidebarRowFeed.flush`: 2 to 6 s on the
main thread at 1,100 workspaces. Each half of that is a rule here; check-main-actor-work.py cannot see either,
because the encode sits behind a `nonisolated` wrapper (`welcomeRule`) several calls away from the row.

Rules (grep level, by name; the scope tracking and masking are check-main-actor-work.py's):

1. "sync Rust bridge call in row, frame or body code": a call, in row code, of a declaration that reaches a
   synchronous Rust bridge call (HomeRules.call, HomeRust.call, welcomeRule, dockRule, the cmux_*_call FFI
   symbols, CloudStartCore/CloudMachineRules/CloudMoveCore.call, LaunchSnapshot.rule) directly or through other
   declarations, followed by name to a fixed point. Row code: a SwiftUI `var body`, a `ForEach` and its
   closure, a row, cell, flush, draw or layout function (ROW_FUNC), and a closure passed as a per-row argument
   (ROW_CLOSURE, such as `chiefAvatar:`). Cost there is calls times rows times frames: compute it once per
   change, off the main actor or in Rust over all rows in one call, and read a Swift cache in the row.
2. "whole settings file (fileRoot) over the bridge": a bare `fileRoot` (not subscripted, not `.value(at:)`)
   passed to a declaration that hands that parameter on bare, through any number of calls, as a field of a Rust
   bridge request. Send only the keys the rule reads.

A name declared AMBIGUOUS_AT times or more, or one the standard library also declares (NOT_FOLLOWED), is not followed, so a common name does not
spread reach to every caller; such a call is missed, not flagged.

A reviewed exception carries `// bridge-ok: <reason>` on the line or in the comment block directly above.
The check is a ratchet like check-main-actor-work.py: scripts/cmux-next/bridge-on-main-baseline.json holds the
per-file, per-rule counts of origin/feat-cmux-next; above fails, below is a note (lower it with
`--update-baseline`), so a fix never waits on this file.

Usage: scripts/cmux-next/check-bridge-on-main.py [--root <repo>] [--update-baseline] [--list] [--why]
"""

from __future__ import annotations

import argparse
import bisect
import importlib.util
import json
import os
import re
import subprocess
import sys
from typing import NamedTuple

HERE = os.path.dirname(os.path.abspath(__file__))
_spec = importlib.util.spec_from_file_location("check_main_actor_work", os.path.join(HERE, "check-main-actor-work.py"))
assert _spec and _spec.loader
_work = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(_work)

# Comments and string-literal contents, for a regex mask: check-main-actor-work.py's mask_code is exact (nested
# comments, strings inside interpolations) but walks characters in Python, 150 s over CmuxNext's 50 MB; this is
# one regex pass. An interpolation holding a quote can unmask a few characters of a string; at grep level that
# only adds or drops a token.
_MASKED = re.compile(r'//[^\n]*|/\*.*?\*/|(?P<h>#+)"(?:"")?.*?(?:"")?"(?P=h)|"""(?:\\.|[^\\])*?"""|"(?:\\.|[^"\\\n])*"', re.S)
_NOT_NEWLINE = re.compile(r"[^\n]")


def _blank(m: re.Match) -> str:
    text = m.group()
    if text.startswith("/"):
        return _NOT_NEWLINE.sub(" ", text)
    quote = text.index('"')
    tail = len(text) - text.rindex('"')
    return text[:quote + 1] + _NOT_NEWLINE.sub(" ", text[quote + 1:len(text) - tail]) + text[len(text) - tail:]


def mask_code(text: str) -> str:
    """TEXT with comments and string contents blanked, same length and line breaks."""
    return _MASKED.sub(_blank, text)

PACKAGE = "Packages/macOS/CmuxNext"
BASELINE = "scripts/cmux-next/bridge-on-main-baseline.json"
ROW_RULE = "sync Rust bridge call in row, frame or body code"
FILE_RULE = "whole settings file (fileRoot) over the bridge"

# A synchronous call into Rust: each encodes its request as JSON, crosses the FFI and decodes the reply.
SEED = re.compile(r"\bHomeRules\.call(Data)?\s*\(|\bHomeRust\.call\s*\(|(?<![\w.])welcomeRule\s*\(|(?<![\w.])dockRule\s*\("
                  r"|\bcmux_\w+_(call|apply)\s*\(|\b(CloudStartCore|CloudMachineRules|CloudMoveCore)\(\)\.call(Data)?\s*\("
                  r"|\bLaunchSnapshot\.rule\s*\(")
SEED_NAME = "Rust bridge"

# Every other synchronous FFI call that crosses a serialized payload (bytes or a C string in, or a C string out):
# read from the crates' C headers, so a new `cmux_*` export is covered the day it lands (the brief, 2026-11-27:
# "ban synchronous Rust FFI calls in sidebar row and flush code paths"). Scalar calls (`cmux_motion_ease(curve, t)`)
# and the `_free` / `_abi_version` helpers stay out: they cost nanoseconds.
FFI_HEADERS = ("cmux-tui/crates", "Packages")
_C_COMMENT = re.compile(r"/\*.*?\*/|//[^\n]*", re.S)
_C_DECL = re.compile(r"(?P<ret>[A-Za-z_][\w \t*]*?)\b(?P<name>cmux_\w+)\s*\((?P<params>[^;{}()]*)\)\s*;")
_PAYLOAD = re.compile(r"\bchar\s*\*|\buint8_t\s*\*|\bvoid\s*\*\s*\w*\s*,\s*size_t\b")
_CHEAP = re.compile(r"_(free|abi_version|version)$")


def payload_ffi(root: str) -> list[str]:
    """Names of the `cmux_*` C functions whose declarations pass a payload, from the tracked headers."""
    out = subprocess.run(["git", "-C", root, "ls-files", "--", *(f"{d}/*.h" for d in FFI_HEADERS)],
                         capture_output=True, text=True)
    names: set[str] = set()
    for rel in out.stdout.split():
        if "/vendor/" in rel or "/Tests/" in rel:
            continue
        try:
            with open(os.path.join(root, rel), encoding="utf-8", errors="replace") as handle:
                text = _C_COMMENT.sub(" ", handle.read())
        except OSError:
            continue
        for m in _C_DECL.finditer(text):
            if _CHEAP.search(m.group("name")):
                continue
            if _PAYLOAD.search(m.group("params")) or "char" in m.group("ret") and "*" in m.group("ret"):
                names.add(m.group("name"))
    return sorted(names)


def extend_seed(root: str) -> None:
    """Add the headers' payload FFI calls to SEED (once per run)."""
    global SEED
    names = payload_ffi(root)
    if names:
        SEED = re.compile(SEED.pattern + r"|(?<![\w.])(" + "|".join(map(re.escape, names)) + r")\s*\(")
ALLOW = re.compile(r"//\s*bridge-ok:\s*\S")
COMMENT_ONLY = re.compile(r"^\s*(//|\*|/\*)")
DECL = re.compile(r"(?<![\w.])(func\s+(?P<func>[A-Za-z_]\w*)|var\s+(?P<var>[A-Za-z_]\w*)\s*:|subscript\s*(?=\())")
# Row, frame and per-row code: functions by name, and closures by argument label.
ROW_FUNC = re.compile(r"^(flush\w*|passSections|laneRowSource|rowSource|rows?|row\w*For|make(Row|Cell)\w*|cell\w*|draw|layout"
                      r"|updateNSView|updateUIView|tableView|outlineView|collectionView)$")
ROW_CLOSURE = re.compile(r"\b(chiefAvatar|rowSource|row|rows|cell|avatar)\s*:\s*\{")
BODY_VAR = re.compile(r"(?<![\w.])var\s+body\s*:\s*some\s+View\b")
FOR_EACH = re.compile(r"\bForEach\s*\(")
FILE_ROOT = re.compile(r"\bfileRoot\b(?!\s*[?!]?\s*(\[|\.value\b|\.objectValue\b))")
AMBIGUOUS_AT = 3
NOT_FOLLOWED = {"body", "init", "call", "callData", "description", "id", "value", "hash", "encode", "decode", "map", "flatMap",
                "compactMap", "filter", "reduce", "sorted", "sort", "first", "last", "contains", "append", "insert", "remove",
                "removeValue", "removeAll", "joined", "split", "compare", "min", "max", "index", "forEach", "count", "prefix",
                "suffix", "dropFirst", "dropLast", "union", "subtract", "merge", "updateValue", "send", "yield", "finish",
                "withUnsafeBytes", "withCString", "withLock", "run", "start", "stop", "cancel", "update", "load", "save", "read",
                "write", "observe", "apply", "make", "resolve", "string", "data", "object", "array", "number", "bool", "values",
                "keys", "key", "name", "jsonObject", "decoded", "encoded", "text", "label", "title", "url", "path", "error", "result", "state", "event", "unknown"}


class Decl(NamedTuple):
    file: str
    name: str
    kind: str  # func, var, subscript
    start: int  # offset of the declaration keyword
    open: int  # offset of its body's `{`
    end: int  # offset of its body's `}`
    params: list  # [(label, local name, type text)]


def _match_brace(masked: str, opening: int) -> int:
    depth = 0
    for k in range(opening, len(masked)):
        c = masked[k]
        if c == "{":
            depth += 1
        elif c == "}":
            depth -= 1
            if depth == 0:
                return k
    return len(masked)


def _params(signature: str) -> list:
    """[(label, local, type)] of a function signature's top-level parameter list."""
    open_ = signature.find("(")
    if open_ < 0:
        return []
    depth, segment, out = 0, open_ + 1, []
    for k in range(open_, len(signature)):
        c = signature[k]
        if c in "([<":
            depth += 1
        elif c in ")]>":
            depth -= 1
            if depth == 0 and c == ")":
                parts = [signature[segment:k]]
                break
        if c == "," and depth == 1:
            out.append(signature[segment:k])
            segment = k + 1
    else:
        return []
    raw = out + parts
    params = []
    for item in raw:
        if ":" not in item:
            continue
        names, typ = item.split(":", 1)
        words = names.replace("inout", "").split()
        if not words:
            continue
        label, local = (words[0], words[1]) if len(words) > 1 else (words[0], words[0])
        params.append((label, local, typ.strip()))
    return params


BRACKET = re.compile(r"[()\[\]{}]")
SIGNATURE_STOP = re.compile(r"[()\[\]{}=]|\n(?=\s*(?:@\w+\s*)*(?:(?:public|private|internal|fileprivate|open|static|final|override"
                            r"|nonisolated|mutating|class)\s+)*(?:func|var|let|init|case|subscript|struct|enum|class)\b)")


def brace_map(masked: str) -> dict[int, int]:
    """{offset of each `{`, `(` or `[`: offset of its closer} of MASKED, in one pass."""
    out, stack = {}, []
    for m in BRACKET.finditer(masked):
        c = m.group()
        if c in "({[":
            stack.append(m.start())
        elif stack:
            out[stack.pop()] = m.start()
    for opening in stack:
        out[opening] = len(masked)
    return out


def declarations(path: str, masked: str, closers: dict[int, int]) -> list[Decl]:
    decls = []
    for m in DECL.finditer(masked):
        name = m.group("func") or m.group("var") or "subscript"
        kind = "func" if m.group("func") else ("var" if m.group("var") else "subscript")
        # The body's `{`: the first at bracket depth 0 after the signature; none (a protocol requirement, a
        # stored property) when a `}`, a `=` (a var's) or the next declaration comes first.
        open_, k = -1, m.end()
        while True:
            stop = SIGNATURE_STOP.search(masked, k)
            if stop is None:
                break
            c = stop.group()
            if c in "([":
                k = closers.get(stop.start(), len(masked)) + 1
                continue
            if c == "{":
                open_ = stop.start()
            elif c == "=" and kind != "var":
                k = stop.end()
                continue
            break
        if open_ < 0:
            continue
        end = closers.get(open_, len(masked))
        params = _params(masked[m.end():open_]) if kind != "var" else []
        decls.append(Decl(path, name, kind, m.start(), open_, end, params))
    return decls


def _line_of(text: str, offset: int) -> int:
    return text.count("\n", 0, offset) + 1


def allowed(lines: list[str], index: int) -> bool:
    if ALLOW.search(lines[index]):
        return True
    j = index - 1
    while j >= 0 and COMMENT_ONLY.match(lines[j]):
        if ALLOW.search(lines[j]):
            return True
        j -= 1
    return False


class Source(NamedTuple):
    path: str
    text: str
    masked: str
    lines: list
    decls: list
    closers: dict


def load(root: str) -> list[Source]:
    sources_dir = os.path.join(root, PACKAGE, "Sources")
    out = []
    for dirpath, _, files in os.walk(sources_dir):
        for filename in sorted(files):
            if not filename.endswith(".swift"):
                continue
            path = os.path.join(dirpath, filename)
            with open(path, encoding="utf-8", errors="replace") as handle:
                text = handle.read()
            masked = mask_code(text)
            relative = os.path.relpath(path, root).replace(os.sep, "/")
            closers = brace_map(masked)
            out.append(Source(relative, text, masked, text.split("\n"), declarations(relative, masked, closers), closers))
    out.sort(key=lambda s: s.path)
    return out


def _innermost(decls: list[Decl], offset: int) -> Decl | None:
    best = None
    for d in decls:
        if d.open < offset < d.end and (best is None or d.open > best.open):
            best = d
    return best


# A call (`name(`, `name {` a trailing closure) or a subscripted read (`name[`, a computed dictionary such as
# `chiefFaces[chief]`). A bare member read (`.isChief`) is not followed: most are stored properties.
TOKEN = re.compile(r"(?<![\w])\.?(?P<c>[A-Za-z_]\w*)(?=\(|\[|\s+\{)")


def tokens(s: Source) -> tuple[list[int], list[str]]:
    """Offsets and names of every call (`name(`, `name[`, `name {`) and member read (`.name`) in S, in order."""
    offsets, names = [], []
    for m in TOKEN.finditer(s.masked):
        offsets.append(m.start())
        names.append(m.group("c"))
    return offsets, names


def _slice(tok: tuple[list[int], list[str]], start: int, end: int):
    offsets, names = tok
    i = bisect.bisect_left(offsets, start)
    while i < len(offsets) and offsets[i] < end:
        yield offsets[i], names[i]
        i += 1


def reach(sources: list[Source], toks: dict[str, tuple]) -> dict[str, str]:
    """{name: the callee it reaches the bridge through} for every followed name that reaches a Rust bridge call."""
    counts: dict[str, int] = {}
    for s in sources:
        for d in s.decls:
            counts[d.name] = counts.get(d.name, 0) + 1
    followed = lambda n: n not in NOT_FOLLOWED and counts.get(n, 0) < AMBIGUOUS_AT
    via: dict[str, str] = {}
    callers: dict[str, set[str]] = {}
    for s in sources:
        for d in s.decls:
            if not followed(d.name):
                continue
            for _, n in _slice(toks[s.path], d.open, d.end):
                callers.setdefault(n, set()).add(d.name)
        for m in SEED.finditer(s.masked):
            d = _innermost(s.decls, m.start())
            if d is not None and followed(d.name) and d.name not in via:
                via[d.name] = SEED_NAME
    queue = list(via)
    while queue:
        callee = queue.pop()
        for caller in sorted(callers.get(callee, ())):
            if caller not in via:
                via[caller] = callee
                queue.append(caller)
    return via


def chain(name: str, via: dict[str, str]) -> str:
    out, seen = [name], {name}
    while out[-1] in via and via[out[-1]] != SEED_NAME and via[out[-1]] not in seen:
        out.append(via[out[-1]])
        seen.add(out[-1])
    out.append(SEED_NAME)
    return " -> ".join(out)


def _row_regions(s: Source) -> list[tuple[int, int, str]]:
    regions = []
    for d in s.decls:
        if d.kind == "func" and ROW_FUNC.match(d.name):
            regions.append((d.open, d.end, f"func {d.name}"))
    for m in BODY_VAR.finditer(s.masked):
        d = next((d for d in s.decls if d.start == m.start()), None)
        if d is not None:
            regions.append((d.open, d.end, "var body"))
    for m in FOR_EACH.finditer(s.masked):
        close = s.closers.get(m.end() - 1, len(s.masked))
        k = close + 1
        while k < len(s.masked) and s.masked[k] in " \t\n":
            k += 1
        end = s.closers.get(k, len(s.masked)) if k < len(s.masked) and s.masked[k] == "{" else close
        regions.append((m.start(), end, "ForEach"))
    for m in ROW_CLOSURE.finditer(s.masked):
        opening = m.end() - 1
        regions.append((opening, s.closers.get(opening, len(s.masked)), f"{m.group(1)}: closure"))
    return regions


def row_hits(sources: list[Source], via: dict[str, str], toks: dict[str, tuple]) -> list[tuple[str, int, str, str]]:
    hits = []
    for s in sources:
        seen_lines: set[int] = set()
        for start, end, region in _row_regions(s):
            found = [(m.start(), SEED_NAME) for m in SEED.finditer(s.masked, start, end)]
            found += [(o, chain(n, via)) for o, n in _slice(toks[s.path], start, end) if n in via]
            for offset, what in sorted(found):
                line = _line_of(s.masked, offset)
                if line in seen_lines or allowed(s.lines, line - 1):
                    continue
                seen_lines.add(line)
                hits.append((s.path, line, ROW_RULE, f"{region}: {what}: {s.lines[line - 1].strip()}"))
    return hits


def _bare(masked: str, local: str, start: int, end: int, labels: set[str] | None) -> list[int]:
    """Offsets in MASKED[START:END] where LOCAL is passed bare as an argument: `label: LOCAL` followed by `,` or
    `)` (any label when LABELS is None)."""
    rx = re.compile(rf"(?:\b(?P<l>\w+)\s*:\s*)?(?<![\w.]){re.escape(local)}\s*(?=[,)])")
    out = []
    for m in rx.finditer(masked, start, end):
        label = m.group("l")
        if labels is None and label is not None:
            out.append(m.start())
        elif labels is not None and (label in labels or (label is None and "_" in labels)):
            out.append(m.start())
    return out


def sinks(sources: list[Source], via: dict[str, str]) -> dict[str, set[str]]:
    """{declaration name: argument labels} whose JSON parameter that declaration hands on bare, through any
    number of calls, as a field of a Rust bridge request."""
    out: dict[str, set[str]] = {}
    # Direct: a declaration that makes a bridge call and passes a JSONValue parameter bare into a labeled argument.
    sources = [s for s in sources if "JSONValue" in s.text]
    for s in sources:
        for d in s.decls:
            if not SEED.search(s.masked, d.open, d.end) and not (d.name in via and via[d.name] == SEED_NAME):
                continue
            for label, local, typ in d.params:
                if "JSONValue" in typ and _bare(s.masked, local, d.open, d.end, None):
                    out.setdefault(d.name, set()).add(label)
    changed = True
    while changed:
        changed = False
        for s in sources:
            for d in s.decls:
                for label, local, typ in d.params:
                    if "JSONValue" not in typ or label in out.get(d.name, set()):
                        continue
                    for sink, labels in list(out.items()):
                        for call in re.finditer(rf"(?<![\w]){re.escape(sink)}\s*\(", s.masked[d.open:d.end]):
                            opening = d.open + call.end() - 1
                            close = s.closers.get(opening, len(s.masked))
                            if _bare(s.masked, local, opening + 1, close, labels):
                                out.setdefault(d.name, set()).add(label)
                                changed = True
                                break
    return out


def file_hits(sources: list[Source], sink: dict[str, set[str]]) -> list[tuple[str, int, str, str]]:
    hits = []
    for s in sources:
        if "fileRoot" not in s.text:
            continue
        for name, labels in sink.items():
            for call in re.finditer(rf"(?<![\w]){re.escape(name)}\s*\(", s.masked):
                opening = call.end() - 1
                close = s.closers.get(opening, len(s.masked))
                for label, (a, b) in _work._arguments(s.masked, opening + 1, close).items():
                    if label in labels and FILE_ROOT.search(s.masked, a, b):
                        line = _line_of(s.masked, a)
                        if not allowed(s.lines, line - 1):
                            hits.append((s.path, line, FILE_RULE, f"{name}({label}:): {s.lines[line - 1].strip()}"))
                if "_" in labels:
                    first = s.masked[opening + 1:close].split(",", 1)[0]
                    if ":" not in first and FILE_ROOT.search(first):
                        line = _line_of(s.masked, opening)
                        if not allowed(s.lines, line - 1):
                            hits.append((s.path, line, FILE_RULE, f"{name}(_:): {s.lines[line - 1].strip()}"))
        for m in SEED.finditer(s.masked):
            close = s.closers.get(m.end() - 1, len(s.masked))
            if FILE_ROOT.search(s.masked, m.end(), close):
                line = _line_of(s.masked, m.start())
                if not allowed(s.lines, line - 1):
                    hits.append((s.path, line, FILE_RULE, f"{SEED_NAME}: {s.lines[line - 1].strip()}"))
    return hits


def collect(root: str) -> dict[str, dict[str, list[tuple[int, str]]]]:
    extend_seed(root)
    sources = load(root)
    toks = {s.path: tokens(s) for s in sources}
    via = reach(sources, toks)
    result: dict[str, dict[str, list[tuple[int, str]]]] = {}
    for f, line, rule, text in row_hits(sources, via, toks) + file_hits(sources, sinks(sources, via)):
        result.setdefault(f, {}).setdefault(rule, []).append((line, text))
    for rules in result.values():
        for items in rules.values():
            items.sort()
    return result


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", default=None)
    parser.add_argument("--update-baseline", action="store_true")
    parser.add_argument("--list", action="store_true", help="print every hit, not only the ratchet result")
    args = parser.parse_args()
    root = args.root or subprocess.run(["git", "rev-parse", "--show-toplevel"], capture_output=True, text=True,
                                       check=True).stdout.strip()
    hits = collect(root)
    counts = {f: {r: len(v) for r, v in rules.items()} for f, rules in sorted(hits.items())}
    baseline_path = os.path.join(root, BASELINE)
    if args.update_baseline:
        with open(baseline_path, "w", encoding="utf-8") as handle:
            json.dump(counts, handle, indent=1, sort_keys=True)
            handle.write("\n")
        total = sum(sum(r.values()) for r in counts.values())
        print(f"check-bridge-on-main: baseline written ({total} hits in {len(counts)} files)")
        return 0
    if args.list:
        for f, rules in sorted(hits.items()):
            for rule, items in sorted(rules.items()):
                for line, text in items:
                    print(f"{f}:{line}: {rule}: {text}")
    baseline: dict[str, dict[str, int]] = {}
    if os.path.exists(baseline_path):
        with open(baseline_path, encoding="utf-8") as handle:
            baseline = json.load(handle)
    failures = lowered = 0
    for f, rules in counts.items():
        for rule, count in rules.items():
            allowed_count = baseline.get(f, {}).get(rule, 0)
            if count > allowed_count:
                failures += 1
                print(f"bridge-on-main violation: {f}: {rule}: {count} hit(s), baseline {allowed_count}")
                for line, text in hits[f][rule]:
                    print(f"    {f}:{line}: {text}")
    for f, rules in baseline.items():
        for rule, allowed_count in rules.items():
            if counts.get(f, {}).get(rule, 0) < allowed_count:
                lowered += 1
                print(f"bridge-on-main: {f}: {rule}: {counts.get(f, {}).get(rule, 0)} hit(s), below baseline "
                      f"{allowed_count}: lower it with scripts/cmux-next/check-bridge-on-main.py --update-baseline")
    if failures:
        print(f"check-bridge-on-main: {failures} file/rule count(s) above the baseline. Cache the Rust answer in "
              "Swift (computed once per settings or rows change, read by the row), batch the rows into one call, "
              "or send only the keys the rule reads; `// bridge-ok: <reason>` for a reviewed exception.")
        return 1
    # A fix lowers a count without failing, so the fixes in flight (and this check) land in any order.
    total = sum(sum(r.values()) for r in counts.values())
    print(f"check-bridge-on-main: OK ({total} baselined hits in {len(counts)} files)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
