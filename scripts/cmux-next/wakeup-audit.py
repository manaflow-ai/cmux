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

A hit is escaped by a comment `wakeup-allow: <word> <reason>` on its statement's lines or in the comment
block directly above the statement (text inside a string literal is not an escape). The word is one of
deadline|backoff|bounded|cli-only|fixture|debug|periodic. `periodic <owner>` must name an owner in
idle-budget.json `allowed_periodic` ([{owner, period_s, why}]); the other words need a reason after them.
`--strict` exits 1 on any unescaped hit, any other escape word, an escape with no reason, and any periodic
escape whose owner is missing or not listed.

Each hit has a shape. `loop`: it sits in a loop (or is a repeating source: an interval, `repeats: true`,
`Timer.publish`, `repeating:` other than `.never`) and the path that loops again has no untimed blocking
wait, so it wakes the process on a period: make it an event, a deadline or MaintenanceClock. Not on that
path: a wait in a branch or a `select!` arm that leaves the loop (`return`, `break`, `throw`), a wait in a
spawned body or a nested function, a read of a stream the same function makes non-blocking or gives a read
timeout, and the other arms of a `select!` whose arm future is the timed wait (they race it: while idle the
timer still fires on its period). A timed wait whose own branch or arm leaves the loop is `oneshot`.
`oneshot`: a single deadline (an escape is allowed when its code shape matches).

Modes:
  (none)               counts per language and rule
  --json               every hit with its status, shape and escape word
  --queue              group<TAB>file:line<TAB>rule<TAB>loop|oneshot, one line per hit --strict refuses; an
                       escape to reword adds <TAB>bad-escape|no-reason|periodic-unlisted
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
ESCAPE = re.compile(r"wakeup-allow:\s*([^\s,;:.()]*)(.*)")
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
    status: str  # hit | escaped | bad-escape | no-reason | periodic-unlisted
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
# A stream read takes its buffer (`.read(&mut buf)`, `.read(buf)`): not `RwLock::read()` or an RPC `.read(op, args)`.
# A watch's `.changed()` is awaited, selected (`=>`) or passed on, not a `done.changed() ||` query.
RUST_EVENT = re.compile(
    r"\.recv\(\)|\.accept\(\)|\.read(?:_exact|_line|_to_end|_to_string)?\((?=\s*(?:&\s*mut\b|\w+\s*\)))"
    r"|\.next\(\)\s*\.await|\.changed\(\)(?=\s*(?:\.await|=>|,|\)))"
    r"|\.cancelled\(\)(?=\s*(?:\.await|=>|,|\)))|\.notified\(\)|\.wait\(\s*\w*\s*\)|\.join\(\)|\.incoming\(\)|\.recv_many\(")
SWIFT_EVENT = re.compile(r"\bfor\s+(try\s+)?await\b|\bawait\b[^\n]*\.(next|value|receive|read|accept)\(|"
                         r"\bwith(Checked|Unsafe)(Throwing)?Continuation\b")
# A statement that leaves the loop: a wait in its branch is not on the path that loops again.
RUST_EXIT = re.compile(r"\b(?:return|break)\b|\bprocess::exit\(|\b(?:panic|unreachable|bail)!")
SWIFT_EXIT = re.compile(r"\b(?:return|break|throw)\b|\bfatalError\(")
# A `.read(` of a stream that has a read timeout or is non-blocking returns on a period: it is not an event.
RUST_READ = re.compile(r"\.read(?:_exact|_line|_to_end|_to_string)?\($")
RUST_TIMED_READ = re.compile(r"set_read_timeout\(\s*Some\b|set_nonblocking\(\s*true\b|O_NONBLOCK|\bWouldBlock\b"
                             r"|\bTimedOut\b")


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
    function: bool = False  # a boundary that is a function body (`fn`, `func`, `init`)


