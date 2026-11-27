#!/usr/bin/env python3
"""The cheap cmux-tui spec and bindings checks, on every head whose change reaches what they read.

#56203 (dd19a6ecf137, 2026-11-27) added the control event `client-disconnected-by` in server code and merged with the
spec inventory red: cmux-tui-spec.yml's `inventory` job skips a feat-cmux-next pull request without `full-ci` (run
45977048802: `changes` and `inventory` skipped), pr-pipeline.yml's linux job runs only on the full tier, and the land
ran the affected tier, so the check first ran in the post-merge batch and on the next safe-push. cmux-next-guards.yml's
`spec-checks` job runs CHECKS here on every pull request head and push into feat-cmux-next whose diff reaches INPUTS
(workflow-start-lint's route step calls `route`), about half a minute of stdlib Python on our own runners.

  spec_checks.py route                 changed paths on stdin; prints `true` when one is an input, else `false`
  spec_checks.py run [--base REV]      runs every check at once; with --base, a red check runs again on REV's tree
                                       and is the change's own only when it is green there or prints a new line
  spec_checks.py exec --trace FILE [--path DIR]... -- SCRIPT|-m MODULE [ARGS]
                                       runs one check as `python3 SCRIPT ARGS` would and lists the repository files
                                       it opened (the read audit)

The read audit: every file a check opens must be an input, or a change to that file would skip the job. A read outside
INPUTS fails the run when the change edits a Python file the checks ran (that is where a new read comes from), and is
a warning otherwise. cmux-tui-spec.yml's jobs still run all of this, plus api-compat and clippy, after the merge.
"""

from __future__ import annotations

import argparse
from concurrent.futures import ThreadPoolExecutor
from dataclasses import dataclass, field
import fnmatch
import os
from pathlib import Path
import re
import runpy
import subprocess
import sys
import tempfile
from typing import IO, Iterable, Sequence

HERE = Path(__file__).resolve().parent


@dataclass(frozen=True)
class Check:
    name: str
    # A script path (relative to the repository) and its arguments, or `-m MODULE ARGS`.
    argv: tuple[str, ...]
    # Folders put on sys.path first, as PYTHONPATH would.
    path: tuple[str, ...] = ()


# cmux-tui-spec.yml's `inventory` job, without its shell tests of the installers (minutes, not spec or bindings).
CHECKS: tuple[Check, ...] = (
    Check("spec inventory", ("cmux-tui/scripts/check-spec-inventory.py",)),
    Check("spec inventory checker tests", ("cmux-tui/scripts/test_check_spec_inventory.py",)),
    Check("frontend documentation protocol", ("cmux-tui/scripts/test_frontend_docs.py",)),
    Check("SDK schema against the runtime inventory", ("cmux-tui/scripts/check-sdk-schema.py",)),
    Check("SDK schema checker tests", ("cmux-tui/scripts/test_check_sdk_schema.py",)),
    Check("public resource API boundary", ("cmux-tui/scripts/check-resource-api-boundary.py",)),
    Check("resource boundary checker tests", ("cmux-tui/scripts/test_check_resource_api_boundary.py",)),
    Check("generated SDK wire layers", ("cmux-tui/bindings/codegen/generate.py", "--check")),
    Check("SDK generator tests", ("-m", "unittest", "discover", "-s", "cmux-tui/bindings/codegen/tests"),
          path=("cmux-tui/bindings",)),
    Check("phone lane field allowlist", ("scripts/cmux-next/gen-phone-lane-fields.py", "--check")),
)

