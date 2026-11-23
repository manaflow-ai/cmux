#!/usr/bin/env python3
"""Content-addressed job results, in shadow: the input key of a CI job, and its ci-receipt/v1 record.

Leo, 2026-11-20 (ask-8ed2d4d7c2): "the whole point is we can do what the point of doing Bazel is, which is to run
Borg without needing Bazel. You can just do the Borg." A job's verdict is a function of its inputs, so a green
verdict recorded under the hash of those inputs stands for every later run with the same hash
(cmuxterm-hq RFD 0016, "Borg without Bazel").

The input key is the sha256 of a canonical JSON object: the check, its canonical command, the selected units (React
Doctor's projects), and the git object id at HEAD of every input path the check reads, from
scripts/ci/receipt-inputs/CHECK.txt. A path absent at HEAD is recorded as absent, so adding it changes the key. The
toolchain pins (bun, node) live in the workflow file, which is itself an input. Prior art for the function:
scripts/ci/cmux_tui_tree_key.py.

The record is RFD 0019's ci-receipt/v1 (scripts/ci/ci_receipt.py is its producer for local receipts) with one
added field, `input_key`; `tree` stays, so a whole-tree match still counts. No second format.

Shadow only. Until the controller signs receipts and posts them as the check run from the manaflow-checks App
(RFD 0019), nothing is skipped: the workflow looks the key up, reports `would_skip`, runs in full, and records its
own green result. A record here is unsigned and is never skip evidence.

  key CHECK [--units "a b"] [--base SHA] [--output FILE]   print input_key (empty when no unit is selected: nothing
        to key) and pinned=true|false: with --base, whether the change touches a pinned file, the check's own
        `*` inputs (its scripts, tool, workflow) or a line of the base's scripts/ci/check-paths.txt (fnmatch). The
        code under test runs those, so a run that touches one is never skipped, whatever its key (the receipt
        signer's rule, cmuxterm-hq RFD 0019); its would-skip is false.
  record CHECK --input-key K [--base SHA] [--exit N] --out FILE   write the unsigned ci-receipt/v1 record
  replay CHECK --since ISO [--ref origin/feat-cmux-next]   the base-push hit rate this key would have had: each
        first-parent commit keyed over every unit, a hit when its key was seen on an earlier push
"""
from __future__ import annotations

import argparse
import datetime
import fnmatch
import hashlib
import json
import os
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
INPUTS_DIR = ROOT / "scripts" / "ci" / "receipt-inputs"
SCHEMA = "ci-receipt/v1"
KEY_VERSION = 1
# The check name each record carries and the canonical command its key covers.
CHECKS = {
    "react-doctor": {
        "check": "React Doctor (changed React projects)",
        "command": "python3 scripts/ci/react_doctor_gate.py",
    },
}
GIT_ENV = {**os.environ, "GIT_NO_LAZY_FETCH": "1"}


def git(*args: str) -> str:
    return subprocess.check_output(["git", "-C", str(ROOT), *args], text=True, env=GIT_ENV,
                                   stderr=subprocess.DEVNULL, timeout=60).strip()


def load_inputs(check: str, path: Path | None = None) -> list[tuple[str, str, str]]:
    """(unit, kind, path) rows; unit `*` is read by every run of the check."""
    rows = []
    for raw in (path or INPUTS_DIR / f"{check}.txt").read_text(encoding="utf-8").splitlines():
        line = raw.split("#", 1)[0].strip()
        if not line:
            continue
        unit, kind, rel = line.split()
        if kind not in ("tree", "blob"):
            raise ValueError(f"{check}: unknown input kind {kind!r} in {raw!r}")
        rows.append((unit, kind, rel))
    return rows


def object_id(revision: str, rel: str) -> str | None:
    try:
        return git("rev-parse", f"{revision}:{rel}")
    except subprocess.CalledProcessError:
        return None


def input_key(check: str, units: list[str], revision: str = "HEAD", rows=None) -> tuple[str, dict]:
    if check not in CHECKS:
        raise ValueError(f"unknown check {check!r}; known: {sorted(CHECKS)}")
    rows = load_inputs(check) if rows is None else rows
    known = {unit for unit, _, _ in rows if unit != "*"}
    unknown = sorted(set(units) - known)
    if unknown:
        # A unit with no inputs listed would key on nothing and hit forever: refuse it.
        raise ValueError(f"{check}: no inputs listed for {unknown}; add them to receipt-inputs/{check}.txt")
    selected = sorted(set(units))
    paths = sorted({rel for unit, _, rel in rows if unit == "*" or unit in selected})
    material = {
        "v": KEY_VERSION,
        "check": check,
        "command": CHECKS[check]["command"],
        "units": selected,
        "inputs": {rel: object_id(revision, rel) for rel in paths},
    }
    blob = json.dumps(material, sort_keys=True, separators=(",", ":")).encode()
    return hashlib.sha256(blob).hexdigest(), material


