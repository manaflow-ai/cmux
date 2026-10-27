#!/usr/bin/env python3
"""Refactor switch registry: one plans/cmux-next/refactor-switches/<name>.json per switch.

Spec: plans/cmux-next/chrome-parity/p15-oracle.md, sections 3F.2 and 3I, task p15-oracle-018.
Schema: schemas/oracle/refactor-switches.schema.json. Stdlib only, Python 3.9+, safe under `python3 -I`.

Chrome reference (chromium/src):
- chrome/browser/flag-metadata.json: every flag has `owners` and an `expiry_milestone`;
  chrome/browser/about_flags_unittest.cc refuses an entry with no owner.
- tools/flags/generate_expired_list.py: the expired flags are a list that the build reads.
- base/feature_list.h: the FeatureList is built once before the first read, then frozen. A site asks
  the frozen value; it never reads its own source again.
- third_party/blink/web_tests/FlagExpectations/: the expected differences of one flag configuration
  (`expected_differences` here, read by diff.py --expected FILE).

Usage:
    switches.py --check [--registry DIR]      exit 0: every switch passes; 1: findings; 2: bad usage
    switches.py --expired [--today YYYY-MM-DD] one deletion task per switch whose `expires` day has come
                                               (exit 0: none, 1: some, 2: a file whose day is unreadable)
    switches.py --hits FILE --switch NAME --arm old|new
                                               the verdict of one debug.oracle.switch_hits result
                                               (exit 0: exercised, 1: arm-not-exercised or arm-mixed, 2: bad input)
    switches.py --selftest                    the refusal table below, on temporary registries
`oracle.py switches ARGS` runs this script with ARGS.

`--hits` (task p15-oracle-027) reads the per-site hit counters the app reports through
`debug.oracle.switch_hits` (`SwitchHits.swift`): `{"switches": {KEY: {"old": N, "new": N, "sites":
{SITE: {"old": N, "new": N}}}}}`, KEY the registry entry's `app_key` (the golden reply both sides test
is schemas/oracle/fixtures/switch-hits-reply.json). It prints one line
    NAME arm=ARM verdict=VERDICT key=app:KEY old=N new=N sites=SITE:old=N/new=N,...
A daemon switch (`daemon_key`) is refused as bad input: only app sites count hits; the daemon has no
hit source yet, so every daemon run would read as arm-not-exercised.
`exercised` needs hits on the requested arm and none on the other. 0 hits on the requested arm (or no
entry) is `arm-not-exercised`: the run never reached a guarded site on that arm, so its diff proves
nothing. Hits on the other arm too are `arm-mixed`: a site does not read the frozen value. Chrome
reports a field trial only once `FeatureList::IsEnabled` activated it (base/feature_list.cc), so a
configured trial that no code queried reports nothing; here the site counts the branch it took.

`--check` refuses, per file:
- a file that does not parse or does not match the schema (normalize.py's validator, task 013):
  a missing `planned`, `owner` or `plan`, an unknown field, a bad arm, no key or two keys;
- a `name` that is not the file stem;
- `expires` before `created`, or more than MAX_LIFETIME_DAYS (14) after it;
- an app key that is not a raw value of `enum RefactorSwitchKey` in APP_CATALOG (task 180);
- a daemon key that is not in `SWITCH_NAMES` of DAEMON_CATALOG (task 020): the daemon would not parse it;
- an app switch that a Swift source reads through a per-call closure (see `closure_reads`);
- a `plan` or `old_paths` entry that does not exist, a suite that baselines.py does not classify,
  and an `expected_differences` list that diff.py refuses.
`--check` does not read the date: an expired switch is the `--expired` queue (task 171), not a refusal.

`bisect_switch_set(candidates, probe, seed=N)` (task p15-oracle-183) is the search of `oracle.py bisect-switches
CASE`: the smallest set of switches at their `planned` arm whose run of CASE diverges from all-default. ddmin over
an order shuffled by the seed, then every smaller set in that order (up to max_proof_probes) to prove it the
smallest; the same seed and probe answers give the same probes. `--selftest` plants interactions and checks it.

`--expired` (MQ-switch-expiry) prints, by `expires` day then name, one line per switch:
    NAME expired=DAY owner=OWNER key=app:KEY|daemon:KEY catalog=PATH default=ARM keep=ARM delete=P1,P2,...
`keep` is the `planned` arm. `delete` is the old arm's `old_paths` (only when `keep` is new) and the
registry file; the owner also removes KEY's case from `catalog` and its reads. Values are shell-quoted.

Catalog contracts this file reads (the producing tasks must keep them):
- APP_CATALOG declares `enum RefactorSwitchKey: String` with one `case name = "raw.value"` (or a bare
  `case name`, raw value = name) per switch. A site names a switch as `RefactorSwitchKey.name` or as
  `.name` in the argument of `arm(_:)`, `isNew(_:)` or `isOld(_:)`.
- DAEMON_CATALOG declares `SWITCH_NAMES: &[&str] = &["name", ...];`, the names CMUX_TUI_SWITCHES accepts.
"""

from __future__ import annotations

import argparse
import datetime as dt
import importlib
import io
import itertools
import json
import math
import random
import re
import shlex
import shutil
import sys
import tempfile
from contextlib import redirect_stderr, redirect_stdout
from dataclasses import dataclass, replace
from pathlib import Path
from typing import Any, Callable, Dict, List, Optional, Sequence, Set, Tuple

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[2]
TASK = "p15-oracle-018"
REGISTRY = REPO / "plans" / "cmux-next" / "refactor-switches"
# The `debug.oracle.switch_hits` reply SwitchHitsTests encodes; --selftest reads the same file.
GOLDEN_HITS = REPO / "schemas" / "oracle" / "fixtures" / "switch-hits-reply.json"
SCHEMA = REPO / "schemas" / "oracle" / "refactor-switches.schema.json"
APP_CATALOG = REPO / "Packages" / "macOS" / "CmuxNext" / "Sources" / "CmuxNextCompat" / "RefactorSwitches.swift"
DAEMON_CATALOG = REPO / "cmux-tui" / "crates" / "cmux-tui-core" / "src" / "switches.rs"
SWIFT_ROOT = REPO / "Packages" / "macOS" / "CmuxNext" / "Sources"
APP_CATALOG_TASK = "p15-oracle-180"
DAEMON_CATALOG_TASK = "p15-oracle-020"
MAX_LIFETIME_DAYS = 14


class UsageError(Exception):
    """A missing sibling script, schema or registry directory: exit 2."""


@dataclass(frozen=True)
class Finding:
    path: str
    message: str

    def __str__(self) -> str:
        return f"{self.path}: {self.message}"


@dataclass(frozen=True)
class Roots:
    """Every input of a check; tests point them at a temporary tree."""

    repo: Path = REPO
    registry: Path = REGISTRY
    schema: Path = SCHEMA
    app_catalog: Path = APP_CATALOG
    daemon_catalog: Path = DAEMON_CATALOG
    swift_root: Path = SWIFT_ROOT


