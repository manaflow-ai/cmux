#!/usr/bin/env python3
"""Evidence required before --main-fix may waive an existing Swift test failure.

Run via scripts/gh-merge-green. Missing, skipped, stale and unparseable evidence
refuses the merge. This exception currently has a contract only for cmux-next.
"""
from __future__ import annotations

import argparse
from collections import deque
import json
import os
import re
import subprocess
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import gh_pages  # noqa: E402

RELEASE = "cmux-next Release compile (Xcode 26)"
DEBUG = "cmux app scheme compile (Debug)"
SWIFT = "cmux-next swift test"
BUILDS = {RELEASE: "Release compile", DEBUG: "Compile the cmux scheme", SWIFT: "Build package and tests"}
TEST_STEPS = {
    "Regenerate action surface export",
    "Run package tests (excluding control deadline and WebKit driver tests)",
    "Run package tests (excluding control deadline, WebKit driver and attach stress tests)",
    "Run package tests (selected targets; control deadline, WebKit driver and attach stress tests run below)",
    "Run control package tests", "Run WebKit driver package tests", "Run attach driver stress tests",
}
ISSUE = re.compile(r"✘ Test (.+?) recorded an issue at ([^:]+\.swift):\d+:\d+: (.+)")
SUMMARY = re.compile(r"✘ Test run with .* failed .* with (\d+) issues?\.")
MARKERS = re.compile(r"^\+(?:<<<<<<<|>>>>>>>|=======$)", re.MULTILINE)
# A cmux-next swift test job log reached about 40 MB on 2026-11-01 (#28391), past the old 32 MiB cap, so
# no such red could be compared with the base. Output goes to a temporary file, not memory, until read.
MAX_OUTPUT = 256 * 1024 * 1024
MAX_ANCESTOR_DEPTH = 100
MAX_ANCESTOR_NODES = 500
PATH_FILTERED_PREFIXES = ("docs/", "plans/", "design/")
# A red that refuses the exception. For the newest check run of a name, every one of these: that is the verdict for
# the name and nothing else speaks for it. For an older same-named sibling -- another workflow's job of that name, or
# an earlier run of the same workflow (check_runs_at) -- only the two that are a verdict a job actually reached.
# `cancelled` and `stale` are what concurrency does to a superseded run, and a `startup_failure` attempt ran no job
# at all, so none of them is a result anybody must explain. (Only a sibling is read that way. check_runs_at keeps the
# highest id per check suite and reads no conclusion, so a `startup_failure` that is the newest of its name is still
# that name's verdict and still refuses.) Reading them as reds
# would refuse nearly every real head: 8375182a4233 had three runs of each workflow, and three names whose newest was
# green over a `cancelled` sibling (`language-boundaries`, `pr-capture-check, ...`, `risk evidence`).
VERDICT_REDS = {"failure", "timed_out"}
ALL_REDS = VERDICT_REDS | {"cancelled", "action_required", "startup_failure", "stale"}


class Refused(RuntimeError):
    """Evidence is insufficient to merge."""


class Unread(Refused):
    """A read that never happened: the request passed its deadline, its answer was over the size cap, or `gh` itself
    failed. It is not a verdict on anything -- nothing was compared -- so a caller that judges a red must retry rather
    than record a refusal. A Refused, so gh-merge-green keeps refusing to merge on one (`not green:`, exit 1); callers
    that can tell them apart catch Unread first (scripts/ci/base_red_excuse.py's UnreadRead, exit 3, which land-judge
    reads as "not judged, a retry" instead of red_not_excused)."""


class BrokerRefused(Refused):
    """A read the lane-gh broker refused for its shape: a GraphQL root field or field outside the broker's allowlist
    (cmuxterm-hq tools/lane-gh-broker/parts/44-calls-graphql.py GRAPHQL_ROOT_FIELDS, GRAPHQL_FIELDS). The broker
    refuses the same query on every call, so it is neither a verdict on a red nor a retry: it is this tool's bug, and
    the fix is the query, never the allowlist (that is security). Before this it was an Unread, which base_red_excuse.py
    exits 3 on and land-judge reads as a rate limit: hq#30852 was refused "quota: not judged, retry after 02:24Z
    (reset)" twice on 2026-11-27 over SUITE_CHECKS_QUERY's root `nodes`, and every retry after the reset was refused
    the same way. A Refused, so gh-merge-green keeps refusing to merge on one; base_red_excuse.py catches it first
    (BrokerRefusedRead, exit 4: a tool error that names the fix)."""


