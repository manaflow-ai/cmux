#!/usr/bin/env python3
"""Keep one comment on a pull request into feat-cmux-next that names its red web and size checks.

The web checks and the CmuxNextApp size cap are advisory (not required) on feat-cmux-next, so a
red one does not stop a merge; this comment makes it impossible to miss (chief 2026-10-12, after
#20117 merged with red web checks and left 168 settings strings stale on the base).

Reads every check run of the pull request's head commit, keeps the newest run per name among the
TRACKED names, and writes the `checks` line of the pull request's status comment
(scripts/ci/pr_status.py):
  - some tracked check red -> "red: <check>; do not merge until green; see lane-rules", one line
    per red check;
  - none red, and the line says red -> "web and size checks: green";
  - none red and no red line -> nothing (no comment on a clean PR).
Pending checks do not count. Several workflows call it (each after its own checks); every call
recomputes from all check runs, so the line converges.

With BASE_SHA (the pull request's base commit), each red check is compared with the base commit's
run of the same check (Leo 2026-10-19, after #20633 merged a new lint red behind a known base red):
its failure signature is its failed step names plus its failure annotations (minus "Process
completed with exit code N"). Anything in the pull request's signature that the base's lacks is
NEW and blocks; the same signature is a base red and does not; a base with no finished run of the
check cannot excuse it.

Two kinds of check are never compared with the base that way (2026-10-30: 22 pull requests merged webview
test reds that broke the base, and this line called most of them base reds):
  - web / react-apps-base-check (N) is already the base comparison: it replays the head's red webview test
    files on the merge parent and fails only on tests red on the change alone. A push never runs it, so the
    base has no run of it. Its red line names those tests, read from its "Webview test red on this
    change" annotations.
  - web / react-apps-check and web / Web status only gather other jobs. Their one failed step ("Check
    webview test shards", "Check routed web jobs") failed the same way on a red base for any reason, so a
    signature match said nothing. Each follows the lines of the red jobs it gathers (AGGREGATES): it blocks
    when one of them blocks, when a job it gathers was cancelled, or when none of them is red. A red check
    it does not gather (the size cap) never excuses it. A new advisory check is one more entry
in TRACKED. The comment this used to keep on its own (LEGACY_MARKER) is deleted on the first write.

OWN_CHECKS_GREEN=true (the caller's tracked jobs all passed or were skipped) reads only the status
comment and stops when its line names no red: then this call has nothing to change.

A call for a commit that is no longer the pull request's head writes nothing: a red at a superseded
commit is not the pull request's red, and a late call for an old head (queued behind a newer one in
the per-PR group) must not overwrite the line the current head's call wrote. The head is read just
before the write, so only a call that has something to change pays for that read, and it is read
with `git ls-remote origin refs/pull/N/head` (no API call); the REST read is the fallback.

The status comment is read through pr_status's default client: over GraphQL (its own hourly pool),
REST only when that fails. So a green caller with no red line spends no REST call at all; the
repository's GITHUB_TOKEN REST budget (1,000/h, shared by every workflow) is kept for the writes.

Env: GITHUB_TOKEN, GITHUB_REPOSITORY, PR_NUMBER, HEAD_SHA, GITHUB_API_URL (default api.github.com),
BASE_SHA, OWN_CHECKS_GREEN, PR_HEAD_REMOTE (the git remote the head is read from; default origin).
"""
import json
import os
import re
import subprocess
import sys
import urllib.error
import urllib.request
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import pr_status  # noqa: E402