def load_sibling(module: str, task: str) -> Any:
    """Imports scripts/cmux-next/oracle/<module>.py. `python3 -I` leaves this directory off sys.path."""
    if not (HERE / f"{module}.py").is_file():
        raise UsageError(f"{module}.py is not on this branch ({task})")
    if str(HERE) not in sys.path:
        sys.path.insert(0, str(HERE))
    return importlib.import_module(module)


# ---------------------------------------------------------------------------------------------------------
# Swift and Rust text: comments and string literals out, so a name in a doc comment is not a read


_SWIFT_TOKENS = re.compile(r'"""[\s\S]*?"""|"(?:\\.|[^"\\\n])*"|//[^\n]*|/\*[\s\S]*?\*/')


def strip_swift(text: str) -> str:
    """Comments and string literals become spaces; newlines stay, so line numbers do not move."""

    def blank(match: "re.Match[str]") -> str:
        return re.sub(r"[^\n]", " ", match.group(0))

    return _SWIFT_TOKENS.sub(blank, text)


def app_catalog(path: Path) -> Optional[Dict[str, str]]:
    """Raw value -> case name of `enum RefactorSwitchKey`, or None when the file is not on this branch."""
    if not path.is_file():
        return None
    code = strip_swift(path.read_text(encoding="utf-8"))
    raw_text = path.read_text(encoding="utf-8")
    match = re.search(r"\benum\s+RefactorSwitchKey\b[^{]*\{", code)
    if match is None:
        return {}
    depth, end = 1, match.end()
    while end < len(code) and depth:
        depth += {"{": 1, "}": -1}.get(code[end], 0)
        end += 1
    body_code, body_raw = code[match.end():end - 1], raw_text[match.end():end - 1]
    keys: Dict[str, str] = {}
    for case in re.finditer(r"\bcase\b([^\n;]*)", body_code):
        # The raw text keeps the string literals the stripped text blanked; offsets are the same.
        declaration = body_raw[case.start(1):case.end(1)]
        for item in declaration.split(","):
            named = re.match(r'\s*`?([A-Za-z_][A-Za-z0-9_]*)`?\s*(?:=\s*"([^"]*)")?\s*$', item)
            if named:
                keys[named.group(2) if named.group(2) is not None else named.group(1)] = named.group(1)
    return keys


def daemon_catalog(path: Path) -> Optional[Set[str]]:
    """The string literals of `SWITCH_NAMES`, or None when switches.rs is not on this branch."""
    if not path.is_file():
        return None
    text = re.sub(r"//[^\n]*", "", path.read_text(encoding="utf-8"))
    match = re.search(r"\bSWITCH_NAMES\s*:\s*&\s*\[\s*&\s*(?:'static\s+)?str\s*\]\s*=\s*&\s*\[([^\]]*)\]", text)
    if match is None:
        return set()
    return set(re.findall(r'"([^"\\]*)"', match.group(1)))


# ---------------------------------------------------------------------------------------------------------
# Per-call closure reads


# The opening brace of a closure literal follows one of these: an argument or default value
# (`isEnabled: {`, `= {`, `({`, `, {`, `[{`) or a returned closure (`return {`). A trailing closure
# (`.map {`) and a body (`) {`, `Bool {`) follow an identifier or `)`.
_CLOSURE_OPENERS = re.compile(r"(?:[(,:=\[]|\breturn)\s*$")


_SWITCH_MENTION = re.compile(r"\bRefactorSwitchKey\b|\b(?:arm|isNew|isOld)\s*\(\s*\.")


def key_reference(case: str) -> "re.Pattern[str]":
    name = re.escape(case)
    return re.compile(rf"\bRefactorSwitchKey\s*\.\s*{name}\b|\b(?:arm|isNew|isOld)\s*\(\s*\.\s*{name}\b")


def closure_reads(text: str, case: str) -> List[int]:
    """1-based lines where a closure literal is only a read of the switch `case`.

    `isEnabled: { switches.isNew(.layerHosting) }` hands the site a closure that reads the switch at
    each call, the TunableStore pattern that let one process run both arms (p15-oracle.md 2.6). A switch
    is a frozen value: the owner passes the arm (or RefactorSwitches) itself. A closure that does more
    than return the read (a handler with statements) is a use at that time, not a per-call read.
    """
    code = strip_swift(text)
    lines: List[int] = []
    for match in key_reference(case).finditer(code):
        depth, start = 0, match.start() - 1
        while start >= 0:
            char = code[start]
            if char == "}":
                depth += 1
            elif char == "{":
                if depth == 0:
                    break
                depth -= 1
            start -= 1
        if start < 0 or not _CLOSURE_OPENERS.search(code[max(0, start - 16):start]):
            continue
        depth, end = 1, start + 1
        while end < len(code) and depth:
            depth += {"{": 1, "}": -1}.get(code[end], 0)
            end += 1
        body = code[start + 1:end - 1]
        statements = [line for line in body.split("\n") if line.strip()]
        if "{" not in body and ";" not in body and len(statements) == 1:
            lines.append(code.count("\n", 0, match.start()) + 1)
    return lines


def swift_sources(root: Path) -> List[Tuple[Path, str]]:
    """Every Swift file under root that names RefactorSwitchKey or a switch accessor, read once."""
    sources: List[Tuple[Path, str]] = []
    if root.is_dir():
        for path in sorted(root.rglob("*.swift")):
            try:
                text = path.read_text(encoding="utf-8")
            except (OSError, UnicodeDecodeError):
                continue
            if _SWITCH_MENTION.search(text):
                sources.append((path, text))
    return sources


# ---------------------------------------------------------------------------------------------------------
# --check


def parse_day(value: Any) -> Optional[dt.date]:
    if not isinstance(value, str):
        return None
    try:
        return dt.date.fromisoformat(value)
    except ValueError:
        return None


def relative(path: Path, repo: Path) -> str:
    try:
        return str(path.relative_to(repo))
    except ValueError:
        return str(path)


def load_entry(path: Path) -> Tuple[Optional[Dict[str, Any]], Optional[str]]:
    normalize = load_sibling("normalize", "p15-oracle-013")
    try:
        data = normalize.parse_json(path.read_text(encoding="utf-8"))
    except normalize.OracleError as error:
        return None, str(error)
    if not isinstance(data, dict):
        return None, "a switch file is a JSON object"
    return data, None


