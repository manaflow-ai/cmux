#!/usr/bin/env python3
"""Generate the walks suite: seeded random walks over the enabled operations of a generated suite.

Spec: plans/cmux-next/chrome-parity/p15-oracle.md, section 3D (suite walks, class differential) and task 098.
Stdlib only, Python 3.9+, safe under `python3 -I`. `oracle.py gen --suite walks` runs it with
`--out <corpus>/walks`; minimize.py (the same task) turns a walk that diverges into a small case of the suite.

A walk is one case: the standard fixture steps its moves need, then `--length` moves drawn from a seeded
generator. A move is one of
- an enabled operation: the `call` step of that operation's success case in the source suite (daemon-ops,
  gen_daemon_ops.py), with its target and params as generated there and a fresh idempotency key;
- a retry: an earlier move's call again with its idempotency key (invariant I10 inside a sequence).
A walk has no restart: a restarted owner adopts its terminals after it answers, so the next capture races the
adoption. Restarts and kills belong to crash_walks.py (p15-oracle-207), which compares a restarted root with the
last acknowledged sequence once it has settled.
Every call move expects outcome `any` (case-v1): the driver records what it gave (ok with `replayed`, or the typed
error) as the `reply` facet of its settled checkpoint, beside the daemon facet. What a call does depends on the state
the walk reached, so the case cannot assert it; the base run is the oracle (section 3D: differential suites compare
base == head or arm == arm, with no reviewed baseline).

An operation is enabled when its success case would run on the product as it stands: covered by the source
suite (no gap, no placeholder field), its case needs no capability the product lacks, no repository fixture and
no crash allowance, its call does not end the daemon, and its call reads only fixture objects (a value of a tuned
`before` step may be missing in the state a walk reached). coverage.json lists every enabled operation and every
excluded one with its reason, and the sha256 of the move table, so a walk names exactly what it was drawn from.
A walk inherits the switches of its operations' cases and their known failures on one arm: the generator owns a
block of tests/oracle/Expectations.d/walks.txt with one `[ arm ]` line per such walk, naming the task that fixes it.

The generator is SplitMix64 seeded from the sha256 of `walks.<source>.<seed>`: the same seed gives the same
walk on every host and Python version (no `random`, no hash randomization), and a walk does not move when
another seed is added.

Chrome reference (chromium/src):
- tools/ipc_fuzzer/: message sequences generated from a seed and replayed against a fresh renderer
  (ipc_fuzzer_replay), each failure kept as the file that reproduces it.
- base/test/launcher/test_launcher.cc: --gtest_random_seed is printed with a shuffled run so the order
  replays exactly; here the seed is the case name.

Usage:
  gen_walks.py --out DIR [--seeds A:B] [--length N] [--source daemon-ops] [--product daemon] [--corpus DIR]
                                    write walk cases seed-<n>.json for seeds A..B-1 (default 0:8, length 30) and
                                    coverage.json into DIR; minimized cases (min-*.json, minimize.py) are kept
  gen_walks.py --out DIR --check    exit 1 when DIR differs from a fresh generation with the same options
  gen_walks.py show --seed N        print one walk to stdout (same options)
"""

from __future__ import annotations

import argparse
import copy
import hashlib
import json
import re
import sys
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Dict, Iterable, List, Mapping, Optional, Sequence, Set, Tuple

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[2]
if str(HERE) not in sys.path:
    sys.path.insert(0, str(HERE))

import gen_daemon_ops  # noqa: E402 - sibling of this file: the standard fixture's declared order (FIXTURE)

DEFAULT_CORPUS = REPO / "tests" / "oracle" / "corpus"
SUITE = "walks"
GENERATOR = "scripts/cmux-next/oracle/gen_walks.py"
SCHEMA_REF = "../../../../schemas/oracle/case-v1.schema.json"
COVERAGE = "coverage.json"
# The block of tests/oracle/Expectations.d/walks.txt this generator owns (expectations.py format).
EXPECTATIONS_BEGIN = f"# BEGIN {GENERATOR}: walks with an operation that is a known failure on one switch arm"
EXPECTATIONS_END = f"# END {GENERATOR}"
EXPECTATIONS_HEADER = (f"# {SUITE} expectations (format: scripts/cmux-next/oracle/expectations.py).\n"
                       f"# {GENERATOR} writes the block below from the daemon-ops known failures; lines outside\n"
                       "# the block are kept.\n")