LEGACY_MARKER = "<!-- cmux-red-checks -->"
# (kind, value): "prefix" matches the start of a check name, "name" the whole name.
TRACKED = (
    ("prefix", "web / "),                            # ci-web.yml jobs (ci.yml `web` caller)
    # cmux-next-guards.yml own-change-checks job: the CmuxNextApp size cap (hq-11) and the crash ratchet among its steps
    ("name", "cmux-next size cap, crash ratchet, localization debt ratchet, no new generated files"),
    # cmux-next-guards.yml static-checks job: page strings among its steps. GitHub reports a name past 100
    # characters cut to 97 and "...", and this one's `name:` is 101: the full name never matched its red.
    ("name", "cmux-next static checks (vt-link-graph, nightly static capabilities, defaults snapshot, page stri..."),
    ("name", "cmux-next checks (god files, concurrency, crash safety, l10n)"),  # cmux-next.yml checks job
)
RED = {"failure", "timed_out", "action_required", "startup_failure"}
# The webview tests' own base comparison (ci-web.yml), and its annotations' title for each new red test.
BASE_CHECK = re.compile(r"^web / react-apps-base-check \(\d+\)$")
NEW_TEST_TITLE = "Webview test red on this change"
NAMED = 3  # new red tests a line names before "(+N more)"
# Jobs that only gather other jobs' verdicts, each with the jobs it gathers (its `needs`, as check names): never
# compared with the base on their own. react-apps-check comes first: Web status gathers it too.
AGGREGATES = {
    "web / react-apps-check": re.compile(r"^web / (?:react-apps-(?:base-)?check \(\d+\)|react-doctor)$"),
    "web / Web status": re.compile(r"^web / (?!Web status$)"),  # it needs every routed web job
}
# A gathered job that ended with no verdict: the aggregate failed on it, and no base red explains that. Skipped is
# not one: a replay is skipped after its shard fails (that shard's line decides), and an unrouted job skips.
NO_VERDICT = {"cancelled", "stale"}
GREEN_LINE = "web and size checks: green"
BLOCK = "do not merge until green; see lane-rules"
EXIT_CODE = re.compile(r"^Process completed with exit code \d+\.?$")


def tracked(name):
    return any(name.startswith(v) if k == "prefix" else name == v for k, v in TRACKED)


def newest_runs(check_runs):
    """The newest run of each tracked check, by name."""
    newest = {}
    for run in check_runs:
        name = run.get("name") or ""
        if not tracked(name):
            continue
        key = (run.get("started_at") or "", run.get("id") or 0)
        if name not in newest or key > newest[name][0]:
            newest[name] = (key, run)
    return {n: r for n, (_, r) in newest.items()}


def is_red(run):
    return run is not None and run.get("status") == "completed" and run.get("conclusion") in RED


def red_checks(check_runs):
    """Names of tracked checks whose newest completed run is red."""
    return sorted(n for n, r in newest_runs(check_runs).items() if is_red(r))


def signature(steps, annotations):
    """What failed in one check run: its failed step names and its failure annotations."""
    sig = [f"step `{s.get('name')}`" for s in steps if s.get("conclusion") in RED]
    for a in annotations:
        message = " ".join((a.get("message") or "").split())
        if a.get("annotation_level") == "failure" and message and not EXIT_CODE.match(message):
            sig.append(f"`{message[:160]}`")
    return list(dict.fromkeys(sig))


def compare(name, pr_sig, base_run, base_sig, base_sha):
    """The line for one red check, given the base commit's run of it (None: no finished run)."""
    short = base_sha[:10]
    if base_run is None or base_run.get("status") != "completed" or base_run.get("conclusion") not in RED | {"success"}:
        # Missing, running, cancelled or skipped: no verdict on the base to excuse anything with.
        return f"red: {name}; no finished base run on {short} to compare; {BLOCK}"
    if not is_red(base_run):
        return f"red: {name}; NEW: green on the base {short}; {BLOCK}"
    new = [item for item in pr_sig if item not in base_sig]
    if not new:
        return f"red: {name}; base red: the same failure on the base {short}; does not block"
    what = new[0] + (f" (+{len(new) - 1} more)" if len(new) > 1 else "")
    verb = "passes" if new[0].startswith("step ") else "is not red"
    return f"red: {name}; NEW: {what} {verb} on the base {short}; {BLOCK}"


def decide(check_runs, existing_line, lines=None):
    """The checks line to write, or None to leave it as it is. `lines` maps a red check to its
    base-compared line (BASE_SHA); without it every red check blocks."""
    red = red_checks(check_runs)
    if red:
        line = "\n".join((lines or {}).get(n) or f"red: {n}; {BLOCK}" for n in red)
    elif existing_line is not None and "red: " in existing_line:
        line = GREEN_LINE
    else:
        return None
    return None if existing_line is not None and existing_line.strip() == line else line