# What CHECKS read (the read audit holds it), globs: `**` crosses folders, `*` does not. A change to none of these
# skips the job; tests/test_ci_spec_checks.py and the audit on every run keep the list whole.
INPUTS: tuple[str, ...] = (
    "cmux-tui/spec/**",
    "cmux-tui/bindings/**",
    "cmux-tui/docs/**",
    "cmux-tui/scripts/*spec_inventory*.py",
    "cmux-tui/scripts/check-spec-inventory.py",
    "cmux-tui/scripts/*sdk_schema*.py",
    "cmux-tui/scripts/check-sdk-schema.py",
    "cmux-tui/scripts/*resource_api_boundary*.py",
    "cmux-tui/scripts/check-resource-api-boundary.py",
    "cmux-tui/scripts/test_frontend_docs.py",
    # test_frontend_docs.py: the frontends' protocol notes and the web client's protocol module.
    "cmux-tui/frontends/README*.md",
    "cmux-tui/frontends/web/README*.md",
    "cmux-tui/frontends/web/src/lib/protocol.ts",
    # The server (server.rs and server/, its events and commands), the mux, the resource layer and the TUI's
    # action catalog and CLI: what the inventory and the boundary check parse.
    "cmux-tui/crates/cmux-tui-core/src/**",
    "cmux-tui/crates/cmux-tui/src/**",
    "cmux-tui/crates/cmux-daemon-launch-core/src/**",
    "cmux-tui/crates/cmux-terminal-host-protocol/src/**",
    "cmux-tui/crates/cmux-tui-cloud-conversations/src/**",
    "cmux-tui/crates/cmux-tui-machine-protocol/src/**",
    "cmux-tui/crates/cmux-tui-machine-agent-protocol/src/**",
    # The Swift clients of the daemon protocol the boundary check reads, and the phone lane allowlist.
    "Packages/macOS/CmuxNext/Sources/CmuxNextDaemon/**",
    "Packages/macOS/CmuxNext/Sources/CmuxNextMobile/DaemonLane/**",
    "webviews/src/pages/shared/generated/pageRouter.ts",
    "scripts/cmux-next/gen-phone-lane-fields.py",
    # This job.
    "scripts/ci/spec_checks.py",
    "tests/test_ci_spec_checks.py",
    ".github/workflows/cmux-next-guards.yml",
)

TIMEOUT_SECONDS = 600


def _pattern(glob: str) -> re.Pattern[str]:
    return re.compile("".join(".*" if part == "**" else "[^/]*" if part == "*" else re.escape(part)
                              for part in re.split(r"(\*\*|\*)", glob)))


_INPUTS = tuple(_pattern(glob) for glob in INPUTS)


def is_input(path: str, inputs: Sequence[re.Pattern[str]] = _INPUTS) -> bool:
    return any(pattern.fullmatch(path) for pattern in inputs)


def routed(paths: Iterable[str]) -> bool:
    """Whether a change to PATHS can change a check's verdict."""
    return any(is_input(path) for path in paths)


@dataclass
class Result:
    rc: int
    output: str
    reads: list[str] = field(default_factory=list)


def run_one(repo: Path, check: Check, audit: bool) -> Result:
    with tempfile.TemporaryDirectory() as tmp:
        trace = Path(tmp) / "reads.txt"
        command = [sys.executable, "-I", str(Path(__file__).resolve()), "exec", "--trace", str(trace)]
        for folder in check.path:
            command += ["--path", folder]
        command += ["--", *check.argv]
        try:
            done = subprocess.run(command, cwd=repo, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                                  stderr=subprocess.STDOUT, text=True, timeout=TIMEOUT_SECONDS, check=False)
            rc, output = done.returncode, done.stdout
        except subprocess.TimeoutExpired as stopped:
            text = stopped.stdout.decode(errors="replace") if isinstance(stopped.stdout, bytes) else stopped.stdout
            rc, output = 124, (text or "") + f"\nstopped after {TIMEOUT_SECONDS} s\n"
        reads = trace.read_text().splitlines() if audit and trace.exists() else []
    return Result(rc, output, reads)


