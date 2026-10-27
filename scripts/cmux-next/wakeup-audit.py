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
  cxx           Packages/macOS/CmuxNext/CEFShim/src and ChromiumHost/src: the C++/ObjC of the app's CEF shim
                and of the Chromium Host process (their tests/ are outside src)
  zig           ghostty-next/src when the submodule is checked out (renderer, termio and search threads run in
                the app), without `test` blocks, test files, benchmarks, the GTK runtime and the build system.
                Report-only: the work list goes to ghostty-next's owner (PL-ghostty), `--strict` never fails on it

The Swift rules are check-concurrency.sh's WAKEUP_RULES (read from that file, one definition), plus
TimelineView(.periodic / .animation), NSWindow.didUpdateNotification, `.activeAlways` and SwiftUI's own loops (an
indefinite `symbolEffect`, an indeterminate `ProgressView`, `repeatForever`, `startAnimation`), which only
CmuxNextDesign's VisibleLoopEffects.swift writes, gated by its window's visibility and the motion switches. In
swift-shared an infinite Core Animation loop (`repeatCount = .infinity`) must come from a maker, a function that
returns the animation, and every call of a maker in the package must be the make closure of a LoopHost
`.attach(` (CmuxHomeCore), or sit in a maker in its turn; the site in a non-maker and each other call is a hit
(CmuxNext's own loops are LoopRegistrationTests'). The cxx rules are
dispatch_after, NSTimer, CFRunLoopTimer, dispatch timer sources, performSelector afterDelay:, PostDelayedTask /
CefPostDelayedTask, sleeps, timed condition waits and `for (;;)` / `while (true)`; such a loop whose own braced
body (or `do { }` body) blocks on its looping path has status `blocking`: reported, never open. Blocking is an
untimed wait: `read(`, `recv(`, `accept(`, waitpid without WNOHANG, kevent with a NULL timeout, epoll_wait with -1,
mach_msg without MACH_RCV_TIMEOUT, or a call of a function or `[self method]` of the same file that makes one. A
timer re-armed from its own function or ObjC method (`@selector(tick)` in `tick`) is a `loop`. The zig rules are
`.run(` / `.reset(` of an `xev.Timer` (named by its field or variable, `Struct.field` inside a nested struct) and
sleeps; a timer re-armed from its own callback is a `loop`.

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
  --lang L[,L]         swift, swift-shared, rust, web, cxx, zig (default all)
  --strict             exit 1 on unescaped hits, bad escape words or unlisted periodic escapes (not zig)
