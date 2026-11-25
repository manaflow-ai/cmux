#!/usr/bin/env python3
"""What share of cmux-next pull request heads could reuse a receipt: inputs unchanged since a head that passed.

The ceiling of receipt reuse for the PR verdict (goal ci-verdict-wall-100x, cmuxterm-hq): a head whose inputs a
passing run already verified can take that run's verdict in seconds (the 0.1-min "unchanged" floor). This counts how
many heads that is, so nobody has to guess whether narrowing a job's declared inputs would make its receipt hit.

Run it on any machine with `gh` and a cmux checkout (no fleet machine needed):

    python3 scripts/ci/receipt_reuse_share.py --repo-dir . [--newest 50] [--pages 10] [--json OUT]

It lists the newest `cmux-next.yml` pull_request runs (100 a page; GitHub stops at 1,000), fetches each head and
each run's merge commit (the run name carries it), and takes the newest run of each head. Over the newest
--newest non-bot heads whose run finished green or red, a head counts under a key when an earlier green run
(any pull request unless noted) had the same key:

  merge_tree    the merge commit's whole tree: what the jobs that key `**` (job_input_fingerprint.py) can reuse;
  head_tree     the head's own tree, same pull request (a re-push of the same tree, a "re-run all jobs");
  pr_delta      the change the merge commit makes to its base (`git diff-tree M^1 M`), same pull request: the
                pull request's own change is unchanged and only the base moved (a base merge with no conflict, a
                rebase, a revert of a revert). Reusing on it trusts the base to be verified on its own;
  docs_only     the head changes only docs/ or *.md since a green head of the same pull request;
  cargo_inputs  for the heads that reach `cmux-next fast tier (cargo)` (fast_tier_cargo_route.py), the merge tree's
                object ids at that job's sound input set: its route inputs plus every cmux-tui tree input
                (scripts/cmux-next/cmux-tui-tree-inputs.txt). The narrowest key that is still a function of what the
                job reads; cargo_delta is the same set under pr_delta's rule.

A merge commit GitHub no longer serves (refs/pull/N/merge moved on, and the object is gone) counts as a miss under
the merge keys. The window is what the 1,000 newest runs hold (about 4.5 h on 2026-11-24), so a pull request's
earlier green head older than that counts as missing: the shares are a lower bound by that much.

2026-11-24 (newest 50 heads, 08:42Z..09:38Z; 200 heads 06:51Z..09:38Z): merge_tree 1 of 50 (2%), pr_delta 7 of
50 (14%, 27 of 200), any key 7 of 50 (14%); half the heads (25 of 50, 106 of 200) are the first head of their pull
request with a finished run, and nothing of theirs could be reused. cargo_inputs 0 of 42 cargo heads, cargo_delta 1
of 42: base churn changes the job's sound input set between any two pushes. So p50 0.1 min is out of reach by
receipts alone: at most about 14 to 17% of heads are unchanged by any key.
"""
from __future__ import annotations

import argparse
import collections
import json
import os
import subprocess
import sys
from pathlib import Path

REPO = "manaflow-ai/cmux"
WORKFLOW = "cmux-next.yml"
FIELDS = ".workflow_runs[] | [.id, .head_sha, .head_branch, (.conclusion // \"none\"), .created_at, " \
         ".actor.login, (.pull_requests[0].number // \"\"), .display_title] | @tsv"


def git(root: str, *args: str) -> str | None:
    env = {**os.environ, "GIT_NO_LAZY_FETCH": "1"}
    result = subprocess.run(["git", "-C", root, *args], capture_output=True, text=True, env=env, timeout=300)
    return result.stdout.strip() if result.returncode == 0 else None


def list_runs(pages: int) -> list[dict]:
    runs = {}
    for page in range(1, pages + 1):
        out = subprocess.run(["gh", "api", f"repos/{REPO}/actions/workflows/{WORKFLOW}/runs?event=pull_request"
                              f"&per_page=100&page={page}", "--jq", FIELDS],
                             capture_output=True, text=True, timeout=120)
        if out.returncode != 0:
            print(f"page {page}: {out.stderr.strip()}", file=sys.stderr)
            break
        lines = [line for line in out.stdout.splitlines() if line]
        for line in lines:
            rid, head, branch, conclusion, created, actor, pr, title = line.split("\t")
            runs[rid] = {"id": rid, "head": head, "conclusion": conclusion, "created": created, "actor": actor,
                         "pr": pr or branch, "merge": title.rsplit(" ", 1)[-1]}
        if len(lines) < 100:
            break
    return sorted(runs.values(), key=lambda run: run["created"])


def fetch(root: str, shas: list[str]) -> None:
    missing = [sha for sha in sorted(set(shas)) if len(sha) == 40 and git(root, "cat-file", "-e", f"{sha}^{{commit}}") is None]
    for start in range(0, len(missing), 150):
        # A sha GitHub no longer serves fails the batch's fetch; retry the batch one at a time.
        batch = missing[start:start + 150]
        if git(root, "fetch", "-q", "--filter=blob:none", "origin", *batch) is None:
            for sha in batch:
                git(root, "fetch", "-q", "--filter=blob:none", "origin", sha)


