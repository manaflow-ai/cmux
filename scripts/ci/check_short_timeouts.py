#!/usr/bin/env python3
"""Ratchet short hard timeouts in the app/daemon and agent request paths.

The checked-in allowlist is a snapshot of the debt on the base branch.  A
new hit, a raised count, or a fixed hit whose allowlist count was not lowered
is an error.  ``--update`` regenerates the snapshot after an intentional
timeout fix lands.
"""

from __future__ import annotations

import argparse
import bisect
import json
import re
import subprocess
from pathlib import Path
from typing import Iterable

ROOT = Path(__file__).resolve().parents[2]
ALLOWLIST = ROOT / "tests" / "short-timeout-allowlist.json"
FLOOR_MS = 30_000

PATH_PREFIXES = (
    "Packages/macOS/CmuxNext/Sources/CmuxNextAgentPane/",
    "Packages/macOS/CmuxNext/Sources/CmuxNextApp/",
    "Packages/macOS/CmuxNext/Sources/CmuxNextApps/",
    "cmux-tui/crates/acpmux/src/",
    "cmux-tui/crates/cmux-tui/src/cli/",
    "webviews/src/agent-session/",
)
SOURCE_SUFFIXES = {".swift", ".rs", ".ts", ".tsx", ".js", ".jsx", ".mjs", ".cjs"}
CANDIDATE = re.compile(r"seconds|milliseconds|from_secs|from_millis|timeout|deadline|SO_(?:SNDTIMEO|RCVTIMEO)", re.I)
CANDIDATE_GIT_GREP = "seconds|milliseconds|from_secs|from_millis|timeout|deadline|SO_SNDTIMEO|SO_RCVTIMEO"

NUM = r"(?:\d[\d_]*)(?:\.\d+)?"
SWIFT_DURATION = re.compile(rf"\.(seconds|milliseconds)\(\s*({NUM})\s*\)")
SWIFT_DEADLINE_WORD = re.compile(r"\b(?:deadline|timeout)\b", re.I)
SWIFT_TIMEOUT_INTERVAL = re.compile(rf"\btimeoutInterval\s*=\s*({NUM})\b")
SWIFT_SOCKET_TIMEOUT = re.compile(r"\bSO_(?:SNDTIMEO|RCVTIMEO)\b")

RUST_DURATION = re.compile(rf"\bDuration::from_(secs|millis)\(\s*({NUM})\s*\)")
RUST_CONST_NAME = re.compile(r"\b(?:const|static)\s+\w*(?:TIMEOUT|BUDGET|DEADLINE|WAIT)\w*\b", re.I)
RUST_TIMEOUT_CALL = re.compile(r"(?:tokio::time::timeout|\.timeout\s*\(|\bwait_timeout\b)")

TS_HARD_TIMEOUT = re.compile(
    rf"\b(?:[A-Za-z_]*timeout(?:Ms|_ms)|[A-Za-z_]*deadline)\b\s*(?:\??\s*:\s*[^=,;]+)?(?:=|:)[^;\n]*?({NUM})\b",
    re.I,
)

TIMEOUT_COMMENT = re.compile(r"(?:\/\/|#)\s*timeout:\s*\S", re.I)
_MASK_TOKEN = re.compile(
    r'//[^\n]*|/\*.*?\*/|"""(?:\\.|(?!""").)*"""|"(?:\\.|[^"\\\n])*"|\'(?:\\.|[^\'\\\n])*\'|`(?:\\.|[^`\\\n])*`',
    re.S,
)


def _mask(text: str) -> str:
    """Blank comments and string literals while preserving line positions."""

    def blank(match: re.Match[str]) -> str:
        return "".join("\n" if char == "\n" else " " for char in match.group(0))

    return _MASK_TOKEN.sub(blank, text)


