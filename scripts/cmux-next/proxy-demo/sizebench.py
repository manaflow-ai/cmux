#!/usr/bin/env python3
"""Resize bench for the proxy demo: does every layer follow a resize?

A harness tmux server (its own socket, `-L cmuxbench`) runs a real cmux
client, `cmux attach --terminal TERM`, in a window of a known size. The bench
resizes that window and checks, after each step, the three layers that must
agree:

  1. the daemon's terminal grid      (`cmux terminal TERM screen read`)
  2. the inner tmux client size      (`tmux list-clients` on the default server)
  3. the inner tmux panes            (pane heights sum to the client height - 1)

Cases: single steps (grow, shrink, tiny, wide), a drag storm (40 sizes in
about a second, as a split drag sends), and a return to the first size. Each
case reports the time until all layers agreed, or FAIL with what disagreed.
The Mac app's view sizing (split drag in the app, window resize, zoom, browser
viewport) needs the app on screen and is in workspace-proxy-DESIGN.md 9.

  sizebench.py --session cmux-chief-2e448bc2 --terminal term_… --tmux-session NAME
"""

from __future__ import annotations

import argparse
import json
import shlex
import subprocess
import sys
import time

HARNESS = ["tmux", "-L", "cmuxbench"]


def sh(argv: list[str]) -> str:
    return subprocess.run(argv, capture_output=True, text=True, timeout=20).stdout


CMUX = "cmux"


def daemon_grid(session: str, terminal: str) -> tuple[int, int]:
    data = json.loads(sh([CMUX, "--session", session, "--json", "terminal", terminal, "screen", "read"]))
    value = data.get("value", data)
    return int(value["cols"]), int(value["rows"])


def inner_client(tmux_session: str) -> tuple[int, int] | None:
    for line in sh(["tmux", "list-clients", "-F", "#{session_name} #{client_width} #{client_height}"]).splitlines():
        name, w, h = line.rsplit(" ", 2)
        if name == tmux_session:
            return int(w), int(h)
    return None


def inner_panes(tmux_session: str) -> list[tuple[int, int]]:
    out = sh(["tmux", "list-panes", "-t", f"{tmux_session}:", "-F", "#{pane_width} #{pane_height}"])
    return [tuple(map(int, l.split())) for l in out.splitlines() if l]  # type: ignore[misc]


def check(args: argparse.Namespace, want: tuple[int, int]) -> tuple[bool, str]:
    grid = daemon_grid(args.session, args.terminal)
    client = inner_client(args.tmux_session)
    panes = inner_panes(args.tmux_session)
    problems = []
    if grid != want:
        problems.append(f"daemon grid {grid[0]}x{grid[1]}")
    if client != want:
        problems.append(f"tmux client {client}")
    # Vertical split: panes share the width, heights + 1 border = client height - 1 status.
    if panes and client:
        if any(w != client[0] for w, _ in panes):
            problems.append(f"pane widths {[w for w, _ in panes]}")
        if sum(h for _, h in panes) + len(panes) - 1 != client[1] - 1:
            problems.append(f"pane heights {[h for _, h in panes]}")
        if len(panes) > 1 and min(h for _, h in panes) < 3 and client[1] >= 15:
            problems.append(f"monitor pane collapsed to {min(h for _, h in panes)} rows")
    return (not problems), ", ".join(problems)


def settle(args: argparse.Namespace, want: tuple[int, int], timeout: float) -> tuple[bool, float, str]:
    start = time.time()
    detail = ""
    while time.time() - start < timeout:
        ok, detail = check(args, want)
        if ok:
            return True, time.time() - start, ""
        time.sleep(0.05)
    return False, time.time() - start, detail


def resize(w: int, h: int) -> None:
    sh([*HARNESS, "resize-window", "-t", "bench", "-x", str(w), "-y", str(h)])


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--session", required=True)
    parser.add_argument("--terminal", required=True)
    parser.add_argument("--tmux-session", required=True)
    parser.add_argument("--timeout", type=float, default=5.0)
    parser.add_argument("--json", action="store_true")
    parser.add_argument("--cmux", default="cmux",
                        help="cmux CLI path; the harness tmux server does not inherit this shell's PATH")
    args = parser.parse_args(argv)
    global CMUX
    CMUX = args.cmux

    sh([*HARNESS, "kill-server"])
    sh([*HARNESS, "new-session", "-d", "-s", "bench", "-x", "120", "-y", "40",
        f"env -u TMUX {shlex.quote(CMUX)} attach --session {args.session} --terminal {args.terminal}"])
    sh([*HARNESS, "set-option", "-g", "window-size", "manual"])
    results = []
    try:
        cases: list[tuple[str, list[tuple[int, int]]]] = [
            ("attach 120x40", []),
            ("grow 200x60", [(200, 60)]),
            ("shrink 80x24", [(80, 24)]),
            ("tiny 20x6", [(20, 6)]),
            ("wide 300x20", [(300, 20)]),
            ("drag storm 40 steps", [(100 + i * 3, 30 + (i % 7)) for i in range(40)] + [(161, 45)]),
            ("back to 120x40", [(120, 40)]),
        ]
        for name, steps in cases:
            for w, h in steps:
                resize(w, h)
                if len(steps) > 1:
                    time.sleep(0.025)
            want = steps[-1] if steps else (120, 40)
            ok, took, detail = settle(args, want, args.timeout)
            results.append({"case": name, "want": f"{want[0]}x{want[1]}", "ok": ok,
                            "ms": round(took * 1000), "detail": detail})
    finally:
        sh([*HARNESS, "kill-server"])
    if args.json:
        print(json.dumps(results, indent=2))
    else:
        for r in results:
            status = "ok  " if r["ok"] else "FAIL"
            print(f"{status} {r['case']:<22} want {r['want']:<8} {r['ms']:>5} ms  {r['detail']}")
    return 0 if all(r["ok"] for r in results) else 1


if __name__ == "__main__":
    sys.exit(main())
