#!/usr/bin/env python3
"""Same-tree reuse: a job that already passed on this exact tree is not run again.

The same tree should never be tested twice. A pull request job that passed records a receipt in the GitHub Actions
cache under a key of everything its result is a function of:

    same-tree-v1-<job id>-<workflow file blob>-<tree>

- the tree of the commit the job tests (`git rev-parse <sha>^{tree}`; a pull_request run tests its merge commit), so
  a re-push with an unchanged tree, a rebase onto the same base, a reopen, an `edited` or `labeled` re-trigger or a
  "re-run all jobs" finds it, and any other change does not;
- the job id;
- the blob of the workflow file at that commit, so a changed workflow never reuses a pass.

Before the job takes its runner, a pre-job the job already waits on (its `host`, a placement or plan job) computes
the keys (`keys`), restores each one with actions/cache/restore and decides (`decide`). On a hit the job is skipped,
and the host's annotation and step summary name the run that passed. The Actions cache costs no API quota and no
secret. GitHub scopes it: a pull request reads entries its own runs wrote and its base branch's, never another pull
request's, so a fork or another branch cannot plant a receipt. Only same-repository pull requests read or write.

Detector: CI_SAME_TREE_AUDIT_PERCENT (default 10) of hits still run in full, seeded by the key and the run attempt;
a red there names the receipt it contradicts (the job's audit step). `vars.CI_SAME_TREE_REUSE == '0'` turns lookups
off; every job then runs.

Which jobs may reuse (scripts/ci/same_tree_reuse.json): every job of a pull-request-triggered workflow is either
`wired` or on the `deny` list with its reason; tests/test_same_tree_reuse.py holds every one to that. A job is
eligible only when its pass is a pure function of the key (`blockers`): no pull_request_target, reusable workflow,
matrix, outputs, dependents, secrets, write permission, pull request metadata or base ref, checkout of another ref,
publish/release/live/cloud work, or `always()` judging of other jobs.

Input-scoped keys (`inputs` in same_tree_reuse.json). A whole-tree key hits only when the exact tree was already
checked: a re-run, or a merge commit identical to an up-to-date head. A job whose `inputs` are listed keys only them:

    same-inputs-v1-<job id>-<workflow file blob>-<sha1 of the input manifest>

the manifest being every `git ls-tree -r` entry (mode, object id, path) at the commit under test that the job's
patterns match (GitHub path-filter syntax: `**`, `*`, a leading `!` excludes, the last match wins), plus the patterns
themselves. This file and same_tree_reuse.json are inputs of every input-scoped job, so a change to the list or to
this script never reuses a pass keyed by the old one. The list must be a superset of what the job reads: a path it
reads and the list misses lets a pass stand for a change that was never checked; when unsure, list more.

Two hits come from such a key:
- a receipt (as above) under the same key: the job passed on these inputs before, in this pull request or on the base;
- the base's key (`keys --base-rev`): the change leaves every input as it is on the base (a pull request's merge
  commit against its first parent, a push against the previous tip). The job's verdict is then the base's, which the
  base push run gives; the job is not run here. This is affected-only selection, keyed by the same manifest.
A job that failed records a red receipt (`<key>-red`): the decision names it (`known_red`, the run that failed on the
same inputs) and the job still runs; a red receipt never passes a check. Receipts are written only by runs that
checked their inputs (the job's receipt steps say when).

Cost (last 52 merged PRs before this change, cmux#47096's stack): 6,234 finished PR job-runs, 13,305 job-minutes;
only 22 minutes ran on a merge tree that already had a green run of the same job (21 of them metadata-triggered
jobs that are not tree-pure), 96 on an already-green head tree. A receipt write is ~2 s per green job, so a job is
wired only where that is below what it saves; the rest say so on the deny list.

usage:
  same_tree_reuse.py keys --workflow PATH --jobs A[,B] [--rev SHA] [--repo DIR] [--base-rev REV]
        -> `<job>=<key>` and `keys=<json>` lines; with --base-rev, `base_keys=<json>` (input-scoped jobs only)
  same_tree_reuse.py decide --keys JSON --hits JOB=true,... [--base-keys JSON] [--receipts DIR] [--audit-percent N]
                            [--run-id ID] [--attempt N]                 -> `same_tree=<json>` line
  same_tree_reuse.py receipt --job JOB --key KEY --out DIR [--conclusion success|failure]
        -> writes DIR/receipt.json for the cache save (a failure is saved under KEY-red)
  same_tree_reuse.py check [--root DIR]                                 -> coverage and wiring of every PR job
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import subprocess
import sys
from pathlib import Path

VERSION = "v1"
PREFIX = f"same-tree-{VERSION}"
SHA = re.compile(r"^[0-9a-f]{40}$")
JOB_ID = re.compile(r"^[A-Za-z_][A-Za-z0-9_-]*$")
INPUTS_PREFIX = f"same-inputs-{VERSION}"
KEY = re.compile(rf"^(?:{PREFIX}|{INPUTS_PREFIX})-(?P<job>[A-Za-z_][A-Za-z0-9_-]*)-(?P<blob>[0-9a-f]{{12}})"
                 r"-(?P<tree>[0-9a-f]{40})$")
# Inputs of every input-scoped job: the keying itself.
ALWAYS_INPUTS = ("scripts/ci/same_tree_reuse.py", "scripts/ci/same_tree_reuse.json")
# What an input-scoped job may read of the event: the base it diffs its inputs against.
BASE_META = frozenset({"github.event.pull_request.base.sha", "github.event.before"})
GIT_ENV = {**os.environ, "GIT_NO_LAZY_FETCH": "1"}
DEFAULT_AUDIT_PERCENT = 10
CONFIG = Path(__file__).with_name("same_tree_reuse.json")
PR_EVENTS = ("pull_request", "pull_request_target", "merge_group")

# ------------------------------------------------------------------------------------------------- runtime


def git(*args: str, cwd: str | None = None) -> str:
    # A partial clone never fetches a missing object here: a missing tree is no key (every job runs), not a hang.
    return subprocess.run(["git", *args], cwd=cwd, check=True, capture_output=True, text=True,
                          env=GIT_ENV).stdout.strip()


def make_key(job: str, workflow_blob: str, tree: str, prefix: str = PREFIX) -> str:
    if not JOB_ID.match(job) or not SHA.match(workflow_blob) or not SHA.match(tree):
        raise ValueError(f"not a job id, blob and tree: {job!r} {workflow_blob!r} {tree!r}")
    return f"{prefix}-{job}-{workflow_blob[:12]}-{tree}"


def glob_re(pattern: str) -> re.Pattern:
    """A GitHub path-filter glob: `**` crosses folders, `*` and `?` do not."""
    out, i = "", 0
    while i < len(pattern):
        if pattern.startswith("**/", i):
            out, i = out + "(?:.*/)?", i + 3
        elif pattern.startswith("**", i):
            out, i = out + ".*", i + 2
        elif pattern[i] == "*":
            out, i = out + "[^/]*", i + 1
        elif pattern[i] == "?":
            out, i = out + "[^/]", i + 1
        else:
            out, i = out + re.escape(pattern[i]), i + 1
    return re.compile(out + r"\Z")


def input_patterns(config: dict, workflow_name: str, job: str) -> list[str] | None:
    """JOB's input patterns from the config's wired entry, with the keying's own files; None: whole-tree job."""
    listed = ((config.get("wired") or {}).get(workflow_name) or {}).get("inputs", {}).get(job)
    if not listed:
        return None
    return list(listed) + [p for p in ALWAYS_INPUTS if p not in listed]


