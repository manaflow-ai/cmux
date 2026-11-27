#!/usr/bin/env python3
"""Fail when a scheduled workflow dispatches another workflow run with only the repository GITHUB_TOKEN.

A schedule registers only from main, so many nightlies are a cron job on main that runs `gh workflow run X --ref
BRANCH`. The job token shares the repository's one hourly Actions REST pool with every other workflow; when it is
spent the dispatch fails "HTTP 403: API rate limit exceeded for installation" and the nightly silently does not run
(ios-reliability-matrix, 2026-11-23 run 45138996666 and 2026-11-25 run 45576360618: two of three nightlies lost,
the ios-app-store-live probe's matrix part went stale). The cmux bot App's token has an hour of its own, so a
dispatch step must use it (`steps.<id>.outputs.token`, from actions/create-github-app-token), with the job token
allowed only as the fallback (`steps.app-token.outputs.token || github.token`). cmux#57719 and this lint's PR moved
every such step; this keeps new ones from coming back.

A step dispatches when its `run:` (or a repository script it names, or a Python module beside that script it
imports, one level) has `gh workflow run`, a REST call to `.../dispatches`, or `createWorkflowDispatch`. The
imported modules count since nightly-next-feed-watch.yml's resume step ran nightly_next_unsigned_resume.py, whose
dispatch is nightly_next_feed_watch.py's, on the job token: the lint passed and the resume read 403 (run
45961586372). Imports are read as `import a, b`, `from a import x`, `from . import a, b` and `from .a import x`, each
resolved to a sibling `a.py`. One level, not the whole import graph: a deeper walk reaches shared helpers whose own
dispatch the step never calls (main_full_suite.py > classify_failures.py > ui_tests_dispatch.py's rerun dispatch,
while main_full_suite.py uses only classify_failures.failure_key and BOT) and flagged three steps that dispatch
nothing.

An actions/github-script step dispatches when its `script:` (or a repository script it names) calls
`createWorkflowDispatch` or a `.../dispatches` route; a `gh workflow run` there is text in a message, not a call.
github-script calls on its `github-token:` input, which defaults to the job token, so six nightly dispatchers that
read through `github` were invisible to a `run:`-only lint and went red for a day on the spent job token (cmux#61103,
runs 45791594489, 45809391120, 45804008279, 45831824446, 45944569896).

It is fine when any of these holds:
- its token (github-script's `github-token:`; else GH_TOKEN / GITHUB_TOKEN of the step's env, else the job's, else
  the workflow's) names an App token output;
- another env value of the step names one (a script that takes the App token in its own variable, as
  hosted_light_rescue.py's HOSTED_LIGHT_TOKEN);
- an earlier step of the job runs `scripts/ci/gh_app_token.sh --install` without `--reads-only` (every gh call made
  with github.token then goes out as the App first; --reads-only leaves the dispatch, a write, on github.token).
With no token at all, gh has none and the lint flags it too.

Handbook: cmuxterm-hq docs/handbook/cron-dispatch-on-job-token.md.

    python3 scripts/ci/cron_dispatch_token_lint.py [--workflows DIR]   # exit 1 and one line per offending step
"""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[2]
WORKFLOWS = ROOT / ".github" / "workflows"

DISPATCH = re.compile(r"gh\s+workflow\s+run\b|/dispatches\b|createWorkflowDispatch")
JS_DISPATCH = re.compile(r"/dispatches\b|createWorkflowDispatch")
SCRIPT = re.compile(r"(?<![\w/.-])((?:\./)?(?:scripts|\.github)/[\w./-]+\.(?:py|sh|js|mjs|ts))")
APP_TOKEN = re.compile(r"steps\.[\w-]+\.outputs\.token")

# (workflow, job): why that job keeps the job token. Each is a choice another guard holds, so the
# exemption names it; a new entry needs the same.
EXEMPT = {
    ("billing-nightly.yml", "storekit"): "secret-free by tests/test_ci_billing_nightly.py "
    "(secrets stay in the Apple environment jobs), so it cannot hold the App key",
    ("ci-hosted-light-rescue.yml", "rescue"): "secret-free by tests/test_ci_runner_pools.py "
    "(it runs on a fresh VM without the overflow probe), so it cannot hold the App key",
}


def triggers(workflow: dict) -> object:
    # PyYAML reads the bare key `on` as True.
    return workflow.get("on", workflow.get(True))


def scheduled(workflow: dict) -> bool:
    on = triggers(workflow)
    return isinstance(on, dict) and "schedule" in on