def check_entry(path: Path, data: Dict[str, Any], schema: Any, roots: Roots, apps: Optional[Dict[str, str]],
                daemons: Optional[Set[str]], sources: Sequence[Tuple[Path, str]]) -> List[Finding]:
    normalize = load_sibling("normalize", "p15-oracle-013")
    where = relative(path, roots.repo)
    errors = normalize.validate(data, schema)
    if errors:
        return [Finding(where, error) for error in errors]
    findings: List[Finding] = []

    def refuse(message: str) -> None:
        findings.append(Finding(where, message))

    if data["name"] != path.stem:
        refuse(f"name {data['name']!r} is not the file stem {path.stem!r}")
    created, expires = parse_day(data["created"]), parse_day(data["expires"])
    if created is None:
        refuse(f"created {data['created']!r} is not a day (YYYY-MM-DD)")
    if expires is None:
        refuse(f"expires {data['expires']!r} is not a day (YYYY-MM-DD)")
    if created and expires:
        lifetime = (expires - created).days
        if lifetime < 0:
            refuse(f"expires {expires} is before created {created}")
        elif lifetime > MAX_LIFETIME_DAYS:
            refuse(f"expires {expires} is {lifetime} days after created {created}; the limit is {MAX_LIFETIME_DAYS}")

    if "app_key" in data:
        key = data["app_key"]
        if apps is None:
            refuse(f"app key {key!r}: {relative(roots.app_catalog, roots.repo)} is not on this branch ({APP_CATALOG_TASK})")
        elif key not in apps:
            known = ", ".join(sorted(apps)) or "none"
            refuse(f"unknown app key {key!r}: not a RefactorSwitchKey raw value in "
                   f"{relative(roots.app_catalog, roots.repo)} (known: {known})")
        else:
            case = apps[key]
            for source, text in sources:
                for line in closure_reads(text, case):
                    refuse(f"{data['read']} switch {key!r} is read through a per-call closure at "
                           f"{relative(source, roots.repo)}:{line}; pass the frozen arm, not a closure")
    else:
        key = data["daemon_key"]
        if daemons is None:
            refuse(f"daemon key {key!r}: {relative(roots.daemon_catalog, roots.repo)} is not on this branch "
                   f"({DAEMON_CATALOG_TASK})")
        elif key not in daemons:
            known = ", ".join(sorted(daemons)) or "none"
            refuse(f"daemon key {key!r} is not parsed: not in SWITCH_NAMES of "
                   f"{relative(roots.daemon_catalog, roots.repo)} (known: {known})")

    plan = data["plan"].partition("#")[0]
    if not (roots.repo / plan).is_file():
        refuse(f"plan {plan} does not exist")
    for old in data.get("old_paths", []):
        if not (roots.repo / old).exists():
            refuse(f"old path {old} does not exist")

    baselines = load_sibling("baselines", "p15-oracle-016")
    for suite in data["suites"]:
        if suite not in baselines.SUITE_CLASSES:
            refuse(f"suite {suite!r} is not in baselines.py SUITE_CLASSES")

    diff = load_sibling("diff", "p15-oracle-014")
    try:
        diff.load_rules(str(path))
    except diff.InputError as error:
        refuse(f"diff.py refuses expected_differences: {error}")
    return findings


def check(roots: Roots) -> Tuple[List[Finding], int]:
    """Findings of every registry file, and the number of files read."""
    if not roots.registry.is_dir():
        raise UsageError(f"{roots.registry}: no registry directory")
    normalize = load_sibling("normalize", "p15-oracle-013")
    try:
        schema = normalize.Schema(normalize.parse_json(roots.schema.read_text(encoding="utf-8")), str(roots.schema))
    except (OSError, normalize.OracleError) as error:
        raise UsageError(f"{roots.schema}: {error}") from None
    apps, daemons = app_catalog(roots.app_catalog), daemon_catalog(roots.daemon_catalog)
    findings: List[Finding] = []
    paths = sorted(roots.registry.glob("*.json"))
    sources = swift_sources(roots.swift_root) if paths and apps else []
    for path in paths:
        data, error = load_entry(path)
        if data is None:
            findings.append(Finding(relative(path, roots.repo), error or "unreadable"))
            continue
        findings.extend(check_entry(path, data, schema, roots, apps, daemons, sources))
    return findings, len(paths)


# ---------------------------------------------------------------------------------------------------------
# --expired (task p15-oracle-171): the MQ-switch-expiry queue, one deletion task per switch


@dataclass(frozen=True)
class DeletionTask:
    """What the owner deletes when a switch's `expires` day has come (chrome tools/flags/list-flags.py
    --expired-by lists the flags past their milestone the same way: one row per flag, with its owners)."""

    name: str
    expires: dt.date
    owner: str
    key: str
    catalog: str
    default: str
    keep: str
    delete: Tuple[str, ...]

    def line(self) -> str:
        """`NAME expired=DAY owner=O key=app:K catalog=PATH default=A keep=A delete=P1,P2`, shell-quoted
        values (`shlex.split` reads it back), so an owner with a space stays one field."""
        fields = (("expired", str(self.expires)), ("owner", self.owner), ("key", self.key),
                  ("catalog", self.catalog), ("default", self.default), ("keep", self.keep),
                  ("delete", ",".join(self.delete)))
        return " ".join([shlex.quote(self.name)] + [f"{label}={shlex.quote(value)}" for label, value in fields])


def deletion_task(path: Path, data: Dict[str, Any], day: dt.date, roots: Roots) -> DeletionTask:
    """The registry file always goes; the old arm's files go only when the refactor keeps the new arm.
    A switch planned at `old` is a refactor given up: its old paths stay and the key's reads go."""
    keep = str(data.get("planned", "-"))
    if "app_key" in data:
        key, catalog = f"app:{data['app_key']}", roots.app_catalog
    else:
        key, catalog = f"daemon:{data.get('daemon_key', '-')}", roots.daemon_catalog
    old_paths = [str(old) for old in data.get("old_paths") or []] if keep == "new" else []
    return DeletionTask(name=path.stem, expires=day, owner=str(data.get("owner") or "-"), key=key,
                        catalog=relative(catalog, roots.repo), default=str(data.get("default", "-")), keep=keep,
                        delete=tuple(old_paths + [relative(path, roots.repo)]))


def expired(roots: Roots, today: dt.date) -> Tuple[List[DeletionTask], List[Finding]]:
    """The deletion tasks of every switch whose `expires` day is today or earlier, by day then name, and
    the files whose day cannot be read: such a file is reported, never dropped from the queue unseen."""
    if not roots.registry.is_dir():
        raise UsageError(f"{roots.registry}: no registry directory")
    tasks: List[DeletionTask] = []
    unread: List[Finding] = []
    for path in sorted(roots.registry.glob("*.json")):
        where = relative(path, roots.repo)
        data, error = load_entry(path)
        if data is None:
            unread.append(Finding(where, f"{error or 'unreadable'}; its expiry is unknown (run --check)"))
            continue
        day = parse_day(data.get("expires"))
        if day is None:
            unread.append(Finding(where, f"expires {data.get('expires')!r} is not a day (YYYY-MM-DD); its expiry is unknown"))
            continue
        if day <= today:
            tasks.append(deletion_task(path, data, day, roots))
    return sorted(tasks, key=lambda task: (task.expires, task.name)), unread


# ---------------------------------------------------------------------------------------------------------
# --hits (p15-oracle-027)


ARMS = ("old", "new")
EXERCISED = "exercised"
NOT_EXERCISED = "arm-not-exercised"
MIXED = "arm-mixed"


