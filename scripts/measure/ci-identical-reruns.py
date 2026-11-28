#!/usr/bin/env python3
"""Byte-identical CI reruns: runner-minutes spent on a job whose inputs had already passed.

Shows how many runner-minutes in a window went to a job (workflow, job name, input key) that had already finished
green earlier in the same window. That is the ceiling for "skip a job whose key already passed".

Input key:
  - job_input_fingerprint (scripts/ci/job_input_fingerprint.py, cmux#54976), when a record carries one. Today
    the controller's timing records and run feed do not record it, so in practice:
  - the commit tree SHA (the run feed's head_tree). Two runs on the same tree have byte-identical repo
    contents. This proxy UNDERCOUNTS: a job whose own input paths did not change but whose tree did (another
    file in the repo moved) counts as new work here.
    The run feed keeps only a few hours of runs (about a quarter of GitHub job minutes in its newest hours), and
    timing records carry no head SHA, so most GitHub jobs fall through to:
  - the run id: a later attempt of a job whose earlier attempt in the same run passed. Exact, but a lower bound
    (it cannot see a new run on the same tree).
  - Fleet ci-steps (controller /v1/jobs) carry a head SHA in step_key; --git-dir resolves it to a tree from a
    local mirror (no network), else the SHA itself is the key.
"Re-run failed jobs" copies each passed job into the new attempt with the same duration and completion time;
no runner ran those. They are dropped and reported as carried_copy_min (the timing feed counts them as minutes).

A record is a rerun when its key had a success that finished before the record started. All of its minutes
count as wasted, whatever the record's own conclusion. Shard suffixes are collapsed ("test (2/4)" -> "test"), so
the key works on the job, not the shard; shards of one run are not reruns of each other because the earlier
pass must have finished before the later one started.

Data: the controller's timing feed (every GitHub and fleet-runner job, all attempts), its fleet jobs and its run
feed, all read through build-fleet/data/ci_per_pr.py from a cmuxterm-hq checkout. It makes no GitHub API calls.

Run:
  python3 scripts/measure/ci-identical-reruns.py --meter ~/src/cmuxterm-hq/build-fleet/data   # last 24 h
  python3 scripts/measure/ci-identical-reruns.py --meter DIR --until 1795554000 --save /tmp/x  # pull and keep
  python3 scripts/measure/ci-identical-reruns.py --load /tmp/x                                # recompute offline
  add --git-dir manaflow-ai/cmux=PATH/cmux.git --git-dir manaflow-ai/cmuxterm-hq=PATH/cmuxterm-hq.git to key
  fleet steps by tree instead of commit.
  --json prints the full result as JSON.
"""
from __future__ import annotations

import argparse
import collections
import gzip
import json
import os
import re
import sys
import time
import urllib.request

REPOS = ("manaflow-ai/cmux", "manaflow-ai/cmuxterm-hq")


def collapse(job: str) -> str:
    j = re.sub(r"\s*\([^()]*\)\s*$", "", job)
    j = re.sub(r"[\s_-]*(shard|part|chunk)?[\s_-]*\d+\s*/\s*\d+\s*$", "", j, flags=re.I)
    j = re.sub(r"[\s_-]+(shard|part|chunk)[\s_-]*\d+\s*$", "", j, flags=re.I)
    return j.strip() or job


def ts(s):
    if not s or s.startswith("0001-"):  # Go's zero time: never started
        return None
    s = s.replace("Z", "+00:00")
    if "." in s:  # trim fractional seconds past microseconds
        head, rest = s.split(".", 1)
        frac = re.match(r"\d+", rest).group(0)
        s = f"{head}.{frac[:6]}{rest[len(frac):]}"
    from datetime import datetime
    return datetime.fromisoformat(s).timestamp()


# ---- pull ------------------------------------------------------------------------------------------------------

def fetch_events_all(c):
    """The run feed, every repo (ci_per_pr.fetch_events keeps cmux only)."""
    cursor = 0
    while True:
        url = f"{c.ci_minutes.CONTROLLER}/v1/github/events?since={cursor}&limit=5000"
        for attempt in range(6):
            try:
                with urllib.request.urlopen(url, timeout=120) as resp:
                    page = json.loads(resp.read())
                break
            except Exception as err:  # noqa: BLE001
                if attempt == 5:
                    raise
                print(f"events retry {attempt + 1}: {err!r}", file=sys.stderr)
                time.sleep(5 * (attempt + 1))
        yield from page.get("runs") or []
        if not page.get("more") or page.get("cursor") == cursor:
            return
        cursor = page["cursor"]