"""
from __future__ import annotations

import argparse
import bisect
import functools
import json
import os
import re
import sys
from collections import Counter
from dataclasses import asdict, dataclass, field
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
LANGS = ("swift", "swift-shared", "rust", "web", "cxx", "zig")
# Code another team owns (a submodule): its hits are listed for its owner and never fail --strict.
REPORT_ONLY = frozenset({"zig"})
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
CEFSHIM_SRC = f"{CMUXNEXT}/CEFShim/src"
CHROMIUM_HOST_SRC = f"{CMUXNEXT}/ChromiumHost/src"
CXX_ROOTS = {"shim": CEFSHIM_SRC, "host": CHROMIUM_HOST_SRC}
CXX_SUFFIXES = (".mm", ".m", ".h", ".hpp", ".cc", ".cpp", ".c")
GHOSTTY_NEXT_SRC = "ghostty-next/src"
# Not in the macOS app: benchmarks, synthetic data generators, the GTK runtime and the build system.
ZIG_SKIP_DIRS = {"benchmark", "synthetic", "gtk", "build"}
# Test files, and Flatpak (Linux only).
ZIG_SKIP_FILE = re.compile(r"(?:^|_)test(?:ing)?\.zig$|^flatpak\.zig$")


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
    # The languages it audits (empty: every language the rule list is used for).
    langs: frozenset[str] = frozenset()
    # Repository-relative files that are the sanctioned owner of what the rule finds (never hits).
    owners: tuple[str, ...] = ()
    # An infinite-animation site judged through its maker's calls (loop_host_hits) instead of by itself.
    maker: bool = False


@dataclass
class Hit:
    lang: str
    group: str
    file: str
    line: int
    rule: str
    shape: str
    status: str  # hit | escaped | bad-escape | no-reason | periodic-unlisted | blocking
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
        Rule("swiftui-loop", "a SwiftUI loop runs while its window is hidden or occluded (use VisibleLoopEffects: "
             "indeterminateSymbolEffect, IndeterminateProgressBar)", SWIFTUI_LOOP, repeating=True,
             owners=SWIFTUI_LOOP_OWNERS),
        Rule("infinite-loop", "an infinite Core Animation loop outside a LoopHost draws for a hidden view (return it "
             "from a maker and add it with loops.attach(layer, key:) { maker() })", INFINITE_LOOP, repeating=True,
             langs=frozenset({"swift-shared"}), maker=True),
    ]


# SwiftUI's infinite loops (p14-energy-115): a symbol effect with no `value:` (indefinite: it repeats while active),
# an indeterminate ProgressView (no `value:`; a timerInterval one counts too), a repeatForever animation and
# NSProgressIndicator.startAnimation.
SWIFTUI_LOOP = re.compile(r"\.symbolEffect\s*\((?![^()]*\bvalue\s*:)|\bProgressView\s*\((?![^()]*\bvalue\s*:)|"
                          r"\.repeatForever\s*\(|\.startAnimation\s*\(")
SWIFTUI_LOOP_OWNERS = (f"{CMUXNEXT}/Sources/CmuxNextDesign/Motion/VisibleLoopEffects.swift",)
# An infinite Core Animation loop.
INFINITE_LOOP = re.compile(r"\brepeatCount\s*=\s*(?:Float|CGFloat|Double)?\.(?:infinity|greatestFiniteMagnitude)\b|"
                           r"\brepeatDuration\s*=\s*(?:CFTimeInterval|TimeInterval|Double)?\.(?:infinity|"
                           r"greatestFiniteMagnitude)\b")


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

# CEFShim C++/ObjC. Chromium's own rule: a delayed task is a deadline the message pump coalesces
# (base/task/sequence_manager/wake_up_queue.cc); a thread waits on its fd or its pump, never on a period.
CXX_SPIN = "spin-loop"
# Rules for a wait in place, not a timer that is armed: rearms() does not apply to them.
WAITS = frozenset({CXX_SPIN, "sleep", "timed-wait"})
CXX_RULES = [
    Rule("dispatch-after", "dispatch_after (post on the event; a deadline only for a one-shot timeout)",
         re.compile(r"\bdispatch_after(?:_f)?\("), literal="dispatch_after"),
    Rule("ns-timer", "NSTimer (post on the event; a one-shot deadline through the app's MainWakeUpQueue)",
         re.compile(r"\[\s*NSTimer\s+\w|\b(?:scheduledTimerWith|timerWith)TimeInterval\b|\binitWithFireDate:"),
         literal="Timer"),
    Rule("cf-timer", "CFRunLoopTimer (post on the event; a one-shot deadline through the app's MainWakeUpQueue)",
         re.compile(r"\bCFRunLoopTimerCreate(?:WithHandler)?\("), literal="CFRunLoopTimerCreate"),
    Rule("dispatch-timer", "dispatch timer source (post on the event; a one-shot deadline)",
         re.compile(r"\bdispatch_source_set_timer\("), literal="dispatch_source_set_timer("),
    Rule("after-delay", "performSelector afterDelay: (post on the event; a one-shot deadline)",
         re.compile(r"\bafterDelay:"), literal="afterDelay:"),
    Rule("delayed-task", "PostDelayedTask (post the task on the event; a delayed task only for a one-shot timeout)",
         re.compile(r"\b(?:Cef)?PostDelayedTask\("), literal="PostDelayedTask("),
    Rule("sleep", "sleep (block on the fd or the event; a deadline for a one-shot timeout)",
         re.compile(r"\bsleep_(?:for|until)\(|\busleep\(|\bnanosleep\(|(?<![\w.>])sleep\(|\bsleepForTimeInterval:"
                    r"|\bsleepUntilDate:"), literal="sleep"),
    Rule("timed-wait", "timed wait (wait for the event; a deadline only for a one-shot timeout)",
         re.compile(r"\.wait_(?:for|until)\(|\bpthread_cond_timedwait\("
                    r"|\bdispatch_(?:semaphore|group)_wait\((?![^;]*DISPATCH_TIME_FOREVER)"
                    r"|(?<![\w.>])poll\((?![^;]*,\s*-1\s*\))"), literal=""),
    Rule(CXX_SPIN, "loop that can spin (block on a read of the fd; end on EOF and errors)",
         re.compile(r"\bfor\s*\(\s*;\s*;\s*\)|\bwhile\s*\(\s*(?:true|1|YES)\s*\)")),
]

# ghostty-next Zig: report-only. An xev.Timer rule per timer name is built per file (zig_timer_rules).
ZIG_RULES = [
    Rule("sleep", "sleep (block on the fd, the child's exit or the event; a deadline for a one-shot timeout)",
         re.compile(r"\b(?:Thread|Io|time)\.sleep\(|\bnanosleep\("), literal="sleep("),
]
_ZIG_TIMER_DECL = re.compile(r"\b(\w+)\s*:\s*\??\s*xev\.Timer(?![.\w])|\b(?:var|const)\s+(\w+)\s*=\s*(?:try\s+)?"
                             r"xev\.Timer\.init\(")
_ZIG_STRUCT = re.compile(r"\bconst\s+(\w+)\s*=\s*(?:extern\s+|packed\s+)?struct\b[^{;]*\{")

# Untimed blocking waits: a loop that holds one of these wakes on an event, not on a period.
# A stream read takes its buffer (`.read(&mut buf)`, `.read(buf)`): not `RwLock::read()` or an RPC `.read(op, args)`.
# A watch's `.changed()` is awaited, selected (`=>`) or passed on, not a `done.changed() ||` query.
RUST_EVENT = re.compile(
    r"\.recv\(\)|\.accept\(\)|\.read(?:_exact|_line|_to_end|_to_string)?\((?=\s*(?:&\s*mut\b|\w+\s*\)))"
    r"|\.next\(\)\s*\.await|\.changed\(\)(?=\s*(?:\.await|=>|,|\)))"
    r"|\.cancelled\(\)(?=\s*(?:\.await|=>|,|\)))|\.notified\(\)|\.wait\(\s*\w*\s*\)|\.join\(\)|\.incoming\(\)|\.recv_many\(")
SWIFT_EVENT = re.compile(r"\bfor\s+(try\s+)?await\b|\bawait\b[^\n]*\.(next|value|receive|read|accept)\(|"
                         r"\bwith(Checked|Unsafe)(Throwing)?Continuation\b")
# A blocking read or wait in C/C++/ObjC; cxx_events() adds the functions of the same file that make one.
CXX_BLOCKING = (r"(?<![\w.>])(?:read|readv|recv|recvfrom|recvmsg|accept|accept4|kevent|epoll_wait|waitpid|"
                r"pthread_cond_wait|sem_wait|mach_msg|getline|fgets|fread)\s*\(|\.wait\(\s*\w*\s*\)"
                r"|\bpoll\([^;]*,\s*-1\s*\)|\bdispatch_semaphore_wait\([^;]*DISPATCH_TIME_FOREVER")
# xev's `.wait(&loop, &c, ...)` registers a callback; a blocking wait takes at most one argument (a Condition's
# mutex, a ResetEvent's io). waitpid blocks only without WNOHANG.
ZIG_EVENT = re.compile(r"\.(?:read|readAll|accept|recv)\(|\.wait\(\s*(?:&?[\w.()]*)\s*\)|\bposix\.(?:read|accept)\("
                       r"|\bwaitpid\([^;]*,\s*0\s*\)|\.run\(\s*\.until_done\s*\)")
# A statement that leaves the loop: a wait in its branch is not on the path that loops again.
RUST_EXIT = re.compile(r"\b(?:return|break)\b|\bprocess::exit\(|\b(?:panic|unreachable|bail)!")
SWIFT_EXIT = re.compile(r"\b(?:return|break|throw)\b|\bfatalError\(")
CXX_EXIT = re.compile(r"\b(?:return|break|goto|throw)\b|\b(?:_?exit|abort)\(")
ZIG_EXIT = re.compile(r"\b(?:return|break|unreachable)\b|@panic\(")
EXITS = {"rust": RUST_EXIT, "swift": SWIFT_EXIT, "cxx": CXX_EXIT, "zig": ZIG_EXIT}
# Languages whose statements end only at `;` (Swift's also end at a line break).
SEMICOLON_LANGS = ("rust", "cxx", "zig")
# A `.read(` of a stream that has a read timeout or is non-blocking returns on a period: it is not an event.
RUST_READ = re.compile(r"\.read(?:_exact|_line|_to_end|_to_string)?\($")
RUST_TIMED_READ = re.compile(r"set_read_timeout\(\s*Some\b|set_nonblocking\(\s*true\b|O_NONBLOCK|\bWouldBlock\b"
                             r"|\bTimedOut\b")
CXX_READ = re.compile(r"(?:read|readv|recv\w*|accept4?)\s*\($")
CXX_TIMED_READ = re.compile(r"\bO_NONBLOCK\b|\bEAGAIN\b|\bEWOULDBLOCK\b|\bSO_RCVTIMEO\b|\bMSG_DONTWAIT\b")
READS = {"rust": RUST_READ, "cxx": CXX_READ}
TIMED_READ = {"rust": RUST_TIMED_READ, "cxx": CXX_TIMED_READ}


# ---------------------------------------------------------------------------------------------------------------
# Masking: comment and string contents become spaces (newlines kept), so rules see code only.

_RUST_TOKEN = re.compile(r"//|/\*|b?r#*\"|b?\"|'")
_SWIFT_TOKEN = re.compile(r"//|/\*|#*\"\"\"|#*\"")
_WEB_TOKEN = re.compile(r"//|/\*|[\"'`]|/")
_CSS_TOKEN = re.compile(r"/\*|[\"']")
_CXX_TOKEN = re.compile(r"//|/\*|\bR\"|[\"']")
_ZIG_TOKEN = re.compile(r"//|\\\\|[\"']")
_CXX_RAW = re.compile(r"R\"([^(\s\\]{0,16})\(")
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
    token = {"rust": _RUST_TOKEN, "swift": _SWIFT_TOKEN, "web": _WEB_TOKEN, "css": _CSS_TOKEN, "cxx": _CXX_TOKEN,
             "zig": _ZIG_TOKEN}[lang]
    out: list[str] = []
    kept = i = 0
    while True:
        m = token.search(text, i)
        if not m:
            break
        s, tok = m.start(), m.group()
        contents = None  # (start, end) of a string's contents when its delimiters are not one character each
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
        elif lang == "cxx" and tok == "'" and s > 0 and text[s - 1].isdigit():  # a digit separator: 1'000
            i = s + 1
            continue
        elif lang == "cxx" and tok == 'R"':
            raw = _CXX_RAW.match(text, s)
            if not raw:
                i = s + 1
                continue
            close = text.find(")" + raw.group(1) + '"', raw.end())
            e = len(text) if close < 0 else close + len(raw.group(1)) + 2
            contents = (raw.end(), max(raw.end(), e - len(raw.group(1)) - 2))
        elif lang == "zig" and tok == "\\\\":  # a multiline string line runs to the end of the line
            e = text.find("\n", s)
            e = len(text) if e < 0 else e
            contents = (m.end(), e)
        else:
            e = _end_of_quoted(text, m.end(), tok[-1], multiline=tok == "`" or lang == "rust")
        # Comments go entirely; strings and regexes keep their delimiters, so they still read as expressions.
        if strings or tok in ("//", "/*"):
            start, end = (s, e) if tok in ("//", "/*") else contents or (m.end(), max(m.end(), e - 1))
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
    name: str = ""  # the function's name, when it has one (an ObjC method's: its selector, `run:with:`)
    objc: bool = False  # an ObjC method: called as `[self name]`, named by `@selector(name)`
    # A loop whose condition comes after its `}`: Swift's `repeat { } while c`, C's `do { } while (c);`.
    repeat: bool = False


_RUST_LOOP = re.compile(r"\bloop\s*$|^(?:'\w+\s*:\s*)?(?:while\b|for\b.*\bin\b)", re.S)
_RUST_BOUNDARY = re.compile(r"\bfn\b|\|[^|]*\|\s*(?:->\s*[^{]+)?$|\|\|\s*$|\basync(?:\s+move)?\s*$", re.S)
_SWIFT_LOOP = re.compile(r"^(?:\w+\s*:\s*)?(?:while\b|repeat\s*$|for\b.*\bin\b)", re.S)
_SWIFT_REPEAT = re.compile(r"(?:\w+\s*:\s*)?repeat\s*$")
_SWIFT_CONTROL = re.compile(r"^(?:if|else|guard|switch|case|default|do|catch|defer|while|for|repeat)\b|\belse\s*$|"
                            r"\belse\s+if\b", re.S)
_SWIFT_FUNCTION = re.compile(r"\b(?:func|init|deinit)\b")
_RUST_FUNCTION = re.compile(r"\bfn\b")
_CXX_LOOP = re.compile(r"^(?:\w+\s*:\s*)?(?:(?:for|while)\s*\(|do$)", re.S)
# A lambda (`[&](int x) {`, `[] {`) or an ObjC block (`^{`, `^(id x) {`).
_CXX_LAMBDA = re.compile(r"\]\s*(?:\([^)]*\))?\s*(?:mutable\s*)?(?:->\s*[^{]+)?$|\^\s*(?:\w[^{(]*)?(?:\([^)]*\))?\s*$",
                         re.S)
_CXX_CONTROL = re.compile(r"^(?:if|else|switch|case|default|try|catch|@try|@catch|@finally|@autoreleasepool|"
                          r"@synchronized|namespace|class|struct|union|enum|extern|@interface|@implementation)\b"
                          r"|\belse\s*$|=\s*$|\breturn\s*$|^[\w:]*$", re.S)
# A function (`) const {`, `) -> T {`) or an ObjC method (`- (void)run:(int)x {`).
_CXX_FUNCTION = re.compile(r"\)\s*(?:const|override|final|noexcept|volatile|&|\s)*(?:->\s*[^{]+)?$|^[-+]\s*\(", re.S)
_CXX_PREPROCESSOR = re.compile(r"^\s*#.*$", re.M)
# ObjC container lines: a method's header after `@implementation X` is the method's.
_OBJC_CONTAINER = re.compile(r"^\s*@(?:implementation|interface|protocol|end)\b.*$", re.M)
_OBJC_METHOD = re.compile(r"^[-+]\s*\(")
_OBJC_TYPE = re.compile(r"\([^()]*\)")
_OBJC_KEYWORD = re.compile(r"(\w+)\s*:")
_CXX_DO = re.compile(r"^(?:\w+\s*:\s*)?do$")
# A loop statement or a loop expression (`const pid = while (true) {`, `outer: while (x) {`).
_ZIG_LOOP = re.compile(r"(?:^|[=:]\s*|\breturn\s+)(?:inline\s+)?(?:while|for)\s*\(", re.S)
_ZIG_TEST = re.compile(r"(?m)^[ \t]*test\b[^{;]*\{")
_ZIG_FUNCTION = re.compile(r"\bfn\b")
_FUNCTION_NAME = {"cxx": re.compile(r"^[^(]*?([A-Za-z_]\w*)\s*\("), "zig": re.compile(r"\bfn\s+([A-Za-z_]\w*)\s*\("),
                  "rust": re.compile(r"\bfn\s+([A-Za-z_]\w*)"), "swift": re.compile(r"\bfunc\s+([A-Za-z_]\w*)")}
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


def objc_selector(header: str) -> str:
    """The selector of an ObjC method header: `run:with:` for `- (void)run:(int)a with:(id)b`, `tick` for
    `- (void)tick`."""
    rest = _OBJC_METHOD.sub("(", header, count=1)
    while (bare := _OBJC_TYPE.sub(" ", rest)) != rest:
        rest = bare
    keywords = _OBJC_KEYWORD.findall(rest)
    if keywords:
        return "".join(k + ":" for k in keywords)
    word = re.search(r"\w+", rest)
    return word.group() if word else ""


def _classify(header: str, lang: str) -> Block:
    """The block (kind, function, name, objc, repeat; no position yet) whose header (the code since the last
    `{`, `}` or `;`) is HEADER."""
    objc = repeat = False
    if lang == "rust":
        kind = "loop" if _RUST_LOOP.search(header) else "boundary" if _RUST_BOUNDARY.search(header) else "plain"
        function = kind == "boundary" and bool(_RUST_FUNCTION.search(header))
    elif lang == "zig":
        kind = "loop" if _ZIG_LOOP.search(header) else "boundary" if _ZIG_FUNCTION.search(header) else "plain"
        function = kind == "boundary"
    elif lang == "cxx":
        header = _OBJC_CONTAINER.sub("", _CXX_PREPROCESSOR.sub("", header)).strip()
        if _CXX_LOOP.search(header):
            kind, function, repeat = "loop", False, bool(_CXX_DO.search(header))
        elif _CXX_LAMBDA.search(header):
            kind, function = "boundary", False
        elif _CXX_CONTROL.search(header) or not _CXX_FUNCTION.search(header):
            kind, function = "plain", False
        else:
            kind, function, objc = "boundary", True, bool(_OBJC_METHOD.search(header))
    else:
        header = swift_statement(header)
        kind = "loop" if _SWIFT_LOOP.search(header) else "plain" if _SWIFT_CONTROL.search(header) else "boundary"
        function = kind == "boundary" and bool(_SWIFT_FUNCTION.search(header))
        repeat = bool(_SWIFT_REPEAT.match(header))
    if objc:
        name = objc_selector(header)
    else:
        found = _FUNCTION_NAME[lang].search(header) if function else None
        name = found.group(1) if found else ""
    return Block(0, 0, 0, kind, function, name, objc, repeat)


def blocks(code: str, lang: str) -> list[Block]:
    out: list[Block] = []
    stack: list[Block] = []
    boundary = 0
    # In C and Zig a `;` inside parentheses (`for (;;)`) does not end the header. A block inside parentheses
    # (a lambda argument, Zig's `.{ }`) counts its own; the depth outside it comes back at its `}`.
    parens, outer = 0, []
    for m in re.finditer(r"[{};()]" if lang in ("cxx", "zig") else r"[{};]", code):
        c, at = m.group(), m.start()
        if c in "()":
            parens = max(0, parens + (1 if c == "(" else -1))
            continue
        if c == ";" and parens:
            continue
        if c == "{":
            outer.append(parens)
            parens = 0
            block = _classify(code[boundary:at].strip(), lang)
            block.header_start, block.open, block.close = boundary, at, len(code)
            stack.append(block)
            out.append(stack[-1])
        elif c == "}":
            parens = outer.pop() if outer else 0
            if stack:
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
    statements = re.split(r";" if lang in SEMICOLON_LANGS else r"[;\n]", "".join(body))
    return _end_kind(next((part for part in reversed(statements) if part.strip()), ""), exits)


def _breaks_out(kind: str, block: Block, loop: Block, inside: list[Block]) -> bool:
    """A `kind` end inside `block` leaves `loop`: any `leave`, and a `break` with no loop between them."""
    return kind == "leave" or kind == "break" and not any(
        c.kind == "loop" and c.open < block.open < c.close for c in inside)


def _leaves_from(pos: int, code: str, loop: Block, inside: list[Block], lang: str, outside: int = -1) -> bool:
    """The path from `pos` leaves `loop`: the innermost branch around `pos` (and not around `outside`) that ends
    with return, break, throw or continue decides. A nested loop holds the path until it ends."""
    exits = EXITS[lang]
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
    exits = EXITS[lang]
    statement = max([code.rfind(c, loop.header_start, e) for c in ";{},"] + [loop.header_start - 1])
    return not exits.search(code, statement + 1, e)


def function_at(e: int, code: str, all_blocks: list[Block]) -> Block:
    """The innermost function body around `e` (the whole file when there is none)."""
    functions = [b for b in all_blocks if b.function and b.open < e < b.close]
    return max(functions, key=lambda b: b.open) if functions else Block(0, 0, len(code), "boundary", True)


def _timed_read(e: int, code: str, all_blocks: list[Block], lang: str) -> bool:
    """The function around `e` gives its stream a read timeout or non-blocking mode, or handles WouldBlock."""
    scope = function_at(e, code, all_blocks)
    return bool(TIMED_READ[lang].search(code, scope.open, scope.close))


_CXX_TIMED_CALL = re.compile(r"(waitpid|kevent|epoll_wait|mach_msg)\s*\($")


def _cxx_untimed_call(m: re.Match[str], code: str) -> bool:
    """A waitpid, kevent, epoll_wait or mach_msg match blocks until its event: waitpid's flags are 0 (no
    WNOHANG), kevent's timeout is NULL, epoll_wait's is -1, mach_msg's options have no MACH_RCV_TIMEOUT."""
    call = _CXX_TIMED_CALL.search(m.group())
    if not call:
        return True
    args = call_args(code, m.end() - 1)
    if call.group(1) == "waitpid":
        return len(args) == 3 and args[2] == "0"
    if call.group(1) == "kevent":
        return len(args) == 6 and args[5] in ("NULL", "nullptr", "0")
    if call.group(1) == "epoll_wait":
        return len(args) == 4 and args[3] == "-1"
    return len(args) > 1 and "MACH_RCV_TIMEOUT" not in args[1]


