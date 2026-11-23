#!/usr/bin/env python3
"""session-pack on real session logs: size against raw, gzip and zstd; time to read the last 50
turns, one range and one tool result; and what a move ships to a machine holding an older copy.

  scripts/measure/session-pack.py --bin cmux-tui/target/release/session-pack LOG_DIR_OR_FILE...

A LOG is an acpmux chat's events/ folder (its NNNNNN.ndjson files back to back) or one JSONL file.
Prints one JSON line per log and a markdown table. Reads only; its stores are temporary folders.
Goal (the RFD "Session pack" in cmuxterm-hq): >= 10x smaller than raw, any range < 100 ms, a move
to a machine with an older copy < 5% of the log's bytes.
"""
import argparse, gzip, json, os, shutil, statistics, subprocess, sys, tempfile, time


def run(cmd, **kw):
    return subprocess.run(cmd, check=True, stdout=subprocess.PIPE, **kw).stdout


def timed(cmd, drop=None, reps=7):
    """Median wall ms of cmd over reps; with drop, that folder's files leave the page cache first."""
    out = []
    for _ in range(reps):
        if drop:
            evict(drop)
        t = time.perf_counter()
        subprocess.run(cmd, check=True, stdout=subprocess.DEVNULL)
        out.append((time.perf_counter() - t) * 1000)
    return round(statistics.median(out), 1)


def evict(folder):
    for root, _, names in os.walk(folder):
        for n in names:
            fd = os.open(os.path.join(root, n), os.O_RDONLY)
            try:
                os.fsync(fd)
                os.posix_fadvise(fd, 0, 0, os.POSIX_FADV_DONTNEED)
            finally:
                os.close(fd)


def files_of(log):
    if os.path.isdir(log):
        return sorted(os.path.join(log, n) for n in os.listdir(log) if n.endswith((".ndjson", ".jsonl")))
    return [log]


