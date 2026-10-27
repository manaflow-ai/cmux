#!/usr/bin/env python3
"""Route confirmed oracle divergences to their owners (MQ-divergences).

Spec: plans/cmux-next/chrome-parity/p15-oracle.md, sections 3F.5 and 6, task p15-oracle-118.
Stdlib only, Python 3.9+, safe under `python3 -I`. `oracle.py route ARGS` runs this script with ARGS.

Usage:
    route.py [CONFIRMED.jsonl ...] [--out FILE] [--switch NAME | --base REF --head REF]
             [--owners FILE] [--registry DIR] [--repo DIR] [--json]
    exit 0: every confirmed divergence routed (none is fine); 1: a confirmed divergence had no
    switch or change to map; 2: bad input (a missing or malformed file, an unknown switch, a bad ref)

Input (default /tmp/oracle/confirmed.jsonl, written by `oracle.py confirm`, task p15-oracle-184): one
JSON object per line, a diff.py finding (`journey`, `step`, `checkpoint`, `pointer`, `a`, `b`, `replay`,
`evidence`, ...) plus what confirm learned:
    "confidence": "confirmed" | "flaky" | "base-red" | "unconfirmed"
    "verdicts": {"head": {"verdict": "fail", "run": RUN_ID}, "head_retry": {...}, "base": {"verdict": "pass", ...}}
    "switch": NAME (a `diff --switch` divergence) or "base" and "head": commit SHAs (a `diff --base --head` one);
    a line's own target is used as a whole (half a commit pair is unroutable), --switch or --base/--head only for
    a line that names none
    optional "product": the oracle product the case ran on (default daemon)
Only a line that is confirmed is routed: confidence "confirmed" and the three verdicts "head fails twice,
base passes" (3F.5), each with its run id. Any other line is counted by its reason and goes nowhere: confirm
already sent flaky lines to MQ-flakes and base-red lines to the base-red queue. A diff.py document
(divergence.json) is refused: none of its findings is confirmed yet.

Mapping (one owner per divergence, the others listed):
1. A switch divergence maps to the switch's files: its `plan` (without the #anchor) and `old_paths`
   (plans/cmux-next/refactor-switches/<name>.json).
2. A base/head divergence maps to the files that differ between the two commits (`git diff --name-only`).
3. Each file belongs to the most specific OWNERS.md row that matches it, the rule the pre-push hook uses
   (guardrails.parse_owners, glob_match, glob_specificity; this file has no second copy of it). The row
   with the most files is the owner; a tie goes to the row listed first. A switch whose files no row
   matches goes to the registry's `owner`; any other unlisted change goes to the Performance Lead, who
   adds rows (OWNERS.md, "Not listed").
The owning program is the chrome-parity program id (pNN-name) the owner cell names, or else the switch
plan's file name.

Output (--out, default /tmp/oracle/route.jsonl, replaced as a whole): one line per confirmed divergence,
the same divergence (case, pointer, product, and switch at its source ref or commit pair) once, with
`owner`, `area`, `program`, `doc`, every matched row in `owners`, the three `verdicts` with their run ids,
`replay` (confirm's diff.py command over the recorded runs) and `rerun` (the oracle.py command that builds
and compares the case again).

Chrome reference:
- depot_tools/owners_client.py and owners_finder.py: a file's owners come from the closest OWNERS file;
  here the most specific row of one OWNERS.md stands for the closest file.
- ClusterFuzz (src/clusterfuzz/_internal/bot/tasks/regression_task.py): a bug is filed and assigned only
  for a testcase that reproduces, from the changes of its regression range; an unreliable one is
  marked flaky and assigned to no one. The CQ's "(retry with patch)" and "(without patch)" steps are the
  same rule for a try job: only a failure that repeats with the patch and passes without it is the CL's.
"""

from __future__ import annotations

import argparse
import glob
import hashlib
import importlib.util
import json
import os
import re
import shlex
import subprocess
import sys
import tempfile
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Dict, Iterable, List, Optional, Sequence, Tuple

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[2]
SCHEMA = "cmux-oracle-route-v1"
DIVERGENCE_SCHEMA = "oracle-divergence-v1"
DEFAULT_IN = Path("/tmp/oracle/confirmed.jsonl")
DEFAULT_OUT = Path("/tmp/oracle/route.jsonl")
OWNERS = Path("plans/cmux-next/OWNERS.md")
REGISTRY = Path("plans/cmux-next/refactor-switches")
UNLISTED_OWNER = "Performance Lead"
FILES_PER_OWNER = 20
PROGRAM = re.compile(r"\bp\d{2}-[a-z][a-z0-9]*\b")
REQUIRED_VERDICTS = (("head", "fail"), ("head_retry", "fail"), ("base", "pass"))