@dataclass(frozen=True)
class HitVerdict:
    """What the hit counters say about one arm of one switch. `exercised`: a guarded site ran the
    requested arm and none ran the other. `arm-not-exercised`: no site ran the requested arm, so the
    run proves nothing about it (a missing entry counts as 0 hits). `arm-mixed`: a site ran the other
    arm too, so the switch is not frozen at that site (the per-call read of p15-oracle.md 2.6)."""

    name: str
    key: str
    arm: str
    verdict: str
    hits: Dict[str, int]
    sites: Tuple[Tuple[str, int, int], ...]

    @property
    def ok(self) -> bool:
        return self.verdict == EXERCISED

    def line(self) -> str:
        """`NAME arm=A verdict=V key=app:K old=N new=N sites=SITE:old=N/new=N,...`, shell-quoted values."""
        sites = ",".join(f"{site}:old={old}/new={new}" for site, old, new in self.sites) or "-"
        fields = (("arm", self.arm), ("verdict", self.verdict), ("key", self.key), ("old", str(self.hits["old"])),
                  ("new", str(self.hits["new"])), ("sites", sites))
        return " ".join([shlex.quote(self.name)] + [f"{label}={shlex.quote(value)}" for label, value in fields])


def hit_count(value: Any, where: str) -> int:
    if isinstance(value, bool) or not isinstance(value, (int, float)) or value < 0 or value != int(value):
        raise UsageError(f"{where}: a hit count is a whole number >= 0, got {value!r}")
    return int(value)


def hit_verdict(report: Any, name: str, key: str, arm: str) -> HitVerdict:
    """The verdict on `arm` of the switch `key` from one `debug.oracle.switch_hits` result:
    `{"switches": {KEY: {"old": N, "new": N, "sites": {SITE: {"old": N, "new": N}}}}}`.
    `key` is the registry entry's `app:KEY`; the report, made by the app, is keyed by the bare KEY.
    A `daemon:KEY` is refused: the daemon has no hit source, so the app report says nothing about it."""
    if key.startswith("daemon:"):
        raise UsageError(f"{name}: {key} is a daemon switch; only app sites report switch hits "
                         "(the daemon has no hit source), so --hits cannot judge it")
    if arm not in ARMS:
        raise UsageError(f"arm {arm!r} is not one of {', '.join(ARMS)}")
    switches = report.get("switches") if isinstance(report, dict) else None
    if not isinstance(switches, dict):
        raise UsageError('a switch_hits report is an object with a "switches" object')
    bare = key.partition(":")[2] or key
    entry = switches.get(bare, {})
    if not isinstance(entry, dict):
        raise UsageError(f"switches[{bare!r}] is not an object")
    counts = {side: hit_count(entry.get(side, 0), f"{bare} {side}") for side in ARMS}
    raw_sites = entry.get("sites", {})
    if not isinstance(raw_sites, dict):
        raise UsageError(f"{bare} sites is not an object")
    sites: List[Tuple[str, int, int]] = []
    for site in sorted(raw_sites):
        arms = raw_sites[site]
        if not isinstance(arms, dict):
            raise UsageError(f"{bare} site {site!r} is not an object")
        sites.append((site, hit_count(arms.get("old", 0), f"{site} old"), hit_count(arms.get("new", 0), f"{site} new")))
    other = "new" if arm == "old" else "old"
    if counts[arm] == 0:
        verdict = NOT_EXERCISED
    elif counts[other] > 0:
        verdict = MIXED
    else:
        verdict = EXERCISED
    return HitVerdict(name=name, key=key, arm=arm, verdict=verdict, hits=counts, sites=tuple(sites))


def switch_key(roots: Roots, name: str) -> str:
    """`app:KEY` or `daemon:KEY` of the registry entry `name` (hit_verdict refuses a daemon key)."""
    path = roots.registry / f"{name}.json"
    where = relative(path, roots.repo)
    if not path.is_file():
        raise UsageError(f"{where}: no such switch")
    data, error = load_entry(path)
    if data is None:
        raise UsageError(f"{where}: {error}")
    if isinstance(data.get("app_key"), str):
        return f"app:{data['app_key']}"
    if isinstance(data.get("daemon_key"), str):
        return f"daemon:{data['daemon_key']}"
    raise UsageError(f"{where}: no app_key or daemon_key (run --check)")


def hits(roots: Roots, report_path: Path, name: str, arm: str) -> HitVerdict:
    """`--hits FILE --switch NAME --arm ARM`: FILE holds one `debug.oracle.switch_hits` result."""
    normalize = load_sibling("normalize", "p15-oracle-013")
    try:
        report = normalize.parse_json(report_path.read_text(encoding="utf-8"))
    except OSError as error:
        raise UsageError(f"{report_path}: {error.strerror or error}") from error
    except normalize.OracleError as error:
        raise UsageError(f"{report_path}: {error}") from error
    return hit_verdict(report, name, switch_key(roots, name), arm)


# ---------------------------------------------------------------------------------------------------------
# bisect-switches (task p15-oracle-183): the smallest switch set at its planned arm that makes one case
# diverge from all-default. `oracle.py bisect-switches CASE` runs the probes; this is the search.


PROBE_DIVERGENT, PROBE_SAME = "divergent", "same"
# Probe sizes the smallest-set proof may spend after ddmin; past it the answer is only 1-minimal.
DEFAULT_MAX_PROOF_PROBES = 64

# A probe: the sorted switch names set to their planned arm (every other switch at its default) to the
# verdict of the case against all-default: PROBE_DIVERGENT, PROBE_SAME, or anything else (flaky, refused),
# which stops the search because no later answer could be trusted.
Probe = Callable[[Tuple[str, ...]], str]


@dataclass(frozen=True)
class BisectResult:
    """verdict: found (switches is the set), not-reproducible (the whole set does not diverge) or unreliable
    (a probe answered neither divergent nor same; reason names it). minimality: smallest (no smaller set
    diverges: every smaller one was probed) or 1-minimal (dropping any one switch stops the divergence)."""

    verdict: str
    order: Tuple[str, ...]
    switches: Tuple[str, ...] = ()
    minimality: Optional[str] = None
    probes: Tuple[Tuple[Tuple[str, ...], str], ...] = ()
    reason: Optional[str] = None


class _Unreliable(Exception):
    pass


def _chunks(items: Sequence[str], n: int) -> List[Tuple[str, ...]]:
    size, extra = divmod(len(items), n)
    out, start = [], 0
    for index in range(n):
        end = start + size + (1 if index < extra else 0)
        out.append(tuple(items[start:end]))
        start = end
    return out


