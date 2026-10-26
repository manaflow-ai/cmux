"""Shared setup of the oracle's action cases and the every-action sweep (p15-oracle-046, phase 1: no move).

Spec: plans/cmux-next/chrome-parity/p15-oracle.md, section 3 and task 046. Stdlib only, Python 3.9+, safe under
`python3 -I` (the caller puts scripts/cmux-next/oracle on sys.path).

The sweep's setup and teardown stay where they are (scripts/cmux-next/every-action-sweep.py: Sweep.build, plan,
ready, restore, close_new, App, TagTeardown). `load_sweep` imports that script as a module, so the oracle drives
the same code; `every-action-sweep.py --plan-only` shows a later move changed no action's plan.

Per-family fixtures are the sibling modules action_fixtures/<family>.py (`*_test.py` are their tests). Each one
defines:

  FAMILY      the family slug (case-v1 `fixtures.setup`).
  CONTEXTS    {registry context key: factory}. The sweep calls each factory once per session run (and again after
              a relaunch) and keeps the ContextFixture it returns. `enter(driver)` runs where show() makes the base
              pane show a tab kind, before action.describe: it returns None, or why the context did not hold (the
              row's `gap` skip). It may run again before `leave` (the key-not-routed retry's second ready()) and
              then keeps what the first call made. `leave(driver)` runs in the restore before close_new whenever
              `enter` ran, also when the sample stopped after it; it returns None or a drift note. What `enter`
              made is an extra close_new closes like PREPARE's.
  PREPARE     {action id: [(action, args)]}, merged into the sweep's PREPARE (an id both name is refused).
  ARGUMENTS   {(action id, argument name): factory}: values for arguments the sweep's ARGUMENT_FIXTURES does not
              fill, required or not. The sweep calls each distinct factory once per session run (and again after a
              relaunch), so keys that share a factory share one ArgumentFixture. `value(driver, base)` runs in the
              row's plan, before ready(): it returns (value, None), or (None, why) for the row's `gap` skip.
  UNDO        {action id: (action, args)}: the inverse the restore runs after each sample of an action whose effect
              no restore sees (a default it set), merged into the sweep's UNDO (an id both name is refused).
  CLOSES      the gap ids this fixture closes. load_families refuses a CLOSES that is not exactly the `closed` ids of
              tests/oracle/gap-closures/<family>.json (the record p15-oracle-087 applies to every-action-gaps.json),
              and that file without a CLOSES.

`driver` is the sweep's narrow seam (SweepDriver): `run(action, args)` is action.run with focus (the PREPARE path),
`rpc(method, params)` one socket call, `wait(predicate, seconds)` its bounded poll. Replies are the raw socket
reply dicts.

Chrome reference (chromium/src): chrome/test/interaction/interactive_browser_test.h and
ui/base/interaction/interactive_test.h keep one setup and verb set that every interactive UI test composes, instead
of each suite owning its fixture; web_tests/VirtualTestSuites reruns one test list with extra setup, as the
families add contexts to one sweep.
"""

from __future__ import annotations

import importlib.util
import json
import re
import sys
from dataclasses import dataclass, field
from pathlib import Path
from types import ModuleType
from typing import Any, Callable, Dict, Iterable, List, Mapping, Optional, Protocol, Sequence, Tuple

HERE = Path(__file__).resolve().parent
SCRIPTS = HERE.parents[1]  # scripts/cmux-next
SWEEP = SCRIPTS / "every-action-sweep.py"
SWEEP_MODULE = "every_action_sweep"
GAP_CLOSURES = HERE.parents[3] / "tests" / "oracle" / "gap-closures"  # <family>.json per gap fixture family
FAMILY_SLUG = re.compile(r"^[a-z][A-Za-z0-9_]*$")


class FixtureError(ValueError):
    """A family module that does not load or does not hold the interface, or two families (or a family and the
    sweep) that claim the same context, PREPARE, ARGUMENTS or UNDO entry."""


class Driver(Protocol):
    def run(self, action: str, args: Optional[dict] = None, target: Optional[str] = None) -> Any: ...

    def rpc(self, method: str, params: Optional[dict] = None) -> Any: ...

    def wait(self, predicate: Callable[[], Any], seconds: float) -> Any: ...


