#!/usr/bin/env python3
"""Fail a pull request that moves an area out of its language (.github/language-boundaries.toml).

Lawrence's rule, relayed by Leo (2026-11-10): "imessage home lives in swift, chat ui lives in react, acpmux/cmux-tui
lives in rust, cmux cloud core should be rust (together with cmux-tui/acpmux) and should have very minimal in
swift." #37777 deleted the native Swift Chief transcript for a React page and shipped a broken Chief UI to the
nightly; this check fails that diff (tests/fixtures/language-boundaries/pr-37777-name-status.tsv).

A `keep` area fails when the pull request loses files of the area's language there (more deleted or renamed away
than added) or adds a file of a foreign language there. A `minimal` area fails when the pull request adds a Swift
file there. The header of .github/language-boundaries.toml is the schema and the rules in full.

Leo's approval, the only way through, needs all three:
  1. the label `leo-approved-port` is on the pull request;
  2. its latest `labeled` event's actor is teamleaderleo, not through a GitHub App;
  3. a comment or review by teamleaderleo, not through a GitHub App, has a line starting `leo-approved-port:` with a
     reason after it, and carries no agent footer (agent-identity's "Agent session:" deeplink, "Generated with
     [Claude Code]", "Co-Authored-By:", the robot emoji).
The limit, honestly: agents act on GitHub as teamleaderleo with Leo's own token, so GitHub cannot tell Leo's label
or comment from an agent's. (2) stops every other account and every bot; (3) stops an agent that follows the
rulebook's footer rule. An agent that adds the label and writes a bare approval line on purpose gets through; the
rulebook forbids it, and the approval line is in the PR's history for anyone to read.

Also a library: `load(path)` and `violations(areas, records)` are what the agents' merge gate (merge_hold) can read the
same file with.
"""

from __future__ import annotations

import argparse
import json
import re
import sys
import tomllib
from dataclasses import dataclass, field
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
DEFAULT_MANIFEST = ROOT / ".github" / "language-boundaries.toml"
LABEL = "leo-approved-port"
LEO = "teamleaderleo"
APPROVAL_LINE = re.compile(rf"^{re.escape(LABEL)}:\s*\S")
# Matched case-insensitively (a `Co-authored-by:` trailer counts too).
AGENT_MARKERS = ("cmux.com/deeplink/agent", "agent session:", "generated with [claude code]", "co-authored-by:",
                 "\U0001f916")

LANGUAGES: dict[str, frozenset[str]] = {
    "swift": frozenset({".swift"}),
    "rust": frozenset({".rs"}),
    "web": frozenset({".ts", ".tsx", ".js", ".jsx", ".mjs", ".cjs", ".mts", ".cts", ".css", ".html", ".vue",
                      ".svelte"}),
}
# The languages a `keep` area of each language refuses as new files. Rust crates already carry small TypeScript
# runtimes, test apps and templates (cmux-app-host/js, cmux-tui-hooks/assets), so a rust area refuses Swift only.
FOREIGN: dict[str, tuple[str, ...]] = {"swift": ("rust", "web"), "web": ("swift", "rust"), "rust": ("swift",)}
POLICIES = ("keep", "minimal")
FIELDS = ("name", "language", "policy", "paths")
# The check itself: a pull request that changes what judges boundaries needs Leo's approval too (it lands on the
# base, where the next pull request's run reads it).
SELF_PATHS = (".github/language-boundaries.toml", "scripts/ci/language_boundaries.py",
              ".github/workflows/language-boundaries.yml")


def glob_regex(pattern: str) -> re.Pattern[str]:
    """`**` crosses directories, `*` and `?` stay within one path segment (classic_frozen_guard.py's globs)."""
    out = []
    i = 0
    while i < len(pattern):
        if pattern.startswith("**/", i):
            out.append("(?:.*/)?")
            i += 3
        elif pattern.startswith("**", i):
            out.append(".*")
            i += 2
        elif pattern[i] == "*":
            out.append("[^/]*")
            i += 1
        elif pattern[i] == "?":
            out.append("[^/]")
            i += 1
        else:
            out.append(re.escape(pattern[i]))
            i += 1
    return re.compile("^" + "".join(out) + "$")