def input_digest(rev: str, patterns: list[str], cwd: str | None = None) -> str:
    """sha1 of the patterns and of every tree entry at REV they match (mode, object id, path)."""
    rules = [(p.startswith("!"), glob_re(p[1:] if p.startswith("!") else p)) for p in patterns]
    digest = hashlib.sha1(json.dumps(patterns).encode())
    listing = subprocess.run(["git", "ls-tree", "-r", "--full-tree", "-z", rev], cwd=cwd, check=True,
                             capture_output=True, env=GIT_ENV).stdout.decode("utf-8", "surrogateescape")
    for entry in listing.split("\0"):
        if not entry:
            continue
        meta, path = entry.split("\t", 1)
        selected = False
        for negated, rule in rules:
            if rule.match(path):
                selected = not negated
        if selected:
            mode, _, oid = meta.split()
            digest.update(f"{mode} {oid} {path}\n".encode("utf-8", "surrogateescape"))
    return digest.hexdigest()


def keys(workflow: str, jobs: list[str], rev: str = "HEAD", cwd: str | None = None,
         config: dict | None = None) -> dict[str, str]:
    """The key of each job at REV: its tree (or, for a job with `inputs`, the digest of its inputs) and its workflow
    file's blob there (a job-runtime read of trees, no blobs)."""
    config = json.loads(CONFIG.read_text()) if config is None else config
    name = Path(workflow).name
    blob = git("rev-parse", f"{rev}:{workflow}", cwd=cwd)
    out, tree = {}, None
    for job in jobs:
        patterns = input_patterns(config, name, job)
        if patterns is None:
            tree = tree or git("rev-parse", f"{rev}^{{tree}}", cwd=cwd)
            out[job] = make_key(job, blob, tree)
        else:
            out[job] = make_key(job, blob, input_digest(rev, patterns, cwd), INPUTS_PREFIX)
    return out