class ContextFixture(Protocol):
    def enter(self, driver: Driver) -> Optional[str]: ...

    def leave(self, driver: Driver) -> Optional[str]: ...


class ArgumentFixture(Protocol):
    def value(self, driver: Driver, base: Mapping[str, Any]) -> Tuple[Any, Optional[str]]: ...


Step = Tuple[str, Dict[str, Any]]
ArgumentKey = Tuple[str, str]  # (action id, argument name), as the sweep's ARGUMENT_FIXTURES keys


@dataclass(frozen=True)
class Family:
    """One action_fixtures/<family>.py, checked."""

    name: str
    path: Path
    contexts: Mapping[str, Callable[[], ContextFixture]]
    prepare: Mapping[str, Tuple[Step, ...]]
    closes: Tuple[str, ...]
    module: ModuleType = field(compare=False, repr=False)  # the loaded module, for what a family adds beyond these
    arguments: Mapping[ArgumentKey, Callable[[], ArgumentFixture]] = field(default_factory=dict)
    undo: Mapping[str, Step] = field(default_factory=dict)


@dataclass(frozen=True)
class Families:
    """Every family of a directory, merged: no context key, PREPARE or UNDO id or ARGUMENTS key is claimed twice."""

    families: Tuple[Family, ...] = ()
    owners: Mapping[str, str] = field(default_factory=dict)  # context key -> family name

    @property
    def contexts(self) -> frozenset:
        return frozenset(self.owners)

    def new_contexts(self) -> Dict[str, ContextFixture]:
        """One fresh ContextFixture per context key: a session run's (or a relaunch's) own state."""
        return {key: family.contexts[key]() for family in self.families for key in family.contexts}

    def merged_prepare(self, base: Mapping[str, Sequence[Step]]) -> Dict[str, List[Step]]:
        """`base` (the sweep's PREPARE) with every family's steps added. An id `base` already prepares is refused:
        two setups for one action would run in an order nobody chose."""
        merged = {ident: list(steps) for ident, steps in base.items()}
        for family in self.families:
            for ident, steps in family.prepare.items():
                if ident in merged:
                    raise FixtureError(f"{family.path.name}: PREPARE {ident!r} is already prepared by the sweep "
                                       f"or another family")
                merged[ident] = [(step, dict(args)) for step, args in steps]
        return merged

    def new_arguments(self, driver: Driver, gap: Callable[[str], Any]) -> Dict[ArgumentKey, Callable[[Any], Any]]:
        """The families' ARGUMENTS as ARGUMENT_FIXTURES entries (`base -> (value, None)` or `(None, gap(why))`), over
        one fresh ArgumentFixture per distinct factory: a session run's (or a relaunch's) own state."""
        made: Dict[int, ArgumentFixture] = {}
        fixtures: Dict[ArgumentKey, Callable[[Any], Any]] = {}
        for family in self.families:
            for key, factory in family.arguments.items():
                fixture = made.get(id(factory))
                if fixture is None:
                    fixture = made[id(factory)] = factory()
                fixtures[key] = lambda base, fixture=fixture: _answer(fixture.value(driver, base), gap)
        return fixtures

    def argument_keys(self) -> Tuple[ArgumentKey, ...]:
        """Every (action id, argument name) a family fills, for --plan-only's placeholders."""
        return tuple(key for family in self.families for key in family.arguments)

    def check_arguments(self, sweep_arguments: Iterable[ArgumentKey]) -> None:
        """Refuses a family argument the sweep already fills (ARGUMENT_FIXTURES): one argument, one value."""
        taken = sorted(set(sweep_arguments) & set(self.argument_keys()))
        if taken:
            raise FixtureError(f"argument {', '.join('.'.join(k) for k in taken)} is filled by the sweep "
                               f"(ARGUMENT_FIXTURES) and by a family")

    def merged_undo(self, base: Mapping[str, Step]) -> Dict[str, Step]:
        """`base` (the sweep's UNDO) with every family's inverses added; an id `base` already undoes is refused."""
        merged = dict(base)
        for family in self.families:
            for ident, step in family.undo.items():
                if ident in merged:
                    raise FixtureError(f"{family.path.name}: UNDO {ident!r} is already undone by the sweep or another "
                                       f"family")
                merged[ident] = step
        return merged

    def check_contexts(self, sweep_contexts: Iterable[str]) -> None:
        """Refuses a family context the sweep already sets up (CONTEXT_SETUP): one key, one setup."""
        taken = sorted(set(sweep_contexts) & set(self.owners))
        if taken:
            raise FixtureError(f"context {', '.join(taken)} is set up by the sweep (CONTEXT_SETUP) and by family "
                               f"{', '.join(sorted({self.owners[k] for k in taken}))}")


