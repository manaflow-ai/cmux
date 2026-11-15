#!/usr/bin/env python3
"""Flag resources nothing bounds or owns: the "unfreed memory" lint for time and processes.

A connection with no timeout, a process nobody stops, a task or timer nobody holds and a wait with no
deadline all leak the same way memory does: nothing fails when they go in, and later something hangs, piles
up or outlives its owner. This lint finds those shapes in the product sources (Rust, TypeScript, Go):

  connect-no-timeout  a connection opened with nothing bounding it: Rust TcpStream/UnixStream::connect and
                      connect_async outside a timeout, a reqwest client without .timeout; TypeScript fetch
                      without a signal, a WebSocket with no open deadline; Go net.Dial, http.Get/Post,
                      http.DefaultClient, an http.Client without Timeout.
  process-no-cleanup  a child process nothing stops: Rust Command .spawn() without kill_on_drop(true) or a
                      later kill; TypeScript spawn/exec/execFile/Bun.spawn without a signal, timeout or later
                      .kill(); Go exec.Command (use exec.CommandContext).
  task-unowned        a background task whose handle is dropped: Rust tokio::spawn, spawn_blocking,
                      spawn_local, thread::spawn and thread::Builder .spawn as a bare statement; Go `go`
                      statements with no context, WaitGroup, errgroup or done channel.
  timer-unowned       a TypeScript setTimeout/setInterval whose handle is dropped, so nothing can cancel it.
  wait-no-deadline    a wait that can block forever: Rust .wait(), .wait_with_output(), Command .output() and
                      thread .join() with no timeout near them; TypeScript execSync/spawnSync/execFileSync
                      without a timeout.

It is a pattern lint, not a type checker: comments and string contents are blanked first, and "near" means
the same statement or the few lines around it. Tests, benches, examples, scripts and Rust #[cfg(test)]
modules are not scanned.

Today's cases are recorded in scripts/ci/resource-lifetime-allowlist.json, per rule and file, with the exact
number of matches and a reason. They are reported as warnings. The check fails when a file not on the list
matches, when a file has more matches than its entry (new code has to follow the rule), when it has fewer
(lower the count, so the list only shrinks), and when an entry is stale or has no reason. Entries whose
reason starts with "debt:" are the recorded baseline. In CI, CMUX_GUARDS_BASE_SHA names the base commit: an
entry added or raised since that commit's list fails unless its reason starts with "safe:" and says why the
resource is bounded some other way, so debt never grows and the exception shows in review.

  scripts/ci/lint_resource_lifetimes.py               check (exit 1 on a new case, 2 if the scan failed)
  scripts/ci/lint_resource_lifetimes.py --list        print every finding, file:line rule
  scripts/ci/lint_resource_lifetimes.py --write-baseline
                                                   rewrite the counts from the tree, keeping reasons; new
                                                   entries get "debt:" reasons a reviewer will see in the diff
"""

from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
ALLOWLIST = Path(__file__).resolve().parent / "resource-lifetime-allowlist.json"

RULES = ("connect-no-timeout", "process-no-cleanup", "task-unowned", "timer-unowned", "wait-no-deadline")

HOW = {
    "connect-no-timeout": "bound the connect: tokio::time::timeout / connect_timeout / a reqwest .timeout, "
                          "fetch with an AbortSignal (AbortSignal.timeout), a WebSocket open deadline that "
                          "closes and retries, net.DialTimeout / DialContext / an http.Client with Timeout",
    "process-no-cleanup": "give the child an owner that stops it: kill_on_drop(true) or a kill on the "
                          "owner's teardown, a spawn signal/timeout or .kill(), exec.CommandContext",
    "task-unowned": "keep the handle (JoinHandle, JoinSet, AbortHandle, a cancellation token) where its owner "
                    "can stop or await it; in Go pass a context or join it with a WaitGroup/errgroup",
    "timer-unowned": "keep the timer's id and clear it when its owner goes away (an effect cleanup, dispose)",
    "wait-no-deadline": "bound the wait: tokio::time::timeout, wait_timeout / try_wait with a deadline, an "
                        "execSync/spawnSync timeout",
}

