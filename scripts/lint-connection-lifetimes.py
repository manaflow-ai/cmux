#!/usr/bin/env python3
"""Warn on connections opened without a deadline and on work nobody frees.

Connections die: at the start (a dial or handshake that never answers), while connected (a peer that goes silent),
and at teardown (a child process or task left running after its owner is gone, the way unfreed memory is left
behind). Each rule below flags one shape of that in NEXT code:

  R1  Rust network open with no deadline: TcpStream::connect, UnixStream::connect, connect_async, or a reqwest
      Client::new()/builder() with no .timeout/.connect_timeout, and no tokio::time::timeout, set_read_timeout
      or deadline next to it.
  R2  Rust Command .spawn() whose child is not killed with its owner: no kill_on_drop(true), and not a
      process_group/setsid child that is waited or killed.
  R3  tokio::spawn / spawn_local whose JoinHandle is dropped on the spot (`tokio::spawn(..);`, `let _ = ..`)
      with no cancellation, shutdown or abort in the task.
  R4  TS/JS: setInterval, or a setTimeout of 1 s or more, whose id is not kept; a kept id never passed to
      clearInterval/clearTimeout in the file; `new WebSocket(` / `new EventSource(` in a file with no close()
      or no onclose/onerror handling.
  R5  A wait that polls with sleep and has no deadline: a Rust `loop`/`while` with a sleep and a break or return
      and no Instant/deadline/timeout/attempt cap/cancel in it; a TS `while (true)` / `for (;;)` with an awaited
      sleep and none of those.
  R6  Swift in Packages/macOS/CmuxNext/Sources: a URLSessionWebSocketTask in a file with no sendPing (a dead
      peer is never noticed); a Process() in a file with no terminate() (the child outlives its owner).
      Timers, sleeps and `while true` in NEXT Swift are scripts/cmux-next/check-concurrency.sh's (its idle-wakeup
      rule), so this script does not repeat them.

A hit that is right as written carries `// lifetime-ok: <reason>` on its line or in the comment lines directly
above it (`// wakeup-allow: <reason>` counts too in Swift). Today's hits are listed in
scripts/lint-connection-lifetimes-baseline.txt, keyed by path, rule and a fingerprint of the line's text (not
its number, so an edit elsewhere in the file does not churn it). A hit not in the baseline is printed as a
warning with its file:line, why and the fix; a baseline entry whose hit is gone is reported so the baseline
shrinks (`--update-baseline` rewrites it). The CI step is warn-only for now; `--strict` exits 1 on either.

The principles and fixes: cmuxterm-hq docs/handbook/connections-and-lifetimes.md. Related: short fixed gates on
slow paths are scripts/lint-short-gates.py's; a relay socket that dies while opening is cmux#40917's.
Heuristic and line based: tests, vendored code, ghostty and the classic app are not scanned.
"""

from __future__ import annotations

import argparse
import hashlib
import os
import re
import subprocess
import sys
from collections import Counter
from dataclasses import dataclass
from pathlib import Path
from typing import Dict, Iterable, List, Optional, Sequence, Tuple

REPO_ROOT = Path(__file__).resolve().parent.parent
BASELINE = REPO_ROOT / "scripts" / "lint-connection-lifetimes-baseline.txt"
HANDBOOK = "cmuxterm-hq docs/handbook/connections-and-lifetimes.md"

RUST_ROOT = "cmux-tui/crates/"
TS_ROOT = "webviews/src/"
SWIFT_ROOT = "Packages/macOS/CmuxNext/Sources/"
TS_SUFFIXES = (".ts", ".tsx", ".js", ".jsx", ".mjs")
# Crates that are not NEXT app code: the vendored terminal, the classic importer, benches and test hosts.
SKIPPED_CRATES = (
    "ghostty-vt",
    "ghostty-vt-sys",
    "cmux-classic-import",
    "cmux-cellgrid-bench",
    "cmux-remote-browser-testhost",
)
MARKERS = ("lifetime-ok:",)
SWIFT_MARKERS = ("lifetime-ok:", "wakeup-allow:")