def bisect_switch_set(candidates: Sequence[str], probe: Probe, *, seed: int,
                      max_proof_probes: int = DEFAULT_MAX_PROOF_PROBES) -> BisectResult:
    """Delta debugging (Zeller and Hildebrandt, "Simplifying and Isolating Failure-Inducing Input", 2002)
    over the switches in a seeded order, then a size-ascending search below ddmin's answer to prove it the
    smallest. Chrome's tools/variations/bisect_variations.py halves a field-trial config to one culprit
    study; ddmin also finds an interaction of several. The same seed and probe answers give the same probes."""
    order = sorted(set(candidates))
    random.Random(seed).shuffle(order)
    answers: Dict[frozenset, bool] = {}
    log: List[Tuple[Tuple[str, ...], str]] = []

    def diverges(subset: Sequence[str]) -> bool:
        key = frozenset(subset)
        if not key:
            return False  # all-default against itself: confirm.py's question, not a switch's
        if key not in answers:
            names = tuple(sorted(key))
            verdict = probe(names)
            log.append((names, verdict))
            if verdict not in (PROBE_DIVERGENT, PROBE_SAME):
                raise _Unreliable(f"probe {','.join(names)}: {verdict}")
            answers[key] = verdict == PROBE_DIVERGENT
        return answers[key]

    def result(verdict: str, **fields: Any) -> BisectResult:
        return BisectResult(verdict, tuple(order), probes=tuple(log), **fields)

    if not order:
        return result("not-reproducible", reason="no switch has a planned arm unlike its default")
    try:
        if not diverges(order):
            return result("not-reproducible", reason="every switch at its planned arm does not diverge")
        items: List[str] = list(order)
        n = 2
        while len(items) >= 2:
            chunks = _chunks(items, n)
            subset = next((c for c in chunks if diverges(c)), None)
            if subset is not None:
                items, n = list(subset), 2
                continue
            complement = next((rest for rest in ([x for x in items if x not in c] for c in chunks)
                               if n > 2 and diverges(rest)), None)
            if complement is not None:
                items, n = complement, max(n - 1, 2)
                continue
            if n >= len(items):
                break
            n = min(len(items), 2 * n)
        smaller_total = sum(math.comb(len(order), size) for size in range(1, len(items)))
        answered = sum(1 for key in answers if len(key) < len(items))
        if smaller_total - answered > max_proof_probes:
            return result("found", switches=tuple(sorted(items)), minimality="1-minimal")
        smaller = (combo for size in range(1, len(items)) for combo in itertools.combinations(order, size))
        found = next((combo for combo in smaller if diverges(combo)), None)
        return result("found", switches=tuple(sorted(found or items)), minimality="smallest")
    except _Unreliable as error:
        return result("unreliable", reason=str(error))


# ---------------------------------------------------------------------------------------------------------
# --selftest


SELFTEST_SWIFT_CATALOG = """
/// Doc text that names case ghost = "ghost.key" is not a case.
public enum RefactorSwitchKey: String, Sendable, CaseIterable {
    case layerHosting = "browser.layer-hosting"
    case cefHelper = "browser.cef-helper", intents
}
"""
SELFTEST_RUST_CATALOG = """
// "commented" is not a name.
pub const SWITCH_NAMES: &[&str] = &["holder", "discard"];
"""
SELFTEST_GOOD_SITE = """
final class Host {
    init(layerHosting: Bool) {}
    static func make(switches: RefactorSwitches) -> Host {
        Host(layerHosting: switches.isNew(.layerHosting))
    }
    func tap(switches: RefactorSwitches) {
        button.onTap = {
            let arm = switches.arm(.cefHelper)
            log(arm)
        }
    }
    // isEnabled: { switches.isNew(.layerHosting) } in a comment is not a read.
}
"""
SELFTEST_CLOSURE_SITE = """
final class Hosting {
    init(isEnabled: @escaping () -> Bool = { false }) {}
    static func make(switches: RefactorSwitches) -> Hosting {
        Hosting(isEnabled: {
            switches.isNew(.layerHosting)
        })
    }
}
"""


def selftest_entry(**overrides: Any) -> Dict[str, Any]:
    entry: Dict[str, Any] = {
        "name": "layer-hosting",
        "owner": "perf-lead",
        "plan": "plans/plan.md#f1",
        "read": "live",
        "app_key": "browser.layer-hosting",
        "default": "old",
        "planned": "new",
        "created": "2026-10-25",
        "expires": "2026-11-08",
        "suites": ["actions"],
        "expected_differences": [{"pointer": "/layout", "reason": "the new arm hosts the page layer", "task": "p03-rendering-001"}],
        "old_paths": ["Sources/Old.swift"],
    }
    for key, value in overrides.items():
        if value is None:
            entry.pop(key, None)
        else:
            entry[key] = value
    return entry


def daemon_entry(**overrides: Any) -> Dict[str, Any]:
    return selftest_entry(**{"name": "holder", "app_key": None, "daemon_key": "holder", "read": "launch",
                             "suites": ["daemon-ops", "terminal"], "expected_differences": [], "old_paths": None,
                             **overrides})


# (name, files {stem: entry}, extra Swift site or None, the substring every finding must hold; "" = pass)
SELFTEST_CASES: Sequence[Tuple[str, Dict[str, Dict[str, Any]], Optional[str], str]] = (
    ("seed app and daemon switches pass", {"layer-hosting": selftest_entry(), "holder": daemon_entry()}, None, ""),
    ("expiry 14 days passes", {"layer-hosting": selftest_entry(expires="2026-11-08")}, None, ""),
    ("expiry 15 days is refused", {"layer-hosting": selftest_entry(expires="2026-11-09")}, None,
     "is 15 days after created 2026-10-25; the limit is 14"),
    ("expiry before created is refused", {"layer-hosting": selftest_entry(expires="2026-10-24")}, None,
     "is before created"),
    ("an impossible day is refused", {"layer-hosting": selftest_entry(expires="2026-02-30")}, None,
     "is not a day"),
    ("missing planned is refused", {"layer-hosting": selftest_entry(planned=None)}, None,
     "missing required member 'planned'"),
    ("planned outside old/new is refused", {"layer-hosting": selftest_entry(planned="launch")}, None, "/planned"),
    ("missing owner is refused", {"layer-hosting": selftest_entry(owner=None)}, None, "missing required member 'owner'"),
    ("an unknown field is refused", {"layer-hosting": selftest_entry(flavor="x")}, None, "'flavor' is not allowed"),
    ("both keys are refused", {"layer-hosting": selftest_entry(daemon_key="holder")}, None, "oneOf"),
    ("no key is refused", {"layer-hosting": selftest_entry(app_key=None)}, None, "oneOf"),
    ("read outside launch/live is refused", {"layer-hosting": selftest_entry(read="startup")}, None, "/read"),
    ("unknown app key is refused", {"layer-hosting": selftest_entry(app_key="browser.ghost")}, None,
     "unknown app key 'browser.ghost'"),
    ("a doc-comment case is not an app key", {"layer-hosting": selftest_entry(app_key="ghost.key")}, None,
     "unknown app key 'ghost.key'"),
    ("a bare case is its own raw value", {"layer-hosting": selftest_entry(app_key="intents")}, None, ""),
    ("unparsed daemon switch is refused", {"holder": daemon_entry(daemon_key="holder-v3")}, None,
     "daemon key 'holder-v3' is not parsed"),
    ("a commented daemon name is not parsed", {"holder": daemon_entry(daemon_key="commented")}, None,
     "is not parsed"),
    ("live switch read through a per-call closure is refused", {"layer-hosting": selftest_entry()},
     SELFTEST_CLOSURE_SITE, "read through a per-call closure at Sources/Closure.swift:6"),
    ("name must be the file stem", {"layer-hosting": selftest_entry(name="layer-host")}, None, "is not the file stem"),
    ("a missing plan is refused", {"layer-hosting": selftest_entry(plan="plans/none.md")}, None,
     "plan plans/none.md does not exist"),
    ("a missing old path is refused", {"layer-hosting": selftest_entry(old_paths=["Sources/Gone.swift"])}, None,
     "old path Sources/Gone.swift does not exist"),
    ("an unclassified suite is refused", {"layer-hosting": selftest_entry(suites=["nowhere"])}, None,
     "suite 'nowhere' is not in baselines.py SUITE_CLASSES"),
    ("an empty suites list is refused", {"layer-hosting": selftest_entry(suites=[])}, None, "/suites"),
    ("an expected difference with no reason is refused",
     {"layer-hosting": selftest_entry(expected_differences=[{"pointer": "/layout"}])}, None,
     "missing required member 'reason'"),
)