DEFAULT_SEEDS = (0, 8)
DEFAULT_LENGTH = 30
DEFAULT_SOURCE = "daemon-ops"
# Per mille of moves that retry an earlier call (when there is one).
RETRY_PER_MILLE = 100
TASK_ID = re.compile(r"\bp\d{2}-[a-z]+-\d{3}[a-z]?\b")
# The generator's case files; minimize.py writes min-<case>-<signature>.json beside them, which it never touches.
SEED_CASE = re.compile(r"^seed-[0-9]{4,}\.json$")
STEP_REF = re.compile(r"\$step:([a-z0-9][a-z0-9-]{0,63})#")
# hermetic_env.py ROOT_TOKEN: the daemon driver does not expand it in step params.
ROOT_TOKEN = "$CASE_ROOT"
FIXTURE_PREFIX = "fx-"
DEFAULT_PLATFORMS = ("linux", "mac")
MASK64 = (1 << 64) - 1

# oracle.py PRODUCTS (the capabilities each product offers), for the products a walk source runs on.
PRODUCT_CAPABILITIES: Dict[str, frozenset] = {
    "daemon": frozenset({"resource_api", "restart"}),
    "cli": frozenset({"resource_api", "restart"}),
    "mcp": frozenset({"resource_api", "actions", "mcp", "restart"}),
    "headless": frozenset({"resource_api", "actions"}),
    "app": frozenset({"resource_api", "actions", "keys", "gui", "chromium", "restart", "mcp"}),
}
# Capabilities a case needs only because of its steps (case-v1 opNeedsCapability*): a move is one call, so it
# needs none of these unless a walk step of that op is present.
STEP_CAPABILITIES = {"restart": "restart", "kill": "restart", "action.run": "actions", "key": "keys",
                     "mcp": "mcp", "tui.key": "tui"}


class GenError(Exception):
    """The source suite cannot give a move table (a missing case, a fixture step that differs between cases)."""


# ------------------------------------------------------------------------------------------- the generator


class Rng:
    """SplitMix64 (Steele, Lea and Flood, OOPSLA 2014), seeded from the sha256 of a text."""

    def __init__(self, seed_text: str):
        self.state = int.from_bytes(hashlib.sha256(seed_text.encode("utf-8")).digest()[:8], "big")

    def next64(self) -> int:
        self.state = (self.state + 0x9E3779B97F4A7C15) & MASK64
        z = self.state
        z = ((z ^ (z >> 30)) * 0xBF58476D1CE4E5B9) & MASK64
        z = ((z ^ (z >> 27)) * 0x94D049BB133111EB) & MASK64
        return z ^ (z >> 31)

    def below(self, bound: int) -> int:
        """Uniform in [0, bound): rejection of the top partial range, so no value is more likely."""
        if bound <= 0:
            raise ValueError("bound must be positive")
        limit = (1 << 64) - ((1 << 64) % bound)
        while True:
            value = self.next64()
            if value < limit:
                return value % bound

    def chance(self, per_mille: int) -> bool:
        return self.below(1000) < per_mille


# ------------------------------------------------------------------------------------------- the move table


@dataclass(frozen=True)
class Move:
    """One enabled operation: its call step (no id, no key) and the fixture steps it reads."""

    operation: str
    family: str
    call: Mapping[str, Any] = field(hash=False, compare=False)
    fixture: Tuple[str, ...]
    requires: Tuple[str, ...]
    switches: Tuple[str, ...]
    platforms: Tuple[str, ...]
    # Known failures of the success case on one switch arm: (arm, results, reason naming the task that fixes it).
    known: Tuple[Tuple[str, Tuple[str, ...], str], ...] = ()


