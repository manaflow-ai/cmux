#!/usr/bin/env python3
"""The input-injection A/B (README.md, "Input A/B"): every arm sends the same click, key and
scroll to the same target window, with the user's window in front (background) and with the
target in front (foreground), and each trial counts what the target itself received and what
it did to the user's window.

  input_ab.py --bin DIR --out DIR [--electron PATH] [--driver NAME=BINARY]... [--reps N]

Arms: the raw routes of cu-eval-inject (ROUTES) and one arm per --driver, a Cua Driver build
(cua-driver or cmux-cua) driven over MCP stdio with its own click, press_key and scroll tools.
Targets: native (AppKit), webkit (WKWebView) and, with --electron, electron (Chromium).

Writes OUT/input-ab.json (the aggregate below) and OUT/trials.jsonl (one line per trial).
input-ab.json: {"schema", "arms", "targets", "gestures", "conditions", "grants", "errors",
  "rows": {"ARM|TARGET|GESTURE|CONDITION": ROW}, "wins": {TARGET: {GESTURE: WIN}}}
ROW: {"n", "setup_failed", "delivered", "delivered_rate", "clean", "clean_rate", "duplicates",
  "focus_steals", "key_losses", "raises", "pointer_moved", "stray", "loc_err_max", "call_ms_p50",
  "unsupported", "errors"}. A count nobody could measure is null.
"clean" (background only) is delivered with none of: a focus steal, a key loss of the user's
window, a window raised over it, the pointer moved more than 1 pt, or input landing in it.
"""

from __future__ import annotations

import argparse
import json
import math
import os
import select
import statistics
import subprocess
import sys
import time
from pathlib import Path

SCHEMA = "cmux.cu-driver-eval.input-ab/1"
ROUTES = ["cg-pid", "sl-pid", "session-tap", "nsevent-pid", "stamped-pid"]
GESTURES = ["click", "key", "scroll"]
CONDITIONS = ["background", "foreground"]
# The gesture's point, window-local below the title bar, outside the user's window (layout()).
POINT = (200, 150)
SETTLE_S = 0.35
AFTER_S = 0.6
SCROLL_LINES = 5
# A driver arm that times out this many calls in a row is stopped for the rest of the run.
MAX_TIMEOUTS = 3


def layout(width: float, height: float) -> dict:
    """Window frames (top-left screen points) for a WIDTH x HEIGHT main display: the target at the
    top left, the user's window over the target's lower-right corner, and a pointer rest right of
    both. POINT stays outside the user's window, and the user's window keeps a corner (its lower
    right) that the target never covers, down to a 1280 x 800 display."""
    tw, th = min(900, width * 0.5), min(640, height * 0.6)
    tx, ty = 40, 60
    ww, wh = min(600, width * 0.35), min(400, height * 0.4)
    wx, wy = tx + tw * 0.55, ty + th * 0.5
    free = wx + ww
    return {"target": (tx, ty, round(tw), round(th)), "witness": (round(wx), round(wy), round(ww), round(wh)),
            "park": (round(free + (width - free) / 2), ty + 20)}


def sh(argv: list[str], timeout: float = 20) -> dict:
    proc = subprocess.run(argv, capture_output=True, text=True, timeout=timeout)
    if proc.returncode != 0:
        raise RuntimeError(f"{Path(argv[0]).name} {' '.join(argv[1:3])}: exit {proc.returncode}: {proc.stderr.strip()[-300:]}")
    lines = [line for line in proc.stdout.splitlines() if line.strip()]
    return json.loads(lines[-1]) if lines else {}


class Log:
    """A JSON-lines log one app appends to; read() returns the lines added since mark()."""

    def __init__(self, path: Path):
        self.path, self.offset = path, 0

    def lines(self) -> list[dict]:
        out = []
        try:
            text = self.path.read_text()
        except OSError:
            return out
        for raw in text.splitlines():
            try:
                out.append(json.loads(raw))
            except ValueError:
                pass
        return out

    def mark(self) -> None:
        self.offset = len(self.lines())

    def read(self) -> list[dict]:
        return self.lines()[self.offset:]

    def ready(self, timeout: float) -> dict | None:
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            for line in self.lines():
                if line.get("kind") == "ready":
                    return line
            time.sleep(0.1)
        return None


