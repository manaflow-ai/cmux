#!/usr/bin/env python3
"""Merge the newest green main commit into this branch, then run the guards.

scripts/merge-main.sh is the entry point; agents use it instead of a raw
`git merge origin/main`. It:

1. fetches main from the remote that points at manaflow-ai/cmux (whatever it
   is called here: origin, mf, upstream),
2. picks the newest main commit whose CI fast guards passed
   (last_green_base.py) and says which newer commits it skipped and why
   (failure or pending); `--tip` merges main's tip anyway,
3. merges it through catch_up_pr.py, so the generated files (project.pbxproj,
   the config schema Swift, string catalogs) resolve the same way the PR
   catch-up workflow resolves them; any other conflict aborts the merge and
   names the paths,
4. runs the local guards (scripts/ci/guards-local.sh, the `ci` group by
   default, `--all-guards` for every group) and labels each failure: a step
   that also fails on the merged main commit alone is "inherited from main",
   one that passes there is "introduced by this branch". A local pass stamp
   for that main commit settles it without a rerun; otherwise the failed
   steps rerun in a temporary worktree of the main commit.

Guard failures do not fail the command: the merge is done either way, and the
labels say what to fix. `--strict` exits 3 when the branch introduced one.

Exit codes: 0 merged or already up to date, 1 conflicts or no green main
commit, 2 error (with --strict, also a guard failure whose origin could not be
told, or a guard run that ended without step results), 3 (--strict) guard
failure introduced by this branch, 130 interrupted.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
from dataclasses import dataclass, field
from pathlib import Path
from typing import Callable

sys.path.insert(0, str(Path(__file__).resolve().parent))

import catch_up_pr  # noqa: E402
import last_green_base  # noqa: E402

CMUX_REMOTE_RE = re.compile(r"github\.com[:/]manaflow-ai/cmux(?:\.git)?/?$")
BASE_BRANCH = "main"


class MergeMainError(Exception):
    pass


def say(line: str) -> None:
    # Flushed: the guard runner writes to the same stdout between these lines.
    print(line, flush=True)


def git(repo: Path, *args: str, check: bool = True) -> str:
    completed = subprocess.run(["git", "-C", str(repo), *args], capture_output=True, text=True)
    if check and completed.returncode != 0:
        raise MergeMainError(f"git {' '.join(args)}: {completed.stderr.strip()}")
    return completed.stdout.strip()


def cmux_remote(repo: Path) -> str:
    """The remote whose fetch URL is manaflow-ai/cmux; origin wins a tie, then the first by name."""
    matches: set[str] = set()
    for line in git(repo, "remote", "-v").splitlines():
        parts = line.split()
        if len(parts) == 3 and parts[2] == "(fetch)" and CMUX_REMOTE_RE.search(parts[1]):
            matches.add(parts[0])
    if not matches:
        raise MergeMainError("no git remote points at github.com/manaflow-ai/cmux; add one or pass --remote")
    return "origin" if "origin" in matches else sorted(matches)[0]


# --- guards ---------------------------------------------------------------------


@dataclass
class GuardFailure:
    unit: str
    job: str
    group: str | None
    name: str
    output_tail: str
    origin: str = "unknown"  # introduced, inherited, unknown
    why: str = ""


@dataclass
class GuardRun:
    ran: bool = False
    returncode: int = 0
    passed: int = 0
    failures: list[GuardFailure] = field(default_factory=list)
    # False when the runner exited without writing step results (a plan
    # error, a crash, Ctrl-C): nothing can be said about the merge's guards.
    complete: bool = True

    @property
    def introduced(self) -> list[GuardFailure]:
        return [item for item in self.failures if item.origin == "introduced"]


GuardCommand = list[str]


def default_guard_command(repo: Path) -> GuardCommand:
    return [str(repo / "scripts/ci/guards-local.sh")]


def read_results(path: Path) -> dict:
    try:
        return json.loads(path.read_text())
    except (OSError, ValueError):
        return {}


def run_guards(repo: Path, command: GuardCommand, base: str, all_groups: bool,
               output: Callable[[str], None] = say) -> GuardRun:
    """Run the branch's guards on the merged tree; failures come back unlabeled."""
    with tempfile.TemporaryDirectory(prefix="merge-main-") as scratch:
        results_path = Path(scratch) / "guards.json"
        args = [*command, "--json", str(results_path)] + (["--all"] if all_groups else [])
        env = {**os.environ, "CMUX_GUARDS_BASE_SHA": base}
        completed = subprocess.run(args, cwd=repo, env=env, stdin=subprocess.DEVNULL)
        results = read_results(results_path)
    run = GuardRun(ran=True, returncode=completed.returncode, complete=bool(results))
    for step in results.get("steps", []):
        if step.get("status") == "pass":
            run.passed += 1
        elif step.get("status") == "fail":
            run.failures.append(GuardFailure(
                unit=step.get("unit", ""), job=step.get("job", ""), group=step.get("group"),
                name=step.get("name", ""), output_tail=step.get("output_tail", ""),
            ))
    if completed.returncode != 0 and not run.failures:
        # Exit 1 always comes with a failed step; anything else without one
        # means the run did not finish, so its pass count vouches for nothing.
        run.complete = False
    return run


