#!/usr/bin/env python3
"""SHORTCUT FRAMES floor: refreshes from each HID key-down to the first frame that shows it, in a plain AppKit app.

  floor.py RESULT.json [--hz 120]

RESULT.json is a journey result with a `key_floor` step (scripts/journeys/ext_keyfloor.py). For each key the probe
logged (NSEvent.timestamp, host clock), the first complete frame after it whose region checksum (layer or text)
differs from the newest complete frame at or before the key is its first frame; refreshes are counted on the vsync
grid of the frame display times, as judge.py does (1 = the next refresh). Prints p50/p95/max per kind.
"""
import argparse
import json
import math
import sys


def pct(v, q):
    v = sorted(v)
    return v[min(len(v) - 1, max(0, math.ceil(q * len(v)) - 1))] if v else None


def main():
    p = argparse.ArgumentParser()
    p.add_argument("result")
    p.add_argument("--hz", type=float, default=120.0)
    a = p.parse_args()
    steps = json.load(open(a.result))["steps"]
    data = next(s["result"] for s in steps if s.get("do") == "key_floor" and s.get("result"))
    frames = [f for f in data["frames"] if f[1] == "complete" and len(f) >= 4]
    period = 1.0 / a.hz
    angles = [(f[0] % period) / period * 2 * math.pi for f in data["frames"]]
    phase = (math.atan2(sum(map(math.sin, angles)), sum(map(math.cos, angles))) % (2 * math.pi)) / (2 * math.pi) * period

    def refreshes(k, t):
        return math.floor((t - phase) / period + 0.5) - math.floor((k - phase) / period)

    out = {}
    for t_key, kind, _ch in data["keys"]:
        region = 3 if kind == "text" else 2
        before = [f for f in frames if f[0] <= t_key]
        if not before:
            continue
        ref = before[-1][region]
        after = next((f for f in frames if f[0] > t_key and f[region] != ref), None)
        out.setdefault(kind, []).append(refreshes(t_key, after[0]) if after else None)
    report = {"frames": len(data["frames"]), "complete": len(frames), "max_fps": data.get("max_fps"), "kinds": {}}
    for kind, values in out.items():
        n = [v for v in values if v is not None]
        report["kinds"][kind] = {"presses": len(values), "missing": len(values) - len(n), "p50": pct(n, 0.5),
                                 "p95": pct(n, 0.95), "max": max(n) if n else None, "all": values}
    print(json.dumps(report, indent=1))


if __name__ == "__main__":
    sys.exit(main())