class Mcp:
    """A Cua Driver build over MCP stdio, in this process tree so it inherits this step's
    Accessibility grant and measures exactly the downloaded binary: cua-driver with `mcp --direct`
    (no daemon), cmux-cua with `mcp --no-daemon-relaunch` (never hands off to an installed
    cmux Computer Use.app). No fallback to plain `mcp`, which may hand the work to another build."""

    def __init__(self, name: str, binary: str, stderr_path: Path):
        self.name, self.next_id, self.timeouts, self.buffer = name, 1, 0, b""
        env = None
        if name.startswith("cmux-cua"):
            argv = [binary, "mcp", "--no-daemon-relaunch"]
            env = {**os.environ, "CMUX_CUA_MCP_NO_RELAUNCH": "1"}
        else:
            argv = [binary, "mcp", "--direct"]
        self.stderr = open(stderr_path, "ab")
        self.proc = subprocess.Popen(argv, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=self.stderr, env=env)
        try:
            self.request("initialize", {"protocolVersion": "2025-06-18", "capabilities": {},
                                        "clientInfo": {"name": "cu-driver-eval", "version": "1"}}, timeout=30)
            self._send({"jsonrpc": "2.0", "method": "notifications/initialized"})
        except Exception:
            self.close()
            raise

    def _send(self, message: dict) -> None:
        assert self.proc.stdin
        self.proc.stdin.write((json.dumps(message) + "\n").encode())
        self.proc.stdin.flush()

    def _line(self, deadline: float) -> bytes | None:
        """One stdout line, read with os.read into our own buffer: a buffered readline() can hold
        a second message where select() no longer sees it."""
        assert self.proc.stdout
        fd = self.proc.stdout.fileno()
        while b"\n" not in self.buffer:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                return None
            if self.proc.poll() is not None:
                raise RuntimeError(f"exited {self.proc.returncode}")
            ready, _, _ = select.select([fd], [], [], min(remaining, 0.2))
            if ready:
                chunk = os.read(fd, 65536)
                if not chunk:
                    raise RuntimeError("closed its stdout")
                self.buffer += chunk
        line, _, self.buffer = self.buffer.partition(b"\n")
        return line

    def request(self, method: str, params: dict, timeout: float = 30) -> dict:
        ident = self.next_id
        self.next_id += 1
        self._send({"jsonrpc": "2.0", "id": ident, "method": method, "params": params})
        deadline = time.monotonic() + timeout
        while True:
            raw = self._line(deadline)
            if raw is None:
                self.timeouts += 1
                raise RuntimeError(f"{method} timed out after {timeout:.0f} s")
            try:
                message = json.loads(raw)
            except ValueError:
                continue
            if message.get("id") != ident:
                continue
            self.timeouts = 0
            if "error" in message:
                raise RuntimeError(json.dumps(message["error"])[:300])
            return message.get("result") or {}

    def call(self, tool: str, args: dict) -> dict:
        result = self.request("tools/call", {"name": tool, "arguments": args})
        if result.get("isError"):
            text = " ".join(part.get("text", "") for part in result.get("content", []) if isinstance(part, dict))
            raise RuntimeError(f"{tool}: {text.strip()[:300]}")
        return result

    def close(self) -> None:
        if self.proc.poll() is None:
            try:
                self.proc.stdin.close()
                self.proc.wait(timeout=5)
            except Exception:
                self.proc.kill()
        self.stderr.close()