WHY = {
    "R1": (
        "a network open with no deadline: a peer that never answers holds the caller forever",
        "wrap it in tokio::time::timeout (or set .timeout/.connect_timeout on the client, set_read_timeout on a"
        " std socket) with the operation's own deadline",
    ),
    "R2": (
        "a spawned child nobody kills: it outlives its owner when the owner drops it, errors or exits",
        "set .kill_on_drop(true) (tokio), or put it in its own process_group and keep the Child to wait()/kill()"
        " on every exit path",
    ),
    "R3": (
        "a task whose JoinHandle is dropped with no cancellation: nothing can stop it, it outlives its owner",
        "keep the JoinHandle and abort() it with its owner, or select! on a CancellationToken/shutdown signal"
        " inside the task",
    ),
    "R4": (
        "a timer or socket the page never frees: it keeps firing (or the socket stays open) after its owner is gone",
        "keep the id and clear it in the owner's cleanup (useEffect return, dispose); close() the socket and handle"
        " onclose/onerror",
    ),
    "R5": (
        "a polling wait with no deadline: if the condition never comes true it spins forever",
        "bound it with an Instant/deadline or an attempt cap and return an error when it passes",
    ),
    "R6": (
        "a Swift connection or child process with no liveness or teardown",
        "sendPing on a timer through CmuxNextWakeups for a WebSocket; terminate() a Process with its owner",
    ),
}


@dataclass(frozen=True)
class Hit:
    path: str
    line: int
    rule: str
    text: str
    detail: str = ""

    @property
    def fingerprint(self) -> str:
        return fingerprint(self.rule, self.text)

    @property
    def key(self) -> Tuple[str, str, str]:
        return (self.path, self.rule, self.fingerprint)


def normalize(text: str) -> str:
    return " ".join(text.split())


def fingerprint(rule: str, text: str) -> str:
    return hashlib.sha1(f"{rule}\0{normalize(text)}".encode("utf-8")).hexdigest()[:12]


# ---------------------------------------------------------------------------------------------------------------
# Masking: comments and string contents become spaces, so code patterns never match inside them. Line breaks stay.


TOKENS = {
    "rust": re.compile(
        r"//[^\n]*|/\*[\s\S]*?\*/|(?<![\w])b?r(#*)\"[\s\S]*?\"\1|\"(?:\\[\s\S]|[^\"\\])*\""
        r"|'(?:\\u\{[0-9a-fA-F]+\}|\\.|[^\\'\n])'"
    ),
    "ts": re.compile(
        r"//[^\n]*|/\*[\s\S]*?\*/|\"(?:\\.|[^\"\\\n])*\"|'(?:\\.|[^'\\\n])*'|`(?:\\[\s\S]|[^`\\])*`"
    ),
    "swift": re.compile(r"//[^\n]*|/\*[\s\S]*?\*/|\"\"\"[\s\S]*?\"\"\"|\"(?:\\.|[^\"\\\n])*\""),
}
NOT_NEWLINE = re.compile(r"[^\n]")


def mask(text: str, lang: str) -> str:
    """Comments and string contents become spaces (line breaks stay), so code patterns never match inside them."""

    def blank(m: "re.Match[str]") -> str:
        token = m.group(0)
        if token.startswith("/"):
            return NOT_NEWLINE.sub(" ", token)
        return token[0] + NOT_NEWLINE.sub(" ", token[1:-1]) + token[-1]

    return TOKENS[lang].sub(blank, text)


CFG_TEST = re.compile(r"^[ \t]*#\[cfg\((?:all\()?test\b[^\n]*\n", re.MULTILINE)


def mask_rust_tests(masked: str) -> str:
    """Blank `#[cfg(test)]` items: the item after it, to its closing brace or its `;`."""
    out = masked
    pos = 0
    while True:
        m = CFG_TEST.search(out, pos)
        if not m:
            return out
        # The item: through its first `;` or its block's closing brace, whichever comes first.
        i = m.end()
        while i < len(out) and out[i] not in "{;":
            i += 1
        end = match_close(out, i) + 1 if i < len(out) and out[i] == "{" else i + 1
        end = min(end, len(out))
        segment = "".join(ch if ch == "\n" else " " for ch in out[m.start() : end])
        out = out[: m.start()] + segment + out[end:]
        pos = end