def blocks_untimed(m: re.Match[str], code: str, all_blocks: list[Block], lang: str) -> bool:
    """The event match `m` waits for its event: not a read of a stream its function makes non-blocking or gives
    a read timeout, and not a C wait given a timeout or WNOHANG."""
    if lang in READS and READS[lang].search(m.group()) and _timed_read(m.start(), code, all_blocks, lang):
        return False
    return lang != "cxx" or _cxx_untimed_call(m, code)


def loop_shape(at: int, code: str, loop: Block, all_blocks: list[Block], lang: str, event: re.Pattern[str]) -> str:
    """`loop` when the path that goes round `loop` again has no untimed wait for the hit at `at`, else `oneshot`."""
    inside = [c for c in all_blocks if loop.open < c.open < loop.close]
    hit = race(at, code, loop, inside, all_blocks) if lang == "rust" else NO_RACE
    if hit.leaves or _leaves_from(at, code, loop, inside, lang):
        return "oneshot"
    for m in event.finditer(code, loop.header_start, loop.close):
        if blocks_untimed(m, code, all_blocks, lang) and _on_looping_path(m.start(), at, code, loop, inside, lang, hit):
            return "oneshot"
    return "loop"


def _default_event(lang: str) -> re.Pattern[str]:
    return {"rust": RUST_EVENT, "zig": ZIG_EVENT}.get(lang, SWIFT_EVENT)