EXIT_OK, EXIT_UNROUTED, EXIT_BAD_INPUT = 0, 1, 2


class InputError(Exception):
    """A missing or malformed input file, an unknown switch or a ref git cannot read: exit 2."""


@dataclass(frozen=True)
class OwnerRow:
    index: int
    area: str
    globs: Tuple[str, ...]
    owner: str
    doc: str

    @property
    def program(self) -> Optional[str]:
        match = PROGRAM.search(self.owner)
        return match.group(0) if match else None


@dataclass(frozen=True)
class Roots:
    """Every input of a routing run; tests point them at a temporary tree."""

    repo: Path = REPO
    owners: Path = REPO / OWNERS
    registry: Path = REPO / REGISTRY


@dataclass(frozen=True)
class Target:
    """What a divergence is mapped from: a switch, or the change between two commits."""

    switch: Optional[str] = None
    base: Optional[str] = None
    head: Optional[str] = None


def load_guardrails() -> Any:
    """scripts/cmux-next/guardrails.py, the one OWNERS.md parser and matcher. `python3 -I` leaves it off sys.path."""
    spec = importlib.util.spec_from_file_location("oracle_route_guardrails", HERE.parent / "guardrails.py")
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module  # its dataclasses resolve their module through sys.modules
    spec.loader.exec_module(module)
    return module


def owner_rows(text: str, guardrails: Any) -> List[OwnerRow]:
    return [OwnerRow(i, area, tuple(globs), owner, doc)
            for i, (area, globs, owner, doc) in enumerate(guardrails.parse_owners(text))]


def rows_of(path: str, rows: Sequence[OwnerRow], guardrails: Any) -> List[OwnerRow]:
    """The most specific rows matching PATH (rows tied on the same glob are all its owners), as the hook picks."""
    scored = [(max(guardrails.glob_specificity(g) for g in row.globs if guardrails.glob_match(path, g)), row)
              for row in rows if any(guardrails.glob_match(path, g) for g in row.globs)]
    if not scored:
        return []
    best = max(score for score, _ in scored)
    return [row for score, row in scored if score == best]


def group_by_owner(files: Iterable[str], rows: Sequence[OwnerRow], guardrails: Any) -> List[Tuple[OwnerRow, List[str]]]:
    """(row, its files) for every row that owns one of FILES: most files first, then OWNERS.md order."""
    hits: Dict[int, List[str]] = {}
    for path in files:
        for row in rows_of(path, rows, guardrails):
            hits.setdefault(row.index, []).append(path)
    return sorted(((rows[i], hit) for i, hit in hits.items()), key=lambda item: (-len(item[1]), item[0].index))


# ---------------------------------------------------------------------------------------------------------
# Input


def read_lines(paths: Sequence[Path]) -> List[Tuple[str, Dict[str, Any]]]:
    """(where, object) for every non-empty line of PATHS."""
    out = []
    for path in paths:
        try:
            text = path.read_text(encoding="utf-8")
        except OSError as error:
            raise InputError(f"{path}: {error.strerror or error}") from error
        try:
            whole = json.loads(text)
        except ValueError:
            whole = None  # JSON lines: more than one document
        if isinstance(whole, dict) and whole.get("schema") == DIVERGENCE_SCHEMA:
            raise InputError(f"{path}: a diff.py document holds unconfirmed findings; run `oracle.py confirm` "
                             "and route its output")
        for number, line in enumerate(text.splitlines(), 1):
            if not line.strip():
                continue
            where = f"{path}:{number}"
            try:
                item = json.loads(line)
            except ValueError as error:
                raise InputError(f"{where}: not JSON ({error})") from error
            if not isinstance(item, dict):
                raise InputError(f"{where}: a line is a JSON object")
            out.append((where, item))
    return out


def unconfirmed_reason(item: Dict[str, Any]) -> Optional[str]:
    """None for a confirmed divergence (3F.5: head fails twice, base passes, each with a run id), else why not."""
    confidence = item.get("confidence")
    if confidence != "confirmed":
        return str(confidence or "unconfirmed")
    verdicts = item.get("verdicts")
    if not isinstance(verdicts, dict):
        return "confirmed without verdicts"
    for name, wanted in REQUIRED_VERDICTS:
        verdict = verdicts.get(name)
        if not isinstance(verdict, dict) or not verdict.get("run"):
            return f"confirmed without a {name} verdict and run id"
        if verdict.get("verdict") != wanted:
            return f"confirmed but {name} verdict is {verdict.get('verdict')!r}, not {wanted!r}"
    if not isinstance(item.get("journey"), str) or not item["journey"]:
        return "confirmed without a case (journey)"
    return None


