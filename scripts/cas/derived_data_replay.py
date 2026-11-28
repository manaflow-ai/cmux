#!/usr/bin/env python3
"""RFD 0166 row B1 by replay: what `cas/1` moves to restore a DerivedData seed on a runner
that already holds the previous one.

Today a macOS job that adopts a DerivedData seed (seed-derived-data.yml, scripts/ci/
seed_derived_data.py) downloads the whole `tar.zst` archive from the public CI cache
(https://ci-cache.cmux.com, `v1/macOS-ARM64/objects/<key>.tar.zst`), whatever it held before.
Under `cas/1` a runner holding seed N-1 fetches only the FastCDC chunks it lacks. This script
replays that over the real seeds main published, with no credentials:

  1. prefix: the seed key prefix to follow (`admission-derived-data-v1-<os>-<arch>-<fingerprint>-j<width>-`).
     --prefix names it; else it is read from the newest successful main run of
     seed-derived-data.yml (its job log names the key it saved).
  2. seeds: main's newest first-parent commits (one commits API call, or --git-dir), each
     checked for `<prefix><sha>.tar.zst` by HEAD on the public cache. Main seeds about one
     commit in ten, so the newest --count hits are consecutive seeds.
  3. stream each archive through `zstd -d | tar -x` into its own tree (the archive never
     lands on disk), oldest first, and run `cas-replay --archive-bytes SIZE... DIR...`.
  4. print the B1 summary (p50 of range_bytes / archive bytes, 1 seed behind) as JSON and,
     under GitHub Actions, a table in the step summary. Trees are removed unless --keep.

Usage:
  derived_data_replay.py --cas-replay BIN [--prefix P] [--count N] [--work DIR] [--git-dir D]
                         [--from-dir DIR] [--keep] [--max-p50 PCT]

--from-dir reads already-unpacked trees (DIR/<n>-<sha>/, oldest first by name) and their
DIR/<n>-<sha>.bytes archive sizes. --max-p50 exits 1 when the 1-behind p50 is above PCT (RFD
0166's target is 20); unset, the script only reports. A seed is up to 12 GiB raw, so each tree
needs that much free disk: a run without it reports a skip, not a failure.
"""
import argparse
import glob
import json
import os
import re
import shutil
import statistics
import subprocess
import sys
import urllib.error
import urllib.request
from concurrent.futures import ThreadPoolExecutor

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from web_ota_replay import WAIT_BUDGET, RateLimited, api, pct  # noqa: E402

PUBLIC = os.environ.get("CI_CACHE_R2_PUBLIC_URL", "https://ci-cache.cmux.com").rstrip("/")
NAMESPACE = "v1/macOS-ARM64"
WORKFLOW = "seed-derived-data.yml"
# The CDN answers urllib's default User-Agent with 403 (seed_derived_data.py USER_AGENT).
USER_AGENT = "cmux-cas-replay-b1"
# seed_derived_data.py MAX_RAW_BYTES: a seed tree is at most this big.
MAX_RAW = 12 * 1024**3
KEY_RE = re.compile(r"admission-derived-data-v1-[A-Za-z0-9._-]+?-j[0-9]+-[0-9a-f]{40}")
SAVED_RE = re.compile(r"r2-cache: saved (" + KEY_RE.pattern + ")")
TARGET = 20
# Seeds are bsdtar archives from macOS: GNU tar warns once per Apple xattr header it skips.
TAR_QUIET = "--warning=no-unknown-keyword" if b"GNU tar" in subprocess.run(
    ["tar", "--version"], capture_output=True).stdout else ""


class Skip(Exception):
    """This run cannot measure B1 (no budget, no disk, no seeds); a gap in a report, not a failure."""


def head(key):
    """The archive's size if the public cache holds KEY.tar.zst, else None."""
    req = urllib.request.Request(f"{PUBLIC}/{NAMESPACE}/objects/{key}.tar.zst", method="HEAD",
                                 headers={"User-Agent": USER_AGENT})
    try:
        with urllib.request.urlopen(req, timeout=20) as r:
            return int(r.headers.get("content-length") or 0) or None if r.status == 200 else None
    except Exception:  # noqa: BLE001 - any failure is a miss for this key
        return None


