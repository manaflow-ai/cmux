#!/usr/bin/env python3
"""Story expectations: a story x host-class pair the lab does not run for a few days, with an issue and an expiry.

    python3 -I scripts/perf-lab/lab.py expectations [--check] [--today YYYY-MM-DD]
    active_at(path, now).skip                        # the skip(story, host) hook of scheduler.plan()

Chrome disables a story on a platform in tools/perf/expectations.config (a crbug link, the platform tags and
the story, `[ Skip ]`), and core/perf_data_generator.py refuses a malformed file. Here an entry of
expectations.json is {story, host_class, reason, issue, added, expires}: `host_class` is the series host class
(store.host_class, for example apple-m6/24gb/120hz), `issue` an https link, `added` and `expires` UTC dates with
expires at most MAX_DAYS after added (p12-perf-process.md 3.7). An entry skips its pair through the end of its
`expires` day. An expired entry, or one that breaks a rule, skips nothing: the story runs again,
`expectations --check` exits 1 and every scheduler plan lists the problem until someone fixes the story or removes
the entry. scheduler.Driver (labd) and `lab.py schedule` read the file through active_at() for every plan. Never
add or extend an entry to clear an alert (R3); a noisy series gets de-noised (task 024), never disabled.

Stdlib only; loads catalog.py by file path, so it runs under `python3 -I`.
"""
from __future__ import annotations

import argparse
import importlib.util
import json
import re
import sys
from collections.abc import Iterable, Mapping
from dataclasses import dataclass
from datetime import date, datetime, timedelta, timezone
from pathlib import Path

HERE = Path(__file__).resolve().parent
REPO_ROOT = HERE.parents[1]
EXPECTATIONS_PATH = Path("scripts/perf-lab/expectations.json")
SCHEMA = "cmux-perf-expectations/v1"
MAX_DAYS = 7
FIELDS = ("story", "host_class", "reason", "issue", "added", "expires")
ISSUE = re.compile(r"^https://\S+$")
HOST_CLASS = re.compile(r"^[a-z0-9][a-z0-9._-]*/[0-9]+gb/[0-9]+hz$")  # store.host_class(chip, memory_gb, display_hz)


def _load_sibling(name: str):
    module_name = f"perf_lab_{name}"
    if module_name in sys.modules:
        return sys.modules[module_name]
    spec = importlib.util.spec_from_file_location(module_name, HERE / f"{name}.py")
    module = importlib.util.module_from_spec(spec)
    sys.modules[module_name] = module  # before exec: dataclasses resolve their module through sys.modules
    spec.loader.exec_module(module)
    return module


class ExpectationsError(ValueError):
    """The expectations file is missing, is not JSON or is not a {schema, expectations: [...]} document."""


@dataclass(frozen=True)
class Expectation:
    story: str
    host_class: str
    reason: str
    issue: str
    added: date
    expires: date
    where: str  # "expectations.json entry N", for messages

    @property
    def pair(self) -> tuple[str, str]:
        return self.story, self.host_class

    def rule_problems(self) -> list[str]:
        """What makes this entry invalid on any day; an invalid entry never skips."""
        problems = []
        if not ISSUE.match(self.issue):
            problems.append(f"{self.where}: issue {self.issue!r} is not an https issue link")
        if not self.reason.strip():
            problems.append(f"{self.where}: reason is empty")
        if not HOST_CLASS.match(self.host_class):
            problems.append(f"{self.where}: host_class {self.host_class!r} is not a host class like "
                            "apple-m6/24gb/120hz")
        if self.expires < self.added:
            problems.append(f"{self.where}: expires {self.expires} is before added {self.added}")
        elif self.expires > self.added + timedelta(days=MAX_DAYS):
            problems.append(f"{self.where}: expires {self.expires} is more than {MAX_DAYS} days after added "
                            f"{self.added}")
        return problems

    def expired(self, on: date) -> bool:
        return on > self.expires

    def future(self, on: date) -> bool:
        """An `added` after today would stretch the MAX_DAYS window; such an entry skips nothing."""
        return on < self.added


@dataclass(frozen=True)
class ActiveExpectations:
    """The pairs to skip on one day. `skip` is scheduler.plan()'s skip(story, host) hook; `problems` are the
    entries that skip nothing that day and why, which the scheduler adds to its plan's problems."""

    pairs: frozenset[tuple[str, str]]
    problems: tuple[str, ...] = ()

    def skip(self, story: str, host) -> bool:
        return (story, host.host_class) in self.pairs


@dataclass(frozen=True)
class Expectations:
    entries: tuple[Expectation, ...]
    problems: tuple[str, ...]  # entries that could not be read at all (a missing field, a bad date)

    def active(self, on: date) -> ActiveExpectations:
        """The valid, unexpired entries on `on`. A pair listed twice is a problem, and neither entry skips."""
        duplicates = self._duplicates()
        return ActiveExpectations(frozenset(
            e.pair for e in self.entries
            if not e.rule_problems() and not e.expired(on) and not e.future(on) and e.pair not in duplicates),
            tuple(self.check(on)))

    def check(self, on: date, *, stories: Iterable[str] | None = None) -> list[str]:
        """Every problem on `on`: unreadable, issue-less, too long or expired entries, duplicate pairs and,
        with `stories`, an entry whose story is not in the catalog."""
        problems = list(self.problems)
        known = None if stories is None else set(stories)
        for entry in self.entries:
            problems.extend(entry.rule_problems())
            if entry.expired(on):
                problems.append(f"{entry.where}: expired on {entry.expires} ({entry.story} on {entry.host_class}, "
                                f"{entry.issue}); fix the story or remove the entry")
            if entry.future(on):
                problems.append(f"{entry.where}: added {entry.added} is after {on}")
            if known is not None and entry.story not in known:
                problems.append(f"{entry.where}: story {entry.story!r} is not in stories.d/")
        for story, host_class in sorted(self._duplicates()):
            problems.append(f"expectations.json: {story} on {host_class} is listed more than once")
        return problems

    def _duplicates(self) -> set[tuple[str, str]]:
        seen: set[tuple[str, str]] = set()
        twice: set[tuple[str, str]] = set()
        for entry in self.entries:
            (twice if entry.pair in seen else seen).add(entry.pair)
        return twice


