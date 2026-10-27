#!/usr/bin/env python3
"""Applies every gap-closures record to the every-action sweep's gap baseline in one edit (p15-oracle-087).

Spec: plans/cmux-next/chrome-parity/p15-oracle.md, "071 gen_actions.py, 072-081 action families, 082-087 gap
fixtures": each gap fixture task writes tests/oracle/gap-closures/<family>.json, and this applies all of them to
scripts/cmux-next/every-action-gaps.json. Stdlib only, Python 3.9+, safe under `python3 -I`.

A record is {"family": <its file's stem>, "closed": {id: why}, "reasoned": {id: why}} (other keys are notes).
Applying drops each `closed` id from `gaps` and sets each `reasoned` id's reason, so the result is the same however
often it runs: a closed id no longer listed was applied before. Refused (ClosureError), with nothing written: two
records that name one id, an id the catalog does not have, a record that closes ids but has no fixture family in
oracle/action_fixtures (its fixture has not landed: the sweep would report those ids as new gaps), a closed id the
reviewed `excluded` list names, and a reasoned id that is not a gap (the record went stale). action_fixtures
.load_families checks the other way: a family's CLOSES is exactly its record's `closed`. The sweep's own --write-gaps still rewrites the baseline from a
whole-catalog run; this keeps the records and the baseline in step between such runs.

Usage:
  apply_gap_closures.py           print what applying would change
  apply_gap_closures.py --write   apply it to every-action-gaps.json
  apply_gap_closures.py --check   exit 1 when the baseline is not the records applied

Chrome reference (chromium/src): third_party/blink/web_tests/TestExpectations is one reviewed list of tests that do
not pass, each line with its reason or bug, and tools like `blink_tool.py rebaseline` rewrite it from results; here
the fixture records rewrite the sweep's list the same way.
"""

from __future__ import annotations

import argparse
import json
import sys
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Dict, List, Mapping, Optional, Sequence, Tuple

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[2]
GAPS = REPO / "scripts" / "cmux-next" / "every-action-gaps.json"
CLOSURES = REPO / "tests" / "oracle" / "gap-closures"
CATALOG = REPO / "plans" / "cmux-next" / "action-surfaces.json"


class ClosureError(ValueError):
    """A record that cannot be applied: unreadable, or in conflict with another record, the catalog or the baseline."""


@dataclass(frozen=True)
class Record:
    """One tests/oracle/gap-closures/<family>.json."""

    path: Path
    family: str
    closed: Mapping[str, str]
    reasoned: Mapping[str, str] = field(default_factory=dict)


@dataclass(frozen=True)
class Applied:
    """The baseline after applying, and what changed."""

    baseline: Dict[str, Any]
    dropped: Tuple[str, ...]
    reasons: Tuple[str, ...]  # reasoned ids whose reason changed

    @property
    def changed(self) -> bool:
        return bool(self.dropped or self.reasons)


def _reasons(path: Path, record: Mapping[str, Any], key: str) -> Dict[str, str]:
    value = record.get(key, {})
    if not isinstance(value, dict) or not all(isinstance(k, str) and k and isinstance(v, str) and v.strip()
                                              for k, v in value.items()):
        raise ClosureError(f"{path.name}: `{key}` maps an action id to a non-empty reason")
    return dict(value)


def load_records(directory: Path = CLOSURES) -> List[Record]:
    """Every <family>.json of `directory`, sorted by name, checked for its shape."""
    records = []
    for path in sorted(directory.glob("*.json")):
        try:
            raw = json.loads(path.read_text())
        except (OSError, ValueError) as error:
            raise ClosureError(f"{path.name}: not JSON: {error}") from error
        if not isinstance(raw, dict) or "closed" not in raw:
            raise ClosureError(f"{path.name}: a gap-closures record has `closed`")
        if raw.get("family") != path.stem:
            raise ClosureError(f"{path.name}: `family` is {raw.get('family')!r}, not its file's stem {path.stem!r}")
        records.append(Record(path, path.stem, _reasons(path, raw, "closed"), _reasons(path, raw, "reasoned")))
    return records