def prefix_from_key(key):
    return key[:-40]


def saved_key(log):
    """The seed key a seed job's log says r2-cache saved (it also names the N-1 seed it
    adopted, under the same prefix), else the last seed key it names, else None."""
    saved = SAVED_RE.findall(log)
    if saved:
        return saved[-1]
    keys = KEY_RE.findall(log)
    return keys[-1] if keys else None


def discover_prefix(repo, token, budget):
    """The scoped prefix the newest successful main seed run saved under."""
    runs = api(f"repos/{repo}/actions/workflows/{WORKFLOW}/runs?branch=main&status=success&per_page=5",
               token, budget=budget)["workflow_runs"]
    for run in runs:
        for job in api(f"repos/{repo}/actions/runs/{run['id']}/jobs?per_page=50", token, budget=budget)["jobs"]:
            if job.get("conclusion") != "success":
                continue
            log = api(f"repos/{repo}/actions/jobs/{job['id']}/logs", token, raw=True, budget=budget)
            key = saved_key(log.decode("utf-8", "replace"))
            if key:
                return prefix_from_key(key)
    raise Skip("no successful main seed run names a seed key")


def main_commits(repo, token, budget, git_dir, limit):
    if git_dir:
        out = subprocess.run(["git", "-C", git_dir, "rev-list", "--first-parent", f"--max-count={limit}",
                              "origin/main"], check=True, capture_output=True, text=True).stdout
        return out.split()
    shas = []
    for page in range(1, (limit + 99) // 100 + 1):
        got = api(f"repos/{repo}/commits?sha=main&per_page=100&page={page}", token, budget=budget)
        shas += [c["sha"] for c in got]
        if len(got) < 100:
            break
    return shas[:limit]


def find_seeds(prefix, shas, count):
    """The newest COUNT (sha, archive bytes) with a seed under PREFIX, oldest first."""
    with ThreadPoolExecutor(max_workers=16) as pool:
        sizes = list(pool.map(lambda s: head(prefix + s), shas))
    hits = [(s, n) for s, n in zip(shas, sizes) if n]
    return list(reversed(hits[:count]))


def restore(key, tree):
    """Stream KEY's archive into TREE (no archive file on disk); on failure leave nothing."""
    os.makedirs(tree)
    url = f"{PUBLIC}/{NAMESPACE}/objects/{key}.tar.zst"
    cmd = (f"curl --fail --silent --show-error --location --retry 3 -A {USER_AGENT} '{url}'"
           f" | zstd -dc | tar {TAR_QUIET} -xf - -C '{tree}'")
    r = subprocess.run(["bash", "-o", "pipefail", "-c", cmd])
    if r.returncode != 0:
        shutil.rmtree(tree, ignore_errors=True)
        raise SystemExit(f"could not restore {key} (exit {r.returncode})")


def summarize(rows, seeds):
    one = rows[:-1] if len(rows) > 1 else rows
    span = rows[-1] if len(rows) > 2 else None
    p = [r["pct_of_full"] for r in one]
    return {
        "row": "B1", "pairs": len(one), "seeds": [s for s, _ in seeds],
        "full_bytes_p50": statistics.median(r["full"] for r in one),
        "tree_bytes_p50": statistics.median(r["tree"] for r in one),
        "range_bytes_p50": statistics.median(r["range_bytes"] for r in one),
        "want_wire_p50": statistics.median(r["want_wire"] for r in one),
        "pct_p50": round(statistics.median(p), 2), "pct_p90": round(pct(p, 0.9), 2),
        "pct_max": round(max(p), 2),
        "span": None if span is None else {
            "behind": len(rows) - 1, "full": span["full"], "range_bytes": span["range_bytes"],
            "pct": round(span["pct_of_full"], 2)},
        "target_pct_p50": TARGET,
    }


def write_summary(text):
    path = os.environ.get("GITHUB_STEP_SUMMARY")
    if path:
        with open(path, "a") as f:
            f.write(text)


def skip(reason):
    print(f"::warning::B1 replay skipped: {reason}", file=sys.stderr)
    write_summary(f"### RFD 0166 B1: skipped\n\n{reason}\n")
    print(json.dumps({"row": "B1", "skipped": reason}))
    return 0


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--cas-replay", required=True)
    ap.add_argument("--prefix")
    ap.add_argument("--count", type=int, default=3)
    ap.add_argument("--commits", type=int, default=200, help="main commits to search for seeds")
    ap.add_argument("--work", default="cas-replay-b1")
    ap.add_argument("--git-dir")
    ap.add_argument("--from-dir")
    ap.add_argument("--keep", action="store_true")
    ap.add_argument("--max-p50", type=float)
    a = ap.parse_args()
    os.makedirs(a.work, exist_ok=True)
    if not os.access(a.cas_replay, os.X_OK):
        raise SystemExit(f"no cas-replay at {a.cas_replay}: build it first (cargo build -p cmux-cas --bin cas-replay)")
    made = []
    try:
        if a.from_dir:
            trees = sorted(d for d in glob.glob(os.path.join(a.from_dir, "*")) if os.path.isdir(d))
            seeds = []
            for t in trees:
                with open(t.rstrip("/") + ".bytes") as f:
                    seeds.append((os.path.basename(t.rstrip("/")), int(f.read().strip())))
        else:
            repo, token = os.environ.get("GITHUB_REPOSITORY", "manaflow-ai/cmux"), os.environ.get("GH_TOKEN", "")
            budget = [WAIT_BUDGET]
            prefix = a.prefix or discover_prefix(repo, token, budget)
            if not prefix.startswith("admission-derived-data-v1-"):
                raise SystemExit(f"not a seed prefix: {prefix}")
            seeds = find_seeds(prefix, main_commits(repo, token, budget, a.git_dir, a.commits), a.count)
            if len(seeds) < 2:
                raise Skip(f"{len(seeds)} seed(s) under {prefix} in main's newest {a.commits} commits")
            trees = []
            for i, (sha, _) in enumerate(seeds):
                tree = os.path.join(a.work, "trees", f"{i:02d}-{sha[:12]}")
                if not os.path.isdir(tree):
                    free = shutil.disk_usage(a.work).free
                    if free < MAX_RAW + 2 * 1024**3:
                        raise Skip(f"{free / 1024**3:.1f} GiB free under {a.work}; a seed tree needs up to 12 GiB")
                    print(f"B1: restoring {prefix}{sha}", file=sys.stderr)
                    restore(prefix + sha, tree)
                    made.append(tree)
                trees.append(tree)
        if len(trees) < 2:
            raise SystemExit(f"need two seeds to replay, found {len(trees)}")
        cmd = [a.cas_replay]
        for _, size in seeds:
            cmd += ["--archive-bytes", str(size)]
        out = subprocess.run(cmd + trees, check=True, capture_output=True, text=True).stdout
    except (RateLimited, Skip) as e:
        return skip(str(e))
    finally:
        if not a.keep:
            for t in made:
                shutil.rmtree(t, ignore_errors=True)
    rows = [json.loads(line) for line in out.splitlines() if line.strip()]
    with open(os.path.join(a.work, "rows.jsonl"), "w") as f:
        f.write(out)
    s = summarize(rows, seeds)
    print(json.dumps(s))
    gib = 1024**3
    text = ("### RFD 0166 B1: DerivedData seed restore bytes under cas/1 (replay)\n\n"
            "| pairs | seed archive p50 | tree p50 | cas/1 Range GET p50 | % p50 | % p90 | % max | target |\n"
            "| --- | --- | --- | --- | --- | --- | --- | --- |\n"
            f"| {s['pairs']} | {s['full_bytes_p50'] / gib:.2f} GiB | {s['tree_bytes_p50'] / gib:.2f} GiB"
            f" | {s['range_bytes_p50'] / gib:.2f} GiB | {s['pct_p50']} | {s['pct_p90']} | {s['pct_max']}"
            f" | <= {TARGET} at p50 |\n")
    if s["span"]:
        text += (f"\nOldest to newest ({s['span']['behind']} seeds behind): {s['span']['range_bytes'] / gib:.2f} GiB"
                 f" of {s['span']['full'] / gib:.2f} GiB ({s['span']['pct']}%).\n")
    write_summary(text)
    if a.max_p50 is not None and s["pct_p50"] > a.max_p50:
        print(f"B1 p50 {s['pct_p50']}% is above {a.max_p50}%", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
