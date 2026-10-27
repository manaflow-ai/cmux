#!/usr/bin/env python3
"""route: confirmed divergences to their owners (MQ-divergences).

Spec: plans/cmux-next/chrome-parity/p15-oracle.md, section 3F.5, rule 10 and done check 12; tasks 118
and 184. Stdlib only, Python 3.9+, safe under `python3 -I`.

    route.py CONFIRMED.jsonl [...] [--out /tmp/oracle/route.jsonl] [--owners OWNERS.md]
             [--switch-registry DIR] [--json]

Reads confirm.py's lines (schema cmux-oracle-confirmed-v1) and routes only a confirmed divergence:
class `confirmed` and the three verdicts head `fail`, head_retry `fail`, base `pass`, each with its run
id. Lines of the other classes are counted and left alone (confirm.py queued them elsewhere); a line
that says confirmed without those verdicts is refused by name. A divergence never reaches an owner
unconfirmed.

A routed divergence maps to files, then to owners:
    --switch NAME          the switch's registry file (plans/cmux-next/refactor-switches/NAME.json): its
                           `plan` and `old_paths`; the registry `owner` is recorded as switch_owner
    --arm launch-config    the same for every registered switch
    --base/--head          the files the head changes over the base (`git diff --name-only BASE HEAD`)
and each file to the most specific row of plans/cmux-next/OWNERS.md that matches it, read with the
pre-push hook's parser (guardrails.py), so a file's owner here is the hook's.

The queue file holds one line per divergence (key: case, pointer, head SHA, mode and switch), each with
its three verdicts, its owners and two replay commands: the oracle diff of that case and diff.py over the
original runs. A later route of the same divergence replaces its line; a line in the file without three
verdicts is dropped. Exit codes: 0 no line refused, 1 some lines refused, 2 bad input.
"""

from __future__ import annotations

import argparse
import importlib.util
import json
import os
import shlex
import subprocess
import sys
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Callable, Dict, Iterable, List, Mapping, Optional, Sequence, Tuple

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[2]
DEFAULT_OUT = Path("/tmp/oracle/route.jsonl")
DEFAULT_OWNERS = REPO / "plans" / "cmux-next" / "OWNERS.md"
DEFAULT_REGISTRY = REPO / "plans" / "cmux-next" / "refactor-switches"
CONFIRMED_SCHEMA = "cmux-oracle-confirmed-v1"
SCHEMA = "cmux-oracle-route-v1"
VERDICT_KEYS = ("head", "head_retry", "base")
ROUTED_VERDICTS = {"head": "fail", "head_retry": "fail", "base": "pass"}
FILES_KEPT = 50
FILES_PER_OWNER = 10
EXIT_OK, EXIT_REFUSED, EXIT_USAGE = 0, 1, 2


class RouteError(Exception):
    """An unreadable input or OWNERS.md: exit 2."""


def load_guardrails() -> Any:
    """scripts/cmux-next/guardrails.py, the pre-push hook's OWNERS.md parser and matcher."""
    spec = importlib.util.spec_from_file_location("oracle_route_guardrails", HERE.parent / "guardrails.py")
    if spec is None or spec.loader is None:
        raise RouteError("scripts/cmux-next/guardrails.py is missing: it owns the OWNERS.md parser")
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module  # dataclasses resolve their module through sys.modules
    spec.loader.exec_module(module)
    return module