@dataclass
class MoveTable:
    source: str
    product: str
    moves: List[Move]
    excluded: Dict[str, str]
    fixture: Dict[str, Dict[str, Any]]  # fixture step id -> its step, without its idempotency key
    fixture_order: List[str]
    case_fields: Dict[str, Any]

    def digest(self) -> str:
        """The sha256 of everything a walk is drawn from: a walk records it, --check compares it."""
        doc = {"source": self.source, "product": self.product,
               "moves": [{"operation": m.operation, "call": m.call, "fixture": m.fixture, "requires": m.requires,
                          "switches": m.switches, "platforms": m.platforms, "known": m.known} for m in self.moves],
               "fixture": [self.fixture[i] for i in self.fixture_order], "case": self.case_fields}
        return hashlib.sha256(json.dumps(doc, sort_keys=True, separators=(",", ":")).encode("utf-8")).hexdigest()


def step_refs(value: Any) -> Set[str]:
    """The step ids a value's `$step:<id>#<pointer>` strings name."""
    return set(STEP_REF.findall(json.dumps(value)))


def without_key(step: Mapping[str, Any]) -> Dict[str, Any]:
    out = copy.deepcopy(dict(step))
    (out.get("args") or {}).pop("idempotencyKey", None)
    out.pop("note", None)
    return out


def load_json(path: Path) -> Any:
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError) as error:
        raise GenError(f"{path}: {error}") from None


def case_file(suite_dir: Path, case_name: str) -> Path:
    """A case of the suite by its name: cases are flat in the suite directory (oracle.py names one segment)."""
    path = suite_dir / f"{case_name}.json"
    if not path.is_file():
        raise GenError(f"{path} is missing: regenerate the source suite (oracle.py gen --suite {suite_dir.name})")
    return path


def exclusion(entry: Mapping[str, Any], case: Mapping[str, Any], call: Optional[Mapping[str, Any]],
              capabilities: frozenset) -> Optional[str]:
    """Why an operation of the source suite is not a move, or None when it is one."""
    if entry.get("gap"):
        return f"not covered by the source suite: {entry['gap']}"
    if entry.get("placeholders"):
        return f"its success case has placeholder fields ({', '.join(entry['placeholders'])})"
    if call is None:
        return "its success case has no call step"
    needs = set(case.get("requires") or ()) - set(STEP_CAPABILITIES.values())
    missing = sorted(needs - capabilities)
    if missing:
        return f"its case needs {', '.join(missing)}, which the product does not offer"
    if (case.get("fixture") or {}).get("repo"):
        return "its case builds a git repository fixture; a walk has the standard fixture only"
    if call.get("ends"):
        return f"its call ends the {call['ends']}; the walk's later moves would have no daemon"
    if case.get("allow_crashes"):
        return "its case allows a crash; a walk allows none"
    if ROOT_TOKEN in json.dumps(call):
        return f"its call names {ROOT_TOKEN}, which the daemon driver does not expand"
    other = sorted(r for r in step_refs(call) if not r.startswith(FIXTURE_PREFIX))
    if other:
        return (f"its call reads {', '.join(other)}, a tuned before step: that value may be missing in the state a "
                f"walk reached")
    return None


def known_failures(operation: str, entry: Mapping[str, Any]) -> Tuple[Tuple[str, Tuple[str, ...], str], ...]:
    """The success case's known failures on a switch arm (gen_daemon_ops.py coverage `expectations`)."""
    out = []
    for item in (entry.get("expectations") or {}).get("success") or ():
        reason = str(item.get("reason") or "")
        if not TASK_ID.search(reason):
            raise GenError(f"{operation}: a known failure names no task: {reason}")
        out.append((str(item["arm"]), tuple(item["results"]), reason))
    return tuple(sorted(out))


