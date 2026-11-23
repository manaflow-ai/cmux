#!/usr/bin/env python3
"""ci-oops fault isolation: a pull request's build drops an optional unit that alone fails to compile.

    isolate.py run --kind KIND [--dropped-out FILE] -- CMD...   run CMD; on a red that only optional units of KIND
                                                               cause, run it again without them (see below)
    isolate.py allowed                                          print whether this run may drop units, and why
    isolate.py check                                            validate optional-units.json (exit 1 on a problem)

Leo, 2026-11-19: "Can we do things where it's like, like the CI doesn't necessarily have to fail and like give up.
It can just be like, okay, you got to fix this afterwards or whatever, just as if it were like a follow-up". A kernel
oops, not a panic: an optional webview page, the gallery or an optional cargo member that does not compile is left
out of this pull request's build, the rest builds and runs, and the job prints one `CI_OOPS={json}` line per dropped
unit (class soft, outcome soft_failed) that the ci-oops follow-up actor (cmuxterm-hq tools/ci-oops act_softfail)
files. Everything optional-units.json does not list is core and stays red.

Only a pull_request event drops anything (allowed()): a push, a schedule or a dispatch, any workflow or base whose
name is a ship path (nightly, release, promote, stable, publish) and CMUX_OOPS_STRICT=1 run the command as it is.

How a red is attributed (attribute()): webview-page reads the paths of esbuild's `[ERROR]` blocks
(src/pages/<page>/...), cargo-member reads cargo's `could not compile `NAME`` lines. Every attributed unit must be
optional, else nothing is dropped. The second run is the proof: a unit that something core still needs fails it
again, and the step stays red. Dropping: webview-page removes the page's name from CMD's arguments, cargo-member
adds `--exclude NAME`.

Callers that judge findings themselves (the webviews type check, scripts/ci/fast_gate_webviews_checks.py) use
unit_of_path() and report() from Python. Test: tests/test_ci_oops_isolate.py.
"""
from __future__ import annotations

import argparse
import fnmatch
import json
import os
import re
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
UNITS = HERE / "optional-units.json"
KINDS = ("webview-page", "gallery", "cargo-member")
# A workflow, ref or base with one of these words is a ship path: it compiles everything strictly.
SHIP = re.compile(r"nightly|release|promote|stable|publish|notariz|appcast|dogfood-artifact", re.I)
MAX_ROUNDS = 3

ANSI = re.compile(r"\x1b\[[0-9;]*m")
ESBUILD_ERROR = re.compile(r"\[ERROR\]")
ESBUILD_OTHER = re.compile(r"\[(?:WARNING|INFO|DEBUG)\]")
SOURCE_PATH = re.compile(r"(?:^|[\s\"'(\[])((?:\.{1,2}/)*(?:webviews/)?src/[\w./@+-]+\.(?:tsx?|jsx?|mjs|css|json))\b")
CARGO_RED = re.compile(r"(?:error|warning): could not compile `(?P<name>[\w-]+)`")


def load(path: Path = UNITS) -> list[dict]:
    return json.loads(path.read_text(encoding="utf-8"))["units"]


def problems(units: list[dict]) -> list[str]:
    """What is wrong with the allowlist: every unit needs a known kind, a name, paths and a reason."""
    out, seen = [], set()
    for unit in units:
        uid = unit.get("id", "?")
        if unit.get("kind") not in KINDS:
            out.append(f"{uid}: kind must be one of {', '.join(KINDS)}")
        if not unit.get("name") or not unit.get("paths"):
            out.append(f"{uid}: needs a name and paths")
        if len(unit.get("why", "")) < 30:
            out.append(f"{uid}: `why` must say why the product builds and runs without it")
        if uid != f"{unit.get('kind')}:{unit.get('name')}" and uid != unit.get("kind"):
            out.append(f"{uid}: id must be KIND:NAME (or KIND for a one-unit kind)")
        if uid in seen:
            out.append(f"{uid}: listed twice")
        seen.add(uid)
    return out