def _answer(answer: Any, gap: Callable[[str], Any]) -> Tuple[Any, Any]:
    """An ArgumentFixture's (value, why) as the sweep's (value, None) or (None, gap(why))."""
    value, why = answer
    if value is None:
        return None, gap(why or "the argument fixture gave no value")
    return value, None


def family_paths(directory: Path = HERE) -> List[Path]:
    """The family modules of `directory`, sorted: every *.py but __init__.py and *_test.py."""
    return sorted(p for p in directory.glob("*.py") if p.name != "__init__.py" and not p.stem.endswith("_test"))


def _steps(where: str, ident: Any, steps: Any, table: str = "PREPARE") -> Tuple[Step, ...]:
    if not isinstance(ident, str) or not ident:
        raise FixtureError(f"{where}: a {table} key is an action id, not {ident!r}")
    if not isinstance(steps, (list, tuple)):
        raise FixtureError(f"{where}: {table} {ident!r} is a list of (action, args)")
    out = []
    for step in steps:
        if not (isinstance(step, (list, tuple)) and len(step) == 2 and isinstance(step[0], str) and step[0]
                and isinstance(step[1], dict)):
            raise FixtureError(f"{where}: {table} {ident!r} step {step!r} is not (action id, args dict)")
        out.append((step[0], dict(step[1])))
    return tuple(out)


def check_family(module: Any, path: Path) -> Family:
    """The Family `module` (loaded from `path`) defines, or FixtureError naming what it lacks."""
    where = path.name
    name = getattr(module, "FAMILY", None)
    if not isinstance(name, str) or not FAMILY_SLUG.match(name):
        raise FixtureError(f"{where}: FAMILY must be a family slug, not {name!r}")
    contexts = getattr(module, "CONTEXTS", {})
    if not isinstance(contexts, dict) or not all(isinstance(k, str) and k and callable(v) for k, v in contexts.items()):
        raise FixtureError(f"{where}: CONTEXTS maps a registry context key to a ContextFixture factory")
    prepare = getattr(module, "PREPARE", {})
    if not isinstance(prepare, dict):
        raise FixtureError(f"{where}: PREPARE maps an action id to its (action, args) steps")
    closes = getattr(module, "CLOSES", ())
    if not isinstance(closes, (list, tuple)) or not all(isinstance(i, str) and i for i in closes):
        raise FixtureError(f"{where}: CLOSES is a list of action ids")
    if len(set(closes)) != len(closes):
        raise FixtureError(f"{where}: CLOSES names an id twice")
    arguments = getattr(module, "ARGUMENTS", {})
    if not isinstance(arguments, dict) or not all(
            isinstance(k, tuple) and len(k) == 2 and all(isinstance(p, str) and p for p in k) and callable(v)
            for k, v in arguments.items()):
        raise FixtureError(f"{where}: ARGUMENTS maps (action id, argument name) to an ArgumentFixture factory")
    undo = getattr(module, "UNDO", {})
    if not isinstance(undo, dict):
        raise FixtureError(f"{where}: UNDO maps an action id to its (action, args) inverse")
    if not (contexts or prepare or arguments or undo):
        raise FixtureError(f"{where}: a family gives CONTEXTS, PREPARE, ARGUMENTS or UNDO")
    return Family(name, path, dict(contexts), {i: _steps(where, i, s) for i, s in prepare.items()}, tuple(closes),
                  module, dict(arguments), {i: _steps(where, i, [s], "UNDO")[0] for i, s in undo.items()})


def load_module(path: Path, name: str) -> ModuleType:
    """`path` imported as module `name`, registered in sys.modules before it runs (importlib's recipe): dataclasses,
    typing.get_type_hints and pickle look a class's module up there."""
    spec = importlib.util.spec_from_file_location(name, path)
    if spec is None or spec.loader is None:
        raise FixtureError(f"{path}: not a Python module")
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    try:
        spec.loader.exec_module(module)
    except BaseException:
        sys.modules.pop(name, None)
        raise
    return module