# The broker's guard refusal as lane-gh prints it ("gh: lane-gh call graphql OWNER/REPO: refused: graphql: root field
# nodes is refused ..."). Every `graphql:` refusal of graphql_check is about the query's shape (a root field, a field,
# a fragment, a missing repo), never a quota, so none is cleared by a retry. A broker quota or latch refusal does not
# read "refused: graphql: " and stays an Unread.
BROKER_REFUSED = re.compile(r"\blane-gh call graphql \S+: refused: graphql: [^\n]*")
BROKER_REFUSED_LEAD = "the lane-gh broker refuses this query on every call (no retry clears it): "
BROKER_REFUSED_FIX = ("fix the query, not the broker: read it under an allowed root field (repository naming the "
                      "call's repo, search type: ISSUE, rateLimit) and allowed fields (cmuxterm-hq "
                      "tools/lane-gh-broker/graphql-allowlist.json), or with a REST GET; the allowlist is security "
                      "and is never widened for this")


def broker_refusal(stderr: str) -> str | None:
    """The broker's guard refusal in gh's STDERR (BROKER_REFUSED), or None when it holds none."""
    found = BROKER_REFUSED.search(stderr or "")
    return found.group(0).strip() if found else None


def read_name(args: list[str]) -> str:
    """The read, short enough to print in a refusal. `gh api <route>` is that route; anything else is its words,
    capped at 200 characters -- `run view <run> --repo R --job <job> --log`, which is the read most likely to be
    the slow one. A GraphQL body is compressed to its operation name: `-f query=...` is thousands of characters and
    every caller sends the same handful of queries, so the name alone identifies it.
    Without this a timeout said only "GitHub evidence request exceeded 90 seconds", so which of the ~60 reads
    base_red_excuse makes had spent the 90 s was a guess (leo-workspace#9276, #9153, #8643, 2026-11-24)."""
    if len(args) >= 2 and args[0] == "api" and args[1] != "graphql" and not args[1].startswith("-"):
        return f"gh api {args[1][:200]}"
    kept = []
    for word in args:
        if word in ("-f", "--field", "-F", "--raw-field"):
            continue  # the flag itself says nothing; its value is kept below
        if word.startswith("query="):
            found = re.search(r"\b(?:query|mutation)\s+(\w+)", word)
            kept.append(f"query={found.group(1)}" if found else "query=...")
            continue
        kept.append(word)
    return ("gh " + " ".join(kept))[:200]


class GitHub:
    def run(self, args: list[str], *, repo: str | None = None) -> str:
        # Disk and memory are bounded per command; neither logs nor receipts are
        # kept. A long API call has a deadline instead of an observation loop.
        with tempfile.TemporaryFile() as output, tempfile.TemporaryFile() as errors:
            env = {**os.environ, "GH_REPO": repo} if repo else None
            process = subprocess.Popen(["gh", *args], stdout=output, stderr=errors, env=env)
            try:
                process.wait(timeout=90)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait()
                raise Unread(f"GitHub evidence request exceeded 90 seconds: {read_name(args)}") from None
            if output.tell() > MAX_OUTPUT or errors.tell() > MAX_OUTPUT:
                raise Unread(f"GitHub evidence exceeds the {MAX_OUTPUT // (1024 * 1024)} MiB limit: "
                             f"{read_name(args)}")
            output.seek(0)
            errors.seek(0)
            if process.returncode:
                said = errors.read(2000).decode(errors="replace")
                if (refused := broker_refusal(said)) is not None:
                    raise BrokerRefused(f"{BROKER_REFUSED_LEAD}{read_name(args)}: {refused}; {BROKER_REFUSED_FIX}")
                raise Unread(f"GitHub evidence request failed: {read_name(args)}: " + said)
            return output.read().decode(errors="replace")

    def json(self, route: str, *, paginate: bool = False, per_page: int = gh_pages.PER_PAGE):
        if not paginate:
            return json.loads(self.run(["api", route]))
        # The raw pages, as `--slurp` gave them, one bounded call each (scripts/ci/gh_pages.py).
        try:
            return gh_pages.pages(lambda url: json.loads(self.run(["api", url])), route, per_page=per_page)
        except gh_pages.PageCapError as error:
            raise Unread(str(error)) from None

    def log(self, repo: str, job: dict) -> str:
        return self.run(["run", "view", str(job["run_id"]), "--repo", repo,
                         "--job", str(job["id"]), "--log"])