def _strip_rust_test_modules(masked: str) -> str:
    """Blank ``#[cfg(test)] mod ... { ... }`` blocks in already-masked Rust."""

    out = list(masked)
    marker = re.compile(r"#\s*\[\s*cfg\s*\(\s*test\s*\)\s*\]")
    for match in reversed(list(marker.finditer(masked))):
        opening = masked.find("{", match.end())
        if opening < 0:
            continue
        depth = 0
        closing = None
        for i in range(opening, len(masked)):
            if masked[i] == "{":
                depth += 1
            elif masked[i] == "}":
                depth -= 1
                if depth == 0:
                    closing = i
                    break
        if closing is None:
            continue
        for i in range(match.start(), closing + 1):
            if masked[i] != "\n":
                out[i] = " "
    return "".join(out)


def _value(number: str, unit: str) -> float:
    value = float(number.replace("_", ""))
    return value if unit in {"milliseconds", "millis"} else value * 1000


def _commented(lines: list[str], line: int) -> bool:
    return any(TIMEOUT_COMMENT.search(lines[i]) for i in (line, line - 1) if 0 <= i < len(lines))


def _hit(hits: list[dict], pattern: str, line: int, source: str, lines: list[str]) -> None:
    if not _commented(lines, line - 1):
        hits.append({"pattern": pattern, "line": line, "source": source.strip()})


def scan_source(text: str, rel: str) -> list[dict]:
    """Return short-timeout hits for one repository-relative source file."""

    if Path(rel).suffix not in SOURCE_SUFFIXES or not any(rel.startswith(p) for p in PATH_PREFIXES):
        return []
    if rel.endswith("_tests.rs"):
        return []
    raw_lines = text.splitlines()
    masked = _mask(text)
    if rel.endswith(".rs"):
        masked = _strip_rust_test_modules(masked)
    lines = masked.splitlines()
    line_starts = [0]
    line_starts.extend(index + 1 for index, char in enumerate(masked) if char == "\n")
    hits: list[dict] = []

    for index, line in enumerate(lines):
        raw = raw_lines[index] if index < len(raw_lines) else ""
        if rel.endswith(".swift"):
            for match in SWIFT_TIMEOUT_INTERVAL.finditer(line):
                if float(match.group(1).replace("_", "")) * 1000 < FLOOR_MS:
                    _hit(hits, "swift-timeoutInterval", index + 1, raw, raw_lines)
            for _ in SWIFT_SOCKET_TIMEOUT.finditer(line):
                _hit(hits, "swift-socket-timeout", index + 1, raw, raw_lines)
        else:
            if not rel.endswith(".rs"):
                for match in TS_HARD_TIMEOUT.finditer(line):
                    if float(match.group(1).replace("_", "")) < FLOOR_MS:
                        _hit(hits, "ts-hard-timeout", index + 1, raw, raw_lines)

    if rel.endswith(".swift"):
        for match in SWIFT_DURATION.finditer(masked):
            index = bisect.bisect_right(line_starts, match.start()) - 1
            context = "\n".join(lines[max(0, index - 3) : index + 1])
            if SWIFT_DEADLINE_WORD.search(context) and _value(match.group(2), match.group(1)) < FLOOR_MS:
                raw = raw_lines[index] if index < len(raw_lines) else ""
                _hit(hits, "swift-duration", index + 1, raw, raw_lines)
    elif rel.endswith(".rs"):
        for match in RUST_DURATION.finditer(masked):
            index = bisect.bisect_right(line_starts, match.start()) - 1
            value = _value(match.group(2), match.group(1))
            context = "\n".join(lines[max(0, index - 3) : min(len(lines), index + 4)])
            if value < FLOOR_MS and (RUST_CONST_NAME.search(context) or RUST_TIMEOUT_CALL.search(context)):
                raw = raw_lines[index] if index < len(raw_lines) else ""
                _hit(hits, "rust-duration", index + 1, raw, raw_lines)
    return hits


