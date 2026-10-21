#!/usr/bin/env python3
"""cmux-next fast gates: five checks, in fail mode, on a pull request merged with its base.

.github/workflows/cmux-next-fast-gates.yml runs this for every pull request into feat-cmux-next
and on dispatch (`pr=N`, against the current tip). It posts `cmux-next/fast-gates` with
`base <BASE sha>` on the PR head; mergers (next-autoland, the hq merge hook) judge whether that
result is fresh for the tip they merge into.

  prepare --event pull_request --head SHA --base SHA      the checkout is GitHub's merge ref
  prepare --event workflow_dispatch --pr N --head SHA --base SHA
                                                  fetch the PR head and the tip, merge them here
      The workflow's resolve job names HEAD and BASE without running this checkout's code;
      prepare fails unless the merge it gates is exactly BASE + HEAD. Writes merge= and web=
      (true when web lint has something to lint) to --output (GITHUB_OUTPUT).
  run --base BASE [--web true|false]              every gate on BASE..HEAD (the merge); exit 1
                                                  when any gate fails, after running all of them

The gates, each the same invocation as its push-time job:
  web lint        scripts/web_lint_prepush.py --base BASE --head MERGE (cmux-next-web.yml, web lint (fast))
  crash ratchet   scripts/ci/crash_ratchet_compare.py on the merge and BASE's exported tree (cmux-next-guards.yml)
  defaults stamp  scripts/ci/defaults_guard.py check-stamp --base BASE (cmux-next-guards.yml, defaults-snapshot)
  prepush gate    scripts/cmux-next/prepush-gate.py --base BASE --head MERGE (only violations the PR adds)
  crash-class rules  scripts/ci/crash_class_fast_gate.py on the merge and BASE's exported tree
                  (cmux-next-crash-class.yml: concurrency crash classes, super-call selectors and the
                  Chromium Objective-C contract; only findings the PR adds)
"""
from __future__ import annotations

import argparse
import re
import shutil
import subprocess
import sys
import tempfile
import time
from pathlib import Path

BRANCH = "feat-cmux-next"
PR_NUMBER = re.compile(r"^[0-9]{1,7}$")
SHA = re.compile(r"^[0-9a-f]{40}$")
# Ref names this script writes; nothing else in the checkout uses them.
HEAD_REF = "refs/fast-gates/head"
BASE_REF = "refs/fast-gates/base"
IDENTITY = ("-c", "user.name=cmux fast gates", "-c", "user.email=fast-gates@users.noreply.github.com")
# The crash ratchet reads these trees on each side (cmux-next-guards.yml, crash-ratchet).
RATCHET_PATHS = ("Packages", "cmux-tui/crates", "scripts/cmux-next")
FETCH_DEPTH = 50
DEEPEN_STEPS = (200, 1000, 5000)


def log(message: str) -> None:
    print(message, file=sys.stderr, flush=True)


def git(repo: Path, *args: str, check: bool = True) -> subprocess.CompletedProcess:
    result = subprocess.run(["git", "-C", str(repo), *args], capture_output=True, text=True)
    if check and result.returncode != 0:
        raise SystemExit(f"fast-gates: git {' '.join(args)} failed: {result.stderr.strip()}")
    return result


def rev(repo: Path, ref: str) -> str | None:
    result = git(repo, "rev-parse", "--verify", "--quiet", f"{ref}^{{commit}}", check=False)
    return result.stdout.strip() or None


def write_outputs(path: Path | None, values: dict[str, str]) -> None:
    lines = "".join(f"{key}={value}\n" for key, value in values.items())
    print(lines, end="")
    if path:
        with path.open("a", encoding="utf-8") as stream:
            stream.write(lines)


def web_needed(repo: Path, base: str, merge: str) -> bool:
    """Whether web_lint_prepush.py would lint anything on base..merge (its own plan)."""
    sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
    import web_lint_prepush  # noqa: PLC0415  (scripts/web_lint_prepush.py)

    files = web_lint_prepush.changed_files(repo, base, merge)
    exists, _ = web_lint_prepush.snapshot(repo, merge)
    plan = web_lint_prepush.make_plan(repo, files, guard_executed=False, exists=exists)
    return bool(plan.script_packages or plan.eslint_files)


