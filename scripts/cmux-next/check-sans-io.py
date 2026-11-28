#!/usr/bin/env python3
"""SANS-IO guard: a Rust module that says it is sans-IO never reads a clock, opens a socket, sleeps or spawns.

A sans-IO state machine takes time (`now: Instant`) and input as arguments and returns what to send and when
to wake it (`poll_timeout`); its caller owns the clock, the sockets and the tasks. That is what lets its tests
skip minutes of backoff, keepalive and idle timeout in a microsecond, and pipe two peers into each other with
loss, reordering and long RTT as plain inputs. One stray `Instant::now()` inside it ends that quietly: the tests
still pass, but now they sleep or flake.

Which files: a Rust file under cmux-tui/crates whose module doc's first paragraph (its leading `//!` lines up
to the first blank `//!` line) says "sans-IO" (any case, `sans-io`, `sans IO`), and every file below that
module (its `mod x;` files: `foo.rs` owns `foo/`). So `cmux-transport/src/hop.rs` ("this module is its sans-IO
implementation") covers `hop/leg.rs`, `hop/rx.rs` and the rest. A crate's lib.rs that only mentions a sans-IO
part further down is not covered.

What is product code: as check-spawn-owner.py has it (rust_test_modules.py, plus nothing after a trailing
`#[cfg(test)] mod ... {`); a comment is not a line. Tests may read the clock.

What it refuses there (FORBIDDEN below): `Instant::now()`, `SystemTime::now()` and chrono's `now()`; tokio's
`sleep`, `sleep_until`, `interval` and `timeout`, and `thread::sleep`; socket types (`UdpSocket`, `TcpStream`,
`TcpListener`, `UnixStream`, `UnixListener`, `UnixDatagram`); `tokio::spawn`, `thread::spawn`; ambient
randomness (`thread_rng()`, `rand::random`, `OsRng`). Address types (`SocketAddr`, `IpAddr`) and the `Instant`
type itself are fine: they are values.

No baseline: every covered file passed when this landed (2026-11-27), so any hit fails with a `next:` line.
A text scan of the covered files only, well under a second. An error in the guard itself prints a warning
and passes (fail open), as the other ratchets do. Its rules are tested by tests/test_sans_io_guard.py.

Usage: scripts/cmux-next/check-sans-io.py [repo-root] [--list]
"""

from __future__ import annotations

import importlib.util
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
CRATES = os.path.join("cmux-tui", "crates")
MARK = re.compile(r"sans[-\s]?io\b", re.IGNORECASE)
COMMENT = re.compile(r"^\s*(//|/\*|\*(\s|/|$))")
TEST_TAIL = re.compile(r"^#\[cfg\(test\)\]\s*\n(?:#\[[^\n]*\]\s*\n)*(?:pub(?:\([^)]*\))?\s+)?mod\s+\w+\s*\{",
                       re.MULTILINE)
FORBIDDEN = [
    ("reads the clock", re.compile(r"\b(?:Instant|SystemTime|Utc|Local)::now\s*\(")),
    ("sleeps or sets a timer", re.compile(
        r"\b(?:tokio::time::|time::)?(?:sleep|sleep_until|interval|interval_at|timeout|timeout_at)\s*\("
        r"|\bthread::sleep\s*\(")),
    ("opens a socket", re.compile(r"\b(?:UdpSocket|TcpStream|TcpListener|UnixStream|UnixListener|UnixDatagram)\b")),
    ("spawns a task or thread", re.compile(r"(?<![\w:])(?:tokio::(?:task::)?|task::|(?:std::)?thread::)spawn\s*\(")),
    ("draws ambient randomness", re.compile(r"\bthread_rng\s*\(|\brand::random\b|\bOsRng\b")),
]
NEXT = ("next: take it as an argument (`now: Instant`, a seeded `&mut impl Rng`, the bytes that came in) and hand "
        "the action back (`poll_transmit`, `poll_timeout`); the driver that owns the socket and the clock does "
        "it. If this file is not sans-IO, take \"sans-IO\" out of its module doc's first paragraph.")