def check_runs_at(repo: str, sha: str, github: GitHub) -> dict:
    """Every check run of each name on SHA, newest first: one per check suite, its last real attempt. Every attempt is
    read (filter=all), since GitHub's default lists only each check suite's newest attempt, and one that ended in
    startup_failure ran no jobs, so a red before it vanished from that list (cmux#35906, 2026-11-05). Such an attempt
    is no result: the newest check run of a name is the last attempt that ran it, red or green.
    A name is several check runs whenever several workflows have a job of that name -- three were named `tests` at
    hq#17005's head -- so they are kept apart by check suite, the run each belongs to (base_red_excuse's named_check
    tells them apart by its workflow). Keying by name alone kept the highest id and read the name as that one check run, so a
    caller naming another of them was answered about a check it had not asked about (2026-11-21)."""
    newest: dict[tuple, dict] = {}
    for page in github.json(f"repos/{repo}/commits/{sha}/check-runs?filter=all&per_page=100", paginate=True):
        for check in page["check_runs"]:
            # A third-party app cannot provide compile or test evidence.
            if check.get("app", {}).get("slug") != "github-actions":
                continue
            key = (check["name"], (check.get("check_suite") or {}).get("id"))
            if check["id"] > newest.get(key, {}).get("id", -1):
                newest[key] = check
    by_name: dict[str, list[dict]] = {}
    for check in sorted(newest.values(), key=lambda found: found["id"], reverse=True):
        by_name.setdefault(check["name"], []).append(check)
    return by_name


def latest_checks(repo: str, sha: str, github: GitHub) -> dict:
    """The newest check run of each name on SHA (check_runs_at), for a caller that asks only that. A caller that must
    not answer about a sibling of the name reads check_runs_at itself."""
    return {name: found[0] for name, found in check_runs_at(repo, sha, github).items()}


def _parent_shas(repo: str, sha: str, github: GitHub) -> list[str]:
    """Return the parent SHAs GitHub reports for a commit."""
    commit = github.json(f"repos/{repo}/commits/{sha}")
    parents = commit.get("parents", []) if isinstance(commit, dict) else []
    return [parent["sha"] for parent in parents
            if isinstance(parent, dict) and isinstance(parent.get("sha"), str)]


def nearest_ancestor_check(repo: str, base: str, name: str, github: GitHub) -> tuple[str, dict, int] | None:
    """Find the closest parent with NAME evidence using bounded breadth-first search."""
    queue = deque((parent, 1) for parent in _parent_shas(repo, base, github))
    visited: set[str] = set()
    while queue and len(visited) < MAX_ANCESTOR_NODES:
        sha, distance = queue.popleft()
        if sha in visited or distance > MAX_ANCESTOR_DEPTH:
            continue
        visited.add(sha)
        checks = latest_checks(repo, sha, github)
        if name in checks:
            return sha, checks[name], distance
        queue.extend((parent, distance + 1) for parent in _parent_shas(repo, sha, github))
    return None


def path_filtered_intervening_changes(repo: str, ancestor: str, base: str, github: GitHub) -> list[str]:
    """Reject ancestor evidence when intervening paths could affect Swift tests."""
    comparison = github.json(f"repos/{repo}/compare/{ancestor}...{base}")
    files = comparison.get("files", []) if isinstance(comparison, dict) else []
    if len(files) >= 300:
        raise Refused("GitHub compare reached the 300-file limit; intervening changes are not fully verified")
    paths = []
    for file in files:
        if not isinstance(file, dict):
            continue
        for key in ("filename", "previous_filename"):
            if isinstance(file.get(key), str):
                paths.append(file[key])
    unsafe = [path for path in paths if not path.startswith(PATH_FILTERED_PREFIXES)]
    if unsafe:
        message = (
            f"Swift tests have not run on base {base}; ancestor evidence is unsafe because "
            f"intervening changes may affect the test ({', '.join(unsafe[:5])})"
        )
        raise Refused(message)
    return paths


def completed_success(item: dict) -> bool:
    return item.get("status") == "completed" and item.get("conclusion") == "success"


def job_for(repo: str, check: dict, sha: str, github: GitHub) -> dict:
    url = check.get("details_url", "")
    match = re.fullmatch(r"https://github\.com/" + re.escape(repo) + r"/actions/runs/(\d+)/job/(\d+)", url)
    if not match:
        raise Refused(f"{check['name']}: missing GitHub Actions job evidence")
    job = github.json(f"repos/{repo}/actions/jobs/{match[2]}")
    if job.get("head_sha") != sha or job.get("run_id") != int(match[1]) or job.get("name") != check["name"]:
        raise Refused(f"{check['name']}: job is not for the exact SHA {sha}")
    if job.get("status") != "completed" or check.get("status") != "completed":
        raise Refused(f"{check['name']}: job has not completed on {sha}")
    return job