def fixture_closure(ids: Iterable[str], fixture: Mapping[str, Mapping[str, Any]]) -> Set[str]:
    """The fixture steps `ids` need, with the fixture steps those read."""
    out: Set[str] = set()
    todo = list(ids)
    while todo:
        step_id = todo.pop()
        if step_id in out:
            continue
        if step_id not in fixture:
            raise GenError(f"{step_id} is not a fixture step of the source suite")
        out.add(step_id)
        todo.extend(step_refs(fixture[step_id]))
    return out


def load_move_table(corpus: Path, source: str, product: str) -> MoveTable:
    """The enabled operations of `<corpus>/<source>`, read from its coverage.json and success cases."""
    if product not in PRODUCT_CAPABILITIES:
        raise GenError(f"product {product} is not one of {', '.join(sorted(PRODUCT_CAPABILITIES))}")
    if source != DEFAULT_SOURCE:
        raise GenError(f"source {source}: only {DEFAULT_SOURCE} has runnable success cases (the actions suite's "
                       f"coverage.json covers 0 actions until its live catalog lands)")
    suite_dir = corpus / source
    coverage = load_json(suite_dir / COVERAGE)
    operations = coverage.get("operations")
    if not isinstance(operations, dict):
        raise GenError(f"{suite_dir / COVERAGE} has no operations table")
    capabilities = PRODUCT_CAPABILITIES[product]
    moves: List[Move] = []
    excluded: Dict[str, str] = {}
    fixture: Dict[str, Dict[str, Any]] = {}
    case_fields: Dict[str, Any] = {}
    for operation in sorted(operations):
        entry = operations[operation]
        success = ((entry.get("cases") or {}).get("success") or "").split("/", 1)
        if len(success) != 2 or success[0] != source:
            raise GenError(f"{operation}: coverage names no {source} success case")
        case = load_json(case_file(suite_dir, success[1]))
        steps = case.get("steps") or []
        calls = [s for s in steps if s.get("id") == "call"]
        call = calls[0] if len(calls) == 1 else None
        for step in steps:
            if not str(step.get("id", "")).startswith(FIXTURE_PREFIX):
                continue
            plain = without_key(step)
            if fixture.setdefault(step["id"], plain) != plain:
                raise GenError(f"fixture step {step['id']} of {operation}'s case differs from another case's")
        if not case_fields:
            case_fields = {key: case[key] for key in ("surface", "preconditions", "teardown") if key in case}
        reason = exclusion(entry, case, call, capabilities)
        if reason:
            excluded[operation] = reason
            continue
        assert call is not None
        plain_call = without_key(call)
        for key in ("id", "checkpoint", "expect", "waitFor", "settleMaxMs"):
            plain_call.pop(key, None)
        needs = sorted(set(case.get("requires") or ()) - set(STEP_CAPABILITIES.values()))
        moves.append(Move(operation, str(entry.get("family") or ""), plain_call,
                          tuple(sorted(fixture_closure(step_refs(plain_call), fixture))), tuple(needs),
                          tuple(sorted(case.get("switches") or ())), tuple(case.get("platforms") or DEFAULT_PLATFORMS),
                          known_failures(operation, entry)))
    if not moves:
        raise GenError(f"{source} has no enabled operation for product {product}")
    return MoveTable(source, product, moves, excluded, fixture, standard_order(fixture), case_fields)


def standard_order(fixture: Mapping[str, Mapping[str, Any]]) -> List[str]:
    """The fixture steps in gen_daemon_ops.py FIXTURE order, each after the fixture steps it reads."""
    rank = {step.id: index for index, step in enumerate(gen_daemon_ops.FIXTURE)}
    unknown = sorted(set(fixture) - set(rank))
    if unknown:
        raise GenError(f"fixture steps {', '.join(unknown)} are not in gen_daemon_ops.py FIXTURE")
    order = sorted(fixture, key=rank.__getitem__)
    for index, step_id in enumerate(order):
        late = sorted(step_refs(fixture[step_id]) - set(order[:index]))
        if late:
            raise GenError(f"fixture step {step_id} reads {', '.join(late)}, which does not come before it")
    return order