def _repeat_before(at: int, code: str, all_blocks: list[Block]) -> list[Block]:
    """The `repeat { }` / `do { }` loop whose `}` comes just before `at` (the `while` of its condition)."""
    return [b for b in all_blocks if b.repeat and b.close < at and not code[b.close + 1:at].strip()]


def shape(at: int, code: str, all_blocks: list[Block], lang: str, event: re.Pattern[str] | None = None) -> str:
    """`loop` when the innermost loop around `at`, inside the same function or closure, has no untimed wait on
    the path that loops again (EVENT: the language's untimed waits by default)."""
    enclosing = _repeat_before(at, code, all_blocks) + sorted(
        (b for b in all_blocks if b.header_start <= at <= b.close), key=lambda b: -b.open)
    for b in enclosing:
        if b.kind == "boundary" and at > b.open:
            return "oneshot"
        if b.kind == "loop":
            return loop_shape(at, code, b, all_blocks, lang, event or _default_event(lang))
    return "oneshot"


def spin_shape(at: int, code: str, all_blocks: list[Block], lang: str, event: re.Pattern[str]) -> str:
    """The `for (;;)` / `while (true)` at `at` is `blocking` when its own braced body (the loop block whose header
    holds `at`, or the `do { }` block its `while` closes) has an untimed wait on the path that loops again. An
    unbraced loop, or one this parser does not find, is `loop`: open."""
    own = [b for b in all_blocks if b.kind == "loop" and b.header_start <= at < b.open] or \
        _repeat_before(at, code, all_blocks)
    if not own:
        return "loop"
    return "blocking" if loop_shape(at, code, own[-1], all_blocks, lang, event) == "oneshot" else "loop"


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
    if lang == "cxx":
        return [(f"cxx:{name}/{p.stem}", p) for name, src in CXX_ROOTS.items() if (repo / src).is_dir()
                for p in _walk(repo / src, CXX_SUFFIXES)]
    if lang == "zig":
        root = repo / GHOSTTY_NEXT_SRC
        # The group is the file's folder (renderer, termio, terminal/search): the thread that owns the timers.
        return [(f"zig:{p.parent.relative_to(root).as_posix() if p.parent != root else p.stem}", p)
                for p in _walk(root, (".zig",), ZIG_SKIP_DIRS) if not ZIG_SKIP_FILE.search(p.name)] \
            if root.is_dir() else []
    root = repo / "webviews/src"
    return [(f"web:{p.relative_to(root).parts[0].split('.')[0]}", p)
            for p in _walk(root, (".ts", ".tsx", ".css"), WEB_SKIP_DIRS) if not WEB_SKIP_FILE.search(p.name)]


