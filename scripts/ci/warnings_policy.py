#!/usr/bin/env python3
"""Warnings never fail a pull request's compile; nightly, release and every other run keep them errors.

Leo, 2026-11-19: "can the compile somehow be able to like not fail itself or whatever? Like, is there a way for
us to do that for like the more minor incidents, like the compilation itself to like fix itself?" A warning is
the most minor of those: log it, mark it, keep going, fix it afterwards (cmuxterm-hq tools/ci-oops).

CI_WARNINGS picks the mode. A pull request workflow sets it to `soft` for `pull_request` events only:

    env:
      CI_WARNINGS: ${{ github.event_name == 'pull_request' && 'soft' || 'deny' }}

Unset, or anything but `soft` (pushes, dispatches, schedules, nightly and release builds, a local run), is
`deny`: the command runs exactly as written and warnings stay errors.

  warnings_policy.py run -- CMD...   soft: CMD without the arguments that make warnings errors (`-D warnings`,
                                     `-Dwarnings`, `--deny-warnings`, `-Xswiftc -warnings-as-errors`,
                                     `--max-warnings N`), and without them in RUSTFLAGS / RUSTDOCFLAGS. Its
                                     output passes through as it comes and the exit code is CMD's.
                                     deny: CMD as written (exec).
  warnings_policy.py mode            print the mode (soft or deny).

Kept warnings are not lost: the job stays green and says so with a `::warning title=warnings (soft)` annotation,
a job summary section with their text, and one `CI_OOPS={...}` log line (class soft, rule
soft.warnings_as_errors, fixer clippy-fix for cargo, outcome soft_failed): the ledger line cmuxterm-hq
tools/ci-oops reads to fix them afterwards (a mechanical fixer, else a follow-up). The warnings also go to
CI_WARNINGS_LOG ($RUNNER_TEMP/ci-warnings.log). No CI job or step is added for this (CLAUDE.md: no new CI jobs).

Explicit lint denies stay errors in every mode: `#![deny(...)]`, a `[lints]` level of "deny", the panic
ratchet's flags and clippy's deny-by-default correctness group are not warnings. A check that needs a
warn-level lint to block (await_holding_lock) sets it to "deny" instead of relying on `-D warnings`.
"""

from __future__ import annotations

import json
import os
import re
import subprocess
import sys
import threading
from pathlib import Path

SOFT = "soft"
# How much of the kept warnings' text goes into the job summary; all of it is in the log above it.
SUMMARY_CAP = 20_000
FLAG_ENVS = ("RUSTFLAGS", "RUSTDOCFLAGS", "CARGO_ENCODED_RUSTFLAGS")
# A diagnostic header: rustc/clippy `warning: ...` or `warning[E..]: ...`, swiftc/clang `path:1:2: warning: ...`,
# oxlint `  ⚠ plugin(rule): ...`.
# cargo's tallies ("`x` (lib) generated 3 warnings", "N warnings emitted") are not one.
WARNING = re.compile(r"^(?:warning(?:\[[\w:-]+\])?: |\S+:\d+:\d+: warning: |\s*⚠ )")
TALLY = re.compile(r"^warning: (?:.*\bgenerated \d+ warnings?\b|\d+ warnings? emitted|build failed, waiting)")


def mode(env=os.environ) -> str:
    return SOFT if env.get("CI_WARNINGS", "").strip().lower() == SOFT else "deny"


def soft_args(argv: list[str]) -> list[str]:
    """argv without the arguments that turn warnings into errors."""
    out: list[str] = []
    i = 0
    while i < len(argv):
        arg = argv[i]
        nxt = argv[i + 1] if i + 1 < len(argv) else None
        if arg in ("-D", "--deny") and nxt == "warnings":
            i += 2
            continue
        if arg in ("-Dwarnings", "--deny=warnings", "--deny-warnings", "-warnings-as-errors"):
            if out and out[-1] == "-Xswiftc":
                out.pop()
            i += 1
            continue
        if arg == "--max-warnings" and nxt is not None:
            i += 2
            continue
        if arg.startswith("--max-warnings="):
            i += 1
            continue
        out.append(arg)
        i += 1
    return out


def wrap(command: list[str], env=os.environ) -> list[str]:
    """COMMAND as a Python caller runs it: through `run` when soft, as written when deny."""
    if mode(env) != SOFT:
        return command
    return [sys.executable, str(Path(__file__).resolve()), "run", "--", *command]


def soft_env(env: dict[str, str]) -> dict[str, str]:
    env = dict(env)
    for name in FLAG_ENVS:
        if name not in env:
            continue
        if name == "CARGO_ENCODED_RUSTFLAGS":
            env[name] = "\x1f".join(soft_args(env[name].split("\x1f"))) if env[name] else ""
        else:
            env[name] = " ".join(soft_args(env[name].split()))
    return env


