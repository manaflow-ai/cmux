#!/usr/bin/env python3
"""Full-tree static audit of idle wakeups (plans/cmux-next/chrome-parity/p14-energy.md, sections C and 6).

Nothing in cmux may poll. This audit finds every timer, sleep, timed wait, spin loop and repeating
animation in the code that runs while the app is idle:

  swift         Packages/macOS/CmuxNext/Sources (not CmuxNextWakeups, which holds the sanctioned primitives)
  swift-shared  Sources/ of the Packages/Shared and Packages/macOS packages CmuxNext's Package.swift links
                (`.package(path:`); Mock/ and TestSupport/ folders there are in the linked targets
  rust          cmux-tui/crates/*/src, without test-only items (`#[cfg(test)]`, `#[test]`, the
                test-support feature) and the module files declared inside them (tests/, benches/ and
                examples/ are outside src)
  web           webviews/src, without tests, gallery and dev-server

The Swift rules are check-concurrency.sh's WAKEUP_RULES (read from that file, one definition), plus
TimelineView(.periodic / .animation), NSWindow.didUpdateNotification and `.activeAlways`.

A hit is escaped by `wakeup-allow: <word> <reason>` on its line or in the comment block directly above.
The word is one of deadline|backoff|bounded|cli-only|fixture|debug|periodic. `periodic <owner>` must name
an owner in idle-budget.json `allowed_periodic` ([{owner, period_s, why}]). `--strict` exits 1 on any
unescaped hit, any other escape word, and any periodic escape whose owner is not listed.

Each hit has a shape. `loop`: it sits in a loop (or is a repeating source) whose path has no untimed
blocking wait, so it wakes the process on a period: make it an event, a deadline or MaintenanceClock.
`oneshot`: a single deadline (an escape is allowed when its code shape matches).

Modes:
  (none)               counts per language and rule
  --json               every hit with its status, shape and escape word
  --queue              group<TAB>file:line<TAB>rule<TAB>loop|oneshot, one line per unescaped hit
  --queue demand-sync  DemandTimer closures on the main actor whose body has no `await` (Q13)
  --lang L[,L]         swift, swift-shared, rust, web (default all)
  --strict             exit 1 on unescaped hits, bad escape words or unlisted periodic escapes
"""
from __future__ import annotations

import argparse
import bisect
import json
import os
import re
import sys
from collections import Counter
from dataclasses import asdict, dataclass, field
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
LANGS = ("swift", "swift-shared", "rust", "web")
ESCAPE_WORDS = ("deadline", "backoff", "bounded", "cli-only", "fixture", "debug", "periodic")
ESCAPE = re.compile(r"wakeup-allow:\s*([^\s,;:.()]*)\s*([^\s,;:()]*)")
COMMENT_ONLY = re.compile(r"^\s*(//|\*|/\*)")
# idle-budget.json: at most this many periodic owners, none faster than this (p14-energy.md D1).
PERIODIC_MAX = 6
PERIODIC_MIN_S = 15

CMUXNEXT = "Packages/macOS/CmuxNext"
WAKEUP_PRIMITIVES_MODULE = "CmuxNextWakeups"
# Test targets; Mock/ and TestSupport/ folders inside a library target are linked into the app and audited.
SHARED_SKIP_DIRS = {"Tests"}
WEB_SKIP_DIRS = {"test", "dev-server", "gallery", "node_modules"}
WEB_SKIP_FILE = re.compile(r"\.(test|gallery)\.")


@dataclass(frozen=True)
class Rule:
    id: str
    why: str
    pattern: re.Pattern[str]
    # A repeating source by itself (an interval, an infinite animation): always `loop`.
    repeating: bool = False
    # Text every match contains: a file without it is not searched (speed only).
    literal: str = ""
    # Matches inside string literals count (an inline style's `animation: "spin 1s infinite"`).
    in_strings: bool = False


@dataclass
class Hit:
    lang: str
    group: str
    file: str
    line: int
    rule: str
    shape: str
    status: str  # hit | escaped | bad-escape | periodic-unlisted
    escape: str = ""
    text: str = field(default="", repr=False)


