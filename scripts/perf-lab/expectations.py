#!/usr/bin/env python3
"""Story expectations: a story x host-class pair the lab does not run, with an issue and an expiry.

Chrome keeps the same list in `tools/perf/expectations.config` (typ tags: a crbug, platform tags,
the story, `[ Skip ]`) and `tools/perf/validate_story_expectation_data` refuses entries that name
an unknown story. cmux adds an expiry: an entry lives at most 7 days (p12-perf-process.md 3.6), so a
disabled story cannot stay out of the waterfall unnoticed.

The scheduler (task 011, `plan()`) takes the result of `Expectations.in_force(now)` as a pure input
and asks `skip(story, host)` before it plans a story on a host. An entry is in force from its
`added` day up to, but not including, its `expires` day (UTC). An invalid entry (no issue, a
lifetime over 7 days, a bad date) is never in force: the story keeps running, and `--check` fails.

  python3 scripts/perf-lab/expectations.py --check     # what `lab.py expectations --check` runs
  python3 scripts/perf-lab/expectations.py             # list entries and their state
"""
from __future__ import annotations

import argparse
import json
import re
import sys
from collections.abc import Iterable, Mapping, Sequence
from dataclasses import dataclass, field
from datetime import date, datetime, timedelta, timezone
from pathlib import Path

SCHEMA = "cmux-perf-expectations/v1"
MAX_LIFETIME = timedelta(days=7)
ENTRY_KEYS = ("story", "host_class", "reason", "issue", "added", "expires")
DEFAULT_PATH = Path(__file__).resolve().parent / "expectations.json"
DEFAULT_STORIES_DIR = Path(__file__).resolve().parent / "stories.d"

# The issue that tracks the fix: an issue in a manaflow-ai repository, never a PR or a free-form note.
_ISSUE_RE = re.compile(r"^https://github\.com/manaflow-ai/[A-Za-z0-9_.-]+/issues/[1-9][0-9]*$")
# store.host_class(): chip + memory + display Hz, for example `apple-m4-pro/24gb/120hz`.
_HOST_CLASS_RE = re.compile(r"^[a-z0-9][a-z0-9.-]*/[1-9][0-9]*gb/[1-9][0-9]*hz$")
_DATE_RE = re.compile(r"^[0-9]{4}-[0-9]{2}-[0-9]{2}$")


class ExpectationsError(ValueError):
    """The file cannot be read as a `cmux-perf-expectations/v1` document."""


@dataclass(frozen=True)
class Problem:
    index: int
    story: str
    host_class: str
    message: str

    def __str__(self) -> str:
        return f"entries[{self.index}] {self.story or '?'} @ {self.host_class or '?'}: {self.message}"

    def to_json(self) -> dict:
        return {"index": self.index, "story": self.story, "host_class": self.host_class, "message": self.message}


@dataclass(frozen=True)
class Expectation:
    index: int
    story: str
    host_class: str
    reason: str
    issue: str
    added: date | None
    expires: date | None
    # Problems that do not depend on the date: missing fields, a bad issue link, a long lifetime.
    defects: tuple[str, ...] = ()

    @property
    def valid(self) -> bool:
        return not self.defects

    def expired(self, today: date) -> bool:
        return self.expires is not None and today >= self.expires

    def in_force(self, today: date) -> bool:
        return self.valid and self.added is not None and self.expires is not None \
            and self.added <= today < self.expires

    def state(self, today: date) -> str:
        if not self.valid:
            return "invalid"
        if self.expired(today):
            return "expired"
        return "in-force" if self.in_force(today) else "not-yet"


@dataclass(frozen=True)
class ActiveExpectations:
    """The story x host-class pairs to skip at one instant: the scheduler's pure input."""

    pairs: frozenset[tuple[str, str]] = field(default_factory=frozenset)

    def skip(self, story: str, host: object) -> bool:
        return (story, host_class_of(host)) in self.pairs

    def runnable(self, stories: Iterable[str], host: object) -> list[str]:
        """The stories of `stories` that `plan()` may put on `host`, in their given order."""
        cls = host_class_of(host)
        return [story for story in stories if (story, cls) not in self.pairs]


