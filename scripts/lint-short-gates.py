#!/usr/bin/env python3
"""Refuse a new short fixed gate on a slow path: Cloud start and connect, and app <-> daemon.

A short fixed gate is a literal timeout under 5 s, or a retry cap of 3 tries or fewer, on a network or daemon
call. On a path that is slow but works (a Cloud VM whose receiver comes up 20-30 s after boot, a daemon that
takes 5 s to answer while it restarts), such a gate turns "slow" into "failed": the 2 s daemon reply, two link
tries, `cmux cloud exec`'s 25 s, five busy retries in about 3 s (cmuxterm-hq docs/handbook/short-fixed-gates.md).

The fix is a deadline tied to the operation (start-chat's own `--timeout`), retries with backoff until that
deadline, and progress in `stages_ms`. A hard cap stays only where a hang must be broken, and it logs when it
fires. Such a cap is allowed in one of two ways:

  * a `short-gate: <reason>` comment on the line or the line above it, or
  * an entry in scripts/lint-short-gates-allowlist.txt: `PATH | TEXT | REASON`, where TEXT is a part of the
    line (line numbers drift, the text does not).

Tests are not scanned. `--self-test` runs the detector against its own examples.
"""

from __future__ import annotations

import re
import sys
from dataclasses import dataclass
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
ALLOWLIST = REPO_ROOT / "scripts" / "lint-short-gates-allowlist.txt"

# The slow paths: Cloud start and connect, the CLI's app and daemon calls, the app's daemon connection.
SCANNED = (
    "cmux-tui/crates/cmux-tui/src/cli/app.rs",
    "cmux-tui/crates/cmux-tui/src/cli/app/",
    "cmux-tui/crates/cmux-tui/src/cli/cloud_",
    "cmux-tui/crates/cmux-tui/src/cli/vm.rs",
    "cmux-tui/crates/cmux-tui/src/carrier/",
    "cmux-tui/crates/cmux-cloud-api/src/",
    "cmux-tui/crates/cmux-cloud-client/src/",
    "cmux-tui/crates/cmux-cloud-start-core/src/",
    "cmux-tui/crates/cmux-daemon-conn-core/src/",
    "cmux-tui/crates/cmux-relay/src/",
    "cmux-tui/crates/acpmux/src/daemon/cloud_",
    "cmux-tui/crates/acpmux/src/cli/cloud_join",
    "cmux-tui/crates/acpmux/src/hand/link.rs",
    "Packages/macOS/CmuxNext/Sources/CmuxNextCloud/",
    "Packages/macOS/CmuxNext/Sources/CmuxNextApp/Cloud/",
    "Packages/macOS/CmuxNext/Sources/CmuxNextApp/Handlers/Cloud",
    "Packages/macOS/CmuxNext/Sources/CmuxNextDaemon/Connection/",
    "Packages/macOS/CmuxNext/Sources/CmuxNextControl/Routing/",
    "webviews/src/pages/cloud/",
    "webviews/src/pages/cloud-progress/",
)
SUFFIXES = (".rs", ".swift", ".ts", ".tsx")

FLOOR_MS = 5000
MAX_SHORT_TRIES = 3

# The words that make a duration a gate on a call rather than a pause, a debounce or a display interval.
GATE_WORDS = re.compile(
    r"timeout|deadline|time_out|recv_timeout|set_read_timeout|set_write_timeout|within|answer_?wait|reply",
    re.IGNORECASE,
)
DURATIONS = (
    (re.compile(r"Duration::from_secs\((\d[\d_]*)\)"), 1000),
    (re.compile(r"Duration::from_millis\((\d[\d_]*)\)"), 1),
    (re.compile(r"\.seconds\((\d[\d_]*)\)"), 1000),
    (re.compile(r"\.milliseconds\((\d[\d_]*)\)"), 1),
    # A bare number names its unit: `timeout_ms = 1500` is milliseconds, Swift's `timeoutInterval: 2` seconds.
    (re.compile(r"\b(?:timeout_?ms|timeoutMs|deadline_?ms|deadlineMs)\b\s*[:=]\s*(\d[\d_]*)", re.IGNORECASE), 1),
    (re.compile(r"\btimeoutInterval(?:ForRequest|ForResource)?\s*[:=]\s*(\d+)\b"), 1000),
    (re.compile(r"AbortSignal\.timeout\((\d[\d_]*)\)"), 1),
)
TRIES = re.compile(
    r"\b(?:[A-Z_]*(?:TRIES|RETRIES|ATTEMPTS)|tries|attempts|maxAttempts|max_attempts|timedRetries)\b"
    r"\s*(?::\s*[A-Za-z0-9_]+\s*)?[:=]\s*(\d+)\b"
)
MARKER = "short-gate:"


@dataclass(frozen=True)
class Hit:
    path: str
    line: int
    text: str
    why: str

    def show(self) -> str:
        return f"{self.path}:{self.line}: {self.why}\n    {self.text.strip()}"