# ---------------------------------------------------------------------------------------------------------------
# Rules


def swift_wakeup_rules(repo: Path) -> list[Rule]:
    """check-concurrency.sh's SLEEP_CALL and WAKEUP_RULES, evaluated from its source (one definition)."""
    text = (repo / "scripts/cmux-next/check-concurrency.sh").read_text(encoding="utf-8")
    start = text.index("SLEEP_CALL = (")
    end = text.index("WAKEUP_ALLOW =", start)
    scope: dict[str, object] = {}
    exec(compile(text[start:end], "check-concurrency.sh:WAKEUP_RULES", "exec"), {"__builtins__": {}}, scope)
    rules = []
    for name, rx in scope["WAKEUP_RULES"]:  # type: ignore[union-attr]
        slug = re.sub(r"[^a-z]+", "-", name.split(" (", 1)[0].lower()).strip("-")
        rules.append(Rule(slug, name, re.compile(rx), repeating=slug == "raw-display-link"))
    return rules + [
        Rule("timeline-view", "TimelineView(.periodic/.animation) redraws on a schedule (use a FrameClient or an event)",
             re.compile(r"\bTimelineView\(\s*\.(periodic|animation)\b"), repeating=True),
        Rule("did-update", "NSWindow.didUpdateNotification fires on every event-loop pass (observe the real change)",
             re.compile(r"\bNSWindow\.didUpdateNotification\b"), repeating=True),
        Rule("active-always", ".activeAlways tracking areas wake the app for mouse moves while inactive "
             "(use .activeInKeyWindow or .activeInActiveApp)", re.compile(r"\.activeAlways\b")),
    ]


# Rust: definitions (`fn wait_timeout(`) are not calls.
_NOT_DEF = r"(?<!fn )"
RUST_RULES = [
    Rule("recv-timeout", "timed channel receive (wait for the message; a deadline only for a one-shot timeout)",
         re.compile(r"\.recv_timeout\("), literal="recv_timeout("),
    Rule("tokio-sleep", "async sleep (await the event; wake::deadline or MaintenanceClock for time)",
         re.compile(_NOT_DEF + r"(?:\btokio::time::|\btime::|(?<![\w:.]))sleep\("), literal="sleep("),
    Rule("wait-timeout", "timed wait on a condvar or child (wait for the event)",
         re.compile(_NOT_DEF + r"\bwait_timeout\("), literal="wait_timeout("),
    Rule("thread-sleep", "thread sleep (block on the event; a deadline for a one-shot timeout)",
         re.compile(r"\bthread::sleep\("), literal="thread::sleep("),
    Rule("read-timeout", "socket read timeout (block on readiness; it wakes the reader on every timeout)",
         re.compile(r"(?:\.|\b\w+::)set_read_timeout\((?!(?:\s*self\s*,)?\s*None\s*\))"), literal="set_read_timeout("),
    Rule("try-wait", "child exit polled with try_wait (wait for NOTE_EXIT / pidfd)",
         re.compile(r"\.try_wait\("), literal="try_wait("),
    Rule("tokio-interval", "tokio interval (an event, or MaintenanceClock for maintenance)",
         re.compile(_NOT_DEF + r"(?:\btokio::time::|\btime::|(?<![\w:.]))interval\("), repeating=True,
         literal="interval("),
]

WEB_RULES = [
    Rule("set-interval", "setInterval (push from the host, or schedule only while visible)",
         re.compile(r"\bsetInterval\("), repeating=True, literal="setInterval("),
    Rule("css-infinite", "infinite animation (bound it, or gate it on visibility and the motion setting)",
         re.compile(r"\binfinite\b"), repeating=True, literal="infinite", in_strings=True),
]

# Untimed blocking waits: a loop that holds one of these wakes on an event, not on a period.
RUST_EVENT = re.compile(
    r"\.recv\(\)|\.accept\(\)|\.read(?:_exact|_line|_to_end|_to_string)?\(|\.next\(\)\s*\.await|\.changed\(\)"
    r"|\.notified\(\)|\.wait\(\s*\w*\s*\)|\.join\(\)|\.incoming\(\)|\.recv_many\(")
