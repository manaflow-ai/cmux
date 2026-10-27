#!/usr/bin/env python3
"""The oracle's mutation smoke run: `oracle.py selftest --mutants` (p15-oracle-115).

Spec: plans/cmux-next/chrome-parity/p15-oracle.md, section 3F "Mutation strength", acceptance item 7 and task 115.
Stdlib only, Python 3.9+, safe under `python3 -I`.

    oracle.py selftest --mutants [--ref REF] [--product app|daemon]... [--mutant GLOB]... [--out DIR]
                                 [--jobs N] [--dry-run] [--json]

For each seeded patch mutant of tests/oracle/mutants/<product>/ (task 026, patch_mutants.py), the smallest
selection that can catch it runs first, base against base+patch at one SHA, and the first one that catches it
ends that mutant's search:

1. `exercising`: every case the product can run whose steps call one of the names in the patch's `Exercises`
   header, in any suite: a resource.call `method`, an action.run `action`, the action a `key` step's stroke or
   chord is bound to by default, the action or operation a `cli` argv or an `mcp` tool runs, or a facet a
   `snapshot` step reads (Entrypoints: the action catalog export plans/cmux-next/action-surfaces.json, the
   operation list cmux-tui/spec/resource-operations-v2.json and the corpus's mcp/_tools.json).
2. `suite`: the whole suite of the patch's `Suite` header, when it holds other cases than rung 1.

A rung that selects no case is left out. Each rung is one diff run with the diff retry policy
(oracle.DEFAULT_RETRY_LIMIT): a case that passes on retry is Flaky and diff.py leaves it out. A case that passes
every time with a value that changes between two processes is caught by the control instead: the first time a
rung of a selection diverges, the same selection runs once more without the patch (SHA against SHA), and a case
that diverges there does not count for any mutant of that selection. A mutant is:
- caught: a rung's comparison has a divergent case that its control does not have: a checkpoint value or a case
  result (diff.py compares the result too, so a Failure the base does not have, an invariant failure of the run
  included, is a divergence);
- missed: every rung compared cases and none diverged, or no case exercises the fault at all. Each miss is one
  MQ-mutants corpus-gap line (OUT/corpus-gaps.jsonl): the suite to extend and what its new case must do;
- unviable: the patch does not apply at the SHA, or the patched head does not compile (a rustc or Swift compiler
  error in the build's output while the base side built); it counts as not caught, and its line asks for the
  fault to be written again against the new code (tests/oracle/mutants/README.md);
- unmeasured: no rung caught it and at least one could not compare (refused, incomplete, infra error, a head
  build that failed with no compiler error, or a diverged rung whose control did not compare).

Gate (spec 5, item 7): over the full checked-in set, >= 19/20 caught and >= 9/10 per product; with
`--product`, that product's 9/10; with `--mutant`, every selected mutant. Unmeasured mutants count both ways:
the run passes when the gate holds without them, fails when it fails with all of them caught, and is
undecided otherwise.

Backends (both apply the patch to the head side only, in the job's own worktree; nothing goes into the sources):
- daemon, on the Linux VM: `linux_run.sh diff SHA SHA --mutant PATCH --suite S --out DIR -- --retry-limit 3
  [--filter IDS]` through the runnerd queue (one base run per selection is shared by every mutant);
  DIR/comparison.json.
- app, on the fleet: `fleet.py diff --base SHA --head SHA --head-mutant tests/oracle/mutants/app/NAME.patch
  --suite S [--filter IDS] --retry-limit 3 --out DIR`; DIR/compare/comparison.json. The patch must be in the
  commit's tree (fleet.py checks).

Outputs (outside the checkout; default /tmp/oracle/mutants/<run id>): mutants.json (cmux-oracle-mutants-v1:
every mutant, its rungs, the comparisons and the gate), corpus-gaps.jsonl, one directory per rung run and
controls/<product>/ (one per selection that diverged).
Exit: 0 pass, 1 fail, 2 bad usage, 3 undecided (an unmeasured mutant could change the verdict).

Chrome reference: docs/testing/mutation_testing.md (the Gerrit Mutation Testing plugin reports a change's
surviving mutants as findings to act on); test selection by what a change touches is the CQ's analyze step
(testing/buildbot/filters, `gn analyze`), here the patch's own `Exercises` header. cargo mutants (task 191)
stays the broad measure; these 20 faults are the smoke set every product run must still catch.
"""

from __future__ import annotations

import argparse
import concurrent.futures
import fnmatch
import glob
import hashlib
import json
import platform as platform_mod
import re
import subprocess
import sys
import threading
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Callable, Dict, List, Optional, Sequence, Tuple

HERE = Path(__file__).resolve().parent
if str(HERE) not in sys.path:
    sys.path.insert(0, str(HERE))

import driver_app  # noqa: E402  (KEY_NAMES: a case-v1 key name as debug.key sends it)
import gen_entrypoints  # noqa: E402  (tool_name: an action's MCP tool, cli/mcp/action_tools.rs)
import oracle  # noqa: E402  (corpus, selection, retry policy, out-dir rule)
import patch_mutants  # noqa: E402  (the seeded mutants of task 026)

