#!/usr/bin/env python3
"""Ratchet: a git transfer from github.com in a workflow aborts on a stall the way the handbook says.

Handbook network-transfer-stalls-the-whole-job: GitHub sends only keepalives while it builds a pack of this
repository (p50 66 s, p95 286 s), so a low-speed abort must be 1 B/s for at least 60 s, and a fetch needs a wall
clock bound and a bounded retry. On 2026-11-27 "Operation too slow" and "Checkout ... has timed out" were 78 of 465
false reds in 24 h (meter signatures #2, #4, #5).

Checks, over every .github/workflows/*.yml:
  1. no `git -c http.lowSpeedLimit=N` fetch or clone with N > 1, or a fetch or clone with lowSpeedTime under 60;
  2. every runner pool-mirror merge-ref fetch (`"+$SHA:refs/remotes/origin/checkout"`) is bounded (timeout),
     aborts at 1 B/s for 60 s and sits in a retry loop.
"""
from __future__ import annotations

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
WORKFLOWS = sorted((ROOT / ".github" / "workflows").glob("*.y*ml"))

LIMIT = re.compile(r"http\.lowSpeedLimit[= ](\d+)")
TIME = re.compile(r"http\.lowSpeedTime[= ](\d+)")
POOL_FETCH = '"+$SHA:refs/remotes/origin/checkout"'


def command_at(lines: list[str], i: int) -> str:
    """The shell command around line i, with backslash continuations joined."""
    start = i
    while start > 0 and lines[start - 1].rstrip().endswith("\\"):
        start -= 1
    end = i
    while end < len(lines) - 1 and lines[end].rstrip().endswith("\\"):
        end += 1
    return " ".join(line.strip() for line in lines[start : end + 1])


def problems() -> list[str]:
    out: list[str] = []
    for path in WORKFLOWS:
        rel = path.relative_to(ROOT)
        lines = path.read_text().splitlines()
        for i, line in enumerate(lines):
            cmd = command_at(lines, i) if ("lowSpeed" in line or POOL_FETCH in line) else ""
            if "lowSpeed" in line and re.search(r"\b(fetch|clone)\b", cmd):
                for m in LIMIT.finditer(line):
                    if int(m.group(1)) > 1:
                        out.append(f"{rel}:{i + 1}: lowSpeedLimit={m.group(1)} on a fetch/clone; use 1 (GitHub builds the pack silently)")
                for m in TIME.finditer(line):
                    if int(m.group(1)) < 60:
                        out.append(f"{rel}:{i + 1}: lowSpeedTime={m.group(1)} on a fetch/clone; use 60 or more")
            if POOL_FETCH in line and " fetch " in f" {cmd} ":
                if not re.search(r"\btimeout \d+", cmd):
                    out.append(f"{rel}:{i + 1}: pool-mirror fetch has no wall clock bound (timeout N)")
                if "http.lowSpeedLimit=1 " not in cmd or "http.lowSpeedTime=60" not in cmd:
                    out.append(f"{rel}:{i + 1}: pool-mirror fetch lacks -c http.lowSpeedLimit=1 -c http.lowSpeedTime=60")
                window = "\n".join(lines[max(0, i - 6) : i + 1])
                if not re.search(r"for try in 1 2 3|git_retry|fetch_retry", window):
                    out.append(f"{rel}:{i + 1}: pool-mirror fetch is not in a bounded retry")
    return out


def self_test() -> None:
    import tempfile

    global WORKFLOWS, ROOT
    saved = (WORKFLOWS, ROOT)
    with tempfile.TemporaryDirectory() as d:
        ROOT = Path(d)
        wf = ROOT / ".github" / "workflows"
        wf.mkdir(parents=True)
        (wf / "bad.yml").write_text(
            "run: |\n"
            "  git -c http.lowSpeedLimit=1000 -c http.lowSpeedTime=20 fetch origin x\n"
            "  GIT_CONFIG_COUNT=1 \\\n"
            '    git fetch --depth=2 origin "+$SHA:refs/remotes/origin/checkout"\n'
            "  git -c http.lowSpeedLimit=1 -c http.lowSpeedTime=15 ls-remote origin\n"
        )
        WORKFLOWS = [wf / "bad.yml"]
        got = problems()
        assert len(got) == 5, got
        (wf / "bad.yml").write_text(
            "run: |\n"
            "  for try in 1 2 3; do\n"
            '    if X=1 \\\n'
            '      timeout 240 git -c http.lowSpeedLimit=1 -c http.lowSpeedTime=60 fetch --depth=2 origin "+$SHA:refs/remotes/origin/checkout"; then break; fi\n'
            "  done\n"
        )
        assert problems() == [], problems()
    WORKFLOWS, ROOT = saved


def main() -> int:
    self_test()
    found = problems()
    if found:
        print("\n".join(found))
        print(f"{len(found)} git transfer(s) violate handbook network-transfer-stalls-the-whole-job")
        return 1
    print(f"ok: {len(WORKFLOWS)} workflows, every fetch/clone low-speed abort is 1 B/s for >= 60 s; pool-mirror fetches bounded and retried")
    return 0


if __name__ == "__main__":
    sys.exit(main())