SWIFT_EVENT = re.compile(r"\bfor\s+(try\s+)?await\b|\bawait\b[^\n]*\.(next|value|receive|read|accept)\(|"
                         r"\bwith(Checked|Unsafe)(Throwing)?Continuation\b")


# ---------------------------------------------------------------------------------------------------------------
# Masking: comment and string contents become spaces (newlines kept), so rules see code only.

_RUST_TOKEN = re.compile(r"//|/\*|b?r#*\"|b?\"|'")
_SWIFT_TOKEN = re.compile(r"//|/\*|#*\"\"\"|#*\"")
_WEB_TOKEN = re.compile(r"//|/\*|[\"'`]|/")
_CSS_TOKEN = re.compile(r"/\*|[\"']")
_RUST_CHAR = re.compile(r"'(?:\\(?:x[0-9a-fA-F]{2}|u\{[0-9a-fA-F]+\}|.)|[^\\'\n])'")
_REGEX_BEFORE = re.compile(r"(?:^|[(,=:\[!&|?{};]|\breturn)\s*$")


_NOT_NEWLINE = re.compile(r"[^\n]")


def _end_of_block_comment(text: str, i: int, nested: bool) -> int:
    depth = 1
    j = i + 2
    while j < len(text) and depth:
        if nested and text.startswith("/*", j):
            depth += 1
            j += 2
        elif text.startswith("*/", j):
            depth -= 1
            j += 2
        else:
            j += 1
    return j


def _end_of_quoted(text: str, j: int, quote: str, multiline: bool) -> int:
    """Index after the closing quote, from j just after the opening one (backslash escapes)."""
    while j < len(text):
        c = text[j]
        if c == "\\":
            j += 2
            continue
        if c == quote:
            return j + 1
        if c == "\n" and not multiline:
            return j
        j += 1
    return j


def mask(text: str, lang: str, strings: bool = True) -> str:
    """`text` with comments blanked, and string and regex contents too unless `strings` is false."""
    token = {"rust": _RUST_TOKEN, "swift": _SWIFT_TOKEN, "web": _WEB_TOKEN, "css": _CSS_TOKEN}[lang]
    out: list[str] = []
    kept = i = 0
    while True:
        m = token.search(text, i)
        if not m:
            break
        s, tok = m.start(), m.group()
        if tok == "//":
            e = text.find("\n", s)
            e = len(text) if e < 0 else e
        elif tok == "/*":
            e = _end_of_block_comment(text, s, nested=lang in ("rust", "swift"))
        elif lang == "rust" and tok == "'":
            c = _RUST_CHAR.match(text, s)
            if not c:  # a lifetime or a label
                i = s + 1
                continue
            e = c.end()
        elif lang == "rust" and "#" in tok:
            hashes = tok.count("#")
            close = text.find('"' + "#" * hashes, m.end())
            e = len(text) if close < 0 else close + 1 + hashes
        elif lang == "swift" and tok.endswith('"""'):
            hashes = tok.count("#")
            close = text.find('"""' + "#" * hashes, m.end())
            e = len(text) if close < 0 else close + 3 + hashes
        elif lang == "swift" and tok.startswith("#"):
            hashes = tok.count("#")
            close = text.find('"' + "#" * hashes, m.end())
            nl = text.find("\n", m.end())
            e = len(text) if close < 0 else close + 1 + hashes
            if 0 <= nl < close:
                e = nl
        elif lang == "web" and tok == "/":
            line_start = text.rfind("\n", 0, s) + 1
            if not _REGEX_BEFORE.search(text[line_start:s]):
                i = s + 1
                continue
            e = _end_of_regex(text, s + 1)
        else:
            e = _end_of_quoted(text, m.end(), tok[-1], multiline=tok == "`" or lang == "rust")
        # Comments go entirely; strings and regexes keep their delimiters, so they still read as expressions.
        if strings or tok in ("//", "/*"):
            start, end = (s, e) if tok in ("//", "/*") else (m.end(), max(m.end(), e - 1))
            out += [text[kept:start], _NOT_NEWLINE.sub(" ", text[start:end])]
            kept = end
        i = max(e, s + 1)
    out.append(text[kept:])
    return "".join(out)