def pull(meter: str, since: int, until: int, save: str | None):
    sys.path.insert(0, os.path.expanduser(meter))
    import ci_per_pr as c  # noqa: E402
    timing = []
    for repo in REPOS:
        timing += list(c.fetch_live(since, until, repo=repo))
    fleet = [c.fleet_slim(j) for j in c.fetch_fleet(since, until)]
    events = list(fetch_events_all(c))
    if save:
        os.makedirs(save, exist_ok=True)
        json.dump({"since": since, "until": until}, open(os.path.join(save, "window.json"), "w"))
        for name, rows in (("timing", timing), ("fleet", fleet), ("events", events)):
            with gzip.open(os.path.join(save, f"{name}.jsonl.gz"), "wt") as f:
                for r in rows:
                    r = {k: v for k, v in r.items() if k != "steps"}
                    f.write(json.dumps(r, separators=(",", ":")) + "\n")
    return timing, fleet, events


def load(d: str):
    w = json.load(open(os.path.join(d, "window.json")))
    rows = {}
    for name in ("timing", "fleet", "events"):
        rows[name] = [json.loads(l) for l in gzip.open(os.path.join(d, f"{name}.jsonl.gz"), "rt") if l.strip()]
    return w["since"], w["until"], rows["timing"], rows["fleet"], rows["events"]


# ---- compute ---------------------------------------------------------------------------------------------------

HEX = re.compile(r"(?<![0-9a-z])[0-9a-f]{12,40}(?![0-9a-z])")


def fleet_step(j):
    """(step identity, head sha or None) from a fleet ci-step's step_key: the sha is its first 12..40-hex token;
    the identity drops the sha, the submitting node's name, digit runs (PR, run id, retry) and -superseded."""
    sk = j.get("step_key") or ""
    m = HEX.search(sk)
    sha = m.group(0) if m else None
    node = (j.get("submitter") or "").removeprefix("node:")
    ident = sk.replace(sha, "") if sha else sk
    if node and ident.startswith(node):
        ident = ident[len(node):]
    ident = re.sub(r"-superseded$", "", ident)
    ident = re.sub(r"\d+", "", ident)
    ident = re.sub(r"-{2,}", "-", ident).strip("-")
    return ident, sha


def trees_from_git(git_dir, shas):
    """sha (full or short) -> tree SHA from a local clone or mirror, one git cat-file --batch-check call."""
    import subprocess
    shas = sorted(set(shas))
    if not git_dir or not shas:
        return {}
    out = subprocess.run(["git", "-C", os.path.expanduser(git_dir), "cat-file", "--batch-check"],
                         input="".join(f"{s}^{{tree}}\n" for s in shas), capture_output=True, text=True).stdout
    res = {}
    for sha, line in zip(shas, out.splitlines()):
        parts = line.split()
        if len(parts) == 3 and parts[1] == "tree":
            res[sha] = parts[0]
    return res


