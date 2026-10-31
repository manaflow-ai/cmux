#!/usr/bin/env python3
"""Write one tip's A/B table (Markdown) from the drivers' artifacts (fast benches, cmux-ad 2026-10-31).

  publish.py --tip SHA --base SHA --plans DIR --out FILE [--repo GIT_DIR] [--note TEXT] BENCH...

DIR is the drivers' folder: <bench>.state.jsonl files and artifacts/. For each BENCH: bench_ab.compare, then one
table row per (key, metric): A and B with 95 % bootstrap intervals, B - A and A/A, and the verdicts. A sample row shows
p50/p95/p99/max; a replicate row shows only the median of its jobs' values. Each REGRESSION gets a line
"BENCH REGRESSION <bench>/<key>/<metric> <stat> <tip>: +<delta> beyond [lo, hi], range <base>..<tip>", and the section
ends with the commit range (git log --oneline --first-parent base..tip in --repo). Only this tip's section of FILE is
rewritten (between its markers). The script prints the regressions as JSON on stdout.
"""
import argparse, glob, json, os, re, subprocess, sys, time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import bench_ab  # noqa: E402

# Replicate rows shown in the table: the headline numbers. Every metric stays in bench_ab.py's JSON.
HEAD_METRICS = {"commit_ms.p95", "turn_ms.p95", "key_to_frame_ms.p95", "missed_frames", "frames.missed",
                "frames.max_ms", "frames.p95_ms", "frames.p99_ms", "frames.main_max_ms", "key_to_frame.p95",
                "key_to_frame.p99", "ghostty_frames"}
ENDED = ("done", "failed", "cancelled", "timeout", "error")
HEADER = ("# Fast benches by feat tip\n\nOne section per measured tip: an interleaved A/B against the previous measured "
          "tip on the same mini, an A/A self-test and bootstrap intervals (scripts/measure/bench-ab).\n\n")


def fmt(v):
    if not v or v[0] is None:
        return "-"
    val, ci = v
    return f"{val:g} [{ci[0]:g}, {ci[1]:g}]" if ci else f"{val:g}"


def jobs(plans, bench, base="", tip=""):
    """This tip's ended jobs of BENCH: keys that name the base or the tip commit (earlier tips' jobs stay out)."""
    shas = tuple(x[:8] for x in (base, tip) if x)
    out = []
    for path in sorted(glob.glob(os.path.join(plans, "**", f"{bench}.state*.jsonl"), recursive=True)):
        with open(path) as f:
            lines_of = f.read().splitlines()
        for line in lines_of:
            try:
                r = json.loads(line)
            except ValueError:
                continue
            if r.get("job") and r.get("result") in ENDED and (not shas or any(x in r["key"] for x in shas)):
                out.append(f"{r['key'].replace('bench-', '')} {r['job'][:8]} {r['result']}")
    return out