def _end_of_regex(text: str, j: int) -> int:
    in_class = False
    while j < len(text) and text[j] != "\n":
        c = text[j]
        if c == "\\":
            j += 2
            continue
        if c == "[":
            in_class = True
        elif c == "]":
            in_class = False
        elif c == "/" and not in_class:
            return j + 1
        j += 1
    return j


# ---------------------------------------------------------------------------------------------------------------
# Blocks: loops, and the boundaries (functions, closures, async blocks) a loop does not reach through.


@dataclass
class Block:
    header_start: int
    open: int
    close: int
    kind: str  # loop | boundary | plain


_RUST_LOOP = re.compile(r"\bloop\s*$|^(?:'\w+\s*:\s*)?(?:while\b|for\b.*\bin\b)", re.S)
_RUST_BOUNDARY = re.compile(r"\bfn\b|\|[^|]*\|\s*(?:->\s*[^{]+)?$|\|\|\s*$|\basync(?:\s+move)?\s*$", re.S)
_SWIFT_LOOP = re.compile(r"^(?:\w+\s*:\s*)?(?:while\b|repeat\s*$|for\b.*\bin\b)", re.S)
_SWIFT_CONTROL = re.compile(r"^(?:if|else|guard|switch|case|default|do|catch|defer|while|for|repeat)\b|\belse\s*$|"
                            r"\belse\s+if\b", re.S)


def blocks(code: str, lang: str) -> list[Block]:
    out: list[Block] = []
    stack: list[Block] = []
    boundary = 0
    for m in re.finditer(r"[{};]", code):
        c, at = m.group(), m.start()
        if c == "{":
            header = code[boundary:at].strip()
            if lang == "rust":
                kind = "loop" if _RUST_LOOP.search(header) else "boundary" if _RUST_BOUNDARY.search(header) else "plain"
            else:
                kind = "loop" if _SWIFT_LOOP.search(header) else "plain" if _SWIFT_CONTROL.search(header) else "boundary"
            stack.append(Block(boundary, at, len(code), kind))
            out.append(stack[-1])
        elif c == "}" and stack:
            stack.pop().close = at
        boundary = at + 1
    return out


def shape(at: int, code: str, all_blocks: list[Block], event: re.Pattern[str]) -> str:
    """`loop` when the innermost loop around `at`, inside the same function or closure, has no untimed wait."""
    enclosing = sorted((b for b in all_blocks if b.header_start <= at <= b.close), key=lambda b: -b.open)
    for b in enclosing:
        if b.kind == "boundary" and at > b.open:
            return "oneshot"
        if b.kind == "loop":
            return "oneshot" if event.search(code, b.header_start, b.close) else "loop"
    return "oneshot"


# ---------------------------------------------------------------------------------------------------------------
# Rust: test-only items (`#[cfg(test)]`, `#[test]`, the test-support feature) and every module file declared
# inside one, or inside a test-only file.

_TEST_CFG = r"test|all\s*\(\s*test\b[^\]]*|feature\s*=\s*\"test-support\"|any\s*\(\s*test\s*,\s*feature\s*=\s*\"test-support\"\s*\)"
_TEST_ATTR = re.compile(r"#\[\s*(?:cfg\s*\(\s*(?:" + _TEST_CFG + r")\s*\)|(?:tokio::)?test\b[^\]]*)\]")
_INNER_TEST = re.compile(r"#!\[\s*cfg\s*\(\s*(?:" + _TEST_CFG + r")\s*\)\s*\]")
_ATTR = re.compile(r"\s*#\[(?:[^\[\]]|\[[^\]]*\])*\]")
_MOD_ITEM = re.compile(r"\bmod\s+(\w+)\s*([;{])")
_PATH_ATTR = re.compile(r"#\[\s*path\s*=\s*\"([^\"]+)\"\s*\]")
_ITEM_START = re.compile(r"[;{}][^;{}]*$")
_BRACE = re.compile(r"[{}]")