DEBT_REASON = "debt: recorded when the lint started (2026-11-11); bound or own it, then lower the count"

RUST_ROOTS = ("cmux-tui/", "coderouter/", "services/")
TS_ROOTS = ("webviews/", "cmux-tui/frontends/", "agent-chat/", "workers/", "web/")
GO_ROOTS = ("daemon/", "cmux-tui/")
NOT_PRODUCT = re.compile(
    r"(^|/)(tests?|benches|examples|e2e|__tests__|__mocks__|fixtures|scripts|testdata|test-utils|vendor|"
    r"node_modules|dist|build|target|\.next)/"
    r"|(\.test|\.spec|\.stories|\.bench)\.(ts|tsx)$|\.d\.ts$|_test\.go$|(^|/)(tests|test_support)\.rs$"
    r"|_tests?\.rs$|(^|/)build\.rs$"
)

# A file needs one of these words before any tokenizing happens.
CANDIDATE_WORDS = {
    "rs": ("connect", "spawn", "wait", "output()", "join()", "reqwest"),
    "ts": ("fetch", "WebSocket", "setTimeout", "setInterval", "spawn", "exec"),
    "go": ("Dial", "http.", "go ", "exec.Command"),
}


@dataclass(frozen=True)
class Finding:
    path: str
    line: int
    rule: str
    text: str


def lang_of(rel: str) -> str | None:
    if NOT_PRODUCT.search(rel):
        return None
    if rel.endswith(".rs") and rel.startswith(RUST_ROOTS):
        return "rs"
    if rel.endswith((".ts", ".tsx", ".mts", ".cts")) and rel.startswith(TS_ROOTS):
        return "ts"
    if rel.endswith(".go") and rel.startswith(GO_ROOTS):
        return "go"
    return None


# --- blanking: comments and string contents become spaces, newlines stay, so offsets and lines still match.

# Where something that is not code can start; everything between two of these is code and is skipped at once.
OPENERS = {
    "rs": re.compile(r"""//|/\*|(?<![\w])r#*"|"|'"""),
    "ts": re.compile(r"""//|/\*|["'`]"""),
    "go": re.compile(r"""//|/\*|["'`]"""),
}
RUST_CHAR = re.compile(r"'(?:\\[^']{1,10}|[^'\\\n]{1,2})'")


def blank(source: str, lang: str) -> str:
    out = list(source)
    n = len(source)

    def wipe(a: int, b: int) -> None:
        b = min(b, n)
        if a < b:
            out[a:b] = [ch if ch == "\n" else " " for ch in source[a:b]]

    opener = OPENERS[lang]
    i = 0
    while True:
        m = opener.search(source, i)
        if not m:
            break
        i, tok = m.start(), m.group(0)
        if tok == "//":
            j = source.find("\n", i)
            j = n if j < 0 else j
            wipe(i, j)
        elif tok == "/*":
            depth, j = 1, i + 2
            while j < n and depth:
                close = source.find("*/", j)
                nested = source.find("/*", j) if lang == "rs" else -1
                if close < 0:
                    j = n
                elif 0 <= nested < close:
                    depth, j = depth + 1, nested + 2
                else:
                    depth, j = depth - 1, close + 2
            wipe(i, j)
        elif tok.startswith("r"):
            hashes = len(tok) - 2
            end = source.find('"' + "#" * hashes, m.end())
            end = n if end < 0 else end
            wipe(m.end(), end)
            j = end + 1 + hashes
        elif tok == "'" and lang in ("rs", "go"):
            c = RUST_CHAR.match(source, i)
            if c:
                wipe(i + 1, c.end() - 1)
                j = c.end()
            else:
                j = i + 1  # a Rust lifetime
        else:
            # Rust strings and backtick strings span lines; the rest end at the line.
            raw = tok == "`" and lang == "go"
            multiline = lang == "rs" or tok == "`"
            j = i + 1
            while j < n and source[j] != tok:
                if source[j] == "\\" and not raw:
                    j += 1
                elif source[j] == "\n" and not multiline:
                    break
                j += 1
            wipe(i + 1, j)
            j += 1
        i = max(j, i + 1)
    return "".join(out)