def is_test(path: str) -> bool:
    name = Path(path).name
    return (
        "/tests/" in path
        or "/Tests/" in path
        or name.endswith("_tests.rs")
        or name == "tests.rs"
        or ".test." in name
        or name.endswith("Tests.swift")
    )


def scanned(path: str) -> bool:
    return path.endswith(SUFFIXES) and any(path.startswith(root) for root in SCANNED) and not is_test(path)


def code_part(line: str) -> str:
    """The line without a trailing `//` comment (a doc comment that names a value is not a gate)."""
    stripped = line.lstrip()
    if stripped.startswith(("//", "///", "*", "/*")):
        return ""
    index = line.find("//")
    return line if index < 0 else line[:index]


def hits_in(path: str, text: str) -> list[Hit]:
    out: list[Hit] = []
    lines = text.splitlines()
    # `#[cfg(test)]` covers the one item after it: a `use` or `mod x;` line, or a block to its closing brace.
    test_item_pending, test_depth = False, 0
    for number, line in enumerate(lines, start=1):
        if test_depth > 0:
            test_depth += line.count("{") - line.count("}")
            continue
        if re.match(r"\s*#\[cfg\(test\)\]", line):
            test_item_pending = True
            continue
        if test_item_pending:
            if not line.strip() or line.lstrip().startswith("#["):
                continue
            test_item_pending = False
            depth = line.count("{") - line.count("}")
            if depth > 0:
                test_depth = depth
            continue
        code = code_part(line)
        if not code.strip():
            continue
        previous = lines[number - 2] if number > 1 else ""
        if MARKER in line or MARKER in previous:
            continue
        # A continuation line (`    Duration::from_secs(2),` under `timeout(`) takes its gate words from the line above.
        continuation = not re.search(r"\b(?:let|const|var|static|fn|func)\b|=", code)
        gate_line = GATE_WORDS.search(code) or (continuation and GATE_WORDS.search(previous))
        # A backoff's first step or a rate window spaces work; it does not end a call.
        if re.search(r"backoff|Backoff|initial:|_WINDOW|Window", code):
            gate_line = None
        for pattern, scale in DURATIONS:
            for match in pattern.finditer(code):
                ms = int(match.group(1).replace("_", "")) * scale
                before = code[: match.start()].rstrip()
                # A floor (`x.max(1 ms)`) or a comparison (`pause < 1 s`) is not a gate.
                if before.endswith(("max(", "<", ">", "<=", ">=")):
                    continue
                # A retry's pause (`Pace { pause: 2 s, deadline }`) spaces the tries inside the deadline beside it;
                # it ends no call, however many gate words share its line.
                if re.search(r"\b(?:pause|interval|spacing)\s*[:=]\s*$", before, re.IGNORECASE):
                    continue
                if 0 < ms < FLOOR_MS and gate_line:
                    out.append(Hit(path, number, line, f"a fixed {ms} ms gate (under {FLOOR_MS} ms)"))
        for match in TRIES.finditer(code):
            count = int(match.group(1))
            if 0 < count <= MAX_SHORT_TRIES:
                out.append(Hit(path, number, line, f"a fixed cap of {count} tries"))
    return out


def load_allowlist(text: str) -> list[tuple[str, str]]:
    entries = []
    for raw in text.splitlines():
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        parts = [part.strip() for part in line.split(" | ")]
        if len(parts) != 3 or not all(parts):
            raise SystemExit(f"lint-short-gates: allowlist line needs `PATH | TEXT | REASON`: {raw}")
        entries.append((parts[0], parts[1]))
    return entries


def allowed(hit: Hit, entries: list[tuple[str, str]]) -> bool:
    return any(hit.path == path and snippet in hit.text for path, snippet in entries)


def tracked_files() -> list[str]:
    import subprocess

    listed = subprocess.run(
        ["git", "-C", str(REPO_ROOT), "ls-files", "-z", "--", *SCANNED_PATHSPECS],
        check=True,
        capture_output=True,
    ).stdout.decode()
    return [path for path in listed.split("\0") if path and scanned(path)]


SCANNED_PATHSPECS = tuple(root if root.endswith("/") else root + "*" for root in SCANNED)