@dataclass(frozen=True)
class RustModules:
    """One file's test-only character ranges and the module files it declares (path, declared test-only)."""
    test_ranges: list[tuple[int, int]]
    children: list[tuple[Path, bool]]


def rust_modules(code: str, raw: str, path: Path) -> RustModules:
    # Attributes are matched in the raw text (masking blanks `"test-support"`), at a `#` that is code.
    def attrs(pattern: re.Pattern[str]) -> list[re.Match[str]]:
        return [m for m in pattern.finditer(raw) if code[m.start()] == "#"]

    if attrs(_INNER_TEST):
        ranges = [(0, len(code))]
    else:
        ranges = []
        for m in attrs(_TEST_ATTR):
            if ranges and m.start() < ranges[-1][1]:
                continue
            j = m.end()
            while a := _ATTR.match(code, j):
                j = a.end()
            brace, semi = code.find("{", j), code.find(";", j)
            if semi >= 0 and (brace < 0 or semi < brace):
                ranges.append((m.start(), semi + 1))
            elif brace >= 0:
                ranges.append((m.start(), matching_brace(code, brace) + 1))
    inline = [(m.group(1), m.end() - 1, matching_brace(code, m.end() - 1))
              for m in _MOD_ITEM.finditer(code) if m.group(2) == "{"]
    children = []
    for m in _MOD_ITEM.finditer(code):
        if m.group(2) != ";":
            continue
        chain = [name for name, open_, close in inline if open_ < m.start() < close]
        head = _ITEM_START.search(code, 0, m.start())
        attr = _PATH_ATTR.search(raw, head.start() if head else 0, m.start())
        in_test = any(a <= m.start() < b for a, b in ranges)
        children += [(p, in_test) for p in _module_files(path, chain, m.group(1), attr.group(1) if attr else None)]
    return RustModules(ranges, children)


def matching_brace(code: str, open_: int) -> int:
    """Index of the `}` that closes the `{` at `open_` (the end of the text when unbalanced)."""
    depth = 0
    for m in _BRACE.finditer(code, open_):
        depth += 1 if m.group() == "{" else -1
        if depth == 0:
            return m.start()
    return len(code)


def _module_files(parent: Path, chain: list[str], name: str, path_attr: str | None) -> list[Path]:
    """The file of `mod name;` declared in `parent` inside the inline modules `chain`."""
    own_dir = parent.parent / parent.stem
    # A file loaded by `#[path]` resolves its children like a mod.rs file, so its directory is tried too.
    bases = [parent.parent] if parent.name in ("mod.rs", "lib.rs", "main.rs") else [own_dir, parent.parent]
    if path_attr:
        return [((bases[0].joinpath(*chain) if chain else parent.parent) / path_attr).resolve()]
    for base in bases:
        found = [p.resolve() for p in (base.joinpath(*chain, f"{name}.rs"), base.joinpath(*chain, name, "mod.rs"))
                 if p.exists()]
        if found:
            return found
    return []


def rust_test_files(modules: dict[Path, RustModules]) -> set[Path]:
    """Files declared inside a test-only item, and every file a test-only file declares."""
    test = {child for mods in modules.values() for child, in_test in mods.children if in_test}
    todo = list(test)
    while todo:
        mods = modules.get(todo.pop())
        for child, _ in mods.children if mods else []:
            if child not in test:
                test.add(child)
                todo.append(child)
    return test


# ---------------------------------------------------------------------------------------------------------------
# Sources


def app_linked_packages(repo: Path) -> list[Path]:
    """Packages/Shared and Packages/macOS packages that CmuxNext's Package.swift links by path."""
    manifest = repo / CMUXNEXT / "Package.swift"
    if not manifest.exists():
        return []
    out = []
    for line in manifest.read_text(encoding="utf-8").splitlines():
        m = re.match(r'\s*\.package\(\s*path:\s*"([^"]+)"', line)
        if not m:
            continue
        target = (manifest.parent / m.group(1)).resolve()
        rel = target.relative_to(repo.resolve()).as_posix() if target.is_relative_to(repo.resolve()) else ""
        if rel.startswith(("Packages/Shared/", "Packages/macOS/")) and target.is_dir():
            out.append(target)
    return out


