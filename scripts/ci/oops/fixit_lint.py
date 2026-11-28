#!/usr/bin/env python3
"""fixit-lint: after a red web lint, apply the lint tools' own safe fixes and lint again; a green second lint writes
the fixup patch fixit-compile's push already carries.

    fixit_lint.py run --base BASE --merge MERGE [--lint SCRIPT] [--out DIR] [--seconds N]

Leo, 2026-11-22, on a red that sat on a pull request: "should've been caught and fixed faster. hell, maybe even
should've been automatic. how are our fixit type things for lint errors and random bullshit?" Compile errors had one
(fixit_compile.py, ci-oops 0a); lint errors had none on a pull request. The PR autofix's repair job runs only on a
re-run that ci-oops act_fixer asks for after a red it classes `mechanical` with fixer cmux-pr-autofix, and only clippy
is classed so: 0 of 1000 PR autofix runs (2026-11-27 19:32Z-21:31Z) were that re-run, and 985 were skipped whole.

scripts/ci/cmux_next_fast_gates.py runs this only when its `web lint` gate failed, after every gate has finished (it
edits the checkout), so a green pull request pays nothing. In the checkout of MERGE (BASE + the pull request head):
  1. SCRIPT --fix --base BASE --head MERGE: the package's `check:fix` (vp check --fix: Oxfmt and Oxlint's safe fixes)
     and ESLint --fix on web/'s changed files, the same command as `scripts/web-lint.sh --fix`.
  2. Only edits to files the pull request changes (BASE..MERGE) with a suffix fixit-compile's push takes
     (cmuxterm-hq tools/ci-oops/fixit_push.py SOURCE_SUFFIXES), outside .github/, are kept; every other edit is put back.
  3. They are committed on a detached HEAD and SCRIPT --base BASE --head THAT --new-only runs again: the gate's own
     check, so a finding the base already has does not stop the fix.
  4. Green: OUT/web-lint.patch and OUT/web-lint.json (fixer fixit-compile, the pull request head from
     $FIXIT_COMPILE_HEAD_SHA) and the `CI_OOPS={json}` line. The workflow uploads OUT as fixit-compile-<job>-<attempt>
     and the cmuxterm-hq fixit-compile reconciler pushes it to a same-repo lane/* branch as one fixup commit.
The checkout is put back at MERGE either way, and the gate's red stands: the fixup commit is the one that goes green.
Nothing runs off CI ($FIXIT_COMPILE_HEAD_SHA unset) or with FIXIT_COMPILE=0, and any failure here only prints.
"""
from __future__ import annotations

import argparse
import datetime as dt
import json
import os
import signal
import subprocess
import sys
import time
from pathlib import Path

FIXER = "fixit-compile"
NAME = "web-lint"
# cmuxterm-hq tools/ci-oops/fixit_push.py refuses a patch naming any other file.
SOURCE_SUFFIXES = (".rs", ".ts", ".tsx", ".mts", ".cts")


def now_iso() -> str:
    return dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def say(text: str) -> None:
    print(f"fixit-lint: {text}", flush=True)


def git(repo: Path, *args: str, check: bool = True) -> str:
    result = subprocess.run(["git", "-C", str(repo), "-c", "core.hooksPath=/dev/null", *args], capture_output=True,
                            text=True, timeout=120)
    if check and result.returncode != 0:
        raise RuntimeError(f"git {' '.join(args)}: {result.stderr.strip()[:300]}")
    return result.stdout


def bounded(argv: list[str], cwd: Path, seconds: float) -> int | None:
    """ARGV's exit code, its output passed through; None when it ran past SECONDS (its whole process group is
    stopped: bun and the lint tools it starts)."""
    if seconds <= 0:
        return None
    process = subprocess.Popen(argv, cwd=cwd, start_new_session=True)
    try:
        return process.wait(timeout=seconds)
    except subprocess.TimeoutExpired:
        for sig in (signal.SIGTERM, signal.SIGKILL):
            try:
                os.killpg(process.pid, sig)
            except ProcessLookupError:
                break
            try:
                process.wait(timeout=10)
                break
            except subprocess.TimeoutExpired:
                continue
        return None


def keepable(path: str, changed: set[str]) -> bool:
    return path in changed and path.endswith(SOURCE_SUFFIXES) and not path.startswith(".github/")


def ctx_fields(merge: str) -> dict:
    env = os.environ
    return {k: v for k, v in {
        "repo": env.get("GITHUB_REPOSITORY"), "workflow": env.get("GITHUB_WORKFLOW"), "job": env.get("GITHUB_JOB"),
        "run_id": env.get("GITHUB_RUN_ID"), "run_attempt": env.get("GITHUB_RUN_ATTEMPT"),
        "head_sha": env.get("FIXIT_COMPILE_HEAD_SHA"), "compiled_sha": merge,
        "head_ref": env.get("GITHUB_HEAD_REF") or None, "base_ref": env.get("GITHUB_BASE_REF") or None}.items() if v}


