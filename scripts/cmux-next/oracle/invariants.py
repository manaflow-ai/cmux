#!/usr/bin/env python3
"""Oracle invariants: rules every case must hold, whatever its baseline says.

Spec: plans/cmux-next/chrome-parity/p15-oracle.md, section 3F (the invariant table). Each rule
has an id and every violation names a JSON pointer, so an Expectations line can scope a known
violation to that one value (section 3E). This file holds I16; I1-I7 are p15-oracle-110,
I11-I15 p15-oracle-217 and I17/I18 p15-oracle-188, each with its own check function here.

I16: the daemon panic log is empty at teardown, and no panic is a lock-rank panic.
  The session owner appends one JSON line per panic, caught ones too, to
  `owner-panics-<session>.jsonl` beside its sessions directory
  (cmux-tui/crates/cmux-tui/src/owner_start/owner_panic.rs); the acpmux daemon writes
  `$ACPMUX_HOME/panics.jsonl` (crates/acpmux/src/daemon.rs). Both use the cmux-panic-log line
  format: message, location (file:line:col), thread, test, backtrace. The driver puts both under
  the case root (driver_daemon.py), so the check reads every such log under the case root after
  the daemon has exited, and any line fails the case with its message and location.
  A lock-rank panic is the debug lock-order assertion of
  cmux-tui/crates/cmux-tui-core/src/lock_rank.rs. It exists only in builds with debug
  assertions, which the oracle profile keeps (cmux-tui/Cargo.toml [profile.oracle]);
  `lock_ranks_compiled_in` proves a binary has it before the driver runs cases on it.

Chrome reference (chromium/src):
- base/task/common/checked_lock_impl.cc: CheckedLock's acquisition-order DCHECKs, kept in
  release builds with dcheck_always_on (build/config/dcheck_always_on.gni), the
  configuration [profile.oracle] copies.
- third_party/blink/tools/blinkpy/web_tests/port/driver.py: after each test the driver reads
  the content shell's crash output and fails the test as a crash naming its stack, even when
  the text output matched.

    python3 -I scripts/cmux-next/oracle/invariants.py i16 CASE_ROOT [--json]
    python3 -I scripts/cmux-next/oracle/invariants.py lock-ranks BINARY

Exit codes: 0 holds, 1 violated, 2 bad input. Stdlib only, Python 3.9+, safe under `python3 -I`.
"""

from __future__ import annotations

import argparse
import fnmatch
import json
import os
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Dict, Iterator, List, Optional, Sequence

# The panic log names cmux-panic-log users write (owner_panic.rs log_path, acpmux daemon.rs
# panic_log_path). `owner-memory-*.jsonl` beside them is the memory guard's log, not panics.
PANIC_LOG_NAMES = ("owner-panics-*.jsonl", "panics.jsonl")
# The first literal piece of lock_rank.rs held::check's panic message. A lock-rank panic line
# starts with it, and a binary whose rank checker is compiled in holds it as bytes.
LOCK_RANK_PANIC_PREFIX = "lock order violation: acquiring "
# Longest message kept in a failure text; the log line itself stays on disk for the backtrace.
MAX_MESSAGE_CHARS = 2000


@dataclass(frozen=True)
class Violation:
    """One broken invariant. `pointer` is a JSON pointer an Expectations line can scope."""

    id: str
    pointer: str
    message: str
    location: str = ""
    kind: str = ""

    def to_json(self) -> Dict[str, str]:
        out = {"id": self.id, "pointer": self.pointer, "message": self.message}
        if self.location:
            out["location"] = self.location
        if self.kind:
            out["kind"] = self.kind
        return out

    def text(self) -> str:
        where = f" at {self.location}" if self.location else ""
        return f"{self.id} {self.kind or 'violation'}{where}: {self.message} [{self.pointer}]"


def pointer_token(token: str) -> str:
    return token.replace("~", "~0").replace("/", "~1")


def failure_message(violations: Sequence[Violation]) -> str:
    return "; ".join(v.text() for v in violations)


# --- I16 -------------------------------------------------------------------------------------


@dataclass(frozen=True)
class PanicLine:
    log: str  # path relative to the case root
    line: int  # 1-based
    record: Optional[Dict[str, Any]]  # None: the line is not a JSON object
    raw: str