def _walk(root: Path, suffixes: tuple[str, ...], skip_dirs: set[str] = frozenset()) -> list[Path]:
    found = []
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames[:] = sorted(d for d in dirnames if d not in skip_dirs)
        found += [Path(dirpath) / f for f in sorted(filenames) if f.endswith(suffixes)]
    return found


def sources(repo: Path, lang: str) -> list[tuple[str, Path]]:
    """(group, path) for every file of `lang` in the audit."""
    if lang == "swift":
        root = repo / CMUXNEXT / "Sources"
        return [(f"swift:{p.relative_to(root).parts[0]}", p) for p in _walk(root, (".swift",))
                if p.relative_to(root).parts[0] != WAKEUP_PRIMITIVES_MODULE]
    if lang == "swift-shared":
        return [(f"swift-shared:{pkg.name}", p) for pkg in app_linked_packages(repo)
                for p in _walk(pkg / "Sources", (".swift",), SHARED_SKIP_DIRS)]
    if lang == "rust":
        crates = repo / "cmux-tui/crates"
        out = []
        for crate in sorted(crates.iterdir()) if crates.is_dir() else []:
            src = crate / "src"
            for p in _walk(src, (".rs",)) if src.is_dir() else []:
                part = p.relative_to(src).parts[0].removesuffix(".rs")
                out.append((f"rust:{crate.name}/{part}", p))
        return out
    root = repo / "webviews/src"
    return [(f"web:{p.relative_to(root).parts[0].split('.')[0]}", p)
            for p in _walk(root, (".ts", ".tsx", ".css"), WEB_SKIP_DIRS) if not WEB_SKIP_FILE.search(p.name)]


# ---------------------------------------------------------------------------------------------------------------
# Audit


def escape_of(lines: list[str], index: int) -> re.Match[str] | None:
    """The wakeup-allow escape on the line, or in the comment block directly above it."""
    if m := ESCAPE.search(lines[index]):
        return m
    j = index - 1
    while j >= 0 and COMMENT_ONLY.match(lines[j]):
        if m := ESCAPE.search(lines[j]):
            return m
        j -= 1
    return None


def judge(escape: re.Match[str] | None, periodic_owners: set[str]) -> tuple[str, str]:
    if escape is None:
        return "hit", ""
    word, owner = escape.group(1), escape.group(2).rstrip(".")
    if word not in ESCAPE_WORDS:
        return "bad-escape", word
    if word == "periodic" and owner not in periodic_owners:
        return "periodic-unlisted", f"periodic {owner}".strip()
    return "escaped", word


def audit_file(repo: Path, lang: str, group: str, path: Path, rules: list[Rule], periodic_owners: set[str],
               skip: list[tuple[int, int]] = (), raw: str | None = None, code: str | None = None) -> list[Hit]:
    raw = path.read_text(encoding="utf-8", errors="replace") if raw is None else raw
    if not any(rule.literal in raw for rule in rules):
        return []
    mlang = "css" if path.suffix == ".css" else "web" if lang == "web" else "rust" if lang == "rust" else "swift"
    code = mask(raw, mlang) if code is None else code
    lines = raw.split("\n")
    starts = [0] + [m.end() for m in re.finditer("\n", code)]
    tree = blocks(code, mlang) if mlang in ("rust", "swift") else []
    event = RUST_EVENT if mlang == "rust" else SWIFT_EVENT
    rel = path.relative_to(repo).as_posix()
    with_strings = mask(raw, mlang, strings=False) if any(r.in_strings and r.literal in raw for r in rules) else code
    found: dict[tuple[int, str], int] = {}
    for rule in rules:
        text = with_strings if rule.in_strings else code
        if rule.literal not in text:
            continue
        for m in rule.pattern.finditer(text):
            index = bisect.bisect_right(starts, m.start()) - 1
            if (index, rule.id) not in found and not any(a <= m.start() < b for a, b in skip):
                found[(index, rule.id)] = m.start()
    hits = []
    for (index, rule_id), at in sorted(found.items()):
        rule = next(r for r in rules if r.id == rule_id)
        status, word = judge(escape_of(lines, index), periodic_owners)
        kind = "loop" if rule.repeating else shape(at, code, tree, event)
        hits.append(Hit(lang, group, rel, index + 1, rule.id, kind, status, word, lines[index].strip()))
    return hits