def strip_rust_test_modules(code: str) -> str:
    """Blank `#[cfg(test)] mod x { ... }` blocks: inline unit tests are not product code."""
    out = list(code)
    for m in re.finditer(r"#\[cfg\(test\)\]\s*(?:#\[[^\]]*\]\s*)*(?:pub(?:\([^)]*\))?\s+)?mod\s+\w+\s*\{", code):
        j = close_of(code, m.end() - 1)
        for k in range(m.start(), j):
            if out[k] != "\n":
                out[k] = " "
    return "".join(out)


PAIRS = {"(": ")", "[": "]", "{": "}"}


def close_of(code: str, open_at: int) -> int:
    """Index just past the bracket matching the one at open_at (end of text when unbalanced)."""
    depth = 0
    for k in range(open_at, len(code)):
        ch = code[k]
        if ch in "([{":
            depth += 1
        elif ch in ")]}":
            depth -= 1
            if depth == 0:
                return k + 1
    return len(code)


def prev_char(code: str, at: int) -> tuple[str, int, bool]:
    """The non-space character before `at`, its index, and whether a newline sat between."""
    k, crossed = at - 1, False
    while k >= 0 and code[k].isspace():
        crossed = crossed or code[k] == "\n"
        k -= 1
    return (code[k] if k >= 0 else ""), k, crossed


def next_char(code: str, at: int) -> tuple[str, int]:
    k = at
    while k < len(code) and code[k].isspace():
        k += 1
    return (code[k] if k < len(code) else ""), k


def statement_start(code: str, at: int, lang: str) -> int:
    """Start of the statement holding `at`: after the nearest ; { } at this nesting level or above."""
    depth = 0
    k = at - 1
    while k >= 0:
        ch = code[k]
        if ch in ")]":
            depth += 1
        elif ch in "([":
            depth -= 1
        elif ch in ";{}" and depth <= 0:
            return k + 1
        elif ch == "\n" and lang == "go" and depth <= 0 and code[max(0, k - 1)] not in ",(+&|.":
            return k + 1
        k -= 1
    return 0


def statement_end(code: str, at: int, lang: str) -> int:
    depth = 0
    for k in range(at, len(code)):
        ch = code[k]
        if ch in "([{":
            depth += 1
        elif ch in ")]}":
            if depth == 0:
                return k
            depth -= 1
        elif ch == ";" and depth == 0:
            return k
        elif ch == "\n" and lang == "go" and depth == 0:
            return k
    return len(code)


def lines_around(code: str, at: int, before: int, after: int) -> str:
    line_start = code.rfind("\n", 0, at) + 1
    a = line_start
    for _ in range(before):
        a = code.rfind("\n", 0, max(0, a - 1)) + 1
    b = at
    for _ in range(after + 1):
        nl = code.find("\n", b)
        b = len(code) if nl < 0 else nl + 1
    return code[a:b]


TIMEOUT_WORDS = re.compile(r"timeout|deadline|Timeout|Deadline|within|bounded")


# --- Rust

RS_CONNECT = re.compile(r"\b(?:TcpStream|UnixStream)::connect\s*\(|\bconnect_async\s*\(")
RS_REQWEST = re.compile(r"\breqwest::(?:get|Client::new)\s*\(|\breqwest::Client::builder\s*\(\)")
# Literal first, prefix checked after: a pattern that opens with a lookbehind is tried at every offset.
RS_TASK = re.compile(r"spawn(?:_blocking|_local)?\s*\(")
RS_TASK_PREFIX = re.compile(r"(?:^|[^\w.:])(?P<path>(?:tokio::)?(?:task::)?|(?:std::)?thread::)$")
RS_THREAD_BUILDER = re.compile(r"thread::Builder::new\s*\(")
RS_CMD_SPAWN = re.compile(r"\.spawn\s*\(\s*\)")
RS_WAIT = re.compile(r"\.(?:wait|wait_with_output|join)\s*\(\s*\)")
RS_OUTPUT = re.compile(r"\.output\s*\(\s*\)")
RS_TRAILERS = re.compile(r"^(?:\s*(?:\?|\.(?:expect|unwrap|context|with_context|map_err|ok)\s*\([^;]*?\)))*\s*;")


