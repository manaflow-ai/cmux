#!/usr/bin/env python3
"""RFD 0166 row W1 by replay: what `cas/1` moves for an in-app web update, per merge.

Today every web update downloads the whole web bundle archive (about 17 MB). Under `cas/1` a
client holding the previous bundle tree fetches only the FastCDC chunks it lacks. This script
replays that over the real feat-cmux-next publishes, with no network beyond fetching them:

  1. fetch: the newest N successful push runs of cmux-next-web-bundle-publish.yml that built a
     bundle (a run whose key was already published uploads none), via their
     `cmux-next-web-bundles` artifact (archive plus manifest.json; kept 3 days).
  2. unpack each archive with scripts/cmux-next/web-bundle-archive.py unpack.
  3. run `cas-replay --archive-bytes SIZE... DIR...` (cmux-tui/crates/cmux-cas), oldest first:
     one JSON row per consecutive pair (1 merge behind) and one for oldest to newest.
  4. per consecutive pair, the per-file `zstd -19 --long=27 --patch-from` bytes (patch_bytes,
     patch_pct): RFD 0166's candidate PATCH lever for large minified bundles (--no-patch-from skips).
  5. print the W1 summary (p50 and p90 of range_bytes / archive bytes, 1 behind, and the same
     for patch-from) as JSON and, under GitHub Actions, a table in the step summary.

Usage:
  web_ota_replay.py --cas-replay BIN [--count N] [--work DIR] [--from-dir DIR] [--max-p50 PCT]

--from-dir reads already-fetched runs (DIR/<run>/web-bundles-*.tar.gz, as `fetch` leaves them)
instead of the API. --max-p50 exits 1 when the 1-behind p50 is above PCT (RFD 0166's target is
10); unset, the script only reports. Needs GH_TOKEN (actions: read) and GITHUB_REPOSITORY to fetch.
"""
import argparse
import concurrent.futures
import filecmp
import glob
import json
import os
import statistics
import subprocess
import sys
import urllib.request
import zipfile

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
WORKFLOW = "cmux-next-web-bundle-publish.yml"
ARTIFACT = "cmux-next-web-bundles"


def api(path, token, raw=False):
    url = path if path.startswith("https://") else f"https://api.github.com/{path}"
    req = urllib.request.Request(url, headers={
        "Authorization": f"Bearer {token}",
        "Accept": "application/vnd.github+json",
        "X-GitHub-Api-Version": "2022-11-28",
    })
    with urllib.request.urlopen(req, timeout=120) as r:
        body = r.read()
    return body if raw else json.loads(body)


def fetch(repo, token, count, work):
    """Download the newest `count` bundle artifacts; return their run dirs, oldest first."""
    runs = api(f"repos/{repo}/actions/workflows/{WORKFLOW}/runs"
               f"?branch=feat-cmux-next&event=push&status=success&per_page=100", token)["workflow_runs"]
    got = []
    for run in runs:
        if len(got) >= count:
            break
        arts = api(f"repos/{repo}/actions/runs/{run['id']}/artifacts", token)["artifacts"]
        art = next((a for a in arts if a["name"] == ARTIFACT and not a["expired"]), None)
        if art is None:
            continue
        d = os.path.join(work, "runs", f"{run['created_at']}-{run['id']}")
        if not glob.glob(os.path.join(d, "web-bundles-*.tar.gz")):
            os.makedirs(d, exist_ok=True)
            z = os.path.join(d, "a.zip")
            with open(z, "wb") as f:
                f.write(api(art["archive_download_url"], token, raw=True))
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


def tree_files(root):
    out = {}
    for d, _, names in os.walk(root):
        for n in names:
            full = os.path.join(d, n)
            out[os.path.relpath(full, root)] = full
    return out


def zstd_size(new, old=None):
    """Bytes of `zstd -19 --long=27` of new, as a patch from old when given."""
    cmd = ["zstd", "-q", "-c", "-19", "--long=27"]
    if old:
        cmd.append(f"--patch-from={old}")
    with subprocess.Popen(cmd + [new], stdout=subprocess.PIPE) as p:
        n = sum(len(b) for b in iter(lambda: p.stdout.read(1 << 20), b""))
    if p.returncode:
        raise SystemExit(f"zstd failed on {new}")
    return n