class Expectations:
    def __init__(self, entries: Sequence[Expectation]):
        self.entries = tuple(entries)

    @classmethod
    def load(cls, path: Path = DEFAULT_PATH) -> Expectations:
        try:
            document = json.loads(Path(path).read_text(encoding="utf-8"))
        except OSError as error:
            raise ExpectationsError(f"{path}: cannot read: {error.strerror or error}") from error
        except json.JSONDecodeError as error:
            raise ExpectationsError(f"{path}: not JSON: {error}") from error
        return cls.from_document(document, source=str(path))

    @classmethod
    def from_document(cls, document: object, *, source: str = "expectations") -> Expectations:
        if not isinstance(document, Mapping):
            raise ExpectationsError(f"{source}: the top level must be an object")
        if document.get("schema") != SCHEMA:
            raise ExpectationsError(f"{source}: schema must be {SCHEMA!r}, got {document.get('schema')!r}")
        unknown = sorted(set(document) - {"schema", "entries"})
        if unknown:
            raise ExpectationsError(f"{source}: unknown top-level keys {unknown}")
        entries = document.get("entries")
        if not isinstance(entries, list):
            raise ExpectationsError(f"{source}: entries must be a list")
        return cls([_parse_entry(index, raw) for index, raw in enumerate(entries)])

    def in_force(self, now: datetime | date) -> ActiveExpectations:
        today = utc_day(now)
        return ActiveExpectations(frozenset(
            (entry.story, entry.host_class) for entry in self.entries if entry.in_force(today)))

    def skip(self, story: str, host: object, now: datetime | date) -> bool:
        return self.in_force(now).skip(story, host)

    def problems(self, now: datetime | date, known_stories: Iterable[str] | None = None) -> list[Problem]:
        """Every entry `--check` refuses: invalid, expired, added in the future, a duplicate pair or an unknown story."""
        today = utc_day(now)
        known = None if known_stories is None else frozenset(known_stories)
        problems: list[Problem] = []
        seen: dict[tuple[str, str], int] = {}
        for entry in self.entries:
            messages = list(entry.defects)
            if entry.expired(today):
                messages.append(f"expired on {entry.expires.isoformat()}; fix the story or close {entry.issue or 'the issue'}"
                                " and delete the entry (an expectation is never renewed to clear an alert)")
            if entry.added is not None and entry.added > today:
                messages.append(f"added {entry.added.isoformat()} is in the future")
            if known is not None and entry.story and entry.story not in known:
                messages.append(f"unknown story: no stories.d/{entry.story}.json")
            pair = (entry.story, entry.host_class)
            if entry.story and entry.host_class:
                if pair in seen:
                    messages.append(f"duplicates entries[{seen[pair]}]")
                else:
                    seen[pair] = entry.index
            problems.extend(Problem(entry.index, entry.story, entry.host_class, message) for message in messages)
        return problems


def host_class_of(host: object) -> str:
    """The host class of a scheduler host: a class string, a `store.Host`-like object or a host record."""
    if isinstance(host, str):
        return host
    if isinstance(host, Mapping):
        value = host.get("host_class")
    else:
        value = getattr(host, "host_class", None)
    if not isinstance(value, str) or not value:
        raise TypeError(f"host has no host_class: {host!r}")
    return value


def utc_day(now: datetime | date) -> date:
    if isinstance(now, datetime):
        if now.tzinfo is None:
            raise ValueError("now must be timezone-aware")
        return now.astimezone(timezone.utc).date()
    return now


def known_story_ids(stories_dir: Path) -> frozenset[str] | None:
    """Story ids from `stories.d/<id>.json` (R7), or None while the directory does not exist."""
    if not stories_dir.is_dir():
        return None
    return frozenset(path.stem for path in stories_dir.glob("*.json"))