# `import a, b` / `import a as x, b`, `from a import ...`, `from .a import ...` and `from . import a, b`.
IMPORT = re.compile(r"^[ \t]*import[ \t]+([\w., \t]+)", re.MULTILINE)
FROM = re.compile(r"^[ \t]*from[ \t]+(\.*)([\w.]*)[ \t]+import[ \t]+(\([\w,\s]*\)|[\w, \t]+)", re.MULTILINE)


def imported(text: str) -> set[str]:
    """Module names a Python file imports that may be a sibling `NAME.py`."""
    names = set()
    for match in IMPORT.finditer(text):
        for part in match.group(1).split(","):
            name = part.split()[0] if part.split() else ""
            names.add(name.split(".")[0])
    for match in FROM.finditer(text):
        dots, module, what = match.groups()
        if module:
            names.add(module.split(".")[0])
        elif dots:  # `from . import a, b`: each name is a sibling module
            names.update(part.split()[0] for part in what.strip("()").split(",") if part.split())
    return {n for n in names if n.isidentifier()}


def _read(path: Path) -> str:
    try:
        return path.read_text(errors="replace") if path.is_file() else ""
    except OSError:
        return ""


def dispatches(run: str, root: Path, pattern: re.Pattern = DISPATCH) -> bool:
    if pattern.search(run):
        return True
    for rel in SCRIPT.findall(run):
        path = root / rel.removeprefix("./")
        text = _read(path)
        if pattern.search(text):
            return True
        if path.suffix == ".py":
            for name in imported(text):
                if pattern.search(_read(path.with_name(f"{name}.py"))):
                    return True
    return False


def github_script(step: dict) -> bool:
    return "actions/github-script" in str(step.get("uses", ""))


def step_dispatches(step: dict, root: Path) -> bool:
    if github_script(step):
        args = step.get("with") if isinstance(step.get("with"), dict) else {}
        return dispatches(str(args.get("script", "")), root, JS_DISPATCH)
    return dispatches(str(step.get("run", "")), root)


def step_token(step: dict, job: dict, workflow: dict) -> str | None:
    if github_script(step):
        args = step.get("with") if isinstance(step.get("with"), dict) else {}
        return str(args.get("github-token") or "${{ github.token }}")
    return token(step.get("env"), job.get("env"), workflow.get("env"))


def token(*envs: object) -> str | None:
    for env in envs:
        if isinstance(env, dict):
            for key in ("GH_TOKEN", "GITHUB_TOKEN"):
                if key in env:
                    return str(env[key])
    return None


def token_ok(value: str | None) -> bool:
    return value is not None and bool(APP_TOKEN.search(value))


def routes_through_app(steps: list, index: int) -> bool:
    for step in steps[:index]:
        run = str(step.get("run", "")) if isinstance(step, dict) else ""
        if "gh_app_token.sh" in run and "--install" in run and "--reads-only" not in run:
            return True
    return False


def offenders(workflows: Path, root: Path) -> list[str]:
    found = []
    for path in sorted(workflows.glob("*.y*ml")):
        try:
            workflow = yaml.safe_load(path.read_text())
        except yaml.YAMLError:
            continue
        if not isinstance(workflow, dict) or not scheduled(workflow):
            continue
        for job_id, job in (workflow.get("jobs") or {}).items():
            if not isinstance(job, dict):
                continue
            if (path.name, job_id) in EXEMPT:
                continue
            for index, step in enumerate(job.get("steps") or []):
                if not isinstance(step, dict) or not step_dispatches(step, root):
                    continue
                value = step_token(step, job, workflow)
                env = step.get("env") if isinstance(step.get("env"), dict) else {}
                if token_ok(value) or any(token_ok(str(v)) for v in env.values()):
                    continue
                if not routes_through_app(job.get("steps") or [], index):
                    name = step.get("name") or f"step {index + 1}"
                    found.append(f"{path.name}: {job_id}: {name}: dispatches with {value or 'no token'}")
    return found


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--workflows", type=Path, default=WORKFLOWS)
    parser.add_argument("--root", type=Path, default=ROOT)
    args = parser.parse_args(argv)
    found = offenders(args.workflows, args.root)
    for line in found:
        print(f"::error::{line}; mint the cmux bot App token (actions/create-github-app-token) and use "
              "`steps.<id>.outputs.token || github.token` (docs: scripts/ci/cron_dispatch_token_lint.py)")
    return 1 if found else 0


if __name__ == "__main__":
    sys.exit(main())
