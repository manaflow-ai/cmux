#!/usr/bin/env python3
"""cmux-next fast gates: six checks, in fail mode, on a pull request merged with its base.

.github/workflows/cmux-next-fast-gates.yml runs this for every pull request into feat-cmux-next
and on dispatch (`pr=N`, against the current tip). It posts `cmux-next/fast-gates` with
`base <BASE sha>` on the PR head; mergers (next-autoland, the hq merge hook) judge whether that
result is fresh for the tip they merge into.

  prepare --event pull_request --head SHA --base SHA      the checkout is GitHub's merge ref
  prepare --event workflow_dispatch --pr N --head SHA --base SHA
                                                  fetch the PR head and the tip, merge them here
      The workflow's resolve job names HEAD and BASE without running this checkout's code;
      prepare fails unless the merge it gates is exactly BASE + HEAD. Writes merge=, web=
      (true when web lint has something to lint) and checks= (true on a dispatch, or for a
      string catalog or protocol spec change, which ci-web's routing does not check) to --output
      (GITHUB_OUTPUT).
  run --base BASE [--web true|false] [--checks true|false]
                                                  every gate on BASE..HEAD (the merge); exit 1
                                                  when any gate fails, after running all of them

The gates, each the same invocation as its push-time job:
  web lint        scripts/web_lint_prepush.py --base BASE --head MERGE --new-only (cmux-next-web.yml's
                  web lint (fast); only findings the PR adds, per error)
  crash ratchet   scripts/ci/crash_ratchet_compare.py on the merge and BASE's exported tree (cmux-next-guards.yml)
  prepush gate    scripts/cmux-next/prepush-gate.py --base BASE --head MERGE (only violations the PR adds)
  crash-class rules  scripts/ci/crash_class_fast_gate.py on the merge and BASE's exported tree
                  (cmux-next-crash-class.yml: concurrency crash classes, super-call selectors and the
                  Chromium Objective-C contract; only findings the PR adds)
  webviews checks scripts/ci/fast_gate_webviews_checks.py --base BASE (ci-web.yml's fail-mode webviews
                  checks; only findings the PR adds), on a dispatch, or for a pull request that changes a string catalog or
                  the acpmux protocol spec: otherwise ci-web runs them for a webviews/ change on this same merge. A merger
                  dispatches when a check path (scripts/ci/check-paths.txt) changed on the base after the
                  pull request's last fast-gates base, so a check that landed since runs before the merge.

The panic ratchet is the workflow's own job (panic-ratchet: it needs Rust and a cmux-tui build, so it is
not a gate here). cmux-tui-spec.yml's clippy job judges a pull request's Rust against the
rust-panic-baseline.json rows at its own merge; a row the base lowers after that leaves the green standing
(2026-10-30: #28182 landed 6 acpmux indexing hits and #28369 1 over rows lowered since their checks ran).
The baseline is a check path, so a merger dispatches these gates, and on a dispatch `prepare` writes
ratchet=true when the base lowered a deny-lint row of a crate the pull request changes (or any row, for a
workspace-wide Rust input) since the merge base: the job then lints those packages at BASE and on the merge
and fails only on counts over the tip's row that BASE does not already reach.
"""
from __future__ import annotations

import argparse
import json
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


# Inputs of the webviews checks outside webviews/, where ci-web's react-apps routing does not run them on a pull
# request: check:catalog-keys reads every string catalog, acpmux-protocol:check the protocol spec.
CHECK_INPUTS_OUTSIDE_WEBVIEWS = re.compile(r"\.xcstrings$|^cmux-tui/crates/acpmux/spec/")


def checks_needed(repo: Path, event: str, base: str, merge: str) -> bool:
    """Whether the webviews checks gate runs: on a dispatch, or a pull request that changes one of their inputs
    outside webviews/ (on a pull request ci-web runs them for a webviews/ change, on this same merge)."""
    if event == "workflow_dispatch":
        return True
    changed = git(repo, "diff", "--name-only", base, merge).stdout.split()
    return any(CHECK_INPUTS_OUTSIDE_WEBVIEWS.search(path) for path in changed)