TASK = "p15-oracle-115"
SCHEMA = "cmux-oracle-mutants-v1"
GAP_SCHEMA = "cmux-oracle-corpus-gap-v1"
QUEUE = "MQ-mutants"
REPO = oracle.REPO
DEFAULT_OUT_BASE = Path("/tmp/oracle/mutants")
LINUX_RUN = HERE / "linux_run.sh"
FLEET = HERE / "fleet.py"
DEFAULT_JOBS = 10
# The platform each product's cases run on (oracle.select_cases).
PLATFORM = {"daemon": "linux", "app": "mac"}
# Spec 5, item 7: caught / total for the whole set and for each product.
TOTAL_RATE = (19, 20)
PRODUCT_RATE = (9, 10)

CAUGHT, SURVIVED, MISSED, UNVIABLE, UNMEASURED = "caught", "survived", "missed", "unviable", "unmeasured"
PASS, FAIL, UNDECIDED = "pass", "fail", "undecided"
EXIT_PASS, EXIT_FAIL, EXIT_USAGE, EXIT_UNDECIDED = 0, 1, 2, 3
EXITS = {PASS: EXIT_PASS, FAIL: EXIT_FAIL, UNDECIDED: EXIT_UNDECIDED}


# ------------------------------------------------------------------------------------------------ selection


def exercise_names(exercises: str) -> frozenset:
    """The names in an `Exercises` header: `closePane (layout.splitSizing even)` -> closePane, layout.splitSizing,
    even. Words that are no method, action or facet select nothing, so prose in the header is harmless."""
    return frozenset(token for token in re.split(r"[\s,;()]+", exercises) if token)


Stroke = Tuple[str, frozenset]

# AppKit's function-key characters and the control characters as action-surfaces.json writes a shortcut's key, by
# their keybindings.json names (scripts/ci/defaults_guard.py FUNCTION_KEYS and NAMED_KEYS).
WIRE_KEY_NAMES = {"": "up", "": "down", "": "left", "": "right", "": "forwarddelete",
                  "": "home", "": "end", "": "pageup", "": "pagedown", "\t": "tab",
                  "\r": "return", "\n": "return", " ": "space", "\x1b": "escape", "\x7f": "delete", "\x08": "delete"}
MODIFIER_NAMES = {"cmd": "cmd", "command": "cmd", "ctrl": "ctrl", "control": "ctrl", "opt": "opt", "alt": "opt",
                  "option": "opt", "shift": "shift"}
# A case-v1 key name that is not the catalog's: driver_app.KEY_NAMES (what debug.key gets), plus the spellings
# keybindings.json takes for return and escape.
CASE_KEY_NAMES = {**driver_app.KEY_NAMES, "enter": "return", "esc": "escape"}
DIGITS = "123456789"


def case_stroke(text: str) -> Optional[Stroke]:
    """A case-v1 keystroke (`cmd+opt+left`) as (key, modifiers), or None for a modifier this grammar does not have."""
    *mods, key = text.lower().split("+")
    if any(m not in MODIFIER_NAMES for m in mods):
        return None
    return CASE_KEY_NAMES.get(key, key), frozenset(MODIFIER_NAMES[m] for m in mods)


def wire_stroke(shortcut: Any) -> Optional[Stroke]:
    """An action-surfaces.json shortcut ({"key", "modifiers"}) as (key, modifiers)."""
    if not isinstance(shortcut, dict) or not isinstance(shortcut.get("key"), str):
        return None
    key = shortcut["key"]
    mods = [MODIFIER_NAMES.get(m, m) for m in shortcut.get("modifiers") or ()]
    return WIRE_KEY_NAMES.get(key, key.lower()), frozenset(mods)


