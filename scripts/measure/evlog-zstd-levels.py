#!/usr/bin/env python3
"""Measure: zstd speed and ratio per level on acpmux event logs, in 4 MiB pages as a session move sends them.

This is the curve behind `cmux_bytes::serial::EVENT_LOG`. Session move's history pager (`acpmux` `cli/run/transfer_live.rs`)
picks each page's level from that curve and from the link and compressor it has measured so far. Rerun this on a
machine with real chats, and paste the rows into `EVENT_LOG` when they move.

    python3 -I scripts/measure/evlog-zstd-levels.py [--root ~/.acpmux/sessions] [--logs 40] [--json]

Needs the `zstandard` module (zstd 1.5, the same library acpmux links). One core, wall time per level over every page.
"""
import argparse, glob, json, os, sys, time

try:
    import zstandard
except ImportError:
    sys.exit("evlog-zstd-levels: needs `pip install zstandard`")

PAGE = 4 << 20
LEVELS = [1, 3, 5, 7, 9, 12, 15, 19]


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--root", default=os.path.expanduser("~/.acpmux/sessions"))
    ap.add_argument("--logs", type=int, default=40, help="the largest N logs")
    ap.add_argument("--json", action="store_true")
    a = ap.parse_args()
    files = sorted(glob.glob(os.path.join(a.root, "*/events/*.ndjson")), key=os.path.getsize, reverse=True)[: a.logs]
    if not files:
        sys.exit(f"evlog-zstd-levels: no event logs under {a.root}")
    pages = []
    for f in files:
        with open(f, "rb") as fh:
            b = fh.read()
        pages += [b[i : i + PAGE] for i in range(0, len(b), PAGE)]
    raw = sum(map(len, pages))
    rows = []
    for lvl in LEVELS:
        c = zstandard.ZstdCompressor(level=lvl)
        t = time.perf_counter()
        out = sum(len(c.compress(p)) for p in pages)
        s = time.perf_counter() - t
        rows.append({"level": lvl, "ratio": round(out / raw, 4), "mb_per_s": round(raw / s / 1e6, 1)})
    if a.json:
        print(json.dumps({"logs": len(files), "pages": len(pages), "raw_bytes": raw, "rows": rows}))
        return 0
    print(f"{len(files)} logs, {len(pages)} pages, {raw / 1e6:.1f} MB")
    for r in rows:
        print(f"  ({r['level']}, {r['mb_per_s']} * MB, {r['ratio']}),")
    return 0


if __name__ == "__main__":
    sys.exit(main())
