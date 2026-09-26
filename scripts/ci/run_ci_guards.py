#!/usr/bin/env python3
"""Run the CI guard suite from .github/workflows/ci-guards.yml, fast.

ci-guards.yml stays the one list of guard steps. This reads it and runs every
`run:` step of its guard jobs outside GitHub Actions, one worker per job/matrix
group, steps in file order within a group. The same runner backs:

  scripts/ci/guards-local.sh           a dev Mac, seconds, no build
  .github/workflows/ci-fast-guards.yml the "CI fast guards" check

A `uses:` step is not run. Checkout is the working tree itself, and the two
Python dependency steps are replaced by one shared virtualenv (PYTHON_PACKAGES
below). setup-bun and setup-python expect `bun` and `python3` on PATH.

A full run on a clean tree writes a pass stamp for HEAD, which the agent merge
guard (cmuxterm-hq tools/agent-guards) accepts in place of the CI check:
  ${XDG_CACHE_HOME:-~/.cache}/cmux-guards/pass/<sha>

`--step NAME` runs only the named steps (a stateful group also runs the steps
before them), in seconds. `--root DIR` runs another checkout's ci-guards.yml
and tests with this runner, and `--results FILE` writes each step's outcome as
JSON; guard_attribution.py uses the three to find the commit that first fails
a step.
"""

from __future__ import annotations

import argparse
import concurrent.futures
import dataclasses
import json
import os
import re
import signal
import subprocess
import sys
import tempfile
import threading
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
WORKFLOW = ROOT / ".github/workflows/ci-guards.yml"
GUARD_JOBS = (
    "workflow-guard-tests",
    "workflow-guard-history",
    "workflow-guard-cli-scripts",
    "workflow-guard-source-lints",
)
# Steps that install the guard Python dependencies into a per-job venv. The
# runner provides one shared venv with PYTHON_PACKAGES instead. If a step is
# renamed, `--list` fails, so this cannot silently stop matching.
DEPENDENCY_STEPS = {
    "Prepare workflow guard Python dependencies",
    "Install workflow guard Python dependencies",
}
PYTHON_PACKAGES = ("PyYAML==6.0.3", "bashlex==0.18")
# Steps whose `if:` tests the event, which does not apply off Actions. Any
# other condition beyond `matrix.group == '...'` fails the plan rather than
# silently dropping a step.
EVENT_CONDITION_STEPS = {
    # The history job binds the synthetic merge base; run_steps binds it
    # directly (PACKAGE_RESOLVED_POLICY_BASE_REF).
    "Bind package policy to synthetic merge base",
}
# The groups the "CI fast guards" check and a default local run cover: the
# workflow, scripts/ci and repository-variable contracts. `--all` runs every
# guard group, as ci.yml's routed `guards` job does for a CI change.
FAST_GROUPS = ("ci",)
# Steps that assert Linux-only behavior (GNU tools, /proc, a Linux workload
# profile). They run in CI; a macOS run skips them and says so.
LINUX_ONLY_STEPS = {
    "Validate CMUX workload profile contract",
    "Validate the scheduled main full-suite run",
}
# Linux-only wrappers whose payload is portable: off Linux, run the payload.
# The workload profile runner refuses macOS, but ci-guard.sh's commands (the
# self-hosted runner policy among them) run anywhere.
PORTABLE_SUBSTITUTES = {
    "Run canonical CMUX CI guard profile": "scripts/ci/run_ci_guard_payload.sh",
}
GROUP_CONDITION = re.compile(r"matrix\.group\s*==\s*'([a-z0-9-]+)'")
EXPRESSION = re.compile(r"\$\{\{\s*(.*?)\s*\}\}")
SHELL = ["bash", "--noprofile", "--norc", "-eo", "pipefail"]
# Steps run in their own sessions, so Ctrl-C reaches only this process; it
# stops queued steps and kills the running ones' process groups.
STOPPING = threading.Event()
RUNNING: set[int] = set()
RUNNING_LOCK = threading.Lock()


def stop_running() -> None:
    STOPPING.set()
    with RUNNING_LOCK:
        pids = list(RUNNING)
    for pid in pids:
        try:
            os.killpg(pid, signal.SIGKILL)
        except (ProcessLookupError, PermissionError):
            pass