def handle_dropped(code: str, call_start: int, call_end: int, lang: str) -> bool:
    """A spawn whose handle nobody keeps: a bare statement (or `let _ =`, `drop(`, `void`)."""
    start = statement_start(code, call_start, lang)
    head = code[start:call_start].strip()
    if head not in ("", "let _ =", "let _=", "drop(", "void", "_ ="):
        return False
    if lang == "rs":
        return head == "drop(" or bool(RS_TRAILERS.match(code[call_end:]))
    ch, _ = next_char(code, call_end)
    return ch in (";", "}", "") or lang == "ts" and ch not in (".", "?", ",", ")", "]")


def scan_rust(code: str) -> list[tuple[int, str]]:
    hits: list[tuple[int, str]] = []
    for m in RS_CONNECT.finditer(code):
        start = statement_start(code, m.start(), "rs")
        end = statement_end(code, m.start(), "rs")
        near = code[start:end] + lines_around(code, m.start(), 3, 2)
        if "connect_timeout" in near or TIMEOUT_WORDS.search(near):
            continue
        hits.append((m.start(), "connect-no-timeout"))
    for m in RS_REQWEST.finditer(code):
        end = statement_end(code, m.start(), "rs")
        if not re.search(r"\.timeout\s*\(|\.connect_timeout\s*\(", code[m.start():end]):
            hits.append((m.start(), "connect-no-timeout"))
    for m in RS_TASK.finditer(code):
        prefix = RS_TASK_PREFIX.search(code, max(0, m.start() - 24), m.start())
        if not prefix:
            continue
        call_start = prefix.start("path")
        open_at = m.end() - 1
        if handle_dropped(code, call_start, close_of(code, open_at), "rs"):
            hits.append((call_start, "task-unowned"))
    for m in RS_THREAD_BUILDER.finditer(code):
        begin = m.start() - 5 if code.startswith("std::", m.start() - 5) else m.start()
        if begin and (code[begin - 1].isalnum() or code[begin - 1] in "_.:"):
            continue
        end = statement_end(code, begin, "rs")
        sp = re.search(r"\.spawn\s*\(", code[begin:end])
        if sp and handle_dropped(code, begin, close_of(code, begin + sp.end() - 1), "rs"):
            hits.append((begin, "task-unowned"))
    for m in RS_CMD_SPAWN.finditer(code):
        start = statement_start(code, m.start(), "rs")
        before = lines_around(code, m.start(), 40, 0)
        stmt = code[start:statement_end(code, m.start(), "rs")]
        if "Command" not in stmt and not re.search(r"Command::new|Command\b", before):
            continue
        if "kill_on_drop(true)" in before or "kill_on_drop(true)" in stmt:
            continue
        bound = re.match(r"\s*let\s+(?:mut\s+)?(\w+)", code[start:m.start()])
        after = code[m.end():m.end() + 12000]
        if bound and re.search(r"\b%s\s*\.\s*(?:kill|start_kill)\s*\(" % re.escape(bound.group(1)), after):
            continue
        hits.append((m.start(), "process-no-cleanup"))
    for regex in (RS_WAIT, RS_OUTPUT):
        for m in regex.finditer(code):
            start = statement_start(code, m.start(), "rs")
            stmt = code[start:statement_end(code, m.start(), "rs")]
            if regex is RS_OUTPUT and not re.search(r"Command", stmt + lines_around(code, m.start(), 20, 0)):
                continue
            near = stmt + lines_around(code, m.start(), 3, 1)
            if TIMEOUT_WORDS.search(near) or "select!" in lines_around(code, m.start(), 6, 0):
                continue
            hits.append((m.start(), "wait-no-deadline"))
    return hits


# --- TypeScript

TS_FETCH = re.compile(r"(?<![\w.$])(?:(?:window|globalThis|self)\.)?fetch\s*\(")
TS_WS = re.compile(r"\bnew\s+WebSocket\s*\(")
TS_TIMER = re.compile(r"(?<![\w.$])(?:(?:window|globalThis|self)\.)?(?:setTimeout|setInterval)\s*\(")
TS_PROC = re.compile(r"(?<![\w$])((?:Bun|child_process|cp|childProcess)\.)?"
                     r"(spawn|exec|execFile|execSync|spawnSync|execFileSync)\s*\(")
