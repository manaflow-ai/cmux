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
# self-hosted runner policy among them) run anywhere; only its `stage` timing
# markers need the runner.
PORTABLE_SUBSTITUTES = {
    "Run canonical CMUX CI guard profile": (
        "bash -c \"$(sed -e '/^stage /d' -e 's|^root=.*|root=\\\"$PWD\\\"|' "
        "scripts/ci/workloads/ci-guard.sh)\""
    ),
}
GROUP_CONDITION = re.compile(r"matrix\.group\s*==\s*'([a-z0-9-]+)'")
EXPRESSION = re.compile(r"\$\{\{\s*(.*?)\s*\}\}")
SHELL = ["bash", "--noprofile", "--norc", "-eo", "pipefail"]


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


def resolve(value: str, context: dict[str, str]) -> str:
    def replace(match: re.Match[str]) -> str:
        expression = match.group(1)
        if expression in context:
            return context[expression]
        # `a || b` style fallbacks over event fields: take the first known one.
        for part in (p.strip() for p in expression.split("||")):
            if part in context and context[part]:
                return context[part]
        return ""

    return EXPRESSION.sub(replace, str(value))


def plan(workflow: dict, base_sha: str, head_sha: str) -> list[Unit]:
    jobs = workflow["jobs"]
    units: list[Unit] = []
    for job_name in GUARD_JOBS:
        job = jobs[job_name]
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
                    # Conditions on the event (the history job's synthetic
                    # merge-base binding) do not apply off Actions; the base
                    # is bound below instead.
                    continue
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
    with tempfile.TemporaryDirectory(prefix="cmux-guard-") as temp:
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
                "PACKAGE_RESOLVED_POLICY_BASE_REF": base_sha,
            }
        )
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
        proc = subprocess.Popen(
            SHELL + ["-c", step.run],
            cwd=cwd,
            env=env,
            stdin=subprocess.DEVNULL,
            stdout=out,
            stderr=subprocess.STDOUT,
            start_new_session=True,
        )
        returncode = proc.wait()
        try:
            os.killpg(proc.pid, signal.SIGKILL)
        except (ProcessLookupError, PermissionError):
            pass
        out.seek(0)
        return returncode, out.read()


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
    return git("status", "--porcelain", "--untracked-files=no") == ""


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
    args = parser.parse_args(argv)

    workflow = load_yaml(WORKFLOW)
    step_names = {
        str(s.get("name")) for job in GUARD_JOBS for s in workflow["jobs"][job]["steps"]
    }
    stale = (DEPENDENCY_STEPS | LINUX_ONLY_STEPS | set(PORTABLE_SUBSTITUTES)) - step_names
    if stale:
        print(f"run_ci_guards.py: ci-guards.yml has no step named {sorted(stale)}; update this script", file=sys.stderr)
        return 2

    head_sha = git("rev-parse", "HEAD")
    base_sha = default_base(head_sha)
    units = plan(workflow, base_sha, head_sha)
    wanted = set(args.group) if args.group else (None if args.all else set(FAST_GROUPS))
    if wanted is not None:
        units = [u for u in units if u.group in wanted or u.job in wanted]
        if not units:
            print(f"no guard group matches {sorted(wanted)}", file=sys.stderr)
            return 2

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
    with concurrent.futures.ThreadPoolExecutor(max_workers=max(1, args.jobs)) as pool:
        futures = [pool.submit(run_steps, unit, steps, env, base_sha, args.keep_going) for unit, steps in tasks]
        for future in concurrent.futures.as_completed(futures):
            for result in future.result():
                results.append(result)
                if result.ok is False:
                    print(f"  FAIL {result.seconds:6.1f}s  {result.unit.label}: {result.step.name}", flush=True)
                    print(f"::group::{result.step.name}\n{result.output}::endgroup::", flush=True)
                elif args.verbose and result.ok:
                    print(f"  ok   {result.seconds:6.1f}s  {result.unit.label}: {result.step.name}", flush=True)
    seconds = time.monotonic() - started
    failed = [r for r in results if r.ok is False]
    skipped = sorted({r.step.name for r in results if r.ok is None})
    passed = sum(1 for r in results if r.ok)
    print(f"cmux guards: {passed} steps passed, {len(failed)} failed, {len(skipped)} skipped (Linux only) in {seconds:.1f}s")
    if failed:
        print("failed: " + "; ".join(f"{r.unit.label}: {r.step.name}" for r in failed), file=sys.stderr)
        return 1
    if args.no_stamp or args.group:
        return 0
    if not (clean_at_start and tree_is_clean()) or git("rev-parse", "HEAD") != head_sha:
        print("tree has uncommitted changes (or HEAD moved); no pass stamp written. Commit, then rerun to stamp.")
        return 0
    groups = sorted({u.group or u.job for u in units})
    print(f"pass stamp: {write_stamp(head_sha, groups, skipped, seconds)}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