def find_panic_logs(case_root: Path) -> List[Path]:
    """Every panic log under the case root, sorted. Symlinks are never followed: a case root
    is the driver's own directory, and a link out of it would read another case's log."""
    found = []
    for directory, dirs, files in os.walk(case_root, followlinks=False):
        dirs.sort()
        for name in sorted(files):
            if any(fnmatch.fnmatchcase(name, pattern) for pattern in PANIC_LOG_NAMES):
                path = Path(directory) / name
                if not path.is_symlink():
                    found.append(path)
    return found


def read_panic_lines(case_root: Path) -> List[PanicLine]:
    lines = []
    for log in find_panic_logs(case_root):
        relative = log.relative_to(case_root).as_posix()
        text = log.read_bytes().decode("utf-8", errors="replace")
        for number, raw in enumerate(text.splitlines(), start=1):
            if not raw.strip():
                continue
            try:
                record = json.loads(raw)
            except ValueError:
                record = None
            lines.append(PanicLine(relative, number, record if isinstance(record, dict) else None, raw))
    return lines


def is_lock_rank_panic(message: str) -> bool:
    return message.startswith(LOCK_RANK_PANIC_PREFIX)


def panic_violation(panic: PanicLine) -> Violation:
    pointer = f"/daemon/panicLog/{pointer_token(panic.log)}/{panic.line}"
    if panic.record is None:
        return Violation(
            "I16", pointer, f"{panic.log}:{panic.line} is not a panic log record: {panic.raw[:200]!r}", kind="panic"
        )
    record = panic.record
    message = str(record.get("message") or "(no message)")
    if len(message) > MAX_MESSAGE_CHARS:
        message = message[:MAX_MESSAGE_CHARS] + "..."
    thread = record.get("thread")
    details = [f"thread {thread!r}" if thread else "", "debug test trigger" if record.get("test") is True else ""]
    suffix = ", ".join(d for d in details if d)
    kind = "lock-rank" if is_lock_rank_panic(message) else "panic"
    return Violation(
        "I16",
        pointer,
        f"{message} ({suffix})" if suffix else message,
        location=str(record.get("location") or ""),
        kind=kind,
    )


def check_i16(case_root: Path) -> List[Violation]:
    """I16 over a case root whose daemon has exited: one violation per panic log line."""
    if not case_root.is_dir():
        raise FileNotFoundError(f"case root {case_root} is not a directory")
    return [panic_violation(panic) for panic in read_panic_lines(case_root)]


def _chunks(path: Path, size: int) -> Iterator[bytes]:
    with path.open("rb") as handle:
        while True:
            chunk = handle.read(size)
            if not chunk:
                return
            yield chunk


def lock_ranks_compiled_in(binary: Path, *, chunk_size: int = 1 << 20) -> bool:
    """True when the binary holds lock_rank.rs's panic text, so its rank checker is built in.

    Release builds compile the checker out (`#[cfg(debug_assertions)] mod held`) and with it the
    text; the oracle profile keeps debug assertions, so its binary has it.
    """
    needle = LOCK_RANK_PANIC_PREFIX.encode()
    tail = b""
    for chunk in _chunks(binary, max(chunk_size, len(needle))):
        window = tail + chunk
        if needle in window:
            return True
        tail = window[-(len(needle) - 1):]
    return False


# --- CLI -------------------------------------------------------------------------------------


def _report(violations: Sequence[Violation], as_json: bool) -> int:
    if as_json:
        print(json.dumps([v.to_json() for v in violations], indent=1, sort_keys=True))
    else:
        for violation in violations:
            print(violation.text())
        if not violations:
            print("I16 holds: no daemon panic log lines")
    return 1 if violations else 0


def main(argv: Optional[Sequence[str]] = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n", 1)[0])
    sub = parser.add_subparsers(dest="command", required=True)
    i16 = sub.add_parser("i16", help="check a case root's daemon panic logs")
    i16.add_argument("case_root", type=Path)
    i16.add_argument("--json", action="store_true")
    ranks = sub.add_parser("lock-ranks", help="check that a cmux-tui binary has its lock-rank checker")
    ranks.add_argument("binary", type=Path)
    args = parser.parse_args(argv)
    try:
        if args.command == "i16":
            return _report(check_i16(args.case_root), args.json)
        if lock_ranks_compiled_in(args.binary):
            print(f"{args.binary}: lock-rank checker present")
            return 0
        print(f"{args.binary}: no lock-rank checker (built without debug assertions; use linux_run.sh build)")
        return 1
    except OSError as error:
        print(f"invariants.py: {error}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
