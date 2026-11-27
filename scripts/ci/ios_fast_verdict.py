#!/usr/bin/env python3
"""The fast iOS verdict's plan: which iOS target(s) a pull request's diff changed, so pr-pipeline.yml's
`ios-fast` job builds that target and runs only its tests, on a warm owned mini, before the full matrix.

Goal ios-ci-under-5min (cmuxterm-hq goals/ios-ci-under-5min.md): an iOS pull request's CI verdict under 5 min
p90, queue included. The full matrix (the `ios` job's ios-kit and ios-phone-cells steps, cmux-next-ios-kit.yml and
ios-reliability-matrix.yml after merge) is unchanged; this check is additive and runs beside it.

A changed path maps to:

  cmux-next-ios/CmuxMobileKit/Sources/<M>/...   the kit test target <M>Tests, when the kit has one; else a build of
                                                 the kit's test bundle (build-for-testing, no test run)
  cmux-next-ios/CmuxMobileKit/Tests/<T>/...     the kit test target <T> (not the Linux-only and benchmark targets,
                                                 which the simulator run never takes)
  cmux-next-ios/{App,NotificationContent,       the app: xcodegen, then a Debug build of CmuxMobileApp for the
    NotificationService,UITests}/, project.yml   iOS Simulator (no UI tests: the full matrix runs them)
  any other path the ios-kit step routes         a build of the kit's test bundle (Package.swift, the Rust FFI, a
    (the shared packages, the FFI, the toolchain)  shared package the kit links: compile verdict, tests after)

A path the ios-kit step does not route (notes, verify/ evidence, agent scripts) plans nothing, as it takes no Mac in
the full matrix either.

    python3 scripts/ci/ios_fast_verdict.py plan [--paths-file FILE] [--root DIR]

prints the plan as JSON and, under GitHub Actions, writes `run`, `plan` and `summary` to $GITHUB_OUTPUT. With no
--paths-file it diffs HEAD^1..HEAD (the merge commit); no merge commit plans nothing, since the full matrix runs.
"""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
sys.path.insert(0, str(HERE))
import ci_steps  # noqa: E402

KIT = "cmux-next-ios/CmuxMobileKit/"
APP_PATHS = (
    "cmux-next-ios/App/",
    "cmux-next-ios/NotificationContent/",
    "cmux-next-ios/NotificationService/",
    "cmux-next-ios/UITests/",
    "cmux-next-ios/project.yml",
)
# Never run by the simulator: the Instant list bench (ios-kit skips it too) and the Linux FFI shim's tests.
SKIPPED_TESTS = frozenset({"CmuxMobileInstantPerfTests", "CmuxMobileLinkFFILinuxTests"})
# This check's own files: a change to them builds the kit, so the check runs on its own pull request.
SELF = ("scripts/ci/ios_fast_verdict.py", "scripts/ci/ios_fast_verdict.sh")
# Past this many test targets the run is most of the kit: build the bundle and leave the tests to the full matrix.
MAX_TEST_TARGETS = 6
MAX_WHY = 20


def kit_step(table: ci_steps.Table | None = None) -> ci_steps.Step:
    return (table or ci_steps.load()).steps["ios-kit"]


def routes_ios(step: ci_steps.Step, path: str) -> bool:
    """Whether the ios-kit step's inputs take PATH (its globs and ignores, not the pipeline's own files)."""
    if not any(ci_steps.glob_pattern(g).match(path) for g in step.inputs):
        return False
    for glob in reversed(step.ignore):
        if ci_steps.glob_pattern(glob.lstrip("!")).match(path):
            return glob.startswith("!")
    return True


def test_targets(root: Path) -> set[str]:
    tests = root / KIT / "Tests"
    return {p.name for p in tests.iterdir() if p.is_dir()} if tests.is_dir() else set()


def plan(paths: list[str], root: Path = ROOT, step: ci_steps.Step | None = None) -> dict:
    step = step or kit_step()
    have = test_targets(root)
    tests: set[str] = set()
    build = False
    app = False
    why: list[str] = []
    for path in paths:
        if path in SELF:
            build = True
            why.append(f"{path}: this check's own file, kit build")
            continue
        if not routes_ios(step, path):
            continue
        if path.startswith(APP_PATHS):
            app = True
            why.append(f"{path}: app build")
            continue
        parts = path[len(KIT):].split("/") if path.startswith(KIT) else []
        if len(parts) >= 3 and parts[0] == "Sources":
            target = parts[1] + "Tests"
            if target in have and target not in SKIPPED_TESTS:
                tests.add(target)
                why.append(f"{path}: {target}")
            else:
                build = True
                why.append(f"{path}: {parts[1]} has no simulator test target, kit build")
            continue
        if len(parts) >= 3 and parts[0] == "Tests":
            if parts[1] in SKIPPED_TESTS:
                continue
            tests.add(parts[1])
            why.append(f"{path}: {parts[1]}")
            continue
        build = True
        why.append(f"{path}: kit build")
    if len(tests) > MAX_TEST_TARGETS:
        why.append(f"{len(tests)} test targets: kit build only, the full matrix runs the tests")
        tests = set()
        build = True
    return {
        "run": bool(tests or build or app),
        "tests": sorted(tests),
        # A test run builds the kit's bundle anyway; `build` alone is a build-for-testing with no test run.
        "build": build and not tests,
        "app": app,
        # The first reasons only: the plan rides one $GITHUB_OUTPUT line.
        "why": why[:MAX_WHY] + ([f"... {len(why) - MAX_WHY} more"] if len(why) > MAX_WHY else []),
    }


def summary(p: dict) -> str:
    if not p["run"]:
        return "no iOS target changed"
    parts = []
    if p["tests"]:
        parts.append("tests " + ", ".join(p["tests"]))
    if p["build"]:
        parts.append("kit build")
    if p["app"]:
        parts.append("app build")
    return "; ".join(parts)


def diff_paths() -> list[str] | None:
    try:
        subprocess.run(["git", "rev-parse", "-q", "--verify", "HEAD^2"], check=True, capture_output=True)
        out = subprocess.run(["git", "diff", "--name-only", "--no-renames", "-z", "HEAD^1", "HEAD"],
                             check=True, capture_output=True, text=True).stdout
    except (OSError, subprocess.CalledProcessError):
        return None
    return [p for p in out.split("\0") if p]


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    sub = parser.add_subparsers(dest="cmd", required=True)
    p = sub.add_parser("plan")
    p.add_argument("--paths-file")
    p.add_argument("--root", default=str(ROOT))
    args = parser.parse_args(argv)
    paths = ci_steps.read_paths(args.paths_file) if args.paths_file else diff_paths()
    if paths is None:
        result = {"run": False, "tests": [], "build": False, "app": False,
                  "why": ["no merge commit to diff: the full matrix runs"]}
    else:
        result = plan(paths, Path(args.root))
    print(json.dumps(result, indent=2))
    out = os.environ.get("GITHUB_OUTPUT")
    if out:
        with open(out, "a", encoding="utf-8") as f:
            f.write(f"run={'true' if result['run'] else 'false'}\n")
            f.write(f"plan={json.dumps(result, separators=(',', ':'))}\n")
            f.write(f"summary={summary(result)}\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
