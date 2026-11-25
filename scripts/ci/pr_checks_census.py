#!/usr/bin/env python3
"""Counts the checks on pull requests' last head commits and how long their CI took, for a before/after census.

    pr_checks_census.py --repo OWNER/NAME PR [PR ...] [--json] [--save-raw FILE] [--top 60]
    pr_checks_census.py --from-raw FILE [--json] [--top 60]

It reads, through `gh api graphql`, each pull request's last head commit and that commit's statusCheckRollup:
every CheckRun (name, status, conclusion, startedAt, completedAt and its workflow's name) and every StatusContext
(context, state, createdAt). Pull requests are batched by alias, 12 to a query, so a sample of two dozen costs two
or three queries; a commit with more than 100 checks costs one more query per further page. --save-raw keeps
what GitHub returned, and --from-raw reads it back with no GitHub call at all, so a table can be redone for free.

For each pull request it prints the number of check entries, their counts by conclusion (SUCCESS, FAILURE,
SKIPPED, NEUTRAL, CANCELLED, other; a StatusContext counts by its state), how many ran (not SKIPPED or NEUTRAL and
with a startedAt, so a StatusContext never counts as ran), and the wall time: the latest completedAt minus the
earliest startedAt among the checks that ran, in minutes. It prints the counts per workflow too.

Then it prints the median and p75 over the sample of total, ran and skipped checks and of wall time, and a table
of every check name (workflow / name) over the sample: on how many pull requests it appeared, and how many times it
was skipped, ran, failed or ended some other way. A check that appears on every pull request and is always
skipped is one that costs a slot on each of them without doing work.

--json prints all of the above as one JSON object instead of the tables.
"""
from __future__ import annotations

import argparse
import json
import os
import statistics
import subprocess
import sys
from collections import Counter, defaultdict
from datetime import datetime, timedelta

BATCH = 12
CONCLUSIONS = ("SUCCESS", "FAILURE", "SKIPPED", "NEUTRAL", "CANCELLED")
FAILED = {"FAILURE", "TIMED_OUT", "STARTUP_FAILURE", "ERROR", "ACTION_REQUIRED"}
NOT_RAN = {"SKIPPED", "NEUTRAL"}

CONTEXT_FIELDS = """
  totalCount
  pageInfo { hasNextPage endCursor }
  nodes {
    __typename
    ... on CheckRun {
      name status conclusion startedAt completedAt
      checkSuite { workflowRun { workflow { name } } }
    }
    ... on StatusContext { context state createdAt }
  }
"""


def gh_graphql(query: str) -> dict:
    proc = subprocess.run(
        ["gh", "api", "graphql", "-f", f"query={query}"],
        capture_output=True,
        text=True,
    )
    if proc.returncode != 0:
        raise SystemExit(f"gh api graphql failed ({proc.returncode}): {proc.stderr.strip() or proc.stdout.strip()}")
    payload = json.loads(proc.stdout)
    if payload.get("errors"):
        raise SystemExit(f"graphql errors: {json.dumps(payload['errors'])[:2000]}")
    return payload["data"]


def pr_fragment(alias: str, number: int) -> str:
    return f"""
    {alias}: pullRequest(number: {number}) {{
      number title author {{ login }} baseRefName mergedAt
      commits(last: 1) {{ nodes {{ commit {{ oid
        statusCheckRollup {{ state contexts(first: 100) {{ {CONTEXT_FIELDS} }} }}
      }} }} }}
    }}"""