@dataclass
class Area:
    name: str
    language: str
    policy: str
    paths: list[str]
    regexes: list[re.Pattern[str]] = field(default_factory=list, repr=False)

    def covers(self, path: str) -> bool:
        return any(rx.match(path) for rx in self.regexes)


def parse(text: str) -> list[Area]:
    """The manifest's areas. Anything malformed raises ValueError: a typo never opens a boundary."""
    data = tomllib.loads(text)
    unknown = set(data) - {"area"}
    if unknown:
        raise ValueError(f"unknown top-level keys {sorted(unknown)}; want only [[area]] tables")
    areas = []
    for index, raw in enumerate(data.get("area") or [], 1):
        if not isinstance(raw, dict):
            raise ValueError(f"area {index} is not a table")
        missing = [key for key in FIELDS if key not in raw]
        extra = sorted(set(raw) - set(FIELDS))
        if missing or extra:
            raise ValueError(f"area {index}: missing {missing}, unknown {extra}; want exactly {list(FIELDS)}")
        name, language, policy, paths = (raw[key] for key in FIELDS)
        if not isinstance(name, str) or not name:
            raise ValueError(f"area {index}: name must be a non-empty string")
        if language not in LANGUAGES:
            raise ValueError(f"area {name}: language {language!r} is not one of {sorted(LANGUAGES)}")
        if policy not in POLICIES:
            raise ValueError(f"area {name}: policy {policy!r} is not one of {list(POLICIES)}")
        if not isinstance(paths, list) or not paths or not all(isinstance(p, str) and p for p in paths):
            raise ValueError(f"area {name}: paths must be a non-empty list of globs")
        areas.append(Area(name, language, policy, list(paths), [glob_regex(p) for p in paths]))
    if not areas:
        raise ValueError("language-boundaries.toml has no [[area]]")
    names = [a.name for a in areas]
    if len(set(names)) != len(names):
        raise ValueError(f"duplicate area names in {names}")
    return areas


def load(path: Path = DEFAULT_MANIFEST) -> list[Area]:
    return parse(path.read_text())


def language_of(path: str) -> str | None:
    suffix = Path(path).suffix.lower()
    for language, suffixes in LANGUAGES.items():
        if suffix in suffixes:
            return language
    return None


@dataclass(frozen=True)
class Record:
    """One changed file: status is added, removed, modified, renamed or copied; old is a rename's or copy's source."""
    status: str
    path: str
    old: str = ""


GIT_STATUS = {"A": "added", "D": "removed", "M": "modified", "T": "modified", "R": "renamed", "C": "copied"}
REST_STATUS = {"added": "added", "removed": "removed", "modified": "modified", "changed": "modified",
               "unchanged": "modified", "renamed": "renamed", "copied": "copied"}


def parse_records(text: str) -> list[Record]:
    """Changed files, one per line, either REST's `status<TAB>filename<TAB>previous_filename` or `git diff
    --name-status -M`'s `A<TAB>path` / `R100<TAB>old<TAB>new`. An unknown status raises ValueError."""
    records = []
    for number, raw in enumerate(text.splitlines(), 1):
        if not raw.strip():
            continue
        parts = raw.split("\t")
        head = parts[0].strip()
        if head in REST_STATUS:
            status = REST_STATUS[head]
            path = parts[1] if len(parts) > 1 else ""
            old = parts[2] if len(parts) > 2 else ""
        elif head[:1] in GIT_STATUS and (len(head) == 1 or head[1:].isdigit()):
            status = GIT_STATUS[head[:1]]
            if status in ("renamed", "copied"):
                if len(parts) < 3:
                    raise ValueError(f"line {number}: a {status} record needs old and new paths: {raw!r}")
                old, path = parts[1], parts[2]
            else:
                path, old = (parts[1] if len(parts) > 1 else ""), ""
        else:
            raise ValueError(f"line {number}: unknown status {head!r} in {raw!r}")
        if not path:
            raise ValueError(f"line {number}: no path in {raw!r}")
        if status in ("renamed", "copied") and not old:
            raise ValueError(f"line {number}: a {status} record has no previous path: {raw!r}")
        records.append(Record(status, path, old if status in ("renamed", "copied") else ""))
    return records


