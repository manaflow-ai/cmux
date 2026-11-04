#!/usr/bin/env python3
"""Run the CI guard suite from .github/workflows/ci-guards.yml, fast.

ci-guards.yml stays the one list of guard steps. This reads it and runs every
`run:` step of its guard jobs outside GitHub Actions, one worker per job/matrix
group, steps in file order within a group. The same runner backs:

  scripts/ci/guards-local.sh           a dev Mac, seconds, no build
  ci.yml and ci-fast-guards.yml        the "CI fast guards" checks

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
a step. A step that runs several independent checks (tests/test_ci_self_hosted_guard.sh)
reports each one through $CMUX_GUARD_CHECK_RESULTS ("<passed 0|1><TAB><check>"
lines), and --results lists each as "<step> :: <check>" beside the step, so
guards_new_reds.py compares checks, not just steps: one check red on the base
cannot mask a different check red on the change. `--json PATH` writes the full plan and every step's result, which
scripts/ci/merge_main.py uses to tell a failure the branch inherited from main
from one it introduced.
"""

from __future__ import annotations

import argparse
import concurrent.futures
import contextlib
import dataclasses
import fcntl
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
    "workflow-guard-submodule-forward-only",
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
# Steps that prepare an Actions runner's reused workspace, never a guard: the submodule reset deinits every
# submodule, so run inside the parallel groups it would race release-notary's ghostty-next checkout.
WORKSPACE_STEPS = {
    "Drop stale submodule checkouts (self-hosted reused workspace)",
}
# Steps whose `if:` tests the event, which does not apply off Actions. Any
# other condition beyond `matrix.group == '...'` fails the plan rather than
# silently dropping a step.
EVENT_CONDITION_STEPS = {
    # The history job binds the synthetic merge base; run_steps binds it
    # directly (PACKAGE_RESOLVED_POLICY_BASE_REF).
    "Bind package policy to synthetic merge base",
    # A manual dispatch's shallow checkout fetches main's history; a local
    # checkout already has it, so a local run is never a dispatch.
    "Fetch main history for a manual dispatch",
}
# The groups the "CI fast guards" check and a default local run cover: the
# workflow, scripts/ci and repository-variable contracts. `--all` runs every
# guard group, as ci.yml's routed `guards` job does for a CI change.
FAST_GROUPS = ("ci",)
# Steps that assert Linux-only behavior (GNU tools, /proc, a Linux workload
# profile). They run in CI; a macOS run skips them and says so.
LINUX_ONLY_STEPS = {
    "Validate CMUX workload profile contract",
}
# Linux-only wrappers whose payload is portable: off Linux, run the payload.
# The workload profile runner refuses macOS, but ci-guard.sh's commands (the
# self-hosted runner policy among them) run anywhere.
PORTABLE_SUBSTITUTES = {
    "Run canonical CMUX CI guard profile": "scripts/ci/run_ci_guard_payload.sh",
}
# A guard step may run for several matrix groups. Keep the optional fast-guard
# gate attached to each group term, while rejecting any other expression
# instead of silently dropping a step from the local plan.
GROUP_CONDITION = re.compile(r"matrix\.group\s*==\s*'([a-z0-9-]+)'")
GROUP_TERM = re.compile(
    r"matrix\.group\s*==\s*'[a-z0-9-]+'\s*"
    r"(?:&&\s*steps\.fast-guard\.outputs\.skip\s*!=\s*'true'\s*)?"
)
GROUP_EXPRESSION = re.compile(
    rf"(?:{GROUP_TERM.pattern})(?:\s*\|\|\s*(?:{GROUP_TERM.pattern}))*"
)
# The prefix every workflow-guard-tests step carries so a red guard does not
# skip the rest of its group.
KEEP_GOING = re.compile(r"!cancelled\(\)\s*&&\s*(.+)")
EXPRESSION = re.compile(r"\$\{\{\s*(.*?)\s*\}\}")
SHELL = ["bash", "--noprofile", "--norc", "-eo", "pipefail"]
# Steps run in their own sessions, so Ctrl-C reaches only this process; it
# stops queued steps and kills the running ones' process groups.
STOPPING = threading.Event()
RUNNING: set[int] = set()
RUNNING_LOCK = threading.Lock()
# Steps that install packages with apt-get hold the dpkg and apt list locks, so
# two at once fail ("Could not get lock /var/lib/dpkg/lock-frontend"). They take
# turns, host-wide, so concurrent guard runs on one runner host wait too. Not
# "cmux-": tests rewrite the workflows' fixed /tmp/cmux-* paths.
APT_GET = re.compile(r"\bapt-get\b")
APT_LOCK = Path("/tmp/ci-guards-apt.lock")
APT_TURN = threading.Lock()


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
    # The step's own checks, when it reports them (CHECK_RESULTS_ENV).
    checks: dict[str, bool] = dataclasses.field(default_factory=dict)