def allowed(env: dict | None = None) -> tuple[bool, str]:
    """(may this run drop units, why). Only a pull request build of a non-ship workflow into a non-ship base."""
    env = os.environ if env is None else env
    if env.get("CMUX_OOPS_STRICT") == "1":
        return False, "CMUX_OOPS_STRICT=1"
    if env.get("GITHUB_ACTIONS") != "true":
        return False, "not a GitHub Actions run (local builds stay strict)"
    if env.get("GITHUB_EVENT_NAME") != "pull_request":
        return False, f"event {env.get('GITHUB_EVENT_NAME') or 'unknown'} is not pull_request"
    for name in ("GITHUB_WORKFLOW", "GITHUB_WORKFLOW_REF", "GITHUB_BASE_REF", "GITHUB_HEAD_REF"):
        if SHIP.search(env.get(name, "")):
            return False, f"{name}={env.get(name)} is a ship path"
    return True, "pull_request build"


def _match(path: str, pattern: str) -> bool:
    if pattern.endswith("/**"):
        return path.startswith(pattern[:-2])
    if "/**/" in pattern:
        head, tail = pattern.split("/**/", 1)
        return path.startswith(head + "/") and fnmatch.fnmatch(path.rsplit("/", 1)[-1], tail)
    return fnmatch.fnmatch(path, pattern)


def unit_of_path(path: str, kinds: tuple[str, ...] = KINDS, units: list[dict] | None = None) -> dict | None:
    """The optional unit a repository-relative path belongs to (a gallery file inside a page is the gallery's),
    or None for core."""
    path = path.replace("\\", "/")
    while path.startswith("./"):
        path = path[2:]
    hits = [u for u in (load() if units is None else units)
            if u["kind"] in kinds and any(_match(path, p) for p in u["paths"])]
    hits.sort(key=lambda u: u["kind"] != "gallery")
    return hits[0] if hits else None


def webview_path(path: str) -> str:
    """A path as esbuild or the type check prints it (relative to webviews/) as a repository path."""
    path = path.replace("\\", "/")
    if "/webviews/src/" in path:  # an absolute path in a checkout
        path = path[path.rindex("/webviews/src/") + 1:]
    while path.startswith("./") or path.startswith("../"):
        path = path.split("/", 1)[1]
    return path if path.startswith("webviews/") else f"webviews/{path}"


def attribute(kind: str, text: str, units: list[dict] | None = None) -> tuple[set[str], list[str]]:
    """(the optional unit names the red names, the core evidence lines). Nothing is dropped unless the first is
    non-empty and the second empty."""
    units = load() if units is None else units
    names, core = set(), []
    lines = ANSI.sub("", text).splitlines()
    if kind == "webview-page":
        in_error, any_error = False, False
        for line in lines:
            if ESBUILD_ERROR.search(line):
                in_error = any_error = True
            elif ESBUILD_OTHER.search(line):
                in_error = False
            if not in_error:
                continue
            for raw in SOURCE_PATH.findall(line):
                unit = unit_of_path(webview_path(raw), ("webview-page",), units)
                if unit:
                    names.add(unit["name"])
                else:
                    core.append(line.strip())
        if not any_error:
            core.append("no esbuild [ERROR] block to attribute")
    elif kind == "cargo-member":
        optional = {u["name"] for u in units if u["kind"] == "cargo-member"}
        for line in lines:
            if found := CARGO_RED.search(line):
                (names.add(found["name"]) if found["name"] in optional else core.append(line.strip()))
        if not names and not core:
            core.append("no `could not compile` line to attribute")
    else:
        raise ValueError(f"run --kind {kind}: attribute only webview-page or cargo-member")
    return names, core


def evidence(kind: str, name: str, text: str) -> str:
    """The first error line that names the unit, for the follow-up."""
    lines = ANSI.sub("", text).splitlines()
    needle = f"`{name}`" if kind == "cargo-member" else f"src/pages/{name}/"
    for i, line in enumerate(lines):
        if needle in line:
            before = next((lines[j].strip() for j in range(i, max(-1, i - 6), -1)
                           if "[ERROR]" in lines[j] or lines[j].lstrip().startswith("error")), "")
            return (before + " | " if before and before != line.strip() else "") + line.strip()
    return ""