# ---------------------------------------------------------------------------------------------------------------
# Helpers over masked text.


def offsets(text: str) -> List[int]:
    starts, pos = [0], 0
    for line in text.split("\n")[:-1]:
        pos += len(line) + 1
        starts.append(pos)
    return starts


def line_of(starts: Sequence[int], offset: int) -> int:
    lo, hi = 0, len(starts) - 1
    while lo < hi:
        mid = (lo + hi + 1) // 2
        if starts[mid] <= offset:
            lo = mid
        else:
            hi = mid - 1
    return lo + 1


def match_close(text: str, open_at: int) -> int:
    """Index of the bracket closing the one at open_at, or len(text)."""
    pairs = {"(": ")", "[": "]", "{": "}"}
    stack = [pairs[text[open_at]]]
    i = open_at + 1
    while i < len(text) and stack:
        ch = text[i]
        if ch in pairs:
            stack.append(pairs[ch])
        elif stack and ch == stack[-1]:
            stack.pop()
        i += 1
    return i - 1 if not stack else len(text)


def statement_end(text: str, start: int, limit: int = 4000) -> int:
    """End of the statement starting at start: the first `;` at bracket depth 0 (or a closing bracket)."""
    depth, i, stop = 0, start, min(len(text), start + limit)
    while i < stop:
        ch = text[i]
        if ch in "([{":
            depth += 1
        elif ch in ")]}":
            if depth == 0:
                return i
            depth -= 1
        elif ch == ";" and depth == 0:
            return i
        i += 1
    return stop


def window(lines: Sequence[str], line: int, before: int, after: int) -> str:
    return "\n".join(lines[max(0, line - 1 - before) : line + after])


def escaped(original: Sequence[str], line: int, markers: Sequence[str]) -> bool:
    if any(marker in original[line - 1] for marker in markers):
        return True
    j = line - 2
    while j >= 0 and original[j].lstrip().startswith(("//", "/*", "*", "#[")):
        if any(marker in original[j] for marker in markers):
            return True
        j -= 1
    return False


# ---------------------------------------------------------------------------------------------------------------
# Rust rules.

R1_OPEN = re.compile(
    r"\b(?:TcpStream|UnixStream)::connect\s*\("
    r"|\bconnect_async(?:_with_config|_tls_with_config)?\s*\("
    r"|\breqwest::Client::new\s*\(\s*\)"
    r"|\breqwest::(?:Client::builder|ClientBuilder::new)\s*\(\s*\)"
)
R1_REQWEST_BARE = re.compile(r"(?<![\w:])(?:Client::new|Client::builder|ClientBuilder::new)\s*\(\s*\)")
R1_DEADLINE = re.compile(r"timeout|deadline|Deadline|TIMEOUT|DEADLINE", re.IGNORECASE)
R1_CLIENT_TIMEOUT = re.compile(r"\.(?:timeout|connect_timeout|read_timeout)\s*\(")


def rust_r1(path: str, masked: str, lines: List[str], starts: List[int], raw: str) -> Iterable[Tuple[int, str]]:
    uses_reqwest = "reqwest" in masked
    seen = set()
    patterns = [R1_OPEN] + ([R1_REQWEST_BARE] if uses_reqwest else [])
    for pattern in patterns:
        for m in pattern.finditer(masked):
            line = line_of(starts, m.start())
            if line in seen:
                continue
            seen.add(line)
            token = m.group(0)
            if "Client" in token:
                end = statement_end(masked, m.end())
                statement = masked[m.start() : end]
                if R1_CLIENT_TIMEOUT.search(statement):
                    continue
                # A builder kept in a variable and configured on the next lines.
                if R1_CLIENT_TIMEOUT.search(window(lines, line, 0, 12)):
                    continue
                yield line, "a reqwest client with no timeout"
                continue
            end = statement_end(masked, m.end())
            statement = masked[m.start() : end]
            nearby = window(lines, line, 3, 0) + "\n" + statement + "\n" + window(lines, line_of(starts, end), 0, 8)
            if R1_DEADLINE.search(nearby):
                continue
            yield line, f"`{token.rstrip('( ')}` with no deadline"


