#!/usr/bin/env python3
"""Name the merged pull requests behind tests that newly fail on main.

main_full_suite.py keeps one issue open while main's full suite is red, but a
red run lists failing jobs, not what broke them, and nobody is told. This
reads a red full-suite run and finds its new failures: app-host tests the
shard ratchet reported as RATCHET_NEW_FAILURE (so not in the known-failures
catalog) that did not fail in the previous full-suite run whose app-host
shards all finished and graded every test.

Each new failure is attributed to the commits between the two runs' head
SHAs, mapped to the pull requests merged into main by those commits. One pull
request in the range is the suspect. With several, each is ranked by whether
its diff reaches the failing test's suite: 2 when it edits the suite
(test_impact.py), 1 when a changed app declaration or string is named by the
suite (reverse_test_impact.py), 0 otherwise. The top score names the
suspects; when every score is 0 the failure is left unattributed rather than
blaming the whole range.

`report` writes a "New since" markdown section for the tracking issue (read
by main_full_suite.py report --extra-section) and comments once on each
suspect pull request, idempotent through a hidden marker keyed on the pull
request and its failing test set, and once per commit range. A test tied between more than
MAX_PINGED_SUSPECTS pull requests is listed in the issue only. Nothing is
reverted or re-run here.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import subprocess
import sys
from collections.abc import Iterable, Mapping
from dataclasses import dataclass, field
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import main_full_suite as suite_run  # noqa: E402

APP_HOST_JOB_RE = re.compile(r"app-host unit tests \(\d+/\d+\)")
ANSI_RE = re.compile(r"\x1b\[[0-9;]*m")
# One ratchet verdict per line, after the runner's timestamp.
RATCHET_RE = re.compile(r"^(?:\S+Z )?RATCHET_NEW_FAILURE (\S+)\s*$")
RAN_CONCLUSIONS = frozenset({"success", "failure"})
# app_host_result_accounting.py closes every graded batch with one of these.
VERDICT_MARKERS = ("RATCHET_NEW_FAILURE ", "typed app-host run passed", "known-main failures tolerated")
# ...and prints one of these when a batch's tests did not all report, so a
# test that already failed may be missing from its RATCHET_NEW_FAILURE lines.
INCOMPLETE_MARKERS = (
    "incomplete app-host run:",
    "typed xcresult is incomplete",
    "typed xcresult contains zero Test Case nodes",
    "No typed xcresult test JSON found",
    "is not ratchetable",
    "selector matched zero built tests",
    "nonterminal or unknown result",
)
MARKER_PREFIX = "<!-- main-regression-attribution"
MARKER_RE = re.compile(r"<!-- main-regression-attribution pr=(\d+) tests=(\w+) range=(\S+) -->")
# Bounds on one report, so a long red streak cannot fan out into a comment storm.
MAX_RANKED_PRS = 40
MAX_COMMENTED_PRS = 5
# A test that ties more pull requests than this is listed in the issue but
# pings none of them: that is a guess, and slice 2's bisect should settle it.
MAX_PINGED_SUSPECTS = 3
# Earlier runs tried as the baseline before giving up on a comparison.
MAX_BASELINE_CANDIDATES = 8
MAX_LISTED_TESTS = 30


@dataclass
class PullRequest:
    number: int
    title: str
    url: str
    merge_sha: str
    author: str = ""
    # Suites the diff edits, and suites that name what the diff changes.
    edited_suites: set[str] = field(default_factory=set)
    reached_suites: set[str] = field(default_factory=set)


def ratchet_failures(log_text: str) -> set[str]:
    """Test ids one app-host job log reported as new against the catalog."""
    found = set()
    for raw in log_text.splitlines():
        match = RATCHET_RE.match(ANSI_RE.sub("", raw).strip())
        if match:
            found.add(match.group(1))
    return found


def shard_log_complete(log_text: str) -> bool:
    """True when a failed shard graded every batch, so its failures are the full set."""
    return any(text in log_text for text in VERDICT_MARKERS) and not any(
        text in log_text for text in INCOMPLETE_MARKERS
    )


def app_host_jobs(jobs: Iterable[Mapping[str, object]]) -> list[Mapping[str, object]]:
    return [job for job in jobs if APP_HOST_JOB_RE.search(str(job.get("name") or ""))]


def app_host_ran(jobs: Iterable[Mapping[str, object]]) -> bool:
    """True when every app-host shard finished, so its failures are a full picture."""
    shards = app_host_jobs(jobs)
    return bool(shards) and all(job.get("conclusion") in RAN_CONCLUSIONS for job in shards)


def earlier_tested_runs(
    runs: Iterable[Mapping[str, object]], current: Mapping[str, object], branch: str = "main",
) -> list[Mapping[str, object]]:
    """Completed green or red full-suite runs created before `current`, newest first."""
    created = str(current.get("created_at") or "")
    earlier = [
        run for run in runs
        if suite_run.is_main_full_suite_run(run, branch)
        and run.get("status") == "completed"
        and run.get("conclusion") in suite_run.TESTED_CONCLUSIONS
        and run.get("id") != current.get("id")
        and str(run.get("created_at") or "") < created
    ]
    earlier.sort(key=lambda run: str(run.get("created_at") or ""), reverse=True)
    return earlier


def new_failures(current: Mapping[str, list[str]], previous: set[str]) -> dict[str, list[str]]:
    """Failing test -> job URLs, for tests that did not fail in the previous run."""
    return {test: jobs for test, jobs in sorted(current.items()) if test not in previous}


def merged_prs(
    range_shas: Iterable[str], associated: Mapping[str, list[Mapping[str, object]]], branch: str = "main",
) -> tuple[list[PullRequest], list[str]]:
    """Pull requests merged into `branch` by a commit in the range, oldest first, and direct commits.

    A commit also lists open or unrelated pull requests that contain it, so a
    pull request counts only when its merge commit is itself in the range.
    """
    ordered = list(range_shas)
    in_range = set(ordered)
    found: dict[int, PullRequest] = {}
    covered: set[str] = set()
    for sha in ordered:
        for pr in associated.get(sha, []):
            merge_sha = str(((pr.get("mergeCommit") or {}) or {}).get("oid") or "")
            if pr.get("state") != "MERGED" or pr.get("baseRefName") != branch or merge_sha not in in_range:
                continue
            covered.add(sha)
            number = int(pr["number"])
            if number not in found:
                found[number] = PullRequest(
                    number=number,
                    title=str(pr.get("title") or ""),
                    url=str(pr.get("url") or ""),
                    merge_sha=merge_sha,
                    author=str(((pr.get("author") or {}) or {}).get("login") or ""),
                )
    merge_order = {sha: index for index, sha in enumerate(reversed(ordered))}
    prs = sorted(found.values(), key=lambda pr: merge_order.get(pr.merge_sha, 0))
    direct = [sha for sha in ordered if sha not in covered]
    return prs, direct


def suite_of(test: str) -> str:
    return test.split("/", 1)[0]


def score(test: str, pr: PullRequest) -> int:
    name = suite_of(test)
    if name in pr.edited_suites:
        return 2
    if name in pr.reached_suites:
        return 1
    return 0


def suspects_for(
    test: str, prs: list[PullRequest], direct: Iterable[str] = (),
) -> tuple[list[PullRequest], str]:
    """(suspects, how) for one failing test; no suspects when the range gives no signal."""
    if len(prs) == 1 and not list(direct):
        return prs, "only pull request in the range"
    if not prs:
        return [], "no merged pull request in the range"
    scored = [(score(test, pr), pr) for pr in prs]
    best = max((value for value, _ in scored), default=0)
    if best == 0:
        return [], "no pull request in the range reaches this suite"
    how = "edits the suite" if best == 2 else "changes code the suite names"
    return [pr for value, pr in scored if value == best], how


def tests_digest(tests: Iterable[str]) -> str:
    return hashlib.sha256("\n".join(sorted(tests)).encode()).hexdigest()[:16]


def commit_range(previous: Mapping[str, object], run: Mapping[str, object]) -> str:
    return f"{short(str(previous.get('head_sha') or ''))}..{short(str(run.get('head_sha') or ''))}"


def marker(pr_number: int, tests: Iterable[str], range_: str) -> str:
    return f"{MARKER_PREFIX} pr={pr_number} tests={tests_digest(tests)} range={range_} -->"


def already_told(bodies: Iterable[str], pr_number: int, tests: Iterable[str], range_: str) -> bool:
    """A pull request hears once per failing test set, and once per commit range.

    The range covers a re-run of the same red run whose failing set shifted.
    """
    digest = tests_digest(tests)
    for body in bodies:
        for number, seen_digest, seen_range in MARKER_RE.findall(body or ""):
            if int(number) == pr_number and (seen_digest == digest or seen_range == range_):
                return True
    return False


def short(sha: str) -> str:
    return sha[:10]


def issue_section(
    *,
    repo: str,
    run: Mapping[str, object],
    previous: Mapping[str, object] | None,
    failures: Mapping[str, list[str]],
    attributions: Mapping[str, tuple[list[PullRequest], str]],
    prs: list[PullRequest],
    direct: list[str],
) -> str:
    if previous is None:
        return "### New failures\n\nNo earlier full-suite run with every app-host shard finished to compare against."
    prev_sha = str(previous.get("head_sha") or "")
    head_sha = str(run.get("head_sha") or "")
    lines = [
        f"### New since `{short(prev_sha)}`",
        "",
        f"Compared with [the previous full-suite run]({previous.get('html_url')}) "
        f"({previous.get('conclusion')}); commits: "
        f"https://github.com/{repo}/compare/{prev_sha}...{head_sha}",
        "",
    ]
    if not failures:
        lines.append("No app-host test fails here that did not already fail in that run.")
        return "\n".join(lines)
    lines += ["Test | Suspect | Jobs", "--- | --- | ---"]
    for test in list(failures)[:MAX_LISTED_TESTS]:
        suspects, how = attributions[test]
        named = ", ".join(f"#{pr.number}" for pr in suspects) or "unattributed"
        jobs = " ".join(f"[job]({url})" for url in failures[test][:3])
        lines.append(f"`{test}` | {named} ({how}) | {jobs}")
    if len(failures) > MAX_LISTED_TESTS:
        lines.append(f"...and {len(failures) - MAX_LISTED_TESTS} more | |")
    lines += ["", f"Pull requests merged in the range: " + (", ".join(f"#{pr.number}" for pr in prs) or "none")]
    if direct and not prs:
        lines.append("Commits without a merged pull request: " + ", ".join(short(sha) for sha in direct[:10]))
    return "\n".join(lines)


def pr_comment(
    *,
    repo: str,
    pr: PullRequest,
    tests: list[str],
    how: Mapping[str, str],
    run: Mapping[str, object],
    previous: Mapping[str, object],
    failures: Mapping[str, list[str]],
    others: Mapping[str, list[int]],
) -> str:
    prev_sha = str(previous.get("head_sha") or "")
    head_sha = str(run.get("head_sha") or "")
    lines = [
        marker(pr.number, tests, commit_range(previous, run)),
        f"These app-host tests newly fail in [main's full suite]({run.get('html_url')}) "
        f"at `{short(head_sha)}`, after this pull request merged. They did not fail in "
        f"[the previous full-suite run]({previous.get('html_url')}) at `{short(prev_sha)}`, "
        "and are not in `scripts/ci/app-host-known-failures.json`.",
        "",
    ]
    for test in tests[:MAX_LISTED_TESTS]:
        jobs = " ".join(f"[job]({url})" for url in failures[test][:3])
        shared = others.get(test) or []
        also = f"; also suspected: {', '.join(f'#{n}' for n in shared)}" if shared else ""
        lines.append(f"- `{test}` ({how[test]}{also}) {jobs}")
    if len(tests) > MAX_LISTED_TESTS:
        lines.append(f"- ...and {len(tests) - MAX_LISTED_TESTS} more")
    lines += [
        "",
        f"Commits in the range: https://github.com/{repo}/compare/{prev_sha}...{head_sha}",
        "",
        "Pull requests run only the suites their diff reaches, so main's full suite is where "
        "this shows first. If this pull request is the cause, please fix forward or revert; if "
        "it is not, say so here. This is an automated attribution and can be wrong, most often "
        "for a flaky test.",
    ]
    return "\n".join(lines)


def comment_plan(
    failures: Mapping[str, list[str]], attributions: Mapping[str, tuple[list[PullRequest], str]],
) -> list[tuple[PullRequest, list[str], dict[str, str], dict[str, list[int]]]]:
    """(pr, its tests, how each was attributed, co-suspects per test) per suspect pull request."""
    by_pr: dict[int, tuple[PullRequest, list[str], dict[str, str], dict[str, list[int]]]] = {}
    for test in failures:
        suspects, how = attributions[test]
        if len(suspects) > MAX_PINGED_SUSPECTS:
            continue
        for pr in suspects:
            entry = by_pr.setdefault(pr.number, (pr, [], {}, {}))
            entry[1].append(test)
            entry[2][test] = how
            others = [other.number for other in suspects if other.number != pr.number]
            if others:
                entry[3][test] = others
    return list(by_pr.values())[:MAX_COMMENTED_PRS]


# ---- I/O ---------------------------------------------------------------------------------


def gh(args: list[str]) -> str:
    return subprocess.run(["gh", *args], check=True, capture_output=True, text=True).stdout


def git(root: Path, *args: str) -> str:
    return subprocess.run(
        ["git", "-C", str(root), *args], check=True, capture_output=True, text=True, errors="replace",
    ).stdout


def run_jobs(repo: str, run_id: object) -> list[dict]:
    return suite_run.gh_json_lines([
        f"repos/{repo}/actions/runs/{run_id}/jobs", "--paginate",
        "-X", "GET", "-f", "filter=latest", "-f", "per_page=100",
        "--jq", ".jobs[] | {id, name, conclusion, html_url} | tojson",
    ])


def job_failures(repo: str, jobs: list[Mapping[str, object]]) -> tuple[dict[str, list[str]], bool]:
    """(ratchet failure -> job URLs, whether every failed shard graded all its tests) for one run."""
    from app_host_failure_census import _gh_api_escape_flag

    failures: dict[str, list[str]] = {}
    complete = True
    for job in app_host_jobs(jobs):
        if job.get("conclusion") != "failure":
            continue
        log = gh(["api", *_gh_api_escape_flag(), f"repos/{repo}/actions/jobs/{job['id']}/logs"])
        complete = complete and shard_log_complete(ANSI_RE.sub("", log))
        for test in ratchet_failures(log):
            failures.setdefault(test, []).append(str(job.get("html_url") or ""))
    return failures, complete


def associated_prs(repo: str, shas: list[str]) -> dict[str, list[dict]]:
    owner, name = repo.split("/", 1)
    result: dict[str, list[dict]] = {}
    for start in range(0, len(shas), 40):
        chunk = shas[start:start + 40]
        fields = " ".join(
            f'c{index}: object(oid: "{sha}") {{ ... on Commit {{ associatedPullRequests(first: 5) '
            "{ nodes { number title url state baseRefName author { login } mergeCommit { oid } } } } }"
            for index, sha in enumerate(chunk)
        )
        query = f'query {{ repository(owner: "{owner}", name: "{name}") {{ {fields} }} }}'
        data = json.loads(gh(["api", "graphql", "-f", f"query={query}"]))["data"]["repository"]
        for index, sha in enumerate(chunk):
            node = data.get(f"c{index}") or {}
            result[sha] = ((node.get("associatedPullRequests") or {}).get("nodes")) or []
    return result


def overlay(files: Mapping[str, str], changes: Mapping[str, str | None]) -> dict[str, str]:
    """`files` with changed paths replaced by their text, or removed when None."""
    result = dict(files)
    for path, text in changes.items():
        if text is None:
            result.pop(path, None)
        else:
            result[path] = text
    return result


def rank_inputs(root: Path, prs: list[PullRequest]) -> None:
    """Fill each pull request's suite sets from its merge commit's diff.

    The trees are read once from the checkout. Each pull request's own changed
    files are read at its merge commit, so its hunks' line numbers match the
    text they are resolved against.
    """
    import tempfile

    import reverse_test_impact
    import test_impact

    head_files = reverse_test_impact.read_root(root)
    for pr in prs[:MAX_RANKED_PRS]:
        base = f"{pr.merge_sha}^1"
        try:
            status = git(root, "diff", "--no-renames", "--name-status", base, pr.merge_sha).splitlines()
            test_diff = git(root, "diff", "--no-renames", "-U0", base, pr.merge_sha, "--", "cmuxTests")
            app_diff = git(
                root, "diff", "--no-renames", "-U0", base, pr.merge_sha,
                "--", "Sources", "Packages/macOS", "Packages/Shared", "CLI",
            )
            changes: dict[str, str | None] = {}
            for line in status:
                code, _, path = line.partition("\t")
                if path.endswith(".swift") and path.startswith(reverse_test_impact.TREE_PREFIXES):
                    changes[path] = None if code == "D" else git(root, "show", f"{pr.merge_sha}:{path}")
        except subprocess.CalledProcessError as error:
            print(f"::warning::Could not diff #{pr.number}: {(error.stderr or '').strip()}", file=sys.stderr)
            continue
        files = overlay(head_files, changes)
        paths = [line.partition("\t")[2] for line in status]
        if any(path.startswith("cmuxTests/") for path in paths):
            with tempfile.TemporaryDirectory(prefix="attribution-") as scratch:
                for path, text in files.items():
                    if path.startswith("cmuxTests/"):
                        target = Path(scratch) / path
                        target.parent.mkdir(parents=True, exist_ok=True)
                        target.write_text(text, encoding="utf-8")
                edited = test_impact.affected_suites(Path(scratch), paths, test_diff) or []
            pr.edited_suites = {suite.removeprefix("cmuxTests/") for suite in edited}
        pr.reached_suites = set(reverse_test_impact.select(files, app_diff).suites)


def pr_comment_bodies(repo: str, number: int) -> list[str]:
    owner, name = repo.split("/", 1)
    query = (
        'query($owner: String!, $name: String!, $number: Int!) { repository(owner: $owner, name: $name) '
        "{ pullRequest(number: $number) { comments(last: 100) { nodes { body } } } } }"
    )
    data = json.loads(gh([
        "api", "graphql", "-f", f"query={query}", "-f", f"owner={owner}", "-f", f"name={name}",
        "-F", f"number={number}",
    ]))
    nodes = data["data"]["repository"]["pullRequest"]["comments"]["nodes"]
    return [str(node.get("body") or "") for node in nodes]


def resolve_run(args: argparse.Namespace) -> dict | None:
    if args.run_id:
        run = suite_run.gh_json_lines([f"repos/{args.repo}/actions/runs/{args.run_id}", "--jq", "tojson"])[0]
        if not suite_run.is_main_full_suite_run(run, args.branch) or run.get("status") != "completed":
            return None
        return run
    return suite_run.latest_tested_run(
        suite_run.list_runs(args.repo, args.branch, ["-f", "status=completed"]), args.branch,
    )


def command_report(args: argparse.Namespace) -> int:
    run = resolve_run(args)
    if run is None or run.get("conclusion") != "failure":
        print("No red full-suite run to attribute.")
        return 0
    jobs = run_jobs(args.repo, run["id"])
    if not app_host_ran(jobs):
        print(f"Run {run['id']} did not finish every app-host shard; nothing to compare.")
        return 0
    current, _ = job_failures(args.repo, jobs)

    # The baseline is the newest earlier run that graded every app-host test:
    # a shard that stopped early cannot show a test was already failing.
    previous = None
    previous_failures: set[str] = set()
    earlier = earlier_tested_runs(
        suite_run.list_runs(args.repo, args.branch, ["-f", "status=completed"]), run, args.branch,
    )
    for candidate in earlier[:MAX_BASELINE_CANDIDATES]:
        candidate_jobs = run_jobs(args.repo, candidate["id"])
        if not app_host_ran(candidate_jobs):
            continue
        if candidate.get("conclusion") == "failure":
            failed, complete = job_failures(args.repo, candidate_jobs)
            if not complete:
                continue
            previous_failures = set(failed)
        previous = candidate
        break

    failures = new_failures(current, previous_failures) if previous else {}
    prs: list[PullRequest] = []
    direct: list[str] = []
    attributions: dict[str, tuple[list[PullRequest], str]] = {}
    if previous and failures:
        shas = git(args.root, "rev-list", f"{previous['head_sha']}..{run['head_sha']}").split()
        prs, direct = merged_prs(shas, associated_prs(args.repo, shas), args.branch)
        if len(prs) > 1:
            rank_inputs(args.root, prs)
        attributions = {test: suspects_for(test, prs, direct) for test in failures}

    section = issue_section(
        repo=args.repo, run=run, previous=previous, failures=failures,
        attributions=attributions, prs=prs, direct=direct,
    )
    print(section)
    if args.section_output:
        Path(args.section_output).write_text(section + "\n", encoding="utf-8")

    for pr, tests, how, others in comment_plan(failures, attributions):
        if already_told(pr_comment_bodies(args.repo, pr.number), pr.number, tests, commit_range(previous, run)):
            print(f"#{pr.number} already told about these tests.")
            continue
        body = pr_comment(
            repo=args.repo, pr=pr, tests=tests, how=how, run=run, previous=previous,
            failures=failures, others=others,
        )
        if args.dry_run:
            print(f"--- would comment on #{pr.number} ---\n{body}")
            continue
        gh(["api", f"repos/{args.repo}/issues/{pr.number}/comments", "-f", f"body={body}"])
        print(f"Commented on #{pr.number}.")
    return 0


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--repo", default=os.environ.get("GITHUB_REPOSITORY", ""))
    parser.add_argument("--branch", default="main")
    commands = parser.add_subparsers(dest="command", required=True)
    report = commands.add_parser("report", help="attribute a red run's new failures and tell the suspects")
    report.add_argument("--run-id", help="defaults to the newest green or red full-suite run")
    report.add_argument("--root", type=Path, default=Path.cwd(), help="a main checkout with history")
    report.add_argument("--section-output", help="write the issue's markdown section here")
    report.add_argument("--dry-run", action="store_true", help="print pull request comments instead of posting")
    report.set_defaults(handler=command_report)
    args = parser.parse_args(argv)
    if not args.repo:
        parser.error("--repo or GITHUB_REPOSITORY is required")
    return args.handler(args)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
