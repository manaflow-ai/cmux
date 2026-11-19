#!/usr/bin/env python3
"""Local test receipts: a passing same-tree `cmux-ci test` run counts as the CI job it repeats.

Leo: "if you test a change locally and it works or whatever, like we can just count that as a pass, as a skip in CI."

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
                    - its run-name names this pull request's head (`tests OWNER/REPO@HEAD`, which the workflow's
                      "Confirm the tested commit" step proves), and its `checks` job passed;
                    - the job log's FAST_CHECKS_COMMAND (the workflow's own env header, printed before the command
                      runs) is the job's canonical command word for word, in the checkout's root;
                    - the workflow's own FAST_CHECKS_RECEIPT (its last line, printed after the command's process group
                      is gone) has exit 0, an unmoved HEAD, and the head's tree;
                    - the command's CMUX_CI_RECEIPT names this job and this head, and its merge tree is this run's
                      merge tree: with the same base, the tree must equal ours; with an older base (fast gates only),
                      that base must be an ancestor of ours, and the status names it (`base SHA`) so mergers apply
                      their freshness rule to it as to any fast-gates status.
                  Anything else (no pointer, a forged or replayed run, another tree or command, an API failure) is
                  `valid=false` with the reason, and the job runs in full.
                  `audit=true` for CI_RECEIPT_AUDIT_PERCENT of valid receipts (default 10, seeded by the CI run id):
                  the job still runs in full, and a red there names the receipt and its producer.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import shlex
import shutil
import subprocess
import sys
import tempfile
import urllib.error
import urllib.request
from pathlib import Path
from typing import Callable

BRANCH = "feat-cmux-next"
SHA = re.compile(r"^[0-9a-f]{40}$")
WORKFLOW_PATH = ".github/workflows/fast-checks.yml"
RECEIPT_WORKFLOW_BRANCH = "main"
JOB_NAME = "checks"
JOBS = ("fast-gates", "rust-workspaces")
# The command each job's receipt must have run, word for word (shlex-split, so quoting style does not matter).
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
        try:
            with urllib.request.urlopen(request, timeout=30) as response:
                return response.read()
        except urllib.error.HTTPError as error:
            raise Rejected(f"GitHub answered {error.code} for {path}") from error
        except (urllib.error.URLError, TimeoutError) as error:
            raise Rejected(f"GitHub did not answer for {path}: {error}") from error
    return fetch


def pointers(body: str, job: str, repo: str) -> list[str]:
    """Run ids the pull request body names for JOB, in order."""
    found = []
    for match in POINTER.finditer(body or ""):
        if match["job"] == job and (match["repo"] in (None, repo)):
            found.append(match["run"])
    return found


def same_command(text: str, job: str) -> bool:
    try:
        return shlex.split(text) == shlex.split(CANONICAL[job])
    except ValueError:
        return False


def parse_log(text: str) -> dict:
    """The fields of a fast-checks `checks` job log a receipt rests on.

    command/directory: the first env header of the "Run fast checks" step (GitHub prints it inside the step's
    ##[group] before the command starts, so the command's own output cannot come first). fast_checks: the last
    FAST_CHECKS_RECEIPT line (the workflow prints it after the command's process group is stopped). receipt: the
    last CMUX_CI_RECEIPT line before it."""
    lines = [TIMESTAMP.sub("", line, count=1) for line in text.splitlines()]
    command = directory = None
    in_header = False
    for line in lines:
        if line.startswith("##[group]Run "):
            in_header = True
            continue
        if line.startswith("##[endgroup]"):
            if command is not None:
                break
            in_header = False
            continue
        if in_header:
            if line.startswith("  FAST_CHECKS_COMMAND: "):
                command = line[len("  FAST_CHECKS_COMMAND: "):]
            elif line.startswith("  FAST_CHECKS_DIRECTORY: "):
                directory = line[len("  FAST_CHECKS_DIRECTORY: "):]
    fast_checks = receipt = None
    fast_index = -1
    for index, line in enumerate(lines):
        if line.startswith("FAST_CHECKS_RECEIPT="):
            fast_checks, fast_index = line[len("FAST_CHECKS_RECEIPT="):], index
    for line in lines[:fast_index if fast_index >= 0 else len(lines)]:
        if line.startswith("CMUX_CI_RECEIPT="):
            receipt = line[len("CMUX_CI_RECEIPT="):]

    def load(value: str | None) -> dict | None:
        try:
            parsed = json.loads(value) if value else None
        except json.JSONDecodeError:
            return None
        return parsed if isinstance(parsed, dict) else None

    return {"command": command, "directory": directory, "fast_checks": load(fast_checks), "receipt": load(receipt)}


def check_run(fetch: Fetch, *, repo: str, run_id: str, job: str, head: str, head_tree: str, base: str,
              merge_tree: str) -> dict:
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
    if not str(run.get("display_title", "")).endswith(f" tests {repo}@{head}"):
        raise Rejected(f"{where} tests {run.get('display_title')!r}, not this head {head}")
    jobs = json.loads(fetch(f"repos/{repo}/actions/runs/{run_id}/jobs?per_page=20")).get("jobs") or []
    checks = [each for each in jobs if each.get("name") == JOB_NAME]
    if len(checks) != 1 or checks[0].get("conclusion") != "success":
        raise Rejected(f"{where} has no passing {JOB_NAME!r} job")
    found = parse_log(fetch(f"repos/{repo}/actions/jobs/{checks[0]['id']}/logs").decode("utf-8", "replace"))
    if found["command"] is None or not same_command(found["command"], job):
        raise Rejected(f"{where} ran {found['command']!r}, not {job}'s canonical {CANONICAL[job]!r}")
    if found["directory"] not in (".", None):
        raise Rejected(f"{where} ran in {found['directory']!r}, not the checkout's root")
    fast = found["fast_checks"] or {}
    if fast.get("exit_code") != 0 or fast.get("source_tree") != head_tree or fast.get("head_after") != fast.get("source_sha"):
        raise Rejected(f"{where}: the workflow's FAST_CHECKS_RECEIPT is not a pass on this head's tree {head_tree} "
                       f"({json.dumps(fast, sort_keys=True)[:300]})")
    receipt = found["receipt"] or {}
    if receipt.get("job") != job:
        raise Rejected(f"{where} is a receipt for {receipt.get('job')!r}, not {job}")
    if receipt.get("head") != head:
        raise Rejected(f"{where} merged head {receipt.get('head')!r}, not {head}")
    receipt_base, receipt_tree = receipt.get("base"), receipt.get("tree")
    if not (isinstance(receipt_base, str) and SHA.match(receipt_base) and isinstance(receipt_tree, str)
            and SHA.match(receipt_tree)):
        raise Rejected(f"{where} names no base and merge tree")
    if receipt_base == base:
        if receipt_tree != merge_tree:
            raise Rejected(f"{where} tested merge tree {receipt_tree}, not this run's {merge_tree} (same base {base})")
    elif job != "fast-gates":
        raise Rejected(f"{where} merged onto base {receipt_base}, not this run's {base}; a {job} receipt needs the "
                       "same base")
    else:
        compared = json.loads(fetch(f"repos/{repo}/compare/{receipt_base}...{base}?per_page=1"))
        if compared.get("status") not in ("ahead", "identical"):
            raise Rejected(f"{where} merged onto base {receipt_base}, which is {compared.get('status')} of this "
                           f"run's base {base}, not an ancestor")
    return {"base": receipt_base, "run_url": url, "producer": producer}


def audited(seed: str, head: str, percent: int) -> bool:
    digest = int(hashlib.sha256(f"{seed}:{head}".encode()).hexdigest()[:8], 16)
    return digest % 100 < max(0, min(100, percent))


def verify(args: argparse.Namespace, fetch: Fetch | None = None) -> dict:
    out = {"valid": "false", "audit": "false", "base": "", "run_url": "", "producer": "", "reason": ""}
    body = Path(args.body_file).read_text(encoding="utf-8") if args.body_file else os.environ.get("PR_BODY", "")
    runs = pointers(body, args.job, args.repo)
    if not runs:
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
    reasons = []
    # The last line names the newest receipt; read back from it.
    for run_id in reversed(runs[-3:]):
        try:
            found = check_run(fetch, repo=args.repo, run_id=run_id, job=args.job, head=args.head,
                              head_tree=args.head_tree, base=args.base, merge_tree=args.merge_tree)
        except Rejected as error:
            reasons.append(str(error))
            continue
        except (ValueError, KeyError, TypeError, AttributeError) as error:
            reasons.append(f"receipt run {run_id}: unreadable answer ({error})")
            continue
        out.update(found, valid="true", reason=f"receipt run {found['run_url']} (by {found['producer']}) covers "
                                                f"{args.job} on head {args.head}, base {found['base']}")
        out["audit"] = "true" if audited(args.seed, args.head, args.audit_percent) else "false"
        return out
    out["reason"] = "; ".join(reasons)
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
    gates.deepen(repo, remote, [f"+refs/heads/{BRANCH}:{ref}"], head, base)
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
        code = subprocess.run([*script, "run", entry["root"]], cwd=work).returncode
        if code != 0:
            return code
    return 0


def produce(args: argparse.Namespace) -> int:
    repo = Path(git(Path.cwd(), "rev-parse", "--show-toplevel").stdout.strip())
    head = tested_head(repo)
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
    print(f"ci-receipt: passed. Add this line to the pull request body (the run's URL is in cmux-ci's output):\n"
          f"  CI-Receipt: {args.job} https://github.com/manaflow-ai/cmux/actions/runs/{os.environ.get('GITHUB_RUN_ID', 'RUN_ID')}",
          flush=True)
    return 0


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    sub = parser.add_subparsers(dest="mode", required=True)
    make = sub.add_parser("produce")
    make.add_argument("job", choices=JOBS)
    make.add_argument("--remote", default="origin")
    check = sub.add_parser("verify")
    check.add_argument("job", choices=JOBS)
    check.add_argument("--repo", required=True)
    check.add_argument("--head", required=True)
    check.add_argument("--base", required=True)
    check.add_argument("--head-tree", required=True)
    check.add_argument("--merge-tree", required=True)
    check.add_argument("--body-file", help="the pull request body (default: $PR_BODY)")
    check.add_argument("--seed", default=os.environ.get("GITHUB_RUN_ID", ""))
    check.add_argument("--audit-percent", type=lambda v: int(v) if v.strip() else DEFAULT_AUDIT_PERCENT,
                       default=DEFAULT_AUDIT_PERCENT)
    check.add_argument("--output", type=Path)
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