def lang_of(rel: str, repo: Path | None = None) -> str | None:
    """The audit language of a repository-relative path, or None when no audit reads it (for the pre-push
    guardrail, which audits only the lines a push adds). The same files sources() reads: swift-shared needs
    REPO, whose CmuxNext Package.swift says which Shared and macOS packages the app links."""
    path = Path(rel)
    parts, suffix = path.parts, path.suffix
    if rel.startswith(CMUXNEXT + "/Sources/") and suffix == ".swift":
        return None if rel.startswith(f"{CMUXNEXT}/Sources/{WAKEUP_PRIMITIVES_MODULE}/") else "swift"
    if any(rel.startswith(src + "/") for src in CXX_ROOTS.values()) and suffix in CXX_SUFFIXES:
        return "cxx"
    if parts[:2] == ("cmux-tui", "crates") and len(parts) > 4 and parts[3] == "src" and suffix == ".rs":
        return "rust"
    if rel.startswith("webviews/src/") and suffix in (".ts", ".tsx", ".css"):
        dirs = set(parts[2:-1])
        return None if dirs & WEB_SKIP_DIRS or WEB_SKIP_FILE.search(path.name) else "web"
    if repo is not None and suffix == ".swift":
        for package in _linked_package_paths(repo.resolve()):
            sources_dir = f"{package}/Sources/"
            if rel.startswith(sources_dir) and not set(Path(rel[len(sources_dir):]).parts[:-1]) & SHARED_SKIP_DIRS:
                return "swift-shared"
    return None


