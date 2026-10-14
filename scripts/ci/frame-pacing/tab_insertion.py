#!/usr/bin/env python3
"""Cmd-T insertion guard at the tagged app's debug socket.

  tab_insertion.py drive SOCKET OUT_DIR [--record]
  tab_insertion.py judge OUT_DIR

Run in the golden-interactions app, with its isolated config and workspace. The
3, 10 and 20 counts name the tabs present BEFORE Cmd-T. Both cold and warm opens
are traced. --record also captures a cold Cmd-T at each count as composited PNG
frames with timestamps, suitable for a before/after video. No model is simulated.
"""

from __future__ import annotations

import json
import math
import sys
import time
from pathlib import Path

from golden import Driver

COUNTS = (3, 10, 20)
SCENARIOS = tuple(f"tab_insert_{count}_{kind}" for count in COUNTS for kind in ("cold", "warm"))
EPS = 0.51  # one rendered half-point pixel, plus trace serialization rounding


class InsertionDriver(Driver):
    def checked(self, method: str, params: dict | None = None) -> dict:
        result = self.call(method, params)
        if "error" in result:
            raise RuntimeError(str(result["error"]))
        return result

    def settled_tabs(self) -> list:
        trace = self.trace(["tabs"], lambda: {}, 0.3)
        samples = trace.get("samples") or []
        if len(samples) < 2 or not samples[-1].get("tabs"):
            raise RuntimeError("no tab frames from tagged app")
        if any(sample.get("tabs") != samples[-1]["tabs"] for sample in samples[-4:]):
            raise RuntimeError("tab preparation has not settled")
        return samples[-1]["tabs"]

    def prepare(self, count: int) -> None:
        # Bounded setup drives the real key route. Never replace the strip model
        # or inject fake tab cells: provisional-to-store handoff is part of the bug.
        for _ in range(25):
            tabs = self.settled_tabs()
            if len(tabs) == count:
                return
            self.checked("debug.key", {"key": "t" if len(tabs) < count else "w", "modifiers": ["command"]})
            time.sleep(0.6)
        raise RuntimeError(f"could not prepare {count} tabs")

    def run_insertions(self, record: bool) -> None:
        self.out.mkdir(parents=True, exist_ok=True)
        before = self.checked("debug.motion", {"action": "read"})
        self.save("motion_before", before)
        try:
            if before.get("speed") == "off":
                raise RuntimeError("motion is disabled in the tagged app config")
            self.checked("debug.motion", {"action": "reduce", "value": False})
            for count in COUNTS:
                for kind in ("cold", "warm"):
                    name = f"tab_insert_{count}_{kind}"
                    try:
                        self.prepare(count)
                        if kind == "cold":
                            self.checked("debug.new_tab", {"action": "drop_spare"})
                        elif not self.wait_spare():
                            raise RuntimeError("warm case has no ready spare")
                        prior_openings = self.checked("debug.new_tab", {"action": "state"}).get("openings") or []
                        trace = self.trace(["tabs", "window"], lambda: self.key("t", ["command"]), 1.2)
                        trace["initial_count"] = count
                        state = self.checked("debug.new_tab", {"action": "state"})
                        openings = state.get("openings") or []
                        trace["opening"] = openings[-1] if openings and openings[-1] != (prior_openings or [None])[-1] else None
                        self.save(name, trace)
                        if record and kind == "cold":
                            self.prepare(count)
                            self.checked("debug.new_tab", {"action": "drop_spare"})
                            # A failed recording (no screen capture on the host) is its own result;
                            # it never replaces the trace saved above.
                            capture = self.call("debug.new_tab", {
                                "action": "frame_strip", "key": "t", "duration_ms": 1200,
                                "scale": 1, "dir": str(self.out / f"video-{count}"),
                            })
                            self.save(f"video-{count}", capture)
                    except (RuntimeError, OSError) as error:
                        self.save(name, {"error": str(error)})
        finally:
            self.call("debug.motion", {"action": "reduce", "value": None})
            self.call("debug.motion", {"action": "speed", "value": before["speed"]})
            self.save("drive_log", {"log": self.log})