def audit_pick(key: str, run_id: str, attempt: str, percent: int) -> bool:
    """Whether a hit still runs in full. Seeded by the key and the run attempt, so a re-run re-rolls it."""
    if percent <= 0:
        return False
    if percent >= 100:
        return True
    digest = hashlib.sha256(f"{key}:{run_id}:{attempt}".encode()).digest()
    return int.from_bytes(digest[:8], "big") % 100 < percent


def parse_hits(text: str) -> dict[str, bool]:
    hits = {}
    for part in (text or "").split(","):
        if "=" in part:
            job, value = part.split("=", 1)
            hits[job.strip()] = value.strip() == "true"
    return hits


def read_receipt(directory: Path | None, job: str) -> dict:
    if directory is None:
        return {}
    try:
        data = json.loads((directory / job / "receipt.json").read_text())
    except (OSError, ValueError):
        return {}
    return data if isinstance(data, dict) else {}


def decide(job_keys: dict[str, str], hits: dict[str, bool], receipts: Path | None, audit_percent: int,
           run_id: str, attempt: str, base_keys: dict[str, str] | None = None) -> dict[str, dict]:
    """Per job: `reuse` (skip it), `audit` (a hit that runs anyway), `record` (write a receipt on a pass),
    `inherit` (the inputs are the base's: its verdict stands), `known_red` (a run that failed on the same inputs)."""
    out = {}
    for job, key in job_keys.items():
        receipt = read_receipt(receipts, job)
        # A restored entry that does not name this key and job is no receipt (an old or foreign layout): run.
        mine = receipt.get("key") == key and receipt.get("job") == job
        red = mine and receipt.get("conclusion") == "failure"
        hit = bool(hits.get(job)) and mine and not red
        inherit = not hit and bool(key) and (base_keys or {}).get(job) == key and key.startswith(INPUTS_PREFIX)
        audit = (hit or inherit) and audit_pick(key, run_id, attempt, audit_percent)
        out[job] = {"key": key, "reuse": (hit or inherit) and not audit, "audit": audit, "record": not hit,
                    "inherit": inherit, "receipt": receipt.get("run_url", "") if hit else "",
                    "known_red": receipt.get("run_url", "") or "an earlier run" if red else ""}
    return out


def summary_lines(decisions: dict[str, dict]) -> list[str]:
    lines = []
    for job, d in decisions.items():
        tree = KEY.match(d["key"])["tree"] if KEY.match(d["key"]) else "?"
        if d.get("inherit"):
            lines.append(f"- `{job}`: its inputs ({tree[:12]}) are the base's; the base's verdict stands"
                         + ("; runs in full anyway (sampled audit)" if d["audit"] else "; not run here"))
        elif d.get("known_red"):
            lines.append(f"- `{job}`: failed on these inputs in {d['known_red']} (a known red); runs again")
        elif d["reuse"]:
            lines.append(f"- `{job}`: passed on this tree ({tree[:12]}) in {d['receipt'] or 'an earlier run'}; "
                         "not run again")
        elif d["audit"]:
            lines.append(f"- `{job}`: passed on this tree in {d['receipt'] or 'an earlier run'}; runs in full anyway "
                         "(sampled audit)")
        else:
            lines.append(f"- `{job}`: no pass on this tree yet; runs")
    return lines


# ------------------------------------------------------------------------------------------------- static rules

