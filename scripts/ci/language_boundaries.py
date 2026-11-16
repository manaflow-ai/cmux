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
  2. its latest `labeled` event's actor is teamleaderleo, a User account, not through a GitHub App;
  3. a comment (not a review) by teamleaderleo, a User account, not through a GitHub App, has a line starting
     `leo-approved-port:` with a reason after it, and carries no agent footer (agent-identity's "Agent session:"
     deeplink, "Generated with [Claude Code]", "Co-Authored-By:", the robot emoji). A review never counts: GitHub
     reports the app behind an issue comment or event (`performed_via_github_app`) but not behind a review, in REST
     or GraphQL, so a review a GitHub App submitted on Leo's behalf looks like his own.
The limit, honestly: agents act on GitHub as teamleaderleo with Leo's own token, so GitHub cannot tell Leo's label
or comment from an agent's. (2) stops every other account and every bot; (3) stops an agent that follows the
rulebook's footer rule. An agent that adds the label and writes a bare approval line on purpose gets through; the
rulebook forbids it, and the approval line is in the PR's history for anyone to read.

A React port fails anywhere in the repo, keep area or not (Lawrence, relayed by Leo on 2026-11-11: "also let's not
move stuff to react anymore unless we talk about it / swift->rust is usually fine though"): one pull request that
removes Swift files on net and adds web files under the manifest's `[[react_port]]` `web` globs is the same feature
moving from Swift to React. It passes only when the `react-port-ok` label is on it and its latest `labeled` event's
actor is one of the table's `approvers` (Lawrence or Leo), a User account acting without a GitHub App. Swift to Rust
passes. The same limit as above holds for teamleaderleo, whose token agents share.

Changed files arrive as REST's JSON lines (`--format json`) or `git diff -z --name-status -M` (`--format git-z`):
both carry any path byte for byte. The TSV form (`--format tsv`) refuses a git-quoted path, since git quotes a path
with a quote, tab, newline or backslash in it, and the quoted form would match no area.

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
    # DOTALL and \Z: a path with a newline in it still matches `**`, and `$` never stops before a trailing one.
    return re.compile(r"\A" + "".join(out) + r"\Z", re.DOTALL)


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
    unknown = set(data) - {"area", "react_port"}
    if unknown:
        raise ValueError(f"unknown top-level keys {sorted(unknown)}; want only [[area]] and [[react_port]] tables")
    parse_react_port(text)
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


@dataclass
class ReactPort:
    """The manifest's `[[react_port]]` table: the label that lets a Swift-to-React port through, who may add it, and
    where new web code counts."""
    label: str
    approvers: list[str]
    web: list[str]
    regexes: list[re.Pattern[str]] = field(default_factory=list, repr=False)

    def covers(self, path: str) -> bool:
        return any(rx.match(path) for rx in self.regexes)


PORT_FIELDS = ("label", "approvers", "web")


def parse_react_port(text: str) -> ReactPort | None:
    """The manifest's one `[[react_port]]` table, or None when it has none. Malformed raises ValueError."""
    tables = tomllib.loads(text).get("react_port")
    if tables is None:
        return None
    if not isinstance(tables, list) or len(tables) != 1 or not isinstance(tables[0], dict):
        raise ValueError("want exactly one [[react_port]] table")
    raw = tables[0]
    missing = [key for key in PORT_FIELDS if key not in raw]
    extra = sorted(set(raw) - set(PORT_FIELDS))
    if missing or extra:
        raise ValueError(f"react_port: missing {missing}, unknown {extra}; want exactly {list(PORT_FIELDS)}")
    label, approvers, web = (raw[key] for key in PORT_FIELDS)
    if not isinstance(label, str) or not label:
        raise ValueError("react_port: label must be a non-empty string")
    for key, value in (("approvers", approvers), ("web", web)):
        if not isinstance(value, list) or not value or not all(isinstance(v, str) and v for v in value):
            raise ValueError(f"react_port: {key} must be a non-empty list of strings")
    return ReactPort(label, list(approvers), list(web), [glob_regex(p) for p in web])


def load_react_port(path: Path = DEFAULT_MANIFEST) -> ReactPort | None:
    return parse_react_port(path.read_text())


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


def _status(head: str) -> tuple[str, bool] | None:
    """(status, is_git) for a REST status word or a git `--name-status` letter (`R100`), None when unknown."""
    if head in REST_STATUS:
        return REST_STATUS[head], False
    if head[:1] in GIT_STATUS and (len(head) == 1 or head[1:].isdigit()):
        return GIT_STATUS[head[:1]], True
    return None


def _record(where: str, raw: object, status: str, path: str, old: str) -> Record:
    if not path:
        raise ValueError(f"{where}: no path in {raw!r}")
    if status in ("renamed", "copied") and not old:
        raise ValueError(f"{where}: a {status} record has no previous path: {raw!r}")
    return Record(status, path, old if status in ("renamed", "copied") else "")


def _git_quoted(path: str) -> bool:
    return len(path) >= 2 and path.startswith('"') and path.endswith('"')


def parse_records(text: str) -> list[Record]:
    """Changed files, one per line, either REST's `status<TAB>filename<TAB>previous_filename` or `git diff
    --name-status -M`'s `A<TAB>path` / `R100<TAB>old<TAB>new`. An unknown status or a git-quoted path raises
    ValueError (use parse_records_z or parse_records_json for any path)."""
    records = []
    for number, raw in enumerate(text.splitlines(), 1):
        if not raw.strip():
            continue
        parts = raw.split("\t")
        head = parts[0].strip()
        known = _status(head)
        if known is None:
            raise ValueError(f"line {number}: unknown status {head!r} in {raw!r}")
        status, is_git = known
        if is_git and status in ("renamed", "copied"):
            if len(parts) < 3:
                raise ValueError(f"line {number}: a {status} record needs old and new paths: {raw!r}")
            old, path = parts[1], parts[2]
        elif is_git:
            path, old = (parts[1] if len(parts) > 1 else ""), ""
        else:
            path = parts[1] if len(parts) > 1 else ""
            old = parts[2] if len(parts) > 2 else ""
        if _git_quoted(path) or _git_quoted(old):
            raise ValueError(f"line {number}: a git-quoted path, which matches no area; list the files with "
                             f"`git diff -z` or REST JSON: {raw!r}")
        records.append(_record(f"line {number}", raw, status, path, old))
    return records


def parse_records_z(data: bytes) -> list[Record]:
    """`git diff -z --name-status -M`: NUL-separated `A NUL path NUL` and `R100 NUL old NUL new NUL`, every path
    byte for byte (no quoting). Bytes that are not UTF-8 survive as surrogate escapes."""
    fields = data.decode("utf-8", "surrogateescape").split("\0")
    if fields and fields[-1] == "":
        fields.pop()
    records, i = [], 0
    while i < len(fields):
        head = fields[i].strip()
        known = _status(head)
        if known is None or not known[1]:
            raise ValueError(f"field {i + 1}: unknown git status {head!r}")
        status = known[0]
        width = 3 if status in ("renamed", "copied") else 2
        if i + width > len(fields):
            raise ValueError(f"field {i + 1}: a {status} record is cut short")
        raw = fields[i:i + width]
        old, path = (raw[1], raw[2]) if width == 3 else ("", raw[1])
        records.append(_record(f"field {i + 1}", raw, status, path, old))
        i += width
    return records


def parse_records_json(text: str) -> list[Record]:
    """REST's pull request files, one JSON object per line: {status, path, old} (filename and previous_filename
    as GitHub reports them, any character included)."""
    records = []
    for number, line in enumerate(text.splitlines(), 1):
        if not line.strip():
            continue
        item = json.loads(line)
        if not isinstance(item, dict) or not all(isinstance(item.get(k, ""), str) for k in ("status", "path", "old")):
            raise ValueError(f"line {number}: want an object of strings {{status, path, old}}: {line!r}")
        status = REST_STATUS.get(item.get("status", ""))
        if status is None:
            raise ValueError(f"line {number}: unknown status {item.get('status')!r}")
        records.append(_record(f"line {number}", line, status, item.get("path", ""), item.get("old", "")))
    return records


def read_records(path: Path, fmt: str) -> list[Record]:
    if fmt == "git-z":
        return parse_records_z(path.read_bytes())
    if fmt == "json":
        return parse_records_json(path.read_text())
    return parse_records(path.read_text())


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


def react_ports(port: ReactPort | None, records: list[Record]) -> list[str]:
    """One line when the pull request moves a feature from Swift to React (the module docstring's rule), else none.
    Swift anywhere counts; web counts only under the table's `web` globs."""
    if port is None:
        return []
    lost, gained, web = [], 0, []
    for rec in records:
        old = rec.path if rec.status == "removed" else (rec.old if rec.status == "renamed" else "")
        now_swift = rec.status != "removed" and language_of(rec.path) == "swift"
        if old and language_of(old) == "swift" and not now_swift:
            lost.append(old if rec.status == "removed" else f"{rec.old} -> {rec.path}")
        if now_swift and (rec.status in ("added", "copied")
                          or (rec.status == "renamed" and language_of(rec.old) != "swift")):
            gained += 1
        if rec.status != "removed" and language_of(rec.path) == "web" and port.covers(rec.path) and (
                rec.status in ("added", "copied")
                or (rec.status == "renamed" and (language_of(rec.old) != "web" or not port.covers(rec.old)))):
            web.append(rec.path)
    if len(lost) <= gained or not web:
        return []
    def shown(items: list[str]) -> str:
        return ", ".join(items[:5]) + (f" and {len(items) - 5} more" if len(items) > 5 else "")
    return [f"removes {len(lost) - gained} Swift file(s) net ({shown(lost)}) and adds {len(web)} web file(s) "
            f"({shown(web)})"]


def react_port_approval(port: ReactPort, labels: list[str], events: list[dict]) -> tuple[bool, str]:
    """(approved, why) for a React port. events: the PR's issue events ({event, label, actor, type, app}), oldest
    first. Only the latest `labeled` event for the label counts, and only from an approver acting as a User without a
    GitHub App."""
    if port.label not in labels:
        return False, f"the label `{port.label}` is not on the pull request"
    labeled = [e for e in events if e.get("event") == "labeled" and e.get("label") == port.label]
    if not labeled:
        return False, f"no `labeled` event for `{port.label}` was found"
    last = labeled[-1]
    actor = str(last.get("actor") or "")
    if _is_app(last, "actor") or actor.lower() not in {a.lower() for a in port.approvers}:
        how = " through a GitHub App or as a bot" if _is_app(last, "actor") else ""
        return False, f"`{port.label}` was last added by {actor!r}{how}, not by {' or '.join(port.approvers)}"
    return True, f"{actor} added `{port.label}`"


def _is_app(entry: dict, login_key: str) -> bool:
    """Made through a GitHub App or by a bot account: a `performed_via_github_app` slug, an author type that is not
    User (REST `type`, GraphQL `__typename`: Bot, Mannequin, or none reported), or a `[bot]` login."""
    return bool(entry.get("app")) or entry.get("type") != "User" or str(entry.get(login_key) or "").endswith("[bot]")


def leo_approval(labels: list[str], events: list[dict], notes: list[dict]) -> tuple[bool, str]:
    """(approved, why). events: the PR's issue events ({event, label, actor, type, app}), oldest first. notes: its
    comments and reviews ({user, type, body, app, source}); a note with source `review` never approves."""
    if LABEL not in labels:
        return False, f"the label `{LABEL}` is not on the pull request"
    labeled = [e for e in events if e.get("event") == "labeled" and e.get("label") == LABEL]
    if not labeled:
        return False, f"no `labeled` event for `{LABEL}` was found"
    last = labeled[-1]
    if last.get("actor") != LEO or _is_app(last, "actor"):
        return False, (f"`{LABEL}` was last added by {last.get('actor')!r}"
                       f"{' through a GitHub App or as a bot' if _is_app(last, 'actor') else ''}, not by {LEO}")
    review_only = False
    for note in notes:
        body = str(note.get("body") or "")
        if note.get("user") != LEO or _is_app(note, "user"):
            continue
        if any(marker in body.lower() for marker in AGENT_MARKERS):
            continue
        if any(APPROVAL_LINE.match(line.strip()) for line in body.splitlines()):
            if note.get("source") == "review":
                review_only = True
                continue
            return True, f"{LEO} added `{LABEL}` and wrote a `{LABEL}:` approval"
    where = (" (a review has one, but a review never counts: GitHub does not say whether an app submitted it)"
             if review_only else "")
    return False, (f"{LEO} added `{LABEL}`, but no comment by {LEO} without an agent footer has a line starting "
                   f"`{LABEL}:` with his reason{where}. Leo writes that line as a PR comment, then removes and "
                   f"re-adds the label to re-run this check")


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


REACT_RULE = ("Lawrence, relayed by Leo (2026-11-11): \"also let's not move stuff to react anymore unless we talk "
              "about it / swift->rust is usually fine though\"")


def check(areas: list[Area], records: list[Record], labels: list[str], events: list[dict], notes: list[dict],
          expected_files: int | None = None, port: ReactPort | None = None) -> tuple[int, list[str]]:
    """(exit code, annotation lines). PORT is the manifest's `[[react_port]]` table (None: no React-port rule)."""
    approved, why = leo_approval(labels, events, notes)
    paths = {r.path for r in records}
    if expected_files is not None and len(records) < expected_files and not approved:
        return 1, [f"::error::The changed-file listing has {len(records)} files but the pull request changes "
                   f"{expected_files}; a boundary change may be past its end.",
                   "next: split the pull request"]
    ported = react_ports(port, records)
    port_lines: list[str] = []
    if ported and port is not None:
        port_ok, port_why = react_port_approval(port, labels, events)
        if port_ok:
            port_lines = [f"::notice::React port approved ({port_why}): {ported[0]}"]
        else:
            port_lines = [f"::error::Refused a Swift-to-React port: {ported[0]}. Talk to Lawrence or Leo, then they "
                          f"add {port.label} ({port_why}).", f"::error::{REACT_RULE}"]
    port_failed = any(line.startswith("::error::") for line in port_lines)
    found = violations(areas, records)
    if not found:
        if port_failed:
            return 1, port_lines + [f"next: talk to Lawrence or Leo, then they add {port.label}"]
        return 0, port_lines + [f"::notice::Every area keeps its language ({len(paths)} changed files, "
                                ".github/language-boundaries.toml)."]
    shown = found[:30] + ([f"... and {len(found) - 30} more"] if len(found) > 30 else [])
    if approved:
        out = port_lines + [f"::notice::Leo approved this port ({why}): {line}" for line in shown]
        return (1 if port_failed else 0), out
    out = port_lines + [f"::error::Language boundary: {line}" for line in shown]
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
    parser.add_argument("--files", type=Path, required=True, help="the changed files, in --format")
    parser.add_argument("--format", choices=("json", "git-z", "tsv"), default="tsv",
                        help="json: REST JSON lines {status,path,old}; git-z: git diff -z --name-status -M; "
                             "tsv: REST status/filename/previous_filename or git --name-status -M (no quoted paths)")
    parser.add_argument("--labels-json", default="[]", help="the pull request's label names, a JSON list")
    parser.add_argument("--events", type=Path, default=None, help="issue events, JSON lines {event,label,actor,type,app}")
    parser.add_argument("--notes", type=Path, default=None, help="comments and reviews, JSON lines {user,type,body,app,source}")
    parser.add_argument("--manifest", type=Path, default=DEFAULT_MANIFEST)
    parser.add_argument("--expected-files", type=int, default=None, help="the pull request's changed_files")
    args = parser.parse_args(argv)
    try:
        areas = load(args.manifest)
        port = load_react_port(args.manifest)
    except (OSError, ValueError, tomllib.TOMLDecodeError) as exc:
        print(f"::error::Could not read the language-boundaries manifest: {exc}")
        print("next: fix .github/language-boundaries.toml on the base branch (its header is the schema)")
        return 3
    try:
        records = read_records(args.files, args.format)
        labels = [str(name) for name in json.loads(args.labels_json or "[]")]
        events = read_jsonl(args.events)
        notes = read_jsonl(args.notes)
    except (OSError, ValueError, TypeError) as exc:
        print(f"::error::Could not read the pull request's files, labels or history: {exc}")
        print("next: re-run this check; nothing was decided")
        return 3
    code, lines = check(areas, records, labels, events, notes, args.expected_files, port)
    for line in lines:
        print(line)
    return code


if __name__ == "__main__":
    sys.exit(main())