def judge_trace(trace: dict, count: int, kind: str) -> dict:
    problems = []
    samples = trace.get("samples") or []
    try:
        rows = [{tab[0]: tab for tab in sample.get("tabs", [])} for sample in samples]
        for row in rows:
            for tab in row.values():
                if not all(math.isfinite(float(value)) for value in tab[1:4]):
                    raise ValueError("nonfinite geometry")
    except (AttributeError, IndexError, TypeError, ValueError):
        return {"ok": False, "problems": ["not measured: malformed tab frames"]}
    if len(rows) < 12 or len(rows[0]) != count or len(rows[-1]) != count + 1:
        return {"ok": False, "problems": [f"not measured: {trace.get('error', 'missing frames or wrong tab count')}"]}
    old = set(rows[0])
    times = [sample.get("t") for sample in samples]
    if any(not isinstance(t, (int, float)) or not math.isfinite(t) for t in times):
        problems.append("missing or invalid frame times")
    elif any(b <= a for a, b in zip(times, times[1:])):
        problems.append("frame times do not increase")
    if any(row != rows[-1] for row in rows[-4:]):
        problems.append("final tab frames have not settled")
    if not old.issubset(rows[-1]):
        problems.append("an existing tab disappeared")
    widths = [sum(float(tab[2]) for id_, tab in row.items() if id_ not in old) for row in rows]
    final = widths[-1]
    if final <= EPS:
        problems.append("no new tab width")
    peak = 0.0
    reverses = False
    for width in widths:
        reverses |= width < peak - EPS
        peak = max(peak, width)
    if reverses:
        problems.append("new tab width reverses")
    if max(widths) > final + EPS:
        problems.append(f"new tab overshoots {max(widths) - final:.2f} pt")
    intermediate = sum(EPS < width < final - EPS for width in widths)
    if intermediate < 4:
        problems.append(f"only {intermediate} intermediate grow frames")
    if any(len(set(row) - old) > 1 for row in rows):
        problems.append("provisional and permanent tabs coexist")

    totals = [sum(float(tab[2]) for tab in row.values()) for row in rows]
    lo, hi = sorted((totals[0], totals[-1]))
    if any(total < lo - EPS or total > hi + EPS for total in totals):
        problems.append("strip total leaves its endpoint range")
    # An underfull strip consumes its empty space, and an overflowing strip may
    # grow. A compressed strip fills the same width before and after insertion.
    if abs(totals[-1] - totals[0]) <= EPS and max(totals) - min(totals) > EPS:
        problems.append("compressed strip total is not constant")
    visible = [sorted((tab for tab in row.values() if float(tab[2]) > EPS), key=lambda t: t[1]) for row in rows]
    seam = max((abs(float(b[1]) - float(a[1]) - float(a[2]))
                for tabs in visible for a, b in zip(tabs, tabs[1:])), default=0)
    if seam > EPS:
        problems.append(f"adjacent tab frames separate or overlap by {seam:.2f} pt")
    for id_ in old:
        if any(id_ not in row for row in rows):
            problems.append("an existing tab disappeared mid-animation")
            continue
        neighbor = [float(row[id_][2]) for row in rows]
        if neighbor[-1] < neighbor[0] - EPS:
            low = neighbor[0]
            reverses = False
            for width in neighbor:
                reverses |= width > low + EPS
                low = min(low, width)
            if reverses:
                problems.append("neighbor width reverses")
            # The same interpolation progress must shrink neighbors while the
            # inserted tab grows. Allow one rendered pixel in each cell.
            error = max(abs(width - (neighbor[0] + (neighbor[-1] - neighbor[0]) * inserted / final))
                        for width, inserted in zip(neighbor, widths)) if final > EPS else 0
            if error > 2 * EPS:
                problems.append(f"neighbor shrink is out of phase ({error:.2f} pt)")
    windows = [sample.get("window") for sample in samples if sample.get("window")]
    if windows and any(window != windows[0] for window in windows):
        problems.append("window or pane resized during insertion")
    opening = trace.get("opening")
    if opening is None or bool(opening.get("spare")) != (kind == "warm"):
        problems.append(f"{kind} opening path was not exercised")
    return {"ok": not problems, "problems": list(dict.fromkeys(problems)), "frames": len(rows),
            "intermediate": intermediate, "final_width": final, "maximum_width": max(widths),
            "total_before": totals[0], "total_after": totals[-1],
            "total_range": round(max(totals) - min(totals), 2), "max_seam_error": round(seam, 2)}


def main() -> int:
    if len(sys.argv) in (4, 5) and sys.argv[1] == "drive":
        InsertionDriver(sys.argv[2], Path(sys.argv[3])).run_insertions("--record" in sys.argv[4:])
        return 0
    if len(sys.argv) == 3 and sys.argv[1] == "judge":
        out = Path(sys.argv[2])
        verdicts = {}
        for name in SCENARIOS:
            try:
                trace = json.loads((out / f"{name}.json").read_text())
            except (OSError, ValueError) as error:
                trace = {"error": str(error)}
            _, _, count, kind = name.split("_")
            verdicts[name] = judge_trace(trace, int(count), kind)
            print(f"{name}: {'PASS' if verdicts[name]['ok'] else 'FAIL'} {json.dumps(verdicts[name])}")
        (out / "insertion-verdicts.json").write_text(json.dumps(verdicts, indent=2) + "\n")
        return int(any(not verdict["ok"] for verdict in verdicts.values()))
    print(__doc__)
    return 2


if __name__ == "__main__":
    sys.exit(main())