def patch_from_bytes(old_root, new_root, pool):
    """What a client holding old_root downloads under per-file zstd patch-from: 0 for an
    unchanged path, a patch for a changed one, the whole file (zstd) for a new path."""
    old, new = tree_files(old_root), tree_files(new_root)
    jobs = []
    for rel, path in new.items():
        prev = old.get(rel)
        if prev and filecmp.cmp(prev, path, shallow=False):
            continue
        jobs.append(pool.submit(zstd_size, path, prev))
    return sum(j.result() for j in jobs)


def add_patch_from(rows, trees, sizes, jobs):
    """Fill patch_bytes and patch_pct on the 1-behind rows (rows[i] is trees[i] -> trees[i+1])."""
    with concurrent.futures.ThreadPoolExecutor(max_workers=jobs) as pool:
        for i, r in enumerate(rows[:len(trees) - 1]):
            r["patch_bytes"] = patch_from_bytes(trees[i], trees[i + 1], pool)
            r["patch_pct"] = round(100.0 * r["patch_bytes"] / sizes[i + 1], 2)


def pct(values, q):
    s = sorted(values)
    return s[min(len(s) - 1, int(round(q * (len(s) - 1))))]


def summarize(rows):
    one = rows[:-1] if len(rows) > 1 else rows
    span = rows[-1] if len(rows) > 1 else None
    p = [r["pct_of_full"] for r in one]
    out = {
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
    if one and all("patch_pct" in r for r in one):
        pp = [r["patch_pct"] for r in one]
        out["patch_bytes_p50"] = statistics.median(r["patch_bytes"] for r in one)
        out["patch_pct_p50"] = round(statistics.median(pp), 2)
        out["patch_pct_p90"] = round(pct(pp, 0.9), 2)
        out["patch_pct_max"] = round(max(pp), 2)
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--cas-replay", required=True)
    ap.add_argument("--count", type=int, default=30)
    ap.add_argument("--work", default="cas-replay-w1")
    ap.add_argument("--from-dir")
    ap.add_argument("--max-p50", type=float)
    ap.add_argument("--no-patch-from", action="store_true")
    ap.add_argument("--jobs", type=int, default=os.cpu_count() or 4)
    a = ap.parse_args()
    os.makedirs(a.work, exist_ok=True)
    if a.from_dir:
        run_dirs = sorted(d for d in glob.glob(os.path.join(a.from_dir, "*")) if os.path.isdir(d))
    else:
        run_dirs = fetch(os.environ["GITHUB_REPOSITORY"], os.environ["GH_TOKEN"], a.count, a.work)
    if len(run_dirs) < 2:
        raise SystemExit(f"need two bundle publishes to replay, found {len(run_dirs)}")
    trees, sizes = unpack(run_dirs, a.work)
    cmd = [a.cas_replay]
    for s in sizes:
        cmd += ["--archive-bytes", str(s)]
    out = subprocess.run(cmd + trees, check=True, capture_output=True, text=True).stdout
    rows = [json.loads(line) for line in out.splitlines() if line.strip()]
    if not a.no_patch_from:
        add_patch_from(rows, trees, sizes, a.jobs)
    with open(os.path.join(a.work, "rows.jsonl"), "w") as f:
        f.writelines(json.dumps(r) + "\n" for r in rows)
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
            if "patch_pct_p50" in s:
                f.write(f"\nPer-file `zstd -19 --long=27 --patch-from` (1 behind): {s['patch_bytes_p50'] / 1e6:.2f} MB"
                        f" at p50 ({s['patch_pct_p50']}%), p90 {s['patch_pct_p90']}%, max {s['patch_pct_max']}%.\n")
    if a.max_p50 is not None and s["pct_p50"] > a.max_p50:
        print(f"W1 p50 {s['pct_p50']}% is above {a.max_p50}%", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
