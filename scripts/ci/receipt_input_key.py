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
    # Its rows are traced, not written: scripts/ci/traced_inputs.py export (cmuxterm-hq RFD 0148 row 9). It has no
    # units (`*` rows only), so `--units all` keys the whole check.
    "static-checks": {
        "check": "cmux-next static checks (vt-link-graph, nightly static capabilities, defaults snapshot, page strings)",
        "command": ".github/workflows/cmux-next-guards.yml jobs.static-checks",
    },
}
GIT_ENV = {**os.environ, "GIT_NO_LAZY_FETCH": "1"}
# blob, tree: the path's git object id (a tree covers everything under it). names: a directory the check lists but
# does not read through (Python's import system lists every sys.path entry); its key is the names and types of its
# entries, so editing a file under it changes nothing and adding, removing or renaming one does. A traced inputs
# list (scripts/ci/traced_inputs.py, hq RFD 0148 row 9) writes names rows; the controller's parseInputRows takes
# blob and tree only, so a class with names rows stays shadow-only until it learns them.
KINDS = ("tree", "blob", "names")


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
        if kind not in KINDS:
            raise ValueError(f"{check}: unknown input kind {kind!r} in {raw!r}")
        rows.append((unit, kind, rel))
    return rows


def object_id(revision: str, rel: str) -> str | None:
    try:
        return git("rev-parse", f"{revision}:{rel}")
    except subprocess.CalledProcessError:
        return None


def object_ids(revision: str, rels: list[str]) -> dict[str, str | None]:
    """object_id for many paths in one git process (a traced list has hundreds)."""
    if not rels:
        return {}
    if object_id is not _OBJECT_ID:  # replaced (a test's fixed ids): one call per path, as before
        return {rel: object_id(revision, rel) for rel in rels}
    out = subprocess.run(["git", "-C", str(ROOT), "cat-file", "--batch-check=%(objectname) %(objecttype)"],
                         input="".join(f"{revision}:{'' if rel == '.' else rel}\n" for rel in rels), capture_output=True, text=True,
                         env=GIT_ENV, timeout=120, check=True).stdout.splitlines()
    if len(out) != len(rels):
        raise RuntimeError(f"git cat-file answered {len(out)} lines for {len(rels)} paths")
    return {rel: (None if line.endswith(" missing") or " " not in line else line.split()[0])
            for rel, line in zip(rels, out)}


_OBJECT_ID = object_id


def names_id(revision: str, rel: str, oid: str | None) -> str | None:
    """The names and types of a tree's entries, hashed; None when the path is absent, the blob id when it is a file."""
    if oid is None:
        return None
    try:
        listing = subprocess.run(["git", "-C", str(ROOT), "ls-tree", "-z", oid], capture_output=True, env=GIT_ENV,
                                 timeout=60, check=True).stdout
    except subprocess.CalledProcessError:
        return oid  # not a tree: a file (or a gitlink) where the check listed a directory
    return names_hash([rec.split(b" ", 2)[1] + b" " + rec.split(b"\t", 1)[1] for rec in listing.split(b"\0") if rec])


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
    material = {
        "v": KEY_VERSION,
        "check": check,
        "command": CHECKS[check]["command"],
        "units": selected,
        "inputs": input_ids(revision, [(kind, rel) for unit, kind, rel in rows
                                       if unit == "*" or unit in selected]),
    }
    blob = json.dumps(material, sort_keys=True, separators=(",", ":")).encode()
    return hashlib.sha256(blob).hexdigest(), material


def input_ids(revision: str, selected: list[tuple[str, str]]) -> dict[str, str | None]:
    """Each selected path's id at REVISION: its object id (blob, tree) or its names id (names). A path listed both as
    names and as blob or tree keys on its object id, which covers the names."""
    by_path: dict[str, str] = {}
    for kind, rel in selected:
        if by_path.get(rel) in (None, "names"):
            by_path[rel] = kind
    oids = object_ids(revision, sorted(by_path))
    names = [rel for rel, kind in by_path.items() if kind == "names" and oids[rel] is not None]
    listings = tree_listings(revision, names) if len(names) > 8 else {}
    out = {}
    for rel in sorted(by_path):
        if by_path[rel] != "names" or oids[rel] is None:
            out[rel] = oids[rel]
        elif rel in listings:
            out[rel] = names_hash(listings[rel]) if listings[rel] is not None else oids[rel]
        else:
            out[rel] = names_id(revision, rel, oids[rel])
    return out


def names_hash(names: list[bytes]) -> str:
    return "names:" + hashlib.sha256(b"\0".join(sorted(names))).hexdigest()


def tree_listings(revision: str, rels: list[str]) -> dict[str, list[bytes] | None]:
    """`type name` of each REL directory's entries from one recursive ls-tree (many names rows: one git call, not one
    each). None marks a path that is not a tree (names_id keys it on its object id)."""
    want = {("" if r == "." else r).encode() for r in rels}
    raw = subprocess.run(["git", "-C", str(ROOT), "ls-tree", "-r", "-t", "-z", "--full-tree", revision],
                         capture_output=True, env=GIT_ENV, timeout=120, check=True).stdout
    found: dict[bytes, list[bytes]] = {w: [] for w in want}
    trees: set[bytes] = {b""}
    for rec in raw.split(b"\0"):
        if not rec:
            continue
        meta, path = rec.split(b"\t", 1)
        typ = meta.split(b" ", 2)[1]
        if typ == b"tree":
            trees.add(path)
        parent, _, name = path.rpartition(b"/")
        if parent in found:
            found[parent].append(typ + b" " + name)
    return {r: (found[w] if w in trees else None) for r in rels for w in [("" if r == "." else r).encode()]}


CHECK_PATHS = "scripts/ci/check-paths.txt"


def pinned_patterns(check: str, base: str, rows=None) -> list[str]:
    rows = load_inputs(check) if rows is None else rows
    # A names row pins nothing: the check only listed that directory, so editing a file in it is not running new code.
    patterns = [rel + "/*" if kind == "tree" else rel for unit, kind, rel in rows if unit == "*" and kind != "names"]
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
        if units or args.units == "all":  # `all` of a check with no units: its `*` rows alone
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
