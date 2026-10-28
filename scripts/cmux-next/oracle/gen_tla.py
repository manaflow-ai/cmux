#!/usr/bin/env python3
"""TLC simulate traces of the formal specs as oracle cases (p15-oracle-100, golden suite `tla`).

Spec: plans/cmux-next/chrome-parity/p15-oracle.md, task 100. Stdlib only, Python 3.9+, safe under `python3 -I`.

For each spec of plans/cmux-next/formal/oracle-actionmap.json (LayoutRows, TabLayout, closefocus,
OwnershipConvergence) this script:

1. writes a trace module that EXTENDS the spec, keeps the spec's Next as the step relation and labels every
   step with the action map's action that took it (`oracleAct`). A step that no mapped action explains is
   labeled "?" and stops the generation, so the map covers Next exactly;
2. runs TLC 1.7.4 (the jar and sha256 pinned in plans/cmux-next/formal/tlc.sh) with `-simulate` on the spec's
   configs (their CONSTANTS and CONSTRAINT sections; no invariants, the specs' own runs check those), one
   worker and a fixed seed per batch, so a regeneration gives the same traces;
3. maps each trace to one case-v1 case of resource-operations-v2 calls: a fixture that builds the model's
   initial state, then one call per owner step, with the outcome the model gives (`ok`, or the typed error
   the daemon gives for that reject), a keyed retry for every replayed key and a daemon restart for every
   owner restart. Client mirror, channel and view steps have no product step (the map says why for each);
4. writes the model's abstract state after each mapped step to `_expected-<spec slug>.json` (ids erased but tab
   and pane identity kept, as LayoutRows' Sig does), which `check` compares to a run's daemon facet;
5. drops a trace that applies an op kind with no product op (the map's `unmapped`), and one whose reject
   only comes from the model's bounded id pools, and counts every drop by reason in coverage.json;
6. keeps only product-distinct cases (`product_digest`: two traces that differ only in internal steps are one
   case), and handles the known restart defect of the map's `restartRace`: a few cases with one racing call
   stay under a generated `[ Pass Failure ]` line in tests/oracle/Expectations.d/tla.txt, the rest are dropped.

Specs with `excluded` in the map (FeedHandoff, hovercard) make no cases: their configs are simulated only to
check that the map labels every Next step, and coverage.json lists them as excluded with the reason.

Chrome reference: Chromium checks its state machines against models by differential tests that replay
generated operation sequences on the real object (base/containers/flat_tree_unittest.cc's model checks,
components/viz/service/display/surface_aggregator fuzzers with a reference model); here the model is TLA+ and
the sequences come from TLC's random simulation (tlc2.tool.Simulator).

Usage:
  gen_tla.py [--out DIR] [--spec NAME,...] [--check]    generate the suite (oracle.py gen --suite tla);
                                                        --check exits 1 when DIR differs from a fresh run
  gen_tla.py check RESULT.json CASE.json [--expected F] a driver_daemon.py run-case result against the
                                                        model's abstract states
  gen_tla.py vm --binary CMUX_TUI [--spec NAME,...] [--jobs N] [--limit N] [--isolation auto] [--out DIR]
                                                        run the suite's cases on a VM daemon and check them
"""

from __future__ import annotations

import argparse
import concurrent.futures
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import urllib.request
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Callable, Dict, Iterator, List, Mapping, Optional, Sequence, Set, Tuple

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import corpus_store  # noqa: E402 - sibling: tests/oracle/corpus/tla is a pinned artifact, not committed
REPO = HERE.parents[2]
FORMAL = REPO / "plans" / "cmux-next" / "formal"
ACTIONMAP = FORMAL / "oracle-actionmap.json"
TLC_SH = FORMAL / "tlc.sh"
DEFAULT_OUT = REPO / "tests" / "oracle" / "corpus" / "tla"
DRIVER_DAEMON = HERE / "driver_daemon.py"
SUITE = "tla"
TASK = "p15-oracle-100"
GENERATOR = "scripts/cmux-next/oracle/gen_tla.py"
COVERAGE = "coverage.json"
EXPECTED_SCHEMA = "cmux.oracle.tla-expected/v1"
CASE_SCHEMA_REF = "../../../../schemas/oracle/case-v1.schema.json"


def expected_name(slug: str) -> str:
    """The spec's abstract states, beside its cases (a `_` file, which oracle.py does not load as a case)."""
    return f"_expected-{slug}.json"


def slug_of(case_id: str) -> str:
    """Case ids are `<spec slug>-<config>-<nnnn>`; slugs have no `-`."""
    return case_id.split("-", 1)[0]


def owns(rel: str, slugs: Sequence[str]) -> bool:
    """Whether a suite file belongs to one of these specs (all files when no spec is named)."""
    if not slugs:
        return True
    stem = rel[len("_expected-"):] if rel.startswith("_expected-") else rel
    return slug_of(stem.removesuffix(".json")) in slugs


def expectations_path(out: Path) -> Path:
    """`<oracle root>/Expectations.d/tla.txt` for the suite directory `<oracle root>/corpus/tla`."""
    return out.parent.parent / "Expectations.d" / f"{SUITE}.txt"


TRACE_MODULE = "OracleTrace"
UNLABELED = "?"
VIEWPORT_WIDTH = 0.5


class GenError(Exception):
    """The generation cannot go on: a broken map, TLC failure, or a trace the map does not explain."""


class Unmapped(Exception):
    """The trace has a step with no product op; `key` is the coverage key it is counted under."""

    def __init__(self, key: str):
        super().__init__(key)
        self.key = key


# ---------------------------------------------------------------------------------------------------------
# TLA+ values as TLC prints them


class ModelValue(str):
    """A TLC model value (c1, none): kept apart from a TLA+ string of the same text."""

    def __repr__(self) -> str:
        return f"ModelValue({str.__repr__(self)})"

    def __eq__(self, other: object) -> bool:
        return isinstance(other, ModelValue) and str.__eq__(self, other)

    def __ne__(self, other: object) -> bool:
        return not self.__eq__(other)

    def __hash__(self) -> int:
        return hash(("mv", str(self)))


class Rec(dict):
    """A record or function value. Hashable, so it can sit in a set; never mutated after parsing."""

    def __hash__(self) -> int:  # type: ignore[override]
        return hash(frozenset((canon(k), v) for k, v in self.items()))


def canon(value: Any) -> str:
    """A canonical text of a value, for deterministic ordering of sets and maps."""
    if isinstance(value, bool):
        return "TRUE" if value else "FALSE"
    if isinstance(value, ModelValue):
        return f"@{value}"
    if isinstance(value, str):
        return json.dumps(value)
    if isinstance(value, int):
        return f"{value:+021d}"
    if isinstance(value, tuple):
        return "<<" + ",".join(canon(v) for v in value) + ">>"
    if isinstance(value, frozenset):
        return "{" + ",".join(sorted(canon(v) for v in value)) + "}"
    if isinstance(value, Rec):
        return "[" + ",".join(f"{canon(k)}:{canon(v)}" for k, v in sorted(value.items(), key=lambda kv: canon(kv[0]))) + "]"
    raise GenError(f"no canonical form for {value!r}")


_TOKEN = re.compile(r'\s*(<<|>>|\|->|:>|@@|\.\.|[{}\[\](),]|-?\d+|"(?:[^"\\]|\\.)*"|[A-Za-z_][A-Za-z0-9_]*)')


def tokens(text: str) -> List[str]:
    out: List[str] = []
    pos = 0
    text = text.rstrip()
    while pos < len(text):
        match = _TOKEN.match(text, pos)
        if match is None:
            raise GenError(f"cannot read the TLA+ value at {text[pos:pos + 40]!r}")
        out.append(match.group(1))
        pos = match.end()
    return out


class _Parser:
    def __init__(self, text: str):
        self.toks = tokens(text)
        self.i = 0

    def peek(self) -> Optional[str]:
        return self.toks[self.i] if self.i < len(self.toks) else None

    def take(self, want: Optional[str] = None) -> str:
        tok = self.peek()
        if tok is None or (want is not None and tok != want):
            raise GenError(f"expected {want or 'a value'}, got {tok!r} in TLA+ value")
        self.i += 1
        return tok

    def items(self, close: str) -> List[Any]:
        out: List[Any] = []
        if self.peek() == close:
            self.take(close)
            return out
        while True:
            out.append(self.value())
            if self.peek() == ",":
                self.take(",")
                continue
            self.take(close)
            return out

    def value(self) -> Any:
        left = self.atom()
        if self.peek() == "..":
            self.take("..")
            right = self.atom()
            if not (isinstance(left, int) and isinstance(right, int)):
                raise GenError("an interval needs integer bounds")
            return frozenset(range(left, right + 1))
        return left

    def atom(self) -> Any:
        tok = self.take()
        if tok == "<<":
            return tuple(self.items(">>"))
        if tok == "{":
            return frozenset(self.items("}"))
        if tok == "[":
            rec = Rec()
            if self.peek() == "]":
                self.take("]")
                return rec
            while True:
                key = self.take()
                self.take("|->")
                rec[key] = self.value()
                if self.peek() == ",":
                    self.take(",")
                    continue
                self.take("]")
                return rec
        if tok == "(":
            fn = Rec()
            while True:
                key = self.value()
                self.take(":>")
                fn[key] = self.value()
                if self.peek() == "@@":
                    self.take("@@")
                    continue
                self.take(")")
                return fn
        if tok.startswith('"'):
            return json.loads(tok)
        if re.fullmatch(r"-?\d+", tok):
            return int(tok)
        if tok == "TRUE":
            return True
        if tok == "FALSE":
            return False
        if re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*", tok):
            return ModelValue(tok)
        raise GenError(f"unexpected {tok!r} in TLA+ value")


def parse_value(text: str) -> Any:
    parser = _Parser(text)
    value = parser.value()
    if parser.peek() is not None:
        raise GenError(f"trailing {parser.peek()!r} after a TLA+ value")
    return value