LIVE = re.compile(r"deploy|publish|release|rollback|promote|probe|smoke|journey|canary|nightly|migrat|upload|seal"
                  r"|live|cloud|e2e|staging|production", re.I)
META = re.compile(r"github\.event\.(?:pull_request\.(?:body|title|labels|draft|user|number|head\.sha|head\.ref"
                  r"|base\.sha|base\.ref)|label|action|number|changes|before)|github\.(?:head_ref|base_ref)")
SECRET = re.compile(r"secrets\.(?!GITHUB_TOKEN\b)[A-Za-z_]")
JUDGE = re.compile(r"always\(\)|failure\(\)")


def load_yaml(path: Path):
    import yaml  # PyYAML: the guard venv and the Linux runners have it.

    return yaml.load(path.read_text(), Loader=yaml.BaseLoader)


def events(workflow: dict) -> list[str]:
    on = workflow.get("on") or {}
    if isinstance(on, str):
        return [on]
    return list(on)


def pr_workflows(root: Path) -> dict[str, dict]:
    out = {}
    for path in sorted((root / ".github" / "workflows").glob("*.yml")):
        data = load_yaml(path)
        if isinstance(data, dict) and any(e in PR_EVENTS for e in events(data)):
            out[path.name] = data
    return out


def job_text(job: dict) -> str:
    return json.dumps(job, sort_keys=True)


def blockers(workflow: dict, job_id: str, input_scoped: bool = False) -> list[str]:
    """Why JOB's pass is not a pure function of (tree, job, workflow blob), or why a skip would break the run.
    An input-scoped job may read the base it diffs its inputs against (BASE_META): its key is its inputs."""
    jobs = workflow.get("jobs") or {}
    job = jobs[job_id]
    text = job_text(job)
    found = []
    ev = events(workflow)
    if "pull_request" not in ev and "merge_group" not in ev:
        found.append("pull_request_target only: runs the base's workflow with write access, not the tree under test")
    if "uses" in job:
        found.append("calls a reusable workflow: no step here can record its pass")
    if isinstance(job.get("strategy"), dict) and job["strategy"].get("matrix") is not None:
        found.append("matrix: a job-level skip cannot see one leg's receipt")
    if job.get("outputs"):
        found.append("its outputs feed later jobs; a skipped run leaves them empty")
    dependents = sorted(other for other, j in jobs.items()
                        if job_id in ([j.get("needs")] if isinstance(j.get("needs"), str) else (j.get("needs") or [])))
    if dependents:
        found.append(f"needed by {', '.join(dependents)}: a skip would skip them or read as no verdict")
    if SECRET.search(text):
        found.append("reads secrets")
    permissions = job.get("permissions", workflow.get("permissions"))
    if (isinstance(permissions, dict) and "write" in permissions.values()) or \
            (isinstance(permissions, str) and "write" in permissions):
        found.append("writes to GitHub (a write permission): a side effect, not a verdict on the tree")
    meta = sorted(set(m.group(0) for m in META.finditer(text)) - (BASE_META if input_scoped else set()))
    if meta:
        found.append(f"reads pull request metadata or the base ({', '.join(meta[:3])}), not only the tree")
    for step in job.get("steps") or []:
        if isinstance(step, dict) and str(step.get("uses", "")).startswith("actions/checkout"):
            ref = (step.get("with") or {}).get("ref") if isinstance(step.get("with"), dict) else None
            if ref not in (None, "${{ github.sha }}"):
                found.append(f"checks out {ref}, not the run's commit")
                break
    if LIVE.search(f"{job_id} {job.get('name', '')}"):
        found.append("publish, release, deploy, live or cloud work (by its name)")
    if JUDGE.search(str(job.get("if", ""))):
        found.append("judges other jobs (if: always() or failure())")
    return found


# The steps a wired job and its host must carry (tests/test_same_tree_reuse.py reads them through `check`).
HOST_STEP_IDS = ("same-tree-keys", "same-tree")
JOB_STEP_NAMES = ("Same-tree audit", "Write the same-tree receipt", "Record the same-tree receipt")