CHECK_PATHS = "scripts/ci/check-paths.txt"


def pinned_patterns(check: str, base: str, rows=None) -> list[str]:
    rows = load_inputs(check) if rows is None else rows
    patterns = [rel + "/*" if kind == "tree" else rel for unit, kind, rel in rows if unit == "*"]
    try:
        text = git("show", f"{base}:{CHECK_PATHS}")
    except subprocess.CalledProcessError:
        text = ""
    patterns += [line.strip() for line in text.splitlines() if line.strip() and not line.strip().startswith("#")]
    return patterns


def pinned_touched(check: str, base: str, head: str = "HEAD", rows=None) -> list[str]:
    """The files BASE..HEAD changes that match a pinned pattern."""
    patterns = pinned_patterns(check, base, rows)
    changed = [p for p in git("diff", "--name-only", base, head).splitlines() if p]
    return [p for p in changed if any(fnmatch.fnmatch(p, pattern) for pattern in patterns)]


def record(check: str, key: str, base: str, exit_code: int) -> dict:
    env = os.environ
    server, repo = env.get("GITHUB_SERVER_URL", "https://github.com"), env.get("GITHUB_REPOSITORY", "manaflow-ai/cmux")
    run = env.get("GITHUB_RUN_ID", "")
    return {
        "schema": SCHEMA,
        "check": CHECKS[check]["check"],
        "repo": repo,
        "tree": git("rev-parse", "HEAD^{tree}"),
        "base": base,
        "command_sha256": hashlib.sha256(CHECKS[check]["command"].encode()).hexdigest(),
        "exit": exit_code,
        "runner": {"kind": "actions", "name": env.get("RUNNER_NAME", ""), "job": f"{run}/{env.get('GITHUB_RUN_ATTEMPT', '')}"},
        "logs": f"{server}/{repo}/actions/runs/{run}" if run else "",
        "finished_at": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "sig": None,  # unsigned: shadow only, never skip evidence (RFD 0019: the controller signs)
        "input_key": key,
    }


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    sub = parser.add_subparsers(dest="cmd", required=True)
    k = sub.add_parser("key")
    k.add_argument("check", choices=sorted(CHECKS))
    k.add_argument("--units", default="", help="space-separated units; `all` is every unit listed")
    k.add_argument("--base", default="", help="the pull request's base: report whether it touches a pinned file")
    k.add_argument("--output", type=Path, help="append input_key= and pinned= to this file (GITHUB_OUTPUT)")
    r = sub.add_parser("record")
    r.add_argument("check", choices=sorted(CHECKS))
    r.add_argument("--input-key", required=True)
    r.add_argument("--base", default="")
    r.add_argument("--exit", type=int, default=0)
    r.add_argument("--out", type=Path, required=True)
    p = sub.add_parser("replay")
    p.add_argument("check", choices=sorted(CHECKS))
    p.add_argument("--since", required=True)
    p.add_argument("--ref", default="origin/feat-cmux-next")
    args = parser.parse_args(argv)

    if args.cmd == "replay":
        rows = load_inputs(args.check)
        units = sorted({unit for unit, _, _ in rows if unit != "*"})
        commits = git("rev-list", "--first-parent", "--reverse", f"--since={args.since}", args.ref).split()
        seen, hits = set(), 0
        for commit in commits:
            key, _ = input_key(args.check, units, commit, rows)
            hits += key in seen
            seen.add(key)
        rate = hits / len(commits) if commits else 0.0
        print(json.dumps({"check": args.check, "ref": args.ref, "since": args.since, "pushes": len(commits),
                          "hits": hits, "hit_rate": round(rate, 3)}))
        return 0
    if args.cmd == "key":
        units = args.units.split()
        if units == ["all"]:
            units = sorted({unit for unit, _, _ in load_inputs(args.check) if unit != "*"})
        key = ""
        if units:
            key, material = input_key(args.check, units)
            print(json.dumps(material, sort_keys=True), file=sys.stderr)
        touched = pinned_touched(args.check, args.base) if key and args.base else []
        if touched:
            print(f"pinned files touched (never skipped): {' '.join(touched[:20])}", file=sys.stderr)
        pinned = "true" if touched else "false"
        print(f"input_key={key}\npinned={pinned}")
        if args.output:
            with args.output.open("a", encoding="utf-8") as handle:
                handle.write(f"input_key={key}\npinned={pinned}\n")
        return 0
    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text(json.dumps(record(args.check, args.input_key, args.base, args.exit), indent=2) + "\n")
    print(f"ci-receipt shadow: recorded {args.check} input_key={args.input_key}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
