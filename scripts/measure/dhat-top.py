#!/usr/bin/env python3
"""The allocation sites holding the most bytes at a dhat profile's global peak (t-gmax), with the first
acpmux/cmux frames of each: `dhat-top.py PROFILE.json [N]`. Measurement only (CMUX-571 infinite items)."""

import json
import sys


def main():
    path = sys.argv[1]
    top = int(sys.argv[2]) if len(sys.argv) > 2 else 25
    with open(path) as f:
        prof = json.load(f)
    frames = prof["ftbl"]
    pps = prof["pps"]
    total = sum(pp.get("gb", 0) for pp in pps)
    end = sum(pp.get("eb", 0) for pp in pps)
    print(f"DHAT {path} gmax_bytes={total} end_bytes={end} sites={len(pps)}")
    groups = {}
    for pp in pps:
        own = [frames[i] for i in pp["fs"] if any(k in frames[i] for k in ("acpmux", "cmux", "hub::"))]
        key = " <- ".join(f.split(" (")[0].split(": ", 1)[-1] for f in own[:3]) or frames[pp["fs"][-1]][:120]
        g = groups.setdefault(key, [0, 0, 0])
        g[0] += pp.get("gb", 0)
        g[1] += pp.get("gbk", 0)
        g[2] += pp.get("eb", 0)
    for key, (b, blocks, e) in sorted(groups.items(), key=lambda kv: -kv[1][2])[:top]:
        print(f"DHAT-SITE end {e / 1048576:9.3f} MB gmax {b / 1048576:9.3f} MB {blocks:8d} blocks  {key[:400]}")


if __name__ == "__main__":
    main()