def violations(areas: list[Area], records: list[Record]) -> list[str]:
    """One line per broken boundary, empty when the pull request keeps every area in its language."""
    out = [f"changes the language-boundaries check itself: {rec.path}" for rec in records
           if rec.path in SELF_PATHS or rec.old in SELF_PATHS]
    for area in areas:
        lost, gained, foreign, new_swift = [], [], [], []
        for rec in records:
            new_in = area.covers(rec.path) and rec.status != "removed"
            # A removal's path is the old path; a rename's source leaves only if it lands outside the area.
            old_path = rec.path if rec.status == "removed" else (rec.old if rec.status == "renamed" else "")
            old_in = bool(old_path) and area.covers(old_path)
            arrived = new_in and (rec.status in ("added", "copied") or (rec.status == "renamed" and not old_in))
            if area.policy == "keep":
                if old_in and language_of(old_path) == area.language and not (
                        new_in and language_of(rec.path) == area.language):
                    lost.append(old_path if rec.status == "removed" else f"{rec.old} -> {rec.path}")
                if new_in and language_of(rec.path) == area.language and (
                        arrived or (rec.status == "renamed" and language_of(rec.old) != area.language)):
                    gained.append(rec.path)
                renamed_language = rec.status == "renamed" and language_of(rec.old) != language_of(rec.path)
                if new_in and (arrived or renamed_language) and language_of(rec.path) in FOREIGN[area.language]:
                    foreign.append(rec.path)
            elif new_in and language_of(rec.path) == "swift" and (
                    arrived or (rec.status == "renamed" and language_of(rec.old) != "swift")):
                new_swift.append(rec.path if rec.status == "added" else f"{rec.old} -> {rec.path}")
        if len(lost) > len(gained):
            shown = ", ".join(lost[:8]) + (f" and {len(lost) - 8} more" if len(lost) > 8 else "")
            out.append(f"{area.name}: loses {len(lost) - len(gained)} {area.language} file(s) net "
                       f"({len(lost)} deleted or moved away, {len(gained)} added): {shown}")
        for path in foreign:
            out.append(f"{area.name}: adds {path}, {language_of(path)} in a {area.language} area")
        for path in new_swift:
            out.append(f"{area.name}: adds Swift file {path}; Swift stays minimal here, new logic is "
                       f"{area.language}")
    return out


def _is_app(entry: dict) -> bool:
    return bool(entry.get("app"))


def leo_approval(labels: list[str], events: list[dict], notes: list[dict]) -> tuple[bool, str]:
    """(approved, why). events: the PR's issue events ({event, label, actor, app}), oldest first. notes: its
    comments and reviews ({user, body, app})."""
    if LABEL not in labels:
        return False, f"the label `{LABEL}` is not on the pull request"
    labeled = [e for e in events if e.get("event") == "labeled" and e.get("label") == LABEL]
    if not labeled:
        return False, f"no `labeled` event for `{LABEL}` was found"
    last = labeled[-1]
    if last.get("actor") != LEO or _is_app(last):
        return False, (f"`{LABEL}` was last added by {last.get('actor')!r}"
                       f"{' through a GitHub App' if _is_app(last) else ''}, not by {LEO}")
    for note in notes:
        body = str(note.get("body") or "")
        if note.get("user") != LEO or _is_app(note):
            continue
        if any(marker in body.lower() for marker in AGENT_MARKERS):
            continue
        if any(APPROVAL_LINE.match(line.strip()) for line in body.splitlines()):
            return True, f"{LEO} added `{LABEL}` and wrote a `{LABEL}:` approval"
    return False, (f"{LEO} added `{LABEL}`, but no comment or review by {LEO} without an agent footer has a line "
                   f"starting `{LABEL}:` with his reason. Leo writes that line, then removes and re-adds the label "
                   f"to re-run this check")


