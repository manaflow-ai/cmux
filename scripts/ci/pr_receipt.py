#!/usr/bin/env python3
"""Green receipts by input key: a pull request check whose inputs did not change reports the earlier pass.

Leo, 2026-11-21: "help 100x ci speed and the decrease of needed minutes aka lower resources and lower wall time and
lower machine time while maintaining a partial semblance of checks. and we can infrequenrly have fuller checks."

On the 11-23..24 job ledger (1114 heads, 17,612 job-minutes) about 26 to 32% of pull request check-minutes were runs
on inputs an earlier run had already passed: `pr pipeline / web-browser` 825 min and `cmux-next fast gates` 606 min
of them in two days. tooling-tests skips the same way (scripts/ci/tooling_reuse.py, cmux#56528); this is that receipt
for a whole job, keyed on what the job reads instead of diffed step by step.

The key is sha256 over: the check's name and variant, the object id of each file that defines the check (its
workflow, its runner scripts, this file), every tracked file of the merge commit its inputs match (path, mode, object
id), and every path its inputs match where the merge differs from the base (both sides). The last part pins what a
check that judges only what the change adds compares against, so the same key is the same question:

  web-browser  ci/steps.toml's `web-browser` steps' `inputs` (a step with none keys on the whole tree; a step whose
               result is not a function of the tree, ci_steps.reusable, means no key and the job always runs),
               and ci/steps.toml, ci/run, scripts/ci/ci_steps.py and .github/workflows/pr-pipeline.yml.
  fast-gates   scripts/ci/fast-check-inputs.json's `fast-gates` inputs and the top-level files, and the router,
               its map and .github/workflows/cmux-next-fast-gates.yml (inside the `.github/` input).

A job that passes uploads an empty artifact named `pr-receipt-CHECK-KEY` (`record` writes its one file). `lookup`
asks GitHub for that name (one REST read, GET actions/artifacts?name=) and takes the newest unexpired one from a
same-repository run of this pull request's branch or of its base; the job then reports success with that run linked
and does no work. A fork's run never counts (its workflow can upload anything). The workflow decides when to ask:
never on a push, a dispatch, a fork or the full-ci label, so those always run in full.

  - CI_PR_RECEIPTS=off: nothing is reused.
  - CI_PR_RECEIPTS_AUDIT_PERCENT (5 by default) of hits run anyway, the same answer for every attempt of one run.
  - Any git or API error, or a lookup past its deadline, is a miss.

    python3 pr_receipt.py lookup --check CHECK --repository R --branch HEAD_REF --branch BASE_REF --run-id N \\
        [--variant V] [--no-find] [--output GITHUB_OUTPUT] [--summary F]     writes key= and run= (empty: a miss)
    python3 pr_receipt.py record --check CHECK --key K --out FILE
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import subprocess
import sys
import time
import urllib.request
from pathlib import Path
from typing import Callable
from urllib.parse import urlencode

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
KEY_VERSION = 1
ARTIFACT_PREFIX = "pr-receipt-"
REQUEST_TIMEOUT_SECONDS = 15
DEFAULT_AUDIT_PERCENT = 5
SELF = "scripts/ci/pr_receipt.py"
FAST_GATES_WORKFLOW = ".github/workflows/cmux-next-fast-gates.yml"
DEFINITIONS = {
    "web-browser": ("ci/steps.toml", "ci/run", "scripts/ci/ci_steps.py", ".github/workflows/pr-pipeline.yml", SELF),
    "fast-gates": (FAST_GATES_WORKFLOW, "scripts/ci/fast_check_route.py", "scripts/ci/fast-check-inputs.json",
                   "scripts/ci/cmux_next_fast_gates.py", SELF),
}
MACHINE_VARS = ("RUNNER_OS", "RUNNER_ARCH")


def tree(root: Path, rev: str) -> dict[str, tuple[str, str]]:
    """{path: (mode, object id)} for every file of REV's tree (blob-less checkouts have the trees)."""
    out = subprocess.run(["git", "-C", str(root), "ls-tree", "-r", "-z", "--full-tree", rev], check=True,
                         capture_output=True, timeout=120).stdout.decode("utf-8", "surrogateescape")
    files = {}
    for entry in out.split("\0"):
        if entry:
            meta, _, path = entry.partition("\t")
            mode, _kind, oid = meta.split(" ", 2)
            files[path] = (mode, oid)
    return files