_RUST_LOOP = re.compile(r"\bloop\s*$|^(?:'\w+\s*:\s*)?(?:while\b|for\b.*\bin\b)", re.S)
_RUST_BOUNDARY = re.compile(r"\bfn\b|\|[^|]*\|\s*(?:->\s*[^{]+)?$|\|\|\s*$|\basync(?:\s+move)?\s*$", re.S)
_SWIFT_LOOP = re.compile(r"^(?:\w+\s*:\s*)?(?:while\b|repeat\s*$|for\b.*\bin\b)", re.S)
_SWIFT_CONTROL = re.compile(r"^(?:if|else|guard|switch|case|default|do|catch|defer|while|for|repeat)\b|\belse\s*$|"
                            r"\belse\s+if\b", re.S)
_SWIFT_FUNCTION = re.compile(r"\b(?:func|init|deinit)\b")
_RUST_FUNCTION = re.compile(r"\bfn\b")
# A Swift line that continues the expression of the line above (or a line above that it continues).
_SWIFT_CONTINUES = re.compile(r"^(?:\.|&&|\|\||\?\?|[,)\]=+*/<>-]|->|where\b|throws\b|rethrows\b|async\b)")
_SWIFT_CONTINUED = re.compile(r"(?:[(\[,.=+*/<>-]|&&|\|\||\?\?|->)$")


def swift_statement(header: str) -> str:
    """The last statement of a Swift block header: statements end at a line break, not only at `;`."""
    lines = [line.strip() for line in header.split("\n") if line.strip()]
    first = len(lines) - 1
    while first > 0 and (_SWIFT_CONTINUES.match(lines[first]) or _SWIFT_CONTINUED.search(lines[first - 1])):
        first -= 1
    return "\n".join(lines[max(first, 0):])


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
                function = kind == "boundary" and bool(_RUST_FUNCTION.search(header))
            else:
                header = swift_statement(header)
                kind = "loop" if _SWIFT_LOOP.search(header) else "plain" if _SWIFT_CONTROL.search(header) else "boundary"
                function = kind == "boundary" and bool(_SWIFT_FUNCTION.search(header))
            stack.append(Block(boundary, at, len(code), kind, function))
            out.append(stack[-1])
        elif c == "}" and stack:
            stack.pop().close = at
        boundary = at + 1
    return out


# A `match` / `switch` / `select!` body is a list of arms, not one branch: its last arm says nothing about the others.
_ARM_LIST = re.compile(r"\b(?:match|switch)\b[^{}]*$|\bselect(?:_biased)?!\s*$")
_CONTINUE = re.compile(r"\bcontinue\b")
_LABELED_BREAK = re.compile(r"\bbreak\s*'")


def _end_kind(statement: str, exits: re.Pattern[str]) -> str:
    """How a statement ends the path: `leave` (return, throw, exit, panic, a labeled break), `break` (the
    innermost loop), `continue`, or `` (it falls through)."""
    if m := exits.search(statement):
        return "break" if m.group() == "break" and not _LABELED_BREAK.search(statement) else "leave"
    return "continue" if _CONTINUE.search(statement) else ""


def _branch_end(code: str, block: Block, inside: list[Block], exits: re.Pattern[str], lang: str) -> str:
    """`_end_kind` of the last statement of the branch `block`, its nested blocks blanked. A closure, a function, a
    loop body and an arm list are not branches: their last statement does not end the enclosing loop's path."""
    if block.kind != "plain" or _ARM_LIST.search(code, block.header_start, block.open):
        return ""
    body = list(code[block.open + 1:block.close])
    for b in inside:
        if block.open < b.open and b.close <= block.close:
            body[b.open - block.open - 1:b.close - block.open] = " " * (b.close - b.open + 1)
    statements = re.split(r";" if lang == "rust" else r"[;\n]", "".join(body))
    return _end_kind(next((part for part in reversed(statements) if part.strip()), ""), exits)


def _breaks_out(kind: str, block: Block, loop: Block, inside: list[Block]) -> bool:
    """A `kind` end inside `block` leaves `loop`: any `leave`, and a `break` with no loop between them."""
    return kind == "leave" or kind == "break" and not any(
        c.kind == "loop" and c.open < block.open < c.close for c in inside)


