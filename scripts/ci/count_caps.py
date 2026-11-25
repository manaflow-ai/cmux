#!/usr/bin/env python3
"""List the hard-coded count caps in cmux-tui that refuse work, and which ones say what they guard.

Leo, 2026-11-22, on "acpmux background task cap of 32": "shouldn't have these arbitrary caps yo".
A limit is measured, not arbitrary: a count cap that refuses work keeps a doc line on its
constant starting `Measured:` that names the resource it guards and the number behind it (one
thread or descriptor each, N KiB per item, a protocol field). This script is the detector for
cmuxterm-hq docs/handbook/count-cap-with-no-measurement.md; it reports and never blocks.

A cap here is a `const NAME: <integer type> = N;` whose name reads like a limit (MAX_, _LIMIT,
_CAP, CAPACITY, SLOTS) that the same file compares against (`>= NAME`, `> NAME`, `== NAME`)
within a few lines of a refusal (`Err(`, `bail!`, `too many`, `refus`, `limit`).

    python3 scripts/ci/count_caps.py            # unmeasured caps, one per line: file:line NAME = N
    python3 scripts/ci/count_caps.py --all      # every cap, measured or not
    python3 scripts/ci/count_caps.py --json     # the same as JSON
    python3 scripts/ci/count_caps.py --new-since origin/feat-cmux-next   # only caps a branch adds
    python3 scripts/ci/count_caps.py --self-test
"""

from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SCAN = ("cmux-tui/crates",)
CONST = re.compile(
    r"^\s*(?:pub(?:\([^)]*\))?\s+)?const\s+([A-Z0-9_]+)\s*:\s*(?:usize|u8|u16|u32|u64|i32|i64)\s*=\s*([0-9_]+|[0-9_]+\s*<<\s*[0-9]+)\s*;"
)
LIMIT_NAME = re.compile(r"(^MAX_|_MAX$|_MAX_|LIMIT|_CAP$|^CAP_|CAPACITY|SLOTS)")
# Names that are not count caps, by class (the 2026-11-22 sweep decided each by hand first):
NOT_COUNT = re.compile(
    "|".join(
        (
            # byte, size and length bounds
            r"BYTES|_LEN|LENGTH|_SIZE|_BUF|BUFFER|_CHARS|_KIB|_MIB|_TAIL|_DATA$|_OUTPUT|OUTPUT_LIMIT|_INPUT$|_FILE$",
            r"MAX_(LINE|FRAME|STREAM_FRAME|PAYLOAD|MESSAGE|REPLY|HEADER|TEXT|TITLE|QUERY|TOKEN|PATCH|CLAIM|PROLOGUE|COMPONENT|NAME|ENTRY|TICKET|SIDE)$",
            r"NAME_MAX|_MESSAGE$|DIMENSION|CURSOR|CLIPBOARD_TEXT|TEXT_UNITS",
            # time and unit constants
            r"_MS$|_SECS|_SECONDS|_NS$|KBPS|TIMEOUT|_WAIT$|MAX_SAFE_INTEGER",
            # retry, loop and depth bounds
            r"DEPTH|RETRY|RETRIES|ATTEMPTS|RESTARTS|REPEATS|CONTINUATIONS|HOPS|SYMLINK|EXPANSIONS",
            # page and window limits: the most one read returns, or a clamp on a requested limit
            r"DEFAULT_LIMIT|READ_LIMIT|PAGE_MAX|_ROWS$|^MAX_(\w+_)?LIMIT$",
            # per-request argument validation
            r"ARGS$|ARGUMENTS|ENVIRONMENT|_ENV$|SEGMENTS",
        )
    )
)
REFUSAL = re.compile(r"(Err\(|bail!|too many|refus|limit|already|at most|stop one)", re.IGNORECASE)
# A compare that makes room (drops the oldest) and returns no error is an eviction ring, not a refusal.
EVICTS = re.compile(r"(pop_front|pop_back|remove\(0\)|\.drain\(|\.clear\(\)|truncate\(|evict|forget|make_room)")
HARD_REFUSAL = re.compile(r"(Err\(|bail!|refus)")
WINDOW = 8