def without(kind: str, argv: list[str], dropped: list[str]) -> list[str] | None:
    """argv with the dropped units left out, or None when nothing is left to build.
    webview-page: the page names go. cargo-member: `-p NAME` goes; a `--workspace` (or a command that names no
    package, such as a wrapper script) gets `--exclude NAME`, before cargo's own `--` when it has one."""
    if kind == "webview-page":
        return [arg for arg in argv if arg not in dropped]
    if "-p" in argv and "--workspace" not in argv:
        out, skip = [], False
        for i, arg in enumerate(argv):
            if skip:
                skip = False
                continue
            if arg == "-p" and i + 1 < len(argv) and argv[i + 1] in dropped:
                skip = True
                continue
            out.append(arg)
        return out if "-p" in out else None
    excludes = [part for name in dropped for part in ("--exclude", name)]
    cut = argv.index("--") if "--" in argv else len(argv)
    return [*argv[:cut], *excludes, *argv[cut:]]


def dropped_from_env(kind: str, env: dict | None = None) -> list[str]:
    """The units an earlier step of this job left out (report()'s CMUX_OOPS_DROPPED_<KIND>), when this run may
    leave them out too; a name that is not an optional unit of KIND is never honoured."""
    env = os.environ if env is None else env
    names = env.get("CMUX_OOPS_DROPPED_" + kind.upper().replace("-", "_"), "").split()
    return names if names and check_drop(kind, names, env) is None else []


def run_once(argv: list[str]) -> tuple[int, str]:
    """Run argv with its output passed through as it comes, and return its exit code and output."""
    process = subprocess.Popen(argv, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, errors="replace")
    assert process.stdout is not None
    seen = []
    for line in process.stdout:
        sys.stdout.write(line)
        seen.append(line)
    sys.stdout.flush()
    return process.wait(), "".join(seen)


def report(kind: str, dropped: dict[str, str], step: str = "", env: dict | None = None) -> None:
    """One CI_OOPS line, one warning and one job summary row per dropped unit; the names also go to GITHUB_ENV
    (CMUX_OOPS_DROPPED_<KIND>) so a later step of the job can leave the same units out."""
    env = os.environ if env is None else env
    units = {u["name"]: u for u in load() if u["kind"] == kind}
    rows = []
    for name, proof in dropped.items():
        unit = units.get(name, {"id": f"{kind}:{name}", "why": ""})
        line = {
            "class": "soft", "rule": f"isolate.{kind}", "outcome": "soft_failed", "swallow": True,
            "unit": unit["id"], "kind": kind, "name": name, "step": step, "evidence": proof[:400],
            "follow_up": f"{unit['id']} does not compile on this pull request and was left out of its build; "
                         f"fix it in a follow-up (scripts/ci/oops/optional-units.json: {unit.get('why', '')})",
            "repo": env.get("GITHUB_REPOSITORY", ""), "run_id": env.get("GITHUB_RUN_ID", ""),
            "run_attempt": env.get("GITHUB_RUN_ATTEMPT", ""), "job": env.get("GITHUB_JOB", ""),
            "workflow": env.get("GITHUB_WORKFLOW", ""), "head_ref": env.get("GITHUB_HEAD_REF", ""),
            "base_ref": env.get("GITHUB_BASE_REF", ""),
        }
        print(f"CI_OOPS={json.dumps(line, sort_keys=True)}", flush=True)
        print(f"::warning title=ci-oops: {unit['id']} left out of this build::it does not compile on this pull "
              f"request, so this build skipped it and went on; fix it in a follow-up. {proof[:200]}", flush=True)
        rows.append(f"| `{unit['id']}` | {step or kind} | {proof[:160].replace('|', '/')} |")
    if summary := env.get("GITHUB_STEP_SUMMARY"):
        with open(summary, "a", encoding="utf-8") as out:
            out.write("### ci-oops: optional units left out of this build\n\n| unit | step | first error |\n"
                      "| --- | --- | --- |\n" + "\n".join(rows) + "\n\nThe rest built. Each unit needs a follow-up fix "
                      "(scripts/ci/oops/optional-units.json).\n\n")
    if path := env.get("GITHUB_ENV"):
        var = "CMUX_OOPS_DROPPED_" + kind.upper().replace("-", "_")
        names = sorted(set(env.get(var, "").split()) | set(dropped))
        with open(path, "a", encoding="utf-8") as out:
            out.write(f"{var}={' '.join(names)}\n")