def cache_root() -> Path:
    base = os.environ.get("XDG_CACHE_HOME") or str(Path.home() / ".cache")
    return Path(base) / "cmux-guards"


@dataclasses.dataclass
class Step:
    name: str
    run: str
    env: dict[str, str]
    working_directory: str | None


@dataclasses.dataclass
class Unit:
    job: str
    group: str | None
    steps: list[Step]

    @property
    def label(self) -> str:
        return f"{self.job} / {self.group}" if self.group else self.job


@dataclasses.dataclass
class StepResult:
    unit: Unit
    step: Step
    ok: bool | None  # None: skipped on this platform
    seconds: float
    output: str


def load_yaml(path: Path):
    try:
        import yaml  # type: ignore
    except ImportError:
        sys.exit("run_ci_guards.py needs PyYAML; run it through scripts/ci/guards-local.sh")
    with path.open() as handle:
        return yaml.safe_load(handle)


def step_groups(condition: str) -> tuple[set[str], bool]:
    """Groups named by a step `if:`, and whether anything else is in it."""
    groups = set(GROUP_CONDITION.findall(condition))
    rest = GROUP_CONDITION.sub("", condition)
    rest = re.sub(r"[\s${}()|]", "", rest)
    return groups, bool(rest)


class PlanError(Exception):
    pass


def resolve(value: str, context: dict[str, str]) -> str:
    def replace(match: re.Match[str]) -> str:
        expression = match.group(1)
        if expression in context:
            return context[expression]
        # `a || b` fallbacks over event fields: the first known non-empty one.
        # A term this runner does not know is an error, not an empty string:
        # an empty value could quietly turn a check off here but not in CI.
        parts = [p.strip() for p in expression.split("||")]
        unknown = [p for p in parts if p not in context and not re.fullmatch(r"'[^']*'", p)]
        if unknown:
            raise PlanError(f"ci-guards.yml uses ${{{{ {expression} }}}}, which run_ci_guards.py cannot resolve")
        for part in parts:
            value = context[part] if part in context else part.strip("'")
            if value:
                return value
        return ""

    return EXPRESSION.sub(replace, str(value))


def plan(workflow: dict, base_sha: str, head_sha: str) -> list[Unit]:
    jobs = workflow["jobs"]
    units: list[Unit] = []
    for job_name in GUARD_JOBS:
        job = jobs.get(job_name)
        if job is None:  # an older checkout (--root) that predates this guard job
            continue
        matrix = (job.get("strategy") or {}).get("matrix") or {}
        groups = matrix.get("group")
        if isinstance(groups, str):
            # workflow-guard-tests reads its groups from a routed input. Run
            # every group any step names.
            groups = sorted(
                {g for s in job["steps"] for g in step_groups(str(s.get("if", "")))[0]}
            )
        for group in groups or [None]:
            context = {
                "matrix.group": group or "",
                "github.sha": head_sha,
                "github.event.pull_request.base.sha": base_sha,
                "github.event.merge_group.base_sha": base_sha,
            }
            steps: list[Step] = []
            for raw in job["steps"]:
                name = str(raw.get("name") or raw.get("uses") or raw.get("run", "")[:40])
                condition = str(raw.get("if", ""))
                named, other = step_groups(condition)
                if other:
                    if name in EVENT_CONDITION_STEPS:
                        continue
                    raise PlanError(f"step {name!r} has a condition run_ci_guards.py cannot evaluate: {condition}")
                if named and group not in named:
                    continue
                if "uses" in raw or name in DEPENDENCY_STEPS:
                    continue
                env = {k: resolve(v, context) for k, v in (raw.get("env") or {}).items()}
                steps.append(
                    Step(
                        name=name,
                        run=resolve(raw["run"], context),
                        env=env,
                        working_directory=raw.get("working-directory"),
                    )
                )
            if steps:
                units.append(Unit(job=job_name, group=group, steps=steps))
    return units


def read_env_file(path: Path) -> dict[str, str]:
    values: dict[str, str] = {}
    if not path.exists():
        return values
    lines = path.read_text().splitlines()
    index = 0
    while index < len(lines):
        line = lines[index]
        index += 1
        if "<<" in line and "=" not in line.split("<<", 1)[0]:
            key, delimiter = line.split("<<", 1)
            body = []
            while index < len(lines) and lines[index] != delimiter:
                body.append(lines[index])
                index += 1
            index += 1
            values[key] = "\n".join(body)
        elif "=" in line:
            key, value = line.split("=", 1)
            values[key] = value
    return values