class GitHub:
    def __init__(self, api, repo, token):
        self.api, self.repo, self.token = api.rstrip("/"), repo, token
        # check run id -> (steps, annotations), prefetched over GraphQL (prefetch_details); REST answers the rest.
        self.details = {}

    def call(self, method, path, payload=None):
        req = urllib.request.Request(self.api + path, method=method,
                                     data=None if payload is None else json.dumps(payload).encode(),
                                     headers={"Authorization": f"Bearer {self.token}",
                                              "Accept": "application/vnd.github+json",
                                              "X-GitHub-Api-Version": "2022-11-28"})
        with urllib.request.urlopen(req, timeout=30) as resp:
            return json.loads(resp.read() or b"null")

    def pages(self, path, key=None):
        out, page = [], 1
        while page <= 10:
            sep = "&" if "?" in path else "?"
            data = self.call("GET", f"{path}{sep}per_page=100&page={page}")
            items = data[key] if key else data
            out += items
            if len(items) < 100:
                break
            page += 1
        return out


def annotations(gh, run):
    if run.get("id") in gh.details:
        return gh.details[run["id"]][1]
    return gh.call("GET", f"/repos/{gh.repo}/check-runs/{run['id']}/annotations?per_page=100") or []


def run_signature(gh, run):
    if run.get("id") in gh.details:
        return signature(*gh.details[run["id"]])
    steps = gh.call("GET", f"/repos/{gh.repo}/actions/jobs/{run['id']}").get("steps") or []
    return signature(steps, annotations(gh, run))


# Reads over GraphQL (its own hourly pool), so a red call spends no REST: before, it read the head's and the base's
# check-run pages, then each red check's job steps and annotations, on the PR's run and the base's, all from the
# repository GITHUB_TOKEN's 1,000/h REST pool that every workflow shares. Any GraphQL error, or a commit with more
# suites or runs than one page holds, leaves the REST reads to answer exactly as before.
_RUNS = ("checkSuites(first:100){pageInfo{hasNextPage} nodes{checkRuns(first:100,filterBy:{checkType:LATEST})"
         "{pageInfo{hasNextPage} nodes{id databaseId name status conclusion startedAt}}}}")
CHECKS_QUERY = ("query($owner:String!,$name:String!,$head:GitObjectID!,$base:GitObjectID!,$withBase:Boolean!){"
                "repository(owner:$owner,name:$name){head:object(oid:$head){...on Commit{" + _RUNS + "}}"
                " base:object(oid:$base) @include(if:$withBase){...on Commit{" + _RUNS + "}}}"
                " rateLimit{limit cost remaining used resetAt}}")
DETAILS_QUERY = ("query($ids:[ID!]!){nodes(ids:$ids){...on CheckRun{databaseId"
                 " steps(first:100){pageInfo{hasNextPage} nodes{name conclusion number}}"
                 " annotations(first:100){nodes{title message annotationLevel}}}}"
                 " rateLimit{limit cost remaining used resetAt}}")


def _lower(value):
    return value.lower() if isinstance(value, str) else value


def _commit_runs(commit):
    """A commit's check runs in REST's shape, or None when a page was not enough."""
    suites = (commit or {}).get("checkSuites") or {}
    if (suites.get("pageInfo") or {}).get("hasNextPage"):
        return None
    runs = []
    for suite in suites.get("nodes") or []:
        if not isinstance(suite, dict):
            return None  # a null suite could hide a red run: incomplete, so REST answers
        page = suite.get("checkRuns") or {}
        if (page.get("pageInfo") or {}).get("hasNextPage"):
            return None
        for node in page.get("nodes") or []:
            if not isinstance(node, dict):
                return None  # a null node (a deleted or hidden run): incomplete, so REST answers
            runs.append({"id": node.get("databaseId"), "node_id": node.get("id"), "name": node.get("name"),
                         "status": _lower(node.get("status")), "conclusion": _lower(node.get("conclusion")),
                         "started_at": node.get("startedAt")})
    return runs


def prefetch_runs(gh, sha, base_sha, query=None):
    """{sha: check runs} for the head (and the base when given) in one GraphQL query; {} on any error."""
    query = query or pr_status.graphql
    owner, _, name = gh.repo.partition("/")
    try:
        data = query(CHECKS_QUERY, {"owner": owner, "name": name, "head": sha, "base": base_sha or sha,
                                    "withBase": bool(base_sha)})
    except RuntimeError as err:
        print(f"pr-red-checks: check runs over GraphQL failed ({str(err)[:200]}); reading them over REST",
              file=sys.stderr)
        return {}
    repo = (data or {}).get("repository") or {}
    found = {}
    for key, oid in (("head", sha), ("base", base_sha)):
        if oid and repo.get(key) is not None:
            runs = _commit_runs(repo[key])
            if runs is not None:
                found[oid] = runs
    return found