def measure(binary, log, work, older):
    files = files_of(log)
    raw_path = os.path.join(work, "raw")
    with open(raw_path, "wb") as out:
        for f in files:
            with open(f, "rb") as src:
                shutil.copyfileobj(src, out)
    raw = open(raw_path, "rb").read()
    r = {"log": log, "raw": len(raw), "lines": raw.count(b"\n")}
    r["gzip9"] = len(gzip.compress(raw, 9))
    zst = os.path.join(work, "raw.zst")
    run(["zstd", "-19", "-T0", "-q", "-f", raw_path, "-o", zst])
    r["zstd19"] = os.path.getsize(zst)

    store = os.path.join(work, "here")
    sp = [binary, "--store", store]
    t = time.perf_counter()
    stat = json.loads(run(sp + ["pack", "s", raw_path]))
    r["pack_s"] = round(time.perf_counter() - t, 2)
    r["pack"] = stat["storedBytes"] + stat["manifestBytes"]
    r["segments"] = stat["segments"]
    run(sp + ["verify", "s"])
    assert run(sp + ["cat", "s"]) == raw, "the pack does not read back byte for byte"

    # Reads. Baselines: what today's stores must do to reach the same lines.
    turns = run(sp + ["turns", "s"]).decode().split()
    r["turns"] = len(turns)
    lines = r["lines"]
    mid = f"s@{lines // 2}-{lines // 2 + 199}"
    early = "s@100-299"
    seqs = [json.loads(l)["seq"] for l in raw.split(b"\n")[lines // 3 : lines // 3 + 4000]
            if b'"kind":"tool_call_update"' in l[:120] and len(l) > 4000][:1]
    r["tail50_ms"] = timed(sp + ["tail", "s", "--turns", "50"])
    r["tail50_cold_ms"] = timed(sp + ["tail", "s", "--turns", "50"], drop=store)
    r["tail50_bytes"] = len(run(sp + ["tail", "s", "--turns", "50"]))
    r["tail5_ms"] = timed(sp + ["tail", "s", "--turns", "5"])
    r["range_mid_ms"] = timed(sp + ["range", mid])
    r["range_mid_cold_ms"] = timed(sp + ["range", mid], drop=store)
    r["range_early_ms"] = timed(sp + ["range", early])
    if turns:
        r["turn_ms"] = timed(sp + ["range", turns[len(turns) // 2]])
    if seqs:
        r["tool_result_ms"] = timed(sp + ["seq", "s", str(seqs[0])])
        r["tool_result_cold_ms"] = timed(sp + ["seq", "s", str(seqs[0])], drop=store)
    r["base_zstd_all_ms"] = timed(["zstd", "-d", "-q", "-c", zst], reps=3)
    r["base_read_all_ms"] = timed(["wc", "-l", raw_path], reps=3)
    t = time.perf_counter()
    for line in raw.split(b"\n"):
        if line:
            json.loads(line)
    r["base_parse_all_ms"] = round((time.perf_counter() - t) * 1000, 1)

    # A move to a machine that holds an older copy: the log as it was at `older` of its lines.
    cut = 0
    for _ in range(int(lines * older)):
        cut = raw.index(b"\n", cut) + 1
    old_path = os.path.join(work, "old")
    open(old_path, "wb").write(raw[:cut])
    there = os.path.join(work, "there")
    tp = [binary, "--store", there]
    run(tp + ["pack", "s", old_path])
    have = os.path.join(work, "have")
    open(have, "wb").write(run(tp + ["have"]))
    bundle = os.path.join(work, "bundle")
    t = time.perf_counter()
    ship = json.loads(run(sp + ["bundle", "s", "--have", have, "-o", bundle]))
    run(tp + ["unbundle", bundle])
    r["move_ms"] = round((time.perf_counter() - t) * 1000, 1)
    assert run(tp + ["cat", "s"]) == raw, "the moved session does not read back byte for byte"
    r["older_copy"] = older
    r["move_bytes"] = ship["bytes"]
    r["move_pct_of_raw"] = round(100 * ship["bytes"] / len(raw), 2)
    r["move_pct_of_pack"] = round(100 * ship["bytes"] / r["pack"], 1)
    r["new_raw_pct"] = round(100 * (len(raw) - cut) / len(raw), 1)
    # Then the log grows by 1% and moves again.
    return r


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--bin", required=True)
    ap.add_argument("--older", type=float, default=0.9, help="the other side's copy, as a share of the log's lines")
    ap.add_argument("logs", nargs="+")
    a = ap.parse_args()
    rows = []
    for log in a.logs:
        with tempfile.TemporaryDirectory(prefix="session-pack-measure.") as work:
            r = measure(os.path.abspath(a.bin), log, work, a.older)
        print(json.dumps(r), flush=True)
        rows.append(r)
    x = lambda r, k: f"{r['raw'] / r[k]:.1f}x"
    print("\n| log | raw MB | gzip -9 | zstd -19 (whole file) | pack | tail 50 turns ms (cold) | range ms (cold) | tool result ms (cold) | whole-file zstd read ms | move, other side at %d%% |" % (a.older * 100))
    print("|---|---|---|---|---|---|---|---|---|---|")
    for r in rows:
        name = os.path.basename(os.path.dirname(r["log"]) if r["log"].rstrip("/").endswith("events") else r["log"])[:13]
        print(f"| {name} | {r['raw'] / 1e6:.1f} | {x(r, 'gzip9')} | {x(r, 'zstd19')} | {x(r, 'pack')} | "
              f"{r['tail50_ms']} ({r['tail50_cold_ms']}) | {r['range_mid_ms']} ({r['range_mid_cold_ms']}) | "
              f"{r.get('tool_result_ms', '-')} ({r.get('tool_result_cold_ms', '-')}) | {r['base_zstd_all_ms']} | "
              f"{r['move_pct_of_raw']}% of raw |")
    tot = lambda k: sum(r[k] for r in rows)
    print(f"| all | {tot('raw') / 1e6:.1f} | {tot('raw') / tot('gzip9'):.1f}x | {tot('raw') / tot('zstd19'):.1f}x | "
          f"{tot('raw') / tot('pack'):.1f}x | | | | | {100 * tot('move_bytes') / tot('raw'):.2f}% of raw |")


if __name__ == "__main__":
    sys.exit(main())