def catalog_ids(path: Path = CATALOG) -> frozenset:
    return frozenset(a["id"] for a in json.loads(path.read_text())["actions"])


def fixture_families() -> frozenset:
    """The FAMILY names of oracle/action_fixtures (loaded and checked as the sweep loads them)."""
    if str(HERE) not in sys.path:
        sys.path.insert(0, str(HERE))
    import action_fixtures  # noqa: PLC0415  (the oracle's fixture package, beside this script)

    try:
        return frozenset(family.name for family in action_fixtures.load_families().families)
    except action_fixtures.FixtureError as error:
        raise ClosureError(f"oracle/action_fixtures does not load: {error}") from error


def apply(baseline: Mapping[str, Any], records: Sequence[Record], catalog: Optional[frozenset] = None,
          families: Optional[frozenset] = None) -> Applied:
    """`baseline` (every-action-gaps.json) with `records` applied, or ClosureError naming the first conflict.
    `catalog`: the action ids that exist; `families`: the fixture families that have landed (None skips either)."""
    gaps, excluded = dict(baseline["gaps"]), baseline["excluded"]
    owner: Dict[str, str] = {}
    for record in records:
        if record.closed and families is not None and record.family not in families:
            raise ClosureError(f"{record.path.name}: closes {len(record.closed)} ids, but no fixture in "
                               f"oracle/action_fixtures has FAMILY {record.family!r}")
        for ident in [*record.closed, *record.reasoned]:
            if ident in owner:
                raise ClosureError(f"{record.path.name}: {ident} is also in {owner[ident]}")
            owner[ident] = record.path.name
            if catalog is not None and ident not in catalog:
                raise ClosureError(f"{record.path.name}: {ident} is not an action of the catalog")
        for ident in record.closed:
            if ident in excluded:
                raise ClosureError(f"{record.path.name}: closes {ident}, which the reviewed `excluded` list names "
                                   f"({excluded[ident]})")
        for ident in record.reasoned:
            if ident not in gaps:
                raise ClosureError(f"{record.path.name}: keeps {ident} as a gap, but every-action-gaps.json does not "
                                   f"list it: a run covered it, so the record is stale")
    dropped = tuple(sorted(i for record in records for i in record.closed if i in gaps))
    reasons = tuple(sorted(i for record in records for i, why in record.reasoned.items() if gaps[i] != why))
    for record in records:
        for ident in record.closed:
            gaps.pop(ident, None)
        gaps.update(record.reasoned)
    return Applied({**baseline, "gaps": gaps}, dropped, reasons)


def dump(baseline: Mapping[str, Any]) -> str:
    """The baseline as the sweep writes it (every-action-sweep.py write_gaps)."""
    return json.dumps(baseline, indent=1, sort_keys=True) + "\n"


def main(argv: Optional[Sequence[str]] = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--write", action="store_true", help="apply the records to the baseline")
    mode.add_argument("--check", action="store_true", help="exit 1 when the baseline is not the records applied")
    parser.add_argument("--gaps", type=Path, default=GAPS)
    parser.add_argument("--closures", type=Path, default=CLOSURES)
    parser.add_argument("--catalog", type=Path, default=CATALOG)
    opts = parser.parse_args(argv)
    try:
        applied = apply(json.loads(opts.gaps.read_text()), load_records(opts.closures), catalog_ids(opts.catalog),
                        fixture_families())
    except ClosureError as error:
        print(f"apply_gap_closures: {error}", file=sys.stderr)
        return 2
    gaps = applied.baseline["gaps"]
    for ident in applied.dropped:
        print(f"closed  {ident}")
    for ident in applied.reasons:
        print(f"reason  {ident}: {gaps[ident]}")
    print(f"apply_gap_closures: {len(gaps)} gaps after applying, {len(applied.dropped)} closed, "
          f"{len(applied.reasons)} reasons changed")
    if opts.write and applied.changed:
        opts.gaps.write_text(dump(applied.baseline))
    if opts.check and applied.changed:
        print(f"apply_gap_closures: {opts.gaps.name} is not the records applied: run apply_gap_closures.py --write",
              file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