COMMAND_NEW = re.compile(r"\bCommand::new\s*\(")
SPAWN_CALL = re.compile(r"\.spawn\s*\(\s*\)")
R2_KILL_ON_DROP = re.compile(r"kill_on_drop\s*\(\s*true\s*\)")
R2_GROUP = re.compile(r"process_group\s*\(|setsid|pre_exec\s*\(|setpgid")
R2_REAP = re.compile(r"\.(?:wait|wait_with_output|try_wait|kill|start_kill)\s*\(")
FN_START = re.compile(r"^\s*(?:pub(?:\([^)]*\))?\s+)?(?:async\s+)?(?:unsafe\s+)?fn\s", re.MULTILINE)


def rust_r2(path: str, masked: str, lines: List[str], starts: List[int], raw: str) -> Iterable[Tuple[int, str]]:
    news = list(COMMAND_NEW.finditer(masked))
    for index, m in enumerate(news):
        line = line_of(starts, m.start())
        # The command's scope: to the next Command::new or the next fn, at most 60 lines.
        stop_offsets = [starts[min(len(starts) - 1, line + 59)] if line + 59 < len(starts) else len(masked)]
        if index + 1 < len(news):
            stop_offsets.append(news[index + 1].start())
        next_fn = FN_START.search(masked, m.end())
        if next_fn:
            stop_offsets.append(next_fn.start())
        scope = masked[m.start() : min(stop_offsets)]
        spawn = SPAWN_CALL.search(scope)
        if not spawn:
            continue  # .output() / .status() wait for the child themselves.
        # Look a little past the spawn for the child's wait or kill.
        spawn_line = line_of(starts, m.start() + spawn.start())
        after = scope + "\n" + window(lines, spawn_line, 0, 40)
        cut = FN_START.search(after, len(scope))
        after = after if not cut else after[: cut.start()]
        if R2_KILL_ON_DROP.search(scope):
            continue
        if R2_GROUP.search(scope) and R2_REAP.search(after):
            continue
        yield line, "a spawned child with no kill_on_drop(true) and no reaped process group"


R3_SPAWN = re.compile(
    r"^(?P<indent>[ \t]*)(?P<prefix>let\s+_\s*=\s*|drop\s*\(\s*)?"
    r"(?P<call>tokio::task::spawn_blocking|(?:tokio::)?(?:task::)?spawn(?:_local)?)\s*\(",
    re.MULTILINE,
)
R3_OWNED = re.compile(
    r"cancel|Cancel|shutdown|Shutdown|abort|Abort|stop_rx|stop_tx|closed\s*\(|is_closed|CancellationToken|"
    r"select!|watch::Receiver|quit|Quit|stopped|exit_rx|kill_rx|done_rx"
)


def rust_r3(path: str, masked: str, lines: List[str], starts: List[int], raw: str) -> Iterable[Tuple[int, str]]:
    for m in R3_SPAWN.finditer(masked):
        call = m.group("call")
        if not call.startswith("tokio::"):
            # A bare `spawn(` / `task::spawn(` is someone else's unless the file imports tokio's.
            name = call.split("::")[-1]
            if call.startswith("task::"):
                if not re.search(r"use\s+tokio::(?:task\b|\{[^}]*\btask\b)", masked):
                    continue
            elif not re.search(r"use\s+tokio::(?:task::)?(?:\{[^}]*\b" + name + r"\b|" + name + r"\b)", masked):
                continue
        if call == "tokio::task::spawn_blocking":
            continue
        open_at = m.end() - 1
        close = match_close(masked, open_at)
        rest = masked[close + 1 : close + 40].lstrip()
        discarded = m.group("prefix") is not None or rest.startswith(";")
        if m.group("prefix") and m.group("prefix").startswith("drop"):
            discarded = True
        if not discarded:
            continue
        body = masked[open_at:close]
        if R3_OWNED.search(body):
            continue
        yield line_of(starts, m.start("call")), f"`{call}(..)` with its JoinHandle dropped"