def source_files(root: Path) -> Iterable[tuple[str, Path]]:
    # Let git's C scanner discard the many source files that cannot contain a
    # timeout before Python masks and parses them.  Temporary fixture roots in
    # the unit tests use the small recursive fallback.
    tracked = root / ".git"
    if tracked.exists():
        prefixes = [p for p in PATH_PREFIXES if (root / p).is_dir()]
        command = ["git", "-C", str(root), "grep", "-I", "-i", "-l", "-z", "-E", CANDIDATE_GIT_GREP, "--", *prefixes]
        result = subprocess.run(command, capture_output=True, check=False)
        if result.returncode not in (0, 1):
            raise RuntimeError(result.stderr.decode(errors="replace"))
        for raw in result.stdout.decode(errors="replace").split("\0"):
            if not raw:
                continue
            path = root / raw
            if path.suffix in SOURCE_SUFFIXES and not raw.endswith("_tests.rs"):
                yield raw, path
        return
    for prefix in PATH_PREFIXES:
        directory = root / prefix
        if not directory.is_dir():
            continue
        for path in directory.rglob("*"):
            if not path.is_file() or path.suffix not in SOURCE_SUFFIXES:
                continue
            rel = path.relative_to(root).as_posix()
            if rel.endswith("_tests.rs"):
                continue
            yield rel, path


def scan_tree(root: Path = ROOT) -> dict[str, int]:
    counts: dict[str, int] = {}
    for rel, path in source_files(root):
        try:
            hits = scan_source(path.read_text(encoding="utf-8"), rel)
        except (OSError, UnicodeDecodeError):
            continue
        for hit in hits:
            key = f"{rel}:{hit['pattern']}"
            counts[key] = counts.get(key, 0) + 1
    return dict(sorted(counts.items()))


def load(path: Path = ALLOWLIST) -> dict:
    if not path.exists():
        return {"about": "", "allow": {}}
    return json.loads(path.read_text(encoding="utf-8"))


def problems(found: dict[str, int], allow: dict) -> list[str]:
    entries = allow.get("allow", {})
    errors: list[str] = []
    for key, count in found.items():
        entry = entries.get(key)
        if entry is None:
            errors.append(f"{key}: {count} new short timeout(s); add a reason or remove the timeout")
            continue
        expected = entry.get("count")
        if not isinstance(expected, int) or expected < 1:
            errors.append(f"{key}: allowlist count must be a positive integer")
        elif count > expected:
            errors.append(f"{key}: {count} hits, allowlist says {expected}; a new short timeout was added")
        elif count < expected:
            errors.append(f"{key}: {count} hits, allowlist says {expected}; lower the count (the list only shrinks)")
    for key, entry in entries.items():
        if key not in found:
            errors.append(f"{key}: allowlisted but no longer present; remove this entry")
        if not isinstance(entry, dict) or not str(entry.get("reason", "")).strip():
            errors.append(f"{key}: allowlist entry needs a non-empty reason")
    return errors


def update(path: Path, found: dict[str, int], previous: dict) -> None:
    old = previous.get("allow", {})
    entries = {
        key: {
            "count": count,
            "reason": old.get(key, {}).get(
                "reason", "debt: pre-existing short hard timeout; remove or replace with liveness"
            ),
        }
        for key, count in found.items()
    }
    about = (
        "Short hard timeout ratchet for app/daemon, acpmux, CLI and agent-session paths. "
        "Regenerate intentionally with: python3 scripts/ci/check_short_timeouts.py --update"
    )
    # Keep one compact JSON line per file:pattern, matching the repository's
    # other ratchet allowlists so a shrink is easy to review.
    lines = ["{", f"  \"about\": {json.dumps(about)},", '  "allow": {']
    ordered = list(entries.items())
    for index, (key, entry) in enumerate(ordered):
        comma = "," if index < len(ordered) - 1 else ""
        lines.append(f"    {json.dumps(key)}: {json.dumps(entry, sort_keys=True)}{comma}")
    lines.extend(["  }", "}", ""])
    path.write_text("\n".join(lines), encoding="utf-8")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", type=Path, default=ROOT)
    parser.add_argument("--allowlist", type=Path, default=ALLOWLIST)
    parser.add_argument("--update", action="store_true", help="regenerate the baseline from the current tree")
    args = parser.parse_args()
    found = scan_tree(args.root)
    allow = load(args.allowlist)
    if args.update:
        update(args.allowlist, found, allow)
        print(f"updated {args.allowlist} with {len(found)} entries")
        return 0
    errors = problems(found, allow)
    if errors:
        print("short timeout guard failed:")
        print("\n".join(f"  {error}" for error in errors))
        return 1
    print(f"short timeout guard passed ({sum(found.values())} retained hits in {len(found)} file:pattern entries)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
