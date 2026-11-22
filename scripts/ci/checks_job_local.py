#!/usr/bin/env python3
"""Run the "cmux-next checks" job's quick static steps here, before a push, and name only the reds the change adds.

Why: in the 14 days to 2026-11-21 the checks job (.github/workflows/cmux-next.yml, job `checks`) was the red job in
187 of 210 red pull request status sections sampled, and about 40 of its 67 steps run nowhere before CI: the pre-push
gate (scripts/cmux-next/prepush-gate.py) covers the line scanners only. Each red costs a full job (p50 about 16 min on
a runner) and a round trip. Examples this replays: cmux#38366 and cmux#38344 (Web bundle key inputs: an import that
resolves to no file), cmux#38262 (Default cursor: a pointing hand in app UI).

How: the step list is read from the workflow itself, so a step added there is picked up here with no edit. A step
runs when its whole body is one or two plain commands (no runner-only tool, no network, no secrets) or it is one of
the background sections listed in QUICK_SECTIONS; everything else is listed as skipped with its reason
(`--list`). Steps run in parallel, each bounded by --timeout. A red step is run once more on the base (the merge base
with origin/feat-cmux-next, in a throwaway `git worktree`): red on both is base debt and only warns; red on the
head alone is the change's own and fails (exit 1). A step that times out or cannot run here is reported, never
counted as red or green.

  python3 scripts/ci/checks_job_local.py                 run the quick steps on HEAD
  python3 scripts/ci/checks_job_local.py --list          the plan: runnable steps and skipped ones with why
  python3 scripts/ci/checks_job_local.py --only web-bundle-key-inputs,default-cursor
  python3 scripts/ci/checks_job_local.py --base REV      judge against REV instead of the merge base

Advisory: nothing calls it on its own. GUARD_OVERRIDE="why" or ~/.config/agent-guards/off makes it exit 0 at once.
It never edits a file (no --fix: every check here judges a source rule, and the fix is the author's call).
"""
from __future__ import annotations

import argparse
import concurrent.futures as cf
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time
from pathlib import Path

WORKFLOW = ".github/workflows/cmux-next.yml"
JOB = "checks"
BASE_REF = "origin/feat-cmux-next"

# Background sections (run-checks-concurrently.sh) quick enough to run here, measured on a 8-core lane VM
# 2026-11-22: web-bundle-key-inputs 9 s, package-dependency-lists 9 s, overlay-glass 25 s, no-process-scan 49 s.
# The rest (script-tests, checks-structure, tier-routing) are test suites of 2-15 minutes: cmux-ci test runs them.
QUICK_SECTIONS = ("web-bundle-key-inputs", "overlay-glass", "no-process-scan", "state-roots")

# Steps that cannot run on a lane VM or are covered elsewhere, with why. A step not named here and not plain is
# skipped as "not a plain command" so a new complex step never runs here by surprise.
SKIP = {
    "app-size": "needs a built app (full-ci cadence)",
    "crash-safety": "full-ci cadence; the pre-push gate ratchets crash safety",
    "pushed-commits": "is the pre-push gate itself",
    "ghostty-resources-bundle": "fetches a submodule",
    "app-ffi-pin": "reads release artifacts over the network",
    "routing-replay": "reads GitHub (GH_TOKEN)",
    "script-tests": "a 15-minute suite: cmux-ci test",
    "checks-structure": "a 5-minute suite: cmux-ci test",
    "tier-routing": "a 4-minute suite: cmux-ci test",
    "companion-workflows": "a test suite: cmux-ci test",
}

PLAIN = re.compile(r"^[A-Za-z0-9_./-]+( |$)")
SHELL_ONLY = re.compile(r"[|;&`$()<>]")


def git(root: Path, *args: str) -> str:
    return subprocess.run(["git", "-C", str(root), *args], check=True, capture_output=True, text=True).stdout.strip()


def load_steps(root: Path, workflow: str = WORKFLOW) -> list[dict]:
    import yaml  # PyYAML: the checks job's own "Prepare check Python" installs it; guards-local.sh's venv has it

    data = yaml.safe_load((root / workflow).read_text())
    return list(data["jobs"][JOB]["steps"])


def background_sections(steps: list[dict]) -> dict[str, list[str]]:
    """The `[section]` command lists of the step that starts the background checks."""
    out: dict[str, list[str]] = {}
    for step in steps:
        body = step.get("run") or ""
        if "run-checks-concurrently.sh --start" not in body:
            continue
        inner = body.split("<<'CHECKS'", 1)[1].split("\n", 1)[1]
        section = None
        for line in inner.splitlines():
            line = line.strip()
            if line == "CHECKS":
                break
            if not line or line.startswith("#"):
                continue
            m = re.fullmatch(r"\[(.+)\]", line)
            if m:
                section = m.group(1)
                out.setdefault(section, [])
            elif section:
                out[section].append(line)
    return out


def body_lines(body: str) -> list[str]:
    return [line.strip() for line in body.splitlines() if line.strip() and not line.strip().startswith("#")]


def base_compare(lines: list[str]) -> list[str] | None:
    """The `base=(); [[ pull_request ]] && base=(--base HEAD^1); CMD ${base...}` shape, as one command with --base."""
    if len(lines) != 3 or lines[0] != "base=()" or "base=(--base HEAD^1)" not in lines[1]:
        return None
    cmd = lines[2].replace(' ${base[@]+"${base[@]}"}', " --base {BASE}")
    return [cmd] if "{BASE}" in cmd and not SHELL_ONLY.search(cmd.replace("$GITHUB_WORKSPACE", "")
                                                              .replace("{BASE}", "")) else None