def fetch_for_merge(repo: Path, remote: str, pr: str, base: str) -> None:
    """Fetch the PR head and the branch tip shallowly, then deepen until BASE is here and meets the head."""
    refspecs = [f"+refs/pull/{pr}/head:{HEAD_REF}", f"+refs/heads/{BRANCH}:{BASE_REF}"]

    def met() -> bool:
        return bool(rev(repo, base)) and git(repo, "merge-base", HEAD_REF, base, check=False).returncode == 0

    # A depth flag only in a checkout that is already shallow (the CI checkout): in a full clone it would make
    # every worktree sharing it shallow (tests/test_ci_no_shallow_dev_fetch.py), so there it fetches whole.
    if git(repo, "rev-parse", "--is-shallow-repository").stdout.strip() != "true":
        git(repo, "fetch", "--no-tags", "--quiet", remote, *refspecs)
        return
    git(repo, "fetch", "--no-tags", "--quiet", f"--depth={FETCH_DEPTH}", remote, *refspecs)
    for depth in DEEPEN_STEPS:
        if met():
            return
        git(repo, "fetch", "--no-tags", "--quiet", f"--deepen={depth}", remote, *refspecs)
    if not met():
        git(repo, "fetch", "--no-tags", "--quiet", "--unshallow", remote, *refspecs)


def prepare(args: argparse.Namespace) -> int:
    repo = args.repo
    base, head = args.base, args.head
    for flag, value in (("--head", head), ("--base", base)):
        if not SHA.match(value):
            log(f"fast-gates: {flag} must be a full commit sha, not {value!r}")
            return 2
    if args.event == "workflow_dispatch":
        if not PR_NUMBER.match(args.pr or ""):
            log(f"fast-gates: --pr must be a pull request number (digits only), not {args.pr!r}")
            return 2
        fetch_for_merge(repo, args.remote, args.pr, base)
        fetched = rev(repo, HEAD_REF)
        if fetched != head:
            log(f"fast-gates: pull request #{args.pr} is at {fetched}, not the resolved head {head}; "
                "it moved since the run started. Dispatch again.")
            return 1
        if not rev(repo, base) or git(repo, "merge-base", "--is-ancestor", base, BASE_REF, check=False).returncode:
            log(f"fast-gates: the resolved base {base} is not on {BRANCH}")
            return 1
        git(repo, "checkout", "--quiet", "--detach", base)
        # --no-ff: a head already on top of the tip still gives a merge whose first parent is BASE.
        merged = git(repo, *IDENTITY, "merge", "--no-ff", "--no-edit", "--quiet", head, check=False)
        if merged.returncode != 0:
            conflicts = git(repo, "diff", "--name-only", "--diff-filter=U", check=False).stdout.split()
            git(repo, "merge", "--abort", check=False)
            log(f"fast-gates: pull request #{args.pr} ({head}) does not merge cleanly into {BRANCH} ({base}): "
                f"merge conflict in {', '.join(conflicts) or 'the tree'}. Merge {BRANCH} into the branch, "
                "push, and the gates run again.")
            return 1
        merge = rev(repo, "HEAD")
    else:
        merge = rev(repo, "HEAD")
        first, second = rev(repo, "HEAD^1"), rev(repo, "HEAD^2")
        if not merge or not first or not second:
            log("fast-gates: the checkout is not a merge commit; expected the pull request's merge ref")
            return 1
        if second != head:
            log(f"fast-gates: the merge ref's second parent {second} is not the pull request head {head}; "
                "GitHub had not refreshed the merge ref. Push again or dispatch the workflow.")
            return 1
        if first != base:
            log(f"fast-gates: the merge ref's first parent {first} is not the resolved base {base}")
            return 1
    write_outputs(args.output, {"merge": merge, "web": "true" if web_needed(repo, base, merge) else "false"})
    return 0


def export_tree(repo: Path, ref: str, into: Path) -> None:
    paths = [p for p in RATCHET_PATHS if git(repo, "cat-file", "-e", f"{ref}:{p}", check=False).returncode == 0]
    if not paths:
        return
    archive = subprocess.run(["git", "-C", str(repo), "archive", "--format=tar", ref, *paths],
                             check=True, capture_output=True).stdout
    subprocess.run(["tar", "-x", "-C", str(into)], input=archive, check=True)


