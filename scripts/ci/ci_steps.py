#!/usr/bin/env python3
"""Route a diff to the step table's steps and run one job's steps (ci/steps.toml).

  ci_steps.py route --paths-file F            the routed steps by job, as JSON
  ci_steps.py run --job JOB [--paths-file F] [--label NAME]

`run` starts the job's routed steps at once, each as `bash -euo pipefail -c RUN` in the
current directory with the caller's environment, and prints each one's output in a log
group when it ends. It exits 1 only when a step with `blocks = true` failed. A step with
`blocks = false` that fails or runs past its timeout is a warning annotation: an advisory
step never turns its job red. `--label NAME` says the event is a label change of NAME;
then only the steps that list NAME in `labels` run.

The table's rules (checked on load): every step names one of the table's jobs, there are
at most 8 jobs, and a step that does not block runs in the `advisory` job in class `idle`.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import signal
import subprocess
import sys
import time
import tomllib
from concurrent.futures import ThreadPoolExecutor
from dataclasses import dataclass, field
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
TABLE = ROOT / "ci" / "steps.toml"
MAX_JOBS = 8
ADVISORY_JOB = "advisory"
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


@dataclass
class Table:
    jobs: dict[str, str]
    steps: dict[str, Step]
    budget: dict[str, int] = field(default_factory=dict)


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
        )
        if step.job not in jobs:
            raise TableError(f"step {name}: job {step.job!r} is not one of [jobs] {sorted(jobs)}")
        if not isinstance(step.blocks, bool):
            raise TableError(f"step {name}: `blocks` is true or false")
        if step.klass not in CLASSES:
            raise TableError(f"step {name}: class {step.klass!r} is not one of {CLASSES}")
        if not step.blocks and (step.job != ADVISORY_JOB or step.klass != "idle"):
            raise TableError(f"step {name}: a step that does not block runs in job {ADVISORY_JOB!r}, class 'idle'")
        if step.blocks and step.job == ADVISORY_JOB:
            raise TableError(f"step {name}: job {ADVISORY_JOB!r} holds only steps that do not block")
        if not isinstance(step.timeout, int) or step.timeout <= 0:
            raise TableError(f"step {name}: `timeout` is a positive number of seconds")
        steps[name] = step
    return Table(jobs=dict(jobs), steps=steps, budget=dict(doc.get("budget") or {}))


def load(path: Path = TABLE) -> Table:
    return parse(tomllib.loads(path.read_text(encoding="utf-8")))


def routed(step: Step, paths: list[str] | None) -> bool:
    """Whether a diff of `paths` needs the step. No inputs, or an unknown diff, routes it."""
    if not step.inputs or paths is None:
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


def report(results: list[Result], job: str, out=sys.stdout) -> str:
    """Print each step's log and annotation; return the summary table's Markdown."""
    rows = [f"### Job `{job}`", "", "| Step | Blocks | Class | Result | Seconds |", "|---|---|---|---|---|"]
    for r in results:
        print(f"::group::{r.step.name}", file=out)
        print(r.output.rstrip("\n"), file=out)
        print("::endgroup::", file=out)
        result = "passed" if r.ok else ("timed out" if r.code is None else f"exit {r.code}")
        if not r.ok:
            level = "error" if r.step.blocks else "warning"
            what = f"ran past its {r.step.timeout} s" if r.code is None else f"exited {r.code}"
            note = "" if r.step.blocks else " (advisory: never blocks)"
            print(f"::{level} title={r.step.title or r.step.name}::step {r.step.name} {what}{note}; see its log group", file=out)
        rows.append(f"| {r.step.name} | {'yes' if r.step.blocks else 'no'} | {r.step.klass} | {result} | {r.seconds:.1f} |")
    return "\n".join(rows) + "\n"


def run_job(table: Table, job: str, paths: list[str] | None, label: str | None = None, out=sys.stdout) -> int:
    names = route(table, paths, label).get(job, [])
    steps = [table.steps[n] for n in names]
    if not steps:
        print(f"No step of job {job} is routed for this change.", file=out)
        return 0
    with ThreadPoolExecutor(max_workers=len(steps)) as pool:
        results = list(pool.map(run_step, steps))
    summary = report(results, job, out)
    if os.environ.get("GITHUB_STEP_SUMMARY"):
        with open(os.environ["GITHUB_STEP_SUMMARY"], "a", encoding="utf-8") as f:
            f.write(summary)
    return 1 if any(not r.ok and r.step.blocks for r in results) else 0


def read_paths(path: str | None) -> list[str] | None:
    if not path:
        return None
    try:
        return [line for line in Path(path).read_text(encoding="utf-8").splitlines() if line]
    except OSError:
        return None


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
    args = parser.parse_args(argv)
    table = load(Path(args.table))
    paths = read_paths(args.paths_file)
    if args.command == "route":
        print(json.dumps(route(table, paths), indent=1, sort_keys=True))
        return 0
    if args.job not in table.jobs:
        parser.error(f"--job {args.job!r} is not one of {sorted(table.jobs)}")
    return run_job(table, args.job, paths, args.label or None)


if __name__ == "__main__":
    sys.exit(main())