def periodic_owners(budget: Path) -> tuple[set[str], list[str]]:
    """allowed_periodic owners from idle-budget.json, and the entries that break its limits."""
    if not budget.exists():
        return set(), []
    entries = json.loads(budget.read_text(encoding="utf-8")).get("allowed_periodic", [])
    problems = []
    if len(entries) > PERIODIC_MAX:
        problems.append(f"allowed_periodic has {len(entries)} entries (at most {PERIODIC_MAX})")
    for entry in entries:
        if not entry.get("owner") or not entry.get("why"):
            problems.append(f"allowed_periodic entry without owner or why: {entry}")
        if float(entry.get("period_s") or 0) < PERIODIC_MIN_S:
            problems.append(f"allowed_periodic {entry.get('owner')}: period_s below {PERIODIC_MIN_S}")
    return {e["owner"] for e in entries if e.get("owner")}, problems


def audit(repo: Path, langs: list[str], budget: Path) -> tuple[list[Hit], list[str]]:
    owners, problems = periodic_owners(budget)
    hits: list[Hit] = []
    for lang in langs:
        rules = RUST_RULES if lang == "rust" else WEB_RULES if lang == "web" else swift_wakeup_rules(repo)
        files = sources(repo, lang)
        prepared: dict[Path, tuple[str, str | None, list[tuple[int, int]]]] = {}
        if lang == "rust":
            modules: dict[Path, RustModules] = {}
            for _, path in files:
                raw = path.read_text(encoding="utf-8", errors="replace")
                code = mask(raw, "rust") if "test" in raw or "mod " in raw else None
                if code is not None:
                    modules[path.resolve()] = rust_modules(code, raw, path)
                mods = modules.get(path.resolve())
                prepared[path] = (raw, code, mods.test_ranges if mods else [])
            test_files = rust_test_files(modules)
            files = [(g, p) for g, p in files if p.resolve() not in test_files]
        for group, path in files:
            raw, code, ranges = prepared.get(path, (None, None, []))
            hits += audit_file(repo, lang, group, path, rules, owners, ranges, raw, code)
    return hits, problems


# ---------------------------------------------------------------------------------------------------------------
# Q13: DemandTimer closures on the main actor that never await (a sync overload runs them in the callout).

_SCHEDULE = re.compile(r"\.schedule(?:IfIdle)?\(\s*after:")


def demand_sync(repo: Path) -> list[Hit]:
    root = repo / CMUXNEXT / "Sources"
    hits = []
    for path in _walk(root, (".swift",)):
        raw = path.read_text(encoding="utf-8", errors="replace")
        if "DemandTimer" not in raw or ".schedule" not in raw:
            continue
        code = mask(raw, "swift")
        starts = [0] + [m.end() for m in re.finditer("\n", code)]
        for m in _SCHEDULE.finditer(code):
            body = _closure_after_call(code, m.end() - len("after:") - 1)
            if not body:
                continue
            open_, close = body
            if not re.match(r"\s*@MainActor\b", code[open_ + 1:close]) or re.search(r"\bawait\b", code[open_:close]):
                continue
            line = bisect.bisect_right(starts, m.start())
            rel = path.relative_to(repo).as_posix()
            hits.append(Hit("swift", f"swift:{path.relative_to(root).parts[0]}", rel, line, "demand-sync", "oneshot",
                            "hit", "", raw.split("\n")[line - 1].strip()))
    return hits


def _closure_after_call(code: str, paren: int) -> tuple[int, int] | None:
    """The closure argument of the call whose `(` is at `paren`: inside the parens or trailing it."""
    depth, j, open_ = 0, paren, None
    while j < len(code):
        c = code[j]
        if c == "(":
            depth += 1
        elif c == ")":
            depth -= 1
            if depth == 0:
                break
        elif c == "{" and depth == 1:
            open_ = j
            break
        j += 1
    if open_ is None:
        rest = re.match(r"\)\s*\{", code[j:])
        if not rest:
            return None
        open_ = j + rest.end() - 1
    depth = 0
    for k in range(open_, len(code)):
        if code[k] == "{":
            depth += 1
        elif code[k] == "}":
            depth -= 1
            if depth == 0:
                return open_, k
    return None