TS_PROC_IMPORT = re.compile(r"""["'](?:node:)?child_process["']""")


def ts_call_is_definition(code: str, close: int) -> bool:
    ch, _ = next_char(code, close)
    return ch in ("{", ":")


def scan_ts(code: str, raw: str) -> list[tuple[int, str]]:
    hits: list[tuple[int, str]] = []
    for m in TS_FETCH.finditer(code):
        close = close_of(code, m.end() - 1)
        if ts_call_is_definition(code, close):
            continue
        if re.search(r"(function|async)\s*$", code[max(0, m.start() - 12):m.start()]):
            continue
        if not re.search(r"\bsignal\b", code[m.end():close]):
            hits.append((m.start(), "connect-no-timeout"))
    for m in TS_WS.finditer(code):
        if not re.search(r"setTimeout\s*\(|[Tt]imeout|[Dd]eadline", lines_around(code, m.start(), 5, 40)):
            hits.append((m.start(), "connect-no-timeout"))
    for m in TS_TIMER.finditer(code):
        close = close_of(code, m.end() - 1)
        if ts_call_is_definition(code, close):
            continue
        start = statement_start(code, m.start(), "ts")
        head = code[start:m.start()].strip()
        # Without semicolons a statement can also start after a newline that ends an expression.
        prev, _, crossed = prev_char(code, m.start())
        bare = head in ("", "void") or (crossed and prev not in "=(,:?&|+-*/!<>[" and not code[:m.start()].rstrip().endswith("=>"))
        if not bare:
            continue
        nxt, _ = next_char(code, close)
        if nxt in (".", "?", ",", ")", "]") and nxt != "":
            continue
        hits.append((m.start(), "timer-unowned"))
    has_child_process = bool(TS_PROC_IMPORT.search(raw))
    for m in TS_PROC.finditer(code):
        qualified = m.group(1)
        if code[max(0, m.start() - 1)] == ".":
            continue
        if not qualified and not has_child_process:
            continue
        close = close_of(code, m.end() - 1)
        if ts_call_is_definition(code, close):
            continue
        name = m.group(2)
        raw_args = raw[m.end():close]
        if name.endswith("Sync"):
            if not re.search(r"\btimeout\b", raw_args):
                hits.append((m.start(), "wait-no-deadline"))
            continue
        if re.search(r"\b(signal|timeout)\b", raw_args):
            continue
        start = statement_start(code, m.start(), "ts")
        bound = re.match(r"\s*(?:const|let|var)\s+(\w+)|\s*(?:this\.)?(\w+)\s*=", code[start:m.start()])
        var = bound and (bound.group(1) or bound.group(2))
        if var and re.search(r"\b%s\s*(?:\?\.|\.)\s*kill\s*\(" % re.escape(var), code):
            continue
        hits.append((m.start(), "process-no-cleanup"))
    return hits


# --- Go

GO_CONNECT = re.compile(r"\bnet\.Dial\s*\(|\bhttp\.(?:Get|Post|PostForm|Head)\s*\(|\bhttp\.DefaultClient\b")
GO_CLIENT = re.compile(r"&?http\.Client\s*\{")
GO_STMT = re.compile(r"(?m)^[ \t]*(go)\s+")
GO_CMD = re.compile(r"\bexec\.Command\s*\(")
GO_OWNED = re.compile(r"\bctx\b|[Cc]ontext|\bwg\b|WaitGroup|errgroup|\.Done\(\)|\bdone\b|\bstop\b|\bquit\b")


def scan_go(code: str) -> list[tuple[int, str]]:
    hits: list[tuple[int, str]] = []
    for m in GO_CONNECT.finditer(code):
        hits.append((m.start(), "connect-no-timeout"))
    for m in GO_CLIENT.finditer(code):
        if "Timeout" not in code[m.start():close_of(code, m.end() - 1)]:
            hits.append((m.start(), "connect-no-timeout"))
    for m in GO_STMT.finditer(code):
        end = statement_end(code, m.end(), "go")
        if not GO_OWNED.search(code[m.end():end]):
            hits.append((m.start(1), "task-unowned"))
    for m in GO_CMD.finditer(code):
        hits.append((m.start(), "process-no-cleanup"))
    return hits