def default_out(repo: Path) -> Path:
    if os.environ.get("FIXIT_COMPILE_OUT"):
        return Path(os.environ["FIXIT_COMPILE_OUT"])
    if os.environ.get("RUNNER_TEMP"):
        return Path(os.environ["RUNNER_TEMP"]) / "fixit-compile"
    return repo / ".build" / "fixit-compile"


def summary(text: str) -> None:
    path = os.environ.get("GITHUB_STEP_SUMMARY")
    if path:
        try:
            with open(path, "a") as fh:
                fh.write(text + "\n")
        except OSError:
            pass


def fix(repo: Path, base: str, merge: str, lint: str, out: Path, seconds: float) -> dict | None:
    """The record of a written patch, or None (why is printed). The checkout is left at MERGE, clean."""
    deadline = time.monotonic() + seconds
    if git(repo, "rev-parse", "HEAD").strip() != merge:
        say(f"the checkout is not at {merge[:12]}; nothing is fixed")
        return None
    if git(repo, "status", "--porcelain", "--untracked-files=no").strip():
        say("the checkout has edits before the fix; nothing is fixed")
        return None
    changed = {p for p in git(repo, "diff", "--name-only", "--no-renames", "--diff-filter=ACMRT", base, merge)
               .splitlines() if p}
    py = sys.executable
    red_at = now_iso()
    try:
        code = bounded([py, lint, "--fix", "--base", base, "--head", merge], repo, deadline - time.monotonic())
        if code is None:
            say(f"the fix ran past {seconds:.0f}s and was stopped; nothing is fixed")
            return None
        edited = [p for p in git(repo, "diff", "--name-only").splitlines() if p]
        dropped = [p for p in edited if not keepable(p, changed)]
        if dropped:
            git(repo, "checkout", "-q", "--", *dropped)
            say(f"put back {len(dropped)} edit(s) outside the pull request's source files: {', '.join(dropped[:5])}")
        files = sorted(p for p in edited if keepable(p, changed))
        if not files:
            say("the lint tools had no safe fix for the pull request's files; the red is left as it is")
            return None
        patch = git(repo, "diff", "--no-color", "--", *files)
        git(repo, "-c", "user.name=fixit-lint", "-c", "user.email=fixit-lint@invalid", "commit", "-q",
            "--no-verify", "-m", "fixit-lint", "--", *files)
        fixed = git(repo, "rev-parse", "HEAD").strip()
        say(f"safe fixes in {len(files)} file(s); linting again")
        again = bounded([py, lint, "--base", base, "--head", fixed, "--new-only"], repo, deadline - time.monotonic())
        if again != 0:
            say("the second lint is still red" + (" (stopped at the bound)" if again is None else f" (exit {again})")
                + ": the fixes are dropped, the first red stands")
            return None
    finally:
        git(repo, "reset", "-q", "--hard", merge, check=False)
    out.mkdir(parents=True, exist_ok=True)
    (out / f"{NAME}.patch").write_text(patch)
    record = {"class": "mechanical", "rule": "fixit-lint.web", "fixer": FIXER, "swallow": True,
              "evidence": "every finding the web lint adds went away with its tools' own safe fixes",
              "files": files, "patch": f"{NAME}.patch", "command": f"{Path(lint).name} --fix",
              "red_at": red_at, "fixed_at": now_iso(), **ctx_fields(merge)}
    (out / f"{NAME}.json").write_text(json.dumps(record, indent=2) + "\n")
    print("CI_OOPS=" + json.dumps(record, sort_keys=True, separators=(",", ":")), flush=True)
    say(f"the second lint passed: {out / (NAME + '.patch')} ({len(files)} file(s)); the fixup commit carries it, and "
        "this check stays red")
    summary("### fixit-lint: the web lint's own safe fixes clear this pull request's findings\n\n"
            + "".join(f"- `{f}`\n" for f in files)
            + f"\nThe fixup commit is pushed to a same-repo `lane/*` branch by fixit-compile's push; elsewhere apply "
              f"artifact `{NAME}.patch` with `git apply`.")
    return record


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="command", required=True)
    run = sub.add_parser("run", help="fix a red web lint of BASE..MERGE")
    run.add_argument("--base", required=True)
    run.add_argument("--merge", required=True)
    run.add_argument("--repo", type=Path, default=Path.cwd())
    run.add_argument("--lint", default="scripts/web_lint_prepush.py")
    run.add_argument("--out", type=Path)
    run.add_argument("--seconds", type=float, default=300.0)
    args = parser.parse_args(argv)
    if not os.environ.get("FIXIT_COMPILE_HEAD_SHA") or os.environ.get("FIXIT_COMPILE", "1") == "0":
        say("off (no FIXIT_COMPILE_HEAD_SHA, or FIXIT_COMPILE=0)")
        return 0
    repo = args.repo.resolve()
    try:
        fix(repo, args.base, args.merge, args.lint, args.out or default_out(repo), args.seconds)
    except Exception as exc:  # noqa: BLE001 - best effort: the gate's red is the verdict either way
        say(f"failed ({type(exc).__name__}: {exc}); the red stands as it is")
    return 0


if __name__ == "__main__":
    sys.exit(main())
