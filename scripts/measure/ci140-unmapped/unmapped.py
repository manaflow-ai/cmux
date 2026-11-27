#!/usr/bin/env python3
"""Explain the "unmapped" bucket of the ci140 job-reuse measurement (goal ci-min-per-pr-140).

The reuse measurement maps each PR job row to a head SHA only through a `cmux-next · <SHA>` run name on the same
branch within 900 s. Rows with no such run are "unmapped". This script:

1. splits the unmapped minutes by reason (no cmux-next run on the branch / nearest one more than 900 s away),
   attempt and branch prefix, and ranks them by workflow | job | event;
2. draws a minutes-weighted sample of (workflow id, branch) pairs, reads each pair's real runs (head_sha, event)
   with one REST list call per pair, and classifies the sampled minutes: a new head, the same head SHA or tree as an
   earlier green of the same job, or the same head as an earlier non-green.

The sample answers whether the bucket hides skippable work (same input as an earlier green) or is a mapping gap.

Usage:
  unmapped.py --heads DIR --trees GIT [--merges 1306] [--sample 150] [--cache pairs.json]
DIR holds feed.jsonl (the timing feed, seg=pr rows) and runs.json (run id -> {b, w, first}); GIT is a bare repo
holding the head commits. --cache reuses an earlier sample instead of calling the API again.
"""
import argparse, bisect, collections, datetime, json, os, random, re, subprocess, sys

os.environ["GIT_NO_LAZY_FETCH"] = "1"
CN = re.compile(r"cmux-next · ([0-9a-f]{40})$")


def ts(s):
    return datetime.datetime.strptime(s, "%Y-%m-%dT%H:%M:%SZ").timestamp()