def scan_text(raw: str, lang: str) -> list[tuple[int, str, str]]:
    """(line, rule, source line) for every finding in one file's text."""
    code = blank(raw, lang)
    if lang == "rs":
        code = strip_rust_test_modules(code)
        hits = scan_rust(code)
    elif lang == "ts":
        hits = scan_ts(code, raw)
    else:
        hits = scan_go(code)
    raw_lines = raw.splitlines()
    out = []
    for at, rule in sorted(set(hits)):
        line = code.count("\n", 0, at) + 1
        out.append((line, rule, raw_lines[line - 1].strip() if line - 1 < len(raw_lines) else ""))
    return out


def tracked_files() -> list[str]:
    argv = ["git", "-C", str(ROOT), "ls-files", "-z", "--"]
    argv += [f"{r}*.{ext}" for r in RUST_ROOTS for ext in ("rs",)]
    argv += [f"{r}*.{ext}" for r in TS_ROOTS for ext in ("ts", "tsx", "mts", "cts")]
    argv += [f"{r}*.go" for r in GO_ROOTS]
    out = subprocess.run(argv, capture_output=True, check=True).stdout
    return sorted({p for p in out.decode().split("\0") if p})


def scan() -> list[Finding]:
    findings: list[Finding] = []
    for rel in tracked_files():
        lang = lang_of(rel)
        if lang is None:
            continue
        path = ROOT / rel
        if path.is_symlink() or not path.is_file():
            continue
        try:
            raw = path.read_text(encoding="utf-8")
        except (UnicodeDecodeError, OSError):
            continue
        if not any(word in raw for word in CANDIDATE_WORDS[lang]):
            continue
        for line, rule, text in scan_text(raw, lang):
            findings.append(Finding(rel, line, rule, text))
    return findings


def counts(findings: list[Finding]) -> dict[str, dict[str, int]]:
    found: dict[str, dict[str, int]] = {rule: {} for rule in RULES}
    for f in findings:
        found[f.rule][f.path] = found[f.rule].get(f.path, 0) + 1
    return found


# --- the allowlist

def base_ref() -> str:
    base = (os.environ.get("RESOURCE_LIFETIME_BASE") or os.environ.get("CMUX_GUARDS_BASE_SHA") or "").strip()
    if not base or set(base) == {"0"}:
        return ""
    p = subprocess.run(["git", "-C", str(ROOT), "cat-file", "-e", f"{base}^{{commit}}"], capture_output=True)
    if p.returncode != 0:
        # Say so: without the base, a new "debt:" entry is not caught here.
        print(f"lint-resource-lifetimes: base {base} is not in this checkout; the shrink-only check is skipped",
              file=sys.stderr)
        return ""
    return base


def base_allowlist() -> dict | None:
    """The allowlist at the base commit, or None when unset or the base predates it."""
    base = base_ref()
    if not base:
        return None
    p = subprocess.run(["git", "-C", str(ROOT), "show", f"{base}:{ALLOWLIST.relative_to(ROOT)}"],
                       capture_output=True, text=True)
    return json.loads(p.stdout) if p.returncode == 0 else None