class Run:
    def __init__(self, args: argparse.Namespace):
        self.bin, self.out = Path(args.bin), Path(args.out)
        self.inject = str(self.bin / "cu-eval-inject")
        self.app = str(self.bin / "cu-eval-app")
        self.procs: list[subprocess.Popen] = []
        self.errors: list[str] = []
        self.trials = open(self.out / "trials.jsonl", "w")

    def launch(self, argv: list[str], name: str) -> subprocess.Popen:
        log = open(self.out / f"{name}.stderr.log", "ab")
        proc = subprocess.Popen(argv, stdout=log, stderr=log)
        self.procs.append(proc)
        return proc

    def stop(self, proc: subprocess.Popen) -> None:
        proc.terminate()
        try:
            proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            proc.kill()

    def window(self, name: str, mode: str, argv: list[str]) -> dict | None:
        log = Log(self.out / f"{name}.jsonl")
        proc = self.launch(argv, name)
        ready = log.ready(30 if mode == "electron" else 10)
        if not ready:
            self.errors.append(f"{name}: no ready line")
            self.stop(proc)
            return None
        time.sleep(0.5)
        try:
            found = sh([self.inject, "find-window", str(ready["pid"])])
        except Exception as error:
            self.errors.append(f"{name}: {error}")
            self.stop(proc)
            return None
        return {"name": name, "proc": proc, "log": log, "pid": ready["pid"], "wid": found["wid"],
                "frame": found["frame"], "scale": ready.get("scale", 2), "title_bar": ready.get("title_bar", 28),
                "pixels_per_point": {}}


def p50(values: list[float]) -> float | None:
    return round(statistics.median(values), 1) if values else None


def tap(run: Run, window: dict, local: tuple[float, float]) -> None:
    x, y, _, _ = window["frame"]
    sh([run.inject, "tap-click", str(x + local[0]), str(y + local[1])])


def trial(run: Run, arm: str, drivers: dict, target: dict, witness: dict, gesture: str, condition: str,
          park: tuple[float, float]) -> dict:
    lx, ly = POINT[0], target["title_bar"] + POINT[1]
    row = {"arm": arm, "target": target["name"], "gesture": gesture, "condition": condition}
    if arm in drivers and drivers[arm].timeouts >= MAX_TIMEOUTS:
        row["setup_failed"] = f"{arm} stopped after {MAX_TIMEOUTS} timeouts in a row"
        return row
    # Setup: a real click puts the user's window (background) or the target (foreground) in front.
    if condition == "background":
        # Its lower-right corner: the part of the user's window the target never covers.
        tap(run, witness, (witness["frame"][2] - 60, witness["frame"][3] - 40))
    else:
        tap(run, target, (40, target["title_bar"] + 40))
    sh([run.inject, "warp", str(park[0]), str(park[1])])
    time.sleep(SETTLE_S)
    before = sh([run.inject, "observe"])
    want_front = witness["pid"] if condition == "background" else target["pid"]
    if before["front_pid"] != want_front:
        row["setup_failed"] = f"front pid {before['front_pid']}, wanted {want_front}"
        return row
    target["log"].mark()
    witness["log"].mark()
    started = time.monotonic()
    try:
        if arm in ROUTES:
            x, y, w, h = target["frame"]
            posted = sh([run.inject, "post", arm, gesture, str(target["pid"]), str(target["wid"]),
                         str(x), str(y), str(w), str(h), str(lx), str(ly)])
            if posted.get("unsupported"):
                row["unsupported"] = posted["unsupported"]
                return row
        else:
            mcp = drivers[arm]
            # Screenshot pixels per window point, as get_window_state reported them for this window.
            scale = target["pixels_per_point"].get(arm) or target["scale"]
            base = {"pid": target["pid"], "window_id": target["wid"]}
            if gesture == "click":
                mcp.call("click", {**base, "x": lx * scale, "y": ly * scale})
            elif gesture == "key":
                mcp.call("press_key", {**base, "key": "a"})
            else:
                mcp.call("scroll", {**base, "x": lx * scale, "y": ly * scale, "direction": "down", "by": "line",
                                    "amount": SCROLL_LINES})
    except Exception as error:
        row["error"] = str(error)[:300]
    row["call_ms"] = round((time.monotonic() - started) * 1000, 1)
    time.sleep(AFTER_S)
    after = sh([run.inject, "observe"])

    layer = "window" if target["name"] == "native" else "dom"
    got = [e for e in target["log"].read() if e.get("kind") == "event" and e.get("layer") == layer]
    downs = [e for e in got if e["type"] == "down"]
    ups = [e for e in got if e["type"] == "up"]
    keys = [e for e in got if e["type"] == "key" and e.get("chars") == "a"]
    wheels = [e for e in got if e["type"] == "wheel"]
    row["received"] = {"down": len(downs), "up": len(ups), "key": len(keys), "wheel": len(wheels)}
    if gesture == "click":
        row["delivered"] = bool(downs and ups)
        row["duplicates"] = max(0, len(downs) - 1)
        if downs:
            want_y = ly if layer == "window" else ly - target["title_bar"]
            row["loc_err"] = round(math.hypot(downs[0]["x"] - lx, downs[0]["y"] - want_y), 1)
    elif gesture == "key":
        row["delivered"] = bool(keys)
        row["duplicates"] = max(0, len(keys) - 1)
    else:
        row["delivered"] = bool(wheels)
        row["duplicates"] = 0

    seen = witness["log"].read()
    states = [e.get("type") for e in seen if e.get("kind") == "state"]
    order = after.get("order", [])
    was = before.get("order", [])

    def above(order_list: list[int]) -> bool:
        return target["wid"] in order_list and witness["wid"] in order_list and order_list.index(target["wid"]) < order_list.index(witness["wid"])

    moved = math.hypot(after["cursor"][0] - before["cursor"][0], after["cursor"][1] - before["cursor"][1])
    row["pointer_moved"] = moved > 1
    if condition == "background":
        row["focus_steal"] = after["front_pid"] != witness["pid"] or "resign-active" in states
        row["key_loss"] = "resign-key" in states
        row["raised"] = above(order) and not above(was)
        # The window layer only: the app layer logs the same event a second time.
        row["stray"] = sum(1 for e in seen if e.get("kind") == "event" and e.get("layer") == "window")
        row["clean"] = row["delivered"] and not (row["focus_steal"] or row["key_loss"] or row["raised"]
                                                 or row["pointer_moved"] or row["stray"])
    return row