def fetch(repo: str, numbers: list[int]) -> tuple[list[dict], int]:
    owner, name = repo.split("/", 1)
    prs: list[dict] = []
    queries = 0
    for start in range(0, len(numbers), BATCH):
        chunk = numbers[start : start + BATCH]
        body = "".join(pr_fragment(f"pr{n}", n) for n in chunk)
        data = gh_graphql(f'query {{ repository(owner: "{owner}", name: "{name}") {{ {body} }} rateLimit {{ cost remaining resetAt }} }}')
        queries += 1
        print(f"query {queries}: rateLimit {data.get('rateLimit')}", file=sys.stderr)
        for n in chunk:
            pr = data["repository"][f"pr{n}"]
            if pr is None:
                print(f"#{n}: not found", file=sys.stderr)
                continue
            nodes = pr["commits"]["nodes"]
            commit = nodes[0]["commit"] if nodes else {"oid": None, "statusCheckRollup": None}
            rollup = commit.get("statusCheckRollup") or {}
            contexts = rollup.get("contexts") or {"nodes": [], "pageInfo": {"hasNextPage": False}}
            entries = list(contexts["nodes"])
            page = contexts["pageInfo"]
            while page.get("hasNextPage"):
                more = gh_graphql(
                    f'query {{ repository(owner: "{owner}", name: "{name}") {{ object(oid: "{commit["oid"]}") {{'
                    f' ... on Commit {{ statusCheckRollup {{ contexts(first: 100, after: "{page["endCursor"]}") {{ {CONTEXT_FIELDS} }} }} }} }} }} }}'
                )
                queries += 1
                ctx = more["repository"]["object"]["statusCheckRollup"]["contexts"]
                entries.extend(ctx["nodes"])
                page = ctx["pageInfo"]
            prs.append(
                {
                    "number": pr["number"],
                    "title": pr["title"],
                    "author": (pr.get("author") or {}).get("login"),
                    "base": pr["baseRefName"],
                    "mergedAt": pr["mergedAt"],
                    "head": commit["oid"],
                    "rollupState": rollup.get("state"),
                    "entries": entries,
                }
            )
    return prs, queries


def gh_rest(path: str, key: str | None = None) -> list:
    """Every page of a REST read, one `gh api` call per page (a counted call each), as a list of page bodies."""
    pages, page = [], 1
    while True:
        sep = "&" if "?" in path else "?"
        target = f"{path}{sep}per_page=100&page={page}" if key else path
        proc = subprocess.run(["gh", "api", target], capture_output=True, text=True)
        if proc.returncode != 0:
            raise SystemExit(f"gh api {target} failed ({proc.returncode}): {proc.stderr.strip() or proc.stdout.strip()}")
        body = json.loads(proc.stdout)
        pages.append(body)
        if not key or len(body.get(key) or []) < 100:
            return pages
        page += 1


def fetch_rest(repo: str, numbers: list[int], save: str | None = None) -> tuple[list[dict], int]:
    """The same pull requests over REST, for a client whose GraphQL may not read completedAt: per pull request its
    head (pulls/N), that commit's check runs and the workflow runs that name each run's workflow. With `save`, each
    pull request is written there as soon as it is read, and one already there is not read again, so a run a spent
    quota stops resumes where it stopped."""
    prs: list[dict] = []
    if save and os.path.exists(save):
        with open(save) as fh:
            prs = [p for p in json.load(fh)["prs"] if p["number"] in numbers and "workflow_runs" in p]
    done = {p["number"] for p in prs}
    calls = 0
    for n in numbers:
        if n in done:
            continue
        pr = gh_rest(f"repos/{repo}/pulls/{n}")[0]
        sha = pr["head"]["sha"]
        runs = [r for page in gh_rest(f"repos/{repo}/commits/{sha}/check-runs?filter=latest", "check_runs")
                for r in page["check_runs"]]
        workflow_runs = [{k: r.get(k) for k in ("check_suite_id", "name", "event", "run_attempt", "created_at",
                                                 "updated_at", "status")}
                         for page in gh_rest(f"repos/{repo}/actions/runs?head_sha={sha}", "workflow_runs")
                         for r in page["workflow_runs"]]
        suites = {r["check_suite_id"]: r["name"] for r in workflow_runs}
        calls += 3
        entries = [{"__typename": "CheckRun", "name": r["name"], "status": (r.get("status") or "").upper(),
                    "conclusion": (r.get("conclusion") or "").upper() or None,
                    "startedAt": r.get("started_at"), "completedAt": r.get("completed_at"),
                    "suite": (r.get("check_suite") or {}).get("id"),
                    "checkSuite": {"workflowRun": {"workflow": {
                        "name": suites.get((r.get("check_suite") or {}).get("id"), "(no workflow)")}}}}
                   for r in runs]
        prs.append({"number": n, "title": pr["title"], "author": (pr.get("user") or {}).get("login"),
                    "base": pr["base"]["ref"], "mergedAt": pr.get("merged_at"), "head": sha,
                    "rollupState": None, "entries": entries, "workflow_runs": workflow_runs})
        print(f"#{n}: {len(entries)} check runs", file=sys.stderr)
        if save:
            with open(save, "w") as fh:
                json.dump({"repo": repo, "prs": prs}, fh, indent=1)
    return prs, calls


def ts(value: str | None) -> datetime | None:
    return datetime.fromisoformat(value.replace("Z", "+00:00")) if value else None