def is_stateful(unit: Unit) -> bool:
    """Steps that hand state to later steps must run in order."""
    return any(
        step.working_directory
        or "git submodule" in step.run
        or "GITHUB_ENV" in step.run
        or "GITHUB_PATH" in step.run
        for step in unit.steps
    )


def skipped_here(step: Step) -> bool:
    return sys.platform != "linux" and step.name in LINUX_ONLY_STEPS


def run_steps(
    unit: Unit,
    steps: list[Step],
    base_env: dict[str, str],
    base_sha: str,
    keep_going: bool,
) -> list[StepResult]:
    """Run steps in order in one job-like sandbox (RUNNER_TEMP, GITHUB_ENV...)."""
    results: list[StepResult] = []
    # Not "cmux-": tests rewrite the workflows' fixed /tmp/cmux-* paths, and on
    # Linux this directory is under /tmp, so a nested temp path would match.
    with tempfile.TemporaryDirectory(prefix="guard-steps-") as temp:
        temp_path = Path(temp)
        env_file = temp_path / "github_env"
        path_file = temp_path / "github_path"
        runner_temp = temp_path / "runner_temp"
        runner_temp.mkdir()
        env = dict(base_env)
        env.update(
            {
                "RUNNER_TEMP": str(runner_temp),
                "GITHUB_ENV": str(env_file),
                "GITHUB_PATH": str(path_file),
                "GITHUB_OUTPUT": str(temp_path / "github_output"),
                "GITHUB_STEP_SUMMARY": str(temp_path / "github_step_summary"),
                "GITHUB_WORKSPACE": str(ROOT),
            }
        )
        if unit.job == "workflow-guard-history":
            env["PACKAGE_RESOLVED_POLICY_BASE_REF"] = base_sha
        for step in steps:
            if skipped_here(step):
                results.append(StepResult(unit, step, None, 0.0, ""))
                continue
            started = time.monotonic()
            step_env = dict(env)
            step_env.update(read_env_file(env_file))
            extra_path = [p for p in path_file.read_text().splitlines() if p] if path_file.exists() else []
            if extra_path:
                step_env["PATH"] = os.pathsep.join(list(reversed(extra_path)) + [step_env["PATH"]])
            step_env.update(step.env)
            cwd = ROOT / step.working_directory if step.working_directory else ROOT
            if sys.platform != "linux" and step.name in PORTABLE_SUBSTITUTES:
                if not (ROOT / PORTABLE_SUBSTITUTES[step.name]).exists():
                    # An older checkout (--root) that predates the substitute.
                    results.append(StepResult(unit, step, None, 0.0, ""))
                    continue
                step = dataclasses.replace(step, run=PORTABLE_SUBSTITUTES[step.name])
            returncode, output = run_step(step, cwd, step_env, temp_path / "step.log")
            results.append(StepResult(unit, step, returncode == 0, time.monotonic() - started, output))
            if returncode != 0 and not keep_going:
                break
    return results


def run_step(step: Step, cwd: Path, env: dict[str, str], log_path: Path) -> tuple[int, str]:
    """Run one step in its own session and reap whatever it leaves behind.

    Output goes to a file, not a pipe: a test that leaks a background child
    (several fake a hung process with `signal.pause()`) would otherwise hold
    the pipe open and the runner would wait on it forever. Actions ends a job
    by killing its process tree; this does the same per step.
    """
    with log_path.open("w+", errors="replace") as out:
        if STOPPING.is_set():
            return 130, "not started: interrupted"
        proc = subprocess.Popen(
            SHELL + ["-c", step.run],
            cwd=cwd,
            env=env,
            stdin=subprocess.DEVNULL,
            stdout=out,
            stderr=subprocess.STDOUT,
            start_new_session=True,
        )
        with RUNNING_LOCK:
            RUNNING.add(proc.pid)
        try:
            returncode = proc.wait()
        finally:
            with RUNNING_LOCK:
                RUNNING.discard(proc.pid)
            try:
                os.killpg(proc.pid, signal.SIGKILL)
            except (ProcessLookupError, PermissionError):
                pass
        out.seek(0)
        return returncode, out.read()