def _date(value, field: str, where: str) -> date:
    if not isinstance(value, str):
        raise ValueError(f"{where}: {field} must be a YYYY-MM-DD string")
    try:
        return date.fromisoformat(value)
    except ValueError:
        raise ValueError(f"{where}: {field} {value!r} is not a YYYY-MM-DD date") from None


def from_document(document: Mapping) -> Expectations:
    if not isinstance(document, Mapping) or document.get("schema") != SCHEMA:
        raise ExpectationsError(f"expectations: expected {{\"schema\": \"{SCHEMA}\", \"expectations\": [...]}}")
    raw = document.get("expectations")
    if not isinstance(raw, list):
        raise ExpectationsError("expectations: \"expectations\" must be a list")
    entries: list[Expectation] = []
    problems: list[str] = []
    for index, item in enumerate(raw):
        where = f"expectations.json entry {index}"
        if not isinstance(item, Mapping):
            problems.append(f"{where}: not an object")
            continue
        missing = [f for f in FIELDS if f not in item]
        extra = sorted(set(item) - set(FIELDS))
        if missing or extra:
            problems.append(f"{where}: " + "; ".join(
                ([f"missing {', '.join(missing)}"] if missing else []) + ([f"unknown {', '.join(extra)}"] if extra else [])))
            continue
        texts = {f: item[f] for f in ("story", "host_class", "reason", "issue")}
        not_text = [f for f, v in texts.items() if not isinstance(v, str)]
        if not_text:
            problems.append(f"{where}: {', '.join(not_text)} must be strings")
            continue
        try:
            added = _date(item["added"], "added", where)
            expires = _date(item["expires"], "expires", where)
        except ValueError as error:
            problems.append(str(error))
            continue
        entries.append(Expectation(added=added, expires=expires, where=where, **texts))
    return Expectations(tuple(entries), tuple(problems))


def load(path: Path | str) -> Expectations:
    path = Path(path)
    try:
        document = json.loads(path.read_text(encoding="utf-8"))
    except OSError as error:
        raise ExpectationsError(f"expectations: {error}") from None
    except json.JSONDecodeError as error:
        raise ExpectationsError(f"expectations: {path} is not JSON: {error}") from None
    return from_document(document)


def utc_today() -> date:
    return datetime.now(timezone.utc).date()


def active_at(path: Path | str, now: datetime) -> ActiveExpectations:
    """The pairs to skip at `now`, judged on its UTC day, so expiry follows the `now` that plan() gets. A file that
    cannot be read skips nothing and says why: a bad edit lets every story run, it never stops the lab."""
    try:
        return load(path).active(now.astimezone(timezone.utc).date())
    except ExpectationsError as error:
        return ActiveExpectations(frozenset(), (str(error),))


# ---------- command (lab.py protocol, task 005) ----------

LAB_COMMANDS = {
    "expectations": "Story x host-class pairs the lab skips (expectations.json); --check fails on expired, "
                    "issue-less or over-7-day entries.",
}


def add_arguments(command: str, parser: argparse.ArgumentParser) -> None:
    parser.add_argument("--root", type=Path, default=REPO_ROOT, help=argparse.SUPPRESS)
    parser.add_argument("--file", type=Path, help=f"the expectations file (default: {EXPECTATIONS_PATH})")
    parser.add_argument("--check", action="store_true", help="exit 1 when any entry is expired or breaks a rule")
    parser.add_argument("--today", type=date.fromisoformat, help="the UTC date to judge expiry on (default: today)")


def run(command: str, args: argparse.Namespace, out=None, err=None) -> int:
    out = out or sys.stdout
    err = err or sys.stderr
    catalog = _load_sibling("catalog")
    today = args.today or utc_today()
    try:
        expectations = load(args.file or args.root / EXPECTATIONS_PATH)
        stories = [s.id for s in catalog.load_catalog(args.root).stories]
    except (ExpectationsError, catalog.CatalogError) as error:
        print(f"expectations: {error}", file=err)
        return 2
    active = expectations.active(today)
    for entry in expectations.entries:
        status = "skips" if entry.pair in active.pairs else "expired" if entry.expired(today) else "invalid"
        print(f"{entry.story}\t{entry.host_class}\t{status} through {entry.expires}\t{entry.issue}\t{entry.reason}",
              file=out)
    problems = expectations.check(today, stories=stories)
    for problem in problems:
        print(problem, file=err)
    print(f"expectations: {len(expectations.entries)} entries, {len(active.pairs)} skipping on {today}, "
          f"{len(problems)} problems", file=out)
    return 1 if args.check and problems else 0


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="expectations.py", description=LAB_COMMANDS["expectations"])
    add_arguments("expectations", parser)
    return run("expectations", parser.parse_args(argv))


if __name__ == "__main__":
    sys.exit(main())