def normalize(entry: dict) -> dict:
    if entry.get("__typename") == "StatusContext":
        return {
            "key": f"(status) / {entry['context']}",
            "workflow": "(status)",
            "conclusion": entry.get("state") or "UNKNOWN",
            "started": None,
            "completed": None,
        }
    run = ((entry.get("checkSuite") or {}).get("workflowRun") or {}).get("workflow") or {}
    workflow = run.get("name") or "(no workflow)"
    conclusion = entry.get("conclusion") or entry.get("status") or "UNKNOWN"
    return {
        "key": f"{workflow} / {entry['name']}",
        "workflow": workflow,
        "conclusion": conclusion,
        "started": ts(entry.get("startedAt")),
        "completed": ts(entry.get("completedAt")),
    }


PUSH_BURST = timedelta(minutes=15)


def push_burst(pr: dict) -> tuple[set, float | None]:
    """The workflow runs the head's push started (pull_request event, first attempt, created within PUSH_BURST of
    the first), by check suite, and the minutes from the first one's creation to the last one's end. Runs for a
    later edit, label or re-run are left out, so a head that sat for a day does not read as a day of CI."""
    runs = [r for r in pr.get("workflow_runs") or [] if r.get("event") == "pull_request" and r.get("run_attempt") == 1
            and r.get("created_at")]
    if not runs:
        return set(), None
    first = min(ts(r["created_at"]) for r in runs)
    burst = [r for r in runs if ts(r["created_at"]) - first <= PUSH_BURST]
    ends = [ts(r["updated_at"]) for r in burst if r.get("status") == "completed" and r.get("updated_at")]
    return {r["check_suite_id"] for r in burst}, (round((max(ends) - first).total_seconds() / 60, 1) if ends else None)


def summarize(pr: dict) -> dict:
    suites, push_wall = push_burst(pr)
    push = [e for e in pr["entries"] if e.get("suite") in suites]
    push_ran = [e for e in push if (e.get("conclusion") or "") not in NOT_RAN and e.get("startedAt")]
    checks = [normalize(e) for e in pr["entries"]]
    by_conclusion = Counter()
    for c in checks:
        by_conclusion[c["conclusion"] if c["conclusion"] in CONCLUSIONS else "other"] += 1
    ran = [c for c in checks if c["conclusion"] not in NOT_RAN and c["started"] is not None]
    starts = [c["started"] for c in ran]
    ends = [c["completed"] for c in ran if c["completed"] is not None]
    wall = (max(ends) - min(starts)).total_seconds() / 60 if starts and ends else None
    per_workflow: dict[str, Counter] = defaultdict(Counter)
    for c in checks:
        per_workflow[c["workflow"]]["total"] += 1
        per_workflow[c["workflow"]]["ran" if c in ran else ("skipped" if c["conclusion"] == "SKIPPED" else "other")] += 1
    return {
        "number": pr["number"],
        "title": pr["title"],
        "head": pr["head"],
        "total": len(checks),
        "conclusions": {k: by_conclusion.get(k, 0) for k in (*CONCLUSIONS, "other")},
        "ran": len(ran),
        "skipped": by_conclusion.get("SKIPPED", 0),
        "wall_minutes": round(wall, 1) if wall is not None else None,
        "push_checks": len(push),
        "push_ran": len(push_ran),
        "push_wall_minutes": push_wall,
        "per_workflow": {w: dict(c) for w, c in sorted(per_workflow.items(), key=lambda kv: -kv[1]["total"])},
        "checks": checks,
    }


def median_p75(values: list[float]) -> dict:
    values = [v for v in values if v is not None]
    if not values:
        return {"n": 0, "median": None, "p75": None}
    p75 = statistics.quantiles(values, n=4, method="inclusive")[2] if len(values) > 1 else values[0]
    return {"n": len(values), "median": round(statistics.median(values), 1), "p75": round(p75, 1)}