def prefetch_details(gh, runs, query=None):
    """Fill gh.details for `runs` (each with a node_id) in one GraphQL query; on any error leave it to REST."""
    query = query or pr_status.graphql
    wanted = {run["node_id"]: run["id"] for run in runs
              if run and run.get("node_id") and run.get("id") is not None and run["id"] not in gh.details}
    if not wanted:
        return
    try:
        data = query(DETAILS_QUERY, {"ids": sorted(wanted)})
    except RuntimeError as err:
        print(f"pr-red-checks: steps and annotations over GraphQL failed ({str(err)[:200]}); reading them over REST",
              file=sys.stderr)
        return
    for node in (data or {}).get("nodes") or []:
        if not node or node.get("databaseId") is None:
            continue
        if ((node.get("steps") or {}).get("pageInfo") or {}).get("hasNextPage"):
            # REST's job read returns every step; a failed step past the first page must not drop out of the
            # signature (it could turn a new red into a base red), so REST answers this run.
            continue
        if not all(isinstance(item, dict) for key in ("steps", "annotations")
                   for item in ((node.get(key) or {}).get("nodes") or [])):
            continue  # a null step or annotation: incomplete, so REST answers this run
        steps = [{"name": s.get("name"), "conclusion": _lower(s.get("conclusion")), "number": s.get("number")}
                 for s in ((node.get("steps") or {}).get("nodes") or [])]
        notes = [{"title": a.get("title"), "message": a.get("message"),
                  "annotation_level": _lower(a.get("annotationLevel"))}
                 for a in ((node.get("annotations") or {}).get("nodes") or [])]
        gh.details[node["databaseId"]] = (steps, notes)


def commit_runs(gh, sha, prefetched):
    """A commit's check runs: the GraphQL prefetch, else REST's pages."""
    if sha in prefetched:
        return prefetched[sha]
    return gh.pages(f"/repos/{gh.repo}/commits/{sha}/check-runs?filter=latest", key="check_runs")


def new_tests(found):
    """The tests a base replay charged to the change, from its failure annotations' messages."""
    names = [" ".join((a.get("message") or "").split()) for a in found
             if a.get("annotation_level") == "failure" and a.get("title") == NEW_TEST_TITLE]
    return list(dict.fromkeys(n for n in names if n))


def base_check_line(name, tests):
    """The line for a red base replay: the tests it charged to the change. It always blocks."""
    if not tests:
        return f"red: {name}; it named no new red test (setup or base replay failed; see its log); {BLOCK}"
    more = f" (+{len(tests) - NAMED} more)" if len(tests) > NAMED else ""
    return f"red: {name}; NEW webview test reds: {'; '.join(tests[:NAMED])}{more}; {BLOCK}"


def aggregate_line(name, gathered, unfinished=()):
    """An aggregate's line, from the lines of the red jobs it gathers: never a base red of its own. It blocks when one
    of them blocks, when a job it gathers was cancelled or skipped (its own failure, which no base red explains), or
    when none of them is red."""
    if any(BLOCK in line for line in gathered):
        return f"red: {name}; a job it gathers is red on this change (its line here); {BLOCK}"
    if unfinished:
        return f"red: {name}; a job it gathers ended without a verdict ({unfinished[0]}); {BLOCK}"
    if not gathered:
        return f"red: {name}; none of the jobs it gathers is red (one was skipped or cancelled); {BLOCK}"
    return f"red: {name}; follows the jobs it gathers, whose reds are all on the base too; does not block"