def is_test_path(path: Path) -> bool:
    parts = path.parts
    return "tests" in parts or path.name.endswith("_tests.rs") or path.name == "tests.rs"


def doc_above(lines: list[str], index: int) -> str:
    out = []
    i = index - 1
    while i >= 0 and (lines[i].lstrip().startswith("///") or lines[i].lstrip().startswith("#[")):
        out.append(lines[i])
        i -= 1
    return "\n".join(reversed(out))


def caps_in(path: Path, text: str) -> list[dict]:
    lines = text.splitlines()
    found = []
    for index, line in enumerate(lines):
        match = CONST.match(line)
        if not match:
            continue
        name, value = match.group(1), match.group(2)
        if not LIMIT_NAME.search(name) or NOT_COUNT.search(name):
            continue
        compare = re.compile(rf"(>=|>|==)\s*(?:Self::|self::|super::)?{name}\b")
        refuses = False
        for at, other in enumerate(lines):
            if at == index or not compare.search(other):
                continue
            near = "\n".join(lines[max(0, at - 2) : at + WINDOW])
            if REFUSAL.search(near) and (HARD_REFUSAL.search(near) or not EVICTS.search(near)):
                refuses = True
                break
        if not refuses:
            continue
        doc = doc_above(lines, index)
        found.append(
            {
                "file": str(path),
                "line": index + 1,
                "name": name,
                "value": value.replace("_", ""),
                "measured": "Measured:" in doc,
            }
        )
    return found


def scan(root: Path) -> list[dict]:
    caps = []
    for top in SCAN:
        base = root / top
        for path in sorted(base.rglob("*.rs")):
            if is_test_path(path.relative_to(base)) or "/target/" in str(path):
                continue
            try:
                text = path.read_text(encoding="utf-8")
            except (OSError, UnicodeDecodeError):
                continue
            for cap in caps_in(path.relative_to(root), text):
                caps.append(cap)
    return caps


def new_since(root: Path, base: str, caps: list[dict]) -> list[dict]:
    """The caps not in `base`'s copy of their file: what a branch adds (a review reads these)."""
    run = lambda *a: subprocess.run(["git", "-C", str(root), *a], capture_output=True, text=True)
    changed = set(run("diff", "--name-only", f"{base}...HEAD").stdout.split())
    changed |= set(run("diff", "--name-only").stdout.split())
    out = []
    for cap in caps:
        if cap["file"] not in changed:
            continue
        old = run("show", f"{base}:{cap['file']}")
        before = {c["name"] for c in caps_in(Path(cap["file"]), old.stdout)} if old.returncode == 0 else set()
        if cap["name"] not in before:
            out.append(cap)
    return out