def select_steps(units: list[Unit], names: set[str]) -> list[Unit]:
    """Only the named steps. A stateful group keeps its earlier steps too: they
    hand state (a bun install, GITHUB_ENV) to the ones asked for."""
    selected: list[Unit] = []
    for unit in units:
        indexes = [i for i, step in enumerate(unit.steps) if step.name in names]
        if not indexes:
            continue
        steps = unit.steps[: indexes[-1] + 1] if is_stateful(unit) else [unit.steps[i] for i in indexes]
        selected.append(dataclasses.replace(unit, steps=steps))
    return selected


def git(*args: str) -> str:
    return subprocess.run(
        ["git", *args], cwd=ROOT, check=True, stdout=subprocess.PIPE, text=True
    ).stdout.strip()


def default_base(head_sha: str) -> str:
    explicit = os.environ.get("CMUX_GUARDS_BASE_SHA")
    if explicit:
        return explicit
    for ref in ("upstream/main", "mf/main", "origin/main"):
        try:
            return git("merge-base", head_sha, ref)
        except subprocess.CalledProcessError:
            continue
    return ""


def tree_is_clean() -> bool:
    # Untracked files count: a new test or module that was never `git add`ed
    # passes here but is not in the commit the stamp vouches for.
    return git("status", "--porcelain", "--untracked-files=normal") == ""


