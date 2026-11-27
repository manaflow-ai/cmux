#!/usr/bin/env python3
"""RFD 0166 row W1: replay the last N published web OTA bundles through cmux-cas.

Downloads the `cmux-next-web-bundles` artifact (manifest.json plus web-bundles-<sha>.tar.gz,
kept 3 days) of the last N successful `cmux-next web bundle publish` runs on feat-cmux-next,
unpacks each archive, runs `cas-replay --behind 1 --behind 20` over them oldest first and
writes the rows (JSONL) and a summary: today every merge moves the whole archive; cas/1 moves
the Range-GET bytes of the chunks the client lacks.

Usage: cas-replay-web.py CAS_REPLAY_BIN WORKDIR [N]   (needs gh with GH_TOKEN, actions: read)
"""
import io, json, os, statistics, subprocess, sys, tarfile, time, zipfile

REPO = os.environ.get("GITHUB_REPOSITORY", "manaflow-ai/cmux")


def gh(path, raw=False):
    # Three tries: a GitHub 5xx or secondary rate limit on one page should not fail the row.
    # On the last failure, print gh's stderr so the job log names the cause.
    for attempt in range(3):
        proc = subprocess.run(["gh", "api", path], capture_output=True)
        if proc.returncode == 0:
            return proc.stdout if raw else json.loads(proc.stdout)
        err = proc.stderr.decode(errors="replace").strip()
        print(f"gh api {path}: exit {proc.returncode} (try {attempt + 1}/3): {err}", file=sys.stderr)
        time.sleep(5 * (attempt + 1))
    sys.exit(f"gh api {path} failed 3 times; last error above")


def main():
    binary, work = sys.argv[1], sys.argv[2]
    want = int(sys.argv[3]) if len(sys.argv) > 3 else 100
    os.makedirs(work, exist_ok=True)
    got, page = [], 1
    while len(got) < want and page <= 10:
        runs = gh(f"repos/{REPO}/actions/workflows/cmux-next-web-bundle-publish.yml/runs"
                  f"?branch=feat-cmux-next&status=success&per_page=100&page={page}")["workflow_runs"]
        if not runs:
            break
        for run in runs:
            if len(got) >= want:
                break
            arts = gh(f"repos/{REPO}/actions/runs/{run['id']}/artifacts")["artifacts"]
            art = next((a for a in arts if a["name"] == "cmux-next-web-bundles" and not a["expired"]), None)
            if art is None:
                continue  # the key was already published: no new archive this merge
            z = zipfile.ZipFile(io.BytesIO(gh(f"repos/{REPO}/actions/artifacts/{art['id']}/zip", raw=True)))
            man = json.loads(z.read("manifest.json"))
            blob = z.read(man["archive"])
            dest = os.path.join(work, f"{run['created_at']}-{man['commit'][:10]}")
            os.makedirs(dest, exist_ok=True)
            with tarfile.open(fileobj=io.BytesIO(blob), mode="r:gz") as t:
                t.extractall(dest, filter="data")
            got.append((run["created_at"], dest, len(blob)))
        page += 1
    got.sort()
    if len(got) < 2:
        sys.exit(f"only {len(got)} archives still held")
    argv = [binary, "--behind", "1", "--behind", "20"]
    for _, _, size in got:
        argv += ["--archive-bytes", str(size)]
    argv += [d for _, d, _ in got]
    rows = [json.loads(l) for l in subprocess.run(argv, capture_output=True, text=True, check=True).stdout.splitlines()]
    with open(os.path.join(work, "rows.jsonl"), "w") as f:
        f.writelines(json.dumps(r) + "\n" for r in rows)
    summary = {"archives": len(got)}
    for k in sorted({r["behind"] for r in rows}):
        rs = [r for r in rows if r["behind"] == k]
        pct = sorted(r["pct_of_full"] for r in rs)
        summary[f"behind_{k}"] = {
            "pairs": len(rs), "p50_pct": round(statistics.median(pct), 2),
            "p90_pct": round(pct[int(0.9 * (len(pct) - 1))], 2),
            "full_bytes": sum(r["full"] for r in rs), "range_bytes": sum(r["range_bytes"] for r in rs),
            "ms_p50": statistics.median(r["ms"] for r in rs)}
    json.dump(summary, open(os.path.join(work, "summary.json"), "w"), indent=1)
    print(json.dumps(summary, indent=1))
    if os.environ.get("GITHUB_STEP_SUMMARY"):
        with open(os.environ["GITHUB_STEP_SUMMARY"], "a") as f:
            f.write("## RFD 0166 W1: web OTA bytes per merge, cas/1 vs the whole archive\n\n")
            f.write("| behind | pairs | p50 % of archive | p90 % | archive bytes | cas/1 bytes |\n|---|---|---|---|---|---|\n")
            for k, v in summary.items():
                if k.startswith("behind_"):
                    f.write(f"| {k[7:]} | {v['pairs']} | {v['p50_pct']} | {v['p90_pct']} | {v['full_bytes']} | {v['range_bytes']} |\n")


if __name__ == "__main__":
    main()
