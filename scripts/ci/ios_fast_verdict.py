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
  cmux-next-ios/{App,NotificationContent,       the app: xcodegen, then build-for-testing of the CmuxMobileApp
    NotificationService,UITests}/, project.yml   scheme for the iOS Simulator (the app and CmuxMobileAppUITests
                                                 compiled, no UI test run: the full matrix runs them)
  any other path the ios-kit step routes         a build of the kit's test bundle (Package.swift, the Rust FFI and
    (the shared packages, the FFI, the toolchain,  the cmux-tui crates it compiles, a shared package the kit links:
    the Rust crates the FFI compiles)              compile verdict, tests after)

Every routed path but a kit test file also builds the app: a kit or shared-package API change that compiles in the
kit but not in the app or its UI tests is the break that reached feat-cmux-next (cmux#55399, cmux#55664: each PR
compiled on its own branch, the merged tree did not). The Rust crates are ios-kit's inputs, derived from the FFI's
Cargo graph (scripts/ci/ios_app_package_paths.py --check), so a new shared crate routes here once it is linked.

The `cmux/ios-fast` commit status (scripts/ci/pr_router.py posts it from the route, this script's `status` from
the jobs): success at once for a head that touches nothing iOS builds, pending until this check runs on an
iOS-affecting head handed to land, then this check's own verdict, so a ruleset can require it.

A path the ios-kit step does not route (notes, verify/ evidence, agent scripts) plans nothing, as it takes no Mac in
the full matrix either.

    python3 scripts/ci/ios_fast_verdict.py plan [--paths-file FILE] [--root DIR]
    python3 scripts/ci/ios_fast_verdict.py status STATE DESCRIPTION   (env REPO, SHA, TOKENS; never fails the job)

prints the plan as JSON and, under GitHub Actions, writes `run`, `plan` and `summary` to $GITHUB_OUTPUT. With no
--paths-file it diffs HEAD^1..HEAD (the merge commit); no merge commit plans nothing, since the full matrix runs.
"""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
import time
import urllib.request
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
sys.path.insert(0, str(HERE))
import ci_steps  # noqa: E402
import gh_http  # noqa: E402

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
# The commit status a ruleset can require (pr-router.yml posts the route's state, pr-pipeline.yml the verdict).
STATUS_CONTEXT = "cmux/ios-fast"


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


def affects(paths: list[str], step: ci_steps.Step | None = None) -> bool:
    """Whether any of PATHS is one this check builds (the router's instant-success test; plan()'s `run` without the
    kit's test-target listing, which the router's sparse checkout does not have)."""
    step = step or kit_step()
    return any(path in SELF or routes_ios(step, path) for path in paths)


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
        if not (len(parts) >= 3 and parts[0] == "Tests"):
            # The app and its UI tests link the kit and the shared packages: their compile is the merged-tree break.
            app = True
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


def post_status(state: str, description: str, repo: str, sha: str, tokens: list[str], target_url: str = "",
                rounds: int = 3, pause: float = 10.0) -> bool:
    """POST the STATUS_CONTEXT commit status, each token in turn, ROUNDS times (a spent budget or a 5xx on one is
    retried on the next). GitHub refuses a description over 140 characters."""
    body = json.dumps({"state": state, "context": STATUS_CONTEXT, "description": description[:140],
                       **({"target_url": target_url} if target_url else {})}).encode()
    for attempt in range(rounds):
        for token in tokens:
            req = urllib.request.Request(f"https://api.github.com/repos/{repo}/statuses/{sha}", data=body, method="POST",
                                         headers={"Accept": "application/vnd.github+json",
                                                  "Authorization": f"Bearer {token}",
                                                  "X-GitHub-Api-Version": "2022-11-28"})
            try:
                status, answer, _ = gh_http.request_through_rate_limit(req, 20)
                if status == 201:
                    return True
                print(f"{STATUS_CONTEXT}: post refused (HTTP {status}: {answer[:200]!r})", file=sys.stderr)
            except Exception as e:  # noqa: BLE001 - the next token, then the next round
                print(f"{STATUS_CONTEXT}: post refused ({type(e).__name__}: {e})", file=sys.stderr)
        if attempt + 1 < rounds:
            time.sleep(pause * (attempt + 1))
    return False


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
    st = sub.add_parser("status")
    st.add_argument("state", choices=("pending", "success", "failure", "error"))
    st.add_argument("description")
    args = parser.parse_args(argv)
    if args.cmd == "status":
        repo, sha = os.environ.get("REPO", ""), os.environ.get("SHA", "")
        tokens = [t for t in os.environ.get("TOKENS", "").split() if t]
        if not (repo and sha and tokens):
            print(f"::warning::{STATUS_CONTEXT} not posted: REPO, SHA and TOKENS are needed")
            return 0
        if not post_status(args.state, args.description, repo, sha, tokens, os.environ.get("RUN_URL", "")):
            print(f"::warning::{STATUS_CONTEXT} ({args.state}) was not posted at {sha}: its land waits on the last state")
        return 0
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
            # unknown (no merge commit to diff): the job skips, and cmux/ios-fast reads no verdict (error), not success.
            f.write(f"run={'unknown' if paths is None else 'true' if result['run'] else 'false'}\n")
            f.write(f"plan={json.dumps(result, separators=(',', ':'))}\n")
            f.write(f"summary={summary(result)}\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