def self_test() -> int:
    unmeasured = """
/// The most tasks one chat runs at once.
const MAX_RUNNING: usize = 32;
fn start() -> Result<(), E> {
    if running >= MAX_RUNNING {
        return Err(E::new("too many tasks; stop one first"));
    }
}
"""
    measured = """
/// Each is a thread.
/// Measured: one thread each, 2 MiB of stack address space.
pub(crate) const MAX_WAITS: usize = 64;
fn wait() { if waits.len() >= MAX_WAITS { return Err(refusal("too many waits")); } }
"""
    not_a_refusal = """
const MAX_ITEMS: usize = 8;
fn shown() { let n = items.len().min(MAX_ITEMS); if n == MAX_ITEMS { log::info!("full view"); } }
"""
    a_size = """
const OUTPUT_MAX_BYTES: usize = 1 << 20;
fn read() { if n > OUTPUT_MAX_BYTES { return Err(E::new("too large")); } }
"""
    # One sample per excluded class: each is a bound that refuses, but not a count of held work.
    not_counts = {
        "a line bound": "const MAX_LINE: usize = 65536;",
        "a frame bound": "const MAX_FRAME: usize = 1 << 24;",
        "a payload bound": "const MAX_PAYLOAD: usize = 4096;",
        "a title bound": "const MAX_TITLE: usize = 200;",
        "a pg identifier": "const APP_ID_NAME_MAX: usize = 63;",
        "a time bound": "const MAX_DEBOUNCE_SECONDS: u64 = 60;",
        "a nanosecond sample": "const KEY_SAMPLE_LIMIT_NS: u64 = 5_000;",
        "a depth bound": "const MAX_DEPTH: usize = 16;",
        "a retry bound": "const INTERFACE_RETRY_LIMIT: u32 = 64;",
        "a restart bound": "const MAX_RESTARTS: u32 = 5;",
        "a continuation bound": "const MAX_CONTINUATIONS: u64 = 50;",
        "a hop bound": "const MAX_PEER_HOPS: usize = 4;",
        "a symlink bound": "const MAX_SYMLINK_EXPANSIONS: usize = 40;",
        "a page default": "const DEFAULT_LIMIT: usize = 50;",
        "a clamp on a requested limit": "const MAX_DIRECTORY_LIMIT: u32 = 4096;",
        "a page of rows": "const MAX_WINDOW_ROWS: usize = 500;",
        "an argv bound": "const MAX_ARGS: usize = 256;",
        "an environment bound": "const MAX_PROCESS_ENVIRONMENT: usize = 512;",
    }
    for why, const in not_counts.items():
        name = const.split()[1].rstrip(":")
        sample = f"{const}\nfn f() {{ if n > {name} {{ return Err(E::new(\"too many\")); }} }}\n"
        assert caps_in(Path("e.rs"), sample) == [], f"{why} is no count cap"
    ring = """
const TOLD_LIMIT: usize = 256;
fn tell() { if told.len() >= TOLD_LIMIT { told.pop_front(); } told.push_back(id); }
"""
    assert caps_in(Path("f.rs"), ring) == [], "an eviction ring that never refuses is no cap"
    held = """
const MAX_PENDING: usize = 8;
fn hold() { if pending.len() >= MAX_PENDING { pending.pop_front(); return Err(E::new("refused")); } }
"""
    assert [c["name"] for c in caps_in(Path("g.rs"), held)] == ["MAX_PENDING"], "a ring that also refuses is a cap"
    in_flight = """
const MAX_PAGE_INFLIGHT: usize = 64;
fn call() { if slot.inflight >= MAX_PAGE_INFLIGHT { return refused("too many calls in flight"); } }
"""
    assert [c["name"] for c in caps_in(Path("h.rs"), in_flight)] == ["MAX_PAGE_INFLIGHT"], "calls in flight are a count"
    one = caps_in(Path("a.rs"), unmeasured)
    assert [(c["name"], c["value"], c["measured"]) for c in one] == [("MAX_RUNNING", "32", False)], one
    two = caps_in(Path("b.rs"), measured)
    assert [(c["name"], c["measured"]) for c in two] == [("MAX_WAITS", True)], two
    assert caps_in(Path("c.rs"), not_a_refusal) == [], "a clamp with no refusal is no cap"
    assert caps_in(Path("d.rs"), a_size) == [], "a byte bound is no count cap"
    print("count_caps self-test: ok")
    return 0


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--all", action="store_true", help="list measured caps too")
    parser.add_argument("--json", action="store_true")
    parser.add_argument("--self-test", action="store_true")
    parser.add_argument("--new-since", metavar="BASE", help="only caps this branch adds over BASE")
    parser.add_argument("--root", type=Path, default=ROOT)
    args = parser.parse_args(argv)
    if args.self_test:
        return self_test()
    caps = scan(args.root)
    if args.new_since:
        caps = new_since(args.root, args.new_since, caps)
    shown = caps if args.all else [c for c in caps if not c["measured"]]
    if args.json:
        print(json.dumps({"caps": shown, "total": len(caps), "unmeasured": sum(not c["measured"] for c in caps)}, indent=2))
        return 0
    for cap in shown:
        mark = "measured" if cap["measured"] else "no Measured: line"
        print(f"{cap['file']}:{cap['line']} {cap['name']} = {cap['value']} ({mark})")
    unmeasured = sum(not c["measured"] for c in caps)
    print(f"{len(caps)} count caps that refuse work; {unmeasured} with no Measured: line", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
