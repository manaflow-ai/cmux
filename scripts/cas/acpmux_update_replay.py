#!/usr/bin/env python3
"""RFD 0166 row A1 by replay: the bytes a fleet host downloads when acpmux updates, today and under cas/1.

Today `acpmux machine self-update` (cmux-tui/crates/acpmux/src/cli/host_self_update.rs) fetches the
whole binary for its target, uncompressed, from files.cmux.com/cmux-tui/tree/<key>/ (about 75 MB for
x86_64-unknown-linux-musl). This script replays the published builds and prints, per update from
one published build to the next:

  - today: the whole binary;
  - zstd: the same binary at zstd -19 (what serving it compressed would cost);
  - cas/1: what `cas-replay` (cmux-tui/crates/cmux-cas) reads by Range GET for a host holding the
    previous build (FastCDC chunks it lacks, zstd 19, coalesced);
  - patch: `zstd -19 --long=27 --patch-from=<previous build>` (a patch against the installed build).

Discovery: a build is published under its cmux-tui tree key (scripts/ci/cmux_tui_tree_key.py), and
only some commits are published (CI coalesces pushes). The script walks feat-cmux-next's first-parent
commits, newest first, keys each one, and keeps the distinct keys whose binary is on files.cmux.com
(one HEAD request each, no token). The checkout needs that history (fetch-depth).

Usage:
  acpmux_update_replay.py --cas-replay BIN [--count 12] [--walk 600] [--target T] [--work DIR]
                          [--rev origin/feat-cmux-next] [--keys K1,K2,...] [--from-dir DIR]

--keys skips discovery (oldest first). --from-dir reads DIR/<key> instead of the network (a test).
It reports, it does not gate.
"""
import argparse
import json
import os
import shutil
import statistics
import subprocess
import sys
import urllib.error
import urllib.request
from concurrent.futures import ThreadPoolExecutor

FILES = "https://files.cmux.com/cmux-tui/tree"
# The CDN answers urllib's default User-Agent with 403 (as mac_update_replay.py and derived_data_replay.py note).
USER_AGENT = "cmux-cas-replay-a1"
ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
TREE_KEY = os.path.join(ROOT, "scripts/ci/cmux_tui_tree_key.py")


def binary_url(key, target):
    return f"{FILES}/{key}/cmux-tui-acpmux-{target}"


def head_ok(url):
    req = urllib.request.Request(url, method="HEAD", headers={"User-Agent": USER_AGENT})
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            return r.status == 200
    except (urllib.error.HTTPError, urllib.error.URLError, TimeoutError):
        return False


def tree_key(commit):
    out = subprocess.run([sys.executable, TREE_KEY, commit], capture_output=True, text=True)
    return out.stdout.strip() if out.returncode == 0 else None


def discover(rev, walk, count, target, jobs=16):
    """The newest `count` published keys, oldest first."""
    commits = subprocess.run(["git", "-C", ROOT, "rev-list", "--first-parent", "-n", str(walk), rev],
                             check=True, capture_output=True, text=True).stdout.split()
    with ThreadPoolExecutor(jobs) as pool:
        keys = list(pool.map(tree_key, commits))
    distinct = []
    for k in keys:
        if k and k not in distinct:
            distinct.append(k)
    found = []
    with ThreadPoolExecutor(jobs) as pool:
        for k, ok in zip(distinct, pool.map(lambda k: head_ok(binary_url(k, target)), distinct)):
            if ok:
                found.append(k)
            if len(found) >= count:
                break
    return list(reversed(found))


def fetch(key, target, work, from_dir):
    d = os.path.join(work, "trees", key)
    path = os.path.join(d, "acpmux")
    if os.path.isfile(path):
        return d
    os.makedirs(d, exist_ok=True)
    if from_dir:
        shutil.copyfile(os.path.join(from_dir, key), path)
        return d
    tmp = path + ".part"
    with urllib.request.urlopen(urllib.request.Request(binary_url(key, target), headers={"User-Agent": USER_AGENT}),
                                timeout=600) as r, open(tmp, "wb") as f:
        shutil.copyfileobj(r, f, 1 << 20)
    os.replace(tmp, path)
    return d