def web_browser_matcher(root: Path) -> Callable[[str], bool] | None:
    """Whether a path is an input of a `web-browser` step; None when some step's result is not the tree's alone."""
    sys.path.insert(0, str(root / "scripts" / "ci"))
    import ci_steps  # noqa: PLC0415

    table = ci_steps.load(root / "ci" / "steps.toml")
    steps = [s for s in table.steps.values() if s.job == "web-browser"]
    if not steps or not all(ci_steps.reusable(s) for s in steps):
        return None
    if any(not s.inputs for s in steps):
        return lambda _path: True
    pattern = re.compile("|".join(f"(?:{ci_steps.glob_pattern(g).pattern})" for s in steps for g in s.inputs))
    return lambda path: bool(pattern.match(path))


def fast_gates_matcher(root: Path) -> Callable[[str], bool] | None:
    sys.path.insert(0, str(root / "scripts" / "ci"))
    import fast_check_route  # noqa: PLC0415

    inputs = fast_check_route.load(root)["workflows"][FAST_GATES_WORKFLOW]["fast-gates"]["inputs"]
    return lambda path: "/" not in path or any(fast_check_route.covered(path, entry) for entry in inputs)


MATCHERS = {"web-browser": web_browser_matcher, "fast-gates": fast_gates_matcher}


def key(check: str, root: Path, merge: str = "HEAD", base: str = "HEAD^1", variant: str = "",
        env: dict[str, str] | None = None) -> str | None:
    """The check's input key at MERGE against BASE, or None when it has none (always run)."""
    matches = MATCHERS[check](root)
    if matches is None:
        return None
    after, before = tree(root, merge), tree(root, base)
    env = os.environ if env is None else env
    doc = {
        "v": KEY_VERSION,
        "check": check,
        "variant": variant,
        "machine": {v: env.get(v, "") for v in MACHINE_VARS} if check == "web-browser" else {},
        "definitions": {p: list(after.get(p, ("", ""))) for p in DEFINITIONS[check]},
        "files": sorted([p, *entry] for p, entry in after.items() if matches(p)),
        "changed": sorted([p, *(before.get(p) or ("", "")), *(after.get(p) or ("", ""))]
                          for p in before.keys() | after.keys() if before.get(p) != after.get(p) and matches(p)),
    }
    raw = json.dumps(doc, sort_keys=True, separators=(",", ":"))
    return hashlib.sha256(raw.encode("utf-8", "surrogateescape")).hexdigest()


def artifact_name(check: str, input_key: str) -> str:
    return f"{ARTIFACT_PREFIX}{check}-{input_key}"


def github(repository: str, token: str, deadline_seconds: float = 40) -> Callable[[str], dict]:
    deadline = time.monotonic() + deadline_seconds

    def call(path: str) -> dict:
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise TimeoutError("receipt lookup deadline reached")
        request = urllib.request.Request(f"https://api.github.com/repos/{repository}/{path}")
        request.add_header("Accept", "application/vnd.github+json")
        if token:
            request.add_header("Authorization", f"Bearer {token}")
        sys.path.insert(0, str(Path(__file__).resolve().parent))
        import gh_http  # noqa: PLC0415 - scripts/ci on the path only when a lookup runs

        _, body, _ = gh_http.request(request, min(REQUEST_TIMEOUT_SECONDS, remaining), raise_errors=True)
        return json.loads(body)

    return call


def find(check: str, input_key: str, branches: list[str], run_id: str, call: Callable[[str], dict]) -> dict | None:
    """The newest unexpired receipt at the key from a same-repository run of one of BRANCHES, or None."""
    query = urlencode({"name": artifact_name(check, input_key), "per_page": 30})
    found = []
    for artifact in call(f"actions/artifacts?{query}").get("artifacts") or []:
        run = artifact.get("workflow_run") or {}
        if artifact.get("expired") or artifact.get("name") != artifact_name(check, input_key):
            continue
        if not run.get("id") or str(run.get("id")) == str(run_id):
            continue
        if run.get("head_repository_id") != run.get("repository_id") or run.get("head_branch") not in branches:
            continue
        found.append(artifact)
    return max(found, key=lambda a: str(a.get("created_at") or "")) if found else None


def audited(run_id: str, percent: int) -> bool:
    """True for about `percent` in 100 runs, the same answer for every attempt of one run."""
    return int(hashlib.sha256(f"pr-receipt:{run_id}".encode()).hexdigest()[:8], 16) % 100 < percent


