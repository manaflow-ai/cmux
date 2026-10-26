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
    switches.py --expired [--today YYYY-MM-DD] one line per switch whose `expires` day has come
                                               (exit 0: none, 1: some)
    switches.py --selftest                    the refusal table below, on temporary registries
`oracle.py switches ARGS` runs this script with ARGS.

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
import json
import re
import shutil
import sys
import tempfile
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Dict, List, Optional, Sequence, Set, Tuple

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[2]
TASK = "p15-oracle-018"
REGISTRY = REPO / "plans" / "cmux-next" / "refactor-switches"
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
# --expired


def expired(registry: Path, today: dt.date, repo: Path = REPO) -> List[str]:
    """One deletion line per switch whose `expires` day is today or earlier, by day then name."""
    rows: List[Tuple[dt.date, str, str]] = []
    for path in sorted(registry.glob("*.json")):
        data, _ = load_entry(path)
        if data is None:
            continue
        day = parse_day(data.get("expires"))
        if day is None or day > today:
            continue
        key = f"app:{data['app_key']}" if "app_key" in data else f"daemon:{data.get('daemon_key')}"
        old = ",".join(data.get("old_paths") or []) or "-"
        line = (f"{path.stem} expired {day} owner={data.get('owner', '-')} key={key} "
                f"planned={data.get('planned', '-')} old_paths={old} file={relative(path, repo)}")
        rows.append((day, path.stem, line))
    return [line for _, _, line in sorted(rows)]


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


def selftest() -> int:
    failures = selftest_closures()
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
        roots = selftest_tree(tmp, {"layer-hosting": selftest_entry(), "holder": daemon_entry(expires="2026-10-30")}, None)
        lines = expired(roots.registry, dt.date(2026, 11, 8), roots.repo)
        want_lines = [
            "holder expired 2026-10-30 owner=perf-lead key=daemon:holder planned=new old_paths=- file=registry/holder.json",
            "layer-hosting expired 2026-11-08 owner=perf-lead key=app:browser.layer-hosting planned=new "
            "old_paths=Sources/Old.swift file=registry/layer-hosting.json",
        ]
        if lines != want_lines:
            failures.append(f"--expired on 2026-11-08: got {lines}")
        if expired(roots.registry, dt.date(2026, 10, 29), roots.repo):
            failures.append("--expired on 2026-10-29 lists a switch that has not expired")
        missing = selftest_tree(tmp, {"layer-hosting": selftest_entry(), "holder": daemon_entry()}, None)
        missing.app_catalog.unlink()
        missing.daemon_catalog.unlink()
        messages = [str(f) for f in check(missing)[0]]
        if not (len(messages) == 2 and APP_CATALOG_TASK in messages[1] and DAEMON_CATALOG_TASK in messages[0]):
            failures.append(f"missing catalogs: got {messages}")
    # The closure table, the refusal table, two --expired days and the missing catalogs.
    total = len(SELFTEST_CLOSURES) + len(SELFTEST_CASES) + 3
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
    parser.add_argument("--registry", type=Path, default=REGISTRY, help="registry directory (default: this checkout's)")
    parser.add_argument("--today", type=dt.date.fromisoformat, help="the day for --expired (default: today, UTC)")
    args = parser.parse_args(argv)
    try:
        if args.selftest:
            return selftest()
        if args.expired:
            today = args.today or dt.datetime.now(dt.timezone.utc).date()
            lines = expired(args.registry, today)
            for line in lines:
                print(line)
            return 1 if lines else 0
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