# ------------------------------------------------------------------------------------------------ the walk


def case_name(seed: int) -> str:
    return f"seed-{seed:04d}"


def move_expect(call: Mapping[str, Any]) -> Dict[str, Any]:
    """Outcome any, with the receipt an ok reply gives (I1); an error is one typed error."""
    if call.get("op") != "resource.call" or call.get("readOnly"):
        raise GenError(f"a move is a resource.call mutation, not {call.get('op')} (readOnly {call.get('readOnly')})")
    return {"outcome": "any", "receipt": "mutation_result"}


def generate_walk(table: MoveTable, seed: int, length: int) -> Dict[str, Any]:
    """The walk of `seed`: a function of the move table, the seed and the length only."""
    if length < 1:
        raise GenError("a walk has at least one move")
    name = case_name(seed)
    rng = Rng(f"walks.{table.source}.{seed}")
    moves: List[Dict[str, Any]] = []
    calls: List[Dict[str, Any]] = []
    used: List[Move] = []
    for number in range(1, length + 1):
        prefix = f"m{number:02d}"
        if calls and rng.chance(RETRY_PER_MILLE):
            earlier = calls[rng.below(len(calls))]
            step = {**copy.deepcopy(earlier), "id": f"{prefix}-retry-{earlier['id'].split('-', 1)[0]}",
                    "note": f"retry of {earlier['id']} with its idempotency key (I10)"}
        else:
            move = table.moves[rng.below(len(table.moves))]
            used.append(move)
            step = {"id": f"{prefix}-{move.operation.replace('.', '-').replace('_', '-')}"[:64],
                    **copy.deepcopy(dict(move.call))}
            args = step.get("args")
            if isinstance(args, dict) and not step.get("readOnly"):
                args["idempotencyKey"] = f"{name}.{step['id']}"
            step["expect"] = move_expect(step)
            step["checkpoint"] = ["settled"]
            calls.append(step)
        moves.append(step)
    fixture_ids = fixture_closure((i for m in used for i in m.fixture), table.fixture)
    fixture_steps = []
    for step_id in table.fixture_order:
        if step_id in fixture_ids:
            step = copy.deepcopy(table.fixture[step_id])
            if isinstance(step.get("args"), dict) and step["op"] == "resource.call" and not step.get("readOnly"):
                step["args"]["idempotencyKey"] = f"{name}.{step_id}"
            fixture_steps.append(step)
    steps = fixture_steps + moves
    requires = {"resource_api"} | {cap for m in used for cap in m.requires}
    requires |= {STEP_CAPABILITIES[s["op"]] for s in steps if s["op"] in STEP_CAPABILITIES}
    platforms = [p for p in DEFAULT_PLATFORMS if all(p in m.platforms for m in used)]
    switches = sorted({s for m in used for s in m.switches})
    doc: Dict[str, Any] = {
        "$schema": SCHEMA_REF,
        "corpusVersion": 1,
        "id": name,
        "suite": SUITE,
        "title": f"{table.source} walk, seed {seed}: {length} moves over {len(table.moves)} enabled operations",
        **({"surface": table.case_fields["surface"]} if "surface" in table.case_fields else {}),
        "source": {"repo": "manaflow-ai/cmux", "ref": "$RUN", "artifact": "$RUN"},
        "environment": {},
        "fixture": {"seed": f"walks.{table.source}.{seed}", "network": "offline", "clock": "virtual"},
        "preconditions": list(table.case_fields.get("preconditions") or ["hermetic state root"]),
        "requires": sorted(requires),
        **({"switches": switches} if switches else {}),
        "platforms": platforms,
        "steps": steps,
        "invariants": [
            f"generated by {GENERATOR} from {table.source} seed {seed} (move table sha256 {table.digest()})",
            "each call move's reply (ok or its typed error) is the reply facet of its settled checkpoint; "
            "base and head (or both arms) must give the same receipts and facets",
        ],
        "teardown": list(table.case_fields.get("teardown") or ["stop the case daemon"]),
    }
    return doc