LOOP_HEAD = re.compile(r"(?<![\w.])(?:loop|while)\b[^{;]*\{")
RUST_SLEEP = re.compile(r"\bsleep\s*\(|\bsleep_until\s*\(|\.tick\(\)\s*\.await")
R5_BOUND = re.compile(
    r"Instant|deadline|Deadline|DEADLINE|timeout|Timeout|TIMEOUT|elapsed|attempt|ATTEMPT|tries|TRIES|retries|"
    r"RETRIES|max_|MAX_|budget|cancel|Cancel|shutdown|Shutdown|stop|Stop|backoff|Backoff|remaining|expir|until"
)
R5_EXIT = re.compile(r"\bbreak\b|\breturn\b")


def rust_r5(path: str, masked: str, lines: List[str], starts: List[int], raw: str) -> Iterable[Tuple[int, str]]:
    for m in LOOP_HEAD.finditer(masked):
        head = m.group(0)
        if head.startswith("while") and re.match(r"while\s+let\b", head) and ".recv()" in head:
            continue
        open_at = m.end() - 1
        close = match_close(masked, open_at)
        body = masked[open_at:close]
        if body.count("\n") > 200 or not RUST_SLEEP.search(body):
            continue
        # The sleep must be this loop's, not only an inner loop's or a spawned task's.
        if not R5_EXIT.search(body):
            continue
        if R5_BOUND.search(head) or R5_BOUND.search(body):
            continue
        yield line_of(starts, m.start()), "a polling loop with a sleep and no deadline"


# ---------------------------------------------------------------------------------------------------------------
# TS rules.

TIMER_CALL = re.compile(r"(?<![\w$.])(?:window\.|globalThis\.|self\.)?(setInterval|setTimeout)\s*\(")
TIMER_ASSIGN = re.compile(
    r"(?:(?:const|let|var)\s+(?P<decl>[\w$]+)(?:\s*:[^=]+)?|(?P<target>[\w$.\[\]]+))\s*=\s*$"
)


def ts_delay_arg(masked: str, open_at: int) -> str:
    """The last top-level argument of the call opening at open_at, or "" when it has one argument."""
    close = match_close(masked, open_at)
    inner = masked[open_at + 1 : close]
    depth, last = 0, -1
    for idx, ch in enumerate(inner):
        if ch in "([{":
            depth += 1
        elif ch in ")]}":
            depth -= 1
        elif ch == "," and depth == 0:
            last = idx
    return inner[last + 1 :].strip() if last >= 0 else ""


def ts_r4(path: str, masked: str, lines: List[str], starts: List[int], raw: str) -> Iterable[Tuple[int, str]]:
    for m in TIMER_CALL.finditer(masked):
        kind = m.group(1)
        clear = "clearInterval" if kind == "setInterval" else "clearTimeout"
        line_start = masked.rfind("\n", 0, m.start()) + 1
        before = masked[line_start : m.start()]
        stripped = before.strip()
        line = line_of(starts, m.start())
        if stripped in ("", "void"):
            # A statement continuing the previous line (`x =\n setInterval(`, an argument) is not dropped here.
            prev = masked[:line_start].rstrip()
            if prev.endswith(("=", "(", ",", "?", ":", "=>", "return", "&&", "||")):
                continue
            # Not kept. A setTimeout under 1 s (a deferral to a later turn) is left alone.
            if kind == "setTimeout":
                delay = ts_delay_arg(masked, m.end() - 1)
                if not delay or (re.fullmatch(r"[\d_]+", delay) and int(delay.replace("_", "")) < 1000):
                    continue
            yield line, f"`{kind}` whose id is not kept"
            continue
        assign = TIMER_ASSIGN.search(before)
        if not assign:
            continue
        name = assign.group("decl") or assign.group("target")
        last = re.split(r"[.\[\]]", name.strip("[]."))
        ident = [part for part in last if part][-1] if any(last) else name
        if re.search(r"\b(?:clearInterval|clearTimeout)\s*\([^)]*\b" + re.escape(ident) + r"\b", masked):
            continue
        # The id handed on: returned, stored in a ref/collection or passed to a cleanup helper.
        if re.search(r"\breturn\s+" + re.escape(ident) + r"\b|\b" + re.escape(ident) + r"\b\s*[,)]", masked[m.end() :]):
            continue
        yield line, f"`{name} = {kind}(..)` never passed to {clear}"
    for m in re.finditer(r"\bnew\s+(WebSocket|EventSource)\s*\(", masked):
        kind = m.group(1)
        has_close = re.search(r"\.close\s*\(", masked)
        has_handler = re.search(r"\bon(?:close|error)\b", masked) or re.search(
            r"addEventListener\s*\(\s*[\"'`](?:close|error)[\"'`]", raw
        )
        missing = []
        if not has_close:
            missing.append("close()")
        if not has_handler:
            missing.append("onclose/onerror")
        if missing:
            yield line_of(starts, m.start()), f"`new {kind}` in a file with no {' or '.join(missing)}"


