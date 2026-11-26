#!/usr/bin/env python3
"""RFD 0166 row W1 by replay: what `cas/1` moves for an in-app web update, per merge.

Today every web update downloads the whole web bundle archive (about 17 MB). Under `cas/1` a
client holding the previous bundle tree fetches only the FastCDC chunks it lacks. This script
replays that over the real feat-cmux-next publishes, with no network beyond fetching them:

  1. fetch: the newest N `cmux-next-web-bundles` artifacts from feat-cmux-next runs of
     cmux-next-web-bundle-publish.yml (archive plus manifest.json; kept 3 days), named by one
     artifacts list call, then one download each.
  2. unpack each archive with scripts/cmux-next/web-bundle-archive.py unpack.
  3. run `cas-replay --archive-bytes SIZE... DIR...` (cmux-tui/crates/cmux-cas), oldest first:
     one JSON row per consecutive pair (1 merge behind) and one for oldest to newest.
  4. print the W1 summary (p50 and p90 of range_bytes / archive bytes, 1 behind) as JSON and,
     under GitHub Actions, a table in the step summary.

Usage:
  web_ota_replay.py --cas-replay BIN [--count N] [--work DIR] [--from-dir DIR] [--max-p50 PCT]

--from-dir reads already-fetched runs (DIR/<run>/web-bundles-*.tar.gz, as `fetch` leaves them)
instead of the API. --max-p50 exits 1 when the 1-behind p50 is above PCT (RFD 0166's target is
10); unset, the script only reports. Needs GH_TOKEN (actions: read) and GITHUB_REPOSITORY to fetch.
"""
import argparse
import glob
import json
import os
import statistics
import subprocess
import sys
import time
import urllib.error
import urllib.request
import zipfile

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
ARTIFACT = "cmux-next-web-bundles"
# Seconds a run waits in total for the API budget to reset before it skips the report.
WAIT_BUDGET = 180


class RateLimited(Exception):
    """The token's API budget is spent past what this report waits for."""


def api(path, token, raw=False, budget=None):
    """GET one GitHub API path. The token goes only to GitHub, never to the blob storage an
    artifact download redirects to (it rejects a Bearer header with 401). A rate-limit 403/429
    waits for its reset while `budget` (seconds of total waiting, shared across calls) lasts,
    then raises RateLimited; any other HTTP error exits with GitHub's message."""
    budget = budget if budget is not None else [WAIT_BUDGET]
    url = path if "://" in path else f"https://api.github.com/{path}"
    req = urllib.request.Request(url, headers={
        "Accept": "application/vnd.github+json",
        "X-GitHub-Api-Version": "2022-11-28",
    })
    req.add_unredirected_header("Authorization", f"Bearer {token}")
    for _ in range(8):
        try:
            with urllib.request.urlopen(req, timeout=120) as r:
                body = r.read()
            return body if raw else json.loads(body)
        except urllib.error.HTTPError as e:
            msg = e.read()[:500].decode("utf-8", "replace")
            h = e.headers
            limited = e.code == 429 or (e.code == 403 and (
                h.get("retry-after") or h.get("x-ratelimit-remaining") == "0" or "rate limit" in msg))
            if not limited:
                raise SystemExit(f"GET {url}: HTTP {e.code}: {msg}")
            wait = int(h.get("retry-after") or 0) or max(5, int(h.get("x-ratelimit-reset") or 0) - int(time.time()))
            if wait > budget[0]:
                raise RateLimited(f"GET {url}: rate limited (HTTP {e.code}), reset in {wait}s: {msg[:200]}")
            budget[0] -= wait
            print(f"GET {url}: rate limited (HTTP {e.code}), retrying in {wait}s", file=sys.stderr)
            time.sleep(wait)
    raise RateLimited(f"GET {url}: still rate limited after 8 tries")


def fetch(repo, token, count, work):
    """Download the newest `count` feat-cmux-next bundle artifacts; return their run dirs, oldest
    first. One list call names them all (a run whose key was already published uploads none)."""
    budget = [WAIT_BUDGET]
    arts = api(f"repos/{repo}/actions/artifacts?name={ARTIFACT}&per_page=100", token, budget=budget)["artifacts"]
    arts = [a for a in arts if not a["expired"] and (a.get("workflow_run") or {}).get("head_branch") == "feat-cmux-next"]
    arts.sort(key=lambda a: a["created_at"], reverse=True)
    got = []
    for art in arts[:count]:
        d = os.path.join(work, "runs", f"{art['created_at']}-{art['workflow_run']['id']}")
        if not glob.glob(os.path.join(d, "web-bundles-*.tar.gz")):
            os.makedirs(d, exist_ok=True)
            z = os.path.join(d, "a.zip")
            with open(z, "wb") as f:
                f.write(api(art["archive_download_url"], token, raw=True, budget=budget))
            with zipfile.ZipFile(z) as zf:
                zf.extractall(d)
            os.remove(z)
        got.append(d)
    return sorted(got)