@functools.lru_cache(maxsize=8)
def _linked_package_paths(repo: Path) -> tuple[str, ...]:
    """app_linked_packages(repo) as repository-relative paths."""
    return tuple(p.relative_to(repo).as_posix() for p in app_linked_packages(repo))


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


def mask_lang(lang: str, suffix: str) -> str:
    """The lexer mask() uses for a file of audit language LANG with SUFFIX."""
    if suffix == ".css":
        return "css"
    return {"web": "web", "rust": "rust", "cxx": "cxx", "zig": "zig"}.get(lang, "swift")


def audit_file(repo: Path, lang: str, group: str, path: Path, rules: list[Rule], periodic_owners: set[str],
               skip: list[tuple[int, int]] = (), raw: str | None = None, code: str | None = None,
               makers: frozenset[str] | None = None) -> list[Hit]:
    raw = path.read_text(encoding="utf-8", errors="replace") if raw is None else raw
    return audit_text(lang, group, path.relative_to(repo).as_posix(), raw, rules, periodic_owners, skip, code, makers)


def audit_text(lang: str, group: str, rel: str, raw: str, rules: list[Rule], periodic_owners: set[str],
               skip: list[tuple[int, int]] = (), code: str | None = None,
               makers: frozenset[str] | None = None) -> list[Hit]:
    """The hits of one file's text RAW (repository path REL). MAKERS: the loop makers of the file's group
    (group_makers); None judges with the file's own."""
    mlang = mask_lang(lang, Path(rel).suffix)
    rules = [r for r in rules if (not r.langs or lang in r.langs) and rel not in r.owners]
    if lang == "zig":
        code = mask(raw, mlang) if code is None else code
        rules = rules + zig_timer_rules(code)
        skip = list(skip) + [(m.start(), matching_brace(code, m.end() - 1) + 1) for m in _ZIG_TEST.finditer(code)]
    if not any(rule.literal in raw for rule in rules):
        return []
    code = mask(raw, mlang) if code is None else code
    starts = [0] + [m.end() for m in re.finditer("\n", code)]
    tree = blocks(code, mlang) if mlang in ("rust", "swift", "cxx", "zig") else []
    with_strings = mask(raw, mlang, strings=False)
    lines = Lines(raw.split("\n"), code.split("\n"), with_strings.split("\n"))
    found: dict[tuple[int, str], int] = {}
    for rule in rules:
        text = with_strings if rule.in_strings else code
        if rule.literal not in text:
            continue
        spots = loop_host_hits(code, tree, rule.pattern, makers) if rule.maker else \
            [m.start() for m in rule.pattern.finditer(text)]
        for at in spots:
            index = bisect.bisect_right(starts, at) - 1
            if (index, rule.id) not in found and not any(a <= at < b for a, b in skip):
                found[(index, rule.id)] = at
    event = cxx_events(code, tree) if lang == "cxx" and found else None
    timers = [r for r in rules if r.id not in WAITS] if lang in ("cxx", "zig") else []
    arming = re.compile("|".join(r.pattern.pattern for r in timers) or "(?!)")
    hits = []
    for (index, rule_id), at in sorted(found.items()):
        rule = next(r for r in rules if r.id == rule_id)
        status, word = judge(escape_of(lines, index), periodic_owners)
        if rule.id == CXX_SPIN and lang == "cxx":
            # The loop itself: it is fine when every turn blocks on a read (it wakes on input, not on a period).
            kind = spin_shape(at, code, tree, mlang, event)
            if status == "hit" and kind == "blocking":
                status = "blocking"
        elif rule.repeating or repeating_timer(rule, code, at) or \
                (rule in timers and rearms(at, code, tree, arming)):
            kind = "loop"
        else:
            kind = shape(at, code, tree, mlang, event) if tree else "oneshot"
        hits.append(Hit(lang, group, rel, index + 1, rule.id, kind, status, word, lines.raw[index].strip()))
    return hits


# ---------------------------------------------------------------------------------------------------------------
# Infinite Core Animation loops in swift-shared (p14-energy-115): a maker returns the loop, a LoopHost attaches it.

# A function header that returns an animation (`-> CAAnimation`, `-> CAKeyframeAnimation?`).
_RETURNS_ANIMATION = re.compile(r"->\s*CA\w*Animation\w*\s*[?!]?\s*(?:where\b[^{]*)?$")
# The header of a LoopHost attach's make closure: `loops.attach(layer, key: "spin") {`.
_ATTACH_CALL = re.compile(r"\.attach\s*\(")
# A name's declaration, not a call: `func spin(`.
_DECLARES = re.compile(r"\bfunc\s+$")


def _header(code: str, block: Block) -> str:
    return swift_statement(code[block.header_start:block.open].strip())


def _function_around(at: int, tree: list[Block]) -> Block | None:
    functions = [b for b in tree if b.function and b.open < at < b.close]
    return max(functions, key=lambda b: b.open) if functions else None


def _maker(code: str, function: Block | None) -> bool:
    """FUNCTION returns an animation: a maker, judged at its calls."""
    return function is not None and bool(function.name) and bool(_RETURNS_ANIMATION.search(_header(code, function)))


def _attached(at: int, code: str, tree: list[Block]) -> bool:
    """The call at AT is in the make closure of a LoopHost attach (no function between them)."""
    for block in sorted((b for b in tree if b.open < at < b.close), key=lambda b: b.open, reverse=True):
        if block.function:
            return False
        if _ATTACH_CALL.search(_header(code, block)):
            return True
    return False