def plan(steps: list[dict]) -> tuple[list[tuple[str, str, list[str]]], list[tuple[str, str, str]]]:
    """(id, name, commands) to run and (id, name, why) skipped, in workflow order."""
    sections = background_sections(steps)
    run: list[tuple[str, str, list[str]]] = []
    skipped: list[tuple[str, str, str]] = []
    for step in steps:
        sid, name, body = step.get("id"), step.get("name", ""), step.get("run") or ""
        if not sid:
            continue
        if sid in SKIP:
            skipped.append((sid, name, SKIP[sid]))
            continue
        m = re.search(r"run-checks-concurrently\.sh --wait \S+ (\S+)", body)
        if m:
            section = m.group(1)
            if section in QUICK_SECTIONS and sections.get(section):
                run.append((sid, name, sections[section]))
            else:
                skipped.append((sid, name, SKIP.get(section, f"background section {section}: not in QUICK_SECTIONS")))
            continue
        lines = body_lines(body)
        cmds = base_compare(lines)
        if cmds is None and 1 <= len(lines) <= 2 and all(
                PLAIN.match(c) and not SHELL_ONLY.search(c.replace('"$GITHUB_WORKSPACE', '"').replace("&&", ""))
                for c in lines):
            cmds = lines
        if cmds is None:
            skipped.append((sid, name, "not a plain command (runner-only setup or a cadence switch)"))
            continue
        run.append((sid, name, cmds))
    return run, skipped


def run_step(root: Path, commands: list[str], base: str, timeout: float) -> tuple[str, float, str]:
    """('green'|'red'|'timeout', seconds, last output) for one step's commands in `root`."""
    start = time.monotonic()
    with tempfile.TemporaryDirectory(prefix="checks-local-") as tmp:
        env = dict(os.environ, GITHUB_WORKSPACE=str(root), RUNNER_TEMP=tmp, EVENT_NAME="pull_request",
                   GITHUB_STEP_SUMMARY=os.path.join(tmp, "summary"))
        for cmd in commands:
            try:
                p = subprocess.run(["bash", "-c", cmd.replace("{BASE}", base)], cwd=root, env=env, text=True,
                                   capture_output=True, timeout=max(1.0, timeout - (time.monotonic() - start)))
            except subprocess.TimeoutExpired:
                return "timeout", time.monotonic() - start, ""
            if p.returncode != 0:
                return "red", time.monotonic() - start, (p.stdout + p.stderr)[-2000:]
    return "green", time.monotonic() - start, ""


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n", 1)[0])
    ap.add_argument("--root", type=Path, default=Path(__file__).resolve().parents[2])
    ap.add_argument("--base", help=f"base revision (default: merge base of HEAD with {BASE_REF})")
    ap.add_argument("--only", help="comma-separated step ids")
    ap.add_argument("--list", action="store_true")
    ap.add_argument("--timeout", type=float, default=120.0, help="seconds per step (default 120)")
    ap.add_argument("--jobs", type=int, default=os.cpu_count() or 4)
    args = ap.parse_args(argv)

    if os.environ.get("GUARD_OVERRIDE") or (Path.home() / ".config/agent-guards/off").exists():
        print(f"checks-local: skipped ({os.environ.get('GUARD_OVERRIDE') or '~/.config/agent-guards/off'})")
        return 0
    root = args.root.resolve()
    todo, skipped = plan(load_steps(root))
    if args.only:
        wanted = set(args.only.split(","))
        unknown = wanted - {s[0] for s in todo} - {s[0] for s in skipped}
        if unknown:
            print(f"checks-local: no checks-job step with id {', '.join(sorted(unknown))}", file=sys.stderr)
            return 2
        todo = [s for s in todo if s[0] in wanted]
    if args.list:
        for sid, name, cmds in todo:
            print(f"run   {sid:28} {name[:60]}  ({len(cmds)} command{'s' if len(cmds) > 1 else ''})")
        for sid, name, why in skipped:
            print(f"skip  {sid:28} {name[:60]}  ({why})")
        return 0

    base = args.base or git(root, "merge-base", "HEAD", BASE_REF)
    started = time.monotonic()
    with cf.ThreadPoolExecutor(max(1, args.jobs)) as pool:
        results = list(pool.map(lambda s: (s, *run_step(root, s[2], base, args.timeout)), todo))
    red = [(s, out) for s, verdict, _, out in results if verdict == "red"]
    for (sid, name, _), verdict, seconds, _ in results:
        if verdict == "timeout":
            print(f"checks-local: {name}: no verdict, over {args.timeout:.0f}s here (CI still runs it)")

    own: list[tuple[tuple[str, str, list[str]], str]] = []
    if red:
        work = Path(tempfile.mkdtemp(prefix="checks-local-base-"))
        tree = work / "tree"
        try:
            subprocess.run(["git", "-C", str(root), "worktree", "add", "--detach", "--quiet", str(tree), base],
                           check=True, capture_output=True)
            with cf.ThreadPoolExecutor(max(1, args.jobs)) as pool:
                again = list(pool.map(lambda r: run_step(tree, r[0][2], base, args.timeout)[0], red))
        finally:
            subprocess.run(["git", "-C", str(root), "worktree", "remove", "--force", str(tree)], capture_output=True)
            shutil.rmtree(work, ignore_errors=True)
        for (step, out), verdict in zip(red, again):
            if verdict == "red":
                print(f"checks-local: {step[1]}: red on the base too ({base[:12]}): base debt, not this change's")
            else:
                own.append((step, out))
    took = time.monotonic() - started
    for (sid, name, _), out in own:
        print(f"red check: {name}  [{sid}]\n{out.rstrip()}\n")
    print(f"checks-local: {len(results)} steps in {took:.0f}s, {len(own)} red of this change's own"
          f" ({len(skipped)} skipped here: --list)")
    return 1 if own else 0


if __name__ == "__main__":
    sys.exit(main())
