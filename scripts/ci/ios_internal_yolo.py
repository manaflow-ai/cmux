#!/usr/bin/env python3
"""iPhone YOLO: a cmux INTERNAL TestFlight build of feat-cmux-next plus a named list of pull requests.

Design: docs/design/ios-dev-channels.md in cmuxterm-hq (step 2, "iPhone YOLO"). Same app, same signing path as the
nightly INTERNAL build (ios-internal-nightly.yml on rc/cnx-ios-builder, scripts/ci/ios_ci_profiles.py): no new Apple
setup. The next nightly INTERNAL build replaces it on the phone.

Which PRs: every open PR labelled `ios-yolo`, or the list a person dispatches (ios-internal-yolo.yml). Each is merged
in number order onto the feat-cmux-next head; one that conflicts is left out and told so. The stack is pushed to
`ios-yolo/<UTC stamp>` (kept YOLO_KEEP so the nightly plan can tell its runs from nightlies), then the INTERNAL
builder is dispatched with that commit and the feat-cmux-next head as base, so TestFlight's "What to Test" lists
exactly the stacked PRs and its first line names them.

  ios_internal_yolo.py run [--prs "N M ..."] [--dry-run]   (GitHub Actions: needs GH_TOKEN, a full clone)

Only PRs from this repository's own branches: the build is signed with the team's distribution certificate.
"""
from __future__ import annotations

import argparse
import dataclasses
import datetime as dt
import json
import os
import re
import subprocess
import sys

REPO = os.environ.get("GITHUB_REPOSITORY", "manaflow-ai/cmux")
BASE = "feat-cmux-next"
LABEL = "ios-yolo"
PREFIX = "ios-yolo/"
BUILDER_WORKFLOW = "ios-internal-nightly.yml"
BUILDER_BRANCH = "rc/cnx-ios-builder"
YOLO_KEEP = dt.timedelta(days=14)
MERGE_SUBJECT = "ios-yolo: merge #{number}"
MAX_PRS = 20


@dataclasses.dataclass
class PullRequest:
    number: int
    title: str
    sha: str
    cross_repo: bool = False
    state: str = "OPEN"


@dataclasses.dataclass
class Stack:
    base: str
    head: str = ""
    included: list[PullRequest] = dataclasses.field(default_factory=list)
    dropped: list[tuple[PullRequest, str]] = dataclasses.field(default_factory=list)


# ---- pure logic (tests/test_ios_internal_yolo.py) ----

def parse_numbers(text: str) -> list[int]:
    """'#12, 34 56' -> [12, 34, 56]; anything else in the list is an error."""
    out = []
    for word in re.split(r"[\s,]+", text.strip()):
        if not word:
            continue
        m = re.fullmatch(r"#?(\d+)", word)
        if not m:
            raise ValueError(f"not a PR number: {word!r}")
        if int(m.group(1)) not in out:
            out.append(int(m.group(1)))
    return out


def choose(prs: list[PullRequest]) -> tuple[list[PullRequest], list[tuple[PullRequest, str]]]:
    """The PRs to stack, in number order, and the ones refused with why."""
    take, refused = [], []
    for pr in sorted(prs, key=lambda p: p.number):
        if pr.state != "OPEN":
            refused.append((pr, f"is {pr.state.lower()}"))
        elif pr.cross_repo:
            refused.append((pr, "is from a fork; a YOLO build signs only this repository's branches"))
        elif len(take) >= MAX_PRS:
            refused.append((pr, f"is past the first {MAX_PRS}"))
        else:
            take.append(pr)
    return take, refused


def branch_name(now: dt.datetime) -> str:
    return PREFIX + now.astimezone(dt.timezone.utc).strftime("%Y%m%dT%H%M%SZ")