def _maker_calls(code: str, names: set[str] | frozenset[str]) -> list[int]:
    if not names:
        return []
    call = re.compile(r"(?<![\w])(?:" + "|".join(map(re.escape, sorted(names))) + r")\s*\(")
    return [m.start() for m in call.finditer(code) if not _DECLARES.search(code, max(0, m.start() - 40), m.start())]


def file_makers(code: str, tree: list[Block], pattern: re.Pattern[str], known: set[str] | frozenset[str]) -> set[str]:
    """The makers CODE declares: functions that return an animation and hold an infinite loop or call a maker."""
    makers = {f.name for f in (_function_around(m.start(), tree) for m in pattern.finditer(code)) if _maker(code, f)}
    while True:
        more = {f.name for f in (_function_around(at, tree) for at in _maker_calls(code, set(known) | makers))
                if _maker(code, f)} - makers
        if not more:
            return makers
        makers |= more


def group_makers(files: list[tuple[str, Path]], pattern: re.Pattern[str]) -> dict[str, frozenset[str]]:
    """Each group's makers: a maker in one file of a package is called from another."""
    parsed: dict[str, list[tuple[str, list[Block]]]] = {}
    for group, path in files:
        raw = path.read_text(encoding="utf-8", errors="replace")
        if "Animation" in raw:
            code = mask(raw, "swift")
            parsed.setdefault(group, []).append((code, blocks(code, "swift")))
    out: dict[str, frozenset[str]] = {}
    for group, items in parsed.items():
        names: set[str] = set()
        while True:
            found = set().union(*(file_makers(code, tree, pattern, names) for code, tree in items))
            if found <= names:
                break
            names |= found
        out[group] = frozenset(names)
    return out


def loop_host_hits(code: str, tree: list[Block], pattern: re.Pattern[str], makers: frozenset[str] | None) -> list[int]:
    """Where CODE runs an infinite loop outside a LoopHost: a site in a function that does not return the loop,
    and each call of a maker that is neither a LoopHost attach's make closure nor inside a maker."""
    names = file_makers(code, tree, pattern, makers or frozenset()) | (makers or frozenset())
    bare = [m.start() for m in pattern.finditer(code) if not _maker(code, _function_around(m.start(), tree))]
    calls = [at for at in _maker_calls(code, names)
             if not _attached(at, code, tree) and not _maker(code, _function_around(at, tree))]
    return sorted(bare + calls)


def call_pattern(function: Block) -> str:
    """A call of `function`: `name(` for a C/C++ function, `[self name]` / `[self name:` for an ObjC method."""
    if not function.objc:
        return rf"(?<![\w.>]){re.escape(function.name)}\s*\("
    first = function.name.split(":")[0]
    return rf"\[\s*self\s+{re.escape(first)}" + (r"\s*:" if ":" in function.name else r"\s*\]")


def cxx_events(code: str, tree: list[Block]) -> re.Pattern[str]:
    """CXX_BLOCKING and the calls of this file's functions and ObjC methods that block: one whose body makes an
    untimed blocking call (a read of a stream the same function makes non-blocking does not), or calls such a
    function."""
    functions = [b for b in tree if b.function and b.name]
    blocking: list[Block] = []
    while True:
        pattern = re.compile("|".join([CXX_BLOCKING] + list(dict.fromkeys(call_pattern(f) for f in blocking))))
        more = [f for f in functions if f not in blocking and any(
            blocks_untimed(m, code, tree, "cxx") for m in pattern.finditer(code, f.open, f.close))]
        if not more:
            return pattern
        blocking += more


_NS_REPEATS = re.compile(r"\brepeats:\s*(?:YES|true)\b")


def call_args(code: str, paren: int) -> list[str]:
    """The top-level arguments of the call whose `(` is at PAREN."""
    inner = code[paren + 1:matching_brace(code, paren, _PAREN)]
    out, depth, start = [], 0, 0
    for i, c in enumerate(inner):
        depth += 1 if c in "([{" else -1 if c in ")]}" else 0
        if c == "," and depth == 0:
            out.append(inner[start:i].strip())
            start = i + 1
    return out + [inner[start:].strip()]


def names(function: Block, text: str, call: bool = False) -> bool:
    """TEXT names `function`: its name (a call of it with CALL), or for an ObjC method `@selector(name)` or a
    `[self name]` message."""
    if function.objc:
        selector = rf"@selector\(\s*{re.escape(function.name)}\s*\)"
        return bool(re.search(call_pattern(function) + ("" if call else "|" + selector), text))
    return bool(re.search(rf"(?<![\w]){re.escape(function.name)}\b" + (r"\s*\(" if call else ""), text))


def armed_text(at: int, code: str) -> tuple[str, list[str]]:
    """The statement that arms the timer at `at` (from its start to the `;` after `at`, or to the end of its
    call's arguments when they hold a block), and the arguments of that call (none for an ObjC message)."""
    start = max(code.rfind(c, 0, at) for c in ";{}") + 1
    end = code.find(";", at)
    end = len(code) if end < 0 else end
    paren = code.find("(", at, end)
    if paren < 0 or code[:at].rstrip().endswith("["):  # an ObjC message: `[NSTimer scheduledTimer...]`
        return code[start:end], []
    close = matching_brace(code, paren, _PAREN)
    return code[start:max(end, close + 1)], call_args(code, paren)