# The panic ratchet's baseline and the cmux-tui inputs whose change can move every crate's count.
PANIC_BASELINE = "scripts/cmux-next/rust-panic-baseline.json"
PANIC_WORKSPACE_WIDE = re.compile(r"^cmux-tui/(Cargo\.(toml|lock)|\.?clippy\.toml|rust-toolchain(\.toml)?|\.cargo/config\.toml)$"
                                  r"|^scripts/cmux-next/rust_panic_ratchet\.py$")


def panic_rows(repo: Path, ref: str) -> tuple[dict, list[str]] | None:
    """The baseline's crate rows and deny lints at `ref`, or None when it has none."""
    shown = git(repo, "show", f"{ref}:{PANIC_BASELINE}", check=False)
    if shown.returncode != 0:
        return None
    try:
        data = json.loads(shown.stdout)
        return dict(data.get("crates") or {}), list(data.get("deny_lints") or [])
    except (ValueError, AttributeError, TypeError):
        return None


def panic_crate(path: str) -> str | None:
    """The ratchet's crate name for a path (rust_panic_ratchet.crate_of): crates/<name>, bindings-<name>."""
    parts = path.split("/")
    if len(parts) >= 4 and parts[0] == "cmux-tui" and parts[1] == "crates":
        return parts[2]
    if len(parts) >= 4 and parts[0] == "cmux-tui" and parts[1] == "bindings":
        return f"bindings-{parts[2]}"
    return None


def ratchet_needed(repo: Path, event: str, base: str, head: str) -> list[str]:
    """The crates whose panic-ratchet verdict a dispatch must redo: a deny-lint row BASE lowered since the
    merge base, of a crate the pull request changes (every lowered crate for a workspace-wide input). A pull
    request event has none: cmux-tui-spec.yml's clippy job ran the ratchet on this same merge."""
    if event != "workflow_dispatch":
        return []
    since = git(repo, "merge-base", head, base, check=False).stdout.split()
    old, new = (panic_rows(repo, since[0]) if since else None), panic_rows(repo, base)
    if old is None or new is None:
        return []
    rows, deny = new
    lowered = {crate for crate, row in old[0].items()
               if isinstance(row, dict) and any(int((rows.get(crate) or {}).get(lint, 0)) < int(row.get(lint, 0))
                                                for lint in deny)}
    if not lowered:
        return []
    changed = git(repo, "diff", "--name-only", since[0], head).stdout.split()
    if any(PANIC_WORKSPACE_WIDE.match(path) for path in changed):
        return sorted(lowered)
    return sorted(lowered & {crate for path in changed if (crate := panic_crate(path))})


def deep_enough(repo: Path, head: str, base: str) -> bool:
    """BASE is here and meets HEAD at its true merge base, with no shallow cut between them.

    A cut commit shows no parents, so a merge base found here can be an older common ancestor than the true one,
    hidden past the cut on one side (#24250: spurious conflicts in files the PR never touched). And a cut PR commit
    reads as a root that adds every file in the tree: #24526's head, a commit bringing the base in, was cut at the
    merge ref's depth 2, so the Sidebar-Look check saw it add 162 sidebar files. One found base is the true one once
    every cut either side reaches lies behind it. Several can be stale even then (a cut at one hides that it
    descends from another), and git merges them into a virtual base from their own history, so they count only
    once no cut is reachable at all."""
    if not rev(repo, base) or not rev(repo, head):
        return False
    bases = git(repo, "merge-base", "--all", head, base, check=False).stdout.split()
    if not bases:
        return False
    shallow = Path(git(repo, "rev-parse", "--path-format=absolute", "--git-path", "shallow").stdout.strip())
    cuts = set(shallow.read_text().split()) if shallow.exists() else set()
    behind = ["--not", *bases] if len(bases) == 1 else []
    return not cuts.intersection(git(repo, "rev-list", head, base, *behind).stdout.split())


