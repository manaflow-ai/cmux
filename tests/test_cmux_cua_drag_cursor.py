#!/usr/bin/env python3
"""Live macOS regression: the cursor feed follows native button-held motion.

Run only on an isolated GUI Mac, with a helper daemon and a snapshotted pane
divider. Coordinates are the window screenshot's pixels, just like CUA drag.
This intentionally fails without a working helper, capture permission, or real
drag. It never substitutes a synthetic feed for the driver's output.
"""

import argparse
import ctypes
import json
import math
import subprocess
import time
from pathlib import Path


class Point(ctypes.Structure):
    """CoreGraphics screen point returned by CGEventGetLocation."""

    _fields_ = [("x", ctypes.c_double), ("y", ctypes.c_double)]


class NativePointer:
    """Observe the WindowServer pointer independently of the helper's feed."""

    def __init__(self):
        """Bind the native pointer location and button-state read APIs."""
        self.cg = ctypes.CDLL(
            "/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics"
        )
        self.cf = ctypes.CDLL(
            "/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation"
        )
        self.cg.CGEventSourceButtonState.argtypes = [ctypes.c_int, ctypes.c_int]
        self.cg.CGEventSourceButtonState.restype = ctypes.c_bool
        self.cg.CGEventCreate.argtypes = [ctypes.c_void_p]
        self.cg.CGEventCreate.restype = ctypes.c_void_p
        self.cg.CGEventGetLocation.argtypes = [ctypes.c_void_p]
        self.cg.CGEventGetLocation.restype = Point
        self.cf.CFRelease.argtypes = [ctypes.c_void_p]

    def snapshot(self):
        """Return the current global position and physical left-button state."""
        event = self.cg.CGEventCreate(None)
        if not event:
            raise RuntimeError("CGEventCreate failed")
        try:
            point = self.cg.CGEventGetLocation(event)
            return {
                "x": point.x,
                "y": point.y,
                "pressed": bool(self.cg.CGEventSourceButtonState(0, 0)),
            }
        finally:
            self.cf.CFRelease(event)


def read_feed(path, session):
    """Read a session observation, treating malformed visible records as unavailable."""
    try:
        state = json.loads(path.read_text())
    except (OSError, ValueError):
        return None
    if not isinstance(state, dict) or state.get("session") != session:
        return None
    if state.get("visible") and not all(
        type(state.get(key)) in (int, float) and math.isfinite(state[key])
        for key in ("x", "y")
    ):
        return None
    return state


def verify(samples, result):
    """Require sustained native motion, a visible aligned feed, and confirmed release."""
    assert result.returncode == 0, result.stderr or result.stdout
    assert '"isError":true' not in result.stdout.replace(" ", ""), result.stdout
    held = [sample for sample in samples if sample["pointer"]["pressed"]]
    assert len(held) >= 10, "No sustained native mouse-down interval was observed"
    positions = {
        (round(sample["pointer"]["x"], 1), round(sample["pointer"]["y"], 1))
        for sample in held
    }
    assert len(positions) >= 8, "Native pointer did not traverse a real drag path"
    visible = [sample for sample in held if (sample["feed"] or {}).get("visible")]
    assert len(visible) == len(held), "Cursor feed disappeared while the button was held"
    feed_positions = {
        (round(sample["feed"]["x"], 1), round(sample["feed"]["y"], 1))
        for sample in visible
    }
    assert len(feed_positions) >= 8, (
        f"Cursor feed had only {len(feed_positions)} distinct positions during "
        f"{len(positions)} native drag positions; intermediate movement is missing"
    )
    # Sampling and WindowServer delivery are asynchronous. Allow one small step
    # of lag, while rejecting the original start-then-end-only cursor behavior.
    errors = sorted(
        math.hypot(
            sample["feed"]["x"] - sample["pointer"]["x"],
            sample["feed"]["y"] - sample["pointer"]["y"],
        )
        for sample in visible
    )
    assert errors[int(len(errors) * 0.95)] <= 12, (
        f"Cursor/feed alignment p95 was {errors[int(len(errors) * 0.95)]:.1f} points"
    )
    final = samples[-1]
    assert not final["pointer"]["pressed"], "Drag left the native button pressed"
    assert (final["feed"] or {}).get("visible"), "Cursor vanished at release"
    assert math.hypot(
        final["feed"]["x"] - final["pointer"]["x"],
        final["feed"]["y"] - final["pointer"]["y"],
    ) <= 2, "Cursor did not finish at the actual release point"
    return {"native_positions": len(positions), "cursor_positions": len(feed_positions)}


def main():
    """Record and verify one real drag on a caller-supplied isolated Mac window."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--driver", required=True)
    parser.add_argument("--socket", required=True)
    parser.add_argument("--feed", required=True, type=Path)
    parser.add_argument("--pid", required=True, type=int)
    parser.add_argument("--window-id", required=True, type=int)
    parser.add_argument("--from", dest="start", required=True, nargs=2, type=float)
    parser.add_argument("--to", dest="end", required=True, nargs=2, type=float)
    parser.add_argument("--session", default="issue-12663-drag-regression")
    parser.add_argument("--out", required=True, type=Path)
    args = parser.parse_args()
    pointer = NativePointer()
    assert not pointer.snapshot()["pressed"], "A mouse button is already held"
    payload = {
        "session": args.session,
        "pid": args.pid,
        "window_id": args.window_id,
        "from_x": args.start[0], "from_y": args.start[1],
        "to_x": args.end[0], "to_y": args.end[1],
        "duration_ms": 2500,
        "steps": 100,
        "delivery_mode": "foreground",
    }
    command = [args.driver, "call", "drag", json.dumps(payload), "--raw", "--socket", args.socket]
    samples = []
    started = time.monotonic()
    process = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    try:
        while True:
            samples.append({
                "t": time.monotonic() - started,
                "pointer": pointer.snapshot(),
                "feed": read_feed(args.feed, args.session),
            })
            if process.poll() is not None:
                break
            if time.monotonic() - started > 45:
                raise TimeoutError("CUA drag did not finish within 45 seconds")
            time.sleep(0.005)
        stdout, stderr = process.communicate(timeout=5)
        result = subprocess.CompletedProcess(command, process.returncode, stdout, stderr)
        # A tool acknowledgement proves dispatch, not that WindowServer has
        # consumed mouse-up. Keep the failed trace too if this deadline expires.
        release_deadline = time.monotonic() + 2
        while True:
            final = {
                "t": time.monotonic() - started,
                "pointer": pointer.snapshot(),
                "feed": read_feed(args.feed, args.session),
            }
            samples.append(final)
            feed = final["feed"] or {}
            if (
                not final["pointer"]["pressed"]
                and feed.get("visible")
                and math.hypot(
                    feed["x"] - final["pointer"]["x"],
                    feed["y"] - final["pointer"]["y"],
                ) <= 2
            ):
                break
            if time.monotonic() >= release_deadline:
                break
            time.sleep(0.005)
        args.out.parent.mkdir(parents=True, exist_ok=True)
        args.out.write_text(json.dumps({
            "command": command, "stdout": stdout, "stderr": stderr, "samples": samples,
        }, indent=2) + "\n")
        print(json.dumps(verify(samples, result), sort_keys=True))
    finally:
        if process.poll() is None:
            process.kill()
            process.wait()


if __name__ == "__main__":
    main()