def gates(repo: Path, base: str, merge: str, base_tree: Path, web: bool) -> list[tuple[str, list[str] | None]]:
    """(name, argv) in order; argv None is a skipped gate."""
    py = sys.executable
    return [
        ("web lint", [py, "scripts/web_lint_prepush.py", "--base", base, "--head", merge, "--timings"] if web else None),
        ("crash ratchet", [py, "scripts/ci/crash_ratchet_compare.py", "--script", "scripts/cmux-next/crash_ratchet.py",
                           "--head", str(repo), "--base", str(base_tree)]),
        ("defaults stamp", [py, "scripts/ci/defaults_guard.py", "check-stamp", "--base", base]),
        ("prepush gate", [py, "-I", "scripts/cmux-next/prepush-gate.py", "--base", base, "--head", merge]),
        ("crash-class rules", [py, "scripts/ci/crash_class_fast_gate.py", "--base", str(base_tree)]),
    ]


def run(args: argparse.Namespace) -> int:
    repo = args.repo.resolve()
    if not SHA.match(args.base) or not rev(repo, args.base):
        log(f"fast-gates: --base {args.base!r} is not a commit in this checkout")
        return 2
    merge = rev(repo, args.merge)
    if not merge:
        log(f"fast-gates: --merge {args.merge!r} is not a commit in this checkout")
        return 2
    holder = Path(tempfile.mkdtemp(prefix="fast-gates-base-"))
    rows: list[tuple[str, str, float]] = []
    try:
        export_tree(repo, args.base, holder)
        for name, argv in gates(repo, args.base, merge, holder, args.web == "true"):
            if argv is None:
                print(f"{name}: skipped (no web path changed)", flush=True)
                rows.append((name, "skipped", 0.0))
                continue
            print(f"::group::{name}", flush=True)
            started = time.monotonic()
            code = subprocess.run(argv, cwd=repo).returncode
            seconds = time.monotonic() - started
            print("::endgroup::", flush=True)
            outcome = "passed" if code == 0 else f"failed (exit {code})"
            print(f"{name}: {outcome} in {seconds:.1f}s", flush=True)
            if code != 0:
                print(f"::error title=fast gates: {name}::{name} failed on the merge with base {args.base}")
            rows.append((name, outcome, seconds))
    finally:
        shutil.rmtree(holder, ignore_errors=True)
    failed = [name for name, outcome, _ in rows if outcome.startswith("failed")]
    lines = ["### cmux-next fast gates", "", f"Base `{args.base}`, merge `{merge}`.", "",
             "| gate | result | time |", "| --- | --- | --- |"]
    lines += [f"| {name} | {outcome} | {seconds:.1f}s |" for name, outcome, seconds in rows]
    if args.summary:
        with args.summary.open("a", encoding="utf-8") as stream:
            stream.write("\n".join(lines) + "\n")
    if failed:
        print(f"fast gates: {', '.join(failed)} failed", flush=True)
        return 1
    print("fast gates: all passed", flush=True)
    return 0


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="command", required=True)
    prep = sub.add_parser("prepare", help="find or make the merge of BASE and HEAD; write merge, web")
    prep.add_argument("--event", required=True, choices=("pull_request", "workflow_dispatch"))
    prep.add_argument("--pr", help="pull request number (workflow_dispatch)")
    prep.add_argument("--head", required=True, help="the pull request head sha, resolved before this runs")
    prep.add_argument("--base", required=True, help="the base sha the head merges into, resolved before this runs")
    prep.add_argument("--remote", default="origin")
    prep.add_argument("--output", type=Path, help="append key=value lines here (GITHUB_OUTPUT)")
    prep.add_argument("--repo", type=Path, default=Path.cwd())
    gate = sub.add_parser("run", help="run every gate on BASE..merge")
    gate.add_argument("--base", required=True)
    gate.add_argument("--merge", default="HEAD")
    gate.add_argument("--web", choices=("true", "false"), default="true")
    gate.add_argument("--summary", type=Path)
    gate.add_argument("--repo", type=Path, default=Path.cwd())
    args = parser.parse_args(argv)
    return prepare(args) if args.command == "prepare" else run(args)


if __name__ == "__main__":
    sys.exit(main())
