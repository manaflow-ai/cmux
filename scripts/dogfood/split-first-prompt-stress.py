#!/usr/bin/env python3
"""Stress new splits and check each one draws its first shell prompt (#16184).

Creates splits in an existing workspace (local, `cmux ssh`, or Cloud) through
the cmux CLI and reads each new pane's screen. A pane passes once its screen
shows a line matching --prompt-regex. A pane that stays blank past --timeout
is the #16184 failure: the prompt cells were lost while the cursor survived.

Each new split is closed after it is checked, so every split is made from the
same source pane at a realistic size instead of subdividing forever.

    CMUX_TAG=issue-16184-split-prompt-race \\
        scripts/dogfood/split-first-prompt-stress.py --workspace workspace:3 --count 60
"""

from __future__ import annotations

import argparse
import os
import re
import subprocess
import sys
import time
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]


def cli_prefix(args: argparse.Namespace) -> list[str]:
    if args.cli:
        return [args.cli]
    if not os.environ.get("CMUX_TAG"):
        sys.exit("Set CMUX_TAG to a tagged build or pass --cli.")
    return [str(REPO / "scripts" / "cmux-debug-cli.sh")]


def run(prefix: list[str], *argv: str) -> str:
    env = dict(os.environ, CMUX_QUIET="1")
    result = subprocess.run(
        [*prefix, *argv], text=True, capture_output=True, env=env, timeout=30
    )
    if result.returncode:
        raise RuntimeError(f"{' '.join(argv)}: {result.stderr.strip() or result.stdout.strip()}")
    return result.stdout


def read_screen(prefix: list[str], workspace: str, surface: str) -> str:
    try:
        return run(prefix, "read-screen", "--workspace", workspace, "--surface", surface, "--lines", "60")
    except RuntimeError:
        return ""


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--workspace", required=True, help="workspace ref, e.g. workspace:3")
    parser.add_argument("--surface", help="source terminal to split (default: the focused one)")
    parser.add_argument("--count", type=int, default=50)
    parser.add_argument("--timeout", type=float, default=20.0, help="seconds to wait for each prompt")
    parser.add_argument("--prompt-regex", default=r"[%$#>]\s*$", help="a prompt line matches this")
    parser.add_argument("--cli", help="cmux CLI to use instead of scripts/cmux-debug-cli.sh")
    parser.add_argument("--keep", action="store_true", help="leave failing splits open for inspection")
    args = parser.parse_args()

    prefix = cli_prefix(args)
    prompt = re.compile(args.prompt_regex, re.MULTILINE)
    source = ["--surface", args.surface] if args.surface else []
    failures: list[tuple[int, str, str]] = []
    latencies: list[float] = []

    for index in range(1, args.count + 1):
        direction = "right" if index % 2 else "down"
        out = run(prefix, "new-split", direction, "--workspace", args.workspace, *source, "--focus", "true")
        match = re.search(r"surface:\d+", out)
        if not match:
            raise RuntimeError(f"new-split returned no surface: {out!r}")
        surface = match.group(0)
        started = time.monotonic()
        screen = ""
        while time.monotonic() - started < args.timeout:
            screen = read_screen(prefix, args.workspace, surface)
            if prompt.search(screen):
                break
            time.sleep(0.1)
        elapsed = time.monotonic() - started
        if prompt.search(screen):
            latencies.append(elapsed)
            print(f"{index:3d} {surface} ok {elapsed:.2f}s", flush=True)
        else:
            failures.append((index, surface, screen))
            print(f"{index:3d} {surface} FAIL no prompt after {elapsed:.1f}s screen={screen.strip()!r}", flush=True)
            if args.keep:
                continue
        run(prefix, "close-surface", "--workspace", args.workspace, "--surface", surface)

    ok = args.count - len(failures)
    worst = f", slowest {max(latencies):.2f}s" if latencies else ""
    print(f"\n{ok}/{args.count} splits drew their first prompt{worst}")
    for index, surface, _ in failures:
        print(f"  failed: split {index} ({surface})")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