def selftest_tree(tmp: Path, files: Dict[str, Dict[str, Any]], site: Optional[str]) -> Roots:
    repo = tmp / "repo"
    if repo.exists():
        shutil.rmtree(repo)
    roots = Roots(repo=repo, registry=repo / "registry", schema=SCHEMA, app_catalog=repo / "Sources" / "RefactorSwitches.swift",
                  daemon_catalog=repo / "switches.rs", swift_root=repo / "Sources")
    roots.registry.mkdir(parents=True)
    roots.swift_root.mkdir(parents=True)
    (repo / "plans").mkdir()
    (repo / "plans" / "plan.md").write_text("# plan\n", encoding="utf-8")
    roots.app_catalog.write_text(SELFTEST_SWIFT_CATALOG, encoding="utf-8")
    roots.daemon_catalog.write_text(SELFTEST_RUST_CATALOG, encoding="utf-8")
    (roots.swift_root / "Old.swift").write_text("// old arm\n", encoding="utf-8")
    (roots.swift_root / "Good.swift").write_text(SELFTEST_GOOD_SITE, encoding="utf-8")
    if site is not None:
        (roots.swift_root / "Closure.swift").write_text(site, encoding="utf-8")
    for stem, entry in files.items():
        (roots.registry / f"{stem}.json").write_text(json.dumps(entry, indent=2), encoding="utf-8")
    return roots


SELFTEST_CLOSURES: Sequence[Tuple[str, List[int]]] = (
    ("init(isEnabled: { switches.isNew(.layerHosting) })", [1]),
    ("isEnabled: { switches[RefactorSwitchKey.layerHosting] == .new }", [1]),
    ("return { switches.arm(.layerHosting) == .new }", [1]),
    ("Host(layerHosting: switches.isNew(.layerHosting))", []),
    ("var on: Bool { switches.isNew(.layerHosting) }", []),
    ("items.map { switches.isNew(.layerHosting) }", []),
    ("run(handler: { _ in switches.isNew(.layerHosting) })", [1]),
    ("f(a: { let v = switches.arm(.layerHosting); use(v) })", []),
    ("f(a: { \"switches.isNew(.layerHosting)\" })", []),
    ("host.layerHosting.stop()", []),
)


def selftest_closures() -> List[str]:
    """closure_reads on its own: what is a per-call read and what is not."""
    failures: List[str] = []
    for source, want in SELFTEST_CLOSURES:
        got = closure_reads(source, "layerHosting")
        if got != want:
            failures.append(f"closure_reads({source!r}) = {got}, want {want}")
    return failures


# (label, files {stem: entry}, today, the --expired lines, the unreadable stems)
SELFTEST_EXPIRED: Sequence[Tuple[str, Dict[str, Dict[str, Any]], dt.date, List[str], List[str]]] = (
    ("a past date is one deletion task",
     {"layer-hosting": selftest_entry(created="2026-09-01", expires="2026-09-10")}, dt.date(2026, 10, 26),
     ["layer-hosting expired=2026-09-10 owner=perf-lead key=app:browser.layer-hosting "
      "catalog=Sources/RefactorSwitches.swift default=old keep=new delete=Sources/Old.swift,registry/layer-hosting.json"],
     []),
    ("the day before expires lists nothing", {"layer-hosting": selftest_entry()}, dt.date(2026, 11, 7), [], []),
    ("the expires day itself is expired", {"layer-hosting": selftest_entry()}, dt.date(2026, 11, 8),
     ["layer-hosting expired=2026-11-08 owner=perf-lead key=app:browser.layer-hosting "
      "catalog=Sources/RefactorSwitches.swift default=old keep=new delete=Sources/Old.swift,registry/layer-hosting.json"],
     []),
    ("by day, then by name, whatever the file order",
     {"zeta": selftest_entry(name="zeta", expires="2026-10-30"),
      "holder": daemon_entry(expires="2026-11-01"),
      "alpha": selftest_entry(name="alpha", expires="2026-10-30", old_paths=None),
      "later": selftest_entry(name="later", expires="2026-11-08")},
     dt.date(2026, 11, 1),
     ["alpha expired=2026-10-30 owner=perf-lead key=app:browser.layer-hosting "
      "catalog=Sources/RefactorSwitches.swift default=old keep=new delete=registry/alpha.json",
      "zeta expired=2026-10-30 owner=perf-lead key=app:browser.layer-hosting "
      "catalog=Sources/RefactorSwitches.swift default=old keep=new delete=Sources/Old.swift,registry/zeta.json",
      "holder expired=2026-11-01 owner=perf-lead key=daemon:holder catalog=switches.rs default=old keep=new "
      "delete=registry/holder.json"],
     []),
    ("a refactor planned at old keeps its old paths",
     {"layer-hosting": selftest_entry(planned="old", default="new")}, dt.date(2026, 11, 8),
     ["layer-hosting expired=2026-11-08 owner=perf-lead key=app:browser.layer-hosting "
      "catalog=Sources/RefactorSwitches.swift default=new keep=old delete=registry/layer-hosting.json"],
     []),
    ("an owner with a space stays one field",
     {"layer-hosting": selftest_entry(owner="Lawrence Chen", old_paths=["Sources/Old.swift", "Sources"])},
     dt.date(2026, 11, 8),
     ["layer-hosting expired=2026-11-08 owner='Lawrence Chen' key=app:browser.layer-hosting "
      "catalog=Sources/RefactorSwitches.swift default=old keep=new "
      "delete=Sources/Old.swift,Sources,registry/layer-hosting.json"],
     []),
    ("an unreadable expiry is reported, the rest still listed",
     {"layer-hosting": selftest_entry(expires="2026-02-30"), "holder": daemon_entry(expires="2026-10-30")},
     dt.date(2026, 11, 8),
     ["holder expired=2026-10-30 owner=perf-lead key=daemon:holder catalog=switches.rs default=old keep=new "
      "delete=registry/holder.json"],
     ["layer-hosting"]),
)

# (CLI arguments after --registry, a broken file beside the two switches, exit code, stdout line count)
SELFTEST_EXPIRED_CLI: Sequence[Tuple[Tuple[str, ...], bool, int, int]] = (
    (("--today", "2026-10-29"), False, 0, 0),
    (("--today", "2026-11-08"), False, 1, 2),
    (("--today", "2026-10-29"), True, 2, 0),
    (("--today", "2026-11-08"), True, 2, 2),
)