# ---------------------------------------------------------------------------------------------------------------


def queue_line(hit: Hit) -> str:
    return f"{hit.group}\t{hit.file}:{hit.line}\t{hit.rule}\t{hit.shape}"


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n", 1)[0])
    parser.add_argument("--root", type=Path, default=REPO, help="repository root (default: this checkout)")
    parser.add_argument("--budget", type=Path, help="idle-budget.json (default: scripts/cmux-next/idle-budget.json)")
    parser.add_argument("--lang", default=",".join(LANGS), help="comma list of " + ", ".join(LANGS))
    parser.add_argument("--json", action="store_true", help="every hit as JSON")
    parser.add_argument("--queue", nargs="?", const="wakeups", choices=("wakeups", "demand-sync"),
                        help="the work list, one line per hit")
    parser.add_argument("--strict", action="store_true",
                        help="exit 1 on unescaped hits, bad escape words or unlisted periodic escapes")
    args = parser.parse_args(argv)
    repo = args.root.resolve()
    langs = [lang.strip() for lang in args.lang.split(",") if lang.strip()]
    if unknown := [lang for lang in langs if lang not in LANGS]:
        parser.error(f"unknown --lang {', '.join(unknown)} (choose from {', '.join(LANGS)})")

    if args.queue == "demand-sync":
        hits = demand_sync(repo)
        if args.json:
            print(json.dumps([asdict(h) for h in hits], indent=1))
        for hit in [] if args.json else hits:
            print(queue_line(hit))
        return 1 if args.strict and hits else 0

    hits, problems = audit(repo, langs, args.budget or repo / "scripts/cmux-next/idle-budget.json")
    failing = {"hit", "bad-escape", "periodic-unlisted"} if args.strict else {"hit"}
    open_hits = [h for h in hits if h.status in failing]
    if args.json:
        print(json.dumps({"counts": _counts(hits), "budget_problems": problems, "hits": [asdict(h) for h in hits]},
                         indent=1))
    elif args.queue:
        for hit in open_hits:
            print(queue_line(hit) + (f"\t{hit.status} {hit.escape}" if hit.status != "hit" else ""))
    else:
        for lang, counts in _counts(hits).items():
            states = ", ".join(f"{k} {v}" for k, v in counts["status"].items())
            rules = ", ".join(f"{k} {v}" for k, v in counts["rules"].items())
            print(f"wakeup-audit {lang}: {states} (unescaped by rule: {rules or 'none'})")
        if args.strict:
            for hit in open_hits:
                print(f"wakeup-audit: {hit.file}:{hit.line}: {hit.rule} ({hit.shape}) {hit.status} {hit.escape}".rstrip())
    if args.strict:
        for problem in problems:
            print(f"wakeup-audit: idle-budget.json: {problem}", file=sys.stderr)
        if open_hits or problems:
            print(f"wakeup-audit: {len(open_hits)} open hit(s). Make each an event, a deadline or MaintenanceClock, "
                  f"or escape it with `wakeup-allow: <{'|'.join(ESCAPE_WORDS)}> <reason>`.", file=sys.stderr)
            return 1
    return 0


def _counts(hits: list[Hit]) -> dict[str, dict[str, dict[str, int]]]:
    out: dict[str, dict[str, dict[str, int]]] = {}
    for lang in dict.fromkeys(h.lang for h in hits):
        mine = [h for h in hits if h.lang == lang]
        out[lang] = {"status": dict(Counter(h.status for h in mine).most_common()),
                     "rules": dict(Counter(h.rule for h in mine if h.status == "hit").most_common()),
                     "shapes": dict(Counter(h.shape for h in mine if h.status == "hit").most_common())}
    return out


if __name__ == "__main__":
    sys.exit(main())