def lookup(args: argparse.Namespace, env: dict[str, str], call: Callable[[str], dict] | None = None,
           out=sys.stdout) -> dict[str, str]:
    """{key, run}: run is the vouching run's URL, empty on a miss, an audit or any error."""
    result = {"key": "", "run": ""}
    try:
        result["key"] = key(args.check, Path(args.root), args.merge, args.base, args.variant, env) or ""
    except Exception as error:  # noqa: BLE001 - a receipt is optional: no key, the job runs and records nothing
        print(f"{args.check}: no receipt key ({error}); the job runs", file=out)
        return result
    if not result["key"]:
        print(f"{args.check}: a step's result is not the tree's alone, so no receipt; the job runs", file=out)
        return result
    print(f"{args.check}: input key {result['key']}", file=out)
    if args.no_find:
        return result
    if env.get("CI_PR_RECEIPTS", "").strip().lower() == "off":
        print("CI_PR_RECEIPTS=off: no earlier pass is reused", file=out)
        return result
    repository = args.repository
    try:
        call = call or github(repository, env.get("GH_TOKEN") or env.get("GITHUB_TOKEN") or "")
        hit = find(args.check, result["key"], [b for b in args.branch if b], args.run_id, call)
    except Exception as error:  # noqa: BLE001 - any API error is a miss
        print(f"{args.check}: receipt lookup failed ({error}); the job runs", file=out)
        return result
    if not hit:
        print(f"{args.check}: no green receipt at this key; the job runs", file=out)
        return result
    run = hit["workflow_run"]
    url = f"https://github.com/{repository}/actions/runs/{run['id']}"
    where = f"{url} ({run.get('head_branch')} at {str(run.get('head_sha', ''))[:10]})"
    try:
        percent = int(env.get("CI_PR_RECEIPTS_AUDIT_PERCENT") or DEFAULT_AUDIT_PERCENT)
    except ValueError:
        percent = DEFAULT_AUDIT_PERCENT
    if audited(args.run_id, percent):
        print(f"{args.check}: audit run ({percent}%): {where} passed these inputs; the job runs anyway", file=out)
        return result
    result["run"] = url
    print(f"::notice title={args.check} receipt::these inputs (key {result['key'][:16]}) passed in {where}; "
          "the job reports that pass and does not run again", file=out)
    return result


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    sub = parser.add_subparsers(dest="command", required=True)
    look = sub.add_parser("lookup")
    look.add_argument("--check", choices=sorted(MATCHERS), required=True)
    look.add_argument("--root", default=str(ROOT))
    look.add_argument("--merge", default="HEAD")
    look.add_argument("--base", default="HEAD^1")
    look.add_argument("--variant", default="")
    look.add_argument("--repository", default=os.environ.get("GITHUB_REPOSITORY", ""))
    look.add_argument("--branch", action="append", default=[], help="a branch whose runs vouch (head and base)")
    look.add_argument("--run-id", default=os.environ.get("GITHUB_RUN_ID", ""))
    look.add_argument("--no-find", action="store_true", help="only the key (full-ci: run in full, still record)")
    look.add_argument("--output", type=Path, help="append key= and run= here (GITHUB_OUTPUT)")
    look.add_argument("--summary", type=Path)
    rec = sub.add_parser("record")
    rec.add_argument("--check", choices=sorted(MATCHERS), required=True)
    rec.add_argument("--key", required=True)
    rec.add_argument("--out", type=Path, required=True)
    args = parser.parse_args(argv)
    if args.command == "record":
        if not re.fullmatch(r"[0-9a-f]{64}", args.key):
            print(f"{args.check}: no input key, nothing recorded")
            return 0
        args.out.parent.mkdir(parents=True, exist_ok=True)
        args.out.write_text(json.dumps({"check": args.check, "key": args.key, "run_id": os.environ.get("GITHUB_RUN_ID"),
                                        "sha": os.environ.get("GITHUB_SHA")}) + "\n", encoding="utf-8")
        print(f"{args.check}: recorded {artifact_name(args.check, args.key)} for later heads of this pull request")
        return 0
    result = lookup(args, dict(os.environ))
    if args.output:
        with args.output.open("a", encoding="utf-8") as stream:
            stream.write(f"key={result['key']}\nrun={result['run']}\n")
    if args.summary and result["run"]:
        with args.summary.open("a", encoding="utf-8") as stream:
            stream.write(f"\n{args.check}: these inputs passed in {result['run']}; reused, not run again.\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