def read_jsonl(path: Path | None) -> list[dict]:
    if path is None or not path.exists():
        return []
    out = []
    for line in path.read_text().splitlines():
        line = line.strip()
        if line:
            item = json.loads(line)
            if isinstance(item, list):
                out.extend(i for i in item if isinstance(i, dict))
            elif isinstance(item, dict):
                out.append(item)
    return out


def check(areas: list[Area], records: list[Record], labels: list[str], events: list[dict], notes: list[dict],
          expected_files: int | None = None) -> tuple[int, list[str]]:
    """(exit code, annotation lines)."""
    approved, why = leo_approval(labels, events, notes)
    paths = {r.path for r in records}
    if expected_files is not None and len(records) < expected_files and not approved:
        return 1, [f"::error::The changed-file listing has {len(records)} files but the pull request changes "
                   f"{expected_files}; a boundary change may be past its end.",
                   "next: split the pull request"]
    found = violations(areas, records)
    if not found:
        return 0, [f"::notice::Every area keeps its language ({len(paths)} changed files, "
                   ".github/language-boundaries.toml)."]
    shown = found[:30] + ([f"... and {len(found) - 30} more"] if len(found) > 30 else [])
    if approved:
        return 0, [f"::notice::Leo approved this port ({why}): {line}" for line in shown]
    out = [f"::error::Language boundary: {line}" for line in shown]
    out.append(
        "::error::Lawrence's rule, relayed by Leo: \"imessage home lives in swift, chat ui lives in react, "
        "acpmux/cmux-tui lives in rust, cmux cloud core should be rust (together with cmux-tui/acpmux) and should "
        "have very minimal in swift.\" Keep each area in its language (.github/language-boundaries.toml). Only Leo "
        f"lets a port through: the `{LABEL}` label plus his `{LABEL}:` comment. Not approved: {why}.")
    out.append("next: restore the deleted or moved files and drop the foreign-language ones; if the port is wanted, "
               f"ask Leo for `{LABEL}`")
    return 1, out


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--files", type=Path, required=True,
                        help="changed files: REST status/filename/previous_filename TSV or git --name-status -M")
    parser.add_argument("--labels-json", default="[]", help="the pull request's label names, a JSON list")
    parser.add_argument("--events", type=Path, default=None, help="issue events, JSON lines {event,label,actor,app}")
    parser.add_argument("--notes", type=Path, default=None, help="comments and reviews, JSON lines {user,body,app}")
    parser.add_argument("--manifest", type=Path, default=DEFAULT_MANIFEST)
    parser.add_argument("--expected-files", type=int, default=None, help="the pull request's changed_files")
    args = parser.parse_args(argv)
    try:
        areas = load(args.manifest)
    except (OSError, ValueError, tomllib.TOMLDecodeError) as exc:
        print(f"::error::Could not read the language-boundaries manifest: {exc}")
        print("next: fix .github/language-boundaries.toml on the base branch (its header is the schema)")
        return 3
    try:
        records = parse_records(args.files.read_text())
        labels = [str(name) for name in json.loads(args.labels_json or "[]")]
        events = read_jsonl(args.events)
        notes = read_jsonl(args.notes)
    except (OSError, ValueError, TypeError) as exc:
        print(f"::error::Could not read the pull request's files, labels or history: {exc}")
        print("next: re-run this check; nothing was decided")
        return 3
    code, lines = check(areas, records, labels, events, notes, args.expected_files)
    for line in lines:
        print(line)
    return code


if __name__ == "__main__":
    sys.exit(main())