def norm_wf(w):
    return re.sub(r";.*", "", re.sub(r"[0-9a-f]{40}", "<SHA>", w))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--heads", required=True)
    ap.add_argument("--trees", required=True)
    ap.add_argument("--merges", type=int, default=1306)
    ap.add_argument("--sample", type=int, default=150)
    ap.add_argument("--cache")
    ap.add_argument("--top", type=int, default=10)
    a = ap.parse_args()
    M = a.merges
    runs = json.load(open(f"{a.heads}/runs.json"))

    cn_times = collections.defaultdict(list)
    for rid, x in runs.items():
        if CN.match(x["w"]):
            cn_times[x["b"]].append(ts(x["first"]))
    for v in cn_times.values():
        v.sort()

    def reason(rid):
        x = runs.get(rid)
        if not x:
            return "run_not_in_runs.json"
        if CN.match(x["w"]):
            return None
        v = cn_times.get(x["b"])
        if not v:
            return "no_cmux_next_run_on_branch"
        t = ts(x["first"]); i = bisect.bisect_left(v, t)
        near = min(abs(v[j] - t) for j in (i - 1, i) if 0 <= j < len(v))
        return None if near <= 900 else "nearest_cmux_next_gt_900s"

    R = collections.Counter(); ATT = collections.Counter(); BR = collections.Counter()
    K = collections.Counter(); P = collections.Counter(); total = 0.0
    rows = collections.defaultdict(list)
    for line in open(f"{a.heads}/feed.jsonl"):
        r = json.loads(line)
        if r["seg"] != "pr":
            continue
        m = int(r["seconds"] or 0) / 60; total += m
        why = reason(str(r["run"]))
        if not why:
            continue
        R[why] += m
        ATT["rerun" if r["attempt"] > 1 else "first attempt"] += m
        BR[(r.get("branch") or "?").split("/")[0]] += m
        K[(r.get("workflow_id"), norm_wf(r["workflow"]), r["job"])] += m
        if r.get("workflow_id"):
            k = f'{r["workflow_id"]}|{r["branch"]}'; P[k] += m; rows[k].append(r)
    U = sum(R.values())
    pct = lambda c: {k: (round(v), round(v / M, 1)) for k, v in c.most_common(6)}
    print(f"pr job minutes {total:.0f}; unmapped {U:.0f} = {U / M:.1f} per merged PR ({M} merges)")
    print("reason (min, min/merged PR):", pct(R))
    print("attempt:", pct(ATT))
    print("branch prefix:", pct(BR))

    # minutes-weighted sample of (workflow, branch) pairs, true head_sha and event from the API
    if a.cache and os.path.exists(a.cache):
        d = json.load(open(a.cache)); sample, api = d["sample"], d["runs"]
    else:
        keys = list(P); random.seed(140)
        sample = random.choices(keys, weights=[P[k] for k in keys], k=a.sample); api = {}
        for k in sorted(set(sample)):
            wid, b = k.split("|", 1)
            p = subprocess.run(["gh", "api", f"repos/manaflow-ai/cmux/actions/workflows/{wid}/runs?branch={b}&per_page=100",
                                "--jq", "[.workflow_runs[]|{id,head_sha,event,conclusion,run_attempt,created_at}]"],
                               capture_output=True, text=True)
            api[k] = json.loads(p.stdout) if p.returncode == 0 and p.stdout.strip() else []
        if a.cache:
            json.dump({"sample": sample, "runs": api}, open(a.cache, "w"))
    info = {x["id"]: x for v in api.values() for x in v or []}
    trees = {}

    def tree(s):
        if s not in trees:
            p = subprocess.run(["git", "-C", a.trees, "rev-parse", s + "^{tree}"], capture_output=True, text=True)
            trees[s] = p.stdout.strip() if p.returncode == 0 else None
        return trees[s]

    C = collections.Counter(); EV = collections.Counter(); WFEV = collections.defaultdict(collections.Counter)
    SK = collections.Counter(); mult = collections.Counter(sample)
    for k, rs in rows.items():
        if k not in mult:
            continue
        rs.sort(key=lambda r: r["at"]); w = mult[k] / (sum(int(r["seconds"] or 0) for r in rs) or 1)
        hist = collections.defaultdict(list)
        for r in rs:
            x = info.get(r["run"]); s = int(r["seconds"] or 0) * w
            if not x:
                C["run_not_listed"] += s; continue
            EV[x["event"]] += s; WFEV[r["workflow_id"]][x["event"]] += s
            t = tree(x["head_sha"]); h = hist[r["job"]]
            if any(hs == x["head_sha"] and c == "success" for hs, _, c in h): cls = "same_sha_after_green"
            elif t and any(ht == t and c == "success" for _, ht, c in h): cls = "same_tree_after_green"
            elif any(hs == x["head_sha"] for hs, _, _ in h): cls = "same_sha_after_nongreen"
            elif t is None: cls = "sha_not_in_trees"
            else: cls = "new_head"
            C[cls] += s
            if cls.endswith("after_green"):
                SK[(norm_wf(r["workflow"]), r["job"])] += s
            h.append((x["head_sha"], t, r["conclusion"]))
    n = len(sample) or 1
    est = lambda c: {k: (f"{v / n * 100:.1f}%", round(v / n * U / M, 1)) for k, v in c.most_common()}
    print(f"\nsample of {len(sample)} minutes-weighted draws over {len(set(sample))} (workflow, branch) pairs")
    print("class (% of bucket, est min/merged PR):", est(C))
    print("event:", est(EV))

    print(f"\ntop {a.top} unmapped by workflow | job | event (event: the workflow's sampled event)")
    print("| # | min / 24 h | min / merged PR | workflow | job | event |")
    print("|---|---|---|---|---|---|")
    for i, ((wid, wf, job), v) in enumerate(K.most_common(a.top), 1):
        ev = WFEV.get(wid); ev = ev.most_common(1)[0][0] if ev else "pull_request?"
        print(f"| {i} | {v:.0f} | {v / M:.1f} | {wf[:40]} | {job[:70]} | {ev} |")
    print("\nlargest same-input-after-green jobs in the sample (est min/merged PR)")
    for (wf, job), v in SK.most_common(8):
        print(f"  {v / n * U / M:4.1f}  {wf[:30]} | {job[:60]}")


if __name__ == "__main__":
    sys.exit(main())