def coverage_doc(table: MoveTable, seeds: Tuple[int, int], length: int) -> Dict[str, Any]:
    return {
        "generator": GENERATOR,
        "suite": SUITE,
        "source": table.source,
        "product": table.product,
        "move_table_sha256": table.digest(),
        "seeds": {"first": seeds[0], "end": seeds[1]},
        "length": length,
        "retry_per_mille": RETRY_PER_MILLE,
        # `oracle.py check --coverage`: the source's operations, those a walk draws from, the rest with a reason.
        "total": len(table.moves) + len(table.excluded),
        "covered": len(table.moves),
        "verdicts": "not run",
        "fixture": table.fixture_order,
        "moves": {m.operation: {"family": m.family, "fixture": list(m.fixture),
                                **({"switches": list(m.switches)} if m.switches else {})} for m in table.moves},
        "excluded": dict(sorted(table.excluded.items())),
    }


def render(value: Any) -> str:
    return json.dumps(value, indent=2, ensure_ascii=False) + "\n"


def walk_known(table: MoveTable, walk: Mapping[str, Any]) -> List[str]:
    """The walk's expectation lines: `<task> [ <arm> ] walks/<case> [ <results> ]` per switch arm on which one of
    its operations' success cases is a known failure, with the results of all of them and the first task named."""
    by_operation = {m.operation: m for m in table.moves}
    operations = {(s.get("args") or {}).get("method") for s in walk["steps"]
                  if s["op"] == "resource.call" and not s["id"].startswith(FIXTURE_PREFIX)}
    arms: Dict[str, Tuple[Set[str], List[str]]] = {}
    for operation in sorted(o for o in operations if o in by_operation):
        for arm, results, reason in by_operation[operation].known:
            known_results, tasks = arms.setdefault(arm, (set(), []))
            known_results.update(results)
            tasks.extend(TASK_ID.findall(reason))
    order = ("Pass", "Failure", "Crash", "Timeout", "Skip", "Slow")
    return [f"{sorted(tasks)[0]} [ {arm} ] {SUITE}/{walk['id']} [ {' '.join(r for r in order if r in results)} ]"
            for arm, (results, tasks) in sorted(arms.items())]


def render_expectations(existing: str, lines: Sequence[str]) -> str:
    """`existing` with the generator's block replaced by `lines` (or appended); lines outside it are kept."""
    block = "\n".join([EXPECTATIONS_BEGIN, *lines, EXPECTATIONS_END]) + "\n"
    begin, end = existing.find(EXPECTATIONS_BEGIN), existing.find(EXPECTATIONS_END)
    if begin >= 0 and end > begin:
        tail = existing[end + len(EXPECTATIONS_END):]
        return existing[:begin] + block + (tail[1:] if tail.startswith("\n") else tail)
    if begin >= 0 or end >= 0:
        raise GenError(f"the {SUITE} expectations file has one of the generator's block markers without the other")
    if not existing.strip():
        return EXPECTATIONS_HEADER + block
    return existing + ("" if existing.endswith("\n") else "\n") + block


def expectations_path(out: Path) -> Path:
    """`<oracle root>/Expectations.d/walks.txt` for a suite directory `<oracle root>/corpus/walks`."""
    return out.parent.parent / "Expectations.d" / f"{SUITE}.txt"


def generate(table: MoveTable, seeds: Tuple[int, int], length: int) -> Tuple[Dict[str, str], List[str]]:
    """File name -> text of every file the generator owns in the suite directory, and the expectation lines."""
    files: Dict[str, str] = {}
    lines: List[str] = []
    for seed in range(*seeds):
        walk = generate_walk(table, seed, length)
        files[f"{walk['id']}.json"] = render(walk)
        lines.extend(walk_known(table, walk))
    files[COVERAGE] = render(coverage_doc(table, seeds, length))
    return files, lines


