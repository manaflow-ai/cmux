#!/usr/bin/env python3
"""Local test receipts: a passing same-tree `cmux-ci test` run counts as the CI job it repeats.

A change tested locally (Leo) counts as a CI pass, and the CI job it repeats is skipped.

A receipt is a Fast checks run (.github/workflows/fast-checks.yml), dispatched on main by the lane-gh broker for
`cmux-ci test`, whose command is a job's canonical command below. GitHub is the signer: the run, its workflow file
(main's), its conclusion and its job log come from the Actions API, so no key is minted, held or rotated, and a pull
request job reads it with its own read-only token. The pull request names the run in its body:

    CI-Receipt: fast-gates https://github.com/manaflow-ai/cmux/actions/runs/RUN_ID

  produce JOB     the canonical command (run it with `cmux-ci test -- python3 scripts/ci/ci_receipt.py produce JOB`,
                  `--setup webviews` when the change touches web code): merges the tested commit into the current
                  feat-cmux-next tip in a scratch worktree, runs the job there exactly as CI does, and on a pass
                  prints one `CMUX_CI_RECEIPT={...}` line naming the job, the head, the base and the merge tree.
  verify JOB      in CI, before any heavy runner is taken. Exit 0 always; writes `valid=`, `audit=`, `base=`,
                  `run_url=`, `producer=` and `reason=` to --output. A receipt counts only when every check holds:
                    - the run is fast-checks.yml in this repository, a workflow_dispatch on main, completed success;
                    - its run-name names a tested commit (`tests OWNER/REPO@SHA`, which the workflow's "Confirm the
                      tested commit" step proves), and its `checks` job passed;
                    - the job log's env header of the "Run fast checks" step (GitHub prints it before the command
                      runs) is exactly FAST_CHECKS_COMMAND, _DIRECTORY, _TIMEOUT, _SOURCE, _OUT, one line each, in
                      that order: COMMAND the job's canonical command character for character, DIRECTORY `.`. A
                      command with a newline in it prints extra header lines and is refused (it would run a second
                      line after the canonical one);
                    - the workflow's own FAST_CHECKS_RECEIPT (its last line, printed after the command's process group
                      is gone) has exit 0, an unmoved HEAD, and this head's tree: a receipt is keyed on the tree, so a
                      commit with the same tree (an empty commit pushed after the body names the receipt) keeps it;
                    - the command's CMUX_CI_RECEIPT names this job and a commit of this tree, and its merge tree is this run's
                      merge tree: with the same base, the tree must equal ours; with an older base, that base must
                      be an ancestor of ours. For fast gates the status names it (`base SHA`) so mergers apply their
                      freshness rule to it as to any fast-gates status; for rust workspaces the commits since may change
                      no Rust input (a Rust or Cargo file anywhere, the build setup, or a path under a listed
                      workspace root or input, .github/rust-workspaces.toml), at most 300 files.
                  Anything else (no pointer, a forged or replayed run, another tree or command, an API failure) is
                  `valid=false` with the reason, and the job runs in full.
                  `audit=true` for CI_RECEIPT_AUDIT_PERCENT of valid receipts (default 10, seeded by the head and the
                  receipt run, so pushing or reopening again does not re-roll it):
                  the job still runs in full, and a red there names the receipt and its producer.

Lane receipts (fast gates). Leo: "Shift checks left into the lanes. The agent's lane VM already has the tree built; it
runs the fast tier and the affected tests before pushing, and records a signed receipt keyed by tree hash." `produce
fast-gates` run plainly on a lane (no cmux-ci; leo-workspace `wt push` runs it before every cmux push from a Linux lane
host) records its pass with the build controller (POST /v1/ci/lane-receipt, tailnet). The controller names the producer
from the caller's tailnet node (`lane:<node>`) and signs the receipt with its CI receipt key (cmuxterm-hq
build-fleet/cmd/controller/lane_receipt.go). `verify --lane` asks the controller first through its public front door
with the run's OIDC token (audience cmux-ci-lane-receipt) for receipts of this head's tree and holds each to this
run's merge exactly as above (same base: same merge tree; older base: an ancestor). Audit is the same 10%, and every
receipt of a producer in shadow (one whose audited receipt re-ran red, until 20 audits agree) is audited; the
workflow's lane-receipt-audit job reports each audited verdict back. No lane receipt falls through to the pointer and
discovery path above. `vars.CI_LANE_RECEIPTS=0` turns the lane lookup off; `produce --no-record` records nothing.
"""
from __future__ import annotations

import argparse
import datetime
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request
from pathlib import Path
from typing import Callable

sys.path.insert(0, str(Path(__file__).resolve().parent))
import deadline_http  # noqa: E402
import gh_http  # noqa: E402

BRANCH = "feat-cmux-next"
SHA = re.compile(r"^[0-9a-f]{40}$")
WORKFLOW_PATH = ".github/workflows/fast-checks.yml"
RECEIPT_WORKFLOW_BRANCH = "main"
JOB_NAME = "checks"
JOBS = ("fast-gates", "rust-workspaces")
# The command each job's receipt must have run, character for character.
CANONICAL = {job: f"python3 scripts/ci/ci_receipt.py produce {job}" for job in JOBS}
POINTER = re.compile(r"^\s*CI-Receipt:\s*(?P<job>[a-z-]+)\s+(?:https://github\.com/(?P<repo>[^/\s]+/[^/\s]+)/actions/runs/)?"
                     r"(?P<run>[0-9]{1,15})(?:/\S*)?\s*$", re.M)