def selftest_expired(tmp: Path) -> List[str]:
    """--expired on the table above, its line round trip through shlex, the CLI exit codes, and the
    missing registry directory."""
    failures: List[str] = []
    for label, files, today, want_lines, want_unread in SELFTEST_EXPIRED:
        tasks, unread = expired(selftest_tree(tmp, files, None), today)
        lines = [task.line() for task in tasks]
        stems = [Path(finding.path).stem for finding in unread]
        if lines != want_lines or stems != want_unread:
            failures.append(f"--expired {label}: got {lines}, unreadable {stems}")
        for task, line in zip(tasks, lines):
            fields = shlex.split(line)
            if fields[0] != task.name or f"owner={task.owner}" not in fields:
                failures.append(f"--expired {label}: {line!r} does not split back into its fields")
    for extra, broken, want_code, want_count in SELFTEST_EXPIRED_CLI:
        roots = selftest_tree(tmp, {"layer-hosting": selftest_entry(), "holder": daemon_entry(expires="2026-10-30")}, None)
        if broken:
            (roots.registry / "broken.json").write_text("{", encoding="utf-8")
        out, err = io.StringIO(), io.StringIO()
        with redirect_stdout(out), redirect_stderr(err):
            code = main(["--expired", "--registry", str(roots.registry), *extra])
        printed = out.getvalue().splitlines()
        if code != want_code or len(printed) != want_count or broken != ("broken.json" in err.getvalue()):
            failures.append(f"--expired {list(extra)} (broken file: {broken}): exit {code}, stdout {printed}, "
                            f"stderr {err.getvalue()!r}")
    try:
        expired(replace(roots, registry=roots.repo / "none"), dt.date(2026, 11, 8))
        failures.append("--expired on a missing registry directory did not refuse")
    except UsageError:
        pass
    return failures


def hit_report(old: int, new: int, key: str = "browser.layer-hosting", **sites: Tuple[int, int]) -> Dict[str, Any]:
    return {"switches": {key: {"old": old, "new": new, "sites": {
        site.replace("_", "."): {"old": arms[0], "new": arms[1]} for site, arms in sites.items()}}}}


# (label, report, requested arm, verdict; "" = refused as bad input)
SELFTEST_HITS: Sequence[Tuple[str, Any, str, str]] = (
    ("hits only on the requested arm", hit_report(0, 12, CEFLayerHosting_pageShown=(0, 12)), "new", EXERCISED),
    ("old arm requested and run", hit_report(4, 0, CEFLayerHosting_pageShown=(4, 0)), "old", EXERCISED),
    ("0 hits on the requested arm", hit_report(0, 0, CEFLayerHosting_pageShown=(0, 0)), "new", NOT_EXERCISED),
    ("hits only on the other arm", hit_report(3, 0, CEFLayerHosting_pageShown=(3, 0)), "new", NOT_EXERCISED),
    ("no entry for the switch is 0 hits", {"switches": {}}, "new", NOT_EXERCISED),
    ("another switch's hits do not count", hit_report(0, 5, key="browser.cef-helper"), "new", NOT_EXERCISED),
    ("a site ran both arms", hit_report(1, 9, CEFLayerHosting_pageShown=(0, 9), CEFLayerHosting_created=(1, 0)),
     "new", MIXED),
    ("no switches object is refused", {"hits": {}}, "new", ""),
    ("a negative count is refused", hit_report(-1, 2), "new", ""),
    ("a fractional count is refused", hit_report(0, 1.5), "new", ""),
    ("a bool count is refused", hit_report(0, True), "new", ""),
    ("an arm outside old/new is refused", hit_report(0, 1), "launch", ""),
)

# (label, registry key, arm, verdict; "" = refused) on the golden reply both sides test.
SELFTEST_HITS_GOLDEN: Sequence[Tuple[str, str, str, str]] = (
    ("golden: layer hosting ran new", "app:browser.layer-hosting", "new", EXERCISED),
    ("golden: layer hosting never ran old", "app:browser.layer-hosting", "old", NOT_EXERCISED),
    ("golden: cef helper ran old", "app:browser.cef-helper", "old", EXERCISED),
    ("golden: a switch with no entry", "app:browser.discard", "new", NOT_EXERCISED),
    ("golden: a daemon key is refused", "daemon:browser.layer-hosting", "new", ""),
)

# (CLI arguments after --hits FILE, the report, exit code, the verdict on stdout or None)
SELFTEST_HITS_CLI: Sequence[Tuple[Tuple[str, ...], Any, int, Optional[str]]] = (
    (("--switch", "layer-hosting", "--arm", "new"), hit_report(0, 2, CEFLayerHosting_pageShown=(0, 2)), 0, EXERCISED),
    (("--switch", "layer-hosting", "--arm", "old"), hit_report(0, 2, CEFLayerHosting_pageShown=(0, 2)), 1, NOT_EXERCISED),
    (("--switch", "holder", "--arm", "new"), hit_report(0, 1, key="holder"), 2, None),  # a daemon switch is refused
    (("--switch", "ghost", "--arm", "new"), hit_report(0, 1), 2, None),
    (("--switch", "layer-hosting"), hit_report(0, 1), 2, None),
    (("--switch", "layer-hosting", "--arm", "new"), "{", 2, None),
)


def selftest_hits(tmp: Path) -> List[str]:
    """hit_verdict on the table above, its line round trip through shlex, and the --hits CLI."""
    failures: List[str] = []
    for label, report, arm, want in SELFTEST_HITS:
        try:
            got = hit_verdict(report, "layer-hosting", "app:browser.layer-hosting", arm).verdict
        except UsageError:
            got = ""
        if got != want:
            failures.append(f"--hits {label}: got {got or 'refused'!r}, want {want or 'refused'!r}")
    golden = json.loads(GOLDEN_HITS.read_text(encoding="utf-8"))
    for label, key, arm, want in SELFTEST_HITS_GOLDEN:
        try:
            got = hit_verdict(golden, "golden", key, arm).verdict
        except UsageError:
            got = ""
        if got != want:
            failures.append(f"--hits {label}: got {got or 'refused'!r}, want {want or 'refused'!r}")
    golden_sites = hit_verdict(golden, "golden", "app:browser.layer-hosting", "new").sites
    if golden_sites != (("CEFLayerHosting.pageShown", 0, 2), ("CEFLayerHosting.pageWindowCreated", 0, 1)):
        failures.append(f"--hits golden: layer hosting sites read as {golden_sites}")
    verdict = hit_verdict(hit_report(0, 3, CEFLayerHosting_pageShown=(0, 3)), "layer hosting", "app:browser.layer-hosting", "new")
    fields = shlex.split(verdict.line())
    if fields[0] != "layer hosting" or "sites=CEFLayerHosting.pageShown:old=0/new=3" not in fields:
        failures.append(f"--hits line {verdict.line()!r} does not split back into its fields")
    for extra, report, want_code, want_verdict in SELFTEST_HITS_CLI:
        roots = selftest_tree(tmp, {"layer-hosting": selftest_entry(), "holder": daemon_entry()}, None)
        report_path = tmp / "hits.json"
        report_path.write_text(report if isinstance(report, str) else json.dumps(report), encoding="utf-8")
        out, err = io.StringIO(), io.StringIO()
        with redirect_stdout(out), redirect_stderr(err):
            try:
                code = main(["--hits", str(report_path), "--registry", str(roots.registry), *extra])
            except SystemExit as error:  # argparse refuses a missing --arm
                code = int(error.code or 0)
        printed = out.getvalue().splitlines()
        seen = next((field.partition("=")[2] for field in shlex.split(printed[0]) if field.startswith("verdict=")),
                    None) if printed else None
        if code != want_code or seen != want_verdict:
            failures.append(f"--hits {list(extra)}: exit {code}, stdout {printed}, stderr {err.getvalue()!r}")
    return failures