def target_of(item: Dict[str, Any], default: Target) -> Target:
    """The line's own target as a whole, else the command line's.

    A line that names a switch maps to it; a line that names base or head maps to its own pair only (half a pair
    is unroutable, never completed from the command line); the command line's target serves only a line that
    names none of the three.
    """
    switch, base, head = item.get("switch"), item.get("base"), item.get("head")
    if switch:
        return Target(switch=str(switch))
    if base or head:
        return Target(base=str(base) if base else None, head=str(head) if head else None)
    return default


# ---------------------------------------------------------------------------------------------------------
# Mapping


def switch_entry(roots: Roots, name: str) -> Dict[str, Any]:
    if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]*", name):
        raise InputError(f"switch {name!r} is not a registry file name")
    path = roots.registry / f"{name}.json"
    try:
        entry = json.loads(path.read_text(encoding="utf-8"))
    except OSError as error:
        raise InputError(f"switch {name}: no registry file {path} ({error.strerror or error})") from error
    except ValueError as error:
        raise InputError(f"switch {name}: {path} is not JSON ({error})") from error
    if not isinstance(entry, dict):
        raise InputError(f"switch {name}: {path} is not a JSON object")
    return entry


def switch_files(entry: Dict[str, Any]) -> List[str]:
    files = []
    plan = entry.get("plan")
    if isinstance(plan, str) and plan:
        files.append(plan.split("#", 1)[0])
    files += [p for p in entry.get("old_paths") or [] if isinstance(p, str) and p]
    return list(dict.fromkeys(files))


def resolve(roots: Roots, ref: str) -> str:
    proc = subprocess.run(["git", "-C", str(roots.repo), "rev-parse", "--verify", "--quiet", "--end-of-options",
                           f"{ref}^{{commit}}"], check=False, stdout=subprocess.PIPE, text=True)
    if proc.returncode != 0:
        raise InputError(f"{ref}: not a commit in {roots.repo}")
    return proc.stdout.strip()