TS_LOOP = re.compile(r"\bwhile\s*\(\s*(?:true|1)\s*\)\s*\{|\bfor\s*\(\s*;\s*;\s*\)\s*\{")
TS_SLEEP = re.compile(r"await\s+(?:[\w$.]*\b(?:sleep|delay|wait|pause)\w*\s*\(|new\s+Promise\b[^;]*setTimeout)")
TS_BOUND = re.compile(
    r"deadline|Deadline|DEADLINE|Date\.now|performance\.now|timeout|Timeout|TIMEOUT|signal|aborted|abort|attempt|"
    r"tries|retries|max|MAX|until|cancel|Cancel|stop|Stop|disposed|unmounted|closed|budget|elapsed"
)


def ts_r5(path: str, masked: str, lines: List[str], starts: List[int], raw: str) -> Iterable[Tuple[int, str]]:
    for m in TS_LOOP.finditer(masked):
        open_at = m.end() - 1
        close = match_close(masked, open_at)
        body = masked[open_at:close]
        if not TS_SLEEP.search(body):
            continue
        if TS_BOUND.search(body):
            continue
        yield line_of(starts, m.start()), "a `while (true)` wait with a sleep and no deadline"


# ---------------------------------------------------------------------------------------------------------------
# Swift rule.


def swift_r6(path: str, masked: str, lines: List[str], starts: List[int], raw: str) -> Iterable[Tuple[int, str]]:
    if not re.search(r"\bsendPing\b", masked):
        for m in re.finditer(r"\.webSocketTask\s*\(|\bURLSessionWebSocketTask\s*\(", masked):
            yield line_of(starts, m.start()), "a URLSessionWebSocketTask in a file with no sendPing"
    if not re.search(r"\.terminate\s*\(|\.interrupt\s*\(|\bkill\s*\(", masked):
        for m in re.finditer(r"(?<![\w.])(?:Foundation\.)?Process\s*\(\s*\)", masked):
            yield line_of(starts, m.start()), "a Process() in a file with no terminate()"


# ---------------------------------------------------------------------------------------------------------------
# Scope and driver.


def is_test_path(path: str) -> bool:
    name = Path(path).name
    parts = path.split("/")
    if any(part in ("tests", "Tests", "test", "__tests__", "benches", "examples", "fixtures", "vendor", "testdata") for part in parts):
        return True
    return (
        name in ("tests.rs", "test.rs", "build.rs")
        or name.endswith(("_tests.rs", "_test.rs", "Tests.swift", ".d.ts"))
        or name.startswith("test_")
        or re.search(r"\.(?:test|spec|stories|bench)\.[cm]?[jt]sx?$", name) is not None
        or "test_support" in name
        or "testing" in name
    )


def language(path: str) -> Optional[str]:
    if is_test_path(path):
        return None
    if path.startswith(RUST_ROOT) and path.endswith(".rs"):
        crate = path[len(RUST_ROOT) :].split("/", 1)[0]
        return None if crate in SKIPPED_CRATES else "rust"
    if path.startswith(TS_ROOT) and path.endswith(TS_SUFFIXES):
        return "ts"
    if path.startswith(SWIFT_ROOT) and path.endswith(".swift"):
        return "swift"
    return None