def planted(*culprits: str, flaky: Tuple[str, ...] = ()) -> Probe:
    """A probe whose case diverges exactly when every switch of `culprits` is in the set (a planted
    interaction); a set equal to `flaky` answers flaky."""
    def probe(names: Tuple[str, ...]) -> str:
        if names == tuple(sorted(flaky)):
            return "flaky"
        return PROBE_DIVERGENT if culprits and set(culprits) <= set(names) else PROBE_SAME
    return probe


BISECT_NAMES = ("cef-helper", "discard", "holder", "intents", "layer-hosting", "motion", "overlay")


@dataclass(frozen=True)
class BisectRow:
    label: str
    culprits: Tuple[str, ...]
    want: Tuple[str, Tuple[str, ...], Optional[str]]  # verdict, switches, minimality
    names: Tuple[str, ...] = BISECT_NAMES
    flaky: Tuple[str, ...] = ()
    budget: int = DEFAULT_MAX_PROOF_PROBES


SELFTEST_BISECT = [
    BisectRow("planted pair", ("holder", "overlay"), ("found", ("holder", "overlay"), "smallest")),
    BisectRow("one switch", ("intents",), ("found", ("intents",), "smallest")),
    BisectRow("every switch", BISECT_NAMES, ("found", BISECT_NAMES, "1-minimal")),
    BisectRow("triple, no proof budget", ("discard", "holder", "motion"),
              ("found", ("discard", "holder", "motion"), "1-minimal"), budget=0),
    BisectRow("no divergence", (), ("not-reproducible", (), None)),
    BisectRow("no suspects", ("holder",), ("not-reproducible", (), None), names=()),
    BisectRow("a flaky probe", ("holder", "overlay"), ("unreliable", (), None), flaky=BISECT_NAMES),
]
BISECT_SEEDS = range(1, 41)


def selftest_bisect() -> List[str]:
    """Each row over BISECT_SEEDS: the verdict and set, and the same probes for a seed twice."""
    failures = []
    for row in SELFTEST_BISECT:
        for seed in BISECT_SEEDS:
            first, again = (bisect_switch_set(row.names, planted(*row.culprits, flaky=row.flaky), seed=seed,
                                              max_proof_probes=row.budget) for _ in range(2))
            got = (first.verdict, first.switches, first.minimality)
            if got != row.want or first != again:
                failures.append(f"bisect {row.label} seed {seed}: got {got}, want {row.want}, "
                                f"deterministic {first == again}")
                break
    return failures


def selftest() -> int:
    failures = selftest_closures()
    failures.extend(selftest_bisect())
    with tempfile.TemporaryDirectory(prefix="oracle-switches-") as name:
        tmp = Path(name)
        for label, files, site, want in SELFTEST_CASES:
            findings, _ = check(selftest_tree(tmp, files, site))
            messages = [str(f) for f in findings]
            if want == "":
                ok = not messages
            else:
                ok = bool(messages) and all(want in m for m in messages)
            if not ok:
                failures.append(f"{label}: want {'pass' if not want else repr(want)}, got {messages}")
        failures.extend(selftest_expired(tmp))
        failures.extend(selftest_hits(tmp))
        missing = selftest_tree(tmp, {"layer-hosting": selftest_entry(), "holder": daemon_entry()}, None)
        missing.app_catalog.unlink()
        missing.daemon_catalog.unlink()
        messages = [str(f) for f in check(missing)[0]]
        if not (len(messages) == 2 and APP_CATALOG_TASK in messages[1] and DAEMON_CATALOG_TASK in messages[0]):
            failures.append(f"missing catalogs: got {messages}")
    # The closure, refusal, --expired, --expired CLI, --hits, --hits golden, --hits CLI and bisect tables,
    # the missing registry, the missing catalogs, the golden sites and the --hits line round trip.
    total = (len(SELFTEST_CLOSURES) + len(SELFTEST_CASES) + len(SELFTEST_EXPIRED) + len(SELFTEST_EXPIRED_CLI)
             + len(SELFTEST_HITS) + len(SELFTEST_HITS_GOLDEN) + len(SELFTEST_HITS_CLI) + len(SELFTEST_BISECT) + 4)
    for failure in failures:
        print(f"FAIL {failure}")
    print(f"selftest: {total - len(failures)}/{total} pass")
    return 1 if failures else 0


# ---------------------------------------------------------------------------------------------------------
# CLI


def main(argv: Optional[Sequence[str]] = None) -> int:
    parser = argparse.ArgumentParser(prog="switches.py", description=__doc__.split("\n\n")[0])
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument("--check", action="store_true", help="refuse a malformed switch file")
    mode.add_argument("--expired", action="store_true", help="one deletion line per expired switch")
    mode.add_argument("--selftest", action="store_true", help="run the refusal table on temporary registries")
    mode.add_argument("--hits", type=Path, metavar="FILE",
                      help="the verdict of one debug.oracle.switch_hits result on --switch at --arm")
    parser.add_argument("--registry", type=Path, default=REGISTRY, help="registry directory (default: this checkout's)")
    parser.add_argument("--today", type=dt.date.fromisoformat, help="the day for --expired (default: today, UTC)")
    parser.add_argument("--switch", metavar="NAME", help="--hits: the registry switch the run requested")
    parser.add_argument("--arm", choices=ARMS, help="--hits: the arm the run requested")
    args = parser.parse_args(argv)
    if args.hits is not None and (args.switch is None or args.arm is None):
        parser.error("--hits needs --switch NAME and --arm old|new")
    try:
        if args.selftest:
            return selftest()
        if args.hits is not None:
            verdict = hits(Roots(registry=args.registry.resolve()), args.hits, args.switch, args.arm)
            print(verdict.line())
            return 0 if verdict.ok else 1
        if args.expired:
            today = args.today or dt.datetime.now(dt.timezone.utc).date()
            tasks, unread = expired(Roots(registry=args.registry.resolve()), today)
            for task in tasks:
                print(task.line())
            for finding in unread:
                print(f"switches --expired: {finding}", file=sys.stderr)
            return 2 if unread else 1 if tasks else 0
        findings, count = check(Roots(registry=args.registry.resolve()))
    except UsageError as error:
        print(f"switches: {error}", file=sys.stderr)
        return 2
    for finding in findings:
        print(finding)
    print(f"switches --check: {count} switch files, {len(findings)} findings")
    return 1 if findings else 0


if __name__ == "__main__":
    sys.exit(main())