def census(prs: list[dict]) -> dict:
    rows = [summarize(pr) for pr in prs]
    names: dict[str, Counter] = defaultdict(Counter)
    for row in rows:
        seen = set()
        for c in row["checks"]:
            tally = names[c["key"]]
            if c["key"] not in seen:
                tally["prs"] += 1
                seen.add(c["key"])
            if c["conclusion"] == "SKIPPED":
                tally["skipped"] += 1
            elif c["conclusion"] in FAILED:
                tally["failed"] += 1
            elif c["conclusion"] not in NOT_RAN and c["started"] is not None:
                tally["ran"] += 1
            else:
                tally["other"] += 1
    table = sorted(
        ({"check": k, **{f: v.get(f, 0) for f in ("prs", "skipped", "ran", "failed", "other")}} for k, v in names.items()),
        key=lambda r: (-r["prs"], -r["skipped"], r["check"]),
    )
    aggregate = {
        "prs": len(rows),
        "total_checks": median_p75([r["total"] for r in rows]),
        "ran_checks": median_p75([r["ran"] for r in rows]),
        "skipped_checks": median_p75([r["skipped"] for r in rows]),
        "wall_minutes": median_p75([r["wall_minutes"] for r in rows]),
        "push_checks": median_p75([r["push_checks"] for r in rows]),
        "push_ran": median_p75([r["push_ran"] for r in rows]),
        "push_wall_minutes": median_p75([r["push_wall_minutes"] for r in rows]),
    }
    for r in rows:
        del r["checks"]
    return {"per_pr": rows, "aggregate": aggregate, "per_check": table}


def print_tables(result: dict, top: int) -> None:
    print("## Per pull request (last head commit)\n")
    print("| PR | total | SUCCESS | FAILURE | SKIPPED | NEUTRAL | CANCELLED | other | ran | wall min | push checks | push ran | push wall min |")
    print("|---|---|---|---|---|---|---|---|---|---|---|---|---|")
    for r in result["per_pr"]:
        c = r["conclusions"]
        print(
            f"| #{r['number']} | {r['total']} | {c['SUCCESS']} | {c['FAILURE']} | {c['SKIPPED']} | {c['NEUTRAL']} "
            f"| {c['CANCELLED']} | {c['other']} | {r['ran']} | {r['wall_minutes']} | {r['push_checks']} | {r['push_ran']} | {r['push_wall_minutes']} |"
        )
    print("\n## Per workflow, per pull request (total / ran / skipped / other)\n")
    for r in result["per_pr"]:
        parts = ", ".join(
            f"{w} {v.get('total', 0)}/{v.get('ran', 0)}/{v.get('skipped', 0)}/{v.get('other', 0)}" for w, v in r["per_workflow"].items()
        )
        print(f"- #{r['number']}: {parts}")
    a = result["aggregate"]
    print(f"\n## Aggregate over {a['prs']} pull requests\n")
    print("| measure | n | median | p75 |")
    print("|---|---|---|---|")
    for key in ("total_checks", "ran_checks", "skipped_checks", "wall_minutes"):
        print(f"| {key} | {a[key]['n']} | {a[key]['median']} | {a[key]['p75']} |")
    print(f"\n## Check names by appearances (top {top} of {len(result['per_check'])})\n")
    print("| check (workflow / name) | PRs | skipped | ran | failed | other |")
    print("|---|---|---|---|---|---|")
    for r in result["per_check"][:top]:
        print(f"| {r['check']} | {r['prs']} | {r['skipped']} | {r['ran']} | {r['failed']} | {r['other']} |")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("prs", nargs="*", type=int)
    parser.add_argument("--repo", default="manaflow-ai/cmux")
    parser.add_argument("--json", action="store_true", help="print one JSON object instead of tables")
    parser.add_argument("--save-raw", help="write what GitHub returned to this file")
    parser.add_argument("--from-raw", help="read a --save-raw file instead of calling GitHub")
    parser.add_argument("--top", type=int, default=60, help="rows of the per-check table (default 60)")
    parser.add_argument("--rest", action="store_true",
                        help="read over REST (3 calls a pull request) where GraphQL may not read completedAt")
    args = parser.parse_args()
    if args.from_raw:
        with open(args.from_raw) as fh:
            prs = json.load(fh)["prs"]
        queries = 0
    else:
        if not args.prs:
            parser.error("give PR numbers or --from-raw")
        prs, queries = fetch_rest(args.repo, args.prs, args.save_raw) if args.rest else fetch(args.repo, args.prs)
        if args.save_raw:
            with open(args.save_raw, "w") as fh:
                json.dump({"repo": args.repo, "prs": prs}, fh, indent=1)
    print(f"graphql queries sent: {queries}", file=sys.stderr)
    result = census(prs)
    if args.json:
        json.dump(result, sys.stdout, indent=1, default=str)
        print()
    else:
        print_tables(result, args.top)
    return 0


if __name__ == "__main__":
    sys.exit(main())