def run_all(repo: Path, checks: Sequence[Check], audit: bool) -> dict[str, Result]:
    with ThreadPoolExecutor(max_workers=max(1, min(len(checks), os.cpu_count() or 2))) as pool:
        futures = {check.name: pool.submit(run_one, repo, check, audit) for check in checks}
        return {name: future.result() for name, future in futures.items()}


def _git(repo: Path, *args: str) -> subprocess.CompletedProcess[str]:
    return subprocess.run(["git", "-C", str(repo), *args], capture_output=True, text=True, check=False)


def _restore(repo: Path, rev: str) -> None:
    """The tracked tree at REV in the index and the work tree (files REV lacks are removed)."""
    done = _git(repo, "restore", f"--source={rev}", "--staged", "--worktree", "--", ".")
    if done.returncode:
        raise RuntimeError(f"git restore --source={rev} failed: {done.stderr.strip()}")


def _normal(line: str) -> str:
    return re.sub(r"\d+(?:\.\d+)?", "N", line.strip())


def new_lines(change: str, base: str) -> list[str]:
    """CHANGE's output lines the base run did not print (numbers aside: timings, line numbers, counts)."""
    seen = {_normal(line) for line in base.splitlines()}
    return [line for line in change.splitlines() if line.strip() and _normal(line) not in seen]


def _script_of(check: Check) -> str | None:
    return None if check.argv[0] == "-m" else check.argv[0]


def judge(repo: Path, checks: Sequence[Check], base: str | None, stream: IO[str] = sys.stdout, audit: bool = True,
          changed: Sequence[str] | None = None) -> int:
    """Runs CHECKS in REPO; 0 when none is red on the change's own account. BASE: a red check runs again on that
    revision's tree, and is excused when it is red there too with no line of its own. CHANGED: the change's paths,
    for the read audit (None: a read outside INPUTS only warns)."""
    github = os.environ.get("GITHUB_ACTIONS") == "true"

    def say(text: str = "") -> None:
        print(text, file=stream, flush=True)

    results = run_all(repo, checks, audit)
    for check in checks:
        result = results[check.name]
        verdict = "ok" if result.rc == 0 else f"red (exit {result.rc})"
        say(f"::group::{check.name}: {verdict}" if github else f"== {check.name}: {verdict}")
        say(result.output.rstrip())
        if github:
            say("::endgroup::")
    red = [check for check in checks if results[check.name].rc != 0]
    own: list[tuple[Check, str]] = []
    if red and base:
        base_sha = _git(repo, "rev-parse", "--verify", "--quiet", f"{base}^{{commit}}").stdout.strip()
        if not base_sha:
            say(f"{base} is not in this checkout: every red check is judged on the change alone")
            own = [(check, "no base to compare with") for check in red]
        else:
            head_sha = _git(repo, "rev-parse", "--verify", "HEAD^{commit}").stdout.strip()
            _restore(repo, base_sha)
            try:
                present = [check for check in red if _script_of(check) is None or (repo / _script_of(check)).is_file()]
                again = run_all(repo, present, audit=False)
            finally:
                _restore(repo, head_sha)
            for check in red:
                then = again.get(check.name)
                if then is None:
                    own.append((check, f"the base ({base_sha[:12]}) has no {_script_of(check)}"))
                elif then.rc == 0:
                    own.append((check, f"green on the base ({base_sha[:12]})"))
                elif fresh := new_lines(results[check.name].output, then.output):
                    own.append((check, f"red on the base ({base_sha[:12]}) too, but these lines are new:\n  "
                                + "\n  ".join(fresh[:40])))
                else:
                    say(f"::warning title={check.name}::red on the base ({base_sha[:12]}) as well, with the same "
                        f"output: not this change's (fix it on feat-cmux-next)")
    else:
        own = [(check, "red") for check in red]

    failed = False
    for check, why in own:
        failed = True
        say(f"::error title={check.name}::this change's own red: {why}")
        say(f"  run it: {' '.join(['python3', *check.argv])}")

    reads = sorted({path for result in results.values() for path in result.reads})
    outside = [path for path in reads if not is_input(path) and "__pycache__" not in path.split("/")
               and not path.startswith(".git/")]
    if outside:
        ran_code = {path for path in reads if path.endswith(".py")}
        edits_code = bool(changed) and bool(ran_code & set(changed))
        level = "error" if edits_code else "warning"
        failed = failed or edits_code
        say(f"::{level} title=spec checks read audit::the checks read {len(outside)} file(s) outside "
            f"scripts/ci/spec_checks.py INPUTS, so a change to one of them would skip this job; add them there:")
        for path in outside:
            say(f"  {path}")
    say(f"spec checks: {len(checks)} run, {len(red)} red, {len(own)} the change's own"
        + (f", {len(outside)} read(s) outside INPUTS" if outside else ""))
    return 1 if failed else 0