def _leaves_from(pos: int, code: str, loop: Block, inside: list[Block], lang: str, outside: int = -1) -> bool:
    """The path from `pos` leaves `loop`: the innermost branch around `pos` (and not around `outside`) that ends
    with return, break, throw or continue decides. A nested loop holds the path until it ends."""
    exits = RUST_EXIT if lang == "rust" else SWIFT_EXIT
    around = sorted((b for b in inside if b.open < pos < b.close and not b.open < outside < b.close),
                    key=lambda b: -b.open)
    for b in around:
        if b.kind == "loop":
            return False
        kind = _branch_end(code, b, inside, exits, lang)
        if kind:
            return _breaks_out(kind, b, loop, inside)
    return False


# ---------------------------------------------------------------------------------------------------------------
# Rust `select!` (tokio, futures): a timed arm races the other arms. While idle the timer fires on its own period
# whatever the other arms wait for, so their events are not on the timer's path.


@dataclass(frozen=True)
class Arm:
    """One `pattern = future => handler` arm: `start..arrow` is its pattern and future, `start..end` the whole arm,
    `leaves` says its handler leaves the loop the audit is looking at."""
    start: int
    arrow: int
    end: int
    leaves: bool


_SELECT = re.compile(r"\bselect(?:_biased)?!\s*$")
_ARM_PUNCT = re.compile(r"=>|[()\[\]{},;]")
_ARM_GUARD = re.compile(r"\s*if\b")
_INNER_BLOCK = re.compile(r"\{[^{}]*\}")


def select_arms(code: str, select: Block, loop: Block, by_open: dict[int, Block], inside: list[Block]) -> list[Arm]:
    """The arms of the `select! { ... }` body `select`. `biased;` is not an arm; a `, if guard` stays in its arm."""
    def unbraced(start: int, arrow: int, end: int) -> Arm:
        # `=> if failed { return }` leaves only on its branch: nested blocks are blanked.
        handler = code[arrow + 2:end]
        while (blanked := _INNER_BLOCK.sub(" ", handler)) != handler:
            handler = blanked
        return Arm(start, arrow, end, _breaks_out(_end_kind(handler, RUST_EXIT), select, loop, inside))

    arms: list[Arm] = []
    start, arrow, depth, pos = select.open + 1, -1, 0, select.open + 1
    while m := _ARM_PUNCT.search(code, pos, select.close):
        c, pos = m.group(), m.end()
        if c == "{" and depth == 0 and arrow >= 0 and not code[arrow + 2:m.start()].strip() and m.start() in by_open:
            handler = by_open[m.start()]
            kind = _branch_end(code, handler, inside, RUST_EXIT, "rust")
            arms.append(Arm(start, arrow, handler.close + 1, _breaks_out(kind, handler, loop, inside)))
            start, arrow, pos = handler.close + 1, -1, handler.close + 1
        elif c in "([{":
            depth += 1
        elif c in ")]}":
            depth -= 1
        elif depth == 0 and c == "=>" and arrow < 0:
            arrow = m.start()
        elif depth == 0 and c == ";" and arrow < 0:
            start = m.end()
        elif depth == 0 and c == "," and not (arrow < 0 and _ARM_GUARD.match(code, m.end())):
            if arrow >= 0:
                arms.append(unbraced(start, arrow, m.start()))
            start, arrow = m.end(), -1
    if arrow >= 0:
        arms.append(unbraced(start, arrow, select.close))
    return arms


@dataclass(frozen=True)
class Race:
    """For one hit in a loop: the spans of the `select!` arms that race the hit's own arm, the arms of every
    `select!` in the loop, and whether the hit's own arm leaves the loop."""
    siblings: list[tuple[int, int]]
    arms: list[Arm]
    leaves: bool


_LET = re.compile(r"\blet\s+(?:mut\s+)?([A-Za-z]\w*)\s*(?::[^=;]*)?=(?!=)")
NO_RACE = Race([], [], False)