def self_test() -> None:
    gate = "cmux-tui/crates/cmux-tui/src/cli/cloud_x.rs"
    assert scanned(gate) and not scanned("cmux-tui/crates/cmux-tui/src/cli/cloud_x/tests.rs")
    assert not scanned("cmux-tui/crates/cmux-tui/src/cli/chat_start.rs")
    found = hits_in(gate, "let reply = tokio::time::timeout(Duration::from_secs(2), call).await;\n")
    assert [hit.why for hit in found] == ["a fixed 2000 ms gate (under 5000 ms)"], found
    assert hits_in(gate, "const READ_TIMEOUT: Duration = Duration::from_millis(1500);\n")
    assert hits_in(gate, "const READ_TRIES: u32 = 3;\n")
    assert hits_in("Packages/macOS/CmuxNext/Sources/CmuxNextCloud/A.swift", "try await send(x, deadline: .seconds(2))\n")
    assert hits_in("webviews/src/pages/cloud/a.ts", "const answer = await fetch(u, { signal: AbortSignal.timeout(2000) });\n")
    # Not gates: a pause, a long timeout, a comment, a marked hang breaker, a test module, a generous cap.
    assert not hits_in(gate, "std::thread::sleep(Duration::from_secs(2));\n")
    assert not hits_in(gate, "const CONNECT_TIMEOUT: Duration = Duration::from_secs(15);\n")
    assert not hits_in(gate, "/// the 2 s timeout the app gives Duration::from_secs(2)\n")
    assert not hits_in(gate, "// short-gate: a local socket's connect, not the call\nlet t = timeout(Duration::from_secs(2), c);\n")
    assert not hits_in(gate, "#[cfg(test)]\nmod tests { const T: Duration = Duration::from_secs(1); fn timeout() {} }\n")
    assert not hits_in(gate, "#[cfg(test)]\nmod tests {\n    const T_TIMEOUT: Duration = Duration::from_secs(1);\n}\n")
    # A test-only import or module line covers only itself: the code after it is scanned.
    after_test_use = "#[cfg(test)]\nuse foo::bar;\n\nconst REPLY_TIMEOUT: Duration = Duration::from_secs(2);\n"
    assert hits_in(gate, after_test_use), "a #[cfg(test)] use hid the code after it"
    after_test_mod = "#[cfg(test)]\n#[path = \"x_tests.rs\"]\nmod tests;\nconst READ_TRIES: u32 = 2;\n"
    assert hits_in(gate, after_test_mod), "a #[cfg(test)] mod line hid the code after it"
    after_test_block = "#[cfg(test)]\nmod tests {\n    fn a() {}\n}\nconst READ_TRIES: u32 = 2;\n"
    assert hits_in(gate, after_test_block), "a #[cfg(test)] block hid the code after it"
    assert not hits_in(gate, "const UNBOUNDED_READ_TRIES: u32 = 30;\n")
    assert not hits_in(gate, "attempt_timeout: HANDSHAKE_TIMEOUT.min(remaining.max(Duration::from_millis(1))),\n")
    assert not hits_in(gate, "if pause < Duration::from_secs(1) || past_deadline() {\n")
    assert not hits_in(gate, "Pace { pause: Duration::from_secs(2), deadline }\n")
    assert hits_in(gate, "Pace { pause: Duration::from_secs(2), deadline: Duration::from_secs(3) }\n")
    assert not hits_in(gate, "static func lateReplyBackoff() -> Backoff { .fullJitter(initial: .seconds(1), maximum: .seconds(30)) }\n")
    assert not hits_in(gate, "const WRITER_TIMEOUT: Duration = Duration::from_secs(9);\nconst RATE_WINDOW: Duration = Duration::from_secs(1);\n")
    assert not hits_in("Packages/macOS/CmuxNext/Sources/CmuxNextCloud/A.swift", "request.timeoutInterval = 15\n")
    assert hits_in("Packages/macOS/CmuxNext/Sources/CmuxNextCloud/A.swift", "request.timeoutInterval = 2\n")
    assert hits_in(gate, "let daemon = tokio::time::timeout(\n    std::time::Duration::from_secs(2),\n")
    entries = load_allowlist(f"# comment\n{gate} | from_secs(2) | a status read's hang breaker\n")
    assert allowed(Hit(gate, 1, "timeout(Duration::from_secs(2), c)", ""), entries)
    assert not allowed(Hit(gate, 1, "timeout(Duration::from_secs(3), c)", ""), entries)
    print("lint-short-gates: self-test ok")


def main(argv: list[str]) -> int:
    if "--self-test" in argv:
        self_test()
        return 0
    entries = load_allowlist(ALLOWLIST.read_text(encoding="utf-8")) if ALLOWLIST.exists() else []
    files = tracked_files()
    hits = []
    for path in files:
        text = (REPO_ROOT / path).read_text(encoding="utf-8", errors="replace")
        hits.extend(hit for hit in hits_in(path, text) if not allowed(hit, entries))
    if hits:
        print(
            "lint-short-gates: a short fixed gate on a slow path (Cloud start/connect, app <-> daemon).\n"
            "Give the call the operation's own deadline and retry with backoff until it; keep a short cap only to\n"
            "break a hang, log when it fires, and mark it `short-gate: <reason>` or add it to\n"
            "scripts/lint-short-gates-allowlist.txt (cmuxterm-hq docs/handbook/short-fixed-gates.md).\n",
            file=sys.stderr,
        )
        for hit in hits:
            print(hit.show(), file=sys.stderr)
        return 1
    print(f"lint-short-gates: ok ({len(files)} files, {len(entries)} allowlisted gates)")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