def problems(found: dict[str, dict[str, int]], allow: dict, base: dict | None) -> list[str]:
    out = [f"unknown rule {rule!r} in the allowlist" for rule in sorted(set(allow) - set(RULES))]
    for rule in RULES:
        allowed = allow.get(rule, {})
        for rel, n in sorted(found[rule].items()):
            entry = allowed.get(rel)
            if entry is None:
                out.append(f"{rule}: {rel}: {n} new case(s)")
            elif n > entry.get("count", 0):
                out.append(f"{rule}: {rel}: {n} cases, the allowlist says {entry.get('count')}: a new one")
            elif n < entry.get("count", 0):
                out.append(f"{rule}: {rel}: {n} cases, the allowlist says {entry.get('count')}: lower the count "
                           f"(it only shrinks; --write-baseline does it)")
        for rel, entry in sorted(allowed.items()):
            count = entry.get("count")
            if type(count) is not int or count < 1:
                out.append(f"{rule}: {rel}: the count must be a positive integer, not {count!r}")
            if rel not in found[rule]:
                out.append(f"{rule}: {rel}: listed but no longer matches; remove its entry (--write-baseline)")
            if not re.match(r"(safe|debt): \S", str(entry.get("reason", ""))):
                out.append(f"{rule}: {rel}: the reason must start with \"safe: \" or \"debt: \" and say why")
        if base is not None:
            old = base.get(rule, {})
            for rel, entry in sorted(allowed.items()):
                was = old.get(rel, {}).get("count", 0)
                if entry.get("count", 0) > was and not str(entry.get("reason", "")).startswith("safe:"):
                    out.append(f"{rule}: {rel}: allowlist {was} -> {entry.get('count')} since the base: debt only "
                               f"shrinks (a case bounded some other way gets a reason starting with \"safe:\" "
                               f"that says how)")
    return out


def write_baseline(found: dict[str, dict[str, int]], allow: dict) -> dict:
    new: dict[str, dict[str, dict]] = {}
    for rule in RULES:
        new[rule] = {}
        for rel, n in sorted(found[rule].items()):
            reason = allow.get(rule, {}).get(rel, {}).get("reason") or DEBT_REASON
            new[rule][rel] = {"count": n, "reason": reason}
    return new


def dump(allow: dict) -> str:
    lines = ["{"]
    rules = list(allow)
    for i, rule in enumerate(rules):
        lines.append(f"  {json.dumps(rule)}: {{")
        entries = list(allow[rule].items())
        for j, (rel, entry) in enumerate(entries):
            comma = "," if j < len(entries) - 1 else ""
            lines.append(f"    {json.dumps(rel)}: {json.dumps(entry, ensure_ascii=False)}{comma}")
        lines.append("  }" + ("," if i < len(rules) - 1 else ""))
    lines.append("}")
    return "\n".join(lines) + "\n"


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--list", action="store_true", help="print every finding")
    parser.add_argument("--write-baseline", action="store_true", help="rewrite the allowlist counts")
    args = parser.parse_args()
    try:
        findings = scan()
        allow = json.loads(ALLOWLIST.read_text(encoding="utf-8")) if ALLOWLIST.exists() else {}
    except (OSError, ValueError, subprocess.CalledProcessError) as error:
        print(f"lint-resource-lifetimes: the scan failed: {error}", file=sys.stderr)
        return 2
    found = counts(findings)
    if args.list:
        for f in findings:
            print(f"{f.path}:{f.line}: {f.rule}: {f.text}")
    if args.write_baseline:
        ALLOWLIST.write_text(dump(write_baseline(found, allow)), encoding="utf-8")
        print(f"lint-resource-lifetimes: wrote {len(findings)} cases to {ALLOWLIST.relative_to(ROOT)}")
        return 0
    bad = problems(found, allow, base_allowlist())
    in_actions = os.environ.get("GITHUB_ACTIONS") == "true"
    for rule in RULES:
        n = sum(found[rule].values())
        if n:
            note = (f"{n} recorded {rule} case(s) in {len(found[rule])} file(s) are still open; {HOW[rule]} "
                    f"(scripts/ci/lint_resource_lifetimes.py --list)")
            print(f"::warning title=resource lifetimes::{note}" if in_actions else f"warning: {note}")
    if bad:
        print("lint-resource-lifetimes: new resource with no bound or owner:", file=sys.stderr)
        for p in bad:
            print(f"  {p}", file=sys.stderr)
        for rule in RULES:
            if any(p.startswith(rule + ":") for p in bad):
                print(f"How to fix {rule}: {HOW[rule]}", file=sys.stderr)
        print("Fix the new case. If it is bounded or owned in a way this lint cannot see, list it in "
              f"{ALLOWLIST.relative_to(ROOT)} with a reason starting \"safe: \" that says how.", file=sys.stderr)
        return 1
    print(f"lint-resource-lifetimes: ok ({len(findings)} recorded cases, none new)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
