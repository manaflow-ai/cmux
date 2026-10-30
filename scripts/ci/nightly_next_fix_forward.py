#!/usr/bin/env python3
"""Start the fix-forward after a cmux NEXT feed pull (nightly-next-rollback.yml).

A pull keeps the bad build from spreading, but Sparkle never moves a Mac
down, so Macs already on it stay there until a higher, fixed build ships.
This step asks for that build at once (train design, leo-workspace#624, 1.6):

  run --repo R --pulled "B1 B2 ..." --serving S --reason TEXT
      [--train-ref REF] [--dry-run]

1. Resolve the commits: a nightly-next build number is `<run id><attempt, 2
   digits>`, and that run's head is the build's commit on branch nightly-next.
   The first pulled build (the oldest) is the first bad one.
2. Name the suspect car: the newest change in the first bad build. Its head
   commit is a feat-cmux-next commit, or a train commit whose second parent is
   one; the change is that commit's pull request, or the push it came in.
3. If `.github/workflows/nightly-next-train.yml` on --train-ref (default
   feat-cmux-next) declares a `pulled_build` dispatch input, dispatch a train
   with the suspect quarantined. It is given only the inputs it declares, from
   this contract:
       pulled_build  first bad build (digits)
       good_build    the build the feed now serves (digits)
       quarantine    the suspect commit (40 hex)
       reason        why the build was pulled
   The train decides the rest (base = the good build, the quarantine rejoins
   once a fix lands).
4. Otherwise (no train yet, or it cannot fix forward), open or comment on one
   `nightly-next fix-forward needed` issue that names the range, the suspect
   and its owner, and how to fix forward by hand.

Prints a JSON summary. Exit 0 when the train was dispatched or the issue
written, 1 otherwise. Uses `gh` with GH_TOKEN (actions: write, issues: write,
contents: read).
"""

from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
from typing import Callable

TRAIN_WORKFLOW = ".github/workflows/nightly-next-train.yml"
TRAIN_INPUTS = ("pulled_build", "good_build", "quarantine", "reason")
ISSUE_TITLE = "nightly-next fix-forward needed"
SHA = re.compile(r"^[0-9a-f]{40}$")
# The events of a nightly.yml run that publishes (find-nightly-next-recovery.py).
PUBLISHED_EVENTS = {"push", "schedule", "workflow_dispatch"}

Api = Callable[..., object]


def gh_api(path: str, method: str = "GET", fields: dict[str, str] | None = None, raw: bool = False) -> object:
    """`gh api`; a GET's fields go in the query string. raw returns the text."""
    cmd = ["gh", "api", "-X", method, path]
    if raw:
        cmd += ["-H", "Accept: application/vnd.github.raw"]
    for key, value in (fields or {}).items():
        cmd += ["-f", f"{key}={value}"]
    out = subprocess.run(cmd, check=True, capture_output=True, text=True).stdout
    if raw:
        return out
    return json.loads(out) if out.strip() else None


def build_run(build: str) -> str:
    if not build.isdigit() or len(build) < 3:
        raise ValueError(f"build {build!r} is not a nightly-next build number")
    return str(int(build[:-2]))


def build_commit(api: Api, repo: str, build: str) -> str | None:
    """The nightly-next commit a build was made from, or None when its run is
    not a nightly-next run of this repository (a Linux-writer build).

    A fork's pull_request run on a branch named nightly-next reports the same
    head_branch with the fork's commit, so the run must also be a publishing
    event whose head is this repository (as find-nightly-next-recovery.py)."""
    try:
        run = api(f"repos/{repo}/actions/runs/{build_run(build)}")
    except Exception:  # noqa: BLE001 - an unknown run is a build we can't place
        return None
    if not isinstance(run, dict) or run.get("head_branch") != "nightly-next":
        return None
    if run.get("event") not in PUBLISHED_EVENTS:
        return None
    if ((run.get("head_repository") or {}).get("full_name") or "").lower() != repo.lower():
        return None
    sha = run.get("head_sha", "")
    return sha if SHA.match(sha) else None


def suspect(api: Api, repo: str, commit: str) -> dict:
    """The newest car in a build: its feat-cmux-next commit, PR and owner."""
    info = api(f"repos/{repo}/commits/{commit}")
    parents = [p["sha"] for p in info.get("parents", [])]  # type: ignore[union-attr]
    # A train commit (two parents) carries feat-cmux-next as its second parent.
    car = parents[1] if len(parents) == 2 else commit
    if car != commit:
        info = api(f"repos/{repo}/commits/{car}")
    author = ((info.get("author") or {}).get("login")  # type: ignore[union-attr]
              or ((info.get("commit") or {}).get("author") or {}).get("name", ""))  # type: ignore[union-attr]
    pulls = api(f"repos/{repo}/commits/{car}/pulls")
    pr = next((p for p in pulls or [] if p.get("merged_at")), None)  # type: ignore[union-attr]
    subject = ((info.get("commit") or {}).get("message") or "").splitlines()[0:1]  # type: ignore[union-attr]
    return {
        "sha": car,
        "subject": subject[0] if subject else "",
        "pr": pr["number"] if pr else None,
        "owner": (pr["user"]["login"] if pr else author) or "",
    }