def race(at: int, code: str, loop: Block, inside: list[Block], all_blocks: list[Block]) -> Race:
    """The hit's own arm holds it, or names the binding the hit is assigned to (`let poll = sleep(d); ...
    _ = &mut poll => {}`); every other arm of that `select!` is a sibling."""
    by_open = {b.open: b for b in all_blocks}
    statement = max(code.rfind(c, loop.open, at) for c in ";{}")
    bound = _LET.search(code, statement + 1, at)
    name = re.compile(r"\b" + bound.group(1) + r"\b") if bound else None
    siblings: list[tuple[int, int]] = []
    every: list[Arm] = []
    leaves = False
    for select in inside:
        if not _SELECT.search(code, select.header_start, select.open):
            continue
        arms = select_arms(code, select, loop, by_open, inside)
        every += arms
        own = next((a for a in arms if a.start <= at < a.end
                    or (name and a.start > at and name.search(code, a.start, a.arrow))), None)
        # Only a hit that is (or names) the arm's future races the other arms. A hit in a handler runs when its
        # arm fires, so the loop's idle wakes are those of the arms' futures (each a hit of its own when timed).
        if own is not None and (at < own.arrow or own.start > at):
            siblings += [(a.start, a.end) for a in arms if a is not own]
            leaves = leaves or own.leaves
    return Race(siblings, every, leaves)


# A closure or async block handed to a spawn runs on its own: the loop does not wait for what it waits for.
_SPAWN = re.compile(r"\bspawn(?:_blocking|_local)?\s*\([^{}]*$|\bTask(?:\.detached)?\s*(?:\([^(){}]*\))?\s*$")
_ASYNC_BLOCK = re.compile(r"\basync(?:\s+move)?\s*$")


def _waited_for(code: str, body: Block, loop: Block, siblings: list[tuple[int, int]], lang: str) -> bool:
    """The loop waits for the closure, async block or function `body`: not a spawned body or a nested function,
    and not an async block bound to a name that is only polled in a sibling arm, or never."""
    header = code[body.header_start:body.open]
    if body.function or _SPAWN.search(header):
        return False
    bound = _LET.search(header) if lang == "rust" and _ASYNC_BLOCK.search(header) else None
    if not bound:
        return True  # a closure the loop calls, an awaited async block or an argument of an awaited call
    uses = re.finditer(r"\b" + bound.group(1) + r"\b", code[:loop.close])
    return any(u.start() > body.close and not any(s <= u.start() < e for s, e in siblings) for u in uses)


def _on_looping_path(e: int, at: int, code: str, loop: Block, inside: list[Block], lang: str, hit: Race) -> bool:
    """The event at `e` runs on the path that goes round `loop` again: not in a `select!` arm that races the hit or
    whose handler leaves the loop, not in a body the loop does not wait for, not in a branch (one without `at`)
    that ends by leaving the loop, and not in an unbraced `=> return ...` arm."""
    if any(s <= e < end for s, end in hit.siblings) or any(a.start <= e < a.arrow and a.leaves for a in hit.arms):
        return False
    if any(b.kind == "boundary" and b.open < e < b.close and not b.open < at < b.close
           and not _waited_for(code, b, loop, hit.siblings, lang) for b in inside):
        return False
    if _leaves_from(e, code, loop, inside, lang, outside=at):
        return False
    exits = RUST_EXIT if lang == "rust" else SWIFT_EXIT
    statement = max([code.rfind(c, loop.header_start, e) for c in ";{},"] + [loop.header_start - 1])
    return not exits.search(code, statement + 1, e)


def _timed_read(e: int, code: str, all_blocks: list[Block]) -> bool:
    """The function around `e` gives its stream a read timeout or non-blocking mode, or handles WouldBlock."""
    functions = [b for b in all_blocks if b.function and b.open < e < b.close]
    scope = max(functions, key=lambda b: b.open) if functions else Block(0, 0, len(code), "boundary", True)
    return bool(RUST_TIMED_READ.search(code, scope.open, scope.close))