def at(fn: Any, key: Any) -> Any:
    """fn[key] for a TLA+ function TLC printed as a sequence (domain 1..n) or as a function."""
    if isinstance(fn, tuple):
        if not isinstance(key, int) or not 1 <= key <= len(fn):
            raise GenError(f"index {key!r} outside a sequence of {len(fn)}")
        return fn[key - 1]
    if isinstance(fn, Rec):
        return fn[key]
    raise GenError(f"{fn!r} is not a function")


def domain(fn: Any) -> List[Any]:
    if isinstance(fn, tuple):
        return list(range(1, len(fn) + 1))
    if isinstance(fn, Rec):
        return sorted(fn, key=canon)
    raise GenError(f"{fn!r} is not a function")


def parse_trace(text: str, keep: Optional[Set[str]] = None) -> List[Dict[str, Any]]:
    """The states of one TLC simulate trace file (`STATE_n ==` blocks of `/\\ var = value`); only the
    variables in `keep` when it is given (a mirror the projection never reads is not parsed)."""
    states: List[Dict[str, Any]] = []
    for block in re.split(r"^STATE_\d+ ==[ \t]*$", text, flags=re.M)[1:]:
        lines = [line for line in block.splitlines() if not line.startswith("====")]
        body = "\n".join(lines)
        state: Dict[str, Any] = {}
        starts = list(re.finditer(r"^/\\ ([A-Za-z_][A-Za-z0-9_]*) = ", body, flags=re.M))
        for index, match in enumerate(starts):
            if keep is not None and match.group(1) not in keep:
                continue
            end = starts[index + 1].start() if index + 1 < len(starts) else len(body)
            state[match.group(1)] = parse_value(body[match.end():end])
        states.append(state)
    if not states:
        raise GenError("a trace file with no state")
    return states


# ---------------------------------------------------------------------------------------------------------
# The action map and TLC


@dataclass(frozen=True)
class Action:
    label: str
    over: Tuple[Tuple[str, str], ...]
    call: str
    map: str
    why: str
    excluded: str = ""


ACTION_MAPS = ("owner", "restart", "internal", "unmapped")


@dataclass(frozen=True)
class Config:
    name: str
    cfg: str
    depth: int
    seed: int
    batch: int
    max_batches: int
    cases: int
    constants: Tuple[Tuple[str, str], ...] = ()


@dataclass(frozen=True)
class RestartRace:
    """A known daemon defect after an owner restart (the action map's `restartRace`): a fresh call of one of
    `methods` after a restart races the daemon's terminal adoption. `keep` cases per spec that have exactly
    one such call stay in the suite with a `[ Pass Failure ]` line on that step naming `issue`; every other
    case with such a call is dropped and counted until the issue is fixed."""
    issue: str
    methods: Tuple[str, ...]
    keep: int
    why: str


@dataclass
class SpecMap:
    name: str
    slug: str
    module: str
    projection: str
    configs: List[Config]
    actions: List[Action]
    ops: Dict[str, Dict[str, str]]
    view: str = ""
    view_excluded: str = ""
    excluded: str = ""
    race: Optional[RestartRace] = None

    def unmapped(self, kind: str) -> Optional[str]:
        return (self.ops.get(kind) or {}).get("unmapped")


def load_actionmap(path: Path = ACTIONMAP) -> Dict[str, SpecMap]:
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError) as error:
        raise GenError(f"{path}: {error}") from None
    if data.get("schema") != "cmux.oracle.tla-actionmap/v1":
        raise GenError(f"{path}: schema is not cmux.oracle.tla-actionmap/v1")
    race = None
    if "restartRace" in data:
        raw_race = data["restartRace"]
        race = RestartRace(raw_race["issue"], tuple(raw_race["methods"]), int(raw_race["keep"]), raw_race["why"])
        if not re.fullmatch(r"#\d+|p\d{2}-[a-z0-9-]+-\d{3}", race.issue):
            raise GenError(f"{path}: restartRace.issue {race.issue!r} is neither #issue nor a task id")
    specs: Dict[str, SpecMap] = {}
    for name, raw in data["specs"].items():
        actions = []
        for item in raw["actions"]:
            if item["map"] not in ACTION_MAPS:
                raise GenError(f"{name}: action {item['label']} maps to {item['map']!r}")
            if item["map"] in ("internal", "unmapped") and not item.get("why"):
                raise GenError(f"{name}: {item['map']} action {item['label']} needs a why")
            if item["map"] in ("owner", "restart") and raw.get("excluded"):
                raise GenError(f"{name}: an excluded spec has no {item['map']} action ({item['label']})")
            actions.append(Action(item["label"], tuple(tuple(pair) for pair in item.get("over", [])), item["call"],
                                  item["map"], item.get("why", ""), item.get("excluded", "")))
        labels = [a.label for a in actions]
        if len(set(labels)) != len(labels) or UNLABELED in labels:
            raise GenError(f"{name}: action labels must be unique")
        if not re.fullmatch(r"[a-z0-9]+", raw["slug"]):
            raise GenError(f"{name}: slug {raw['slug']!r} must be [a-z0-9]+ (case ids are <slug>-<config>-<n>)")
        configs = [Config(c["name"], c["cfg"], int(c["depth"]), int(c["seed"]), int(c["batch"]),
                          int(c["maxBatches"]), int(c["cases"]),
                          tuple((k, str(v)) for k, v in sorted((c.get("constants") or {}).items())))
                   for c in raw["configs"]]
        if raw.get("excluded") and any(c.cases for c in configs):
            raise GenError(f"{name}: an excluded spec makes no cases; its configs only check the labels")
        if raw.get("view") and not raw.get("viewExcluded"):
            raise GenError(f"{name}: `view` needs `viewExcluded` (no product checks it yet) or a product check")
        specs[name] = SpecMap(name, raw["slug"], raw["module"], raw.get("projection", ""), configs, actions,
                              raw.get("ops", {}), raw.get("view", ""), raw.get("viewExcluded", ""),
                              raw.get("excluded", ""), race)
    return specs