def zstd_bytes(path, patch_from=None):
    cmd = ["zstd", "-19", "-T0", "-q", "-c"]
    if patch_from:
        cmd += ["--long=27", f"--patch-from={patch_from}"]
    out = subprocess.run(cmd + [path], check=True, capture_output=True)
    return len(out.stdout)


def replay(cas_replay, dirs):
    out = subprocess.run([cas_replay] + dirs, check=True, capture_output=True, text=True).stdout
    return [json.loads(line) for line in out.splitlines() if line.strip()]


def pct(part, whole):
    return round(part * 100.0 / whole, 1) if whole else None


def summarize(keys, sizes, zstd, patch, rows):
    """keys oldest first; rows are cas-replay's consecutive pairs, then oldest -> newest."""
    pairs = []
    for i in range(1, len(keys)):
        r = rows[i - 1]
        pairs.append({
            "from": keys[i - 1], "to": keys[i], "today": sizes[i], "zstd": zstd[i],
            "cas_range_bytes": r["range_bytes"], "cas_want_raw": r["want_raw"], "patch": patch[i],
        })

    def stat(field):
        v = sorted(p[field] for p in pairs)
        if not v:
            return None
        p50 = statistics.median(v)
        today = statistics.median(sorted(p["today"] for p in pairs))
        return {"p50": p50, "p90": v[min(len(v) - 1, int(0.9 * len(v)))], "max": v[-1], "p50_pct": pct(p50, today)}

    span = rows[-1] if len(keys) > 2 else None
    return {
        "row": "A1",
        "builds": len(keys),
        "newest": keys[-1],
        "today": stat("today"),
        "zstd": stat("zstd"),
        "cas": stat("cas_range_bytes"),
        "cas_raw_changed": stat("cas_want_raw"),
        "patch": stat("patch"),
        "oldest_to_newest_cas": span and {"from": keys[0], "range_bytes": span["range_bytes"], "full": sizes[-1]},
        "pairs": pairs,
    }


def step_summary(s):
    path = os.environ.get("GITHUB_STEP_SUMMARY")
    if not path or not s["pairs"]:
        return
    mb = lambda b: f"{b / 1e6:.1f} MB"  # noqa: E731
    with open(path, "a") as f:
        f.write(f"### RFD 0166 A1: acpmux update bytes, {len(s['pairs'])} consecutive published builds (replay)\n\n"
                "| path | p50 | p90 | max | p50 of today |\n| --- | --- | --- | --- | --- |\n")
        for key, label in (("today", "today: whole binary"), ("zstd", "whole binary, zstd -19"),
                           ("cas", "cas/1 Range GETs"), ("patch", "zstd --patch-from the installed build")):
            c = s[key]
            f.write(f"| {label} | {mb(c['p50'])} | {mb(c['p90'])} | {mb(c['max'])} | {c['p50_pct']}% |\n")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--cas-replay", required=True)
    ap.add_argument("--count", type=int, default=12)
    ap.add_argument("--walk", type=int, default=600)
    ap.add_argument("--target", default="x86_64-unknown-linux-musl")
    ap.add_argument("--rev", default="origin/feat-cmux-next")
    ap.add_argument("--work", default="cas-replay-a1")
    ap.add_argument("--keys")
    ap.add_argument("--from-dir")
    a = ap.parse_args()

    keys = a.keys.split(",") if a.keys else discover(a.rev, a.walk, a.count, a.target)
    if len(keys) < 2:
        raise SystemExit(f"A1 needs two published builds; found {len(keys)} in {a.walk} commits of {a.rev}"
                         f" (none answering 200 on {FILES} usually means the CDN refused the request: 403)")
    os.makedirs(a.work, exist_ok=True)
    dirs = [fetch(k, a.target, a.work, a.from_dir) for k in keys]
    bins = [os.path.join(d, "acpmux") for d in dirs]
    sizes = [os.path.getsize(b) for b in bins]
    zstd = [zstd_bytes(b) for b in bins]
    patch = [None] + [zstd_bytes(bins[i], bins[i - 1]) for i in range(1, len(bins))]
    rows = replay(a.cas_replay, dirs)
    with open(os.path.join(a.work, "rows.jsonl"), "w") as f:
        for r in rows:
            f.write(json.dumps(r) + "\n")
    s = summarize(keys, sizes, zstd, patch, rows)
    json.dump(s, sys.stdout, indent=1)
    print()
    step_summary(s)


if __name__ == "__main__":
    main()