SKIP_DIRS = {"target", ".build", "node_modules"}


def load_test_modules():
    spec = importlib.util.spec_from_file_location("rust_test_modules", os.path.join(HERE, "rust_test_modules.py"))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def headline(text: str) -> str:
    """The first paragraph of the file's leading `//!` doc."""
    lines = []
    for line in text.split("\n"):
        stripped = line.strip()
        if not stripped.startswith("//!"):
            if lines or stripped:
                break
            continue
        body = stripped[3:].strip()
        if not body:
            if lines:
                break
            continue
        lines.append(body)
    return " ".join(lines)


def module_folder(path: str) -> str:
    here, name = os.path.split(path)
    return here if name in ("mod.rs", "lib.rs", "main.rs") else os.path.join(here, name[:-3])


def product_text(text: str) -> str:
    match = TEST_TAIL.search(text)
    return text[: match.start()] if match else text


def hits(text: str) -> list[tuple[int, str, str]]:
    found = []
    for number, line in enumerate(product_text(text).split("\n"), 1):
        if COMMENT.match(line):
            continue
        code = line.split("//", 1)[0]
        for why, pattern in FORBIDDEN:
            if pattern.search(code):
                found.append((number, why, line.strip()))
                break
    return found


def rust_files(top: str):
    for here, dirs, files in os.walk(top):
        dirs[:] = sorted(d for d in dirs if d not in SKIP_DIRS and d not in ("tests", "benches", "examples"))
        for name in sorted(files):
            if name.endswith(".rs"):
                yield os.path.join(here, name)


HEAD_BYTES = 8192  # a module doc's first paragraph sits well inside this


def crate_of(top: str, path: str) -> str:
    return os.path.join(top, os.path.relpath(path, top).split(os.sep, 1)[0])


def covered(root: str) -> list[str]:
    """Sans-IO files under ROOT's crates (product code only), in path order. Each file's first HEAD_BYTES are
    read to find the marked modules; rust_test_modules scans only the crates that have one."""
    top = os.path.join(root, CRATES)
    if not os.path.isdir(top):
        return []
    paths = list(rust_files(top))
    folders = []
    marked = set()
    for path in paths:
        with open(path, "rb") as f:
            head = f.read(HEAD_BYTES)
        if b"//!" in head and MARK.search(headline(head.decode("utf-8", errors="replace"))):
            marked.add(path)
            folders.append(module_folder(path))
    found = [p for p in paths if p in marked or any(p.startswith(folder + os.sep) for folder in folders)]
    tests = {}
    rust_test_modules = load_test_modules() if found else None
    out = []
    for path in found:
        crate = crate_of(top, path)
        if crate not in tests:
            tests[crate] = rust_test_modules.scan(crate)
        if not tests[crate].contains(path):
            out.append(path)
    return out


def main(argv: list[str]) -> int:
    args = [a for a in argv if not a.startswith("--")]
    root = os.path.abspath(args[0] if args else os.getcwd())
    files = covered(root)
    if "--list" in argv:
        for path in files:
            print(os.path.relpath(path, root))
        return 0
    bad = 0
    for path in files:
        with open(path, encoding="utf-8", errors="replace") as f:
            for number, why, line in hits(f.read()):
                bad += 1
                print(f"check-sans-io: {os.path.relpath(path, root)}:{number} {why} in a sans-IO module: {line}")
    if bad:
        print(NEXT)
        return 1
    print(f"check-sans-io: {len(files)} sans-IO file(s) take time, I/O and tasks from their caller")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv[1:]))
    except Exception as error:  # noqa: BLE001 — fail open, as the other ratchets do
        print(f"::warning title=check-sans-io::the guard itself failed ({error!r}); passing")
        sys.exit(0)