@dataclass
class Entrypoints:
    """What a key, cli or mcp step runs, by name: the default keymap and CLI and MCP names of the action catalog
    export (plans/cmux-next/action-surfaces.json, the table the app's key router resolves a debug.key stroke
    with), the daemon's operations (cmux-tui/spec/resource-operations-v2.json) and the app methods the MCP tool
    list names (the corpus's mcp/_tools.json). A key resolves in every context its binding's `when` names: a
    selection may hold a case that does not reach the action, never leave out one that does."""

    strokes: Dict[Stroke, set] = field(default_factory=dict)
    chords: Dict[Tuple[Stroke, ...], set] = field(default_factory=dict)
    cli: Dict[Tuple[str, ...], set] = field(default_factory=dict)
    tools: Dict[str, set] = field(default_factory=dict)
    methods: set = field(default_factory=set)
    actions: set = field(default_factory=set)

    SURFACES = REPO / "plans" / "cmux-next" / "action-surfaces.json"
    OPERATIONS = REPO / "cmux-tui" / "spec" / "resource-operations-v2.json"

    @classmethod
    def load(cls, corpus: Path = oracle.DEFAULT_CORPUS, surfaces: Path = SURFACES,
             operations: Path = OPERATIONS) -> "Entrypoints":
        try:
            actions = json.loads(surfaces.read_text(encoding="utf-8"))["actions"]
            ops = json.loads(operations.read_text(encoding="utf-8"))["operations"]
        except (OSError, ValueError, KeyError) as error:
            raise oracle.UsageError(f"the action catalog or the operation list does not load: {error}") from None
        found = cls()
        for action in actions:
            ident = action.get("id")
            if not isinstance(ident, str):
                continue
            found.actions.add(ident)
            found.bind_keys(ident, action)
            cli_name = action.get("cli_name")
            if isinstance(cli_name, str) and cli_name.split():
                found.cli.setdefault(tuple(cli_name.split()), set()).add(ident)
                tool = gen_entrypoints.tool_name(cli_name)
                if tool:
                    found.tools.setdefault(tool, set()).add(ident)
        for op in ops:
            found.methods.add(op)
            found.tools.setdefault(op.replace(".", "_"), set()).add(op)
        try:
            listed = json.loads((corpus / "mcp" / "_tools.json").read_text(encoding="utf-8"))
        except (OSError, ValueError):
            listed = {}
        for entry in listed.get("excluded") or ():
            if isinstance(entry, dict) and entry.get("kind") == "app_method" and isinstance(entry.get("name"), str):
                found.methods.update(name.strip() for name in entry["name"].split(",") if "*" not in name)
        return found

    def bind_keys(self, ident: str, action: Dict[str, Any]) -> None:
        shortcut = action.get("default_shortcut")
        stroke = wire_stroke(shortcut)
        if stroke:
            keys = [stroke[0]]
            if shortcut.get("family") == "digits":
                keys = list(DIGITS)
            for key in keys:
                self.strokes.setdefault((key, stroke[1]), set()).add(ident)
        sequences = [alias.get("keys") for alias in action.get("default_aliases") or () if isinstance(alias, dict)]
        sequences.append(action.get("default_chord"))
        for sequence in sequences:
            if not isinstance(sequence, list) or not sequence:
                continue
            strokes = tuple(wire_stroke(item) for item in sequence)
            if None in strokes:
                continue
            table = self.strokes if len(strokes) == 1 else self.chords
            table.setdefault(strokes[0] if len(strokes) == 1 else strokes, set()).add(ident)

    def of_keys(self, keys: Any) -> set:
        """The actions a key step's strokes run: each stroke's binding, and each chord its strokes spell in a row."""
        strokes = [case_stroke(k) for k in keys if isinstance(k, str)] if isinstance(keys, list) else []
        names: set = set()
        for index, stroke in enumerate(strokes):
            if stroke is None:
                continue
            names |= self.strokes.get(stroke, set())
            for chord, actions in self.chords.items():
                if tuple(strokes[index:index + len(chord)]) == chord:
                    names |= actions
        return names

    def of_cli(self, argv: Any) -> set:
        """The action whose CLI name a cli step's words start with (gen_entrypoints.py's `<cli name> --flags`), and
        each operation or app method its command words name as `<noun>.<words>` (`settings set` is settings.set)."""
        if not isinstance(argv, list):
            return set()
        words = [w for w in argv if isinstance(w, str)]
        while words and words[0].startswith("-"):
            words = words[1:]
        command = []
        for word in words:
            if word.startswith("-"):
                break
            command.append(word)
        names: set = set()
        for end in range(1, len(command) + 1):
            names |= self.cli.get(tuple(command[:end]), set())
        for start in range(1, len(command)):
            for end in range(start + 1, len(command) + 1):
                dotted = ".".join([command[0], *command[start:end]])
                if dotted in self.methods:
                    names.add(dotted)
        return names

    def of_tool(self, tool: Any) -> set:
        """What an mcp step's tool runs: an `app_<cli words>` action or an operation (gen_mcp.py's names)."""
        return set(self.tools.get(tool, set())) if isinstance(tool, str) else set()


def called_names(case: oracle.Case, entrypoints: Entrypoints) -> frozenset:
    """What a case's steps call: each resource.call `method` and action.run `action`, the actions its key, cli and
    mcp steps run (Entrypoints), and the facets its snapshot steps read."""
    names: set = set()
    for step in case.data.get("steps") or ():
        if not isinstance(step, dict):
            continue
        args = step.get("args") if isinstance(step.get("args"), dict) else {}
        names.update(value for key in ("method", "action") for value in (args.get(key),) if isinstance(value, str))
        op = step.get("op")
        if op == "key":
            names |= entrypoints.of_keys(args.get("keys"))
        elif op == "cli":
            names |= entrypoints.of_cli(args.get("argv"))
        elif op == "mcp":
            names |= entrypoints.of_tool(args.get("tool"))
        elif op == "snapshot":
            names.update(f for f in args.get("facets") or () if isinstance(f, str))
    return frozenset(names)


@dataclass(frozen=True)
class Rung:
    """One selection a mutant runs against: `exercising` (case ids) or `suite` (a whole suite)."""

    label: str
    suite: str
    cases: Tuple[str, ...]
    filtered: bool

    def filter_arg(self) -> List[str]:
        return ["--filter", ",".join(glob.escape(case) for case in self.cases)] if self.filtered else []

    def record(self) -> Dict[str, Any]:
        return {"rung": self.label, "suite": self.suite, "cases": len(self.cases)}