def owned(out: Path) -> List[str]:
    """Files of the suite directory this generator wrote: its seeds and coverage.json, never min-* cases."""
    if not out.is_dir():
        return []
    return sorted(p.name for p in out.iterdir() if p.is_file() and (p.name == COVERAGE or SEED_CASE.match(p.name)))


def drift(out: Path, files: Mapping[str, str]) -> List[str]:
    problems = []
    for name in sorted(set(owned(out)) | set(files)):
        path = out / name
        if name not in files:
            problems.append(f"{path}: stale (not generated)")
        elif not path.is_file():
            problems.append(f"{path}: missing")
        elif path.read_text(encoding="utf-8") != files[name]:
            problems.append(f"{path}: differs from a fresh generation")
    return problems


def write(out: Path, files: Mapping[str, str]) -> Tuple[int, int]:
    out.mkdir(parents=True, exist_ok=True)
    removed = 0
    for name in owned(out):
        if name not in files:
            (out / name).unlink()
            removed += 1
    written = 0
    for name, text in files.items():
        path = out / name
        if not path.is_file() or path.read_text(encoding="utf-8") != text:
            path.write_text(text, encoding="utf-8")
            written += 1
    return written, removed


def parse_seeds(text: str) -> Tuple[int, int]:
    try:
        first, end = (int(part) for part in text.split(":"))
    except ValueError:
        raise argparse.ArgumentTypeError(f"--seeds takes FIRST:END, got {text!r}") from None
    if not 0 <= first < end:
        raise argparse.ArgumentTypeError(f"--seeds {text}: need 0 <= FIRST < END")
    return first, end


def main(argv: Optional[Sequence[str]] = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("command", nargs="?", choices=["write", "show"], default="write")
    parser.add_argument("--out", type=Path, help="the walks suite directory (write)")
    parser.add_argument("--corpus", type=Path, default=DEFAULT_CORPUS, help="corpus holding the source suite")
    parser.add_argument("--source", default=DEFAULT_SOURCE)
    parser.add_argument("--product", default="daemon", choices=sorted(PRODUCT_CAPABILITIES))
    parser.add_argument("--seeds", type=parse_seeds, default=DEFAULT_SEEDS, help="FIRST:END (default 0:8)")
    parser.add_argument("--length", type=int, default=DEFAULT_LENGTH, help="moves per walk (default 30)")
    parser.add_argument("--seed", type=int, help="show: the walk of this seed")
    parser.add_argument("--expectations", type=Path,
                        help="expectations file whose generated block lists the walks' known failures "
                             "(default <out>/../../Expectations.d/walks.txt)")
    parser.add_argument("--check", action="store_true", help="exit 1 when --out differs from a fresh generation")
    args = parser.parse_args(argv)
    try:
        table = load_move_table(args.corpus, args.source, args.product)
        if args.command == "show":
            if args.seed is None:
                parser.error("show needs --seed")
            sys.stdout.write(render(generate_walk(table, args.seed, args.length)))
            return 0
        if args.out is None:
            parser.error("write needs --out")
        files, lines = generate(table, args.seeds, args.length)
        expectations = args.expectations or expectations_path(args.out)
        existing = expectations.read_text(encoding="utf-8") if expectations.is_file() else ""
        block = render_expectations(existing, lines)
    except GenError as error:
        print(f"gen_walks.py: {error}", file=sys.stderr)
        return 2
    if args.check:
        problems = drift(args.out, files)
        if block != existing:
            problems.append(f"{expectations}: the generated block differs from a fresh generation")
        for problem in problems:
            print(problem)
        return 1 if problems else 0
    written, removed = write(args.out, files)
    if block != existing:
        expectations.parent.mkdir(parents=True, exist_ok=True)
        expectations.write_text(block, encoding="utf-8")
    print(f"gen_walks.py: {len(files) - 1} walks of {args.length} moves over {len(table.moves)} operations "
          f"({len(table.excluded)} excluded) in {args.out}: {written} written, {removed} removed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
