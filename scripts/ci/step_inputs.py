#!/usr/bin/env python3
"""Per-step input keys for the large checks: a step whose inputs are the ones base was green on is not run again.

Leo, 2026-11-22 06:19Z: "i hope you guys continue the trend of thinking of good ways to reduce wall time and reduce
minutes." The CI v2 design ("One step table") has a step declare its inputs; this file is the part that turns a
declaration into a skip.

A large check (a GitHub job of many steps) declares its steps in ci/steps.toml:

    [check.guard-group]
    check = "cmux-next CI guard group"            # the job's GitHub name
    workflow = ".github/workflows/cmux-next-guards.yml"
    job = "ci-guard-group"                        # the job id there

    [check.guard-group.step.workflow-lint]
    inputs = [".github/workflows/**", "scripts/ci/check_workflows.py"]
    tools = ["python3@3.12", "bun"]               # name@version, or a [tools] key (its command, which pins it)

A step's key is a SHA-256 over what its verdict is a function of: every `git ls-tree -r` entry (mode, blob, path) its
input globs match at the commit, its resolved tools, its own declaration, and this file and the glob matcher
(ci_steps.py). Nothing else: a step that reads the whole tree, git history, the base ref, the network or the pull
request's metadata must not be declared (it stays in its job's always-run part).

  - A base push run (feat-cmux-next) runs every step, then `receipt` writes the keys of the steps that passed to a
    manifest, saved to the Actions cache under `step-green-v1-<check>-<sha>`. Only base pushes write: a pull
    request cannot plant a green.
  - A pull request restores the newest manifest (restore key `step-green-v1-<check>-`; GitHub scopes the cache so a
    pull request reads its base branch's entries) and runs `plan`: a step whose key at the merge commit equals the
    manifest's key for it is skipped; every other step runs. A step with no entry, a changed input, a changed
    declaration, a changed tool, a missing or unreadable manifest, or any error here runs. `all_skipped=true`
    lets the workflow not start the job at all.
  - Each skip is an event: one JSON line (`step-input-skip`) in $CI_STEP_EVENTS (default
    $RUNNER_TEMP/step-input-events.jsonl), a notice annotation naming the base commit that was green on these inputs,
    and a row in the step summary. A sampled share of would-be skips still run (`--audit-percent`, default 10,
    seeded by key, run and attempt, as same_tree_reuse.py's audit) and are recorded as `step-input-audit`.

Detector for a wrong declaration: the audit sample, and the base push run, which never skips. `CI_STEP_INPUT_SKIP=0`
turns every skip off.

usage:
  step_inputs.py keys --check ID [--rev REV]                     -> {"step": "key", ...}
  step_inputs.py receipt --check ID --green A,B --out FILE [--rev REV]
  step_inputs.py plan --check ID --manifest FILE [--rev REV] [--audit-percent N] [--run-id R] [--attempt N]
                                                                 -> skip=, run=, all_skipped= (and $GITHUB_OUTPUT)
  step_inputs.py lint                                            -> every declared glob matches a file, steps known
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import subprocess
import sys
import time
import tomllib
from dataclasses import dataclass
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from ci_steps import glob_pattern  # noqa: E402

VERSION = "v1"
CACHE_PREFIX = f"step-green-{VERSION}"
ROOT = Path(__file__).resolve().parents[2]
TABLE = ROOT / "ci" / "steps.toml"
# This file and the glob matcher are an input of every key: a change to how keys are made runs every step.
SELF_INPUTS = ("scripts/ci/step_inputs.py", "scripts/ci/ci_steps.py")
DEFAULT_AUDIT_PERCENT = 10


class DeclError(ValueError):
    pass


@dataclass(frozen=True)
class StepDecl:
    name: str
    inputs: tuple[str, ...]
    tools: tuple[str, ...]


@dataclass(frozen=True)
class CheckDecl:
    id: str
    check: str
    workflow: str
    job: str
    steps: dict[str, StepDecl]


def parse_checks(doc: dict) -> dict[str, CheckDecl]:
    tools_table = doc.get("tools") or {}
    out: dict[str, CheckDecl] = {}
    for cid, raw in (doc.get("check") or {}).items():
        for key in ("check", "workflow", "job"):
            if not isinstance(raw.get(key), str) or not raw[key].strip():
                raise DeclError(f"check {cid}: `{key}` is required")
        unknown = set(raw) - {"check", "workflow", "job", "step"}
        if unknown:
            raise DeclError(f"check {cid}: unknown keys {sorted(unknown)}")
        steps: dict[str, StepDecl] = {}
        for name, s in (raw.get("step") or {}).items():
            unknown = set(s) - {"inputs", "tools"}
            if unknown:
                raise DeclError(f"check {cid} step {name}: unknown keys {sorted(unknown)}")
            inputs = s.get("inputs")
            if not isinstance(inputs, list) or not inputs:
                raise DeclError(f"check {cid} step {name}: `inputs` is a non-empty list of path globs")
            if not all(isinstance(g, str) and g and not g.startswith(("/", "!")) and g not in ("**", "*") for g in inputs):
                raise DeclError(f"check {cid} step {name}: `inputs` are repo-relative path globs, not the whole tree")
            tools = s.get("tools", [])
            if not isinstance(tools, list) or not all(isinstance(t, str) and t for t in tools):
                raise DeclError(f"check {cid} step {name}: `tools` is a list of name@version or [tools] keys")
            for t in tools:
                if "@" not in t and t not in tools_table:
                    raise DeclError(f"check {cid} step {name}: tool {t!r} is neither name@version nor a [tools] key")
            steps[name] = StepDecl(name, tuple(inputs), tuple(tools))
        if not steps:
            raise DeclError(f"check {cid}: declares no step")
        out[cid] = CheckDecl(cid, raw["check"], raw["workflow"], raw["job"], steps)
    return out


def load(path: Path = TABLE) -> tuple[dict[str, CheckDecl], dict[str, str]]:
    doc = tomllib.loads(path.read_text(encoding="utf-8"))
    return parse_checks(doc), dict(doc.get("tools") or {})


def git(*args: str, cwd: Path = ROOT) -> str:
    return subprocess.run(["git", *args], cwd=cwd, check=True, capture_output=True, text=True).stdout


def tree_entries(rev: str, cwd: Path = ROOT) -> list[tuple[str, str, str]]:
    """(mode, object, path) of every entry at REV, gitlinks included: one ls-tree, no blob reads."""
    out = []
    for rec in git("ls-tree", "-r", "-z", "--full-tree", rev, cwd=cwd).split("\0"):
        if not rec:
            continue
        meta, path = rec.split("\t", 1)
        mode, _kind, obj = meta.split(" ")
        out.append((mode, obj, path))
    return out


def resolve_tool(tool: str, tools_table: dict[str, str]) -> str:
    if "@" in tool:
        return tool
    # A [tools] key: its command names the version it installs (ensure-bun.sh 1.4.4, setup-node 24.22.1, ...).
    return f"{tool}#{hashlib.sha256(tools_table[tool].encode()).hexdigest()}"


def step_key(check: CheckDecl, step: StepDecl, entries: list[tuple[str, str, str]], tools_table: dict[str, str]) -> str:
    patterns = [glob_pattern(g) for g in step.inputs]
    selves = {path: obj for _m, obj, path in entries if path in SELF_INPUTS}
    h = hashlib.sha256()
    decl = {"version": VERSION, "check": check.id, "job": check.job, "workflow": check.workflow, "step": step.name,
            "inputs": sorted(step.inputs), "tools": sorted(resolve_tool(t, tools_table) for t in step.tools),
            "self": [selves.get(p, "") for p in SELF_INPUTS]}
    h.update(json.dumps(decl, sort_keys=True).encode())
    h.update(b"\0")
    for mode, obj, path in entries:  # ls-tree order is stable and sorted
        if any(p.match(path) for p in patterns):
            h.update(f"{mode} {obj} {path}\n".encode())
    return h.hexdigest()


def keys(check: CheckDecl, tools_table: dict[str, str], rev: str = "HEAD", cwd: Path = ROOT) -> dict[str, str]:
    entries = tree_entries(rev, cwd)
    return {name: step_key(check, step, entries, tools_table) for name, step in check.steps.items()}


def audit_pick(key: str, run_id: str, attempt: str, percent: int) -> bool:
    """Whether a would-be skip still runs in full. Seeded by the key and the run attempt: a re-run re-rolls it."""
    if percent <= 0:
        return False
    if percent >= 100:
        return True
    digest = hashlib.sha256(f"{key}:{run_id}:{attempt}".encode()).digest()
    return int.from_bytes(digest[:8], "big") % 100 < percent


def read_manifest(path: str | None, check: CheckDecl) -> dict | None:
    if not path:
        return None
    try:
        data = json.loads(Path(path).read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return None
    if not isinstance(data, dict) or data.get("version") != VERSION or data.get("check") != check.id:
        return None
    if not isinstance(data.get("steps"), dict) or not isinstance(data.get("rev"), str):
        return None
    return data


def plan(check: CheckDecl, here: dict[str, str], manifest: dict | None, audit_percent: int = DEFAULT_AUDIT_PERCENT,
         run_id: str = "", attempt: str = "", enabled: bool = True) -> dict:
    """Which declared steps run. A step skips only when the manifest, written by a base push run where it passed,
    holds exactly its key here, and the audit did not pick it."""
    skip, run, audit, events = [], [], [], []
    for name, key in here.items():
        green = (manifest or {}).get("steps", {}).get(name) if enabled else None
        if green != key:
            run.append(name)
            continue
        base = {"check": check.id, "job": check.job, "step": name, "key": key, "green_rev": manifest["rev"],
                "green_run": manifest.get("run_id", "")}
        if audit_pick(key, run_id, attempt, audit_percent):
            run.append(name)
            audit.append(name)
            events.append({"event": "step-input-audit", **base})
        else:
            skip.append(name)
            events.append({"event": "step-input-skip", **base})
    return {"skip": skip, "run": run, "audit": audit, "all_skipped": bool(here) and not run, "events": events}


def emit(result: dict, check: CheckDecl, rev_sha: str, run_id: str, out=sys.stdout) -> None:
    events_path = os.environ.get("CI_STEP_EVENTS") or (
        str(Path(os.environ["RUNNER_TEMP"]) / "step-input-events.jsonl") if os.environ.get("RUNNER_TEMP") else "")
    now = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
    lines = [json.dumps({**e, "rev": rev_sha, "run_id": run_id, "at": now}, sort_keys=True) for e in result["events"]]
    if events_path and lines:
        with open(events_path, "a", encoding="utf-8") as f:
            f.write("\n".join(lines) + "\n")
    for e in result["events"]:
        if e["event"] == "step-input-skip":
            print(f"::notice title=step input skip::{check.check}: step {e['step']} not run; its inputs are the ones "
                  f"{e['green_rev'][:12]} passed on (key {e['key'][:12]})", file=out)
        else:
            print(f"::notice title=step input audit::{check.check}: step {e['step']} runs as the sampled audit of a "
                  f"skip (green on {e['green_rev'][:12]})", file=out)
    for line in lines:
        print(f"step-input-event {line}", file=out)
    if os.environ.get("GITHUB_STEP_SUMMARY"):
        rows = [f"### Step input keys: `{check.check}`", "", "| Step | Decision |", "|---|---|"]
        rows += [f"| {n} | skipped: inputs equal a base green |" for n in result["skip"]]
        rows += [f"| {n} | runs{' (audit)' if n in result['audit'] else ''} |" for n in result["run"]]
        with open(os.environ["GITHUB_STEP_SUMMARY"], "a", encoding="utf-8") as f:
            f.write("\n".join(rows) + "\n\n")


def write_outputs(result: dict, out=sys.stdout) -> None:
    pairs = {"skip": ",".join(result["skip"]), "run": ",".join(result["run"]),
             "all_skipped": "true" if result["all_skipped"] else "false"}
    for k, v in pairs.items():
        print(f"{k}={v}", file=out)
    if os.environ.get("GITHUB_OUTPUT"):
        with open(os.environ["GITHUB_OUTPUT"], "a", encoding="utf-8") as f:
            f.write("".join(f"{k}={v}\n" for k, v in pairs.items()))


def lint(checks: dict[str, CheckDecl], cwd: Path = ROOT, rev: str = "HEAD") -> list[str]:
    paths = [p for _m, _o, p in tree_entries(rev, cwd)]
    errors = []
    for check in checks.values():
        if not (cwd / check.workflow).is_file() and check.workflow not in paths:
            errors.append(f"check {check.id}: workflow {check.workflow} does not exist")
        for step in check.steps.values():
            for g in step.inputs:
                pat = glob_pattern(g)
                if not any(pat.match(p) for p in paths):
                    errors.append(f"check {check.id} step {step.name}: input {g!r} matches no file")
    return errors


def fail_open_run_all(check: CheckDecl | None, why: str, out=sys.stdout) -> int:
    print(f"::notice title=step input skip::{why}; every step runs", file=out)
    names = list(check.steps) if check else []
    write_outputs({"skip": [], "run": names, "audit": [], "all_skipped": False}, out)
    return 0


def main(argv: list[str] | None = None) -> int:
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--table", default=str(TABLE))
    sub = p.add_subparsers(dest="command", required=True)
    k = sub.add_parser("keys")
    k.add_argument("--check", required=True)
    k.add_argument("--rev", default="HEAD")
    r = sub.add_parser("receipt")
    r.add_argument("--check", required=True)
    r.add_argument("--green", required=True, help="the steps that passed, comma separated")
    r.add_argument("--out", required=True)
    r.add_argument("--rev", default="HEAD")
    r.add_argument("--run-id", default=os.environ.get("GITHUB_RUN_ID", ""))
    x = sub.add_parser("plan")
    x.add_argument("--check", required=True)
    x.add_argument("--manifest", default="")
    x.add_argument("--rev", default="HEAD")
    x.add_argument("--audit-percent", type=int,
                   default=int(os.environ.get("CI_STEP_INPUT_AUDIT_PERCENT", DEFAULT_AUDIT_PERCENT)))
    x.add_argument("--run-id", default=os.environ.get("GITHUB_RUN_ID", ""))
    x.add_argument("--attempt", default=os.environ.get("GITHUB_RUN_ATTEMPT", ""))
    sub.add_parser("lint")
    args = p.parse_args(argv)
    try:
        checks, tools_table = load(Path(args.table))
    except (OSError, ValueError) as error:
        if args.command == "plan":
            return fail_open_run_all(None, f"unreadable step table ({error})")
        print(f"step table: {error}", file=sys.stderr)
        return 2
    if args.command == "lint":
        errors = lint(checks)
        for e in errors:
            print(e)
        return 1 if errors else 0
    check = checks.get(args.check)
    if check is None:
        if args.command == "plan":
            return fail_open_run_all(None, f"no check {args.check!r} in this table")
        print(f"no check {args.check!r}; have {sorted(checks)}", file=sys.stderr)
        return 2
    if args.command == "keys":
        print(json.dumps(keys(check, tools_table, args.rev), indent=1, sort_keys=True))
        return 0
    if args.command == "receipt":
        green = [n for n in args.green.replace(" ", ",").split(",") if n]
        here = keys(check, tools_table, args.rev)
        manifest = {"version": VERSION, "check": check.id, "rev": git("rev-parse", args.rev).strip(),
                    "run_id": args.run_id, "steps": {n: here[n] for n in green if n in here}}
        Path(args.out).write_text(json.dumps(manifest, indent=1, sort_keys=True) + "\n", encoding="utf-8")
        print(f"step-green receipt for {check.id}: {len(manifest['steps'])} of {len(here)} steps at {manifest['rev'][:12]}")
        return 0
    # plan: any failure here runs every step.
    try:
        here = keys(check, tools_table, args.rev)
        rev_sha = git("rev-parse", args.rev).strip()
    except (OSError, subprocess.CalledProcessError, ValueError) as error:
        return fail_open_run_all(check, f"no keys ({error})")
    enabled = os.environ.get("CI_STEP_INPUT_SKIP", "1") != "0"
    manifest = read_manifest(args.manifest, check)
    if manifest is None and enabled:
        print(f"::notice title=step input skip::{check.check}: no base green manifest; every step runs")
    result = plan(check, here, manifest, args.audit_percent, args.run_id, args.attempt, enabled)
    emit(result, check, rev_sha, args.run_id)
    write_outputs(result)
    return 0


if __name__ == "__main__":
    sys.exit(main())