TIMESTAMP = re.compile(r"^\d{4}-\d\d-\d\dT[0-9:.]+Z ?")
MERGE_IDENTITY = ("-c", "user.name=cmux ci receipt", "-c", "user.email=ci-receipt@users.noreply.github.com")
DEFAULT_AUDIT_PERCENT = 10


def log(message: str) -> None:
    print(message, file=sys.stderr, flush=True)


class Rejected(Exception):
    """A receipt that does not count; the message says why."""


# ----------------------------------------------------------------------------------------------- verify


Fetch = Callable[[str], bytes]


def github_fetch(token: str, api: str = "https://api.github.com") -> Fetch:
    def fetch(path: str) -> bytes:
        request = urllib.request.Request(f"{api}/{path.lstrip('/')}", headers={
            "Authorization": f"Bearer {token}", "Accept": "application/vnd.github+json",
            "X-GitHub-Api-Version": "2022-11-28", "User-Agent": "cmux-ci-receipt"})
        # Each call ends by its deadline as a whole, not per socket wait (tests/test_ci_no_bare_urlopen.py).
        try:
            # Asked again on a passing refusal (gh_http); a redirect is an answer (follow_redirects=False).
            status, body, headers = gh_http.request(request, 30, follow_redirects=False)
        except (urllib.error.URLError, TimeoutError, OSError) as error:
            raise Rejected(f"GitHub did not answer for {path}: {error}") from error
        if status < 300:
            return body
        location = headers.get("Location") if status in (301, 302, 303, 307, 308) else None
        if location and location.startswith("https://"):
            # A job log answers with a signed storage URL; it must be read without the token (the storage
            # host refuses an Authorization header).
            try:
                again, body, _ = deadline_http.request(urllib.request.Request(
                    location, headers={"User-Agent": "cmux-ci-receipt"}), 60)
            except (urllib.error.URLError, TimeoutError, OSError) as error:
                raise Rejected(f"the redirect for {path} did not answer: {error}") from error
            if again < 300:
                return body
            raise Rejected(f"the redirect for {path} answered {again}")
        raise Rejected(f"GitHub answered {status} for {path}")
    return fetch


def pointers(body: str, job: str, repo: str) -> list[str]:
    """Run ids the pull request body names for JOB, in order."""
    found = []
    for match in POINTER.finditer(body or ""):
        if match["job"] == job and (match["repo"] in (None, repo)):
            found.append(match["run"])
    return found


DISCOVER_DAYS = 2
DISCOVER_PAGES = 5
DISCOVER_COMMITS = 100
# A run cannot test a commit made after it started, so the search starts at the oldest commit's committer date, less
# this margin for a committer's clock running fast. Main holds about 600 receipt dispatches a day (2026-11-21): from
# two days back every search read all five pages, about 240 GITHUB_TOKEN calls an hour from this job alone.
DISCOVER_SKEW = datetime.timedelta(minutes=30)


def committed_at(each: dict) -> datetime.datetime | None:
    try:
        stamp = datetime.datetime.fromisoformat(str(each["commit"]["committer"]["date"]).replace("Z", "+00:00"))
    except (KeyError, TypeError, ValueError):
        return None
    return stamp if stamp.tzinfo else None