def check_closures(family: Family, closures: Path) -> None:
    """Refuses a family whose CLOSES is not the `closed` ids of its gap-closures record (`closures`/<family>.json),
    or a record without a CLOSES: the two name one set of ids."""
    record = closures / f"{family.name}.json"
    where = family.path.name
    if not record.exists():
        if family.closes:
            raise FixtureError(f"{where}: CLOSES names ids but {record.name} is not in {closures}")
        return
    try:
        closed = json.loads(record.read_text())["closed"]
    except (OSError, ValueError, KeyError, TypeError) as error:
        raise FixtureError(f"{record}: not a gap-closures record with `closed`: {error!r}") from error
    if not isinstance(closed, dict):
        raise FixtureError(f"{record}: `closed` maps an action id to why it is closed")
    only_closes, only_record = sorted(set(family.closes) - set(closed)), sorted(set(closed) - set(family.closes))
    if only_closes or only_record:
        raise FixtureError(f"{where}: CLOSES and {record.name} differ: only in CLOSES {only_closes}, "
                           f"only in {record.name} {only_record}")


def load_families(directory: Path = HERE, closures: Path = GAP_CLOSURES) -> Families:
    """Every family of `directory`, checked (CLOSES against `closures`) and merged. A module that fails to import is a
    FixtureError: a fixture that silently drops out would turn its closed gaps back into gaps with no word why."""
    families: List[Family] = []
    owners: Dict[str, str] = {}
    names: Dict[str, Path] = {}
    for path in family_paths(directory):
        try:
            module = load_module(path, f"action_fixtures.{path.stem}")
        except FixtureError:
            raise
        except Exception as error:  # the family's own import error, named with its file
            raise FixtureError(f"{path.name}: does not import: {error!r}") from error
        family = check_family(module, path)
        if family.name in names:
            raise FixtureError(f"{path.name}: FAMILY {family.name!r} is also {names[family.name].name}'s")
        names[family.name] = path
        for key in family.contexts:
            if key in owners:
                raise FixtureError(f"{path.name}: context {key!r} is also family {owners[key]!r}'s")
            owners[key] = family.name
        families.append(family)
    prepared: Dict[str, str] = {}
    filled: Dict[ArgumentKey, str] = {}
    undone: Dict[str, str] = {}
    for family in families:
        for ident in family.prepare:
            if ident in prepared:
                raise FixtureError(f"{family.path.name}: PREPARE {ident!r} is also family {prepared[ident]!r}'s")
            prepared[ident] = family.name
        for key in family.arguments:
            if key in filled:
                raise FixtureError(f"{family.path.name}: ARGUMENTS {'.'.join(key)!r} is also family {filled[key]!r}'s")
            filled[key] = family.name
        for ident in family.undo:
            if ident in undone:
                raise FixtureError(f"{family.path.name}: UNDO {ident!r} is also family {undone[ident]!r}'s")
            undone[ident] = family.name
        check_closures(family, closures)
    return Families(tuple(families), owners)


def load_sweep(argv: Sequence[str]) -> ModuleType:
    """every-action-sweep.py as a module, configured by `argv` (its command line without the program name, e.g.
    ["--app", APP, "--tag", TAG, "--out", DIR]): the oracle's way to its App, Sweep, plan(), restore() and
    TagTeardown where they are. The script reads its options at import (phase 1 moves nothing), so `argv` stands in
    for sys.argv during the import only. One configuration per process: a second call with the same `argv` returns
    the first module, another `argv` is a FixtureError (the module's options are fixed at import)."""
    argv = [str(a) for a in argv]
    loaded = sys.modules.get(SWEEP_MODULE)
    if loaded is not None:
        if getattr(loaded, "LOADED_ARGV", None) != argv:
            raise FixtureError(f"every-action-sweep.py is already loaded with {getattr(loaded, 'LOADED_ARGV', None)}, "
                               f"not {argv}")
        return loaded
    saved = sys.argv
    sys.argv = [str(SWEEP), *argv]
    try:
        module = load_module(SWEEP, SWEEP_MODULE)
    finally:
        sys.argv = saved
    module.LOADED_ARGV = argv
    return module
