"""cmux NEXT spinner cost: what visible loading spinners cost the app while they turn.

budget.py runs this phase at the end of the `cmux-budget` session (budgets.json `scenario.spinners`,
default [1, 20]). Each step makes workspaces whose terminal reports indeterminate progress
(`cmux workspace <id> progress set --indeterminate`), so each one's sidebar row and tab show the
loading spinner, selects the first workspace so the window stays in view, settles, then measures one
idle window. Rows, for 0 spinners (the same window before any spinner) and each count:

  - CPU % and wakeups/s over the whole process tree (procs.Instance.window),
  - the app's main thread CPU % (`ps -M`: the first thread's user + system time over the window).

A spinner animated by the render server (a Core Animation layer animation) adds nearly nothing to
either: the app process gets no per-frame callback. One redrawn by the app each frame (a SwiftUI
`TimelineView(.animation)`, a timer, a display link, a web page repaint) adds main-thread time per
spinner. WindowServer's own compositing is not counted (it is not the app's process).
"""
from __future__ import annotations

import json
import re
import subprocess
import time

ROWS = [
    ("budget-spinners-0-cpu", "CPU, window in view, no spinner (before the spinner rows)", "%"),
    ("budget-spinners-0-main-cpu", "Main thread CPU, window in view, no spinner", "%"),
    ("budget-spinners-0-wakeups", "Wakeups, window in view, no spinner", "/s"),
    ("budget-spinners-1-cpu", "CPU, 1 loading spinner visible", "%"),
    ("budget-spinners-1-main-cpu", "Main thread CPU, 1 loading spinner visible", "%"),
    ("budget-spinners-1-wakeups", "Wakeups, 1 loading spinner visible", "/s"),
    ("budget-spinners-20-cpu", "CPU, 20 loading spinners visible", "%"),
    ("budget-spinners-20-main-cpu", "Main thread CPU, 20 loading spinners visible", "%"),
    ("budget-spinners-20-wakeups", "Wakeups, 20 loading spinners visible", "/s"),
]

_TIME = re.compile(r"^(?:(\d+):)?(\d+):(\d+(?:\.\d+)?)$")


def _seconds(text: str) -> float:
    match = _TIME.match(text.strip())
    if not match:
        return 0.0
    hours, minutes, seconds = match.groups()
    return int(hours or 0) * 3600 + int(minutes) * 60 + float(seconds)


def main_thread_seconds(pid: int) -> float | None:
    """User + system seconds of `pid`'s main thread (`ps -M` lists it first), or None."""
    try:
        out = subprocess.run(["ps", "-M", "-p", str(pid)], capture_output=True, text=True, timeout=10).stdout
    except (OSError, subprocess.TimeoutExpired):
        return None
    lines = out.splitlines()
    if len(lines) < 2:
        return None
    header = lines[0].split()
    first = lines[1].split()
    try:
        stime, utime = first[header.index("STIME")], first[header.index("UTIME")]
    except (ValueError, IndexError):
        return None
    return _seconds(stime) + _seconds(utime)


def _cli(browser, *argv: str) -> dict:
    out = subprocess.run([browser.app.cli_path, "--app-socket", browser.socket, "--json", *argv],
                         capture_output=True, text=True, timeout=60)
    if out.returncode != 0:
        raise RuntimeError(f"cmux {' '.join(argv[:3])}: {(out.stderr or out.stdout).strip()[:300]}")
    try:
        return json.loads(out.stdout or "{}")
    except ValueError:
        return {}


def _workspace_id(reply) -> str | None:
    """The new workspace's id: a `workspace_id` / `workspace` field at any depth (the CLI nests the
    result under `value`), else the first `ws_` id in the reply."""
    found: list[str] = []

    def walk(node, key=None):
        if isinstance(node, dict):
            for k, v in node.items():
                if k in ("workspace_id", "workspaceId") and isinstance(v, str) and v:
                    found.insert(0, v)
                walk(v, k)
        elif isinstance(node, list):
            for v in node:
                walk(v, key)
        elif isinstance(node, str) and node.startswith("ws_"):
            found.append(node)

    walk(reply)
    return found[0] if found else None


def _named_workspace(listing, name: str) -> str | None:
    """The `ws_` id of the workspace called `name` in a `workspace list` reply."""
    if isinstance(listing, dict):
        if name in (listing.get("name"), listing.get("title")):
            hit = _workspace_id({k: v for k, v in listing.items() if k in ("id", "workspace_id", "ref")})
            if hit:
                return hit
        for value in listing.values():
            hit = _named_workspace(value, name)
            if hit:
                return hit
    elif isinstance(listing, list):
        for value in listing:
            hit = _named_workspace(value, name)
            if hit:
                return hit
    return None


def _spinner_workspace(browser, index: int) -> str:
    reply = _cli(browser, "workspace", "create", "--name", f"spinner {index}", "--shell", "exec sleep 86400")
    workspace = _workspace_id(reply) or _named_workspace(_cli(browser, "workspace", "list"), f"spinner {index}")
    if not workspace:
        raise RuntimeError(f"cmux workspace create: no id in {json.dumps(reply)[:200]}")
    _cli(browser, "workspace", workspace, "progress", "set", "--indeterminate", "--label", "bench")
    return workspace


def measure(run, browser, round_no: int, count: int, seconds: float, log):
    pid = browser.instance.pid
    before = main_thread_seconds(pid)
    began = time.monotonic()
    got = browser.instance.window(seconds)
    elapsed = max(time.monotonic() - began, 1e-6)
    after = main_thread_seconds(pid)
    main_cpu = None if before is None or after is None else round(100 * (after - before) / elapsed, 3)
    name = browser.name
    run.record(name, round_no, f"budget-spinners-{count}-cpu", got["cpu_pct"], kinds=got["kinds"])
    run.record(name, round_no, f"budget-spinners-{count}-main-cpu", main_cpu)
    run.record(name, round_no, f"budget-spinners-{count}-wakeups", got["wakeups_per_s"], kinds=got["kinds"])
    app = got["kinds"].get("main", {})
    log(f"{name} r{round_no}: {count:>2} spinners: tree {got['cpu_pct']:.2f}% {got['wakeups_per_s']:.1f} wk/s, "
        f"app {app.get('cpu_pct', 0):.2f}% {app.get('wakeups_per_s', 0):.1f} wk/s, main thread {main_cpu}%")


def phase(run, browser, round_no: int, log, counts: list[int], settle: float, sleep):
    """The spinner rows: 0 spinners, then each count in `counts` (ascending), in one window."""
    seconds = float(run.args.idle)
    made: list[str] = []
    measure(run, browser, round_no, 0, seconds, log)
    for count in sorted(c for c in counts if c > 0):
        while len(made) < count:
            made.append(_spinner_workspace(browser, len(made) + 1))
        # The first spinner workspace in front: its tab's spinner and every row's spinner show.
        _cli(browser, "workspace", made[0], "focus")
        sleep(settle)
        measure(run, browser, round_no, count, seconds, log)
