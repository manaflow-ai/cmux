#!/usr/bin/env python3
"""Route a diff to the step table's steps and run one job's steps (ci/steps.toml).

  ci/run route --paths-file F            the routed steps by job, as JSON
  ci/run run --job JOB [--paths-file F] [--label NAME] [--only NAMES]

`ci/run` is the entry (it calls this file). `run` starts the job's routed steps, as many at
once as the machine has CPUs, each as `bash -euo pipefail -c RUN` in the current directory
with the caller's environment, and prints each one's output in a log group when it ends.
When the table has a `[setup]` command for the job it runs first, once, and only when a step
is routed: it fills `$CI_TOOLS` (a directory of this run; `$CI_TOOLS/bin` leads the steps'
PATH) with what the job's steps share, where a warm machine would already hold it. A step that
lists `needs = ["bun"]` also gets that `[tools]` command run first (bun, node: a tool only the
routed steps that need it pay for), all of them at once after the setup, each in `$CI_TOOLS`. A
setup or tool that fails fails the job. It exits 1 only when a step with `blocks = true` failed. A step with
`blocks = false` that fails or runs past its timeout is a warning annotation: an advisory
step never turns its job red. A step with `alone = true` runs by itself, after the others, in table order.
`--label NAME` says the event is a label change of NAME;
then only the steps that list NAME in `labels` run. `--only NAMES` (comma or space separated)
runs only those of the routed steps; empty means every routed step. A name the table does
not have is a notice and is skipped, never an error: the pull request that adds a step runs
against a base whose table lacks it. Two workflows run steps of the `advisory` job, each its
own (pr-body-checks.yml the description lints, pr-checks.yml the rest), so each names them.

The table's rules (checked on load): every step names one of the table's jobs, there are
at most 8 jobs, and a step that does not block runs in the `advisory` job in class `idle`.

A step's `inputs` are path globs (`**` crosses `/`, `*` and `?` do not). A change routes the
step when it touches one of them; a step with no inputs, an unknown change, and a change to
the pipeline itself (PIPELINE_PATHS: the table, this runner, the entry, the workflow) route it
always.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import signal
import subprocess
import sys
import tempfile
import threading
import time
import tomllib
from concurrent.futures import ThreadPoolExecutor
from dataclasses import dataclass, field
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
TABLE = ROOT / "ci" / "steps.toml"
MAX_JOBS = 8
SETUP_TIMEOUT = 600
# Each `[tools]` command, all started together after the setup: a download and a checksum, not a build.
TOOL_TIMEOUT = 180
# The pipeline's own definition: a change to any of them routes every step, so the change runs what it moved.
PIPELINE_PATHS = ("ci/steps.toml", "ci/run", "scripts/ci/ci_steps.py", ".github/workflows/pr-pipeline.yml")
ADVISORY_JOB = "advisory"
LOG_LOCK = threading.Lock()
CLASSES = ("feed", "named", "pr", "batch", "idle")


class TableError(ValueError):
    pass


@dataclass(frozen=True)
class Step:
    name: str
    job: str
    run: str
    blocks: bool = True
    klass: str = "pr"
    inputs: tuple[str, ...] = ()
    labels: tuple[str, ...] = ()
    timeout: int = 600
    title: str = ""
    about: str = ""
    needs: tuple[str, ...] = ()
    alone: bool = False


@dataclass
class Table:
    jobs: dict[str, str]
    steps: dict[str, Step]
    setup: dict[str, str]
    tools: dict[str, str] = field(default_factory=dict)


def glob_pattern(glob: str) -> re.Pattern[str]:
    """A path glob: ** crosses '/', * and ? do not."""
    out: list[str] = []
    i = 0
    while i < len(glob):
        if glob.startswith("**/", i):
            out.append("(?:.*/)?")
            i += 3
        elif glob.startswith("**", i):
            out.append(".*")
            i += 2
        elif glob[i] == "*":
            out.append("[^/]*")
            i += 1
        elif glob[i] == "?":
            out.append("[^/]")
            i += 1
        else:
            out.append(re.escape(glob[i]))
            i += 1
    return re.compile("".join(out) + r"\Z")


def parse(doc: dict) -> Table:
    jobs = doc.get("jobs") or {}
    if not jobs or not all(isinstance(v, str) for v in jobs.values()):
        raise TableError("[jobs] names each job with a one-line description")
    if len(jobs) > MAX_JOBS:
        raise TableError(f"[jobs] has {len(jobs)} jobs; the PR pipeline has at most {MAX_JOBS}")
    setup = doc.get("setup") or {}
    for job, command in setup.items():
        if job not in jobs:
            raise TableError(f"[setup] {job!r} is not one of [jobs] {sorted(jobs)}")
        if not isinstance(command, str) or not command.strip():
            raise TableError(f"[setup] {job}: a command")
    tools = doc.get("tools") or {}
    for tool, command in tools.items():
        if not isinstance(command, str) or not command.strip():
            raise TableError(f"[tools] {tool}: a command")
    steps: dict[str, Step] = {}
    known = set(Step.__dataclass_fields__) - {"name", "klass"} | {"class"}
    for name, raw in (doc.get("step") or {}).items():
        unknown = set(raw) - known
        if unknown:
            raise TableError(f"step {name}: unknown keys {sorted(unknown)}")
        for key in ("job", "run"):
            if not isinstance(raw.get(key), str) or not raw[key].strip():
                raise TableError(f"step {name}: `{key}` is required")
        step = Step(
            name=name,
            job=raw["job"],
            run=raw["run"],
            blocks=raw.get("blocks", True),
            klass=raw.get("class", "pr"),
            inputs=tuple(raw.get("inputs", ())),
            labels=tuple(raw.get("labels", ())),
            timeout=raw.get("timeout", 600),
            title=raw.get("title", ""),
            about=raw.get("about", ""),
            needs=tuple(raw.get("needs", ())),
            alone=raw.get("alone", False),
        )
        if step.job not in jobs:
            raise TableError(f"step {name}: job {step.job!r} is not one of [jobs] {sorted(jobs)}")
        if not isinstance(step.blocks, bool):
            raise TableError(f"step {name}: `blocks` is true or false")
        if not isinstance(step.alone, bool):
            raise TableError(f"step {name}: `alone` is true or false")
        if step.klass not in CLASSES:
            raise TableError(f"step {name}: class {step.klass!r} is not one of {CLASSES}")
        if not step.blocks and (step.job != ADVISORY_JOB or step.klass != "idle"):
            raise TableError(f"step {name}: a step that does not block runs in job {ADVISORY_JOB!r}, class 'idle'")
        if step.blocks and step.job == ADVISORY_JOB:
            raise TableError(f"step {name}: job {ADVISORY_JOB!r} holds only steps that do not block")
        if not all(isinstance(t, str) and t in tools for t in step.needs):
            raise TableError(f"step {name}: `needs` names tools of [tools] {sorted(tools)}")
        if not isinstance(step.timeout, int) or step.timeout <= 0:
            raise TableError(f"step {name}: `timeout` is a positive number of seconds")
        if not all(isinstance(g, str) and g and not g.startswith(("/", "!")) for g in step.inputs):
            raise TableError(f"step {name}: `inputs` are repo-relative path globs")
        steps[name] = step
    return Table(jobs=dict(jobs), steps=steps, setup=dict(setup), tools=dict(tools))


def load(path: Path = TABLE) -> Table:
    return parse(tomllib.loads(path.read_text(encoding="utf-8")))


def routed(step: Step, paths: list[str] | None) -> bool:
    """Whether a diff of `paths` needs the step. No inputs, or an unknown diff, routes it."""
    if not step.inputs or paths is None or any(p in PIPELINE_PATHS for p in paths):
        return True
    patterns = [glob_pattern(g) for g in step.inputs]
    return any(p.match(path) for path in paths for p in patterns)


def route(table: Table, paths: list[str] | None, label: str | None = None) -> dict[str, list[str]]:
    jobs: dict[str, list[str]] = {}
    for step in table.steps.values():
        if label is not None and label not in step.labels:
            continue
        if routed(step, paths):
            jobs.setdefault(step.job, []).append(step.name)
    return jobs


@dataclass
class Result:
    step: Step
    code: int | None  # None: ran past its timeout
    seconds: float
    output: str

    @property
    def ok(self) -> bool:
        return self.code == 0


def run_step(step: Step, env: dict[str, str] | None = None) -> Result:
    start = time.monotonic()
    proc = subprocess.Popen(
        ["bash", "-euo", "pipefail", "-c", step.run],
        stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True,
        env=env, start_new_session=True,
    )
    try:
        out, _ = proc.communicate(timeout=step.timeout)
        code: int | None = proc.returncode
    except subprocess.TimeoutExpired:
        # The step's own process group, which start_new_session made: its children go with it. A group that is
        # gone (ESRCH), or on macOS one whose processes are all zombies (EPERM), has nothing left to stop.
        try:
            os.killpg(proc.pid, signal.SIGKILL)
        except (ProcessLookupError, PermissionError):
            pass
        out, _ = proc.communicate()
        code = None
    return Result(step, code, time.monotonic() - start, out or "")


def print_log(r: Result, out=sys.stdout) -> None:
    """One step's output as one log group, whole: steps end on several threads."""
    with LOG_LOCK:
        print(f"::group::{r.step.name}\n{r.output.rstrip(chr(10))}\n::endgroup::", file=out, flush=True)