def ladder(mutant: patch_mutants.Mutant, cases: Sequence[oracle.Case], entrypoints: Entrypoints) -> List[Rung]:
    """The mutant's rungs, smallest first; a rung that selects nothing or repeats the one before is left out."""
    runnable, _ = oracle.select_cases(cases, suites=(), filters=(), product=mutant.product,
                                      platform=PLATFORM[mutant.product])
    wanted = exercise_names(mutant.exercises)
    exercising = tuple(sorted(case.id for case in runnable if called_names(case, entrypoints) & wanted))
    suite = tuple(sorted(case.id for case in runnable if case.suite == mutant.suite))
    rungs = []
    if exercising:
        rungs.append(Rung("exercising", "all", exercising, filtered=True))
    if suite and set(suite) != set(exercising):
        rungs.append(Rung("suite", mutant.suite, suite, filtered=False))
    return rungs


# ------------------------------------------------------------------------------------------------ judging


@dataclass(frozen=True)
class Outcome:
    """One rung's comparison: caught, survived, unviable or unmeasured, with its evidence."""

    status: str
    detail: str = ""
    divergent: Tuple[str, ...] = ()
    compared: int = 0
    comparison: Optional[str] = None
    noise: Tuple[str, ...] = ()  # divergent cases left out: they diverged in the unpatched control too


def judge_comparison(path: Path) -> Outcome:
    """A comparison.json that oracle.compare_views wrote. A refusal or nothing compared is no evidence either way."""
    try:
        document = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError) as error:
        return Outcome(UNMEASURED, f"no readable comparison ({error})")
    if not isinstance(document, dict):
        return Outcome(UNMEASURED, f"{path}: not a comparison object")
    divergent = tuple(document.get("divergent") or ())
    compared = int(document.get("compared") or 0)
    where = str(path)
    if document.get("refused"):
        return Outcome(UNMEASURED, f"refused: {document['refused']}", compared=compared, comparison=where)
    if divergent:
        return Outcome(CAUGHT, f"{len(divergent)} of {compared} compared cases diverged", divergent, compared, where)
    if compared and document.get("diff_exit") == oracle.DIFF_OK:
        return Outcome(SURVIVED, f"{compared} compared cases, none diverged", (), compared, where)
    return Outcome(UNMEASURED, f"diff.py exit {document.get('diff_exit')} with {compared} compared cases",
                   compared=compared, comparison=where)


Runner = Callable[[Sequence[str], Path], int]


def run_logged(argv: Sequence[str], log: Path) -> int:
    """Runs one backend command with its output in `log` (the rung's directory)."""
    log.parent.mkdir(parents=True, exist_ok=True)
    with log.open("w", encoding="utf-8") as handle:
        handle.write("$ " + " ".join(argv) + "\n")
        handle.flush()
        return subprocess.run(list(argv), cwd=str(REPO), stdout=handle, stderr=subprocess.STDOUT,
                              check=False).returncode


def log_tail(log: Path, lines: int = 3) -> str:
    try:
        text = log.read_text(encoding="utf-8", errors="replace")
    except OSError:
        return ""
    return " | ".join(line.strip() for line in text.strip().splitlines()[-lines:])


# Positive evidence that the patched sources do not compile (rustc's coded diagnostics or cargo's count of them; a
# Swift compiler diagnostic). Any other failed head build (a timeout, a killed compiler, a full disk, the queue or
# the fleet) is no verdict on the patch.
RUSTC_ERROR = re.compile(r"error\[E\d{4}\]|could not compile `[^`]+`.* due to \d+ previous errors?")
SWIFTC_ERROR = re.compile(r"\.swift:\d+:\d+: error:")


def read_text(path: Path) -> str:
    try:
        return path.read_text(encoding="utf-8", errors="replace")
    except OSError:
        return ""


def first_match(pattern: "re.Pattern[str]", text: str) -> Optional[str]:
    return next((line.strip()[:300] for line in text.splitlines() if pattern.search(line)), None)


class Backend:
    """Runs base against base+patch (or, for the control, base against base) for one rung and judges it."""

    product = ""

    def __init__(self, runner: Runner = run_logged) -> None:
        self.runner = runner

    def command(self, mutant: Optional[patch_mutants.Mutant], rung: Rung, sha: str, out: Path) -> List[str]:
        """The diff of SHA against SHA with the patch on the head side; `mutant` None is the unpatched control."""
        raise NotImplementedError

    def comparison(self, out: Path) -> Path:
        raise NotImplementedError

    def unavailable(self) -> Optional[str]:
        """Why this backend cannot run here, or None."""
        return None

    def head_build_failure(self, out: Path, log: Path) -> Optional[Outcome]:
        """When the base side built and the patched head did not: UNVIABLE on a compiler error, else UNMEASURED."""
        return None

    def judge(self, out: Path, code: int, log: Path, *, patched: bool) -> Outcome:
        if patched and not self.comparison(out).is_file():
            failed = self.head_build_failure(out, log)
            if failed is not None:
                return failed
        outcome = judge_comparison(self.comparison(out))
        if outcome.status == UNMEASURED and outcome.comparison is None:
            return Outcome(UNMEASURED, f"exit {code}, {outcome.detail}: {log_tail(log)}")
        return outcome

    def check(self, mutant: Optional[patch_mutants.Mutant], rung: Rung, sha: str, out: Path) -> Outcome:
        reason = self.unavailable()
        if reason:
            return Outcome(UNMEASURED, reason)
        out.mkdir(parents=True, exist_ok=True)
        log = out / "command.log"
        code = self.runner(self.command(mutant, rung, sha, out), log)
        return self.judge(out, code, log, patched=mutant is not None)