def expired(ref: str, now: dt.datetime, keep: dt.timedelta = YOLO_KEEP) -> bool:
    """An ios-yolo/<stamp> branch older than keep; a name this script did not make is never expired."""
    m = re.fullmatch(r"(?:refs/heads/)?" + re.escape(PREFIX) + r"(\d{8}T\d{6}Z)", ref)
    if not m:
        return False
    made = dt.datetime.strptime(m.group(1), "%Y%m%dT%H%M%SZ").replace(tzinfo=dt.timezone.utc)
    return now - made > keep


def summary(stack: Stack, branch: str, dispatched: bool, refused: list[tuple[PullRequest, str]]) -> str:
    lines = ["## iPhone YOLO build", ""]
    if stack.included:
        lines.append(f"`{BASE}` {stack.base[:12]} + " + " ".join(f"#{p.number}" for p in stack.included)
                     + f" = `{stack.head[:12]}` on `{branch}`")
        lines.append("")
        lines += [f"- #{p.number} {p.title}" for p in stack.included]
    else:
        lines.append("Nothing to build: no PR stacked.")
    for pr, why in [*refused, *stack.dropped]:
        lines.append(f"- left out #{pr.number}: {why}")
    lines.append("")
    lines.append("Dispatched to cmux INTERNAL; TestFlight installs it, and the next nightly INTERNAL build replaces it."
                 if dispatched else "Not dispatched.")
    return "\n".join(lines) + "\n"


# ---- git ----

def git(*args: str, check: bool = True, input_text: str | None = None) -> subprocess.CompletedProcess:
    return subprocess.run(["git", *args], capture_output=True, text=True, check=check, input=input_text)


def build_stack(base: str, prs: list[PullRequest]) -> Stack:
    """Merge prs in order onto base in the current clone (detached); a PR that conflicts is left out."""
    git("checkout", "--quiet", "--force", "--detach", base)
    stack = Stack(base=base)
    for pr in prs:
        merged = git("-c", "user.name=cmux iPhone YOLO", "-c", "user.email=noreply@cmux.dev",
                     "merge", "--no-ff", "--no-edit", "-m", MERGE_SUBJECT.format(number=pr.number),
                     "-m", pr.title, pr.sha, check=False)
        if merged.returncode != 0:
            conflicted = git("diff", "--name-only", "--diff-filter=U", check=False).stdout.split()
            git("merge", "--abort", check=False)
            why = ("conflicts with feat-cmux-next or an earlier PR in the stack"
                   + (f" ({', '.join(conflicted[:5])})" if conflicted else ""))
            stack.dropped.append((pr, why))
            continue
        stack.included.append(pr)
    stack.head = git("rev-parse", "HEAD").stdout.strip()
    return stack


# ---- GitHub ----

def gh(*args: str, input_text: str | None = None) -> str:
    return subprocess.run(["gh", *args], capture_output=True, text=True, check=True, input=input_text).stdout


PR_FIELDS = "number title headRefOid isCrossRepository state"


def read_prs(numbers: list[int] | None) -> list[PullRequest]:
    owner, name = REPO.split("/")
    if numbers is None:
        query = ("query($q:String!){search(query:$q,type:ISSUE,first:50){nodes{... on PullRequest{%s}}}}" % PR_FIELDS)
        data = json.loads(gh("api", "graphql", "-f", f"query={query}",
                             "-f", f"q=repo:{REPO} is:pr is:open label:{LABEL} base:{BASE}"))
        nodes = data["data"]["search"]["nodes"]
    else:
        nodes = []
        for n in numbers:
            query = ("query($o:String!,$r:String!,$n:Int!){repository(owner:$o,name:$r){pullRequest(number:$n){%s}}}"
                     % PR_FIELDS)
            data = json.loads(gh("api", "graphql", "-f", f"query={query}", "-f", f"o={owner}", "-f", f"r={name}",
                                 "-F", f"n={n}"))
            node = data["data"]["repository"]["pullRequest"]
            if node is None:
                raise SystemExit(f"yolo: #{n} is not a pull request in {REPO}")
            nodes.append(node)
    return [PullRequest(number=n["number"], title=n["title"], sha=n["headRefOid"],
                        cross_repo=bool(n["isCrossRepository"]), state=n["state"]) for n in nodes if n]