CHECK_RESULTS_ENV = "CMUX_GUARD_CHECK_RESULTS"
CHECK_SEPARATOR = " :: "


def read_check_results(path: Path) -> dict[str, bool]:
    """A step's per-check outcomes: "<passed 0|1><TAB><check>" lines."""
    checks: dict[str, bool] = {}
    if not path.exists():
        return checks
    for line in path.read_text(errors="replace").splitlines():
        passed, sep, name = line.partition("\t")
        if sep and name.strip() and passed in ("0", "1"):
            name = name.strip()
            checks[name] = checks.get(name, True) and passed == "1"
    return checks


def load_yaml(path: Path):
    try:
        import yaml  # type: ignore
    except ImportError:
        sys.exit("run_ci_guards.py needs PyYAML; run it through scripts/ci/guards-local.sh")
    with path.open() as handle:
        return yaml.safe_load(handle)


def step_groups(condition: str) -> tuple[set[str], bool]:
    """Groups named by a step `if:`, and whether anything else is in it."""
    wrapped = condition.strip()
    if not wrapped:
        return set(), False
    if wrapped.startswith("${{") and wrapped.endswith("}}"):
        expression = wrapped[3:-2].strip()
        # `!cancelled() && <groups>` keeps a group running past a red step in
        # CI; a local run already runs every step, so only the groups count.
        keep_going = KEEP_GOING.fullmatch(expression)
        if keep_going:
            expression = keep_going.group(1).strip()
            if expression.startswith("(") and expression.endswith(")"):
                expression = expression[1:-1].strip()
        if GROUP_EXPRESSION.fullmatch(expression):
            return set(GROUP_CONDITION.findall(expression)), False
    return set(GROUP_CONDITION.findall(condition)), True


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
                "github.token": "",
                "github.event.pull_request.head.sha": head_sha,
                "github.event.pull_request.base.sha": base_sha,
                # Outside Actions there is no PR base branch name. Fetch the
                # explicit local comparison revision instead.
                "github.event.pull_request.base.ref": base_sha,
                "github.event.merge_group.base_ref": base_sha,
                "github.event.merge_group.base_sha": base_sha,
                "github.event.before": base_sha,
            }
            steps: list[Step] = []
            for raw in job["steps"]:
                name = str(raw.get("name") or raw.get("uses") or raw.get("run", "")[:40])
                condition = str(raw.get("if", ""))
                named, other = step_groups(condition)
                if name in EVENT_CONDITION_STEPS:
                    continue
                if other:
                    raise PlanError(f"step {name!r} has a condition run_ci_guards.py cannot evaluate: {condition}")
                if named and group not in named:
                    continue
                if "uses" in raw or name in DEPENDENCY_STEPS or name in WORKSPACE_STEPS:
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
        or "init-submodule.sh" in step.run
        or "GITHUB_ENV" in step.run
        or "GITHUB_PATH" in step.run
        for step in unit.steps
    )