def report(results: list[Result], job: str, out=sys.stdout, logs: bool = True) -> str:
    """Print each step's log (unless it was printed as the step ended) and annotation; return the
    summary table's Markdown."""
    rows = [f"### Job `{job}`", "", "| Step | Blocks | Class | Result | Seconds |", "|---|---|---|---|---|"]
    for r in results:
        if logs:
            print_log(r, out)
        result = "passed" if r.ok else ("timed out" if r.code is None else f"exit {r.code}")
        if not r.ok:
            level = "error" if r.step.blocks else "warning"
            what = f"ran past its {r.step.timeout} s" if r.code is None else f"exited {r.code}"
            note = "" if r.step.blocks else " (advisory: never blocks)"
            print(f"::{level} title={r.step.title or r.step.name}::step {r.step.name} {what}{note}; see its log group", file=out)
        rows.append(f"| {r.step.name} | {'yes' if r.step.blocks else 'no'} | {r.step.klass} | {result} | {r.seconds:.1f} |")
    return "\n".join(rows) + "\n"


def parse_only(text: str | None) -> list[str]:
    """`--only`'s names, comma or space separated, in order; empty means no filter."""
    return [name for name in re.split(r"[\s,]+", text or "") if name]


def run_job(table: Table, job: str, paths: list[str] | None, label: str | None = None, out=sys.stdout,
            workers: int | None = None, only: list[str] | None = None) -> int:
    names = route(table, paths, label).get(job, [])
    if only:
        for name in only:
            if name not in table.steps:
                print(f"::notice title=Step table::no step {name} in this table (a base from before it); skipped",
                      file=out)
        names = [n for n in names if n in only]
    steps = [table.steps[n] for n in names]
    if not steps:
        print(f"No step of job {job} is routed for this change.", file=out)
        return 0
    results: list[Result] = []
    with tempfile.TemporaryDirectory(prefix="ci-tools-", dir=os.environ.get("RUNNER_TEMP") or None) as tools:
        env = dict(os.environ, CI_TOOLS=tools, PATH=f"{tools}/bin{os.pathsep}{os.environ.get('PATH', '')}")
        ready = True
        if job in table.setup:
            setup = run_step(Step(name=f"setup ({job})", job=job, run=table.setup[job], timeout=SETUP_TIMEOUT,
                                  title=f"{job} setup"), env)
            print_log(setup, out)
            results.append(setup)
            ready = setup.ok
        needed = sorted({t for step in steps for t in step.needs})
        if ready and needed:
            # Each tool is a download: all at once, and the steps wait for the slowest.
            with ThreadPoolExecutor(max_workers=len(needed)) as pool:
                def make_tool(tool: str) -> Result:
                    result = run_step(Step(name=f"tool ({tool})", job=job, run=table.tools[tool],
                                           timeout=TOOL_TIMEOUT, title=f"{tool} for {job}"), env)
                    print_log(result, out)
                    return result
                made = list(pool.map(make_tool, needed))
            results += made
            ready = all(r.ok for r in made)
        if ready:
            # Advisory steps wait on the network, not a CPU: they all start at once, as before.
            limit = len(steps) if job == ADVISORY_JOB else min(len(steps), workers or max(2, os.cpu_count() or 1))
            with ThreadPoolExecutor(max_workers=limit) as pool:
                # A step's log prints when it ends, so a job cut by its own timeout still shows the steps
                # that finished and which one was running.
                def run_and_print(step: Step) -> Result:
                    result = run_step(step, env)
                    print_log(result, out)
                    return result
                results += pool.map(run_and_print, [s for s in steps if not s.alone])
            # An `alone` step takes the whole machine: it runs by itself, after the others, in table order.
            results += [run_and_print(s) for s in steps if s.alone]
    summary = report(results, job, out, logs=False)
    if os.environ.get("GITHUB_STEP_SUMMARY"):
        with open(os.environ["GITHUB_STEP_SUMMARY"], "a", encoding="utf-8") as f:
            f.write(summary)
    return 1 if any(not r.ok and r.step.blocks for r in results) else 0