def compute(since, until, timing, fleet, events, git_dirs=None):
    run_tree, run_fp, sha_tree = {}, {}, {}
    for e in events:
        run_tree[e["id"]] = e.get("head_tree")
        if e.get("job_input_fingerprint"):
            run_fp[e["id"]] = e["job_input_fingerprint"]
        if e.get("head_sha") and e.get("head_tree"):
            sha_tree[e["head_sha"]] = e["head_tree"]
    short_tree = {}
    for sha, tree in sha_tree.items():
        for n in (12, 40):
            short_tree.setdefault(sha[:n], tree)
    fleet_shas = collections.defaultdict(set)
    for j in fleet:
        if j.get("kind") == "ci-step":
            sha = fleet_step(j)[1]
            if sha and sha not in short_tree:
                fleet_shas[j.get("repo") or ""].add(sha)
    for repo, shas in fleet_shas.items():
        short_tree.update(trees_from_git((git_dirs or {}).get(repo), shas))

    recs, seen, carried = [], set(), set()
    carried_min = 0.0
    for r in timing:
        k = (r.get("repo"), r.get("id"), r.get("attempt"))
        if k in seen:
            continue
        seen.add(k)
        # "Re-run failed jobs" copies each passed job into the new attempt under a new job id with the original
        # completion time and duration: no runner ran it. Count it once (the timing feed counts every copy).
        ck = (r.get("repo"), r.get("run"), r.get("job"), r.get("at"), r.get("seconds"))
        if r.get("run") and ck in carried:
            if since <= (ts(r.get("at")) or 0) < until:
                carried_min += float(r.get("seconds") or 0) / 60
            continue
        carried.add(ck)
        end = ts(r.get("at"))
        if end is None or not (since <= end < until):
            continue
        secs = float(r.get("seconds") or 0)
        fp = r.get("job_input_fingerprint") or run_fp.get(r.get("run"))
        tree = run_tree.get(r.get("run"))
        # No fingerprint and no tree: the run id still pins the commit, so a later attempt of a job whose earlier
        # attempt in the same run passed is byte-identical (a lower bound: it misses new runs on the same tree).
        run = r.get("run")
        key_kind = "fingerprint" if fp else ("tree" if tree else ("run" if run else None))
        recs.append({
            "src": "github-timing", "repo": r["repo"], "wf": r.get("workflow_path") or str(r.get("workflow_id")),
            "job": r.get("job") or "", "input": fp or tree or (f"run:{run}" if run else None),
            "key_kind": key_kind,
            "start": end - secs, "end": end, "min": secs / 60, "ok": r.get("conclusion") == "success",
            "runner": r.get("runner"),
        })
    for j in fleet:
        if j.get("kind") != "ci-step":
            continue
        s, e = ts(j.get("started_at")), ts(j.get("updated_at"))
        if s is None or e is None or not (since <= e < until):
            continue
        if e < s:
            continue
        step, sha = fleet_step(j)
        tree = short_tree.get(sha) if sha else None
        recs.append({
            "src": "fleet", "repo": j.get("repo") or "?", "wf": j.get("script") or "?", "job": step,
            "input": tree or (f"sha:{sha}" if sha else None),
            "key_kind": "tree" if tree else ("short-sha" if sha else None),
            "start": s, "end": e, "min": (e - s) / 60, "ok": j.get("state") == "done", "runner": "fleet",
        })

    recs.sort(key=lambda x: x["start"])
    out = summarize(recs, since, until)
    out["carried_copy_min"] = round(carried_min)  # dropped from every total above
    # The run feed keeps one latest state per run for a few hours only, so GitHub jobs older than that have no
    # tree. The tail where it covers >= 90% of GitHub job minutes is measured on its own, tree-keyed.
    hours = collections.defaultdict(lambda: [0.0, 0.0])
    for r in recs:
        if r["src"] == "github-timing":
            h = int(r["end"] // 3600)
            hours[h][0] += r["min"]
            hours[h][1] += r["min"] if r["key_kind"] in ("tree", "fingerprint") else 0
    tail = None
    for h in sorted(hours, reverse=True):
        if hours[h][1] < 0.9 * hours[h][0]:
            break
        tail = h * 3600
    if tail is not None and tail > since:
        out["tree_covered_tail"] = summarize([r for r in recs if r["start"] >= tail], tail, until)
    return out


def summarize(recs, since, until):
    import heapq
    passed = set()
    pending = []  # successes not yet finished at the current start, released in end order
    total, waste, unkeyed = collections.Counter(), collections.Counter(), collections.Counter()
    kinds, kind_waste = collections.Counter(), collections.Counter()
    by_job = collections.defaultdict(lambda: [0.0, 0.0, 0, collections.Counter()])  # min, rerun min, reruns, kinds
    for r in recs:
        while pending and pending[0][0] <= r["start"]:
            passed.add(heapq.heappop(pending)[1])
        bucket = (r["src"], r["repo"])
        total[bucket] += r["min"]
        kind = f"{r['src']}:{r['key_kind'] or 'none'}"
        kinds[kind] += r["min"]
        jk = (r["repo"], r["wf"], collapse(r["job"]))
        by_job[jk][0] += r["min"]
        if r["input"] is None:
            unkeyed[bucket] += r["min"]
            continue
        key = (r["repo"], r["wf"], r["job"], r["input"])  # the exact job (shard, matrix leg), not the collapsed name
        if key in passed:
            waste[bucket] += r["min"]
            kind_waste[kind] += r["min"]
            by_job[jk][1] += r["min"]
            by_job[jk][2] += 1
            by_job[jk][3][kind] += r["min"]
        if r["ok"]:
            heapq.heappush(pending, (r["end"], key))
    T, W, U = sum(total.values()), sum(waste.values()), sum(unkeyed.values())
    top = sorted(by_job.items(), key=lambda kv: -kv[1][1])[:15]
    return {
        "window": {"since": since, "until": until},
        "total_min": round(T), "rerun_min": round(W), "rerun_pct": round(100 * W / T, 1) if T else None,
        "unkeyed_min": round(U),
        "key_kinds": {k: {"min": round(v), "rerun_min": round(kind_waste[k]),
                          "rerun_pct": round(100 * kind_waste[k] / v, 1) if v else None} for k, v in kinds.items()},
        "by_source": [{"src": b[0], "repo": b[1], "total_min": round(total[b]), "rerun_min": round(waste[b]),
                       "unkeyed_min": round(unkeyed[b])} for b in sorted(total)],
        "top": [{"repo": k[0], "workflow": k[1], "job": k[2], "job_min": round(v[0]), "rerun_min": round(v[1]),
                 "reruns": v[2], "keyed_by": ",".join(sorted(v[3]))} for k, v in top],
    }


def markdown(r, title="whole window"):
    w = r["window"]
    out = [f"## {title}: {time.strftime('%m-%d %H:%MZ', time.gmtime(w['since']))} .. "
           f"{time.strftime('%m-%d %H:%MZ', time.gmtime(w['until']))}", "",
           f"total {r['total_min']:,} runner-min; reruns of an already-passed key {r['rerun_min']:,} "
           f"({r['rerun_pct']}%); unkeyed {r['unkeyed_min']:,}"
           + (f"; carried-over copies dropped (not run, still counted by the timing feed) {r['carried_copy_min']:,}"
              if "carried_copy_min" in r else ""), "",
           "| key kind | runner-min | rerun-min | rerun % |", "|---|---:|---:|---:|"]
    out += [f"| {k} | {v['min']:,} | {v['rerun_min']:,} | {v['rerun_pct']} |" for k, v in sorted(r["key_kinds"].items())]
    out += ["", "| source | repo | runner-min | rerun-min | unkeyed |", "|---|---|---:|---:|---:|"]
    out += [f"| {b['src']} | {b['repo']} | {b['total_min']:,} | {b['rerun_min']:,} | {b['unkeyed_min']:,} |"
            for b in r["by_source"]]
    out += ["", "| # | workflow | job | job runner-min | rerun-min | reruns | keyed by |",
            "|---:|---|---|---:|---:|---:|---|"]
    out += [f"| {i} | {t['workflow']} | {t['job']} | {t['job_min']:,} | {t['rerun_min']:,} | {t['reruns']} | "
            f"{t['keyed_by']} |" for i, t in enumerate(r["top"], 1)]
    if r.get("tree_covered_tail"):
        out += ["", markdown(r["tree_covered_tail"], "tree-covered tail (run feed holds >= 90% of GitHub job minutes)")]
    return "\n".join(out)


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--meter", default=os.environ.get("CI_METER_DIR"),
                    help="cmuxterm-hq build-fleet/data (holds ci_per_pr.py); or $CI_METER_DIR")
    ap.add_argument("--until", type=int, help="window end, unix seconds (default: last whole hour)")
    ap.add_argument("--hours", type=float, default=24)
    ap.add_argument("--save", help="keep the pulled rows in this directory")
    ap.add_argument("--load", help="recompute from a --save directory, no network")
    ap.add_argument("--git-dir", action="append", default=[], metavar="REPO=DIR",
                    help="a local clone or mirror that resolves fleet step SHAs to trees, e.g. "
                         "manaflow-ai/cmux=~/cmux.git (repeatable)")
    ap.add_argument("--json", action="store_true")
    a = ap.parse_args()
    if a.load:
        since, until, timing, fleet, events = load(a.load)
    else:
        if not a.meter:
            ap.error("--meter DIR (or $CI_METER_DIR) is required to pull; or --load a saved directory")
        until = a.until or int(time.time()) // 3600 * 3600
        since = int(until - a.hours * 3600)
        timing, fleet, events = pull(a.meter, since, until, a.save)
    git_dirs = dict(x.split("=", 1) for x in a.git_dir)
    r = compute(since, until, timing, fleet, events, git_dirs)
    print(json.dumps(r, indent=1) if a.json else markdown(r))


if __name__ == "__main__":
    main()