def aggregate(trials: list[dict]) -> dict:
    rows: dict[str, dict] = {}
    for t in trials:
        key = "|".join([t["arm"], t["target"], t["gesture"], t["condition"]])
        rows.setdefault(key, []).append(t)
    out = {}
    for key, ts in rows.items():
        ran = [t for t in ts if "setup_failed" not in t and "unsupported" not in t]
        bg = key.endswith("|background")

        def count(field: str) -> int | None:
            return sum(1 for t in ran if t.get(field)) if ran else None

        locs = [t["loc_err"] for t in ran if isinstance(t.get("loc_err"), (int, float))]
        out[key] = {
            "n": len(ran),
            "setup_failed": sum(1 for t in ts if "setup_failed" in t),
            "unsupported": next((t["unsupported"] for t in ts if "unsupported" in t), None),
            "delivered": count("delivered"),
            "delivered_rate": round(count("delivered") / len(ran), 3) if ran else None,
            "clean": count("clean") if bg else None,
            "clean_rate": round(count("clean") / len(ran), 3) if bg and ran else None,
            "duplicates": sum(t.get("duplicates", 0) for t in ran) if ran else None,
            "focus_steals": count("focus_steal") if bg else None,
            "key_losses": count("key_loss") if bg else None,
            "raises": count("raised") if bg else None,
            "pointer_moved": count("pointer_moved"),
            "stray": sum(t.get("stray", 0) for t in ran) if bg and ran else None,
            "loc_err_max": max(locs) if locs else None,
            "call_ms_p50": p50([t["call_ms"] for t in ran if "call_ms" in t]),
            "errors": sorted({t["error"] for t in ts if t.get("error")})[:5],
        }
    return out


