"""Failure signatures: one stable key per distinct bug, used for dedupe."""

from __future__ import annotations

import hashlib
import json
import re
from dataclasses import dataclass
from pathlib import Path

_NOISE = [
    # Paths differ per machine and job workspace: keep the file name only, so one bug has one digest.
    (re.compile(r"(?:~|/)[^\s\"'():]*/([^/\s\"'():]+)"), r"\1"),
    (re.compile(r"0x[0-9a-fA-F]+"), "0x_"),
    (re.compile(r"[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}"), "<uuid>"),
    (re.compile(r"\b\d+(\.\d+)?\b"), "N"),
    (re.compile(r"\s+"), " "),
]

# Frames that say nothing about which bug this is.
_SKIP_FRAME = re.compile(
    r"^(_?swift_|__?pthread|_dispatch_|dispatch_|abort|__abort|objc_exception|_objc_|"
    r"__exceptionPreprocess|__cxa|std::|CFRunLoop|__CFRunLoop|_CF|-\[NSApplication|"
    r"NSApplicationMain|main$|start$|Swift runtime failure|assertionFailure|_assertionFailure|"
    r"fatalError|preconditionFailure|mach_msg|__semwait|_os_unfair_lock)"
)


def normalize(text: str) -> str:
    for pattern, repl in _NOISE:
        text = pattern.sub(repl, text)
    return text.strip()


@dataclass(frozen=True)
class Signature:
    kind: str  # crash | hang | invariant | error-log | memory | launch
    key: str  # normalized, human readable
    title: str

    @property
    def digest(self) -> str:
        return hashlib.sha1(f"{self.kind}\n{self.key}".encode()).hexdigest()[:12]

    def to_json(self) -> dict:
        return {"kind": self.kind, "key": self.key, "title": self.title, "digest": self.digest}

    def same_bug(self, other: "Signature | None") -> bool:
        return other is not None and other.digest == self.digest


def _frame_name(frame: dict, images: list[dict]) -> str:
    symbol = frame.get("symbol")
    if symbol:
        return re.sub(r"\s*\+\s*\d+$", "", symbol)
    idx = frame.get("imageIndex")
    image = images[idx].get("name", "?") if isinstance(idx, int) and idx < len(images) else "?"
    return f"{image}+?"


def crash_signature(ips_path: Path, *, frames: int = 4) -> Signature:
    """Signature from a macOS .ips crash report (a JSON header line, then a JSON body)."""
    raw = ips_path.read_text(errors="replace")
    header_line, _, body_text = raw.partition("\n")
    try:
        body = json.loads(body_text)
    except json.JSONDecodeError:
        body = {}
    exc = body.get("exception", {}) or {}
    exc_kind = " ".join(str(exc.get(k, "")) for k in ("type", "signal")).strip() or "unknown"
    images = body.get("usedImages", []) or []
    threads = body.get("threads", []) or []
    faulting = body.get("faultingThread", 0)
    stack: list[str] = []
    if isinstance(faulting, int) and faulting < len(threads):
        for frame in threads[faulting].get("frames", []):
            name = _frame_name(frame, images)
            if _SKIP_FRAME.search(name):
                continue
            stack.append(normalize(name))
            if len(stack) >= frames:
                break
    reason = ""
    asi = body.get("asi") or {}
    for lines in asi.values():
        if lines:
            reason = normalize(str(lines[0]))[:160]
            break
    key = " | ".join([exc_kind, *stack]) or exc_kind
    title = f"Crash: {exc_kind} in {stack[0] if stack else 'unknown frame'}"
    if reason:
        title = f"Crash: {reason[:90]}"
    return Signature("crash", key, title)


def hang_signature(sample_text: str, *, frames: int = 5) -> Signature:
    """Signature from `sample` output: the deepest frames of the main thread's heaviest stack."""
    main: list[str] = []
    in_main = False
    last_depth = -1
    for line in sample_text.splitlines():
        if "Thread_" in line and "main-thread" in line:
            in_main = True
            continue
        if not in_main:
            continue
        m = re.match(r"^([\s+!:|]*)\d+\s+(.+?)\s+\(in ([^)]+)\)", line)
        if not m:
            if main:
                break
            continue
        depth = len(m.group(1))
        # Children are sorted heaviest first, so the first child at each level
        # is the heaviest path; a line that is not deeper ends that path.
        if depth <= last_depth:
            break
        last_depth = depth
        main.append(f"{m.group(2)} (in {m.group(3)})")
    useful = [normalize(f) for f in main if not _SKIP_FRAME.search(f)]
    tail = useful[-frames:] if useful else ["unknown"]
    ours = [f for f in tail if "(in cmux" in f or "Bonsplit" in f]
    lead = (ours or tail)[-1]
    return Signature("hang", " | ".join(tail), f"Main thread hang in {lead}")


def invariant_signature(name: str, detail: str = "") -> Signature:
    return Signature("invariant", name, f"Layout invariant broken: {name}" + (f" ({detail})" if detail else ""))


def log_signature(line: str) -> Signature:
    key = normalize(line)[:200]
    return Signature("error-log", key, f"Error logged: {key[:90]}")


def memory_signature(detail: str) -> Signature:
    return Signature("memory", "rss-growth", f"Memory grows without bound ({detail})")