class VmBackend(Backend):
    """Daemon mutants: linux_run.sh diff in the runnerd queue on the Linux VM."""

    product = "daemon"

    def __init__(self, runner: Runner = run_logged, system: Optional[str] = None) -> None:
        super().__init__(runner)
        self.system = system or platform_mod.system()

    def unavailable(self) -> Optional[str]:
        if self.system != "Linux":
            return "daemon mutants build and run in the Linux VM's queue (linux_run.sh); nothing was queued"
        return None

    def command(self, mutant: Optional[patch_mutants.Mutant], rung: Rung, sha: str, out: Path) -> List[str]:
        patch = ["--mutant", str(mutant.path)] if mutant is not None else []
        return ["bash", str(LINUX_RUN), "diff", sha, sha, *patch, "--suite", rung.suite,
                "--out", str(out), "--", "--retry-limit", str(oracle.DEFAULT_RETRY_LIMIT), *rung.filter_arg()]

    def comparison(self, out: Path) -> Path:
        return out / "comparison.json"

    def head_build_failure(self, out: Path, log: Path) -> Optional[Outcome]:
        # linux_run.sh copies a side's build receipt only after that build succeeded, and runnerd replays the last
        # lines of a failed job's log (cargo's errors) into the command's output.
        if not (out / "build-base.json").is_file() or (out / "build-head.json").is_file():
            return None
        error = first_match(RUSTC_ERROR, read_text(log))
        if error:
            return Outcome(UNVIABLE, f"the patched head does not compile: {error}")
        return Outcome(UNMEASURED, f"the patched head build failed with no compiler error in its log (a timeout, a "
                                   f"kill, the disk or the queue): {log_tail(log)}")


class FleetBackend(Backend):
    """App mutants: fleet.py diff, both sides on one worker, the patch applied by scripts/measure/oracle.sh."""

    product = "app"

    def command(self, mutant: Optional[patch_mutants.Mutant], rung: Rung, sha: str, out: Path) -> List[str]:
        patch: List[str] = []
        if mutant is not None:
            path = mutant.path.resolve()
            patch = ["--head-mutant", path.relative_to(REPO).as_posix() if REPO in path.parents else str(path)]
        return [sys.executable, "-I", str(FLEET), "diff", "--product", "app", "--base", sha, "--head", sha,
                *patch, "--suite", rung.suite, *rung.filter_arg(),
                "--retry-limit", str(oracle.DEFAULT_RETRY_LIMIT), "--out", str(out)]

    def comparison(self, out: Path) -> Path:
        return out / "compare" / "comparison.json"

    def head_build_failure(self, out: Path, log: Path) -> Optional[Outcome]:
        # fleet.json (fleet.py fleet_record): the base side merged and a head shard's step failed. `cmux-ci run`
        # streams the step's log, oracle.sh's compiler errors included, into the shard's step.log.
        try:
            sides = json.loads((out / "fleet.json").read_text(encoding="utf-8")).get("sides") or {}
        except (OSError, ValueError, AttributeError):
            return None
        base, head = sides.get("base") or {}, sides.get("head") or {}
        failed = [s for s in head.get("shards") or () if isinstance(s, dict) and s.get("state") == "failed"]
        if not base.get("merged") or head.get("merged") or not failed:
            return None
        for shard in failed:
            error = first_match(SWIFTC_ERROR, read_text(out / "shards" / "head" / str(shard.get("index")) / "step.log"))
            if error:
                return Outcome(UNVIABLE, f"the patched head does not compile (step {shard.get('step_id')}): {error}")
        return Outcome(UNMEASURED, f"the patched head's step failed with no compiler error in its log: "
                                   f"{failed[0].get('error') or failed[0].get('state')}")


class Controls:
    """One unpatched SHA-against-SHA comparison per selection, run the first time a mutant's rung diverges and shared
    by every mutant with that selection. A case that diverges there differs between two runs of one build (spec 5
    item 6 allows some), so its divergence is no catch: Chrome's CQ retries a failing test without the patch and
    does not blame the change for a failure that repeats there (the model diff.py cites)."""

    def __init__(self, out: Path) -> None:
        self.out = out
        self._lock = threading.Lock()  # guards _runs only; the control runs outside it
        self._runs: Dict[Tuple[Any, ...], "concurrent.futures.Future[Outcome]"] = {}

    def directory(self, product: str, rung: Rung) -> Path:
        digest = hashlib.sha256("\n".join(rung.cases).encode("utf-8")).hexdigest()[:12]
        return self.out / "controls" / product / f"control-{rung.label}-{rung.suite}-{digest}"

    def outcome(self, backend: Backend, rung: Rung, sha: str) -> Outcome:
        key = (backend.product, rung.suite, rung.cases, rung.filtered)
        with self._lock:
            future = self._runs.get(key)
            owner = future is None
            if owner:
                future = self._runs[key] = concurrent.futures.Future()
        assert future is not None
        if owner:
            try:
                future.set_result(backend.check(None, rung, sha, self.directory(backend.product, rung)))
            except BaseException as error:
                future.set_exception(error)
                raise
        return future.result()