def read_paths(path: str | None) -> list[str] | None:
    if not path:
        return None
    try:
        text = Path(path).read_text(encoding="utf-8")
    except (OSError, UnicodeDecodeError):
        return None
    # `git diff -z` ends each path with a NUL and quotes none; a list with no NUL is one path a line.
    return [p for p in (text.split("\0") if "\0" in text else text.splitlines()) if p]


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--table", default=str(TABLE))
    sub = parser.add_subparsers(dest="command", required=True)
    r = sub.add_parser("route")
    r.add_argument("--paths-file")
    x = sub.add_parser("run")
    x.add_argument("--job", required=True)
    x.add_argument("--paths-file")
    x.add_argument("--label", default="", help="the label of a labeled or unlabeled event; empty for other events")
    x.add_argument("--workers", type=int, default=0, help="steps at once (default: the machine's CPUs)")
    x.add_argument("--only", default="", help="run only these routed steps (comma or space separated); empty: all")
    args = parser.parse_args(argv)
    table = load(Path(args.table))
    paths = read_paths(args.paths_file)
    if args.command == "route":
        print(json.dumps(route(table, paths), indent=1, sort_keys=True))
        return 0
    if args.job not in table.jobs:
        parser.error(f"--job {args.job!r} is not one of {sorted(table.jobs)}")
    return run_job(table, args.job, paths, args.label or None, workers=args.workers or None,
                   only=parse_only(args.only))


if __name__ == "__main__":
    sys.exit(main())