def changed_files(roots: Roots, base: str, head: str) -> List[str]:
    proc = subprocess.run(["git", "-C", str(roots.repo), "diff", "--name-only", "--no-renames", "-z", base, head, "--"],
                          check=False, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    if proc.returncode != 0:
        raise InputError(f"git diff {base} {head}: {proc.stderr.strip()}")
    return sorted(p for p in proc.stdout.split("\0") if p)


@dataclass(frozen=True)
class Mapping:
    mapped_from: str
    files: Tuple[str, ...]
    owners: Tuple[Tuple[OwnerRow, Tuple[str, ...]], ...]
    owner: str
    area: Optional[str]
    program: Optional[str]
    doc: Optional[str]
    switch_owner: Optional[str] = None
    plan: Optional[str] = None
    base: Optional[str] = None
    head: Optional[str] = None


class Router:
    """Maps targets to owners; caches each switch entry and commit pair, so a large queue reads each once."""

    def __init__(self, roots: Roots, guardrails: Any):
        self.roots = roots
        self.guardrails = guardrails
        try:
            text = roots.owners.read_text(encoding="utf-8")
        except OSError as error:
            raise InputError(f"{roots.owners}: {error.strerror or error}") from error
        self.rows = owner_rows(text, guardrails)
        if not self.rows:
            raise InputError(f"{roots.owners}: no owner rows (Area | Paths | Owner | Read first)")
        self.cache: Dict[Target, Mapping] = {}

    def map(self, target: Target) -> Mapping:
        """The mapping of TARGET; ValueError when it names nothing to map (no switch, no change)."""
        if target not in self.cache:
            self.cache[target] = self._map(target)
        return self.cache[target]

    def _map(self, target: Target) -> Mapping:
        if target.switch:
            entry = switch_entry(self.roots, target.switch)
            files = switch_files(entry)
            plan = entry.get("plan") if isinstance(entry.get("plan"), str) else None
            switch_owner = entry.get("owner") if isinstance(entry.get("owner"), str) else None
            plan_program = PROGRAM.search(Path(plan.split("#", 1)[0]).stem) if plan else None
            return self._owned("switch-plan", files, fallback=switch_owner, fallback_source="switch-owner",
                               program=plan_program.group(0) if plan_program else None,
                               switch_owner=switch_owner, plan=plan)
        if bool(target.base) != bool(target.head):
            given, missing = ("base", "head") if target.base else ("head", "base")
            raise ValueError(f"names a {given} commit but no {missing}: half a commit pair to map")
        if not target.base:
            raise ValueError("no switch and no base/head commits to map")
        base, head = resolve(self.roots, target.base), resolve(self.roots, target.head)
        if base == head:
            raise ValueError(f"base and head are one commit ({base}): no change to map")
        return self._owned("changed-files", changed_files(self.roots, base, head), fallback=None,
                           fallback_source=None, program=None, base=base, head=head)

    def _owned(self, mapped_from: str, files: List[str], *, fallback: Optional[str], fallback_source: Optional[str],
               program: Optional[str], **extra: Any) -> Mapping:
        if not files:
            raise ValueError(f"{mapped_from}: no files to map")
        grouped = group_by_owner(files, self.rows, self.guardrails)
        owners = tuple((row, tuple(hit)) for row, hit in grouped)
        if owners:
            top = owners[0][0]
            return Mapping(mapped_from, tuple(files), owners, top.owner, top.area, top.program or program, top.doc,
                           **extra)
        if fallback:
            return Mapping(fallback_source or mapped_from, tuple(files), (), fallback, None, program, None, **extra)
        return Mapping(f"{mapped_from} (unlisted)", tuple(files), (), UNLISTED_OWNER, None, program,
                       str(OWNERS), **extra)


# ---------------------------------------------------------------------------------------------------------
# Output


def product_of(item: Dict[str, Any]) -> str:
    product = item.get("product")
    return product if isinstance(product, str) and product else "daemon"


def source_of(item: Dict[str, Any]) -> Optional[str]:
    ref = item.get("source")
    return ref if isinstance(ref, str) and ref else None


def rerun_command(item: Dict[str, Any], mapping: Mapping, target: Target) -> str:
    """The oracle.py command that builds and compares this one case again (fresh, not from the queue's receipts)."""
    parts = ["python3", "-I", "scripts/cmux-next/oracle/oracle.py", "diff"]
    product = product_of(item)
    if product != "daemon":
        parts += ["--product", product]
    if target.switch:
        parts += ["--switch", target.switch]
        ref = source_of(item)
        if ref:
            parts += ["--ref", ref]
    else:
        parts += ["--base", mapping.base or "", "--head", mapping.head or ""]
    parts += ["--filter", glob.escape(item["journey"]), "--fresh"]
    return shlex.join(parts)


def route_key(item: Dict[str, Any], mapping: Mapping, target: Target) -> str:
    """One divergence: the case and pointer on one product, over one switch at one source ref or one commit pair."""
    if target.switch:
        scope = ["switch", target.switch, source_of(item)]
    else:
        scope = ["commits", mapping.base, mapping.head]
    text = json.dumps([item["journey"], item.get("pointer"), product_of(item), scope], separators=(",", ":"))
    return hashlib.sha256(text.encode()).hexdigest()[:16]


def routed_line(item: Dict[str, Any], mapping: Mapping, target: Target) -> Dict[str, Any]:
    return {
        "schema": SCHEMA,
        "key": route_key(item, mapping, target),
        "case": item["journey"],
        "step": item.get("step"),
        "checkpoint": item.get("checkpoint"),
        "pointer": item.get("pointer"),
        "a": item.get("a"),
        "b": item.get("b"),
        "owner": mapping.owner,
        "area": mapping.area,
        "program": mapping.program,
        "doc": mapping.doc,
        "owners": [{"owner": row.owner, "area": row.area, "program": row.program, "doc": row.doc,
                    "file_count": len(files), "files": list(files[:FILES_PER_OWNER])}
                   for row, files in mapping.owners],
        "mapped_from": mapping.mapped_from,
        "file_count": len(mapping.files),
        "switch": target.switch,
        "switch_owner": mapping.switch_owner,
        "plan": mapping.plan,
        "base": mapping.base,
        "head": mapping.head,
        "verdicts": item["verdicts"],
        "replay": item.get("replay"),
        "rerun": rerun_command(item, mapping, target),
        "evidence": item.get("evidence") or [],
    }


def write_jsonl(lines: Sequence[Dict[str, Any]], out: Path) -> None:
    """Replace OUT atomically, so a reader never sees half a queue and a reused path never holds an older run."""
    out.parent.mkdir(parents=True, exist_ok=True)
    handle, temp = tempfile.mkstemp(prefix=f".{out.name}.", dir=str(out.parent))
    try:
        with os.fdopen(handle, "w", encoding="utf-8") as stream:
            for line in lines:
                stream.write(json.dumps(line, sort_keys=True, ensure_ascii=False) + "\n")
        os.replace(temp, out)
    except BaseException:
        Path(temp).unlink(missing_ok=True)
        raise


@dataclass
class Result:
    routed: List[Dict[str, Any]]
    skipped: Dict[str, int]
    unrouted: List[Tuple[str, str]]
    duplicates: int


def route(items: Sequence[Tuple[str, Dict[str, Any]]], router: Router, default: Target) -> Result:
    result = Result([], {}, [], 0)
    seen = set()
    for where, item in items:
        reason = unconfirmed_reason(item)
        if reason is not None:
            result.skipped[reason] = result.skipped.get(reason, 0) + 1
            continue
        target = target_of(item, default)
        try:
            mapping = router.map(target)
        except ValueError as error:
            result.unrouted.append((where, f"{item['journey']}: {error}"))
            continue
        line = routed_line(item, mapping, target)
        if line["key"] in seen:
            result.duplicates += 1
            continue
        seen.add(line["key"])
        result.routed.append(line)
    return result


def print_summary(result: Result, out: Path) -> None:
    owners = sorted({line["owner"] for line in result.routed})
    print(f"route: {len(result.routed)} confirmed divergences to {len(owners)} owners -> {out}")
    for line in result.routed:
        area = f" ({line['area']})" if line["area"] else ""
        program = f" [{line['program']}]" if line["program"] else ""
        print(f"  {line['owner']}{area}{program}: {line['case']} {line['pointer']} via {line['mapped_from']}")
        print(f"    rerun: {line['rerun']}")
    for reason, count in sorted(result.skipped.items()):
        print(f"  not routed ({reason}): {count}")
    if result.duplicates:
        print(f"  duplicates dropped: {result.duplicates}")
    for where, error in result.unrouted:
        print(f"  unrouted {where}: {error}", file=sys.stderr)


def main(argv: Optional[List[str]] = None, roots: Optional[Roots] = None) -> int:
    parser = argparse.ArgumentParser(prog="route.py", description=__doc__.split("\n\n", 1)[0])
    parser.add_argument("inputs", type=Path, nargs="*", help=f"confirmed divergences, JSON lines (default {DEFAULT_IN})")
    parser.add_argument("--out", type=Path, default=DEFAULT_OUT, help=f"queue file (default {DEFAULT_OUT})")
    parser.add_argument("--switch", help="the switch of lines that name none (a `diff --switch` run)")
    parser.add_argument("--base", help="the base commit of lines that name none (a `diff --base --head` run)")
    parser.add_argument("--head", help="the head commit of lines that name none")
    parser.add_argument("--repo", type=Path, help="checkout to read OWNERS.md, the registry and git from")
    parser.add_argument("--owners", type=Path, help=f"owners table (default <repo>/{OWNERS})")
    parser.add_argument("--registry", type=Path, help=f"refactor switch registry (default <repo>/{REGISTRY})")
    parser.add_argument("--json", action="store_true", help="print the routed lines as JSON instead of a summary")
    args = parser.parse_args(argv)
    if args.switch and (args.base or args.head):
        parser.error("--switch maps to a plan, --base/--head to a change: give one")
    if bool(args.base) != bool(args.head):
        parser.error("--base and --head go together")
    roots = roots or Roots()
    if args.repo:
        repo = args.repo.resolve()
        roots = Roots(repo=repo, owners=repo / OWNERS, registry=repo / REGISTRY)
    roots = Roots(repo=roots.repo, owners=args.owners or roots.owners, registry=args.registry or roots.registry)
    try:
        items = read_lines(args.inputs or [DEFAULT_IN])
        result = route(items, Router(roots, load_guardrails()), Target(args.switch, args.base, args.head))
        write_jsonl(result.routed, args.out)
    except InputError as error:
        print(f"route: {error}", file=sys.stderr)
        return EXIT_BAD_INPUT
    if args.json:
        print(json.dumps(result.routed, indent=1, sort_keys=True))
        for where, error in result.unrouted:
            print(f"route: unrouted {where}: {error}", file=sys.stderr)
    else:
        print_summary(result, args.out)
    return EXIT_UNROUTED if result.unrouted else EXIT_OK


if __name__ == "__main__":
    sys.exit(main())