def warnings_in(lines) -> list[str]:
    """The warning diagnostics in `lines`, each with the lines after its header up to the next blank line
    (rustc's `-->`, the source excerpt and its notes)."""
    found: list[str] = []
    block: list[str] | None = None
    for raw in lines:
        line = raw.rstrip("\n")
        if WARNING.match(line) and not TALLY.match(line):
            if block:
                found.append("\n".join(block))
            block = [line]
        elif block is not None:
            if not line.strip() or line.startswith(("error", "warning")):
                found.append("\n".join(block))
                block = None
            else:
                block.append(line)
    if block:
        found.append("\n".join(block))
    return list(dict.fromkeys(found))


def fixer(command: list[str]) -> str | None:
    """The ci-oops fixer id for warnings of `command`: `cargo clippy --fix`, `oxlint --fix` (webviews lint:fix),
    else none (a follow-up)."""
    if any("cargo" in part for part in command[:4]):
        return "clippy-fix"
    if "oxlint" in command or command[:3] == ["bun", "run", "lint"]:
        return "oxlint-fix"
    return None


def log_path(env=os.environ) -> Path:
    if env.get("CI_WARNINGS_LOG"):
        return Path(env["CI_WARNINGS_LOG"])
    return Path(env.get("RUNNER_TEMP") or "/tmp") / "ci-warnings.log"


def keep(command: list[str], found: list[str], rc: int, env=os.environ) -> None:
    """Say what the soft run let through: the annotation, the CI_OOPS line, the summary and the log file."""
    shown = " ".join(command[:3])
    first = found[0].splitlines()[0][:200]
    print(f"::warning title=warnings (soft)::{len(found)} warning(s) from `{shown}` did not fail this pull "
          f"request's compile (CI_WARNINGS=soft). Fix them here or in a follow-up; nightly and release builds keep "
          f"them errors. First: {first}", flush=True)
    verdict = {"class": "soft", "rule": "soft.warnings_as_errors", "fixer": fixer(command), "count": len(found),
               "command": " ".join(command)[:300], "exit": rc, "outcome": "soft_failed"}
    print("CI_OOPS=" + json.dumps(verdict, sort_keys=True), flush=True)
    text = "\n\n".join(found)
    if env.get("GITHUB_STEP_SUMMARY"):
        with open(env["GITHUB_STEP_SUMMARY"], "a", encoding="utf-8") as handle:
            handle.write(f"### {len(found)} warning(s), soft: `{shown}`\n\nThey did not fail this compile. Fix them "
                         f"here or in a follow-up.\n\n```\n{text[:SUMMARY_CAP]}\n```\n")
    path = log_path(env)
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("a", encoding="utf-8") as handle:
        handle.write(f"### {' '.join(command)}\n{text}\n\n")


def run(argv: list[str]) -> int:
    if not argv:
        print("usage: warnings_policy.py run -- CMD...", file=sys.stderr)
        return 2
    if mode() != SOFT:
        os.execvp(argv[0], argv)
    command = soft_args(argv)
    print(f"warnings_policy: CI_WARNINGS=soft: warnings do not fail this pull request's compile "
          f"({len(argv) - len(command)} warnings-as-errors argument(s) dropped)", flush=True)
    # stdout stays stdout (`--message-format=json` readers) and stderr stays stderr (callers read cargo's from
    # it); both are scanned for warnings (cargo writes them to stderr, swift build to stdout).
    process = subprocess.Popen(command, env=soft_env(dict(os.environ)), stdout=subprocess.PIPE,
                               stderr=subprocess.PIPE, text=True, errors="replace")
    seen: list[str] = []

    def pump(source, sink) -> None:
        for line in source:
            sink.write(line)
            sink.flush()
            if len(seen) < 200_000:
                seen.append(line)

    readers = [threading.Thread(target=pump, args=(process.stdout, sys.stdout), daemon=True),
               threading.Thread(target=pump, args=(process.stderr, sys.stderr), daemon=True)]
    for reader in readers:
        reader.start()
    rc = process.wait()
    for reader in readers:
        reader.join()
    found = warnings_in(seen)
    if found:
        keep(command, found, rc)
    return rc


def main(argv: list[str]) -> int:
    if argv[:1] == ["run"]:
        rest = argv[1:]
        if rest[:1] == ["--"]:
            rest = rest[1:]
        return run(rest)
    if argv == ["mode"]:
        print(mode())
        return 0
    print(__doc__, file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