def discover(fetch: Fetch, repo: str, pr: int, head: str, now: datetime.datetime | None = None) -> list[str]:
    """Run ids of successful Fast checks dispatches on main that name a commit of this pull request as the one they
    tested, oldest first (the order `pointers` gives, so `verify` reads the newest). This is the body pointer found
    without anyone writing it: the lane that ran the canonical command needs no `CI-Receipt:` line. It only finds
    candidates; check_run still holds each one to every check a pointed-at run passes (workflow, dispatch on main,
    conclusion, canonical command, the head's tree, the merge tree), so a candidate that is no receipt is rejected
    with its reason and a missing one only means the job runs."""
    commits = [head]
    now = now or datetime.datetime.now(datetime.timezone.utc)
    window = now - datetime.timedelta(days=DISCOVER_DAYS)
    since = window.strftime("%Y-%m-%d")
    try:
        listed = json.loads(fetch(f"repos/{repo}/pulls/{pr}/commits?per_page={DISCOVER_COMMITS}"))
        commits += [each.get("sha", "") for each in reversed(listed) if SHA.match(each.get("sha", ""))]
        dates = [committed_at(each) for each in listed if isinstance(each, dict)]
        # Every listed commit needs a date (a dateless one could be the oldest), and a full page may hide older ones.
        if dates and None not in dates and len(listed) < DISCOVER_COMMITS:
            start = min(dates) - DISCOVER_SKEW
            if start > window:
                since = start.astimezone(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    except (Rejected, ValueError, AttributeError, TypeError):
        pass  # the head alone: a commit pushed after the run needs the pointer line
    wanted = set(commits)
    found = []
    for page in range(1, DISCOVER_PAGES + 1):
        query = (f"event=workflow_dispatch&branch={RECEIPT_WORKFLOW_BRANCH}&status=success&per_page=100&page={page}"
                 f"&created=%3E%3D{since}")
        batch = json.loads(fetch(f"repos/{repo}/actions/workflows/fast-checks.yml/runs?{query}")).get("workflow_runs") or []
        for run in batch:  # newest first
            tested = TESTED.search(str(run.get("display_title", "")))
            if tested and tested["repo"] == repo and tested["sha"] in wanted:
                found.append(str(run["id"]))
        if len(batch) < 100:
            break
    return list(reversed(found))


def same_command(text: str, job: str) -> bool:
    return text == CANONICAL[job]


# The "Run fast checks" step's env block ends with these, in this order (fast-checks.yml), one line each.
STEP_ENV = ("FAST_CHECKS_COMMAND", "FAST_CHECKS_DIRECTORY", "FAST_CHECKS_TIMEOUT", "FAST_CHECKS_SOURCE",
            "FAST_CHECKS_OUT")
ENV_LINE = re.compile(r"^  (?P<key>[A-Za-z_][A-Za-z0-9_]*): (?P<value>.*)$")


class LogShape(Exception):
    pass


def parse_log(text: str) -> dict:
    """The fields of a fast-checks `checks` job log a receipt rests on.

    The "Run fast checks" step is the one ##[group] titled `Run umask 022` (its script's first line). Its env block
    (after `env:`, up to ##[endgroup]) must be `  KEY: value` lines only, and end with STEP_ENV exactly once each, in
    order: GitHub prints a value with a newline in it as extra lines, so a command with a second line is refused here.
    fast_checks: the last FAST_CHECKS_RECEIPT line (the workflow prints it after the command's process group is
    stopped). receipt: the last CMUX_CI_RECEIPT line before it. Raises LogShape when the step is not found once."""
    lines = [TIMESTAMP.sub("", line, count=1) for line in text.splitlines()]
    steps = [index for index, line in enumerate(lines) if line == "##[group]Run umask 022"]
    if len(steps) != 1:
        raise LogShape(f"{len(steps)} 'Run fast checks' steps in the log")
    index = steps[0] + 1
    while index < len(lines) and lines[index] != "env:":
        if lines[index].startswith("##[endgroup]"):
            raise LogShape("the 'Run fast checks' step has no env block")
        index += 1
    env: list[tuple[str, str]] = []
    index += 1
    while index < len(lines) and not lines[index].startswith("##[endgroup]"):
        line = lines[index]
        match = ENV_LINE.match(line)
        if not match or "\r" in line:
            raise LogShape(f"the 'Run fast checks' env block has a line that is not KEY: value ({line[:120]!r}): "
                           "a command with a newline in it")
        env.append((match["key"], match["value"]))
        index += 1
    keys = [key for key, _ in env]
    if keys[-len(STEP_ENV):] != list(STEP_ENV) or any(keys.count(key) != 1 for key in STEP_ENV):
        raise LogShape(f"the 'Run fast checks' env block is {keys[-8:]}, not {list(STEP_ENV)} once each")
    values = dict(env)
    fast_checks = receipt = None
    fast_index = -1
    for at, line in enumerate(lines):
        if line.startswith("FAST_CHECKS_RECEIPT="):
            fast_checks, fast_index = line[len("FAST_CHECKS_RECEIPT="):], at
    for line in lines[index:fast_index if fast_index >= 0 else len(lines)]:
        if line.startswith("CMUX_CI_RECEIPT="):
            receipt = line[len("CMUX_CI_RECEIPT="):]

    def load(value: str | None) -> dict | None:
        try:
            parsed = json.loads(value) if value else None
        except json.JSONDecodeError:
            return None
        return parsed if isinstance(parsed, dict) else None

    return {"command": values["FAST_CHECKS_COMMAND"], "directory": values["FAST_CHECKS_DIRECTORY"],
            "source": values["FAST_CHECKS_SOURCE"], "fast_checks": load(fast_checks), "receipt": load(receipt)}


TESTED = re.compile(r" tests (?P<repo>[^@\s]+)@(?P<sha>[0-9a-f]{40})$")


# What a Cargo workspace build reads beyond its own root (rust-workspaces.py's EVERYTHING and the build setup).
RUST_ANYWHERE = re.compile(r"(^|/)(Cargo\.(toml|lock)|rust-toolchain(\.toml)?|build\.rs|\.cargo/[^/]+|clippy\.toml)$|\.rs$"
                           r"|^ghostty(-next)?($|/)|^\.github/(rust-workspaces\.toml|scripts/rust-workspaces\.py"
                           r"|workflows/rust-workspaces\.yml|actions/setup-cmux-tui-rust/)|^scripts/cmux-next/cargo-locks\.py$"
                           r"|^scripts/(install-zig-ci\.sh|ci/init-submodule\.sh)$")


def load_rust_roots(path: Path | None) -> list[str]:
    """Every listed workspace's root and `inputs` (.github/rust-workspaces.toml, from the base commit)."""
    if path is None or not path.is_file():
        return []
    import tomllib  # noqa: PLC0415

    entries = tomllib.loads(path.read_text(encoding="utf-8")).get("workspace", [])
    return sorted({p for entry in entries for p in [entry.get("root", ""), *entry.get("inputs", [])] if p})


def rust_input(path: str, roots: list[str]) -> bool:
    """Whether a base change to PATH can change a Rust workspace's result: a Rust or Cargo file anywhere, the build
    setup, or anything under a listed workspace root or input."""
    return bool(RUST_ANYWHERE.search(path)) or any(path == r or path.startswith(r.rstrip("/") + "/") for r in roots)


def check_run(fetch: Fetch, *, repo: str, run_id: str, job: str, head_tree: str, base: str,
              merge_tree: str, rust_roots: list[str] | None = None) -> dict:
    """Every check a receipt must pass; raises Rejected naming the first that fails. Returns the receipt's base, the
    run's URL and its producer."""
    run = json.loads(fetch(f"repos/{repo}/actions/runs/{run_id}"))
    url = run.get("html_url") or f"https://github.com/{repo}/actions/runs/{run_id}"
    producer = (run.get("triggering_actor") or run.get("actor") or {}).get("login") or "unknown"
    where = f"receipt run {url} (by {producer})"
    if (run.get("repository") or {}).get("full_name") != repo or (run.get("head_repository") or {}).get("full_name") != repo:
        raise Rejected(f"{where} is not a run of {repo}")
    if run.get("path") != WORKFLOW_PATH:
        raise Rejected(f"{where} is {run.get('path')!r}, not {WORKFLOW_PATH}")
    if run.get("event") != "workflow_dispatch" or run.get("head_branch") != RECEIPT_WORKFLOW_BRANCH:
        raise Rejected(f"{where} is a {run.get('event')} on {run.get('head_branch')!r}; a receipt is a dispatch on "
                       f"{RECEIPT_WORKFLOW_BRANCH} (its workflow file is {RECEIPT_WORKFLOW_BRANCH}'s)")
    if run.get("status") != "completed" or run.get("conclusion") != "success":
        raise Rejected(f"{where} is {run.get('status')}/{run.get('conclusion')}, not a pass")
    tested = TESTED.search(str(run.get("display_title", "")))
    if not tested or tested["repo"] != repo:
        raise Rejected(f"{where} is {run.get('display_title')!r}, which names no tested commit of {repo}")
    jobs = json.loads(fetch(f"repos/{repo}/actions/runs/{run_id}/jobs?per_page=20")).get("jobs") or []
    checks = [each for each in jobs if each.get("name") == JOB_NAME]
    if len(checks) != 1 or checks[0].get("conclusion") != "success":
        raise Rejected(f"{where} has no passing {JOB_NAME!r} job")
    try:
        found = parse_log(fetch(f"repos/{repo}/actions/jobs/{checks[0]['id']}/logs").decode("utf-8", "replace"))
    except LogShape as error:
        raise Rejected(f"{where}: {error}") from error
    if not same_command(found["command"], job):
        raise Rejected(f"{where} ran {found['command']!r}, not {job}'s canonical {CANONICAL[job]!r}")
    if found["directory"] != ".":
        raise Rejected(f"{where} ran in {found['directory']!r}, not the checkout's root")
    fast = found["fast_checks"] or {}
    if fast.get("exit_code") != 0 or fast.get("source_tree") != head_tree or fast.get("source_sha") != found["source"] \
            or fast.get("head_after") != fast.get("source_sha"):
        raise Rejected(f"{where}: the workflow's FAST_CHECKS_RECEIPT is not a pass on this head's tree {head_tree} "
                       f"({json.dumps(fast, sort_keys=True)[:300]})")
    receipt = found["receipt"] or {}
    if receipt.get("job") != job:
        raise Rejected(f"{where} is a receipt for {receipt.get('job')!r}, not {job}")
    if receipt.get("head") != tested["sha"]:
        raise Rejected(f"{where} merged {receipt.get('head')!r}, not the commit it tested ({tested['sha']})")
    receipt_base, receipt_tree = receipt.get("base"), receipt.get("tree")
    if not (isinstance(receipt_base, str) and SHA.match(receipt_base) and isinstance(receipt_tree, str)
            and SHA.match(receipt_tree)):
        raise Rejected(f"{where} names no base and merge tree")
    base_covers(fetch, repo=repo, job=job, where=where, receipt_base=receipt_base, receipt_tree=receipt_tree,
                base=base, merge_tree=merge_tree, rust_roots=rust_roots)
    return {"base": receipt_base, "run_url": url, "producer": producer}


def base_covers(fetch: Fetch, *, repo: str, job: str, where: str, receipt_base: str, receipt_tree: str, base: str,
                merge_tree: str, rust_roots: list[str] | None) -> None:
    """A receipt's merge covers this run's: the same base and merge tree, or an older base that is an ancestor of
    ours (for rust-workspaces, one whose commits since change no Rust input). Raises Rejected otherwise."""
    if receipt_base == base:
        if receipt_tree != merge_tree:
            raise Rejected(f"{where} tested merge tree {receipt_tree}, not this run's {merge_tree} (same base {base})")
    else:
        # One page of up to 300 files: the base's commits since the receipt's base.
        compared = json.loads(fetch(f"repos/{repo}/compare/{receipt_base}...{base}?per_page=300"))
        if compared.get("status") not in ("ahead", "identical"):
            raise Rejected(f"{where} merged onto base {receipt_base}, which is {compared.get('status')} of this "
                           f"run's base {base}, not an ancestor")
        if job == "rust-workspaces":
            if not rust_roots:
                raise Rejected(f"{where} merged onto base {receipt_base}, not this run's {base}, and the workspace "
                               "list is not here to clear the base's changes")
            files = [each.get("filename", "") for each in compared.get("files") or []]
            if len(files) >= 300:
                raise Rejected(f"{where} merged onto base {receipt_base}, {len(files)}+ files behind this run's base "
                               f"{base}; too many to clear")
            reached = [path for path in files if rust_input(path, rust_roots)]
            if reached:
                raise Rejected(f"{where} merged onto base {receipt_base}; the base has changed Rust inputs since "
                               f"({', '.join(reached[:5])}), so it needs a receipt on this run's base {base}")


# ----------------------------------------------------------------------------------------------- lane receipts
#
# Leo, 2026-11-25: "what other fundamental cuts can we make? let's do them". The lane VM already has the tree: it
# runs the canonical command itself (`python3 scripts/ci/ci_receipt.py produce fast-gates`, no cmux-ci), and on a pass
# records the receipt with the build controller over the tailnet (POST /v1/ci/lane-receipt). The controller names the
# producer by the caller's tailnet identity and signs the receipt (cmuxterm-hq build-fleet/cmd/controller/
# lane_receipt.go). The pull request's receipt job asks for it by head tree with its own OIDC token
# (POST gh-events.cmux.com/github/lane-receipt) and holds it to this run's merge like any receipt (base_covers).
# A producer whose green re-ran red is in shadow: its receipts still count as found but always re-run in full
# (audit), and the post job reports each audit back.

LANE_JOBS = ("fast-gates",)
LANE_ENDPOINT = "https://gh-events.cmux.com/github/lane-receipt"
LANE_AUDIENCE = "cmux-ci-lane-receipt"
LANE_CONTROLLER = "http://100.89.225.106:18765"  # scripts/ci/expected_wait.py DEFAULT_CONTROLLER


def lane_oidc_token(env=os.environ) -> str:
    url, bearer = env.get("ACTIONS_ID_TOKEN_REQUEST_URL", ""), env.get("ACTIONS_ID_TOKEN_REQUEST_TOKEN", "")
    if not url or not bearer:
        raise Rejected("no OIDC token here (the job needs permissions: id-token: write)")
    request = urllib.request.Request(f"{url}&audience={LANE_AUDIENCE}", headers={"Authorization": f"Bearer {bearer}"})
    try:
        status, body, _ = deadline_http.request(request, 20)
    except (urllib.error.URLError, TimeoutError, OSError) as error:
        raise Rejected(f"no OIDC token: {error}") from error
    if status >= 300:
        raise Rejected(f"no OIDC token: HTTP {status}")
    return json.loads(body)["value"]


def lane_ask(payload: dict, token: str, endpoint: str = LANE_ENDPOINT) -> dict:
    request = urllib.request.Request(endpoint, data=json.dumps(payload).encode(), method="POST", headers={
        "Authorization": f"Bearer {token}", "Content-Type": "application/json", "User-Agent": "cmux-ci-receipt"})
    try:
        status, body, _ = deadline_http.request(request, 20)
    except (urllib.error.URLError, TimeoutError, OSError) as error:
        raise Rejected(f"the controller did not answer: {error}") from error
    try:
        answer = json.loads(body or b"{}")
    except ValueError:
        answer = {}
    if status >= 300:
        raise Rejected(f"the controller answered {status}: {answer.get('error') or body[:200]!r}")
    return answer


LaneAsk = Callable[[dict], dict]


def lane_receipt(ask: LaneAsk, fetch: Fetch, args: argparse.Namespace) -> dict | None:
    """The newest lane receipt that covers this run's merge, as verify's found dict (plus shadow), or None with
    the reasons in args.lane_reasons."""
    reasons = args.lane_reasons
    answer = ask({"op": "lookup", "check": args.job, "head_tree": args.head_tree})
    for receipt in answer.get("receipts") or []:
        producer = str(receipt.get("producer") or "")
        where = f"lane receipt by {producer or 'unknown'}"
        try:
            if receipt.get("check") != args.job or receipt.get("head_tree") != args.head_tree \
                    or receipt.get("repo") != args.repo or not producer.startswith("lane:"):
                raise Rejected(f"{where} is not a {args.job} receipt of {args.repo} for head tree {args.head_tree}")
            if receipt.get("command_sha256") != hashlib.sha256(CANONICAL[args.job].encode()).hexdigest():
                raise Rejected(f"{where} ran another command than {CANONICAL[args.job]!r}")
            receipt_base, receipt_tree = receipt.get("base"), receipt.get("tree")
            if not (isinstance(receipt_base, str) and SHA.match(receipt_base) and isinstance(receipt_tree, str)
                    and SHA.match(receipt_tree)):
                raise Rejected(f"{where} names no base and merge tree")
            base_covers(fetch, repo=args.repo, job=args.job, where=where, receipt_base=receipt_base,
                        receipt_tree=receipt_tree, base=args.base, merge_tree=args.merge_tree, rust_roots=None)
        except Rejected as error:
            reasons.append(str(error))
            continue
        except (ValueError, KeyError, TypeError, AttributeError) as error:
            reasons.append(f"{where}: unreadable ({error})")
            continue
        return {"base": receipt_base, "producer": producer, "shadow": receipt.get("shadow") is True,
                "seed": str(receipt.get("sig") or producer)}
    if not answer.get("receipts"):
        reasons.append(answer.get("reason") or "no lane receipt for this head tree")
    return None


def audited(seed: str, head: str, percent: int) -> bool:
    """Seeded by the head and the receipt run: the same receipt on the same head always gets the same answer."""
    digest = int(hashlib.sha256(f"{seed}:{head}".encode()).hexdigest()[:8], 16)
    return digest % 100 < max(0, min(100, percent))


def verify(args: argparse.Namespace, fetch: Fetch | None = None, lane_ask_fn: LaneAsk | None = None) -> dict:
    out = {"valid": "false", "audit": "false", "base": "", "run_url": "", "producer": "", "reason": ""}
    body = Path(args.body_file).read_text(encoding="utf-8") if args.body_file else os.environ.get("PR_BODY", "")
    runs = pointers(body, args.job, args.repo)
    pr = getattr(args, "pr", None)
    lane = getattr(args, "lane", False) and args.job in LANE_JOBS
    if not runs and not pr and not lane:
        out["reason"] = f"no CI-Receipt: {args.job} line in the pull request body"
        return out
    for value in (args.head, args.base, args.head_tree, args.merge_tree):
        if not SHA.match(value or ""):
            out["reason"] = f"unresolved head, base or tree ({value!r})"
            return out
    if fetch is None:
        token = os.environ.get("GH_TOKEN", "")
        if not token:
            out["reason"] = "no GH_TOKEN to read the receipt run"
            return out
        fetch = github_fetch(token)
    lane_reasons: list[str] = []
    if lane:
        args.lane_reasons = lane_reasons
        try:
            ask = lane_ask_fn or (lambda payload, token=lane_oidc_token(): lane_ask(payload, token))
            found = lane_receipt(ask, fetch, args)
        except Rejected as error:
            lane_reasons.append(f"lane receipt lookup: {error}")
            found = None
        if found:
            run_url = os.environ.get("RUN_URL_SELF", "")
            out.update(base=found["base"], producer=found["producer"], run_url=run_url, valid="true",
                       reason=f"lane receipt by {found['producer']} covers {args.job} on head {args.head}, base "
                              f"{found['base']}" + ("; its producer is in shadow, so the gates run in full"
                                                    if found["shadow"] else ""))
            out["audit"] = "true" if found["shadow"] or audited(found["seed"], args.head, args.audit_percent) \
                else "false"
            return out
        if not runs and not pr:
            out["reason"] = "; ".join(lane_reasons)
            return out
    if not runs:
        try:
            runs = discover(fetch, args.repo, pr, args.head)
        except (Rejected, ValueError, KeyError, TypeError, AttributeError) as error:
            out["reason"] = f"no CI-Receipt: {args.job} line in the pull request body, and the search for a run failed ({error})"
            return out
        if not runs:
            out["reason"] = "; ".join([*lane_reasons, f"no CI-Receipt: {args.job} line in the pull request body, and no "
                                                   "passing Fast checks run of this pull request's commits"])
            return out
    reasons = []
    # The last line names the newest receipt; read back from it.
    for run_id in reversed(runs[-3:]):
        try:
            found = check_run(fetch, repo=args.repo, run_id=run_id, job=args.job, head_tree=args.head_tree,
                              base=args.base, merge_tree=args.merge_tree,
                              rust_roots=load_rust_roots(args.workspaces))
        except Rejected as error:
            reasons.append(str(error))
            continue
        except (ValueError, KeyError, TypeError, AttributeError) as error:
            reasons.append(f"receipt run {run_id}: unreadable answer ({error})")
            continue
        out.update(found, valid="true", reason=f"receipt run {found['run_url']} (by {found['producer']}) covers "
                                                f"{args.job} on head {args.head}, base {found['base']}")
        out["audit"] = "true" if audited(run_id, args.head, args.audit_percent) else "false"
        return out
    out["reason"] = "; ".join([*lane_reasons, *reasons])
    return out


def write_outputs(path: Path | None, values: dict[str, str]) -> None:
    lines = "".join(f"{key}={str(value).replace(chr(10), ' ')}\n" for key, value in values.items())
    print(lines, end="")
    if path:
        with path.open("a", encoding="utf-8") as stream:
            stream.write(lines)


# ----------------------------------------------------------------------------------------------- produce


def git(repo: Path, *args: str, check: bool = True) -> subprocess.CompletedProcess:
    result = subprocess.run(["git", "-C", str(repo), *args], capture_output=True, text=True)
    if check and result.returncode != 0:
        raise SystemExit(f"ci-receipt: git {' '.join(args)} failed: {result.stderr.strip()}")
    return result


def tested_head(repo: Path) -> str:
    """The commit under test: fast-checks' snapshot's only parent when it has the same tree, else HEAD itself."""
    head = git(repo, "rev-parse", "HEAD").stdout.strip()
    parents = git(repo, "rev-list", "--parents", "-n", "1", "HEAD").stdout.split()[1:]
    if len(parents) == 1 and git(repo, "rev-parse", f"{parents[0]}^{{tree}}", check=False).stdout.strip() == \
            git(repo, "rev-parse", "HEAD^{tree}").stdout.strip():
        return parents[0]
    return head


def merge_worktree(repo: Path, remote: str, head: str, into: Path) -> str:
    """Fetch the feat-cmux-next tip, deepen until it meets HEAD, and merge HEAD into it at INTO (a worktree, so the
    checkout's own HEAD never moves). Returns the base."""
    sys.path.insert(0, str(repo / "scripts" / "ci"))
    import cmux_next_fast_gates as gates  # noqa: PLC0415

    ref = "refs/ci-receipt/base"
    shallow = git(repo, "rev-parse", "--is-shallow-repository").stdout.strip() == "true"
    depth = [f"--depth={gates.FETCH_DEPTH}", gates.DEEPEN_FILTER] if shallow else []
    git(repo, "fetch", "--no-tags", "--quiet", *depth, remote, f"+refs/heads/{BRANCH}:{ref}")
    base = git(repo, "rev-parse", ref).stdout.strip()
    # The tested commit's own history is cut at depth 2 too: deepen both sides until they meet.
    gates.deepen(repo, remote, [f"+refs/heads/{BRANCH}:{ref}", head], head, base)
    git(repo, "worktree", "prune")
    git(repo, "worktree", "add", "--quiet", "--detach", str(into), base)
    merged = git(into, *MERGE_IDENTITY, "merge", "--no-ff", "--no-edit", "--quiet", head, check=False)
    if merged.returncode != 0:
        raise SystemExit(f"ci-receipt: {head} does not merge cleanly into {BRANCH} ({base}); merge {BRANCH} into the "
                         f"branch and push: {merged.stdout.strip()} {merged.stderr.strip()}")
    return base


def produce_fast_gates(work: Path, head: str, base: str) -> int:
    output = work.parent / "prepare-outputs"
    script = [sys.executable, "scripts/ci/cmux_next_fast_gates.py"]
    prepared = subprocess.run([*script, "prepare", "--event", "pull_request", "--head", head, "--base", base,
                               "--output", str(output)], cwd=work)
    if prepared.returncode != 0:
        return prepared.returncode
    values = dict(line.split("=", 1) for line in output.read_text().splitlines() if "=" in line)
    output.unlink()
    if values.get("web") == "true" and not shutil.which("bun"):
        log("ci-receipt: this change needs web lint and there is no bun here: cmux-ci test --setup webviews -- "
            f"{CANONICAL['fast-gates']}")
        return 2
    return subprocess.run([*script, "run", "--base", base, "--web", values.get("web", "true"),
                           "--checks", values.get("checks", "false"), "--budget-seconds", "1260"], cwd=work).returncode


def produce_rust_workspaces(work: Path, head: str, base: str) -> int:
    del head
    script = [sys.executable, ".github/scripts/rust-workspaces.py"]
    for step in ([sys.executable, ".github/scripts/test_rust_workspaces.py"], [*script, "check"],
                 [sys.executable, "scripts/cmux-next/cargo-locks.py", "check", "--strict", "--base", base,
                  "--deadline", "840"]):
        code = subprocess.run(step, cwd=work).returncode
        if code != 0:
            return code
    planned = json.loads(subprocess.run([*script, "plan", "--base", base], cwd=work, check=True,
                                        capture_output=True, text=True).stdout)
    for entry in planned:
        log(f"ci-receipt: rust workspace {entry['root']}")
        # rust-workspaces.yml's workspace job setup: its apt packages and the ghostty-next submodule.
        if entry.get("apt"):
            code = subprocess.run(["sudo", "apt-get", "install", "-y", *entry["apt"].split()]).returncode
            if code != 0:
                return code
        if entry.get("ghostty"):
            code = subprocess.run(["bash", "scripts/ci/init-submodule.sh", "ghostty-next"], cwd=work).returncode
            if code != 0:
                return code
        env = {**os.environ, "GHOSTTY_ZIG_SOURCE": "ghostty-next", "CMUX_GHOSTTY_SRC": ""}
        subprocess.run(["rustup", "toolchain", "install"], cwd=work / entry["root"], env=env)
        code = subprocess.run([*script, "run", entry["root"]], cwd=work, env=env).returncode
        if code != 0:
            return code
    return 0


def produce(args: argparse.Namespace) -> int:
    repo = Path(git(Path.cwd(), "rev-parse", "--show-toplevel").stdout.strip())
    # The receipt names a commit's tree, and the merge is made from that commit: a tracked edit not in it would be
    # neither tested nor named, so refuse it rather than claim a tree the edit is not in.
    dirty = git(repo, "status", "--porcelain", "--untracked-files=no").stdout.strip()
    if dirty:
        log(f"ci-receipt: the checkout has tracked changes not in HEAD ({dirty.splitlines()[0]}...); commit them first")
        return 2
    head = tested_head(repo)
    started = time.monotonic()
    with tempfile.TemporaryDirectory(prefix="ci-receipt-") as scratch:
        work = Path(scratch) / "merge"
        try:
            base = merge_worktree(repo, args.remote, head, work)
            tree = git(work, "rev-parse", "HEAD^{tree}").stdout.strip()
            log(f"ci-receipt: {args.job} on {head} merged into {BRANCH} {base} (tree {tree})")
            runner = produce_fast_gates if args.job == "fast-gates" else produce_rust_workspaces
            code = runner(work, head, base)
        finally:
            git(repo, "worktree", "remove", "--force", str(work), check=False)
    if code != 0:
        log(f"ci-receipt: {args.job} failed (exit {code}); no receipt")
        return code
    print("CMUX_CI_RECEIPT=" + json.dumps({"v": 1, "job": args.job, "head": head, "base": base, "tree": tree},
                                          sort_keys=True), flush=True)
    if lane_records(args):
        head_tree = git(repo, "rev-parse", f"{head}^{{tree}}").stdout.strip()
        return record_lane(args.job, head=head, head_tree=head_tree, base=base, merge_tree=tree,
                           seconds=round(time.monotonic() - started, 1))
    print(f"ci-receipt: passed. Add this line to the pull request body (the run's URL is in cmux-ci's output):\n"
          f"  CI-Receipt: {args.job} https://github.com/manaflow-ai/cmux/actions/runs/{os.environ.get('GITHUB_RUN_ID', 'RUN_ID')}\n"
          "then push (an empty commit keeps the tree, and with it the receipt): the run reads the body its event "
          "carries",
          flush=True)
    return 0


def lane_records(args: argparse.Namespace, env=os.environ) -> bool:
    """Record with the controller: on by default on a lane or laptop (not inside GitHub Actions, where the run itself
    is the receipt), for a job lane receipts cover; --no-record turns it off."""
    return args.job in LANE_JOBS and getattr(args, "record", True) and env.get("GITHUB_ACTIONS") != "true"


def record_lane(job: str, *, head: str, head_tree: str, base: str, merge_tree: str, seconds: float,
                post: Callable[[str, bytes], tuple[int, bytes]] | None = None, env=os.environ) -> int:
    """POST the pass to the controller's /v1/ci/lane-receipt. The controller names the producer (the tailnet node)
    and signs it. A refusal or no answer is no receipt (exit 0: the pass stands and the PR's gates simply run)."""
    controller = (env.get("CMUX_CI_CONTROLLER") or LANE_CONTROLLER).rstrip("/")
    payload = {"repo": env.get("CI_RECEIPT_REPO", "manaflow-ai/cmux"), "check": job, "head": head,
               "head_tree": head_tree, "base": base, "merge_tree": merge_tree, "command": CANONICAL[job], "exit": 0,
               "log_sha256": "", "seconds": seconds,
               "session": env.get("ACPMUX_SESSION_NAME") or env.get("CMUX_AGENT_NAME") or ""}
    url = f"{controller}/v1/ci/lane-receipt"
    if post is None:
        def post(target: str, data: bytes) -> tuple[int, bytes]:
            request = urllib.request.Request(target, data=data, method="POST", headers={
                "Content-Type": "application/json", "User-Agent": "cmux-ci-receipt"})
            status, body, _ = deadline_http.request(request, 20)
            return status, body
    try:
        status, body = post(url, json.dumps(payload).encode())
    except (urllib.error.URLError, TimeoutError, OSError) as error:
        log(f"ci-receipt: passed, but the controller did not answer ({error}); no lane receipt, the PR's gates run")
        return 0
    if status >= 300:
        log(f"ci-receipt: passed, but the controller refused the lane receipt ({status}: {body[:300]!r}); the PR's "
            "gates run")
        return 0
    producer = (json.loads(body or b"{}").get("receipt") or {}).get("producer", "?")
    print(f"ci-receipt: passed and recorded: lane receipt for head tree {head_tree} on base {base[:12]} by "
          f"{producer}. Push this tree (any commit with it): the PR's fast gates take the receipt instead of "
          "re-running.", flush=True)
    return 0


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    sub = parser.add_subparsers(dest="mode", required=True)
    make = sub.add_parser("produce")
    make.add_argument("job", choices=JOBS)
    make.add_argument("--remote", default="origin")
    make.add_argument("--no-record", dest="record", action="store_false",
                      help="do not record a lane receipt with the controller (recorded by default outside Actions)")
    check = sub.add_parser("verify")
    check.add_argument("job", choices=JOBS)
    check.add_argument("--repo", required=True)
    check.add_argument("--head", required=True)
    check.add_argument("--base", required=True)
    check.add_argument("--head-tree", required=True)
    check.add_argument("--merge-tree", required=True)
    check.add_argument("--body-file", help="the pull request body (default: $PR_BODY)")
    check.add_argument("--audit-percent", type=lambda v: int(v) if v.strip() else DEFAULT_AUDIT_PERCENT,
                       default=DEFAULT_AUDIT_PERCENT)
    check.add_argument("--pr", type=int, help="the pull request's number: with no CI-Receipt line in the body, find "
                       "the passing Fast checks run of one of its commits (discover)")
    check.add_argument("--output", type=Path)
    check.add_argument("--lane", action="store_true", help="also ask the controller for a lane receipt of this head "
                       "tree (needs id-token: write)")
    check.add_argument("--workspaces", type=Path, help=".github/rust-workspaces.toml (rust-workspaces, from the base)")
    args = parser.parse_args(argv)
    if args.mode == "produce":
        return produce(args)
    result = verify(args)
    write_outputs(args.output, result)
    if result["valid"] == "true":
        print(f"::notice title=CI receipt::{result['reason']}" + ("; audit: this run still runs in full"
                                                                  if result["audit"] == "true" else ""))
    elif result["reason"]:
        print(f"::notice title=CI receipt::not used: {result['reason'][:900]}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