def isolated_run(kind: str, argv: list[str], env: dict | None = None,
                 runner=run_once, first: tuple[int, str] | None = None) -> tuple[int, list[str]]:
    """Run argv (or take FIRST, the exit code and output of a run the caller made); drop the optional units a
    red alone names and run again, at most MAX_ROUNDS times. Returns (exit code, the dropped unit names).
    The units are reported only when the last run passes."""
    code, out = first if first is not None else runner(argv)
    may, why = allowed(env)
    if code == 0 or not may:
        if code and not may:
            print(f"ci-oops isolate: not dropping anything ({why})", flush=True)
        return code, []
    dropped: dict[str, str] = {}
    for _ in range(MAX_ROUNDS):
        names, core = attribute(kind, out)
        if core or not names or names & set(dropped):
            why = (f"core reds: {core[0][:200]}" if core else
                   "no optional unit to blame" if not names else "a dropped unit is still red")
            print(f"ci-oops isolate: stays red, {why}", flush=True)
            return code, []
        for name in sorted(names):
            dropped[name] = evidence(kind, name, out)
        print(f"ci-oops isolate: {', '.join(sorted(names))} alone {'fails' if len(names) == 1 else 'fail'} to compile; building again without "
              f"{'them' if len(names) > 1 else 'it'}", flush=True)
        rest = without(kind, argv, list(dropped))
        if rest is None:
            print("ci-oops isolate: nothing else to build", flush=True)
            report(kind, dropped, env=env)
            return 0, list(dropped)
        code, out = runner(rest)
        if code == 0:
            report(kind, dropped, env=env)
            return 0, list(dropped)
    print("ci-oops isolate: still red after dropping " + ", ".join(dropped), flush=True)
    return code, []


def check_drop(kind: str, names: list[str], env: dict | None = None) -> str | None:
    """Why NAMES may not be left out of this run (not allowed here, or not optional), or None."""
    may, why = allowed(env)
    if not may:
        return why
    optional = {u["name"] for u in load() if u["kind"] == kind}
    core = [name for name in names if name not in optional]
    return f"{', '.join(core)} {'is' if len(core) == 1 else 'are'} not optional {kind} units" if core else None


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    sub = parser.add_subparsers(dest="command", required=True)
    run = sub.add_parser("run")
    run.add_argument("--kind", required=True, choices=("webview-page", "cargo-member"))
    run.add_argument("--dropped-out", type=Path, help="write the dropped unit names here, one a line")
    run.add_argument("cmd", nargs=argparse.REMAINDER)
    sub.add_parser("allowed")
    sub.add_parser("check")
    args = parser.parse_args(argv)
    if args.command == "allowed":
        may, why = allowed()
        print(f"{'allowed' if may else 'strict'}: {why}")
        return 0
    if args.command == "check":
        found = problems(load())
        for line in found:
            print(f"optional-units.json: {line}")
        return 1 if found else 0
    cmd = args.cmd[1:] if args.cmd[:1] == ["--"] else args.cmd
    if not cmd:
        parser.error("run needs a command after --")
    code, dropped = isolated_run(args.kind, cmd)
    if args.dropped_out:
        args.dropped_out.write_text("".join(f"{name}\n" for name in dropped), encoding="utf-8")
    return code


if __name__ == "__main__":
    sys.exit(main())