def stamp_covers(stamp_dir: Path, base: str, tree: str, groups: set[str], steps: set[str]) -> bool:
    """A local full pass on this main commit (or its exact tree), on this platform,
    that covered these groups and ran these steps (not skipped them)."""
    for name in (base, f"tree-{tree}"):
        try:
            stamp = json.loads((stamp_dir / name).read_text())
        except (OSError, ValueError):
            continue
        if not isinstance(stamp, dict) or stamp.get("platform") != sys.platform:
            continue
        if groups <= set(stamp.get("groups") or []) and not steps & set(stamp.get("skipped_steps") or []):
            return True
    return False


def stamp_dir() -> Path:
    cache = os.environ.get("XDG_CACHE_HOME") or str(Path.home() / ".cache")
    return Path(cache) / "cmux-guards" / "pass"


def rerun_on_base(repo: Path, failures: list[GuardFailure], base: str, command: GuardCommand) -> dict:
    """The failed steps' results on `base` alone, from a temporary worktree of it."""
    parent = Path(tempfile.mkdtemp(prefix="merge-main-base-"))
    tree_path = parent / "tree"
    try:
        git(repo, "worktree", "add", "--detach", "--quiet", str(tree_path), base)
        results_path = parent / "base.json"
        # --keep-going: a stateful group keeps every step (select_steps), and
        # an unrelated earlier step failing on main must not hide the one asked about.
        args = [*command, "--root", str(tree_path), "--no-stamp", "--keep-going", "--json", str(results_path)]
        for group in sorted({item.group or item.job for item in failures}):
            args += ["--group", group]
        for name in sorted({item.name for item in failures}):
            args += ["--step", name]
        env = {**os.environ, "CMUX_GUARDS_BASE_SHA": base}
        subprocess.run(args, cwd=repo, env=env, stdin=subprocess.DEVNULL,
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        return read_results(results_path)
    finally:
        removed = subprocess.run(["git", "-C", str(repo), "worktree", "remove", "--force", str(tree_path)],
                                 capture_output=True)
        shutil.rmtree(parent, ignore_errors=True)
        if removed.returncode != 0:
            # The directory is gone either way; drop its administrative entry.
            subprocess.run(["git", "-C", str(repo), "worktree", "prune"], capture_output=True)


def base_statuses(base_results: dict) -> tuple[dict[tuple[str, str], str], set[tuple[str, str]]]:
    """(unit, step) -> status on main, and the (unit, step) pairs main's plan held.

    In a stateful group a result after an earlier failed step is "tainted": it
    ran on state the failed step did not set up, so it says nothing."""
    stateful = {unit.get("label") for unit in base_results.get("units", []) if unit.get("stateful")}
    statuses: dict[tuple[str, str], str] = {}
    broken: set[str] = set()
    for step in base_results.get("steps", []):
        unit, status = step.get("unit"), step.get("status")
        statuses[(unit, step.get("name"))] = "tainted" if unit in broken else status
        if status == "fail" and unit in stateful:
            broken.add(unit)
    planned = {(item.get("unit"), item.get("name")) for item in base_results.get("planned", [])}
    return statuses, planned


def classify(repo: Path, failures: list[GuardFailure], base: str, command: GuardCommand,
             stamps: Path | None = None) -> None:
    """Label each failure inherited (fails on `base` alone) or introduced (passes there).

    Never raises for git trouble: the merge is already committed, so a failure
    to compare leaves the items "unknown" with the reason."""
    if not failures:
        return
    stamps = stamp_dir() if stamps is None else stamps
    try:
        tree = git(repo, "rev-parse", f"{base}^{{tree}}")
        groups = {item.group or item.job for item in failures}
        if stamp_covers(stamps, base, tree, groups, {item.name for item in failures}):
            for item in failures:
                item.origin = "introduced"
                item.why = f"main {base[:11]} has a local guard pass stamp"
            return
        base_results = rerun_on_base(repo, failures, base, command)
    except MergeMainError as error:
        for item in failures:
            item.why = f"could not rerun on main {base[:11]}: {error}"
        return
    if not base_results:
        for item in failures:
            item.why = f"the rerun on main {base[:11]} produced no result"
        return
    statuses, planned = base_statuses(base_results)
    for item in failures:
        key = (item.unit, item.name)
        status = statuses.get(key)
        if status == "fail":
            item.origin, item.why = "inherited", f"fails on main {base[:11]} alone too"
        elif status == "pass":
            item.origin, item.why = "introduced", f"passes on main {base[:11]} alone"
        elif status == "tainted":
            item.why = f"an earlier step of its group failed on main {base[:11]}"
        elif status is None and key not in planned:
            item.origin, item.why = "introduced", f"main {base[:11]} has no such step"
        elif status is None:
            item.why = f"not reached on main {base[:11]}"
        else:
            item.why = f"main {base[:11]} {status} this step here"


def guard_report(run: GuardRun, base: str, base_verdict: str) -> list[str]:
    if not run.ran:
        return []
    if not run.complete:
        return [f"guards: did not run to completion (exit {run.returncode}); see the runner's output above."
                " Nothing is labeled; rerun scripts/ci/guards-local.sh"]
    if not run.failures:
        return [f"guards: {run.passed} step(s) passed on the merge"]
    lines = [f"guards: {len(run.failures)} step(s) failed after merging main {base[:11]}"]
    for item in run.failures:
        label = {"introduced": "introduced by this branch", "inherited": f"inherited from main {base[:11]}"}.get(
            item.origin, "origin unknown")
        lines.append(f"  {label}: {item.unit}: {item.name} ({item.why})")
        if item.origin == "inherited" and base_verdict == "success" and (item.group or item.job) in {"ci"}:
            lines.append("    main's CI fast guards passed on that commit, so this machine likely differs"
                         " from the Linux runner; not this branch's problem")
    open_items = [item for item in run.failures if item.origin != "inherited"]
    if open_items:
        groups = " ".join(f"--group {group}" for group in sorted({i.group or i.job for i in open_items}))
        what = ("the failure(s) this branch introduced" if all(i.origin == "introduced" for i in open_items)
                else "the failure(s) not shown to come from main")
        lines.append(f"next: fix {what}, then rerun scripts/ci/guards-local.sh {groups}")
    else:
        lines.append("next: nothing to fix on this branch; the failures come from main and CI will show them"
                     " there too")
    return lines


# --- the command ----------------------------------------------------------------


@dataclass
class Options:
    repo: Path
    remote: str | None = None
    tip: bool = False
    dry_run: bool = False
    guards: bool = True
    all_guards: bool = False
    strict: bool = False
    limit: int = last_green_base.DEFAULT_LIMIT
    fetch: bool = True


def merge_main(options: Options, source: last_green_base.VerdictSource | None = None,
               guard_command: GuardCommand | None = None, output: Callable[[str], None] = say,
               stamps: Path | None = None) -> int:
    repo = options.repo
    if not options.dry_run and git(repo, "status", "--porcelain", "--untracked-files=no"):
        raise MergeMainError("the working tree has uncommitted changes; commit or set them aside first")
    branch = git(repo, "rev-parse", "--abbrev-ref", "HEAD")
    if branch == BASE_BRANCH:
        raise MergeMainError(f"HEAD is {BASE_BRANCH} itself; run this on a feature branch")
    remote = options.remote or cmux_remote(repo)
    ref = f"refs/remotes/{remote}/{BASE_BRANCH}"
    if options.fetch:
        git(repo, "fetch", "--quiet", "--no-tags", remote, f"+refs/heads/{BASE_BRANCH}:{ref}")

    source = source or last_green_base.github_verdicts(branch=BASE_BRANCH)
    subject = lambda sha: git(repo, "log", "-1", "--format=%s", sha)  # noqa: E731
    try:
        selection = last_green_base.select(repo, ref, source, options.limit)
    except last_green_base.SelectionError as error:
        if not options.tip:
            raise MergeMainError(f"{error}\nmain's guard results are unreadable; pass --tip to merge main's"
                                 " tip without them") from error
        output(f"merge-main: {error}; merging main's tip as asked")
        selection = last_green_base.Selection(tip=git(repo, "rev-parse", ref), chosen=None, candidates=1,
                                              skipped=[(git(repo, "rev-parse", ref), "unknown")])
    else:
        for line in last_green_base.describe(selection, subject):
            output(line)
    if selection.up_to_date:
        return 0
    base = selection.tip if options.tip else selection.chosen
    if base is None:
        output("merge-main: nothing merged. Wait for a green main commit, or pass --tip to merge the red tip"
               " (its failures will show on this branch).")
        return 1
    base_verdict = "success" if base == selection.chosen else dict(selection.skipped).get(base, "missing")
    if options.tip and base != selection.chosen:
        output(f"merge-main: merging main's tip {base[:11]} ({base_verdict}) as asked with --tip")
    if options.dry_run:
        output(f"merge-main: would merge {base[:11]} {subject(base)}")
        return 0

    skipped = len(selection.skipped) if base == selection.chosen else 0
    note = (f"Merged by scripts/merge-main.sh: {remote}/{BASE_BRANCH} at {base[:12]}"
            + (f", the newest commit with green CI fast guards ({skipped} newer skipped)." if skipped else "."))
    result = catch_up_pr.catch_up(repo, base, catch_up_pr.DEFAULT_TOOLS_ROOT, note,
                                  title=f"Merge {BASE_BRANCH} ({base[:12]}) into {branch}")
    if result.status == "blocked":
        output("merge-main: merge aborted; these paths conflict and need a person:")
        for item in result.blocking:
            output(f"  {item['path']}: {item['reason']}")
        output(f"next: git merge {base} (the same green commit), resolve those, commit, then rerun"
               " scripts/merge-main.sh to run the guards")
        return 1
    if result.status == "up_to_date":
        output(f"merge-main: the branch already contains {base[:11]}")
        return 0
    output(f"merge-main: merged {base[:11]} into {branch} as {result.head_after[:11]}")
    for item in result.resolved:
        output(f"  resolved {item['path']}: {item['method']}")

    if not options.guards:
        return 0
    command = guard_command or default_guard_command(repo)
    run = run_guards(repo, command, base, options.all_guards, output)
    classify(repo, run.failures, base, command, stamps)
    for line in guard_report(run, base, base_verdict):
        output(line)
    if options.strict:
        if run.introduced:
            return 3
        if not run.complete or any(item.origin != "inherited" for item in run.failures):
            return 2
    return 0


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--repo", default=".", help="checkout of the branch (default: current directory)")
    parser.add_argument("--remote", help="remote for manaflow-ai/cmux (default: detected)")
    parser.add_argument("--tip", action="store_true", help="merge main's tip even if its guards are not green")
    parser.add_argument("--dry-run", action="store_true", help="say which commit would be merged; change nothing")
    parser.add_argument("--no-guards", action="store_true", help="skip the guard run after the merge")
    parser.add_argument("--all-guards", action="store_true", help="run every guard group, not only `ci`")
    parser.add_argument("--strict", action="store_true", help="exit 3 when the branch introduced a guard failure")
    parser.add_argument("--limit", type=int, default=last_green_base.DEFAULT_LIMIT,
                        help="newest main commits to consider")
    args = parser.parse_args(argv)
    try:
        repo = Path(git(Path(args.repo), "rev-parse", "--show-toplevel"))
        options = Options(repo=repo, remote=args.remote, tip=args.tip, dry_run=args.dry_run,
                          guards=not args.no_guards, all_guards=args.all_guards, strict=args.strict,
                          limit=args.limit)
        return merge_main(options)
    except (MergeMainError, catch_up_pr.CatchUpError) as error:
        print(f"merge-main: {error}", file=sys.stderr)
        return 2
    except KeyboardInterrupt:
        # catch_up aborts an unfinished merge itself; a finished one stands.
        print("merge-main: interrupted", file=sys.stderr)
        return 130


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