# Each rule with the substrings one of which its pattern needs: a file with none of them skips the rule (and a file
# that skips every rule is never masked), which keeps the whole tree's scan to a few seconds.
RULES = {
    "rust": (
        ("R1", rust_r1, ("connect", "Client")),
        ("R2", rust_r2, ("Command::new",)),
        ("R3", rust_r3, ("spawn",)),
        ("R5", rust_r5, ("sleep", "tick()")),
    ),
    "ts": (
        ("R4", ts_r4, ("setInterval", "setTimeout", "WebSocket", "EventSource")),
        ("R5", ts_r5, ("while (true", "while(true", "while (1)", "while(1)", "for (;;", "for(;;")),
    ),
    "swift": (("R6", swift_r6, ("webSocketTask", "URLSessionWebSocketTask", "Process(")),),
}


def scan_text(path: str, text: str, lang: Optional[str] = None) -> List[Hit]:
    lang = lang or language(path)
    if lang is None:
        return []
    checks = [(rule, check) for rule, check, needs in RULES[lang] if any(word in text for word in needs)]
    if not checks:
        return []
    original = text.split("\n")
    masked = mask(text, lang)
    if lang == "rust":
        masked = mask_rust_tests(masked)
    starts = offsets(masked)
    masked_lines = masked.split("\n")
    markers = SWIFT_MARKERS if lang == "swift" else MARKERS
    hits: List[Hit] = []
    seen = set()
    for rule, check in checks:
        for line, detail in check(path, masked, masked_lines, starts, text):
            if (rule, line) in seen or escaped(original, line, markers):
                continue
            seen.add((rule, line))
            hits.append(Hit(path, line, rule, original[line - 1], detail))
    return sorted(hits, key=lambda hit: (hit.line, hit.rule))


def tracked_files(root: Path) -> List[str]:
    listed = subprocess.run(
        ["git", "-C", str(root), "ls-files", "-z", "--", RUST_ROOT, TS_ROOT, SWIFT_ROOT],
        check=True,
        capture_output=True,
    ).stdout.decode("utf-8", "replace")
    return sorted(path for path in listed.split("\0") if path and language(path))


def scan_repo(root: Path, paths: Optional[Sequence[str]] = None) -> List[Hit]:
    hits: List[Hit] = []
    for path in paths if paths is not None else tracked_files(root):
        if language(path) is None:
            continue
        try:
            text = (root / path).read_text(encoding="utf-8", errors="replace")
        except OSError:
            continue
        hits.extend(scan_text(path, text))
    return hits


# ---------------------------------------------------------------------------------------------------------------
# Baseline: `RULE | PATH | FINGERPRINT | line text`, one line per hit (a repeated line is listed once per hit).

BASELINE_HEADER = """\
# Today's connection and lifetime hits (scripts/lint-connection-lifetimes.py), one per line:
#   RULE | PATH | FINGERPRINT | LINE TEXT (for reading; the fingerprint is of this text)
# The fingerprint is of the hit line's text, not its number, so an edit elsewhere does not churn it. Fix a hit and
# drop its line (`python3 scripts/lint-connection-lifetimes.py --update-baseline`); never add one by hand: a hit that
# is right as written carries `// lifetime-ok: <reason>` instead. Why and how: """ + HANDBOOK + "\n"


def load_baseline(text: str) -> Counter:
    counts: Counter = Counter()
    for raw in text.splitlines():
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        parts = [part.strip() for part in line.split(" | ", 3)]
        if len(parts) < 3 or not re.fullmatch(r"R[1-6]", parts[0]) or not re.fullmatch(r"[0-9a-f]{12}", parts[2]):
            raise SystemExit(f"lint-connection-lifetimes: a baseline line needs `RULE | PATH | FINGERPRINT | TEXT`: {raw}")
        counts[(parts[1], parts[0], parts[2])] += 1
    return counts


def render_baseline(hits: Sequence[Hit]) -> str:
    rows = sorted(
        f"{hit.rule} | {hit.path} | {hit.fingerprint} | {normalize(hit.text)[:120]}" for hit in hits
    )
    return BASELINE_HEADER + "".join(row + "\n" for row in rows)


