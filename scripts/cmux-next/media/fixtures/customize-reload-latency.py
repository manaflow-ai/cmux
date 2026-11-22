#!/usr/bin/env python3
"""Save-to-pixels time of the customize app, measured inside a running cmux.

Run in a cmux terminal (the `customize-templates` tour types it): it needs
`CMUX_CUSTOMIZE_DIR` (the folder the app's daemon watches) and
`CMUX_SOCKET_PATH` (the app's control socket, which every cmux terminal has).
Each round writes `main.js` with a new revision in the sidebar section's
text, the way an editor saves, and then reads the main window as the window
server composited it (`debug.window_snapshot`) until its pixels change. The
time from the end of the write to the first changed snapshot is one sample;
a snapshot takes a few tens of milliseconds, so each sample is an upper bound
by up to one snapshot. It prints p50, p95 and max, and writes them as
`reload-latency.json` beside this script, never inside the watched folder's
own tree: under a tour that tree is the run's work directory, which the tour
removes when it ends, so the numbers would go with it. `CMUX_RELOAD_LATENCY_OUT`
names another folder for it.
"""

from __future__ import annotations

import hashlib
import json
import os
import socket
import statistics
import sys
import time
from pathlib import Path

ROUNDS = 12
TIMEOUT = 10.0

MANIFEST = {
    "$schema": "https://cmux.dev/schemas/cmux-app/2.json",
    "manifestVersion": 2,
    "id": "local/customize",
    "name": "My views",
    "version": "1.0.0",
    "description": "Save-to-pixels probe.",
    "engines": {"cmux": "^2.0"},
    "runtime": {"main": "main.js"},
    "implements": {"cmux.section/1": {"export": "render", "title": "Reload probe", "symbol": "timer",
                                      "options": {"defaultRegion": "bottom"}}},
}


def script(revision: int) -> str:
    return ("function render() {\n"
            f"  return Panel({{ title: \"Reload probe\" }}, [Text(\"Saved revision {revision}\").font(\"title\")])\n"
            "}\n"
            "globalThis.__cmuxAppExports = { render }\n")


def request(path: str, method: str, params: dict) -> dict:
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as connection:
        connection.settimeout(10)
        connection.connect(path)
        connection.sendall((json.dumps({"id": 1, "method": method, "params": params}) + "\n").encode())
        reply = b""
        while not reply.endswith(b"\n"):
            chunk = connection.recv(65536)
            if not chunk:
                break
            reply += chunk
    answer = json.loads(reply.decode() or "{}")
    if not answer.get("ok"):
        raise RuntimeError(f"{method}: {answer.get('error')}")
    return answer.get("result") or {}


def snapshot(sock: str, png: Path) -> str:
    request(sock, "debug.window_snapshot", {"kind": "main", "path": str(png)})
    return hashlib.sha256(png.read_bytes()).hexdigest()


def settle(sock: str, png: Path) -> str:
    """The window's hash once two snapshots in a row agree."""
    deadline = time.monotonic() + TIMEOUT
    last = snapshot(sock, png)
    while time.monotonic() < deadline:
        now = snapshot(sock, png)
        if now == last:
            return now
        last = now
    raise RuntimeError("the window never stopped changing")


def percentile(values: list[float], p: float) -> float:
    ordered = sorted(values)
    return ordered[min(len(ordered) - 1, round(p * (len(ordered) - 1)))]


def main() -> int:
    folder = Path(os.environ["CMUX_CUSTOMIZE_DIR"])
    sock = os.environ["CMUX_SOCKET_PATH"]
    png = folder.parent / "reload-probe.png"  # scratch: it goes with the work directory
    folder.mkdir(parents=True, exist_ok=True)
    sys.stdout.write("\033[?25l")  # no blinking cursor in the window's pixels
    sys.stdout.flush()
    try:
        return measure(folder, sock, png)
    finally:
        sys.stdout.write("\033[?25h")
        sys.stdout.flush()


def result_path() -> Path:
    """Where the numbers are kept: a folder that outlives the watched one."""
    out = os.environ.get("CMUX_RELOAD_LATENCY_OUT")
    return (Path(out) if out else Path(__file__).resolve().parent) / "reload-latency.json"


def measure(folder: Path, sock: str, png: Path) -> int:
    (folder / "cmux-app.json").write_text(json.dumps(MANIFEST, indent=2), encoding="utf-8")
    (folder / "main.js").write_text(script(0), encoding="utf-8")
    time.sleep(3)  # first install and mount
    samples: list[float] = []
    snaps: list[float] = []
    for revision in range(1, ROUNDS + 1):
        before = settle(sock, png)
        # Saved the way most editors save: a whole new file renamed over the old
        # one, so the reload never reads a half-written script.
        draft = folder.parent / "main.js.draft"
        draft.write_text(script(revision), encoding="utf-8")
        os.replace(draft, folder / "main.js")
        saved = time.monotonic()
        while True:
            started = time.monotonic()
            changed = snapshot(sock, png) != before
            ended = time.monotonic()
            snaps.append((ended - started) * 1000)
            if changed:
                samples.append((ended - saved) * 1000)
                break
            if ended - saved > TIMEOUT:
                print(f"revision {revision}: no change within {TIMEOUT:.0f}s")
                break
        if not samples and revision >= 2:
            break  # nothing reloads: stop before the tour's next step types into this terminal
    if not samples:
        print("no samples")
        return 1
    result = {"rounds": len(samples), "p50_ms": round(statistics.median(samples)),
              "p95_ms": round(percentile(samples, 0.95)), "max_ms": round(max(samples)),
              "min_ms": round(min(samples)), "snapshot_ms": round(statistics.median(snaps)),
              "samples_ms": [round(s) for s in samples]}
    out = result_path()
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(json.dumps(result), encoding="utf-8")
    print("\033[2J\033[H")
    print(f"save to pixels, {result['rounds']} saves of main.js")
    print(f"p50 {result['p50_ms']} ms   p95 {result['p95_ms']} ms   max {result['max_ms']} ms   min {result['min_ms']} ms")
    print(f"one window snapshot: {result['snapshot_ms']} ms (each sample is at most this much late)")
    print("samples: " + " ".join(str(s) for s in result["samples_ms"]))
    print(f"numbers: {out}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
