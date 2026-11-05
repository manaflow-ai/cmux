#!/usr/bin/env python3
"""The report half of scripts/measure/live-code-cost.sh: build seconds and sizes of the two builds, and the
instant-create bench of each compared with scripts/measure/bench-ab/bench_ab.py (A = regular, B = live code;
bootstrap intervals, an A/A check, a verdict per row). Writes OUT/result.json and OUT/REPORT.md, and prints
the report."""
import argparse
import json
import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "bench-ab"))
import bench_ab  # noqa: E402

METRICS = ("visible_ms", "key_ms")
STATS = ("p50", "p95")


def app_sizes(app):
    """{"binary_bytes", "app_bytes"} of an .app: its main executable, and every regular file in the bundle."""
    macos = os.path.join(app, "Contents", "MacOS")
    names = sorted(n for n in os.listdir(macos) if not n.endswith(".dylib")) if os.path.isdir(macos) else []
    binary = os.path.join(macos, "cmux") if "cmux" in names else (os.path.join(macos, names[0]) if names else None)
    total = 0
    for root, _, files in os.walk(app):
        for name in files:
            path = os.path.join(root, name)
            if os.path.isfile(path) and not os.path.islink(path):
                total += os.path.getsize(path)
    return {"binary_bytes": os.path.getsize(binary) if binary else None, "app_bytes": total}


def ratio(a, b):
    return round(b / a, 2) if a and b is not None else None


def fmt(cell):
    value, interval = cell
    if value is None:
        return "-"
    return f"{value:g}" if not interval else f"{value:g} [{interval[0]:g}, {interval[1]:g}]"


def report(result):
    """Markdown: the builds, then one row per (command/phase, metric, statistic) of the bench comparison."""
    b = result["builds"]
    lines = [f"# Live code build cost at {result['sha'][:12]}", "",
             "A = regular bench build, B = live code bench build (scripts/live-code/build.sh), same commit and Mac.", "",
             "| | regular (A) | live code (B) | B / A |", "|---|---|---|---|"]
    for key, label, scale in (("build_s", "build, s", 1), ("binary_bytes", "binary, MB", 1e6), ("app_bytes", "app, MB", 1e6)):
        a, l = b["regular"].get(key), b["live"].get(key)
        show = lambda v: "-" if v is None else f"{v / scale:.1f}" if scale != 1 else str(v)  # noqa: E731
        lines.append(f"| {label} | {show(a)} | {show(l)} | {ratio(a, l) or '-'} |")
    cmp = result["bench"]
    lines += ["", f"Instant-create bench, {cmp['jobs_a']} runs of A and {cmp['jobs_b']} of B, ms "
                  "(95 % bootstrap interval in brackets; verdict from bench_ab.py).", "",
              "| command/phase | metric | stat | A | B | B - A | verdict |", "|---|---|---|---|---|---|---|"]
    for row in cmp["rows"]:
        if row["metric"] not in METRICS:
            continue
        for st in STATS:
            if st not in row["verdict"]:
                continue
            lines.append(f"| {row['key']} | {row['metric']} | {st} | {fmt(row['a'][st])} | {fmt(row['b'][st])} "
                         f"| {fmt(row['delta'][st])} | {row['verdict'][st]} |")
    verdicts = [v for row in cmp["rows"] if row["metric"] in METRICS for st, v in row["verdict"].items() if st in STATS]
    lines += ["", "Verdicts: " + ", ".join(f"{v} {verdicts.count(v)}" for v in sorted(set(verdicts))) if verdicts
              else "Verdicts: none (no bench rows)"]
    return "\n".join(lines) + "\n"


def main(argv=None):
    p = argparse.ArgumentParser()
    p.add_argument("--out", required=True)
    p.add_argument("--sha", required=True)
    p.add_argument("--regular-app", required=True)
    p.add_argument("--regular-build-s", type=int, required=True)
    p.add_argument("--live-app", required=True)
    p.add_argument("--live-build-s", type=int, required=True)
    o = p.parse_args(argv)
    builds = {"regular": {"build_s": o.regular_build_s, **app_sizes(o.regular_app)},
              "live": {"build_s": o.live_build_s, **app_sizes(o.live_app)}}
    result = {"sha": o.sha, "host": os.uname().nodename, "builds": builds,
              "bench": bench_ab.compare("instant", bench_ab.load(o.out, "instant", o.sha, o.sha))}
    text = report(result)
    with open(os.path.join(o.out, "result.json"), "w") as f:
        json.dump(result, f, indent=1)
    with open(os.path.join(o.out, "REPORT.md"), "w") as f:
        f.write(text)
    print("LIVE-CODE-COST\n" + text, flush=True)


if __name__ == "__main__":
    main()