def discount(outcome: Outcome, control: Outcome) -> Outcome:
    """A diverged rung less the cases that diverged in its selection's unpatched control."""
    if control.status not in (CAUGHT, SURVIVED):
        return Outcome(UNMEASURED, f"{outcome.detail}, but the unpatched control did not compare ({control.detail})",
                       outcome.divergent, outcome.compared, outcome.comparison)
    noise = set(control.divergent)
    counted = tuple(case for case in outcome.divergent if case not in noise)
    left_out = tuple(case for case in outcome.divergent if case in noise)
    note = (f"; {len(left_out)} more also diverged without the patch ({control.comparison}) and do not count"
            if left_out else "")
    if counted:
        return Outcome(CAUGHT, f"{len(counted)} of {outcome.compared} compared cases diverged{note}", counted,
                       outcome.compared, outcome.comparison, left_out)
    return Outcome(SURVIVED, f"{outcome.compared} compared cases, none diverged with the patch alone{note}", (),
                   outcome.compared, outcome.comparison, left_out)


# ------------------------------------------------------------------------------------------------ one mutant


@dataclass
class Result:
    mutant: patch_mutants.Mutant
    rungs: List[Rung]
    status: str = UNMEASURED
    reason: str = ""
    catcher: Optional[Rung] = None
    tried: List[Dict[str, Any]] = field(default_factory=list)

    def record(self) -> Dict[str, Any]:
        m = self.mutant
        return {"id": m.id, "product": m.product, "suite": m.suite, "exercises": m.exercises, "fault": m.fault,
                "patch": str(m.path), "status": self.status, "reason": self.reason,
                "caughtBy": self.catcher.record() if self.catcher else None,
                "rungs": [rung.record() for rung in self.rungs], "tried": self.tried}


def rung_dir(out: Path, mutant: patch_mutants.Mutant, index: int, rung: Rung) -> Path:
    return out / mutant.product / mutant.name / f"{index}-{rung.label}"


def measure(mutant: patch_mutants.Mutant, rungs: Sequence[Rung], sha: str, backend: Backend, out: Path,
            apply_error: Optional[str] = None, controls: Optional[Controls] = None) -> Result:
    """Runs the rungs smallest first and stops at the first catch (or at a patch that cannot be built). A rung that
    diverges counts only the cases that did not also diverge in its selection's unpatched control."""
    controls = controls or Controls(out)
    result = Result(mutant, list(rungs))
    if apply_error:
        result.status, result.reason = UNVIABLE, apply_error
        return result
    if not rungs:
        result.status = MISSED
        result.reason = (f"no {mutant.product} case calls {', '.join(sorted(exercise_names(mutant.exercises)))} "
                         f"and suite {mutant.suite} has no {mutant.product} case")
        return result
    unmeasured: List[str] = []
    for index, rung in enumerate(rungs):
        outcome = backend.check(mutant, rung, sha, rung_dir(out, mutant, index, rung))
        control: Optional[Outcome] = None
        if outcome.status == CAUGHT:
            control = controls.outcome(backend, rung, sha)
            outcome = discount(outcome, control)
        result.tried.append({**rung.record(), "status": outcome.status, "detail": outcome.detail,
                             "compared": outcome.compared, "divergent": list(outcome.divergent),
                             "noise": list(outcome.noise), "comparison": outcome.comparison,
                             "control": control.comparison if control else None})
        if outcome.status == CAUGHT:
            result.status, result.reason, result.catcher = CAUGHT, outcome.detail, rung
            return result
        if outcome.status == UNVIABLE:
            result.status, result.reason = UNVIABLE, outcome.detail
            return result
        if outcome.status == UNMEASURED:
            unmeasured.append(f"{rung.label}: {outcome.detail}")
    if unmeasured:
        result.status, result.reason = UNMEASURED, "; ".join(unmeasured)
    else:
        result.status = MISSED
        result.reason = "; ".join(f"{t['rung']} ({t['cases']} cases): {t['detail']}" for t in result.tried)
    return result