def base_lines(gh, runs, base_sha, prefetched=None):
    """Each red check's line compared with the base commit's run of it; {} without a base."""
    red = red_checks(runs)
    if not base_sha or not red:
        return {}
    try:
        base = newest_runs(commit_runs(gh, base_sha, prefetched or {}))
    except (urllib.error.URLError, TimeoutError) as err:
        print(f"pr-red-checks: base {base_sha[:10]} unreadable ({err}); every red blocks", file=sys.stderr)
        return {}
    mine = newest_runs(runs)
    # One GraphQL query for every run compared below: each red check's run, and the base's run when it is red too.
    compared = [mine[name] for name in red if name not in AGGREGATES]
    compared += [base[name] for name in red if name not in AGGREGATES and not BASE_CHECK.match(name)
                 and is_red(base.get(name))]
    prefetch_details(gh, compared)
    lines = {}
    for name in red:
        if name in AGGREGATES:
            continue
        try:
            if BASE_CHECK.match(name):
                lines[name] = base_check_line(name, new_tests(annotations(gh, mine[name])))
                continue
            base_run = base.get(name)
            pr_sig = run_signature(gh, mine[name])
            base_sig = run_signature(gh, base_run) if is_red(base_run) else []
        except (urllib.error.URLError, TimeoutError) as err:
            print(f"pr-red-checks: {name}: no signature ({err}); it blocks", file=sys.stderr)
            continue
        lines[name] = compare(name, pr_sig, base_run, base_sig, base_sha)
    for name, gathers in AGGREGATES.items():
        if name not in red:
            continue
        jobs = [n for n in red if n != name and gathers.match(n)]
        unfinished = sorted(f"{n}: {r.get('conclusion')}" for n, r in mine.items()
                            if n != name and gathers.match(n)
                            and r.get("status") == "completed" and r.get("conclusion") in NO_VERDICT)
        lines[name] = aggregate_line(name, [lines.get(n) or f"red: {n}; {BLOCK}" for n in jobs], unfinished)
    return lines


def git_head(pr, remote=None):
    """The pull request's head commit from `git ls-remote` (no API call), or None when git cannot say."""
    remote = remote or os.environ.get("PR_HEAD_REMOTE") or "origin"
    try:
        out = subprocess.run(["git", "ls-remote", remote, f"refs/pull/{int(pr)}/head"], capture_output=True,
                             text=True, timeout=30, check=True).stdout
    except (OSError, subprocess.SubprocessError, ValueError):
        return None
    sha = out.split()[0] if out.split() else ""
    return sha if re.fullmatch(r"[0-9a-f]{40}", sha) else None


def live_head(gh, pr):
    """The pull request's head now: git first, the REST pull request read when git fails."""
    head = git_head(pr)
    if head:
        return head
    print(f"pr-red-checks: #{pr}: git ls-remote gave no head; reading it over REST", file=sys.stderr)
    return ((gh.call("GET", f"/repos/{gh.repo}/pulls/{pr}") or {}).get("head") or {}).get("sha")


def main():
    gh = GitHub(os.environ.get("GITHUB_API_URL", "https://api.github.com"), os.environ["GITHUB_REPOSITORY"],
                os.environ["GITHUB_TOKEN"])
    pr, sha = os.environ["PR_NUMBER"], os.environ["HEAD_SHA"]
    current = pr_status.section(gh.repo, int(pr), "checks")
    if os.environ.get("OWN_CHECKS_GREEN") == "true" and (current is None or "red: " not in current):
        # The caller's own tracked checks passed and the line names no red: reading the head's
        # check runs could only find another workflow's red, which that workflow's own call (after
        # its checks) writes. Nothing for this call to change; skip the check-runs pages.
        print(f"pr-red-checks: #{pr} {sha[:12]}: own checks green, no red line; action=none")
        return 0
    base_sha = os.environ.get("BASE_SHA", "").strip()
    prefetched = prefetch_runs(gh, sha, base_sha)
    runs = commit_runs(gh, sha, prefetched)
    lines = base_lines(gh, runs, base_sha, prefetched)
    line = decide(runs, current, lines)
    action = None
    if line is not None:
        head = live_head(gh, pr)
        if head != sha:
            print(f"pr-red-checks: #{pr} {sha[:12]}: superseded by head {str(head)[:12]}; action=none")
            return 0
        action = pr_status.upsert(gh.repo, int(pr), "checks", line, legacy=LEGACY_MARKER)
    print(f"pr-red-checks: #{pr} {sha[:12]}: red={red_checks(runs)} action={action or 'none'}")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except urllib.error.HTTPError as err:
        # A fork pull request gets a read-only token: the comment cannot be written. Say so; never
        # fail the calling workflow over an advisory comment.
        print(f"pr-red-checks: WARNING, GitHub refused ({err.code} {err.reason}); no comment written", file=sys.stderr)
        sys.exit(0)
    except RuntimeError as err:
        # pr_status's client (the comment read and write) raises RuntimeError on a refusal, QuotaSpent on a spent
        # quota: the same advisory warning.
        print(f"pr-red-checks: WARNING, GitHub refused ({str(err)[:300]}); no comment written", file=sys.stderr)
        sys.exit(0)