def write_stamp(head_sha: str, groups: list[str], skipped: list[str], seconds: float) -> Path:
    directory = cache_root() / "pass"
    directory.mkdir(parents=True, exist_ok=True)
    stamp = directory / head_sha
    # The tree stamp covers a squash of this exact content pushed as another
    # commit (`git push <cmux remote> <squash>:main`).
    tree = git("rev-parse", f"{head_sha}^{{tree}}")
    body = (
        json.dumps(
            {
                "sha": head_sha,
                "tree": tree,
                "finished_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
                "seconds": round(seconds, 1),
                "platform": sys.platform,
                "groups": groups,
                "skipped_steps": skipped,
            },
            indent=2,
        )
        + "\n"
    )
    stamp.write_text(body)
    (directory / f"tree-{tree}").write_text(body)
    return stamp


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--group", action="append", default=[], help="run these matrix groups or jobs instead of the fast set")
    parser.add_argument("--all", action="store_true", help="run every guard group, not only the fast set")
    parser.add_argument("--jobs", type=int, default=os.cpu_count() or 4)
    parser.add_argument("--list", action="store_true", help="print the plan and exit")
    parser.add_argument("--no-stamp", action="store_true")
    parser.add_argument("--keep-going", action="store_true", help="keep running a sequential group after a failed step")
    parser.add_argument("--verbose", action="store_true", help="print every step's output")
    parser.add_argument("--step", action="append", default=[], help="run only this step (exact name); repeatable, no stamp")
    parser.add_argument("--root", help="run this checkout's guard steps instead of the runner's own (no stamp)")
    parser.add_argument("--results", help="write {step name: passed} as JSON to this file")
    args = parser.parse_args(argv)
    if args.root:
        global ROOT, WORKFLOW
        ROOT = Path(args.root).resolve()
        WORKFLOW = ROOT / ".github/workflows/ci-guards.yml"

    workflow = load_yaml(WORKFLOW)
    step_names = {
        str(s.get("name")) for job in GUARD_JOBS for s in (workflow["jobs"].get(job) or {}).get("steps", [])
    }
    stale = (DEPENDENCY_STEPS | LINUX_ONLY_STEPS | EVENT_CONDITION_STEPS | set(PORTABLE_SUBSTITUTES)) - step_names
    # An older checkout (--root, a bisect) may predate a special-cased step; the names only have to be current here.
    if stale and not args.root:
        print(f"run_ci_guards.py: ci-guards.yml has no step named {sorted(stale)}; update this script", file=sys.stderr)
        return 2

    head_sha = git("rev-parse", "HEAD")
    base_sha = default_base(head_sha)
    try:
        units = plan(workflow, base_sha, head_sha)
    except PlanError as error:
        print(f"run_ci_guards.py: {error}", file=sys.stderr)
        return 2
    wanted = set(args.group) if args.group else (None if args.all else set(FAST_GROUPS))
    if wanted is not None:
        units = [u for u in units if u.group in wanted or u.job in wanted]
        if not units:
            print(f"no guard group matches {sorted(wanted)}", file=sys.stderr)
            return 2
    if args.step:
        units = select_steps(units, set(args.step))
        if not units:
            # Exit 3: the checkout has no such step (it predates the test).
            print(f"no guard step named {sorted(args.step)}", file=sys.stderr)
            return 3

    if args.list:
        for unit in units:
            mode = "in order" if is_stateful(unit) else "in parallel"
            print(f"{unit.label}: {len(unit.steps)} steps, {mode}")
            for step in unit.steps:
                note = "  (Linux only; skipped here)" if skipped_here(step) else ""
                print(f"  - {step.name}{note}")
        return 0

    clean_at_start = tree_is_clean()
    env = dict(os.environ)
    env.setdefault("CI", "true")
    env["PYTHONDONTWRITEBYTECODE"] = "1"
    if sys.platform != "linux":
        # test_ci_change_areas.py forks one worker per test on Linux and runs
        # serially elsewhere (about two minutes on a Mac) unless asked.
        env.setdefault("CMUX_TEST_WORKERS", str(max(2, (os.cpu_count() or 4) // 2)))
    started = time.monotonic()
    print(
        f"cmux guards: {len(units)} groups, {sum(len(u.steps) for u in units)} steps, "
        f"head {head_sha[:12]}, base {base_sha[:12] or 'none'}, {args.jobs} workers",
        flush=True,
    )
    # A stateless group's steps are independent tasks; a group whose steps
    # pass state along (GITHUB_ENV, GITHUB_PATH, a bun install) is one task.
    tasks: list[tuple[Unit, list[Step]]] = []
    for unit in units:
        if is_stateful(unit):
            tasks.append((unit, unit.steps))
        else:
            tasks.extend((unit, [step]) for step in unit.steps)
    tasks.sort(key=lambda task: -len(task[1]))
    results: list[StepResult] = []
    pool = concurrent.futures.ThreadPoolExecutor(max_workers=max(1, args.jobs))
    futures = [pool.submit(run_steps, unit, steps, env, base_sha, args.keep_going) for unit, steps in tasks]
    try:
        for future in concurrent.futures.as_completed(futures):
            for result in future.result():
                results.append(result)
                if result.ok is False:
                    print(f"  FAIL {result.seconds:6.1f}s  {result.unit.label}: {result.step.name}", flush=True)
                    print(f"::group::{result.step.name}\n{result.output.rstrip()}\n::endgroup::", flush=True)
                elif args.verbose and result.ok:
                    print(f"  ok   {result.seconds:6.1f}s  {result.unit.label}: {result.step.name}", flush=True)
    except KeyboardInterrupt:
        pool.shutdown(wait=False, cancel_futures=True)
        stop_running()
        print("cmux guards: interrupted", file=sys.stderr)
        return 130
    pool.shutdown()
    seconds = time.monotonic() - started
    failed = [r for r in results if r.ok is False]
    skipped = sorted({r.step.name for r in results if r.ok is None})
    passed = sum(1 for r in results if r.ok)
    if args.results:
        outcome: dict[str, bool] = {}
        for result in results:
            if result.ok is not None:
                outcome[result.step.name] = outcome.get(result.step.name, True) and bool(result.ok)
        Path(args.results).write_text(json.dumps(outcome, indent=2, sort_keys=True) + "\n")
    print(f"cmux guards: {passed} steps passed, {len(failed)} failed, {len(skipped)} skipped (Linux only) in {seconds:.1f}s")
    if failed:
        print("failed: " + "; ".join(f"{r.unit.label}: {r.step.name}" for r in failed), file=sys.stderr)
        return 1
    if args.no_stamp or args.group or args.step or args.root:
        return 0
    if not (clean_at_start and tree_is_clean()) or git("rev-parse", "HEAD") != head_sha:
        print("tree has uncommitted or untracked files (or HEAD moved); no pass stamp written. Commit, then rerun to stamp.")
        return 0
    groups = sorted({u.group or u.job for u in units})
    print(f"pass stamp: {write_stamp(head_sha, groups, skipped, seconds)}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