def require_build(job: dict, name: str) -> None:
    matches = [step for step in job.get("steps", []) if step["name"] == name]
    if len(matches) != 1 or not completed_success(matches[0]):
        raise Refused(f"{name}: build step must succeed on the PR's own head")


def step_log(log: str, name: str) -> str:
    return "\n".join(parts[2] for line in log.splitlines()
                     if len(parts := line.split("\t", 2)) == 3 and parts[1] == name)


def failures(log: str, step: str) -> set[tuple[str, str, str]]:
    text = step_log(log, step)
    records = [line for line in text.splitlines() if "recorded an issue" in line]
    matches = [ISSUE.search(line) for line in records]
    summaries = SUMMARY.findall(text)
    if not records or not summaries or any(match is None for match in matches) or int(summaries[-1]) != len(records):
        raise Refused(f"{step}: cannot parse every failed test issue; no waiver")
    return {tuple(match.groups()) for match in matches}


def validate(repo: str, number: int, github: GitHub) -> str:
    pr = github.json(f"repos/{repo}/pulls/{number}")
    if pr.get("state") != "open":
        raise Refused("PR is not open")
    if pr.get("mergeable") is False:
        raise Refused("PR has merge conflicts")
    head, base = pr["head"]["sha"], pr["base"]["sha"]
    if pr["base"]["ref"] != "feat-cmux-next":
        raise Refused("--main-fix compile evidence is defined for feat-cmux-next only; use normal green merging for other bases")
    at_head = check_runs_at(repo, head, github)
    # The newest of each name for the build and web-validation reads below; the sweep over every failed check at the
    # end reads at_head itself, since a red whose same-named sibling in another workflow is newer and green must not
    # go unexplained -- this caller's whole job (hq#17005's class, in the one reader that grants the exception).
    # A sibling is held to VERDICT_REDS only, so a run concurrency superseded does not refuse a merge.
    checks = {name: found[0] for name, found in at_head.items()}
    jobs = {}
    audit = [f"--main-fix evidence for head `{head}`, base `{base}`:"]
    for name, build in BUILDS.items():
        if name not in checks:
            raise Refused(f"{name}: has not run on exact head {head}")
        # Tier routing skips the app scheme compile for a change that stays in
        # the CmuxNext package; the Release compile still builds all of it.
        if name == DEBUG and checks[name].get("status") == "completed" and checks[name].get("conclusion") == "skipped":
            audit.append(f"- {build}: skipped by tier routing (docs/ci/cmux-next-tiers.md).")
            continue
        job = jobs[name] = job_for(repo, checks[name], head, github)
        require_build(job, build)
        if name != SWIFT and not completed_success(job):
            raise Refused(f"{name}: compile job must succeed on the PR's own head")
        audit.append(f"- {build}: succeeded ([job]({checks[name]['details_url']})).")

    web_validation = checks.get("web-validation", {})
    if not completed_success(web_validation):
        raise Refused("web-validation must complete successfully on the exact head")

    swift = jobs[SWIFT]
    failed_steps = [step for step in swift["steps"] if step.get("conclusion") != "success"
                    and step.get("conclusion") != "skipped"]
    matched = False
    if not completed_success(swift):
        if swift.get("conclusion") != "failure" or not failed_steps:
            raise Refused("Swift test job did not finish with identifiable test failures")
        for step in failed_steps:
            if step["name"] not in TEST_STEPS or step.get("status") != "completed" or step.get("conclusion") != "failure":
                raise Refused(f"{step['name']}: non-test failure cannot be waived")
        base_checks = latest_checks(repo, base, github)
        base_check_sha = base
        base_reason = f"exact base `{base}`"
        if SWIFT not in base_checks:
            ancestor = nearest_ancestor_check(repo, base, SWIFT, github)
            if ancestor is None:
                raise Refused(f"Swift tests have not run on base {base} or any of its nearest {MAX_ANCESTOR_DEPTH} ancestors ({MAX_ANCESTOR_NODES} commit limit)")
            base_check_sha, base_checks[SWIFT], distance = ancestor
            intervening = path_filtered_intervening_changes(repo, base_check_sha, base, github)
            base_reason = (
                f"nearest ancestor `{base_check_sha}` ({distance} parent step"
                f"{'s' if distance != 1 else ''}) because the exact base `{base}`"
                f" has no `{SWIFT}` run and its intervening changes are path-filtered"
            )
            audit.append(
                f"- Base evidence: {base_reason} ({len(intervening)} path-filtered file"
                f"{'s' if len(intervening) != 1 else ''}); using its `{SWIFT}` job "
                f"([job]({base_checks[SWIFT]['details_url']}))."
            )
        base_job = job_for(repo, base_checks[SWIFT], base_check_sha, github)
        require_build(base_job, BUILDS[SWIFT])
        head_log = github.log(repo, swift)
        base_log = github.log(repo, base_job)
        for step in failed_steps:
            name = step["name"]
            base_step = next((step for step in base_job["steps"] if step["name"] == name), {})
            if base_step.get("conclusion") != "failure" or base_step.get("status") != "completed":
                raise Refused(f"{name}: failed tests not reproduced on {base_reason}")
            head_failures, base_failures = failures(head_log, name), failures(base_log, name)
            unmatched = head_failures - base_failures
            if unmatched:
                raise Refused(f"{name}: failures not reproduced on {base_reason}: {sorted(unmatched)!r}")
            for test, source, issue in sorted(head_failures):
                audit.append(f"- Matched base failure: `{source}` / `{test}`: {json.dumps(issue, ensure_ascii=False)} "
                             f"([head]({checks[SWIFT]['details_url']}), [base]({base_checks[SWIFT]['details_url']})).")
        matched = True
    # A completed ci-status failure may aggregate the proven Swift test red;
    # unrelated failures still refuse the exception.
    for name, found in at_head.items():
        for check in found:
            # The waiver the base matching earned belongs to the check run it examined -- the newest of the name --
            # and not to a sibling whose own job was never compared with the base.
            newest = check["id"] == found[0]["id"]
            if check.get("conclusion") not in (ALL_REDS if newest else VERDICT_REDS):
                continue
            if name == SWIFT and matched and newest:
                continue
            if name == "ci-status" and matched and newest and check.get("conclusion") == "failure":
                continue
            raise Refused(f"{name}: failed check has no same-base test match" if newest else
                          f"{name}: failed check has no same-base test match (check run {check['id']}, "
                          f"{check.get('conclusion')}, a same-named sibling of the newest {found[0]['id']})")
    status = checks.get("ci-status", {})
    if not completed_success(status) and not (matched and status.get("status") == "completed" and status.get("conclusion") == "failure"):
        raise Refused("ci-status must complete on the exact head")
    for page in github.json(f"repos/{repo}/pulls/{number}/files?per_page=100", paginate=True):
        for file in page:
            if MARKERS.search(file.get("patch", "")):
                raise Refused(f"conflict markers in {file['filename']}")
    return "\n".join(audit)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("ref", help="OWNER/REPO#NUMBER")
    parser.add_argument("--squash", action="store_true")
    parser.add_argument("--merge", action="store_true")
    parser.add_argument("--rebase", action="store_true")
    parser.add_argument("--check-only", action="store_true", help="print evidence without posting or merging")
    args = parser.parse_args(argv)
    match = re.fullmatch(r"([\w.-]+/[\w.-]+)#(\d+)", args.ref)
    if not match:
        parser.error("expected OWNER/REPO#NUMBER")
    repo, number = match[1], int(match[2])
    github = GitHub()
    try:
        before = github.json(f"repos/{repo}/pulls/{number}")
        audit = validate(repo, number, github)
        after = github.json(f"repos/{repo}/pulls/{number}")
        if before["head"]["sha"] != after["head"]["sha"] or before["base"]["sha"] != after["base"]["sha"] or after["state"] != "open":
            raise Refused("PR head or base moved while collecting evidence; retry")
        print(audit)
        if args.check_only:
            return 0
        with tempfile.TemporaryDirectory(prefix="merge-green-") as directory:
            body = Path(directory) / "audit.md"
            body.write_text(audit + "\n", encoding="utf-8")
            github.run(["pr", "comment", str(number), "--repo", repo, "--body-file", str(body)])
        posted = github.json(f"repos/{repo}/pulls/{number}")
        if posted.get("head", {}).get("sha") != after["head"]["sha"] or posted.get("state") != "open":
            raise Refused("PR head moved while posting the audit comment; retry")
        strategy = "--merge" if args.merge else "--rebase" if args.rebase else "--squash"
        github.run(["pr", "merge", str(number), "--repo", repo, "--match-head-commit", posted["head"]["sha"], strategy])
        return 0
    except (Refused, json.JSONDecodeError, KeyError) as error:
        print(f"not green: {error}\nrefusing to merge {args.ref}; wait with: glaeda-gh wait pr {args.ref}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