def wiring_errors(name: str, workflow: dict, host: str, job_id: str) -> list[str]:
    jobs = workflow.get("jobs") or {}
    errors = []
    if host not in jobs:
        return [f"{name}: host job {host} does not exist"]
    if job_id not in jobs:
        return [f"{name}: wired job {job_id} does not exist"]
    host_job, job = jobs[host], jobs[job_id]
    needs = job.get("needs") or []
    needs = [needs] if isinstance(needs, str) else needs
    if host not in needs:
        errors.append(f"{name}: {job_id} must need {host}, which looks up its receipt before it takes a runner")
    if "same_tree" not in (host_job.get("outputs") or {}):
        errors.append(f"{name}: {host} must output same_tree")
    ids = [s.get("id") for s in host_job.get("steps") or [] if isinstance(s, dict)]
    for step_id in HOST_STEP_IDS + (f"same-tree-{job_id}",):
        if step_id not in ids:
            errors.append(f"{name}: {host} has no step id {step_id}")
    guard = f"fromJSON(needs.{host}.outputs.same_tree || '{{}}')['{job_id}'].reuse"
    if guard not in str(job.get("if", "")):
        errors.append(f"{name}: {job_id}'s if must skip on {guard}")
    names = [s.get("name") for s in job.get("steps") or [] if isinstance(s, dict)]
    if names[-len(JOB_STEP_NAMES):] != list(JOB_STEP_NAMES):
        errors.append(f"{name}: {job_id} must end with the steps {', '.join(JOB_STEP_NAMES)}")
    return errors


def check(root: Path, config: dict) -> list[str]:
    """Every pull-request job is wired or denied with a reason; wired jobs are pure and carry their steps."""
    errors = []
    workflows = pr_workflows(root)
    wired = config.get("wired", {})
    deny = config.get("deny", {})
    for name, entry in wired.items():
        if name not in workflows:
            errors.append(f"wired: {name} is not a pull-request workflow")
            continue
        for job_id, patterns in (entry.get("inputs") or {}).items():
            if job_id not in entry.get("jobs", []):
                errors.append(f"{name}: inputs list {job_id}, which is not wired")
            if not isinstance(patterns, list) or not patterns or not all(isinstance(p, str) and p for p in patterns):
                errors.append(f"{name}: {job_id}'s inputs must be a list of path patterns")
        for job_id in entry.get("jobs", []):
            scoped = job_id in (entry.get("inputs") or {})
            for reason in blockers(workflows[name], job_id, scoped) if job_id in (workflows[name].get("jobs") or {}) \
                    else []:
                errors.append(f"{name}: {job_id} is wired but {reason}")
            errors += wiring_errors(name, workflows[name], entry.get("host", ""), job_id)
    for name, entries in deny.items():
        if name not in workflows:
            errors.append(f"deny: {name} is not a pull-request workflow (remove it)")
            continue
        for job_id, reason in entries.items():
            if job_id not in (workflows[name].get("jobs") or {}):
                errors.append(f"deny: {name}: {job_id} is no job there (remove it)")
            if not str(reason).strip():
                errors.append(f"deny: {name}: {job_id} has no reason")
    for name, workflow in workflows.items():
        wired_jobs = set(wired.get(name, {}).get("jobs", []))
        denied = set(deny.get(name, {}))
        for job_id in workflow.get("jobs") or {}:
            if job_id in wired_jobs and job_id in denied:
                errors.append(f"{name}: {job_id} is both wired and denied")
            elif job_id not in wired_jobs and job_id not in denied:
                why = blockers(workflow, job_id) or ["eligible: wire it, or deny it with why it does not pay"]
                errors.append(f"{name}: {job_id} is neither wired nor denied; suggested: {json.dumps(why[0])}")
    return errors