def exec_check(trace: str | None, folders: Sequence[str], argv: Sequence[str]) -> None:
    """Runs one check in this process as `python3 SCRIPT ARGS` (or `python3 -m MODULE ARGS`) would, and writes the
    repository files it opened to TRACE."""
    root = os.path.realpath(os.getcwd())
    seen: set[str] = set()

    def hook(event: str, args: tuple) -> None:
        if event != "open" or not args or isinstance(args[0], int):
            return
        try:
            path = os.path.realpath(os.fsdecode(args[0]))
        except (TypeError, ValueError):
            return
        if path.startswith(root + os.sep) and os.path.isfile(path):
            seen.add(os.path.relpath(path, root))

    # As `python3 SCRIPT`: the script's folder first, never this one's.
    sys.path[:] = [entry for entry in sys.path if os.path.realpath(entry or ".") != str(HERE)]
    for folder in reversed(folders):
        sys.path.insert(0, os.path.join(root, folder))
    sys.addaudithook(hook)
    code: object = 0
    try:
        if argv[0] == "-m":
            sys.argv = [argv[1], *argv[2:]]
            runpy.run_module(argv[1], run_name="__main__", alter_sys=True)
        else:
            script = os.path.join(root, argv[0])
            sys.path.insert(0, os.path.dirname(script))
            sys.argv = [argv[0], *argv[1:]]
            runpy.run_path(script, run_name="__main__")
    except SystemExit as stop:
        code = stop.code
    finally:
        if trace:
            Path(trace).write_text("".join(f"{path}\n" for path in sorted(seen)))
    sys.exit(code)


def main(argv: Sequence[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    sub = parser.add_subparsers(dest="command", required=True)
    sub.add_parser("route", help="changed paths on stdin; prints true or false")
    run = sub.add_parser("run", help="run every check")
    run.add_argument("--base", help="a red check runs again on this revision's tree")
    run.add_argument("--no-audit", action="store_true")
    run_exec = sub.add_parser("exec", help="run one check, tracing what it opens")
    run_exec.add_argument("--trace")
    run_exec.add_argument("--path", action="append", default=[])
    run_exec.add_argument("argv", nargs=argparse.REMAINDER)
    args = parser.parse_args(argv)
    if args.command == "route":
        print("true" if routed(line.strip() for line in sys.stdin if line.strip()) else "false")
        return 0
    if args.command == "exec":
        rest = args.argv[1:] if args.argv[:1] == ["--"] else args.argv
        if not rest:
            parser.error("exec needs a script or -m MODULE")
        exec_check(args.trace, args.path, rest)
        return 0
    repo = Path(_git(Path.cwd(), "rev-parse", "--show-toplevel").stdout.strip() or ".")
    changed = None
    if args.base:
        diff = _git(repo, "diff", "--no-renames", "--name-only", args.base, "HEAD")
        changed = diff.stdout.splitlines() if diff.returncode == 0 else None
    return judge(repo, CHECKS, args.base, audit=not args.no_audit, changed=changed)


if __name__ == "__main__":
    sys.exit(main())