def compare(hits: Sequence[Hit], baseline: Counter) -> Tuple[List[Hit], List[Tuple[Tuple[str, str, str], int]]]:
    """New hits (over the baseline's count for their key) and stale baseline keys (with how many are gone)."""
    by_key: Dict[Tuple[str, str, str], List[Hit]] = {}
    for hit in hits:
        by_key.setdefault(hit.key, []).append(hit)
    new: List[Hit] = []
    for key, group in by_key.items():
        allowed = baseline.get(key, 0)
        if len(group) > allowed:
            # Which of identical lines is new is unknowable; report the last ones.
            new.extend(group[allowed:])
    stale = [(key, count - len(by_key.get(key, []))) for key, count in baseline.items() if count > len(by_key.get(key, []))]
    return sorted(new, key=lambda h: (h.path, h.line)), sorted(stale)


def annotate(level: str, path: str, line: Optional[int], title: str, message: str, github: bool) -> str:
    if github:
        where = f"file={path}" + (f",line={line}" if line else "")
        body = message.replace("%", "%25").replace("\r", "%0D").replace("\n", "%0A")
        return f"::{level} {where},title={title}::{body}"
    return f"{path}:{line or ''}: {level}: {title}: {message}"


def main(argv: Optional[Sequence[str]] = None) -> int:
    parser = argparse.ArgumentParser(
        description=__doc__.split("\n\n")[0],
        epilog=(
            f"Principles and fixes: {HANDBOOK}. Related checks: scripts/lint-short-gates.py (short fixed gates on slow"
            " paths) and scripts/cmux-next/check-concurrency.sh (timers, sleeps and polling loops in NEXT Swift;"
            " `// wakeup-allow:`). Escape a hit that is right as written with `// lifetime-ok: <reason>`."
        ),
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    parser.add_argument("--strict", action="store_true", help="exit 1 on a new hit or a stale baseline entry")
    parser.add_argument("--update-baseline", action="store_true", help="rewrite the baseline to today's hits")
    parser.add_argument("--baseline", type=Path, default=BASELINE, help="baseline file (default: %(default)s)")
    parser.add_argument("--root", type=Path, default=REPO_ROOT, help="repository root (default: this checkout)")
    parser.add_argument("--counts", action="store_true", help="print today's hits per rule and exit")
    parser.add_argument("paths", nargs="*", help="scan only these repo-relative paths (default: every NEXT file)")
    args = parser.parse_args(argv)

    hits = scan_repo(args.root, args.paths or None)
    if args.counts:
        counts = Counter(hit.rule for hit in hits)
        for rule in sorted(WHY):
            print(f"{rule} {counts.get(rule, 0)}")
        print(f"total {len(hits)}")
        return 0
    if args.update_baseline:
        if args.paths:
            raise SystemExit("lint-connection-lifetimes: --update-baseline scans the whole tree; drop the paths")
        args.baseline.write_text(render_baseline(hits), encoding="utf-8")
        print(f"lint-connection-lifetimes: wrote {len(hits)} hits to {args.baseline}")
        return 0

    baseline = load_baseline(args.baseline.read_text(encoding="utf-8")) if args.baseline.exists() else Counter()
    if args.paths:
        scanned = set(args.paths)
        baseline = Counter({key: count for key, count in baseline.items() if key[0] in scanned})
    new, stale = compare(hits, baseline)
    github = os.environ.get("GITHUB_ACTIONS") == "true"
    level = "error" if args.strict else "warning"
    for hit in new:
        why, fix = WHY[hit.rule]
        message = f"{hit.rule}: {hit.detail}. Why: {why}. Fix: {fix}; or mark it `// lifetime-ok: <reason>` ({HANDBOOK})."
        print(annotate(level, hit.path, hit.line, f"lint-connection-lifetimes {hit.rule}", message, github))
        if not github:
            print(f"    {hit.text.strip()}")
    for (path, rule, fp), gone in stale:
        message = (
            f"{gone} baseline hit(s) {rule} {fp} are gone (fixed or moved); shrink the baseline:"
            " python3 scripts/lint-connection-lifetimes.py --update-baseline"
        )
        print(annotate("error" if args.strict else "notice", path, None, f"lint-connection-lifetimes {rule} fixed", message, github))
    total = sum(baseline.values())
    print(
        f"lint-connection-lifetimes: {len(hits)} hits, {total} in the baseline, {len(new)} new, "
        f"{sum(gone for _, gone in stale)} fixed since the baseline"
        + ("" if args.strict else " (warn-only)")
    )
    if args.strict and (new or stale):
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