# ------------------------------------------------------------------------------------------------- cli


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n", 1)[0])
    sub = parser.add_subparsers(dest="command", required=True)
    p = sub.add_parser("keys")
    p.add_argument("--workflow", required=True)
    p.add_argument("--jobs", required=True)
    p.add_argument("--rev", default="HEAD")
    p.add_argument("--repo", help="the checkout to key (default: the working directory)")
    p.add_argument("--base-rev", default="", help="also print the base's keys of the input-scoped jobs")
    p = sub.add_parser("decide")
    p.add_argument("--keys", required=True)
    p.add_argument("--hits", default="")
    p.add_argument("--base-keys", default="")
    p.add_argument("--receipts")
    p.add_argument("--audit-percent", default="")
    p.add_argument("--run-id", default=os.environ.get("GITHUB_RUN_ID", ""))
    p.add_argument("--attempt", default=os.environ.get("GITHUB_RUN_ATTEMPT", ""))
    p = sub.add_parser("receipt")
    p.add_argument("--job", required=True)
    p.add_argument("--key", required=True)
    p.add_argument("--out", required=True)
    p.add_argument("--conclusion", choices=("success", "failure"), default="success")
    p = sub.add_parser("check")
    p.add_argument("--root", default=str(Path(__file__).resolve().parents[2]))
    args = parser.parse_args(argv)

    if args.command == "keys":
        jobs = [j.strip() for j in args.jobs.split(",") if j.strip()]
        try:
            found = keys(args.workflow, jobs, args.rev, cwd=args.repo)
        except (subprocess.CalledProcessError, ValueError, OSError) as error:
            # No key is no lookup and no record: every job runs.
            print(f"::notice title=same-tree reuse::no key ({error}); every job runs", file=sys.stderr)
            return 0
        for job, key in found.items():
            print(f"{job}={key}")
        print(f"keys={json.dumps(found, separators=(',', ':'))}")
        if args.base_rev:
            try:
                base = {j: k for j, k in keys(args.workflow, jobs, args.base_rev, cwd=args.repo).items()
                        if k.startswith(INPUTS_PREFIX)}
            except (subprocess.CalledProcessError, ValueError, OSError) as error:
                # No base key is no inherited verdict: the jobs look up receipts only.
                print(f"::notice title=same-tree reuse::no base key ({error})", file=sys.stderr)
                base = {}
            print(f"base_keys={json.dumps(base, separators=(',', ':'))}")
        return 0

    if args.command == "decide":
        try:
            job_keys = json.loads(args.keys)
            base_keys = json.loads(args.base_keys) if args.base_keys.strip() else {}
            percent = int(args.audit_percent) if str(args.audit_percent).strip() else DEFAULT_AUDIT_PERCENT
        except ValueError as error:
            print(f"::notice title=same-tree reuse::unreadable input ({error}); every job runs", file=sys.stderr)
            return 0
        decisions = decide(job_keys, parse_hits(args.hits), Path(args.receipts) if args.receipts else None,
                           percent, args.run_id, args.attempt, base_keys)
        for job, d in decisions.items():
            if d["inherit"] and d["reuse"]:
                print(f"::notice title=same-tree reuse::{job}: its inputs are the base's; the base's verdict stands, "
                      "not run here", file=sys.stderr)
            elif d["known_red"]:
                print(f"::notice title=same-tree reuse::{job} failed on these inputs in {d['known_red']}; runs again",
                      file=sys.stderr)
            elif d["reuse"]:
                print(f"::notice title=same-tree reuse::{job} passed on this tree in {d['receipt']}; not run again",
                      file=sys.stderr)
        summary = os.environ.get("GITHUB_STEP_SUMMARY")
        if summary:
            with open(summary, "a") as handle:
                handle.write("### Same-tree reuse\n\n" + "\n".join(summary_lines(decisions)) + "\n")
        print(f"same_tree={json.dumps(decisions, separators=(',', ':'))}")
        return 0

    if args.command == "receipt":
        match = KEY.match(args.key)
        if not match or match["job"] != args.job:
            print(f"::warning title=same-tree reuse::{args.key} is not a key of {args.job}; no receipt",
                  file=sys.stderr)
            return 1
        server = os.environ.get("GITHUB_SERVER_URL", "https://github.com")
        repo, run_id = os.environ.get("GITHUB_REPOSITORY", ""), os.environ.get("GITHUB_RUN_ID", "")
        run_url = f"{server}/{repo}/actions/runs/{run_id}" if repo and run_id else ""
        out = Path(args.out)
        out.mkdir(parents=True, exist_ok=True)
        (out / "receipt.json").write_text(json.dumps({
            "job": args.job, "key": args.key, "tree": match["tree"], "run_url": run_url,
            "attempt": os.environ.get("GITHUB_RUN_ATTEMPT", ""), "sha": os.environ.get("GITHUB_SHA", ""),
            "conclusion": args.conclusion,
        }, sort_keys=True) + "\n")
        return 0

    config = json.loads(CONFIG.read_text())
    errors = check(Path(args.root), config)
    for error in errors:
        print(error)
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main())