def section(tip, base, plans, benches, note="", rng_text=""):
    """The Markdown section of one tip and its regressions [(bench, row, stat)]."""
    lines = [f"<!-- tip {tip} -->", f"## Tip {tip[:11]} against base {base[:11]}", "",
             f"Updated {time.strftime('%H:%MZ', time.gmtime())}. {note}".rstrip(), "",
             f"- A (before) = {base}, B (after) = {tip}. One mini per bench, the two commits interleaved.",
             "- Intervals: 95 %, two-level bootstrap (jobs, then samples in each job). REGRESSION = the B - A interval is "
             f"above max({bench_ab.FLOOR_ABS:g}, {bench_ab.FLOOR_REL:.0%} of A) and the A/A interval (A jobs 1, 3, ... "
             "against 2, 4, ...) contains 0; NOISY = the A/A interval does not contain 0. p95 needs "
             f"{bench_ab.MIN_SAMPLES['p95']} and p99 {bench_ab.MIN_SAMPLES['p99']} samples per arm for a verdict; max "
             "has none. missed = presses with no result, per arm.",
             "- unit sample: all raw samples (p50/p95/p99/max). unit replicate: one value per job (an every-action row "
             "keeps only its own p95); the row is the median of the jobs, and its verdict needs "
             f"{bench_ab.MIN_JOBS}+ jobs per arm.", ""]
    regressions = []
    for bench in benches:
        res = bench_ab.compare(bench, bench_ab.load(os.path.join(plans, "artifacts"), bench, base, tip))
        lines += [f"### {bench}", "", f"Jobs: {'; '.join(jobs(plans, bench, base, tip)) or 'none ended'}. "
                  f"Artifacts: A {res['jobs_a']}, B {res['jobs_b']}.", ""]
        rows = [r for r in res["rows"] if r["unit"] == "sample" or r["metric"] in HEAD_METRICS]
        if not rows:
            lines += ["No comparable rows yet.", ""]
            continue
        lines += ["| key | metric | unit | jobs A/B | A p50 | A p95 | A p99 | A max | B p50 | B p95 | B p99 | B max | "
                  "B-A (p95; replicate: p50) | A/A (same) | verdict |",
                  "|" + "---|" * 15]
        for r in rows:
            st = "p95" if r["unit"] == "sample" else "p50"
            v = r["verdict"]
            mark = "**" if "REGRESSION" in v.values() else ""
            cells = [fmt(r["a"].get(s)) for s in ("p50", "p95", "p99", "max")]
            cells += [fmt(r["b"].get(s)) for s in ("p50", "p95", "p99", "max")]
            miss = f" (missed {r['missed']['before']}/{r['missed']['after']})" if r.get("missed") else ""
            lines.append(f"| {mark}{r['key']}{mark}{miss} | {r['metric']} | {r['unit']} | {r['jobs_a']}/{r['jobs_b']} | "
                         + " | ".join(cells) + f" | {fmt(r['delta'][st])} | {fmt(r['aa'][st])} | "
                         + "/".join(f"{k} {x}" for k, x in v.items()) + " |")
            regressions += [(bench, r, s) for s, x in v.items() if x == "REGRESSION"]
        lines.append("")
    lines += ["### Regressions", ""]
    if regressions:
        for bench, r, s in regressions:
            d = r["delta"][s]
            lines.append(f"- BENCH REGRESSION {bench}/{r['key']}/{r['metric']} {s} {tip[:11]}: +{d[0]:g} beyond "
                         f"[{d[1][0]:g}, {d[1][1]:g}], range {base[:11]}..{tip[:11]}")
        lines += ["", f"Commit range (git log --oneline --first-parent {base[:11]}..{tip[:11]}):", "", "```",
                  rng_text, "```", ""]
    else:
        lines += ["None beyond the interval with a clean A/A in this run.", ""]
    lines.append(f"<!-- end tip {tip} -->")
    return "\n".join(lines) + "\n", regressions


def replace_section(text, tip, new):
    pat = re.compile(rf"<!-- tip {re.escape(tip)} -->.*?<!-- end tip {re.escape(tip)} -->\n", re.S)
    if pat.search(text):
        return pat.sub(lambda _: new, text)
    return (text or HEADER) + new


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--tip", required=True)
    ap.add_argument("--base", required=True)
    ap.add_argument("--plans", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--repo", default=".")
    ap.add_argument("--note", default="")
    ap.add_argument("benches", nargs="+")
    a = ap.parse_args()
    rng = subprocess.run(["git", "-C", a.repo, "log", "--oneline", "--first-parent", f"{a.base}..{a.tip}"],
                         capture_output=True, text=True).stdout.strip()
    new, regressions = section(a.tip, a.base, a.plans, a.benches, a.note, rng)
    text = ""
    if os.path.exists(a.out):
        with open(a.out) as f:
            text = f.read()
    with open(a.out, "w") as f:
        f.write(replace_section(text, a.tip, new))
    print(json.dumps([[b, r["key"], r["metric"], s] for b, r, s in regressions]))


if __name__ == "__main__":
    main()
