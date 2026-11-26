#!/usr/bin/env python3
"""Run, on a feat-cmux-next pull request, the release-notary guard steps its change reaches (ci/steps.toml's
nightly-guards step).

The release-notary group of ci-guards.yml (nightly, signing, cmux-tui publication tests) ran on such a pull
request only inside cmux-next-guards.yml's ci-guard-group, which is a Tier B pull_request_skip job
(scripts/ci/affected-jobs.json): skipped unless the pull request carries full-ci, run on the push that lands it.
So #53861, #56394, #53840, #54859 (nightly.yml) and #55067 (cmux-tui-artifacts.yml) each merged a nightly job
their guard lists did not name, and the guards went red only on feat-cmux-next, after the merge.

This picks release-notary's steps by what the change reaches (guard_step_inputs.select, the selection
run_ci_guards.py --affected uses), leaves out the steps that hand state to later ones (the ghostty-next init:
the pipeline's checkout has no submodules, and nothing picked here reads one), and runs the rest at once.
Any red fails the step. `--list` prints the pick and runs nothing.

  python3 scripts/ci/nightly_guard_steps.py [--paths-file F] [--list] [--jobs N]

The changed paths come from --paths-file, else $CI_PATHS_FILE (ci/run's, one per line); with neither, every
release-notary step runs.
"""
from __future__ import annotations

import argparse
import concurrent.futures
import os
import sys
import tempfile
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent.parent
sys.path.insert(0, str(HERE))

import guard_step_inputs  # noqa: E402
import run_ci_guards  # noqa: E402

GROUP = "release-notary"


def release_notary_steps(root: Path = ROOT) -> list[run_ci_guards.Step]:
    workflow = run_ci_guards.load_yaml(root / ".github/workflows/ci-guards.yml")
    steps: dict[str, run_ci_guards.Step] = {}
    for unit in run_ci_guards.plan(workflow, "BASE_SHA", "HEAD"):
        if unit.group != GROUP:
            continue
        for step in unit.steps:
            if run_ci_guards.hands_state(step) or step.name in run_ci_guards.WORKSPACE_STEPS:
                continue
            steps.setdefault(step.name, step)
    return list(steps.values())


def pick(steps: list[run_ci_guards.Step], changed: list[str] | None, root: Path = ROOT) -> dict[str, str]:
    """{step name: why} for the steps the change reaches; no change list picks every step."""
    if changed is None:
        return {step.name: "no change list" for step in steps}
    tuples = [(s.name, s.run, s.working_directory, tuple(sorted(s.env.items()))) for s in steps]
    return guard_step_inputs.select(guard_step_inputs.Tree(root), tuples, changed)


def read_paths(path: str | None) -> list[str] | None:
    if not path:
        return None
    return [line for line in Path(path).read_text().splitlines() if line.strip()]


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--paths-file", default=os.environ.get("CI_PATHS_FILE") or None)
    parser.add_argument("--list", action="store_true", help="print the picked steps and run nothing")
    parser.add_argument("--jobs", type=int, default=os.cpu_count() or 4)
    args = parser.parse_args(argv)

    steps = release_notary_steps()
    picked = pick(steps, read_paths(args.paths_file))
    chosen = [step for step in steps if step.name in picked]
    print(f"nightly guards: {len(chosen)} of {len(steps)} release-notary steps reached", flush=True)
    for step in chosen:
        print(f"  - {step.name} ({picked[step.name]})", flush=True)
    if args.list or not chosen:
        return 0

    env = dict(os.environ)
    failed: list[str] = []
    with tempfile.TemporaryDirectory(prefix="nightly-guards-") as logs:
        def one(index: int, step: run_ci_guards.Step) -> tuple[run_ci_guards.Step, int, str, float]:
            started = time.monotonic()
            code, output = run_ci_guards.run_step(step, ROOT, env, Path(logs) / f"{index}.log")
            return step, code, output, time.monotonic() - started

        with concurrent.futures.ThreadPoolExecutor(max_workers=max(1, args.jobs)) as pool:
            for step, code, output, seconds in (f.result() for f in concurrent.futures.as_completed(
                    [pool.submit(one, i, s) for i, s in enumerate(chosen)])):
                verdict = "ok" if code == 0 else f"RED (exit {code})"
                print(f"::group::{verdict} {seconds:.0f}s {step.name}", flush=True)
                if code != 0:
                    print(output[-20000:], flush=True)
                print("::endgroup::", flush=True)
                if code != 0:
                    failed.append(step.name)
    if failed:
        print(f"nightly guards: {len(failed)} red: " + "; ".join(sorted(failed)), flush=True)
        return 1
    print(f"nightly guards: all {len(chosen)} green", flush=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