def push_branch(branch: str, base: str, head: str) -> None:
    """Create the branch at base through the API, then fast-forward it: a new branch pushed with the job token is
    compared with main's workflows and refused; created at base, the push carries only the stacked PRs
    (next_batch.py's push does the same)."""
    gh("api", "-X", "POST", f"repos/{REPO}/git/refs", "--input", "-",
       input_text=json.dumps({"ref": f"refs/heads/{branch}", "sha": base}))
    token = os.environ.get("GH_TOKEN", "")
    auth = []
    if token:
        import base64
        basic = base64.b64encode(f"x-access-token:{token}".encode()).decode()
        auth = ["-c", f"http.https://github.com/.extraheader=AUTHORIZATION: basic {basic}"]
    git(*auth, "push", "--quiet", "origin", f"{head}:refs/heads/{branch}")


def prune(now: dt.datetime) -> list[str]:
    try:
        refs = json.loads(gh("api", f"repos/{REPO}/git/matching-refs/heads/{PREFIX}"))
    except (subprocess.CalledProcessError, json.JSONDecodeError):
        return []
    gone = []
    for r in refs:
        ref = r.get("ref", "")
        if expired(ref, now):
            try:
                gh("api", "-X", "DELETE", f"repos/{REPO}/git/{ref}")
                gone.append(ref)
            except subprocess.CalledProcessError:
                pass
    return gone


def tell_dropped(dropped: list[tuple[PullRequest, str]], run_url: str) -> None:
    for pr, why in dropped:
        try:
            gh("pr", "comment", str(pr.number), "-R", REPO,
               "--body", f"iPhone YOLO build left this PR out: it {why}. Merge {BASE} into it and relabel "
                         f"`{LABEL}` (or dispatch the build again) to put it in. Run: {run_url}")
        except subprocess.CalledProcessError as error:
            print(f"yolo: could not comment on #{pr.number}: {error.stderr.strip()[-200:]}", file=sys.stderr)


def cmd_run(prs_text: str, dry_run: bool) -> int:
    numbers = parse_numbers(prs_text) if prs_text.strip() else None
    prs = read_prs(numbers)
    take, refused = choose(prs)
    git("fetch", "--quiet", "--no-tags", "origin", f"+refs/heads/{BASE}:refs/remotes/origin/{BASE}",
        *[f"+refs/pull/{p.number}/head:refs/ios-yolo/pr/{p.number}" for p in take])
    base = git("rev-parse", f"refs/remotes/origin/{BASE}").stdout.strip()
    stack = build_stack(base, take)
    now = dt.datetime.now(dt.timezone.utc)
    branch = branch_name(now)
    dispatched = False
    if stack.included and not dry_run:
        push_branch(branch, base, stack.head)
        gh("workflow", "run", BUILDER_WORKFLOW, "--repo", REPO, "--ref", BUILDER_BRANCH,
           "-f", f"sha={stack.head}", "-f", f"base={base}")
        dispatched = True
        prune(now)
    run_url = f"{os.environ.get('GITHUB_SERVER_URL', 'https://github.com')}/{REPO}/actions/runs/" \
              f"{os.environ.get('GITHUB_RUN_ID', '0')}"
    if not dry_run:
        tell_dropped(stack.dropped, run_url)
    text = summary(stack, branch, dispatched, refused)
    print(text)
    if path := os.environ.get("GITHUB_STEP_SUMMARY"):
        with open(path, "a") as fh:
            fh.write(text)
    return 0 if stack.included or dry_run else 1


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="cmd", required=True)
    r = sub.add_parser("run")
    r.add_argument("--prs", default="", help="PR numbers; empty takes every open PR labelled ios-yolo")
    r.add_argument("--dry-run", action="store_true", help="stack only: no push, dispatch or comment")
    args = parser.parse_args(argv)
    return cmd_run(args.prs, args.dry_run)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