def shape(at: int, code: str, all_blocks: list[Block], lang: str) -> str:
    """`loop` when the innermost loop around `at`, inside the same function or closure, has no untimed wait on
    the path that loops again."""
    # The `while` of Swift's `repeat { } while c` belongs to the loop that closes just before it.
    repeat = [b for b in all_blocks if b.kind == "loop" and b.close < at and not code[b.close + 1:at].strip()]
    enclosing = repeat + sorted((b for b in all_blocks if b.header_start <= at <= b.close), key=lambda b: -b.open)
    event = RUST_EVENT if lang == "rust" else SWIFT_EVENT
    for b in enclosing:
        if b.kind == "boundary" and at > b.open:
            return "oneshot"
        if b.kind == "loop":
            inside = [c for c in all_blocks if b.open < c.open < b.close]
            hit = race(at, code, b, inside, all_blocks) if lang == "rust" else NO_RACE
            if hit.leaves or _leaves_from(at, code, b, inside, lang):
                return "oneshot"
            for m in event.finditer(code, b.header_start, b.close):
                if lang == "rust" and RUST_READ.search(m.group()) and _timed_read(m.start(), code, all_blocks):
                    continue
                if _on_looping_path(m.start(), at, code, b, inside, lang, hit):
                    return "oneshot"
            return "loop"
    return "oneshot"


# ---------------------------------------------------------------------------------------------------------------
# Rust: test-only items (`#[cfg(test)]`, `#[test]`, the test-support feature) and every module file declared
# inside one, or inside a test-only file.

_CFG_ATTR = re.compile(r"#(!?)\[\s*cfg\s*\((.*?)\)\s*\]", re.S)
_TEST_FN_ATTR = re.compile(r"#\[\s*(?:tokio::)?test\b[^\]]*\]")
_CFG_TOKEN = re.compile(r"\s*(?:(\w+)\s*=\s*\"([^\"]*)\"|(\w+)|([(),]))")


def cfg_test_only(predicate: str) -> bool:
    """A `cfg(...)` predicate holds only in test builds: it needs `test` or the test-support feature (`test`,
    `all(..)` with one such operand, `any(..)` with only such operands). Unparsable text is not test-only."""
    tokens = [m for m in _CFG_TOKEN.finditer(predicate)]
    if "".join(m.group() for m in tokens).strip() != predicate.strip():
        return False
    pos = 0

    def parse() -> bool:
        nonlocal pos
        tok = tokens[pos]
        pos += 1
        if tok.group(1):
            return tok.group(1) == "feature" and tok.group(2) == "test-support"
        word = tok.group(3)
        if word not in ("all", "any", "not") or pos >= len(tokens) or tokens[pos].group(4) != "(":
            return word == "test"
        pos += 1
        operands = []
        while pos < len(tokens) and tokens[pos].group(4) != ")":
            operands.append(parse())
            if pos < len(tokens) and tokens[pos].group(4) == ",":
                pos += 1
        pos += 1
        if word == "not":
            return False
        return any(operands) if word == "all" else bool(operands) and all(operands)

    try:
        return parse() and pos == len(tokens)
    except IndexError:
        return False


_ATTR = re.compile(r"\s*#\[(?:[^\[\]]|\[[^\]]*\])*\]")
_MOD_ITEM = re.compile(r"\bmod\s+(\w+)\s*([;{])")
_PATH_ATTR = re.compile(r"#\[\s*path\s*=\s*\"([^\"]+)\"\s*\]")
_ITEM_START = re.compile(r"[;{}][^;{}]*$")
_BRACE = re.compile(r"[{}]")
_PAREN = re.compile(r"[()]")
# An item (its range ends at its body or `;`), as opposed to a field, a variant, an argument, a match arm or a
# statement (whose range also ends at a `,` or at the `}` / `)` of the list it is in).
_ITEM_KEYWORD = re.compile(r"\s*(?:pub(?:\s*\([^)]*\))?\s+)?(?:(?:unsafe|async|const|default|extern(?:\s+\"[^\"]*\")?)\s+)*"
                           r"(?:fn|impl|mod|struct|enum|union|trait|const|static|type|use|let|macro_rules!|extern\s+crate)\b")