def _parse_entry(index: int, raw: object) -> Expectation:
    if not isinstance(raw, Mapping):
        return Expectation(index, "", "", "", "", None, None, ("entry must be an object",))
    defects: list[str] = []
    unknown = sorted(set(raw) - set(ENTRY_KEYS))
    if unknown:
        defects.append(f"unknown keys {unknown}")
    text = {}
    for key in ENTRY_KEYS:
        value = raw.get(key)
        if value is None or (isinstance(value, str) and not value.strip()):
            defects.append(f"missing {key}")
            text[key] = ""
        elif not isinstance(value, str):
            defects.append(f"{key} must be a string")
            text[key] = ""
        else:
            text[key] = value.strip()
    if text["issue"] and not _ISSUE_RE.match(text["issue"]):
        defects.append(f"issue must be https://github.com/manaflow-ai/<repo>/issues/<n>, got {text['issue']!r}")
    if text["host_class"] and not _HOST_CLASS_RE.match(text["host_class"]):
        defects.append(f"host_class must look like apple-m4-pro/24gb/120hz, got {text['host_class']!r}")
    added = _parse_day(text["added"], "added", defects)
    expires = _parse_day(text["expires"], "expires", defects)
    if added is not None and expires is not None:
        if expires <= added:
            defects.append(f"expires {expires.isoformat()} must be after added {added.isoformat()}")
        elif expires - added > MAX_LIFETIME:
            defects.append(f"expires {expires.isoformat()} is more than {MAX_LIFETIME.days} days after added {added.isoformat()}")
    return Expectation(index, text["story"], text["host_class"], text["reason"], text["issue"],
                       added, expires, tuple(defects))


def _parse_day(value: str, key: str, defects: list[str]) -> date | None:
    if not value:
        return None
    if not _DATE_RE.match(value):
        defects.append(f"{key} must be YYYY-MM-DD, got {value!r}")
        return None
    try:
        return date.fromisoformat(value)
    except ValueError:
        defects.append(f"{key} is not a calendar date: {value!r}")
        return None


def _parse_now(value: str) -> datetime:
    try:
        parsed = datetime.fromisoformat(value)
    except ValueError as error:
        raise argparse.ArgumentTypeError(f"--now must be ISO 8601: {value!r}") from error
    return parsed if parsed.tzinfo else parsed.replace(tzinfo=timezone.utc)


def main(argv: Sequence[str] | None = None, *, now: datetime | None = None) -> int:
    parser = argparse.ArgumentParser(prog="lab.py expectations",
                                     description="Story x host-class pairs the perf lab skips, with an issue and an expiry.")
    parser.add_argument("--check", action="store_true",
                        help="exit 1 when any entry is expired, issue-less or otherwise invalid")
    parser.add_argument("--file", type=Path, default=DEFAULT_PATH)
    parser.add_argument("--stories-dir", type=Path, default=DEFAULT_STORIES_DIR,
                        help="refuse entries whose story has no <id>.json here (skipped while the directory is absent)")
    parser.add_argument("--now", type=_parse_now, default=None, help="evaluate at this instant (default: now, UTC)")
    parser.add_argument("--json", action="store_true")
    args = parser.parse_args(argv)
    instant = args.now or now or datetime.now(timezone.utc)
    try:
        expectations = Expectations.load(args.file)
    except ExpectationsError as error:
        print(f"expectations: {error}", file=sys.stderr)
        return 2
    problems = expectations.problems(instant, known_story_ids(args.stories_dir))
    today = utc_day(instant)
    if args.json:
        print(json.dumps({
            "today": today.isoformat(),
            "entries": [{"index": e.index, "story": e.story, "host_class": e.host_class, "issue": e.issue,
                         "expires": e.expires.isoformat() if e.expires else None, "state": e.state(today)}
                        for e in expectations.entries],
            "problems": [problem.to_json() for problem in problems],
        }, indent=2))
    else:
        if not args.check:
            for e in expectations.entries:
                print(f"{e.state(today):8} {e.story or '?'} @ {e.host_class or '?'} until "
                      f"{e.expires.isoformat() if e.expires else '?'} {e.issue}")
        for problem in problems:
            print(f"FAIL {problem}")
        print(f"expectations: {len(expectations.entries)} entries, {len(problems)} problems")
    return 1 if args.check and problems else 0


if __name__ == "__main__":
    sys.exit(main())