def gap_line(result: Result, sha: str) -> Optional[Dict[str, Any]]:
    """The MQ-mutants queue line of a mutant that was not caught: a corpus gap, or a stale patch to rewrite."""
    m = result.mutant
    base = {"schema": GAP_SCHEMA, "queue": QUEUE, "task": TASK, "sha": sha, "mutant": m.id, "product": m.product,
            "suite": m.suite, "exercises": m.exercises, "fault": m.fault, "reason": result.reason,
            "tried": [rung.record() for rung in result.rungs]}
    if result.status == MISSED:
        return {**base, "kind": "corpus-gap",
                "title": f"{m.suite}: add a case that catches {m.id}",
                "work": f"a {m.suite} case that calls {m.exercises} where this fault changes the settled state "
                        f"or the result ({m.fault})"}
    if result.status == UNVIABLE:
        return {**base, "kind": "stale-mutant",
                "title": f"rewrite {m.id} against {sha[:12]}",
                "work": "write the same fault again against the current code, with the same name "
                        "(tests/oracle/mutants/README.md)"}
    return None


# ------------------------------------------------------------------------------------------------ the gate


@dataclass(frozen=True)
class Requirement:
    scope: str
    need: int
    of: int
    caught: int
    unmeasured: int

    @property
    def verdict(self) -> str:
        if self.caught >= self.need:
            return PASS
        return UNDECIDED if self.caught + self.unmeasured >= self.need else FAIL

    def record(self) -> Dict[str, Any]:
        return {"scope": self.scope, "need": self.need, "of": self.of, "caught": self.caught,
                "unmeasured": self.unmeasured, "verdict": self.verdict}