_ITEM_PUNCT = re.compile(r"[()\[\]{};,]")


def attributed_end(code: str, j: int) -> int:
    """The end of the item, field, variant, argument, arm or statement that starts at `j`, after its
    attributes. A `{` at depth 0 is its body; `;` ends it; outside an item a depth-0 `,` ends it too, and a
    depth-0 `}`, `)` or `]` closes the list it is in, so it ends just before."""
    item = bool(_ITEM_KEYWORD.match(code, j))
    depth = 0
    for m in _ITEM_PUNCT.finditer(code, j):
        c = m.group()
        if c in "([{":
            if c == "{" and depth == 0:
                return matching_brace(code, m.start()) + 1
            depth += 1
        elif c in ")]}":
            if depth == 0:
                return m.start()
            depth -= 1
        elif depth == 0 and (c == ";" or not item):
            return m.end()
    return len(code)


@dataclass(frozen=True)
class RustModules:
    """One file's test-only character ranges and the module files it declares (path, declared test-only)."""
    test_ranges: list[tuple[int, int]]
    children: list[tuple[Path, bool]]


def rust_modules(code: str, raw: str, path: Path) -> RustModules:
    # Attributes are matched in the raw text (masking blanks `"test-support"`), at a `#` that is code.
    def attrs(pattern: re.Pattern[str]) -> list[re.Match[str]]:
        return [m for m in pattern.finditer(raw) if code[m.start()] == "#"]

    cfgs = [m for m in attrs(_CFG_ATTR) if cfg_test_only(m.group(2))]
    if any(m.group(1) for m in cfgs):
        ranges = [(0, len(code))]
    else:
        ranges = []
        for m in sorted(cfgs + attrs(_TEST_FN_ATTR), key=lambda m: m.start()):
            if ranges and m.start() < ranges[-1][1]:
                continue
            j = m.end()
            while a := _ATTR.match(code, j):
                j = a.end()
            ranges.append((m.start(), attributed_end(code, j)))
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


def matching_brace(code: str, open_: int, pair: re.Pattern[str] = _BRACE) -> int:
    """Index of the `}` (or `)` with `pair` _PAREN) that closes the one at `open_` (the end when unbalanced)."""
    depth = 0
    for m in pair.finditer(code, open_):
        depth += 1 if m.group() in "({" else -1
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


# A line that continues the statement of the line above it, by its start or by the end of the line above. A
# trailing `,` does not continue: the next line is another arm, field, entry or argument with its own escape.
_CONTINUES = re.compile(r"^\s*(?:\.|\?|&&|\|\||[)\]=+*/<>-])")
_CONTINUED = re.compile(r"(?:[(\[.=+*/<>-]|&&|\|\|)\s*$")


@dataclass(frozen=True)
class Lines:
    """One file's raw lines, its lines with comments and strings blanked, and with only comments blanked."""
    raw: list[str]
    code: list[str]
    comments: list[str]

    def is_comment(self, j: int) -> bool:
        return not self.code[j].strip() and bool(self.raw[j].strip())

    def escapes(self, j: int) -> list[re.Match[str]]:
        """wakeup-allow escapes written in a comment on line j (not inside a string literal)."""
        return [m for m in ESCAPE.finditer(self.raw[j]) if self.comments[j][m.start()] == " "]