def cargo_key_paths(root: str) -> tuple[list[str], list[str]] | None:
    sys.path.insert(0, str(Path(root) / "scripts" / "ci"))
    try:
        import fast_tier_cargo_route as route
        import job_input_fingerprint as fingerprint
    except Exception as error:  # noqa: BLE001 - the cargo keys are optional
        print(f"no cargo keys: {error}", file=sys.stderr)
        return None
    prefixes = route.inputs(Path(root)) or []
    paths = {prefix.rstrip("/") for prefix in prefixes} | fingerprint.tui_tree_inputs(root, "HEAD")
    paths |= {"cmux-tui", ".gitmodules", ".github/workflows/cmux-next.yml"}
    return prefixes, sorted(path for path in paths if not any(path.startswith(other + "/") for other in paths))


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--repo-dir", default=".")
    parser.add_argument("--newest", type=int, default=50)
    parser.add_argument("--pages", type=int, default=10)
    parser.add_argument("--json")
    args = parser.parse_args(argv)
    root = args.repo_dir
    runs = list_runs(args.pages)
    if not runs:
        print("no runs listed", file=sys.stderr)
        return 1
    fetch(root, [run["head"] for run in runs] + [run["merge"] for run in runs])
    for run in runs:
        merge = run["merge"]
        run["has_merge"] = git(root, "cat-file", "-e", f"{merge}^{{commit}}") is not None
        run["has_head"] = git(root, "cat-file", "-e", f"{run['head']}^{{commit}}") is not None
    cargo = cargo_key_paths(root)

    def changed(a: str, b: str, *paths: str) -> str | None:
        return git(root, "diff-tree", "-r", "--no-renames", a, b, *(("--", *paths) if paths else ()))

    def reaches_cargo(run: dict) -> bool:
        names = (changed(f"{run['merge']}^1", run["merge"]) or "").splitlines()
        return any(route_under(line.split("\t", 1)[-1], prefix) for line in names for prefix in cargo[0])

    def route_under(path: str, prefix: str) -> bool:
        return path.startswith(prefix) if prefix.endswith("/") else path == prefix

    def keys(run: dict) -> dict:
        found = {}
        if run["has_head"]:
            found["head_tree"] = git(root, "rev-parse", f"{run['head']}^{{tree}}")
        if run["has_merge"]:
            merge = run["merge"]
            found["merge_tree"] = git(root, "rev-parse", f"{merge}^{{tree}}")
            found["pr_delta"] = changed(f"{merge}^1", merge)
            if cargo and reaches_cargo(run):
                found["cargo_inputs"] = git(root, "ls-tree", "--full-tree", merge, "--", *cargo[1])
                found["cargo_delta"] = changed(f"{merge}^1", merge, *cargo[1])
        return found

    newest = {}
    for run in runs:
        newest[run["head"]] = run
    targets = [run for run in sorted(newest.values(), key=lambda run: run["created"])
               if not run["actor"].endswith("[bot]") and run["conclusion"] in ("success", "failure")][-args.newest:]
    target_ids = {run["id"] for run in targets}
    same_pr_keys = {"head_tree", "pr_delta", "cargo_delta"}
    green_any = collections.defaultdict(set)
    green_pr = collections.defaultdict(lambda: collections.defaultdict(set))
    green_heads = collections.defaultdict(list)
    rows = []
    for run in runs:
        found = keys(run) if (run["id"] in target_ids or run["conclusion"] == "success") else {}
        if run["id"] in target_ids:
            row = {"run": run["id"], "pr": run["pr"], "created": run["created"], "first_head": not green_heads[run["pr"]],
                   "cargo": "cargo_inputs" in found}
            for name, value in found.items():
                pool = green_pr[run["pr"]][name] if name in same_pr_keys else green_any[name]
                row[name] = value is not None and value in pool
            row["docs_only"] = run["has_head"] and any(
                all(path.startswith("docs/") or path.endswith(".md")
                    for path in (git(root, "diff-tree", "-r", "--name-only", earlier, run["head"]) or "x").splitlines())
                for earlier in green_heads[run["pr"]])
            row["any"] = any(row.get(name) for name in ("head_tree", "merge_tree", "pr_delta", "docs_only"))
            rows.append(row)
        if run["conclusion"] == "success":
            for name, value in found.items():
                (green_pr[run["pr"]][name] if name in same_pr_keys else green_any[name]).add(value)
            if run["has_head"]:
                green_heads[run["pr"]].append(run["head"])
    cargo_rows = [row for row in rows if row["cargo"]]
    summary = {"heads": len(rows), "window": [rows[0]["created"], rows[-1]["created"]] if rows else [],
               "runs_listed": len(runs), "oldest_run": runs[0]["created"],
               "first_head": sum(row["first_head"] for row in rows),
               "merge_unavailable": sum(1 for row in rows if "merge_tree" not in row),
               **{name: sum(1 for row in rows if row.get(name))
                  for name in ("merge_tree", "head_tree", "pr_delta", "docs_only", "any")},
               "cargo_heads": len(cargo_rows),
               **{name: sum(1 for row in cargo_rows if row.get(name)) for name in ("cargo_inputs", "cargo_delta")}}
    print(json.dumps(summary, indent=1))
    if args.json:
        Path(args.json).write_text(json.dumps({"summary": summary, "heads": rows}, indent=1) + "\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