def at_least(rate: Tuple[int, int], total: int) -> int:
    """The smallest count that keeps `rate` of `total`: 19/20 of 20 is 19, 9/10 of 10 is 9."""
    caught, out_of = rate
    return -(-caught * total // out_of)


def requirements(results: Sequence[Result], *, full_products: Sequence[str], subset: bool) -> List[Requirement]:
    """Spec 5 item 7 over what was selected: a subset needs every mutant; each full product its 9/10; both
    full products together 19/20."""

    def requirement(scope: str, chosen: Sequence[Result], need: int) -> Requirement:
        return Requirement(scope, need, len(chosen), sum(r.status == CAUGHT for r in chosen),
                           sum(r.status == UNMEASURED for r in chosen))

    if subset:
        return [requirement("selected mutants", results, len(results))]
    out = []
    for product in full_products:
        chosen = [r for r in results if r.mutant.product == product]
        out.append(requirement(product, chosen, at_least(PRODUCT_RATE, len(chosen))))
    if len(full_products) == len(patch_mutants.PRODUCTS):
        out.append(requirement("all", results, at_least(TOTAL_RATE, len(results))))
    return out


def verdict_of(reqs: Sequence[Requirement]) -> str:
    verdicts = {req.verdict for req in reqs}
    if FAIL in verdicts:
        return FAIL
    return UNDECIDED if UNDECIDED in verdicts else PASS


# ------------------------------------------------------------------------------------------------ the run


def select_mutants(mutants: Sequence[patch_mutants.Mutant], products: Sequence[str],
                   globs: Sequence[str]) -> List[patch_mutants.Mutant]:
    return [m for m in mutants
            if m.product in products and (not globs or any(fnmatch.fnmatchcase(m.id, g) for g in globs))]


def default_backends(runner: Runner = run_logged) -> Dict[str, Backend]:
    return {"daemon": VmBackend(runner), "app": FleetBackend(runner)}


def write_json(path: Path, value: Any) -> None:
    tmp = path.with_name("." + path.name + ".tmp")
    tmp.write_text(json.dumps(value, indent=1, sort_keys=True) + "\n", encoding="utf-8")
    tmp.replace(path)


def run(*, ref: str, products: Sequence[str], globs: Sequence[str], root: Path, corpus: Path, out: Path,
        gaps_out: Optional[Path], jobs: int, dry_run: bool, backends: Dict[str, Backend],
        expected_per_product: Optional[int], log: Callable[[str], None] = print) -> Tuple[int, Dict[str, Any]]:
    sha = patch_mutants.resolve(ref)
    loaded, errors = patch_mutants.load(root)
    if errors:
        raise oracle.UsageError("the mutants do not load (patch_mutants.py check):\n  " + "\n  ".join(errors))
    if expected_per_product is not None:
        for product in products:
            count = sum(m.product == product for m in loaded)
            if count != expected_per_product:
                raise oracle.UsageError(f"{root / product}: {count} mutants; the smoke set has "
                                        f"{expected_per_product} per product (patch_mutants.py check)")
    mutants = select_mutants(loaded, products, globs)
    if not mutants:
        raise oracle.UsageError(f"no mutant of {', '.join(products)} matches {', '.join(globs) or '*'} under {root}")
    cases, case_errors = oracle.load_corpus(corpus)
    if case_errors:
        raise oracle.UsageError("the corpus does not load (oracle.py check):\n  " + "\n  ".join(case_errors[:20]))
    entrypoints = Entrypoints.load(corpus)
    plans = [(m, ladder(m, cases, entrypoints)) for m in mutants]
    controls = Controls(out)
    stale = {}
    for mutant in mutants:
        found = patch_mutants.apply_errors([mutant], sha)
        if found:
            stale[mutant.id] = "; ".join(found)
    log(f"oracle selftest --mutants ({TASK}) at {sha[:12]}: {len(mutants)} mutants, out {out}")
    if dry_run:
        for mutant, rungs in plans:
            steps = ", ".join(f"{r.label} {r.suite} ({len(r.cases)} cases)" for r in rungs) or "no case"
            log(f"  plan {mutant.id}: {steps}" + (f"; stale: {stale[mutant.id]}" if mutant.id in stale else ""))
            for index, rung in enumerate(rungs):
                backend = backends[mutant.product]
                log("    $ " + " ".join(backend.command(mutant, rung, sha, rung_dir(out, mutant, index, rung))))
                control = backend.command(None, rung, sha, controls.directory(mutant.product, rung))
                log("      control, once per selection when a rung diverges: $ " + " ".join(control))
        return EXIT_PASS, {"schema": SCHEMA, "sha": sha, "dryRun": True,
                           "plan": {m.id: [r.record() for r in rungs] for m, rungs in plans}}

    with concurrent.futures.ThreadPoolExecutor(max_workers=max(1, jobs)) as pool:
        futures = [pool.submit(measure, m, rungs, sha, backends[m.product], out, stale.get(m.id), controls)
                   for m, rungs in plans]
        results = [future.result() for future in futures]

    full = [p for p in products if not globs]
    reqs = requirements(results, full_products=full, subset=bool(globs))
    verdict = verdict_of(reqs)
    gaps = [line for line in (gap_line(r, sha) for r in results) if line is not None]
    gaps_path = gaps_out or out / "corpus-gaps.jsonl"
    gaps_path.parent.mkdir(parents=True, exist_ok=True)
    with gaps_path.open("w", encoding="utf-8") as handle:
        for line in gaps:
            handle.write(json.dumps(line, sort_keys=True) + "\n")
    document = {"schema": SCHEMA, "task": TASK, "ref": ref, "sha": sha, "products": list(products),
                "mutantGlobs": list(globs), "mutants": [r.record() for r in results],
                "gate": {"verdict": verdict, "requirements": [req.record() for req in reqs]},
                "corpusGaps": str(gaps_path), "exit": EXITS[verdict]}
    write_json(out / "mutants.json", document)
    for result in results:
        caught_by = f" by {result.catcher.label} {result.catcher.suite} ({len(result.catcher.cases)} cases)" \
            if result.catcher else ""
        log(f"  {result.status:<10} {result.mutant.id}{caught_by}: {result.reason}")
    for req in reqs:
        log(f"  gate {req.scope}: {req.caught}/{req.of} caught, need {req.need}"
            + (f", {req.unmeasured} unmeasured" if req.unmeasured else "") + f": {req.verdict}")
    log(f"mutants: {verdict}; {out / 'mutants.json'}; {len(gaps)} {QUEUE} lines in {gaps_path}")
    return EXITS[verdict], document


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="oracle.py selftest --mutants", description=__doc__.split("\n\n")[0])
    parser.add_argument("--ref", default="HEAD", help="the commit both sides build (default HEAD)")
    parser.add_argument("--product", action="append", choices=patch_mutants.PRODUCTS,
                        help="only this product's mutants (repeatable; default both)")
    parser.add_argument("--mutant", action="append", default=[], help="only mutants whose id matches this glob")
    parser.add_argument("--root", type=Path, default=patch_mutants.DEFAULT_ROOT, help="the mutants directory")
    parser.add_argument("--corpus", type=Path, default=oracle.DEFAULT_CORPUS)
    parser.add_argument("--out", type=Path, help=f"output dir outside the checkout (default {DEFAULT_OUT_BASE}/<run>)")
    parser.add_argument("--gaps-out", type=Path, help="the corpus-gap lines (default OUT/corpus-gaps.jsonl)")
    parser.add_argument("--jobs", type=int, default=DEFAULT_JOBS, help=f"mutants at once (default {DEFAULT_JOBS})")
    parser.add_argument("--dry-run", action="store_true", help="print each mutant's rungs and commands; run nothing")
    parser.add_argument("--json", action="store_true", help="print mutants.json")
    return parser


def main(argv: Optional[Sequence[str]] = None, backends: Optional[Dict[str, Backend]] = None) -> int:
    args = build_parser().parse_args(argv)
    products = tuple(dict.fromkeys(args.product or patch_mutants.PRODUCTS))
    out = args.out or DEFAULT_OUT_BASE / oracle.new_run_id()
    try:
        oracle.check_out_dir(out)
        out.mkdir(parents=True, exist_ok=True)
        expected = patch_mutants.EXPECTED_PER_PRODUCT if args.root.resolve() == patch_mutants.DEFAULT_ROOT else None
        code, document = run(ref=args.ref, products=products, globs=args.mutant, root=args.root, corpus=args.corpus,
                             out=out, gaps_out=args.gaps_out, jobs=args.jobs, dry_run=args.dry_run,
                             backends=backends or default_backends(), expected_per_product=expected,
                             log=(lambda line: print(line, file=sys.stderr)) if args.json else print)
    except (oracle.UsageError, patch_mutants.UsageError) as error:
        print(f"selftest --mutants: {error}", file=sys.stderr)
        return EXIT_USAGE
    if args.json:
        print(json.dumps(document, indent=1, sort_keys=True))
    return code


if __name__ == "__main__":
    sys.exit(main())