def escape_of(lines: Lines, index: int) -> tuple[re.Match[str], str] | None:
    """The escape on the lines of the hit's statement or in the comment block directly above the statement,
    and the comment line after it (where a reason may go on)."""
    first = index
    while first > 0:
        above = first - 1
        while above > 0 and lines.is_comment(above):
            above -= 1
        if not (_CONTINUES.match(lines.code[first]) or _CONTINUED.search(lines.code[above])) or \
                not lines.code[above].strip():
            break
        first = above
    candidates = list(range(first, index + 1))
    j = first - 1
    while j >= 0 and lines.is_comment(j):
        candidates.append(j)
        j -= 1
    for j in candidates:
        if found := lines.escapes(j):
            following = lines.raw[j + 1] if j + 1 < len(lines.raw) and lines.is_comment(j + 1) else ""
            return found[0], following
    return None


def judge(escape: tuple[re.Match[str], str] | None, periodic_owners: set[str]) -> tuple[str, str]:
    if escape is None:
        return "hit", ""
    m, following = escape
    word, rest = m.group(1), m.group(2).strip().rstrip("*/").strip()
    # The reason may go on to the next comment line.
    more = re.sub(r"^\s*(?://+|/?\*+)\s*", "", following).strip()
    if word not in ESCAPE_WORDS:
        return "bad-escape", word
    if word == "periodic":
        owner = rest.split()[0].rstrip(".,;:") if rest else ""
        if owner not in periodic_owners:
            return "periodic-unlisted", f"periodic {owner or '(no owner)'}"
        return "escaped", word
    if not (rest or more):
        return "no-reason", word
    return "escaped", word


def audit_file(repo: Path, lang: str, group: str, path: Path, rules: list[Rule], periodic_owners: set[str],
               skip: list[tuple[int, int]] = (), raw: str | None = None, code: str | None = None) -> list[Hit]:
    raw = path.read_text(encoding="utf-8", errors="replace") if raw is None else raw
    if not any(rule.literal in raw for rule in rules):
        return []
    mlang = "css" if path.suffix == ".css" else "web" if lang == "web" else "rust" if lang == "rust" else "swift"
    code = mask(raw, mlang) if code is None else code
    starts = [0] + [m.end() for m in re.finditer("\n", code)]
    tree = blocks(code, mlang) if mlang in ("rust", "swift") else []
    rel = path.relative_to(repo).as_posix()
    with_strings = mask(raw, mlang, strings=False)
    lines = Lines(raw.split("\n"), code.split("\n"), with_strings.split("\n"))
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
        kind = "loop" if rule.repeating or repeating_timer(rule, code, at) else \
            shape(at, code, tree, mlang) if tree else "oneshot"
        hits.append(Hit(lang, group, rel, index + 1, rule.id, kind, status, word, lines.raw[index].strip()))
    return hits


_REPEATING_TIMER = re.compile(r"\bTimer\.publish\b|\brepeating:\s*\.(?!never\b)")


def repeating_timer(rule: Rule, code: str, at: int) -> bool:
    """A Swift timer that repeats: `Timer.publish(every:)`, `repeating:` other than `.never`, `repeats: true`."""
    if rule.id != "timer":
        return False
    if _REPEATING_TIMER.match(code, at):
        return True
    paren = code.find("(", at, at + 40)
    return paren >= 0 and bool(re.search(r"\brepeats:\s*true\b", code[paren:matching_brace(code, paren, _PAREN)]))


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

_SCHEDULE = re.compile(r"\.schedule(?:IfIdle)?(\()\s*after:")


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
            body = _closure_after_call(code, m.start(1))
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


# What --strict refuses, and so what the work list holds. An escape to reword carries its status as a 5th column.
OPEN_STATUSES = ("hit", "bad-escape", "no-reason", "periodic-unlisted")


def queue_line(hit: Hit) -> str:
    status = "" if hit.status == "hit" else f"\t{hit.status}"
    return f"{hit.group}\t{hit.file}:{hit.line}\t{hit.rule}\t{hit.shape}{status}"


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
    open_hits = [h for h in hits if h.status in OPEN_STATUSES]
    if args.json:
        print(json.dumps({"counts": _counts(hits), "budget_problems": problems, "hits": [asdict(h) for h in hits]},
                         indent=1))
    elif args.queue:
        for hit in open_hits:
            print(queue_line(hit))
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