def declared_inputs(workflow_text: str) -> set[str]:
    """The workflow_dispatch input names, read by indentation (no YAML lib)."""
    names: set[str] = set()
    lines = workflow_text.splitlines()
    for i, line in enumerate(lines):
        if re.match(r"^\s*workflow_dispatch:\s*$", line):
            base = len(line) - len(line.lstrip())
            j = i + 1
            while j < len(lines):
                cur = lines[j]
                if cur.strip() and not cur.lstrip().startswith("#"):
                    indent = len(cur) - len(cur.lstrip())
                    if indent <= base:
                        break
                    if cur.strip() == "inputs:":
                        inner = indent
                        k = j + 1
                        child = None
                        while k < len(lines):
                            sub = lines[k]
                            if sub.strip() and not sub.lstrip().startswith("#"):
                                ind = len(sub) - len(sub.lstrip())
                                if ind <= inner:
                                    break
                                child = ind if child is None else child
                                m = re.match(r"^\s*([A-Za-z_][A-Za-z0-9_-]*):", sub)
                                if ind == child and m:
                                    names.add(m.group(1))
                            k += 1
                        return names
                j += 1
    return names


def train_inputs(api: Api, repo: str, ref: str) -> set[str] | None:
    try:
        meta = api(f"repos/{repo}/contents/{TRAIN_WORKFLOW}?ref={ref}", raw=True)
    except Exception:  # noqa: BLE001 - no file there
        return None
    text = meta if isinstance(meta, str) else ""
    return declared_inputs(text) if text else None


def issue_body(plan: dict, run_url: str, why_no_train: str) -> str:
    s = plan.get("suspect") or {}
    who = f"@{s['owner']}" if s.get("owner") else "unknown"
    car = (f"#{s['pr']}" if s.get("pr") else (s.get("sha", "")[:12] or "unknown"))
    rng = (f"https://github.com/{plan['repo']}/compare/{plan['good_commit']}...{plan['bad_commit']}"
           if plan.get("good_commit") and plan.get("bad_commit") else "unknown (a build without a nightly-next run)")
    return "\n".join([
        f"cmux NEXT build {plan['pulled_build']} was pulled off the feed: {plan['reason']}",
        f"Run: {run_url}",
        "",
        f"The feed serves build {plan['good_build']}. Macs already on the pulled build keep it until a higher build ships.",
        f"- Changes in the pulled build: {rng}",
        f"- Newest change (the suspect): {car} {s.get('subject', '')} (owner {who})",
        "",
        f"No fix-forward train started: {why_no_train}.",
        "Fix forward: revert or fix the suspect on feat-cmux-next; the tick promotes it and the new, higher build moves every Mac.",
    ])


def run(api: Api, repo: str, pulled: list[str], serving: str, reason: str, train_ref: str,
        run_url: str, dry_run: bool) -> dict:
    if not pulled or not all(b.isdigit() for b in pulled) or not serving.isdigit():
        raise ValueError(f"need pulled builds and a serving build, got {pulled!r} / {serving!r}")
    first_bad = min(pulled, key=int)
    plan: dict = {
        "repo": repo, "reason": reason, "pulled_build": first_bad, "good_build": serving,
        "good_commit": build_commit(api, repo, serving), "bad_commit": build_commit(api, repo, first_bad),
        "suspect": None, "action": None,
    }
    if plan["bad_commit"]:
        plan["suspect"] = suspect(api, repo, plan["bad_commit"])
    declared = train_inputs(api, repo, train_ref)
    if declared is None:
        why = f"{TRAIN_WORKFLOW} is not on {train_ref} yet"
    elif "pulled_build" not in declared:
        why = f"{TRAIN_WORKFLOW} on {train_ref} has no pulled_build input"
    elif not plan["suspect"]:
        why = f"build {first_bad} has no nightly-next run here, so no suspect car"
    else:
        why = ""
    if not why:
        values = {"pulled_build": first_bad, "good_build": serving,
                  "quarantine": plan["suspect"]["sha"], "reason": reason[:900]}
        fields = {"ref": train_ref, **{f"inputs[{k}]": v for k, v in values.items() if k in declared}}
        plan["action"] = {"dispatch": TRAIN_WORKFLOW, "ref": train_ref,
                          "inputs": {k: v for k, v in values.items() if k in declared}}
        if not dry_run:
            api(f"repos/{repo}/actions/workflows/nightly-next-train.yml/dispatches", method="POST", fields=fields)
        return plan
    body = issue_body(plan, run_url, why)
    plan["action"] = {"issue": ISSUE_TITLE, "why": why}
    if dry_run:
        plan["action"]["body"] = body
        return plan
    found = api("search/issues", fields={"q": f'repo:{repo} is:issue is:open in:title "{ISSUE_TITLE}"'})
    issue = next((i for i in (found or {}).get("items", []) if i.get("title") == ISSUE_TITLE), None)  # type: ignore[union-attr]
    if issue:
        api(f"repos/{repo}/issues/{issue['number']}/comments", method="POST", fields={"body": body})
        plan["action"]["number"] = issue["number"]
    else:
        made = api(f"repos/{repo}/issues", method="POST", fields={"title": ISSUE_TITLE, "body": body})
        plan["action"]["number"] = (made or {}).get("number")  # type: ignore[union-attr]
    return plan


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="command", required=True)
    r = sub.add_parser("run")
    r.add_argument("--repo", required=True)
    r.add_argument("--pulled", required=True, help="space-separated pulled builds")
    r.add_argument("--serving", required=True)
    r.add_argument("--reason", required=True)
    r.add_argument("--train-ref", default="feat-cmux-next")
    r.add_argument("--run-url", default="")
    r.add_argument("--dry-run", action="store_true")
    args = parser.parse_args(argv)
    try:
        plan = run(gh_api, args.repo, args.pulled.split(), args.serving, args.reason,
                   args.train_ref or "feat-cmux-next", args.run_url, args.dry_run)
    except (ValueError, subprocess.CalledProcessError) as err:
        detail = getattr(err, "stderr", "") or ""
        print(f"::error title=nightly-next fix-forward::{err} {detail}".strip(), file=sys.stderr)
        return 1
    print(json.dumps(plan, sort_keys=True))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