def needs_clean_tree(steps: list[Step]) -> bool:
    """The workload profile runner refuses a checkout with source changes, and
    other steps (a submodule init) change the shared checkout while they run,
    so a task holding it runs alone, before the parallel steps."""
    return any("cmux_workload_profile.py run" in step.run for step in steps)


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
            check_file = temp_path / "step-checks.tsv"
            check_file.unlink(missing_ok=True)
            step_env[CHECK_RESULTS_ENV] = str(check_file)
            returncode, output = run_step(step, cwd, step_env, temp_path / "step.log")
            results.append(StepResult(unit, step, returncode == 0, time.monotonic() - started, output,
                                      read_check_results(check_file)))
            if returncode != 0 and not keep_going:
                break
    return results


def wait_for(take) -> bool:
    """Retry `take()` until it succeeds (True) or the run is interrupted
    (False), so an interrupted run never stays blocked on another's turn."""
    while not take():
        if STOPPING.is_set():
            return False
        time.sleep(0.2)
    return True


def try_flock(handle) -> bool:
    try:
        fcntl.flock(handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        return False
    return True


@contextlib.contextmanager
def apt_turn(step: Step):
    """Hold the host-wide apt turn while a step that runs apt-get runs. An
    interrupted wait yields without the turn; run_step then skips the step."""
    if not APT_GET.search(step.run) or not wait_for(lambda: APT_TURN.acquire(timeout=0.2)):
        yield
        return
    try:
        try:
            handle = APT_LOCK.open("a")
        except OSError:
            # Another user's lock file: the in-process turn and apt-get's own
            # DPkg::Lock::Timeout still apply.
            yield
            return
        with handle:
            wait_for(lambda: try_flock(handle))
            yield
    finally:
        APT_TURN.release()


def run_step(step: Step, cwd: Path, env: dict[str, str], log_path: Path) -> tuple[int, str]:
    """Run one step in its own session and reap whatever it leaves behind.

    Output goes to a file, not a pipe: a test that leaks a background child
    (several fake a hung process with `signal.pause()`) would otherwise hold
    the pipe open and the runner would wait on it forever. Actions ends a job
    by killing its process tree; this does the same per step.
    """
    with log_path.open("w+", errors="replace") as out, apt_turn(step):
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


def feat_routed_groups(changed_files: str) -> tuple[str, ...]:
    """The groups a feat-cmux-next change routes to; an unreadable list routes every one."""
    import detect_linux_guard_changes  # noqa: PLC0415 - the router, beside this script

    try:
        paths = [line.strip() for line in Path(changed_files).read_text(encoding="utf-8").splitlines() if line.strip()]
    except (OSError, UnicodeError):
        paths = []
    return detect_linux_guard_changes.classify_feat(paths)


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


def write_results(path: str, head_sha: str, base_sha: str, units: list[Unit],
                  results: list[StepResult], seconds: float) -> None:
    body = {
        "root": str(ROOT),
        "head": head_sha,
        "base": base_sha,
        "seconds": round(seconds, 1),
        "units": [{"label": unit.label, "job": unit.job, "group": unit.group, "stateful": is_stateful(unit)}
                  for unit in units],
        # Every step the plan held, run or not: a step missing from "steps"
        # but planned was not reached (an earlier step of its stateful group
        # failed); one missing from both does not exist in this checkout.
        "planned": [{"unit": unit.label, "name": step.name} for unit in units for step in unit.steps],
        "steps": [
            {
                "unit": r.unit.label,
                "job": r.unit.job,
                "group": r.unit.group,
                "name": r.step.name,
                "status": "skipped" if r.ok is None else ("pass" if r.ok else "fail"),
                "seconds": round(r.seconds, 2),
                "output_tail": "\n".join(r.output.rstrip().splitlines()[-40:]) if r.ok is False else "",
                "checks": dict(sorted(r.checks.items())),
            }
            for r in results
        ],
    }
    Path(path).write_text(json.dumps(body, indent=2) + "\n")


def main(argv: list[str]) -> int:
    global ROOT, WORKFLOW
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
    parser.add_argument("--json", dest="json_path", help="write the plan and every step's result to this file")
    parser.add_argument(
        "--feat-routes", metavar="FILE",
        help="run the fast set plus the groups the changed files in FILE (one per line) route to for a "
             "feat-cmux-next change (detect_linux_guard_changes.classify_feat); no stamp",
    )
    args = parser.parse_args(argv)
    if args.root:
        ROOT = Path(args.root).resolve()
        WORKFLOW = ROOT / ".github/workflows/ci-guards.yml"

    workflow = load_yaml(WORKFLOW)
    step_names = {
        str(s.get("name")) for job in GUARD_JOBS for s in (workflow["jobs"].get(job) or {}).get("steps", [])
    }
    stale = (DEPENDENCY_STEPS | WORKSPACE_STEPS | LINUX_ONLY_STEPS | EVENT_CONDITION_STEPS | set(PORTABLE_SUBSTITUTES)) - step_names
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
    if args.feat_routes:
        routed = feat_routed_groups(args.feat_routes)
        print(f"feat-cmux-next routed guard groups: {', '.join(routed) or 'none'}", flush=True)
        wanted = (wanted or set(FAST_GROUPS)) | set(routed)
    if wanted is not None:
        units = [u for u in units if u.group in wanted or u.job in wanted]
        if not units:
            print(f"no guard group matches {sorted(wanted)}", file=sys.stderr)
            if args.json_path:
                # An empty plan is an answer for a caller comparing checkouts:
                # this one has none of those groups.
                write_results(args.json_path, head_sha, base_sha, [], [], 0.0)
            return 2
    if args.step:
        units = select_steps(units, set(args.step))
        if not units:
            # Exit 3: the checkout has no such step (it predates the test).
            print(f"no guard step named {sorted(args.step)}", file=sys.stderr)
            if args.json_path:
                # An empty plan tells a caller comparing checkouts that this
                # one has none of those steps.
                write_results(args.json_path, head_sha, base_sha, [], [], 0.0)
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
    # Tasks that need a clean checkout run one at a time first; then the rest share the pool.
    batches = [[task] for task in tasks if needs_clean_tree(task[1])]
    batches.append([task for task in tasks if not needs_clean_tree(task[1])])
    results: list[StepResult] = []
    pool = concurrent.futures.ThreadPoolExecutor(max_workers=max(1, args.jobs))
    try:
        for batch in batches:
            futures = [pool.submit(run_steps, unit, steps, env, base_sha, args.keep_going) for unit, steps in batch]
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
                for check, ok in result.checks.items():
                    key = f"{result.step.name}{CHECK_SEPARATOR}{check}"
                    outcome[key] = outcome.get(key, True) and ok
        Path(args.results).write_text(json.dumps(outcome, indent=2, sort_keys=True) + "\n")
    print(f"cmux guards: {passed} steps passed, {len(failed)} failed, {len(skipped)} skipped (Linux only) in {seconds:.1f}s")
    if args.json_path:
        write_results(args.json_path, head_sha, base_sha, units, results, seconds)
    if failed:
        print("failed: " + "; ".join(f"{r.unit.label}: {r.step.name}" for r in failed), file=sys.stderr)
        return 1
    if args.no_stamp or args.group or args.step or args.root or args.feat_routes:
        return 0
    if not (clean_at_start and tree_is_clean()) or git("rev-parse", "HEAD") != head_sha:
        print("tree has uncommitted or untracked files (or HEAD moved); no pass stamp written. Commit, then rerun to stamp.")
        return 0
    groups = sorted({u.group or u.job for u in units})
    print(f"pass stamp: {write_stamp(head_sha, groups, skipped, seconds)}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