def unpack(run_dirs, work):
    trees, sizes = [], []
    for d in run_dirs:
        archives = glob.glob(os.path.join(d, "web-bundles-*.tar.gz"))
        if len(archives) != 1:
            raise SystemExit(f"{d}: want one web-bundles-*.tar.gz, found {len(archives)}")
        tree = os.path.join(work, "trees", os.path.basename(d.rstrip("/")))
        if not os.path.isdir(tree):
            subprocess.run([sys.executable, os.path.join(ROOT, "scripts/cmux-next/web-bundle-archive.py"),
                            "unpack", archives[0], tree], check=True)
        trees.append(tree)
        sizes.append(os.path.getsize(archives[0]))
    return trees, sizes


def pct(values, q):
    s = sorted(values)
    return s[min(len(s) - 1, int(round(q * (len(s) - 1))))]


def summarize(rows):
    one = rows[:-1] if len(rows) > 1 else rows
    span = rows[-1] if len(rows) > 1 else None
    p = [r["pct_of_full"] for r in one]
    return {
        "row": "W1", "pairs": len(one),
        "full_bytes_p50": statistics.median(r["full"] for r in one),
        "range_bytes_p50": statistics.median(r["range_bytes"] for r in one),
        "pct_p50": round(statistics.median(p), 2), "pct_p90": round(pct(p, 0.9), 2),
        "pct_max": round(max(p), 2),
        "span": None if span is None else {
            "behind": len(rows) - 1, "full": span["full"], "range_bytes": span["range_bytes"],
            "pct": round(span["pct_of_full"], 2)},
        "target_pct_p50": 10,
    }


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--cas-replay", required=True)
    ap.add_argument("--count", type=int, default=30)
    ap.add_argument("--work", default="cas-replay-w1")
    ap.add_argument("--from-dir")
    ap.add_argument("--max-p50", type=float)
    a = ap.parse_args()
    os.makedirs(a.work, exist_ok=True)
    if a.from_dir:
        run_dirs = sorted(d for d in glob.glob(os.path.join(a.from_dir, "*")) if os.path.isdir(d))
    else:
        try:
            run_dirs = fetch(os.environ["GITHUB_REPOSITORY"], os.environ["GH_TOKEN"], a.count, a.work)
        except RateLimited as e:
            # The repo's GITHUB_TOKEN budget (1000/h, shared by every job) is spent: this run has
            # no row, which is a gap in a report, not a failure of the code under test.
            print(f"::warning::W1 replay skipped: {e}", file=sys.stderr)
            summary = os.environ.get("GITHUB_STEP_SUMMARY")
            if summary:
                with open(summary, "a") as f:
                    f.write(f"### RFD 0166 W1: skipped\n\nThe API budget is spent: {e}\n")
            print(json.dumps({"row": "W1", "skipped": str(e)}))
            return 0
    if len(run_dirs) < 2:
        raise SystemExit(f"need two bundle publishes to replay, found {len(run_dirs)}")
    trees, sizes = unpack(run_dirs, a.work)
    cmd = [a.cas_replay]
    for s in sizes:
        cmd += ["--archive-bytes", str(s)]
    out = subprocess.run(cmd + trees, check=True, capture_output=True, text=True).stdout
    rows = [json.loads(line) for line in out.splitlines() if line.strip()]
    with open(os.path.join(a.work, "rows.jsonl"), "w") as f:
        f.write(out)
    s = summarize(rows)
    print(json.dumps(s))
    summary = os.environ.get("GITHUB_STEP_SUMMARY")
    if summary:
        with open(summary, "a") as f:
            f.write("### RFD 0166 W1: web update bytes per merge under cas/1 (replay)\n\n"
                    "| pairs | archive p50 | cas/1 Range GET p50 | % p50 | % p90 | % max | target |\n"
                    "| --- | --- | --- | --- | --- | --- | --- |\n"
                    f"| {s['pairs']} | {s['full_bytes_p50'] / 1e6:.2f} MB | {s['range_bytes_p50'] / 1e6:.2f} MB"
                    f" | {s['pct_p50']} | {s['pct_p90']} | {s['pct_max']} | <= 10 at p50 |\n")
            if s["span"]:
                f.write(f"\nOldest to newest ({s['span']['behind']} behind): {s['span']['range_bytes'] / 1e6:.2f} MB"
                        f" of {s['span']['full'] / 1e6:.2f} MB ({s['span']['pct']}%).\n")
    if a.max_p50 is not None and s["pct_p50"] > a.max_p50:
        print(f"W1 p50 {s['pct_p50']}% is above {a.max_p50}%", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