def tlc_pin(script: Path = TLC_SH) -> Tuple[str, str]:
    """The tla2tools version and sha256 that tlc.sh pins (one pin for every TLC run of the repo)."""
    text = script.read_text(encoding="utf-8")
    version = re.search(r'^version="([^"]+)"', text, flags=re.M)
    digest = re.search(r'^sha256="([0-9a-f]{64})"', text, flags=re.M)
    if not version or not digest:
        raise GenError(f"{script}: no version= or sha256= pin")
    return version.group(1), digest.group(1)


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        for chunk in iter(lambda: handle.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


def tlc_jar() -> Path:
    """tlc.sh's cache path; downloads the pinned jar once and checks its sha256, as tlc.sh does."""
    version, digest = tlc_pin()
    cache = Path(os.environ.get("XDG_CACHE_HOME") or Path.home() / ".cache") / "cmux" / f"tla2tools-{version}.jar"
    if not cache.is_file():
        cache.parent.mkdir(parents=True, exist_ok=True)
        part = cache.with_suffix(".jar.part")
        url = f"https://github.com/tlaplus/tlaplus/releases/download/v{version}/tla2tools.jar"
        with urllib.request.urlopen(url, timeout=120) as response, open(part, "wb") as handle:
            shutil.copyfileobj(response, handle)
        part.replace(cache)
    actual = sha256_file(cache)
    if actual != digest:
        cache.unlink()
        raise GenError(f"tla2tools.jar sha256 mismatch: {actual} (tlc.sh pins {digest})")
    return cache


CFG_KEYWORDS = ("CONSTANTS", "CONSTANT", "INIT", "NEXT", "SPECIFICATION", "INVARIANTS", "INVARIANT", "PROPERTIES",
                "PROPERTY", "CONSTRAINTS", "CONSTRAINT", "ACTION_CONSTRAINTS", "ACTION_CONSTRAINT", "SYMMETRY", "VIEW",
                "CHECK_DEADLOCK", "ALIAS", "POSTCONDITION")


def cfg_sections(text: str) -> List[Tuple[str, str]]:
    """(keyword, body) in file order; `\\*` comments removed."""
    text = re.sub(r"\(\*.*?\*\)", "", text, flags=re.S)
    sections: List[Tuple[str, List[str]]] = []
    for raw in text.splitlines():
        line = re.sub(r"\\\*.*$", "", raw).rstrip()
        if not line.strip():
            continue
        head = line.split(None, 1)
        if head[0] in CFG_KEYWORDS:
            sections.append((head[0], [head[1]] if len(head) > 1 else []))
        elif sections:
            sections[-1][1].append(line)
        else:
            raise GenError(f"config text before any section: {line!r}")
    return [(keyword, "\n".join(body)) for keyword, body in sections]


def cfg_constants(text: str) -> Dict[str, Any]:
    """`name = value` constants of a config (substitutions `<-` are skipped)."""
    out: Dict[str, Any] = {}
    for keyword, body in cfg_sections(text):
        if keyword not in ("CONSTANT", "CONSTANTS"):
            continue
        for match in re.finditer(r"([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.+?)(?=\s+[A-Za-z_][A-Za-z0-9_]*\s*(?:=|<-)|\Z)",
                                 body, flags=re.S):
            out[match.group(1)] = parse_value(match.group(2).strip())
    return out


def override_constants(text: str, constants: Sequence[Tuple[str, str]]) -> str:
    """The config text with each `name = value` of `constants` replacing the config's own value (the action
    map raises a bound for more distinct traces without a second .cfg file)."""
    for name, value in constants:
        text, hits = re.subn(rf"(?m)^(\s*{re.escape(name)}\s*=\s*)\S.*$", lambda m: m.group(1) + value, text)
        if hits != 1:
            raise GenError(f"constant {name} is set {hits} times in the config, not once")
    return text


def trace_cfg(text: str) -> str:
    """The simulate config: the spec config's CONSTANTS and CONSTRAINT sections, our Init and Next."""
    kept = [f"{keyword}\n{body}" for keyword, body in cfg_sections(text)
            if keyword in ("CONSTANT", "CONSTANTS", "CONSTRAINT", "CONSTRAINTS")]
    return "\n".join(kept + ["INIT OracleInit", "NEXT OracleNext", ""])


def trace_module(spec: SpecMap) -> str:
    """The module that labels each step of the spec's Next with the action map's action."""

    def quantified(action: Action, body: str) -> str:
        for var, dom in reversed(action.over):
            body = f"\\E {var} \\in {dom} : {body}"
        return body

    def label(action: Action) -> str:
        fields = ", ".join([f'name |-> "{action.label}"'] + [f"{var} |-> {var}" for var, _ in action.over])
        return f"[{fields}]"

    labeled = "\n".join("  \\/ " + quantified(a, "(" + a.call + ") /\\ oracleAct' = " + label(a)) for a in spec.actions)
    covered = "\n".join("  \\/ " + quantified(a, a.call) for a in spec.actions)
    return (
        f"---- MODULE {TRACE_MODULE} ----\n"
        f"\\* Generated by {GENERATOR} from plans/cmux-next/formal/oracle-actionmap.json. Do not edit.\n"
        f"EXTENDS {spec.module}\n"
        "VARIABLE oracleAct\n"
        f"OracleLabeled ==\n{labeled}\n"
        f"OracleCovered ==\n{covered}\n"
        'OracleInit == Init /\\ oracleAct = [name |-> "Init"]\n'
        f"OracleNext == Next /\\ (OracleLabeled \\/ (~OracleCovered /\\ oracleAct' = [name |-> \"{UNLABELED}\"]))\n"
        "====\n"
    )


@dataclass
class Trace:
    spec: str
    config: Config
    batch: int
    index: int
    constants: Dict[str, Any]
    states: List[Dict[str, Any]]

    def label(self, i: int) -> Rec:
        return self.states[i]["oracleAct"]

    @property
    def origin(self) -> str:
        return f"{self.config.cfg}, seed {self.config.seed + self.batch}, trace {self.index}"


def simulate(spec: SpecMap, config: Config, batch: int, jar: Path, keep: Set[str]) -> Iterator[Trace]:
    """One TLC simulate batch: `config.batch` traces of depth <= config.depth, seed config.seed + batch,
    each with the variables in `keep` and its labels."""
    cfg_text = override_constants((FORMAL / config.cfg).read_text(encoding="utf-8"), config.constants)
    constants = cfg_constants(cfg_text)
    with tempfile.TemporaryDirectory(prefix="gen-tla-") as tmp:
        work = Path(tmp)
        shutil.copy(FORMAL / f"{spec.module}.tla", work / f"{spec.module}.tla")
        (work / f"{TRACE_MODULE}.tla").write_text(trace_module(spec), encoding="utf-8")
        (work / f"{TRACE_MODULE}.cfg").write_text(trace_cfg(cfg_text), encoding="utf-8")
        command = ["java", "-XX:+UseParallelGC", "-cp", str(jar), "tlc2.TLC", "-simulate",
                   f"file={work / 'tr'},num={config.batch}", "-depth", str(config.depth),
                   "-seed", str(config.seed + batch), "-workers", "1", "-deadlock", "-nowarning",
                   "-metadir", str(work / "meta"), "-config", f"{TRACE_MODULE}.cfg", f"{TRACE_MODULE}.tla"]
        try:
            done = subprocess.run(command, cwd=work, capture_output=True, text=True, timeout=1800, check=False)
        except FileNotFoundError:
            raise GenError("java is not on PATH (TLC needs Java 11 or later; scripts/cmux-next/linux/setup-tools.sh "
                           "installs it)") from None
        if done.returncode != 0 or "Finished in" not in done.stdout:
            raise GenError(f"TLC simulate of {config.cfg} failed (exit {done.returncode}): "
                           f"{(done.stdout + done.stderr)[-2000:]}")
        if not (work / "tr_0_0").is_file():
            raise GenError(f"TLC simulate of {config.cfg} wrote no trace")
        for index in range(config.batch):
            path = work / f"tr_0_{index}"
            if not path.is_file():
                break
            states = parse_trace(path.read_text(encoding="utf-8"), keep | {"oracleAct"})
            trace = Trace(spec.name, config, batch, index, constants, states)
            for i in range(1, len(states)):
                if trace.label(i)["name"] == UNLABELED:
                    raise GenError(f"{spec.name} ({trace.origin}): step {i + 1} is a Next step no action of the "
                                   f"action map explains; add its disjunct to oracle-actionmap.json")
            yield trace


# ---------------------------------------------------------------------------------------------------------
# Cases


def ref(step: str, pointer: str) -> str:
    return f"$step:{step}#{pointer}"


def value_ref(step: str, field_name: str) -> str:
    return ref(step, f"/value/{field_name}")


class CaseBuilder:
    """One case: its steps, the model's abstract state after each mapped step, and what it exercises."""

    def __init__(self, case_id: str, race_methods: Sequence[str] = ()):
        self.case_id = case_id
        self.steps: List[Dict[str, Any]] = []
        self.expected: List[Dict[str, Any]] = []
        self.requires: Set[str] = {"resource_api"}
        self.exercised: Set[str] = set()
        self.calls: Dict[Any, Tuple[str, Dict[str, Any], Dict[str, Any], Dict[str, Any]]] = {}
        self.owner_steps = 0
        self.race_methods = tuple(race_methods)
        self.restarted = False
        # Fresh calls of a restartRace method after a restart (RestartRace).
        self.race_steps: List[str] = []

    def unique(self, step_id: str) -> str:
        taken = {s["id"] for s in self.steps}
        if step_id not in taken:
            return step_id
        n = 2
        while f"{step_id}-{n}" in taken:
            n += 1
        return f"{step_id}-{n}"

    def call(self, step_id: str, method: str, target: Mapping[str, str], params: Optional[Mapping[str, Any]] = None,
             error: Optional[str] = None, key: Optional[str] = None, note: Optional[str] = None) -> str:
        step_id = self.unique(step_id)
        step: Dict[str, Any] = {"id": step_id, "op": "resource.call",
                                "target": {"machine": "current", "session": "current", **target},
                                "args": {"method": method}}
        if params:
            step["args"]["params"] = dict(params)
        step["args"]["idempotencyKey"] = f"{self.case_id}.{key or step_id}"
        step["expect"] = {"outcome": "error", "error": error} if error else {"outcome": "ok",
                                                                               "receipt": "mutation_result"}
        if note:
            step["note"] = note
        self.steps.append(step)
        if self.restarted and method in self.race_methods:
            self.race_steps.append(step_id)
        return step_id

    def read(self, step_id: str, method: str, target: Mapping[str, str], note: str) -> str:
        step_id = self.unique(step_id)
        self.steps.append({"id": step_id, "op": "resource.call", "readOnly": True,
                           "target": {"machine": "current", "session": "current", **target},
                           "args": {"method": method}, "note": note})
        return step_id

    def replay(self, step_id: str, op_key: Any, note: str) -> str:
        """The same call again with its idempotency key; the owner answers it from its record."""
        if op_key not in self.calls:
            raise GenError(f"{self.case_id}: replay of op {op_key!r}, which this case never sent")
        first, target, args, expect = self.calls[op_key]
        step_id = self.unique(step_id)
        self.steps.append({"id": step_id, "op": "resource.call", "target": dict(target), "args": json.loads(json.dumps(args)),
                           "expect": dict(expect), "note": f"{note}; the keyed retry of step {first}"})
        return step_id

    def remember(self, op_key: Any, step_id: str) -> None:
        step = next(s for s in self.steps if s["id"] == step_id)
        self.calls[op_key] = (step_id, step["target"], step["args"], step["expect"])

    def restart(self, step_id: str, note: str) -> str:
        step_id = self.unique(step_id)
        self.steps.append({"id": step_id, "op": "restart", "target": {"process": "daemon"},
                           "expect": {"outcome": "ok", "noReceiptReason": "a daemon restart runs no action"},
                           "note": note})
        self.requires.add("restart")
        self.restarted = True
        return step_id

    def state(self, step_id: str, state: Mapping[str, Any]) -> None:
        self.expected.append({"step": step_id, "state": state})


_STEP_REF = re.compile(r"^\$step:([^#]+)#(.*)$")


def product_digest(steps: Sequence[Mapping[str, Any]], expected: Sequence[Mapping[str, Any]]) -> str:
    """The sha256 of what a product sees of a case: each step's op, target, method, params and expect, and the
    model's states after them. Step ids, notes and the TLA step numbers in them are dropped, step refs and
    expected-state steps name the step's position, and an idempotency key names the position of the first
    step that sent it (a keyed retry stays a retry). Two TLC traces that only interleave internal steps
    differently give one product case."""
    position = {step["id"]: n for n, step in enumerate(steps)}
    first_key: Dict[str, int] = {}

    def form(value: Any) -> Any:
        if isinstance(value, str):
            ref_match = _STEP_REF.match(value)
            return f"$step:{position[ref_match.group(1)]}#{ref_match.group(2)}" if ref_match else value
        if isinstance(value, dict):
            return {k: form(v) for k, v in value.items()}
        if isinstance(value, list):
            return [form(v) for v in value]
        return value

    forms = []
    for n, step in enumerate(steps):
        body = {k: form(v) for k, v in step.items() if k not in ("id", "note")}
        args = dict(body.get("args") or {})
        if "idempotencyKey" in args:
            args["idempotencyKey"] = first_key.setdefault(args["idempotencyKey"], n)
            body["args"] = args
        forms.append(body)
    states = [{"step": position[entry["step"]], "state": entry["state"]} for entry in expected]
    return hashlib.sha256(json.dumps({"steps": forms, "expected": states}, sort_keys=True).encode()).hexdigest()


def tab_token(tab: Any) -> str:
    return f"t:{tab}"


def tab_set(groups: Sequence[Sequence[Sequence[str]]]) -> Dict[str, Any]:
    """{"workspaces": set of (set of pane tab sequences)} with canonical order."""
    workspaces = [{"set": sorted([list(p) for p in panes], key=json.dumps)} for panes in groups if panes]
    return {"workspaces": {"set": sorted(workspaces, key=lambda w: json.dumps(w, sort_keys=True))}}


class Fixture:
    """Builds tabs in panes in one workspace with the daemon's create ops and binds the model ids to the
    replies: workspace.create gives the first pane and tab, tab.create_terminal the next tabs of a pane,
    pane.split the next pane (`down` stacks it, `right` puts it beside, `viewport` starts a new column)."""

    def __init__(self, case: CaseBuilder):
        self.case = case
        self.tabs: Dict[Any, str] = {}
        self.panes: Dict[Any, str] = {}
        self.workspace = ""
        self.screen = ""
        self.last = ""

    def pane(self, pane: Any, tabs: Sequence[Any], after: Optional[Any] = None, how: str = "right") -> None:
        case = self.case
        if after is None:
            step = case.call("fx-workspace", "workspace.create", {},
                             {"initial_content": "terminal", "name": "oracle"})
            self.workspace = value_ref(step, "workspace_id")
            self.screen = value_ref(step, "screen_id")
        else:
            params: Dict[str, Any] = {"direction": "down" if how == "down" else "right"}
            if how == "viewport":
                params["viewport_width"] = VIEWPORT_WIDTH
            step = case.call(f"fx-pane-{len(self.panes) + 1}", "pane.split", {"pane": self.panes[after]}, params)
        self.panes[pane] = value_ref(step, "pane_id")
        if tabs:
            self.tabs[tabs[0]] = value_ref(step, "tab_id")
        self.last = step
        for tab in tabs[1:]:
            self.last = case.call(f"fx-tab-{len(self.tabs) + 1}", "tab.create_terminal", {"pane": self.panes[pane]})
            self.tabs[tab] = value_ref(self.last, "tab_id")


def move_index(src_tabs: Sequence[Any], dest_tabs: Sequence[Any], tab: Any, final: int, same: bool) -> int:
    """tab.move's index for a final 0-based position: the daemon inserts before the item at `index` of the
    destination as it was before the move, so in the own pane a move to the right names one more."""
    if same:
        current = list(src_tabs).index(tab)
        return final + 1 if final > current else final
    return final


def daemon_move(src_tabs: Sequence[Any], dest_tabs: Sequence[Any], tab: Any, index: int,
                same: bool) -> Tuple[List[Any], List[Any]]:
    """The daemon's tab.move on the two tab lists (insert before `index` of the list before the move)."""
    if same:
        tabs = list(src_tabs)
        current = tabs.index(tab)
        insert = min(index, len(tabs))
        tabs.insert(insert, tab)
        del tabs[current + 1 if insert <= current else current]
        return tabs, tabs
    src = [t for t in src_tabs if t != tab]
    dest = list(dest_tabs)
    dest.insert(min(index, len(dest)), tab)
    return src, dest


# -- TabLayout ----------------------------------------------------------------------------------------------


class TabLayoutProjector:
    """TabLayout.tla: the owner's OwnerApply of move and close, keyed replays and owner restarts."""

    reads = {"layout", "alive", "wsOf", "log", "doneOps", "rejectedOps"}

    def __init__(self, spec: SpecMap):
        self.spec = spec

    @staticmethod
    def abstract(state: Mapping[str, Any]) -> Dict[str, Any]:
        groups: Dict[Any, List[List[str]]] = {}
        for pane in sorted(state["alive"]):
            groups.setdefault(at(state["wsOf"], pane), []).append([tab_token(t) for t in at(state["layout"], pane)])
        return tab_set([groups[w] for w in sorted(groups)])

    def build(self, trace: Trace, case: CaseBuilder) -> None:
        init = trace.states[0]
        fixture = Fixture(case)
        previous = None
        for pane in sorted(init["alive"]):
            if at(init["wsOf"], pane) != 1:
                raise GenError("TabLayout: an initial pane outside workspace 1")
            fixture.pane(pane, at(init["layout"], pane), after=previous, how="right")
            previous = pane
        case.state(fixture.last, self.abstract(init))
        for i in range(1, len(trace.states)):
            pre, post, lab = trace.states[i - 1], trace.states[i], trace.label(i)
            name = lab["name"]
            if name == "OwnerApply":
                self.owner_apply(case, fixture, i, pre, post, lab["r"])
            elif name == "OwnerRestart":
                case.exercised.add(f"{self.spec.name}:OwnerRestart")
                step = case.restart(f"m{i:02d}-restart", f"TLA step {i + 1} OwnerRestart: committed state and the "
                                                         f"replay record survive")
                case.state(step, self.abstract(post))
            else:
                case.exercised.add(f"{self.spec.name}:{name}")

    def owner_apply(self, case: CaseBuilder, fixture: Fixture, i: int, pre: Mapping[str, Any],
                    post: Mapping[str, Any], r: Mapping[str, Any]) -> None:
        kind, op = r["kind"], r["op"]
        what = f"op {op} {kind} tab {r['tab']}" + (f" to pane {r['pane']} at {r['idx']}" if kind == "move" else "")
        if op in pre["doneOps"]:
            if kind not in ("move", "close"):
                raise Unmapped(f"{self.spec.name}:op/{kind}")
            case.exercised.add(f"{self.spec.name}:OwnerApply/replay")
            step = case.replay(f"m{i:02d}-retry", op, f"TLA step {i + 1} OwnerApply({what}) again: replayed")
            case.state(step, self.abstract(post))
            return
        if self.spec.unmapped(kind):
            raise Unmapped(f"{self.spec.name}:op/{kind}")
        rejected = op in post["rejectedOps"]
        case.exercised.add(f"{self.spec.name}:op/{kind}")
        case.exercised.add(f"{self.spec.name}:OwnerApply")
        tab = fixture.tabs[r["tab"]]
        verdict = "rejected" if rejected else ("no change" if len(post["log"]) == len(pre["log"]) else "applied")
        note = f"TLA step {i + 1} OwnerApply({what}): {verdict}"
        error = "selector.not_found" if rejected else None
        if kind == "close":
            step = case.call(f"m{i:02d}-close", "tab.close", {"tab": tab}, error=error, note=note)
        else:
            pane = r["pane"]
            index = max(r["idx"] - 1, 0)
            if not rejected:
                src = next(p for p in sorted(pre["alive"]) if r["tab"] in at(pre["layout"], p))
                same = src == pane
                dest = [t for t in at(pre["layout"], pane) if t != r["tab"]]
                final = min(r["idx"], len(dest) + 1) - 1
                index = move_index(at(pre["layout"], src), at(pre["layout"], pane), r["tab"], final, same)
                new_src, new_dest = daemon_move(at(pre["layout"], src), at(pre["layout"], pane), r["tab"], index, same)
                if list(at(post["layout"], pane)) != new_dest or (not same and list(at(post["layout"], src)) != new_src):
                    raise GenError(f"TabLayout: tab.move index {index} does not give the model's layout at step {i + 1}")
            step = case.call(f"m{i:02d}-move", "tab.move", {"tab": tab},
                             {"destination_workspace": fixture.workspace, "destination_screen": fixture.screen,
                              "destination_pane": fixture.panes[pane], "index": index}, error=error, note=note)
        case.remember(op, step)
        case.owner_steps += 1
        case.state(step, self.abstract(post))


# -- OwnershipConvergence -----------------------------------------------------------------------------------


class OwnershipProjector:
    """OwnershipConvergence.tla: Commit of move and close, keyed answers of decided keys, owner restarts.
    The daemon removes a pane that empties, so the abstract state is the panes that hold tabs."""

    reads = {"durable", "staged"}

    def __init__(self, spec: SpecMap):
        self.spec = spec

    @staticmethod
    def abstract(state: Mapping[str, Any]) -> Dict[str, Any]:
        layout = state["durable"]["state"]["layout"]
        panes = [[tab_token(t) for t in at(layout, p)] for p in domain(layout) if at(layout, p)]
        return tab_set([panes])

    def build(self, trace: Trace, case: CaseBuilder) -> None:
        init = trace.states[0]
        layout = init["durable"]["state"]["layout"]
        holding = [p for p in domain(layout) if at(layout, p)]
        if len(holding) != 1:
            raise GenError("OwnershipConvergence: the initial layout must hold its tabs in one pane")
        fixture = Fixture(case)
        fixture.pane(holding[0], at(layout, holding[0]))
        case.state(fixture.last, self.abstract(init))
        for i in range(1, len(trace.states)):
            pre, post, lab = trace.states[i - 1], trace.states[i], trace.label(i)
            name = lab["name"]
            if name == "Commit":
                self.commit(case, fixture, i, pre, post)
            elif name == "OwnerReceive":
                m = lab["m"]
                decided = pre["durable"]["applied"] | pre["durable"]["rejected"]
                if m["op"]["id"] in decided:
                    if m["op"]["kind"] == "write":
                        raise Unmapped(f"{self.spec.name}:op/write")
                    case.exercised.add(f"{self.spec.name}:OwnerReceive/replay")
                    step = case.replay(f"m{i:02d}-retry", m["op"]["id"],
                                       f"TLA step {i + 1} OwnerReceive({self.describe(m['op'])}) of a decided key: "
                                       f"answered from the ledger")
                    case.state(step, self.abstract(post))
                else:
                    case.exercised.add(f"{self.spec.name}:OwnerReceive")
            elif name == "OwnerRestart":
                case.exercised.add(f"{self.spec.name}:OwnerRestart")
                step = case.restart(f"m{i:02d}-restart", f"TLA step {i + 1} OwnerRestart: the store is durable, "
                                                         f"the staged op is lost")
                case.state(step, self.abstract(post))
            else:
                case.exercised.add(f"{self.spec.name}:{name}")

    @staticmethod
    def describe(op: Mapping[str, Any]) -> str:
        ident = f"{op['id'][0]}.{op['id'][1]}"
        if op["kind"] == "move":
            return f"move {op['tab']} to {op['pane']}, id {ident}"
        if op["kind"] == "close":
            return f"close {op['tab']}, id {ident}"
        return f"write {op['target']}, id {ident}"

    def commit(self, case: CaseBuilder, fixture: Fixture, i: int, pre: Mapping[str, Any],
               post: Mapping[str, Any]) -> None:
        staged = pre["staged"]
        op, valid = staged["m"]["op"], staged["valid"]
        kind = op["kind"]
        if kind == "write":
            raise Unmapped(f"{self.spec.name}:op/write")
        layout = pre["durable"]["state"]["layout"]
        error = None if valid else "selector.not_found"
        note = f"TLA step {i + 1} Commit({self.describe(op)}): {'applied' if valid else 'rejected'}"
        case.exercised.add(f"{self.spec.name}:Commit")
        tab = fixture.tabs[op["tab"]]
        key = f"{op['id'][0]}-{op['id'][1]}"
        if kind == "close":
            case.exercised.add(f"{self.spec.name}:op/close")
            step = case.call(f"m{i:02d}-close", "tab.close", {"tab": tab}, error=error, note=note, key=key)
        else:
            pane = op["pane"]
            # The fixture makes only the pane that holds the tabs; any other pane is empty in the model, and
            # an emptied pane is gone in the daemon.
            if pane not in fixture.panes or (valid and not at(layout, pane)):
                raise Unmapped(f"{self.spec.name}:op/move-to-empty-pane")
            case.exercised.add(f"{self.spec.name}:op/move")
            index = len(at(layout, pane))
            if valid:
                src = next(p for p in domain(layout) if op["tab"] in at(layout, p))
                if src != pane:
                    raise GenError("OwnershipConvergence: a move between two panes that hold tabs")
                new = daemon_move(at(layout, pane), at(layout, pane), op["tab"], index, True)[1]
                if new != list(at(post["durable"]["state"]["layout"], pane)):
                    raise GenError(f"OwnershipConvergence: tab.move to the end does not give the model's layout at "
                                   f"step {i + 1}")
            step = case.call(f"m{i:02d}-move", "tab.move", {"tab": tab},
                             {"destination_workspace": fixture.workspace, "destination_screen": fixture.screen,
                              "destination_pane": fixture.panes[pane], "index": index},
                             error=error, note=note, key=key)
        case.remember(op["id"], step)
        case.owner_steps += 1
        case.state(step, self.abstract(post))


# -- LayoutRows ---------------------------------------------------------------------------------------------


class RowsProjector:
    """LayoutRows.tla: the owner's Process of split, newcol (a full-height row), move, close and dock, and
    keyed replays. Column, row and pane ids are erased (the spec's Sig); tab identity is kept."""

    reads = {"own", "req", "done", "commits"}

    def __init__(self, spec: SpecMap):
        self.spec = spec

    @staticmethod
    def live(own: Mapping[str, Any]) -> Tuple[List[Any], List[Any], List[Any], List[Any]]:
        cols = list(own["cols"])
        rows = [r for c in cols for r in at(own["rowsOf"], c)]
        panes = [p for r in rows for p in at(own["panesOf"], r)]
        tabs = [t for p in panes for t in at(own["tabsOf"], p)]
        return cols, rows, panes, tabs

    def abstract(self, own: Mapping[str, Any], maxh: int) -> Dict[str, Any]:
        cols = []
        for c in own["cols"]:
            rows = []
            for r in at(own["rowsOf"], c):
                if at(own["height"], r) != maxh:
                    raise Unmapped(f"{self.spec.name}:op/heights")
                rows.append([[tab_token(t) for t in at(own["tabsOf"], p)] for p in at(own["panesOf"], r)])
            cols.append({"dock": str(at(own["dock"], c)), "rows": rows})
        return {"cols": cols}

    @staticmethod
    def has_fresh(used: frozenset, size: int) -> bool:
        return bool(set(range(1, size + 1)) - set(used))

    @staticmethod
    def fresh(used: frozenset, size: int) -> int:
        return min(set(range(1, size + 1)) - set(used))

    def result(self, own: Mapping[str, Any], op: Mapping[str, Any], k: Mapping[str, Any]) -> Tuple[str, str]:
        """LayoutRows' Apply guards for the mapped kinds: (done|noop|reject, why)."""
        cols, _, panes, tabs = self.live(own)
        kind = op["k"]
        if kind == "split":
            if op["p"] not in panes:
                return "reject", "dead"
            if not (self.has_fresh(own["usedP"], k["NPanes"]) and self.has_fresh(own["usedT"], k["NTabs"])):
                return "reject", "pool"
            return "done", ""
        if kind == "newcol":
            if op["p"] not in panes:
                return "reject", "dead"
            pools = ((own["usedC"], k["NCols"]), (own["usedR"], k["NRows"]), (own["usedP"], k["NPanes"]),
                     (own["usedT"], k["NTabs"]))
            if not all(self.has_fresh(used, size) for used, size in pools):
                return "reject", "pool"
            return "done", ""
        if kind == "move":
            if op["t"] not in tabs or op["p"] not in panes:
                return "reject", "dead"
            src = next(p for p in panes if op["t"] in at(own["tabsOf"], p))
            if src == op["p"] and at(own["tabsOf"], src)[-1] == op["t"]:
                return "noop", ""
            return "done", ""
        if kind == "close":
            return ("done", "") if op["t"] in tabs else ("reject", "dead")
        if kind == "dock":
            if op["c"] not in cols:
                return "reject", "dead"
            if at(own["dock"], op["c"]) == op["e"]:
                return "noop", ""
            docks = {c: (op["e"] if c == op["c"] else ("none" if op["e"] != "none" and at(own["dock"], c) == op["e"]
                                                         else at(own["dock"], c))) for c in cols}
            return ("done", "") if "none" in docks.values() else ("reject", "all-docked")
        raise GenError(f"LayoutRows: no Apply guard for {kind}")

    def build(self, trace: Trace, case: CaseBuilder) -> None:
        k = trace.constants
        if k.get("FRAME"):
            raise GenError("LayoutRows: FRAME = TRUE configs have no product op for their docks")
        maxh = k["MaxH"]
        init = trace.states[0]["own"]
        fixture = Fixture(case)
        previous = None
        for c in init["cols"]:
            rows = at(init["rowsOf"], c)
            if len(rows) != 1:
                raise GenError("LayoutRows: an initial column with more than one row has no fixture")
            for n, p in enumerate(at(init["panesOf"], rows[0])):
                fixture.pane(p, at(init["tabsOf"], p), after=previous,
                             how="right" if n else ("viewport" if previous is not None else "right"))
                previous = p
        docked = [(i, c) for i, c in enumerate(init["cols"]) if at(init["dock"], c) != "none"]
        if docked:
            get = case.read("fx-columns", "screen.get", {"screen": fixture.screen}, "the column ids for the docks")
            for i, c in docked:
                fixture.last = case.call(f"fx-dock-{i + 1}", "column.update", {"screen": fixture.screen},
                                         {"column": ref(get, f"/layout/root/columns/{i}/column_id"), "dock": True,
                                          "edge": str(at(init["dock"], c))})
        case.state(fixture.last, self.abstract(init, maxh))
        for i in range(1, len(trace.states)):
            pre, post, lab = trace.states[i - 1], trace.states[i], trace.label(i)
            if lab["name"] != "Process":
                case.exercised.add(f"{self.spec.name}:{lab['name']}")
                continue
            gone = pre["req"] - post["req"]
            if len(gone) != 1:
                raise GenError(f"LayoutRows: Process at step {i + 1} took {len(gone)} requests")
            q = next(iter(gone))
            self.process(case, fixture, i, pre, post, q, k, maxh)

    def process(self, case: CaseBuilder, fixture: Fixture, i: int, pre: Mapping[str, Any], post: Mapping[str, Any],
                q: Mapping[str, Any], k: Mapping[str, Any], maxh: int) -> None:
        own, op, key = pre["own"], q["op"], q["key"]
        kind = op["k"]
        if q in pre["done"]:
            if key not in case.calls:
                raise Unmapped(f"{self.spec.name}:op/{kind}")
            case.exercised.add(f"{self.spec.name}:Process/replay")
            step = case.replay(f"m{i:02d}-retry", key, f"TLA step {i + 1} Process of the used key {key}: no change")
            case.state(step, self.abstract(post["own"], maxh))
            return
        if self.spec.unmapped(kind):
            raise Unmapped(f"{self.spec.name}:op/{kind}")
        if kind == "newcol" and op["h"] != maxh:
            raise Unmapped(f"{self.spec.name}:op/newcol-short-row")
        verdict, why = self.result(own, op, k)
        committed = at(post["commits"], key) == at(pre["commits"], key) + 1
        if committed != (verdict == "done") or (verdict != "done" and post["own"] != own):
            raise GenError(f"LayoutRows: the Apply guards of gen_tla.py disagree with the spec at step {i + 1} "
                           f"({kind}: {verdict})")
        if why == "pool":
            raise Unmapped(f"{self.spec.name}:reject/id-pool")
        cols = list(own["cols"])
        if kind == "dock" and (op["c"] not in cols or len(cols) < 2):
            raise Unmapped(f"{self.spec.name}:op/dock-no-column")
        case.exercised.add(f"{self.spec.name}:op/{kind}")
        case.exercised.add(f"{self.spec.name}:Process")
        note = f"TLA step {i + 1} Process(key {key}: {self.describe(op)}): {verdict}"
        error = None if verdict != "reject" else ("validation.invalid" if why == "all-docked" else "selector.not_found")
        pane = fixture.panes.get(op["p"]) if op["p"] else None
        if kind in ("split", "newcol"):
            params: Dict[str, Any] = {"direction": "right"}
            if kind == "newcol":
                params["viewport_width"] = VIEWPORT_WIDTH
            step = case.call(f"m{i:02d}-{kind}", "pane.split", {"pane": pane}, params, error=error, note=note)
            if verdict == "done":
                fixture.panes[self.fresh(own["usedP"], k["NPanes"])] = value_ref(step, "pane_id")
                fixture.tabs[self.fresh(own["usedT"], k["NTabs"])] = value_ref(step, "tab_id")
        elif kind == "move":
            dest = at(own["tabsOf"], op["p"]) if op["p"] in self.live(own)[2] else ()
            step = case.call(f"m{i:02d}-move", "tab.move", {"tab": fixture.tabs[op["t"]]},
                             {"destination_workspace": fixture.workspace, "destination_screen": fixture.screen,
                              "destination_pane": pane, "index": len(dest)}, error=error, note=note)
        elif kind == "close":
            step = case.call(f"m{i:02d}-close", "tab.close", {"tab": fixture.tabs[op["t"]]}, error=error, note=note)
        else:
            get = case.read(f"m{i:02d}-columns", "screen.get", {"screen": fixture.screen},
                            f"TLA step {i + 1}: the column ids before the dock")
            params = {"column": ref(get, f"/layout/root/columns/{cols.index(op['c'])}/column_id")}
            params.update({"dock": False} if op["e"] == "none" else {"dock": True, "edge": str(op["e"])})
            step = case.call(f"m{i:02d}-dock", "column.update", {"screen": fixture.screen}, params, error=error,
                             note=note)
        case.remember(key, step)
        case.owner_steps += 1
        case.state(step, self.abstract(post["own"], maxh))

    @staticmethod
    def describe(op: Mapping[str, Any]) -> str:
        kind = op["k"]
        if kind in ("split", "newcol"):
            return f"{kind} pane {op['p']}"
        if kind == "move":
            return f"move tab {op['t']} to pane {op['p']}"
        if kind == "close":
            return f"close tab {op['t']}"
        return f"dock column {op['c']} {op['e']}"


# -- closefocus ---------------------------------------------------------------------------------------------


class StripProjector:
    """closefocus.tla, Kind = "strip": columns of panes. Close, Focus and Create are product calls; the
    focus after them is view state (`view`), which no product checks yet (the action map's `viewExcluded`)."""

    reads = {"cols", "focus"}

    def __init__(self, spec: SpecMap):
        self.spec = spec

    def build(self, trace: Trace, case: CaseBuilder) -> None:
        if trace.constants.get("Kind") != "strip":
            raise GenError("closefocus: only Kind = \"strip\" maps to daemon panes")
        init = trace.states[0]
        fixture = Fixture(case)
        names: Dict[str, str] = {}
        previous = None
        for col in init["cols"]:
            for n, item in enumerate(col):
                names[item] = f"p:{item}"
                fixture.pane(names[item], [], after=previous, how="down" if n else "viewport")
                previous = names[item]
        none = ModelValue(str(trace.constants.get("None", "none")))

        def abstract(state: Mapping[str, Any]) -> Dict[str, Any]:
            focus = state["focus"]
            return {"cols": [[names[item] for item in col] for col in state["cols"]],
                    "view": {"focus": None if focus == none else names[focus]}}

        step = case.call("fx-focus", "pane.focus", {"pane": fixture.panes[names[init["focus"]]]},
                         note="the initial focus")
        case.state(step, abstract(init))
        made: Dict[str, int] = {}
        for i in range(1, len(trace.states)):
            pre, post, lab = trace.states[i - 1], trace.states[i], trace.label(i)
            name = lab["name"]
            case.exercised.add(f"{self.spec.name}:{name}")
            if name not in ("Close", "Focus", "Create"):
                continue
            item = lab["p"]
            note = f"TLA step {i + 1} {name}({item})"
            if name == "Close":
                step = case.call(f"m{i:02d}-close", "pane.close", {"pane": fixture.panes[names[item]]},
                                 note=note + (" (focused)" if pre["focus"] == item else ""))
            elif name == "Focus":
                step = case.call(f"m{i:02d}-focus", "pane.focus", {"pane": fixture.panes[names[item]]}, note=note)
            else:
                made[item] = made.get(item, 1) + 1
                names[item] = f"p:{item}.{made[item]}" if f"p:{item}" in fixture.panes else f"p:{item}"
                step = case.call(f"m{i:02d}-create", "pane.split", {"pane": fixture.panes[names[pre["focus"]]]},
                                 {"direction": "right", "viewport_width": VIEWPORT_WIDTH, "focus": True}, note=note)
                fixture.panes[names[item]] = value_ref(step, "pane_id")
            case.owner_steps += 1
            case.state(step, abstract(post))


PROJECTORS: Dict[str, Callable[[SpecMap], Any]] = {
    "rows": RowsProjector,
    "tabs": lambda spec: OwnershipProjector(spec) if spec.name == "OwnershipConvergence" else TabLayoutProjector(spec),
    "strip": StripProjector,
}


def case_document(spec: SpecMap, trace: Trace, case: CaseBuilder) -> Dict[str, Any]:
    kinds = sorted({s["args"]["method"] for s in case.steps if s["op"] == "resource.call" and not s["id"].startswith("fx-")}
                   | ({"restart"} if "restart" in case.requires else set()))
    invariants = [
        f"generated by {GENERATOR} ({TASK}) from a TLC simulate trace of plans/cmux-next/formal/{spec.module}.tla "
        f"({trace.origin}); tests/oracle/corpus/{SUITE}/{expected_name(spec.slug)} holds the model's abstract state "
        f"after each mapped step, which `gen_tla.py check` compares to the run's daemon facet",
        "each owner step expects the model's outcome: ok, selector.not_found for an op on a closed tab or a "
        "removed pane, validation.invalid for a dock that leaves no scrolling column; a replayed key answers as "
        "its first call did and changes nothing",
    ]
    if spec.view:
        invariants.append(f"view (not checked yet, {spec.view_excluded}): {spec.view}")
    return {
        "$schema": CASE_SCHEMA_REF,
        "corpusVersion": 1,
        "id": case.case_id,
        "suite": SUITE,
        "title": f"TLA {spec.name} ({trace.config.name}): {', '.join(kinds)}"[:200],
        "surface": "cmux-next-daemon",
        "source": {"repo": "manaflow-ai/cmux", "ref": "$RUN", "artifact": "$RUN"},
        "environment": {},
        "fixture": {"seed": f"tla.{case.case_id}", "network": "offline", "clock": "virtual"},
        "preconditions": ["hermetic state root", "no other cmux-tui on the state root"],
        "requires": sorted(case.requires),
        "platforms": ["linux", "mac"],
        "steps": case.steps,
        "invariants": invariants,
        "teardown": ["stop the case daemon", "verify the socket and state root are gone"],
    }


# ---------------------------------------------------------------------------------------------------------
# Generation


@dataclass
class ConfigStats:
    simulated: int = 0
    kept: int = 0
    duplicates: int = 0
    no_owner_step: int = 0
    dropped: Dict[str, int] = field(default_factory=dict)
    batches: int = 0

    def as_json(self) -> Dict[str, Any]:
        return {"simulated": self.simulated, "batches": self.batches, "kept": self.kept,
                "duplicates": self.duplicates, "no_owner_step": self.no_owner_step,
                "dropped": dict(sorted(self.dropped.items())), "dropped_total": sum(self.dropped.values())}


def coverage_items(spec: SpecMap) -> Dict[str, Optional[str]]:
    """Coverage key -> None (must be exercised) or the reason it is excluded."""
    items: Dict[str, Optional[str]] = {}
    for action in spec.actions:
        reason = action.excluded or (action.why if action.map == "unmapped" else "")
        if spec.excluded and not reason:
            reason = f"{spec.excluded} ({action.why})" if action.why else spec.excluded
        items[f"{spec.name}:{action.label}"] = reason or None
    for kind, entry in spec.ops.items():
        items[f"{spec.name}:op/{kind}"] = entry.get("unmapped") or spec.excluded or None
    if spec.view:
        items[f"{spec.name}:view"] = spec.view_excluded
    if spec.race is not None and not spec.excluded and any(a.map == "restart" for a in spec.actions):
        items[f"{spec.name}:restart-race"] = None
    return items


def label_check(spec: SpecMap, jar: Path) -> Tuple[Dict[str, Any], Dict[str, int]]:
    """An excluded spec makes no cases, but its configs are simulated so the map still covers its Next
    exactly (an unlabeled step is a GenError in `simulate`); returns the trace stats and the labels taken."""
    stats: Dict[str, Any] = {}
    exercised: Dict[str, int] = {}
    for config in spec.configs:
        simulated = 0
        for batch in range(config.max_batches):
            for trace in simulate(spec, config, batch, jar, set()):
                simulated += 1
                for label in {trace.label(i)["name"] for i in range(1, len(trace.states))}:
                    key = f"{spec.name}:{label}"
                    exercised[key] = exercised.get(key, 0) + 1
        stats[config.name] = {"simulated": simulated, "batches": config.max_batches, "kept": 0}
    return stats, exercised


def generate(specs: Mapping[str, SpecMap], only: Sequence[str] = (), jar: Optional[Path] = None,
             log: Callable[[str], None] = lambda _: None) -> Dict[str, Any]:
    """{relative path: JSON value} of the whole suite; coverage.json's `expectations` holds the lines the
    generator owns in Expectations.d/tla.txt."""
    jar = jar or tlc_jar()
    files: Dict[str, Any] = {}
    coverage: Dict[str, Any] = {"generator": GENERATOR, "actionmap": str(ACTIONMAP.relative_to(REPO)),
                                "actionmap_sha256": sha256_file(ACTIONMAP), "tlc": "tla2tools %s (tlc.sh pin)" % tlc_pin()[0],
                                "suite": SUITE, "total": 0, "covered": 0, "verdicts": "not run",
                                "distinct": "product_digest: the steps without ids, notes or TLA step numbers, step "
                                            "refs by position, plus the model's states",
                                "excluded": {}, "missing": [], "specs": {}, "expectations": []}
    for name, spec in specs.items():
        if only and name not in only and spec.slug not in only:
            continue
        expected: Dict[str, Any] = {}
        exercised: Dict[str, int] = {}
        spec_stats: Dict[str, Any] = {}
        if spec.excluded:
            spec_stats, exercised = label_check(spec, jar)
            log(f"{name}: excluded, labels checked on {sum(s['simulated'] for s in spec_stats.values())} traces")
        else:
            spec_stats, exercised = generate_spec(spec, jar, files, expected, coverage["expectations"], log)
            files[expected_name(spec.slug)] = {
                "schema": EXPECTED_SCHEMA, "spec": name, "generator": GENERATOR,
                "description": "The model's abstract state after each mapped step of each case. Tokens t:<id> are "
                               "the spec's tab ids and p:<id> its pane ids; `check` binds each to one daemon id per "
                               "case. {\"set\": [...]} is unordered. `view` is client view state no product checks "
                               "yet (coverage.json `excluded`).",
                "cases": expected,
            }
        missing = []
        for key, reason in coverage_items(spec).items():
            coverage["total"] += 1
            if reason:
                coverage["excluded"][key] = reason
            elif exercised.get(key):
                coverage["covered"] += 1
            else:
                missing.append(key)
        coverage["missing"].extend(missing)
        entry: Dict[str, Any] = {"cfgs": {c.name: c.cfg for c in spec.configs},
                                 "cases": sum(c.cases for c in spec.configs), "traces": spec_stats,
                                 "exercised": dict(sorted(exercised.items()))}
        if spec.excluded:
            entry["excluded"] = spec.excluded
        coverage["specs"][name] = entry
    coverage["expectations"].sort()
    files[COVERAGE] = coverage
    return files


def generate_spec(spec: SpecMap, jar: Path, files: Dict[str, Any], expected: Dict[str, Any], lines: List[str],
                  log: Callable[[str], None]) -> Tuple[Dict[str, Any], Dict[str, int]]:
    """The cases of one spec into `files` and `expected`, its restart-race lines into `lines`; returns the trace
    stats per config and the coverage keys exercised."""
    projector = PROJECTORS[spec.projection](spec)
    race = spec.race if any(a.map == "restart" for a in spec.actions) else None
    seen: Set[str] = set()
    exercised: Dict[str, int] = {}
    spec_stats: Dict[str, Any] = {}
    race_kept = 0
    for config in spec.configs:
        stats = ConfigStats()
        kept_here = 0
        for batch in range(config.max_batches):
            if kept_here >= config.cases:
                break
            stats.batches += 1
            for trace in simulate(spec, config, batch, jar, projector.reads):
                if kept_here >= config.cases:
                    break
                stats.simulated += 1
                case_id = f"{spec.slug}-{config.name}-{kept_here + 1:04d}"
                case = CaseBuilder(case_id, race.methods if race else ())
                try:
                    projector.build(trace, case)
                except Unmapped as drop:
                    stats.dropped[drop.key] = stats.dropped.get(drop.key, 0) + 1
                    continue
                if not case.owner_steps:
                    stats.no_owner_step += 1
                    continue
                digest = product_digest(case.steps, case.expected)
                if digest in seen:
                    stats.duplicates += 1
                    continue
                if race is not None and case.race_steps:
                    if len(case.race_steps) != 1 or race_kept >= race.keep:
                        key = f"{spec.name}:restart-race ({race.issue})"
                        stats.dropped[key] = stats.dropped.get(key, 0) + 1
                        continue
                    race_kept += 1
                    case.exercised.add(f"{spec.name}:restart-race")
                    lines.append(f"{race.issue} [ daemon ] {SUITE}/{case_id}/{case.race_steps[0]} [ Pass Failure ]")
                seen.add(digest)
                kept_here += 1
                stats.kept += 1
                for key in case.exercised:
                    exercised[key] = exercised.get(key, 0) + 1
                files[f"{case_id}.json"] = case_document(spec, trace, case)
                expected[case_id] = case.expected
        if kept_here < config.cases:
            raise GenError(f"{spec.name} ({config.cfg}): {kept_here} product-distinct mapped traces after "
                           f"{stats.batches} batches of {config.batch}, {config.cases} wanted; raise a bound "
                           f"(`constants`), maxBatches or batch")
        spec_stats[config.name] = stats.as_json()
        log(f"{spec.name} {config.name}: {stats.kept} kept of {stats.simulated} simulated, "
            f"{sum(stats.dropped.values())} dropped, {stats.duplicates} duplicates")
    if race is not None and race_kept < race.keep:
        raise GenError(f"{spec.name}: {race_kept} restart-race cases, {race.keep} wanted (restartRace.keep)")
    return spec_stats, exercised


# The generator owns one block of the suite's expectations file (expectations.py); lines outside it are kept,
# as gen_daemon_ops.py does for daemon-ops.
EXPECTATIONS_BEGIN_PREFIX = f"# BEGIN {GENERATOR}:"
EXPECTATIONS_BEGIN = f"{EXPECTATIONS_BEGIN_PREFIX} the restart-race cases of coverage.json (action map restartRace)"
EXPECTATIONS_END = f"# END {GENERATOR}"
EXPECTATIONS_HEADER = (f"# {SUITE} expectations (format: scripts/cmux-next/oracle/expectations.py).\n"
                       f"# {GENERATOR} writes the block below from coverage.json: edit the action map,\n"
                       "# not the block. Lines outside the block are kept.\n")


def render_expectations(existing: str, lines: Sequence[str]) -> str:
    """`existing` with the generator's block replaced by `lines` (or appended, with a header for a new file)."""
    block = "\n".join([EXPECTATIONS_BEGIN, *lines, EXPECTATIONS_END]) + "\n"
    begin, end = existing.find(EXPECTATIONS_BEGIN_PREFIX), existing.find(EXPECTATIONS_END)
    if begin >= 0 and end > begin:
        tail = existing[end + len(EXPECTATIONS_END):]
        return existing[:begin] + block + (tail[1:] if tail.startswith("\n") else tail)
    if begin >= 0 or end >= 0:
        raise GenError(f"the {SUITE} expectations file has one of the generator's block markers without the other")
    if not existing.strip():
        return EXPECTATIONS_HEADER + block
    return existing + ("" if existing.endswith("\n") else "\n") + block


def dump(value: Any) -> str:
    return json.dumps(value, indent=2, ensure_ascii=False) + "\n"


def drift(out: Path, files: Mapping[str, Any], only_slugs: Sequence[str]) -> List[str]:
    problems = []
    for rel, value in sorted(files.items()):
        path = out / rel
        if not path.is_file():
            problems.append(f"{rel}: missing")
        elif path.read_text(encoding="utf-8") != dump(value):
            problems.append(f"{rel}: differs from a fresh generation")
    for path in sorted(out.rglob("*.json")) if out.is_dir() else []:
        rel = path.relative_to(out).as_posix()
        if rel not in files and owns(rel, only_slugs):
            problems.append(f"{rel}: not generated")
    return problems


def write(out: Path, files: Mapping[str, Any], only_slugs: Sequence[str]) -> Tuple[int, int]:
    written = removed = 0
    for rel, value in files.items():
        path = out / rel
        path.parent.mkdir(parents=True, exist_ok=True)
        text = dump(value)
        if not path.is_file() or path.read_text(encoding="utf-8") != text:
            path.write_text(text, encoding="utf-8")
            written += 1
    for path in sorted(out.rglob("*.json")):
        rel = path.relative_to(out).as_posix()
        if rel not in files and owns(rel, only_slugs):
            path.unlink()
            removed += 1
    return written, removed


# ---------------------------------------------------------------------------------------------------------
# Checking a run against the model


def leaves(node: Mapping[str, Any]) -> List[Mapping[str, Any]]:
    kind = node.get("kind")
    if kind == "leaf":
        return [node]
    if kind == "split":
        return leaves(node["first"]) + leaves(node["second"])
    raise GenError(f"layout node kind {kind!r} inside a column")


def screen_columns(root: Mapping[str, Any]) -> List[Tuple[str, List[Mapping[str, Any]]]]:
    """(dock edge or none, leaves) per column; a split tree is one column."""
    if root.get("kind") == "viewport":
        return [(str((col.get("dock") or {}).get("edge", "none")), leaves(col["root"])) for col in root["columns"]]
    return [("none", leaves(root))]


def project(projection: str, facets: Mapping[str, Any]) -> Dict[str, Any]:
    """The run's daemon facet in the shape of the spec's abstract state."""
    daemon = facets.get("daemon") or {}
    if daemon.get("status") == "not-comparable" or "session" not in daemon:
        raise GenError("the checkpoint has no comparable daemon facet")
    session = daemon["session"]
    screens = session.get("screens") or []
    if projection == "tabs":
        groups: Dict[str, List[List[str]]] = {}
        for screen in screens:
            for _, column in screen_columns(screen["layout"]["root"]):
                for leaf in column:
                    groups.setdefault(screen["workspace_id"], []).append(list(leaf["tab_ids"]))
        return tab_set([groups[w] for w in sorted(groups)])
    if len(screens) > 1:
        raise GenError(f"{len(screens)} screens; the {projection} specs have one")
    columns = screen_columns(screens[0]["layout"]["root"]) if screens else []
    if projection == "rows":
        return {"cols": [{"dock": dock, "rows": [[list(leaf["tab_ids"]) for leaf in column]]}
                         for dock, column in columns]}
    state: Dict[str, Any] = {"cols": [[leaf["pane_id"] for leaf in column] for _, column in columns]}
    layout = facets.get("layout")
    if isinstance(layout, dict) and layout.get("status") != "not-comparable" and layout.get("screens") is not None:
        active = [s for s in layout["screens"] if s.get("active")]
        state["view"] = {"focus": active[0].get("focusedPane") if active else None}
    return state


TOKEN_KINDS = {"t:": "tab#", "p:": "pane#"}


def match(want: Any, got: Any, binding: Dict[str, str]) -> Optional[Dict[str, str]]:
    """The binding of model tokens to run ids extended so `got` is `want`, or None. Sets ({"set": [...]})
    match in any order (a small backtracking search)."""
    if isinstance(want, str) and want[:2] in TOKEN_KINDS:
        if not isinstance(got, str) or not got.startswith(TOKEN_KINDS[want[:2]]):
            return None
        bound = binding.get(want)
        if bound is not None:
            return binding if bound == got else None
        if got in binding.values():
            return None
        return {**binding, want: got}
    if isinstance(want, dict) and set(want) == {"set"}:
        if not (isinstance(got, dict) and set(got) == {"set"} and len(got["set"]) == len(want["set"])):
            return None
        return match_set(list(want["set"]), list(got["set"]), binding)
    if isinstance(want, dict):
        if not isinstance(got, dict) or set(want) != set(got):
            return None
        for key in sorted(want):
            result = match(want[key], got[key], binding)
            if result is None:
                return None
            binding = result
        return binding
    if isinstance(want, list):
        if not isinstance(got, list) or len(want) != len(got):
            return None
        for w, g in zip(want, got):
            result = match(w, g, binding)
            if result is None:
                return None
            binding = result
        return binding
    return binding if want == got else None


def match_set(want: List[Any], got: List[Any], binding: Dict[str, str]) -> Optional[Dict[str, str]]:
    if not want:
        return binding
    for index, candidate in enumerate(got):
        result = match(want[0], candidate, binding)
        if result is not None:
            rest = match_set(want[1:], got[:index] + got[index + 1:], result)
            if rest is not None:
                return rest
    return None


@dataclass
class CheckResult:
    case: str
    status: str
    problems: List[str]
    unchecked: List[str]


def check_result(result: Mapping[str, Any], case: Mapping[str, Any], expected: Sequence[Mapping[str, Any]],
                 projection: str) -> CheckResult:
    """A run's result (driver_daemon.py run-case) against the model: the run passed (every outcome as the
    model says) and its settled daemon facet after each mapped step is the model's abstract state."""
    case_id = case["id"]
    problems: List[str] = []
    unchecked: List[str] = []
    if result.get("status") != "Pass":
        problems.append(f"run {result.get('status')} at {result.get('step')}: {(result.get('message') or '')[:400]}")
    settled = {c["step"]: c["snapshot"] for c in result.get("checkpoints") or [] if c.get("checkpoint") == "settled"}
    binding: Dict[str, str] = {}
    for entry in expected:
        snapshot = settled.get(entry["step"])
        if snapshot is None:
            if not problems:
                problems.append(f"{entry['step']}: no settled checkpoint")
            continue
        want = dict(entry["state"])
        try:
            got = project(projection, snapshot.get("facets") or {})
        except GenError as error:
            problems.append(f"{entry['step']}: {error}")
            continue
        if "view" in want and "view" not in got:
            want.pop("view")
            if "view" not in unchecked:
                unchecked.append("view")
        new = match(want, got, binding)
        if new is None:
            problems.append(f"{entry['step']}: model {json.dumps(want, sort_keys=True)} but the run has "
                            f"{json.dumps(got, sort_keys=True)}")
            continue
        binding = new
    status = "Pass" if not problems else "Failure"
    return CheckResult(case_id, status, problems, unchecked)


def load_expected(case_path: Path) -> List[Mapping[str, Any]]:
    case_id = case_path.stem
    path = case_path.parent / expected_name(slug_of(case_id))
    data = json.loads(path.read_text(encoding="utf-8"))
    if case_id not in data["cases"]:
        raise GenError(f"{path}: no expected states for {case_id}")
    return data["cases"][case_id]


def projection_of(case_path: Path, specs: Mapping[str, SpecMap]) -> str:
    slug = slug_of(case_path.stem)
    for spec in specs.values():
        if spec.slug == slug:
            return spec.projection
    raise GenError(f"{case_path}: {slug} is no spec slug of the action map")


def run_one(binary: str, case_path: Path, isolation: str, out: Optional[Path],
            specs: Mapping[str, SpecMap]) -> CheckResult:
    done = subprocess.run([sys.executable, "-I", str(DRIVER_DAEMON), "run-case", "--binary", binary, str(case_path),
                           "--isolation", isolation], capture_output=True, text=True, check=False)
    try:
        result = json.loads(done.stdout)
    except ValueError:
        return CheckResult(case_path.stem, "Crash", [f"driver_daemon.py exit {done.returncode}: {done.stderr[-600:]}"],
                           [])
    if out is not None:
        (out / f"{case_path.stem}.result.json").write_text(json.dumps(result, indent=1), encoding="utf-8")
    case = json.loads(case_path.read_text(encoding="utf-8"))
    return check_result(result, case, load_expected(case_path), projection_of(case_path, specs))


def cmd_check(argv: Sequence[str]) -> int:
    parser = argparse.ArgumentParser(prog="gen_tla.py check")
    parser.add_argument("result", type=Path, help="driver_daemon.py run-case result JSON")
    parser.add_argument("case", type=Path, help="the case file, tests/oracle/corpus/tla/<case>.json")
    args = parser.parse_args(argv)
    specs = load_actionmap()
    case = json.loads(args.case.read_text(encoding="utf-8"))
    outcome = check_result(json.loads(args.result.read_text(encoding="utf-8")), case, load_expected(args.case),
                           projection_of(args.case, specs))
    print(json.dumps({"case": outcome.case, "status": outcome.status, "problems": outcome.problems,
                      "unchecked": outcome.unchecked}, indent=1))
    return 0 if outcome.status == "Pass" else 1


def cmd_vm(argv: Sequence[str]) -> int:
    parser = argparse.ArgumentParser(prog="gen_tla.py vm", description="run the tla cases on a VM daemon and check "
                                                                       "them against the model")
    parser.add_argument("--binary", required=True, help="cmux-tui (linux_run.sh build prints it)")
    parser.add_argument("--corpus", type=Path, default=DEFAULT_OUT)
    parser.add_argument("--spec", action="append", default=[], help="spec name or slug (repeatable; default all)")
    parser.add_argument("--jobs", type=int, default=min(64, os.cpu_count() or 4))
    parser.add_argument("--limit", type=int, default=0, help="at most N cases per spec")
    parser.add_argument("--isolation", default="auto")
    parser.add_argument("--out", type=Path, help="write each run result here")
    args = parser.parse_args(argv)
    if args.corpus.name == SUITE:
        corpus_store.ensure(args.corpus.parent, [SUITE])  # the pinned suite (tests/oracle/corpus-store.json)
    specs = load_actionmap()
    wanted = {s for value in args.spec for s in value.split(",") if s}
    paths: List[Path] = []
    for spec in specs.values():
        if wanted and spec.name not in wanted and spec.slug not in wanted:
            continue
        cases = sorted(args.corpus.glob(f"{spec.slug}-*.json"))
        paths.extend(cases[:args.limit] if args.limit else cases)
    if args.out:
        args.out.mkdir(parents=True, exist_ok=True)
    results: List[CheckResult] = []
    by_spec: Dict[str, List[int]] = {}
    with concurrent.futures.ThreadPoolExecutor(max_workers=max(1, args.jobs)) as pool:
        for path, outcome in zip(paths, pool.map(lambda p: run_one(args.binary, p, args.isolation, args.out, specs),
                                                 paths)):
            results.append(outcome)
            by_spec.setdefault(slug_of(path.stem), [0, 0])[0 if outcome.status == "Pass" else 1] += 1
            if outcome.status != "Pass":
                print(f"{outcome.case}: {outcome.status}: {'; '.join(outcome.problems)[:1200]}")
    for slug, (passed, failed) in sorted(by_spec.items()):
        print(f"{slug}: {passed} pass, {failed} fail")
    unchecked = sorted({u for r in results for u in r.unchecked})
    if unchecked:
        print(f"not checked: {', '.join(unchecked)} (no product checks it yet; coverage.json `excluded`)")
    return 0 if all(r.status == "Pass" for r in results) else 1


def cmd_generate(argv: Sequence[str]) -> int:
    parser = argparse.ArgumentParser(prog="gen_tla.py", description=__doc__.split("\n\n")[0])
    parser.add_argument("--out", type=Path, default=DEFAULT_OUT, help="the suite directory (default: the corpus)")
    parser.add_argument("--spec", action="append", default=[], help="spec name or slug (repeatable; default all)")
    parser.add_argument("--check", action="store_true", help="exit 1 when --out differs from a fresh generation")
    args = parser.parse_args(argv)
    try:
        if args.check and args.out.name == SUITE:
            corpus_store.ensure(args.out.parent, [SUITE])  # the pinned suite (tests/oracle/corpus-store.json), before TLC
        specs = load_actionmap()
        only = [s for value in args.spec for s in value.split(",") if s]
        unknown = [s for s in only if s not in specs and s not in {m.slug for m in specs.values()}]
        if unknown:
            raise GenError(f"no spec {', '.join(unknown)} in the action map")
        slugs = [m.slug for n, m in specs.items() if n in only or m.slug in only]
        files = generate(specs, only, log=lambda line: print(f"gen_tla: {line}", file=sys.stderr))
        # The Expectations block comes from every spec: a run of some specs leaves it alone.
        expectations_file = expectations_path(args.out)
        existing = expectations_file.read_text(encoding="utf-8") if expectations_file.is_file() else ""
        rendered = existing if only else render_expectations(existing, files[COVERAGE]["expectations"])
        if only:
            files.pop(COVERAGE)
        if args.check:
            problems = drift(args.out, files, slugs)
            if rendered != existing:
                problems.append(f"{expectations_file.name}: the generated block differs from coverage.json")
            for problem in problems[:50]:
                print(f"gen_tla: {problem}", file=sys.stderr)
            print(f"gen_tla: {len(files)} files, {'stale' if problems else 'up to date'}")
            return 1 if problems else 0
        written, removed = write(args.out, files, slugs)
        corpus_store.mark_local(args.out)  # the repo suite now differs from its pin until `corpus_store.py publish tla`
        if rendered != existing:
            expectations_file.parent.mkdir(parents=True, exist_ok=True)
            expectations_file.write_text(rendered, encoding="utf-8")
            written += 1
    except (GenError, corpus_store.StoreError) as error:
        print(f"gen_tla: {error}", file=sys.stderr)
        return 2
    print(f"gen_tla: {len(files)} files, {written} written, {removed} removed")
    return 0


def main(argv: Optional[Sequence[str]] = None) -> int:
    argv = list(sys.argv[1:] if argv is None else argv)
    if argv and argv[0] == "check":
        return cmd_check(argv[1:])
    if argv and argv[0] == "vm":
        return cmd_vm(argv[1:])
    return cmd_generate(argv)


if __name__ == "__main__":
    sys.exit(main())