def git_changed_files(repo: Path) -> Callable[[str, str], List[str]]:
    def changed(base: str, head: str) -> List[str]:
        proc = subprocess.run(["git", "-C", str(repo), "diff", "--name-only", "--no-renames", base, head],
                              check=False, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        if proc.returncode != 0:
            raise RouteError(f"git diff {base[:12]} {head[:12]}: {proc.stderr.strip()[-300:]}")
        return sorted(line for line in proc.stdout.splitlines() if line)
    return changed


@dataclass(frozen=True)
class Options:
    out: Path = DEFAULT_OUT
    owners: Path = DEFAULT_OWNERS
    registry: Path = DEFAULT_REGISTRY
    # (base sha, head sha) -> changed repo paths; injected so tests need no commits.
    changed_files: Optional[Callable[[str, str], List[str]]] = field(default=None, compare=False)


def refusal(row: Mapping[str, Any]) -> Optional[str]:
    """Why a line that claims to be confirmed is not routable, or None: head fail twice, base pass, run ids."""
    if row.get("schema") != CONFIRMED_SCHEMA:
        return f"not a {CONFIRMED_SCHEMA} line"
    verdicts = row.get("verdicts") or {}
    for key in VERDICT_KEYS:
        entry = verdicts.get(key) or {}
        if entry.get("verdict") != ROUTED_VERDICTS[key]:
            return f"{key} verdict is {entry.get('verdict')!r}, not {ROUTED_VERDICTS[key]!r}"
        if not entry.get("run_id"):
            return f"{key} verdict has no run id"
    return None


def route_key(row: Mapping[str, Any]) -> str:
    mode = row["mode"] + (f"={row['switch']}" if row.get("switch") else "")
    return f"{row['case']}#{row['finding'].get('pointer')}@{row['head_sha']}:{mode}"


def read_lines(path: Path) -> List[Dict[str, Any]]:
    try:
        text = path.read_text(encoding="utf-8")
    except OSError as error:
        raise RouteError(f"{path}: {error}") from None
    rows = []
    for number, line in enumerate(text.splitlines(), 1):
        if not line.strip():
            continue
        try:
            rows.append(json.loads(line))
        except ValueError as error:
            raise RouteError(f"{path}:{number}: not JSON ({error})") from None
    return rows


def registry_entries(root: Path) -> Dict[str, Dict[str, Any]]:
    entries: Dict[str, Dict[str, Any]] = {}
    if root.is_dir():
        for path in sorted(root.glob("*.json")):
            try:
                entries[path.stem] = json.loads(path.read_text(encoding="utf-8"))
            except (OSError, ValueError) as error:
                raise RouteError(f"{path}: {error}") from None
    return entries


def switch_files(entry: Mapping[str, Any]) -> List[str]:
    plan = str(entry.get("plan") or "").split("#", 1)[0]
    return [p for p in [plan, *(entry.get("old_paths") or ())] if p]


class Router:
    def __init__(self, options: Options) -> None:
        self.options = options
        self.guardrails = load_guardrails()
        try:
            self.rows = self.guardrails.parse_owners(options.owners.read_text(encoding="utf-8"))
        except OSError as error:
            raise RouteError(f"{options.owners}: {error}") from None
        self.registry = registry_entries(options.registry)
        self.changed = options.changed_files or git_changed_files(REPO)
        self.changed_cache: Dict[Tuple[str, str], List[str]] = {}

    def owner_rows(self, path: str) -> List[int]:
        """The most specific OWNERS.md rows of PATH (guardrails.owner_warnings's rule)."""
        g = self.guardrails
        scored = [(max(g.glob_specificity(p) for p in globs if g.glob_match(path, p)), index)
                  for index, (_, globs, _, _) in enumerate(self.rows) if any(g.glob_match(path, p) for p in globs)]
        if not scored:
            return []
        best = max(score for score, _ in scored)
        return [index for score, index in scored if score == best]

    def files_of(self, row: Mapping[str, Any]) -> Tuple[str, List[str], Optional[str]]:
        """(where the files come from, the files, the switch owner)."""
        if row["mode"] == "switch":
            entry = self.registry.get(str(row.get("switch")))
            if entry is None:
                return f"switch {row.get('switch')} (no registry file)", [], None
            return f"switch {row['switch']} plan and old paths", switch_files(entry), entry.get("owner")
        if row["mode"] == "launch-config":
            files = sorted({p for entry in self.registry.values() for p in switch_files(entry)})
            owners = sorted({str(entry.get("owner")) for entry in self.registry.values() if entry.get("owner")})
            return "every switch's plan and old paths", files, ", ".join(owners) or None
        pair = (str(row["base_sha"]), str(row["head_sha"]))
        if pair not in self.changed_cache:
            self.changed_cache[pair] = self.changed(*pair)
        return f"files changed {pair[0][:12]}..{pair[1][:12]}", self.changed_cache[pair], None

    def owners_of(self, files: Iterable[str]) -> Tuple[List[Dict[str, Any]], List[str]]:
        by_row: Dict[int, List[str]] = {}
        unowned: List[str] = []
        for path in files:
            rows = self.owner_rows(path)
            if not rows:
                unowned.append(path)
            for index in rows:
                by_row.setdefault(index, []).append(path)
        owners = []
        for index, paths in sorted(by_row.items(), key=lambda item: (-len(item[1]), item[0])):
            area, _, owner, doc = self.rows[index]
            owners.append({"owner": owner, "area": area, "doc": doc, "count": len(paths), "files": paths[:FILES_PER_OWNER]})
        return owners, unowned

    def line(self, row: Mapping[str, Any], source: Path) -> Dict[str, Any]:
        origin, files, switch_owner = self.files_of(row)
        owners, unowned = self.owners_of(files)
        return {
            "schema": SCHEMA,
            "key": route_key(row),
            "case": row["case"],
            "mode": row["mode"],
            "product": row["product"],
            "switch": row.get("switch"),
            "base_sha": row["base_sha"],
            "head_sha": row["head_sha"],
            "verdicts": {key: row["verdicts"][key] for key in VERDICT_KEYS},
            "finding": row["finding"],
            "files_from": origin,
            "files": files[:FILES_KEPT],
            "file_count": len(files),
            "owners": owners,
            "unowned_files": unowned[:FILES_KEPT],
            "switch_owner": switch_owner,
            "replay": {"oracle": oracle_replay(row), "diff": row["finding"].get("replay")},
            "confirmed": str(source),
        }


def oracle_replay(row: Mapping[str, Any]) -> str:
    """The oracle diff that reruns exactly this case in the comparison's mode."""
    parts = ["python3", "-I", "scripts/cmux-next/oracle/oracle.py", "diff", "--product", str(row["product"])]
    if row["mode"] == "switch":
        parts += ["--switch", str(row["switch"]), "--ref", str(row["head_sha"])]
    elif row["mode"] == "launch-config":
        parts += ["--arm", "launch-config", "--ref", str(row["head_sha"])]
    else:
        parts += ["--base", str(row["base_sha"]), "--head", str(row["head_sha"])]
    return shlex.join(parts + ["--filter", str(row["case"])])


def write_lines(path: Path, rows: Sequence[Mapping[str, Any]]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temp = path.with_name(f".{path.name}.{os.getpid()}.tmp")
    with temp.open("w", encoding="utf-8") as handle:
        for row in rows:
            handle.write(json.dumps(row, sort_keys=True) + "\n")
    temp.replace(path)


def queued(row: Mapping[str, Any]) -> bool:
    """A line of the queue file that still carries three verdicts (done check 12)."""
    verdicts = row.get("verdicts") or {}
    return row.get("schema") == SCHEMA and all(
        (verdicts.get(key) or {}).get("verdict") == ROUTED_VERDICTS[key] and (verdicts.get(key) or {}).get("run_id")
        for key in VERDICT_KEYS)


def route_files(paths: Sequence[Path], options: Options) -> Dict[str, Any]:
    """Routes the confirmed lines of PATHS into options.out; returns what it routed and refused."""
    router = Router(options)
    routed: Dict[str, Dict[str, Any]] = {}
    refused: List[Dict[str, str]] = []
    skipped: Dict[str, int] = {}
    for path in paths:
        for row in read_lines(path):
            if row.get("schema") == CONFIRMED_SCHEMA and row.get("class") != "confirmed":
                # confirm.py queued it elsewhere (MQ-flakes, base-red) or left it unconfirmed.
                skipped[str(row.get("class"))] = skipped.get(str(row.get("class")), 0) + 1
                continue
            why = refusal(row)
            if why is not None:
                refused.append({"case": str(row.get("case")), "why": why, "source": str(path)})
                continue
            line = router.line(row, path)
            routed[line["key"]] = line
    existing = read_lines(options.out) if options.out.is_file() else []
    dropped = [row.get("key") for row in existing if not queued(row)]
    queue = {row["key"]: row for row in existing if queued(row)}
    queue.update(routed)
    write_lines(options.out, [queue[key] for key in sorted(queue)])
    return {"out": str(options.out), "routed": len(routed), "queue": len(queue), "refused": refused,
            "skipped": skipped, "dropped": dropped, "keys": sorted(routed)}


def main(argv: Optional[List[str]] = None, *, changed_files: Optional[Callable[[str, str], List[str]]] = None) -> int:
    parser = argparse.ArgumentParser(prog="route.py", description=__doc__.split("\n\n")[0])
    parser.add_argument("confirmed", type=Path, nargs="+", help="confirm.py's confirmed.jsonl")
    parser.add_argument("--out", type=Path, default=DEFAULT_OUT, help=f"queue file (default {DEFAULT_OUT})")
    parser.add_argument("--owners", type=Path, default=DEFAULT_OWNERS)
    parser.add_argument("--switch-registry", type=Path, default=DEFAULT_REGISTRY)
    parser.add_argument("--json", action="store_true")
    args = parser.parse_args(argv)
    try:
        result = route_files(args.confirmed, Options(args.out, args.owners, args.switch_registry, changed_files))
    except RouteError as error:
        print(f"route: {error}", file=sys.stderr)
        return EXIT_USAGE
    if args.json:
        print(json.dumps(result, indent=1, sort_keys=True))
    else:
        skipped = ", ".join(f"{kind} {n}" for kind, n in sorted(result["skipped"].items())) or "none"
        print(f"oracle route: routed {result['routed']}, refused {len(result['refused'])}, not confirmed ({skipped}), "
              f"queue {result['queue']}: {result['out']}")
        for item in result["refused"][:20]:
            print(f"  refused: {item['case']}: {item['why']}")
        for key in result["dropped"][:20]:
            print(f"  dropped from the queue (no three verdicts): {key}")
    return EXIT_REFUSED if result["refused"] else EXIT_OK


if __name__ == "__main__":
    sys.exit(main())