def wins(rows: dict, arms: list[str], targets: list[str]) -> dict:
    """Per target and gesture, the arm with the most clean background trials (delivered and no
    disturbance), then the most delivered in the foreground, then the fastest call."""
    out: dict[str, dict] = {}
    for target in targets:
        for gesture in GESTURES:
            scored = []
            for arm in arms:
                bg = rows.get(f"{arm}|{target}|{gesture}|background") or {}
                fg = rows.get(f"{arm}|{target}|{gesture}|foreground") or {}
                if not bg.get("n"):
                    continue
                scored.append(((bg.get("clean_rate") or 0, fg.get("delivered_rate") or 0, -(bg.get("call_ms_p50") or 1e9)), arm, bg, fg))
            if not scored:
                continue
            scored.sort(reverse=True)
            (_, arm, bg, fg) = scored[0]
            out.setdefault(target, {})[gesture] = {"arm": arm, "background_clean_rate": bg.get("clean_rate"),
                                                   "foreground_delivered_rate": fg.get("delivered_rate")}
    return out


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--bin", required=True)
    parser.add_argument("--out", required=True)
    parser.add_argument("--electron", default="")
    parser.add_argument("--driver", action="append", default=[], help="NAME=BINARY")
    parser.add_argument("--reps", type=int, default=3)
    args = parser.parse_args()
    out = Path(args.out)
    out.mkdir(parents=True, exist_ok=True)
    run = Run(args)
    grants = sh([run.inject, "grants"])
    drivers: dict[str, Mcp] = {}
    targets: list[dict] = []
    result = {"schema": SCHEMA, "grants": grants, "gestures": GESTURES, "conditions": CONDITIONS}
    all_trials: list[dict] = []
    try:
        screen = sh([run.inject, "observe"]).get("screen") or [1920, 1080]
        frames = layout(*screen)
        result["screen"], result["layout"] = screen, frames
        frame = ",".join(str(v) for v in frames["witness"])
        witness = run.window("witness", "witness", [run.app, "witness", str(out / "witness.jsonl"), frame])
        if not witness:
            raise RuntimeError("the user's window did not start")
        for spec in args.driver:
            name, _, binary = spec.partition("=")
            try:
                drivers[name] = Mcp(name, binary, out / f"{name}.stderr.log")
            except Exception as error:
                run.errors.append(f"{name}: did not start over MCP: {error}")
        arms = ROUTES + list(drivers)
        target_frame = ",".join(str(v) for v in frames["target"])
        specs = [("native", [run.app, "native", str(out / "native.jsonl"), target_frame]),
                 ("webkit", [run.app, "webkit", str(out / "webkit.jsonl"), target_frame])]
        if args.electron:
            main_js = str(Path(__file__).resolve().parent / "electron" / "main.js")
            specs.append(("electron", [args.electron, main_js, str(out / "electron.jsonl"), target_frame]))
        # The pointer rests right of both windows, so no hover lands on either between trials.
        park = frames["park"]
        for name, argv in specs:
            target = run.window(name, name, argv)
            if not target:
                continue
            targets.append(target)
            for arm, mcp in drivers.items():
                try:  # an agent's first look at the window, and the pixel scale its x,y use
                    state = mcp.call("get_window_state", {"pid": target["pid"], "window_id": target["wid"]})
                    facts = state.get("structuredContent") or {}
                    width = (facts.get("window_bounds") or {}).get("width")
                    if facts.get("screenshot_width") and width:
                        target["pixels_per_point"][arm] = facts["screenshot_width"] / width
                    else:
                        run.errors.append(f"{arm} get_window_state on {name}: no screenshot size; used the backing scale")
                except Exception as error:
                    run.errors.append(f"{arm} get_window_state on {name}: {str(error)[:200]}")
            for rep in range(args.reps):
                for condition in CONDITIONS:
                    for gesture in GESTURES:
                        for arm in arms:
                            try:
                                t = trial(run, arm, drivers, target, witness, gesture, condition, park)
                            except Exception as error:
                                t = {"arm": arm, "target": name, "gesture": gesture, "condition": condition,
                                     "setup_failed": str(error)[:300]}
                            t["rep"] = rep
                            all_trials.append(t)
                            run.trials.write(json.dumps(t, sort_keys=True) + "\n")
                            run.trials.flush()
            run.stop(target["proc"])
        result["arms"] = arms
    except Exception as error:
        run.errors.append(str(error)[:300])
        result.setdefault("arms", ROUTES + list(drivers))
    finally:
        for mcp in drivers.values():
            mcp.close()
        for proc in run.procs:
            if proc.poll() is None:
                run.stop(proc)
        run.trials.close()
    names = [t["name"] for t in targets]
    result["pixels_per_point"] = {t["name"]: t["pixels_per_point"] for t in targets}
    result["targets"] = names
    result["rows"] = aggregate(all_trials)
    result["wins"] = wins(result["rows"], result["arms"], names)
    result["errors"] = run.errors
    (out / "input-ab.json").write_text(json.dumps(result, indent=2, sort_keys=True) + "\n")
    return 0 if all_trials else 4


if __name__ == "__main__":
    sys.exit(main())