def deepen(repo: Path, remote: str, wants: list[str], head: str, base: str) -> None:
    """Deepen a shallow checkout until `deep_enough`; a full clone is left alone (a depth flag there would make
    every worktree sharing it shallow: tests/test_ci_no_shallow_dev_fetch.py)."""
    if git(repo, "rev-parse", "--is-shallow-repository").stdout.strip() != "true":
        return
    for depth in DEEPEN_STEPS:
        if deep_enough(repo, head, base):
            return
        git(repo, "fetch", "--no-tags", "--quiet", f"--deepen={depth}", remote, *wants)
    if not deep_enough(repo, head, base):
        git(repo, "fetch", "--no-tags", "--quiet", "--unshallow", remote, *wants)


def fetch_for_merge(repo: Path, remote: str, pr: str, base: str) -> None:
    """Fetch the PR head and the branch tip shallowly, then deepen until BASE is here and meets the head at its
    true merge base."""
    refspecs = [f"+refs/pull/{pr}/head:{HEAD_REF}", f"+refs/heads/{BRANCH}:{BASE_REF}"]
    if git(repo, "rev-parse", "--is-shallow-repository").stdout.strip() != "true":
        git(repo, "fetch", "--no-tags", "--quiet", remote, *refspecs)
        return
    git(repo, "fetch", "--no-tags", "--quiet", f"--depth={FETCH_DEPTH}", remote, *refspecs)
    deepen(repo, remote, refspecs, HEAD_REF, base)


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
        ratchet = ratchet_needed(repo, args.event, base, head)
        if ratchet:
            log(f"fast-gates: {BRANCH} lowered the panic-ratchet rows of {', '.join(ratchet)} since #{args.pr}'s "
                "merge base, and it changes them: the panic-ratchet job runs again on this merge")
    else:
        ratchet = []
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
        # The checkout holds the merge and its two parents only (fetch-depth 2): the PR's own commits need their
        # parents, or the per-commit gates read a cut commit as adding the whole tree.
        deepen(repo, args.remote, [head, base], head, base)
    write_outputs(args.output, {"merge": merge, "web": "true" if web_needed(repo, base, merge) else "false",
                                "checks": "true" if checks_needed(repo, args.event, base, merge) else "false",
                                "ratchet": "true" if ratchet else "false"})
    return 0


def export_tree(repo: Path, ref: str, into: Path) -> None:
    paths = [p for p in RATCHET_PATHS if git(repo, "cat-file", "-e", f"{ref}:{p}", check=False).returncode == 0]
    if not paths:
        return
    archive = subprocess.run(["git", "-C", str(repo), "archive", "--format=tar", ref, *paths],
                             check=True, capture_output=True).stdout
    subprocess.run(["tar", "-x", "-C", str(into)], input=archive, check=True)


SKIPPED = {"web lint": "no web path changed",
           "webviews checks": "a pull_request event with no catalog or protocol spec change: ci-web runs them "
                              "for a webviews/ change on this merge"}


def gates(repo: Path, base: str, merge: str, base_tree: Path, web: bool,
          checks: bool = False) -> list[tuple[str, list[str] | None]]:
    """(name, argv) in order; argv None is a skipped gate (SKIPPED says why)."""
    py = sys.executable
    return [
        ("web lint", [py, "scripts/web_lint_prepush.py", "--base", base, "--head", merge, "--timings", "--new-only"]
         if web else None),
        ("crash ratchet", [py, "scripts/ci/crash_ratchet_compare.py", "--script", "scripts/cmux-next/crash_ratchet.py",
                           "--head", str(repo), "--base", str(base_tree)]),
        ("prepush gate", [py, "-I", "scripts/cmux-next/prepush-gate.py", "--base", base, "--head", merge]),
        ("crash-class rules", [py, "scripts/ci/crash_class_fast_gate.py", "--base", str(base_tree)]),
        ("webviews checks", [py, "scripts/ci/fast_gate_webviews_checks.py", "--base", base] if checks else None),
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
        for name, argv in gates(repo, args.base, merge, holder, args.web == "true", args.checks == "true"):
            if argv is None:
                print(f"{name}: skipped ({SKIPPED[name]})", flush=True)
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
    gate.add_argument("--checks", choices=("true", "false"), default="false")
    gate.add_argument("--summary", type=Path)
    gate.add_argument("--repo", type=Path, default=Path.cwd())
    args = parser.parse_args(argv)
    return prepare(args) if args.command == "prepare" else run(args)


if __name__ == "__main__":
    sys.exit(main())