def rearms(at: int, code: str, tree: list[Block], arming: re.Pattern[str]) -> bool:
    """The timer or delayed task armed at `at` comes back: it repeats by itself (an ObjC `repeats:YES`, a
    CFRunLoopTimer or dispatch timer with an interval), it names the function or ObjC method it is armed in
    (the callback re-arms it: a C callback argument, `@selector(here)`, `[self here]` in a block), or it names a
    function of the file that calls that one again or arms a timer with itself as the callback (Zig's xev
    callbacks, a C++ task that posts itself)."""
    text, args = armed_text(at, code)
    if _NS_REPEATS.search(text):
        return True
    callee = code[at:code.find("(", at)] if args else ""
    if "CFRunLoopTimerCreate" in callee:
        return len(args) > 2 and args[2] not in ("0", "0.0", "0.")
    if "dispatch_source_set_timer" in callee:
        return len(args) > 2 and args[2] != "DISPATCH_TIME_FOREVER"
    here = function_at(at, code, tree)

    # A C callback is one of the call's arguments; an ObjC method is named anywhere in the message or its block.
    def named(function: Block) -> bool:
        return names(function, text if function.objc else "(" + ",".join(args) + ")")

    if here.name and named(here):
        return True
    for callback in (b for b in tree if b.function and b.name and b is not here and named(b)):
        body = code[callback.open:callback.close]
        if here.name and names(here, body, call=True):
            return True
        for m in arming.finditer(code, callback.open, callback.close):
            again, again_args = armed_text(m.start(), code)
            if names(callback, again if callback.objc else "(" + ",".join(again_args) + ")"):
                return True
    return False


def zig_timer_rules(code: str) -> list[Rule]:
    """One rule per xev.Timer this Zig file declares (a field or a `var x = xev.Timer.init()`): its `.run(` and
    `.reset(` calls. A timer declared only inside a nested `const S = struct` is named `S.name`."""
    structs = [(m.group(1), m.end() - 1, matching_brace(code, m.end() - 1)) for m in _ZIG_STRUCT.finditer(code)]
    owners: dict[str, set[str]] = {}
    for m in _ZIG_TIMER_DECL.finditer(code):
        inside = [(close - open_, name) for name, open_, close in structs if open_ < m.start() < close]
        owners.setdefault(m.group(1) or m.group(2), set()).add(min(inside)[1] if inside else "")
    rules = []
    for name, where in sorted(owners.items()):
        label = f"{next(iter(where))}.{name}" if len(where) == 1 and "" not in where else name
        rules.append(Rule(f"xev-timer:{label}", f"xev.Timer {label} (wake on the event; a deadline only once)",
                          re.compile(rf"\b(?:\w+(?:\.\?)?\.)*{re.escape(name)}(?:\.\?)?\.(?:run|reset)\("),
                          literal=name))
    return rules


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
        rules = {"rust": RUST_RULES, "web": WEB_RULES, "cxx": CXX_RULES, "zig": ZIG_RULES}.get(lang) or \
            swift_wakeup_rules(repo)
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
        maker_rule = next((r for r in rules if r.maker and lang in r.langs), None)
        makers = group_makers(files, maker_rule.pattern) if maker_rule else {}
        for group, path in files:
            raw, code, ranges = prepared.get(path, (None, None, []))
            hits += audit_file(repo, lang, group, path, rules, owners, ranges, raw, code,
                               makers.get(group, frozenset()) if maker_rule else None)
    return hits, problems


# ---------------------------------------------------------------------------------------------------------------
# Q13: DemandTimer closures on the main actor that never await (a sync overload runs them in the callout).

_SCHEDULE = re.compile(r"\.schedule(?:IfIdle)?(\()\s*after:")
# A name typed or built as a DemandTimer: `let t = DemandTimer(`, `var t: DemandTimer?`, a `t: DemandTimer` parameter.
_DEMAND_TIMER_NAME = re.compile(r"\b(\w+)\s*:\s*DemandTimer\b|\b(?:let|var)\s+(\w+)\s*=\s*DemandTimer\s*\(")
# The receiver of a `.schedule` call: the identifier just before it (`timer.`, `self.timer.`, `timer?.`).
_RECEIVER = re.compile(r"(\w+)\s*[?!]?\s*$")


def demand_sync(repo: Path) -> list[Hit]:
    """Main-actor DemandTimer closures with no await. A timer is often declared in `Foo.swift` and
    scheduled in an extension file (`Foo+Bar.swift`), so the DemandTimer names are gathered over the
    whole module first, and a call counts when its receiver is one of them. A receiver that is not a
    plain name (a call result, a subscript) counts too: the audit cannot rule it out."""
    root = repo / CMUXNEXT / "Sources"
    files = []
    names: dict[str, set[str]] = {}
    for path in _walk(root, (".swift",)):
        raw = path.read_text(encoding="utf-8", errors="replace")
        code = mask(raw, "swift")
        module = path.relative_to(root).parts[0]
        names.setdefault(module, set()).update(a or b for a, b in _DEMAND_TIMER_NAME.findall(code))
        if ".schedule" in raw:
            files.append((path, module, raw, code))
    hits = []
    for path, module, raw, code in files:
        starts = [0] + [m.end() for m in re.finditer("\n", code)]
        for m in _SCHEDULE.finditer(code):
            receiver = _RECEIVER.search(code[max(0, m.start() - 120):m.start()])
            if receiver and receiver.group(1) not in names[module]:
                continue
            body = _closure_after_call(code, m.start(1))
            if not body:
                continue
            open_, close = body
            if not re.match(r"\s*@MainActor\b", code[open_ + 1:close]) or re.search(r"\bawait\b", code[open_:close]):
                continue
            line = bisect.bisect_right(starts, m.start())
            rel = path.relative_to(repo).as_posix()
            hits.append(Hit("swift", f"swift:{module}", rel, line, "demand-sync", "oneshot",
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
                        help="exit 1 on unescaped hits, bad escape words or unlisted periodic escapes "
                             "(report-only languages never fail it)")
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
    # Report-only languages are in the work list, never in what fails --strict.
    refused = [h for h in open_hits if h.lang not in REPORT_ONLY]
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
            owner = " [report-only]" if lang in REPORT_ONLY else ""
            print(f"wakeup-audit {lang}{owner}: {states} (unescaped by rule: {rules or 'none'})")
        if args.strict:
            for hit in refused:
                print(f"wakeup-audit: {hit.file}:{hit.line}: {hit.rule} ({hit.shape}) {hit.status} {hit.escape}".rstrip())
    if args.strict:
        for problem in problems:
            print(f"wakeup-audit: idle-budget.json: {problem}", file=sys.stderr)
        if refused or problems:
            print(f"wakeup-audit: {len(refused)} open hit(s). Make each an event, a deadline or MaintenanceClock, "
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
