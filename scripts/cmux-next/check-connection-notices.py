#!/usr/bin/env python3
"""A connection state the person can do nothing about stays quiet: no new UI shows one with no action and no bound.

Leo, 2026-11-14: "i also want all our connectivity stuff to shut the fuck up and load faster/percievably load
faster / whatever it takes / desktop gui, ios, remote, cloud, etc". The rule (cmuxterm-hq docs/handbook/
connection-state-with-no-action-or-bound.md): a reconnecting, retrying, handshaking, restoring, "Getting access",
offline or disconnected state says nothing until it has lasted the shared bound, unless the person can act on it.

What it reads, in the cmux NEXT UI (SURFACES): the web pages (webviews/src), the Mac app (Packages/macOS/CmuxNext)
and the iOS app (cmux-next-ios, Packages/iOS). Tests, galleries, fixtures and previews are not read.

A connection state is a string the person can read that says one (CONNECTION_WORDS: connecting, reconnecting,
reattaching (the iOS terminal pill's "Reattaching…"),
retrying, restoring, handshaking, "Getting access", offline, disconnected, not connected, unreachable, can't reach,
link down, waiting for the service): an inline literal that is copy (it starts with a capital: "Reconnecting…",
"Not connected to cmux."), a JSX text node, or a dotted string-table key whose English value says one
("page.disconnected", "terminal.link.connectionLost"). Not read: a lowercase state tag (`phase === "disconnected"`),
an identifier, log, error and assertion lines, an Error/Failure type, and the answer to something the person just
did (a key with a `refusal`, `error`, `failure` or `failed` segment: the person acted; raw-error-text-in-the-ui.md
owns those words).

Each hit belongs to a unit: the top-level declaration it sits in (a TS function or const, a Swift type with its
extensions in the same file). A unit that only holds words for another to draw (a TS helper, label map or strings
map, a Swift `…Strings`/`…Text`/`…Copy` type) passes its hits on to the units that use them (`L.disconnected`,
`RemoteStrings.placeholderReconnecting`, `stateText(…)`), so the check lands where the words are drawn. A unit passes
when it
  bound   names a time gate: the shared bound (CONNECTION_QUIET_MS / useConnectionQuiet on the web,
          NoticeTiming.connectionQuiet on the Mac, QuietStatusGate on iOS; schemas/notice-timing/notice-timing.json,
          each copy checked against it) or an existing hold built on one (TIME_GATES). A gate helper given a literal
          grace under the bound (`useLasting(down, 500)`) does not count: name the shared bound instead;
  action  carries a person action: a button, a click or tap handler, an action closure (PERSON_ACTIONS);
  listed  is in the allowlist (scripts/cmux-next/connection-notices-allowlist.tsv: unit, surface, owner, reason).
The allowlist only shrinks: with --base REV a row the list at REV lacks fails (a unit that moved to another file
under the same name keeps its row), and a row whose unit no longer shows an unbounded connection state (fixed,
renamed or deleted, by any file) fails as stale until a change removes it. Every unlisted offender is judged on
every run, with or without --base. The unit is the granularity: a component with
any button passes, so the check catches a new state drawn with nothing to do, not a button that does the wrong thing.

    python3 scripts/cmux-next/check-connection-notices.py                     # the working tree
    python3 scripts/cmux-next/check-connection-notices.py --base HEAD^1       # and the shrink-only ratchet
    python3 scripts/cmux-next/check-connection-notices.py --list              # every hit, gated or not
    python3 scripts/cmux-next/check-connection-notices.py --write-allowlist   # drop the rows that are fixed
    python3 scripts/cmux-next/check-connection-notices.py --input-block       # report input blocked while connecting
"""
from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
from dataclasses import dataclass, field
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
ALLOWLIST = "scripts/cmux-next/connection-notices-allowlist.tsv"
ALLOWLIST_HEADER = (
    "# check-connection-notices.py allowlist: unit<TAB>surface<TAB>owner<TAB>reason. It only shrinks: a PR that fixes\n"
    "# a unit (a bound, or one action) removes its row in the same change; a stale row fails the check.\n"
)

# Where cmux NEXT UI lives, by surface. The first matching prefix names the surface.
SURFACES: tuple[tuple[str, str], ...] = (
    ("webviews/src/", "web"),
    ("Packages/macOS/CmuxNext/Sources/", "mac"),
    ("cmux-next-ios/", "ios"),
    ("Packages/iOS/", "ios"),
)
SOURCE_SUFFIXES = (".ts", ".tsx", ".swift")
STRING_TABLE_SUFFIX = ".xcstrings"
# Not UI a person sees: tests, galleries, previews, fixtures, mocks, experiments, generated tables.
SKIP = re.compile(
    r"(^|/)(test|tests|\w*Tests|__tests__|fixtures|Fixtures|Preview Content|gallery|Gallery|prototypes?|backend|"
    r"scripts)/"
    r"|\.(test|spec|gallery|stories|fixtures?|experiment|bench|generated)\.(ts|tsx|swift)$"
    r"|(Tests?|Previews?|Gallery\w*|Fixtures?|Tunables|Stress\w*|Debug\w*)\.swift$"
    r"|(^|/)(Mock|mock|Debug)\w*\.(ts|tsx|swift)$|[Ff]ixtures?\.(ts|tsx|swift)$|Fixture\w*\.(ts|tsx|swift)$"
    r"|\+Parity\.swift$|GalleryRoot\w*\.swift$"
)

# What says a connection state. Matched against the English text, case-insensitive.
CONNECTION_WORDS = re.compile(
    r"(?i)\b("
    r"re-?connecting|connecting|re-?attaching|retrying|restoring|handshak\w*|getting access"
    r"|offline|disconnected|not connected|no connection|connection (?:lost|closed|dropped|interrupted)"
    r"|lost (?:the )?connection|can'?t reach|cannot reach|couldn'?t reach|unreachable"
    r"|link (?:is )?down|waiting for (?:the )?(?:agent service|daemon|service|connection|network|host|machine|mac|server)"
    r")"
)
# A string literal that is UI copy, not a state tag, an identifier or a log reason: it starts with a capital (or an
# opening quote or a format) and is either one word ("Offline", "Reconnecting…") or has a space.
TEXT_SHAPE = re.compile(r"^[“\"'(%\\]*[A-Z](?:[a-z’'\-]*[a-z](?:…|\.\.\.|\.)?$|.*\s)")
# A regular expression, not copy: alternation, a group or a word boundary.
REGEX_SHAPE = re.compile(r"\(\?|\\b|\|")
# A key for the answer to something the person just did (a refused verb, a failed load they asked for): the
# person acted, so it is not a state they wait through. raw-error-text-in-the-ui.md and error-with-no-next-step.md
# own its words.
OUTCOME_KEY = re.compile(r"(?i)(^|[.\-_])(refusals?|errors?|failures?|failed)([.\-_]|$)")
# A string-table key: dotted, no spaces.
KEY_SHAPE = re.compile(r"^[A-Za-z0-9_]+(?:[.\-][A-Za-z0-9_]+)+$")

# An error or failure type's text is the outcome of something the person did (raw-error-text-in-the-ui.md owns it).
ERROR_TYPE = re.compile(r"(Error|Failure|Errors|Failures)$")

# A time gate: the shared bound, and helpers that hold a state before it shows. Each one names, in its own file, a
# hold of at least the policy bound or the shared constant itself.
TIME_GATES = re.compile(
    r"\b("
    r"CONNECTION_QUIET_MS|useConnectionQuiet|connectionQuiet|NoticeTiming|QuietStatusGate"  # the shared bound
    r"|useLasting|LASTING_MS|useAfterDelay|RESUME_NOTE_DELAY_MS|HOST_ERROR_DEADLINE_MS|hostErrorShows"  # web holds
    r"|revealDelay|NoticePolicy|noticePolicy|RemoteLatencyHold|QuietHold|connectionChip|connectionLasting|AutoRetry"  # native holds
    r")\b"
)
# A gate helper called with a literal grace: `useLasting(x, 500)`, `useAfterDelay(x, 1_000)`.
LITERAL_GRACE = re.compile(r"\b(useLasting|useAfterDelay)\s*\([^()]*,\s*([0-9][0-9_]*)\s*\)")
# The Swift hold with a literal delay: `QuietHold(owner: "x", delay: .seconds(2))`.
SWIFT_LITERAL_GRACE = re.compile(
    r"\bQuietHold\s*\([^()]*\bdelay:\s*\.(seconds|milliseconds)\(\s*([0-9][0-9_]*)\s*\)")
# The policy bound, ms (schemas/notice-timing/notice-timing.json `connectionQuietMs`), and its copies in each
# language: each must say the same bound.
NOTICE_TIMING = "schemas/notice-timing/notice-timing.json"
BOUND_COPIES: tuple[tuple[str, str, int], ...] = (
    ("webviews/src/ui/lasting.ts", r"export const CONNECTION_QUIET_MS = ([0-9_]+);", 1),
    ("Packages/macOS/CmuxNext/Sources/CmuxNextDesignTokens/NoticeTiming.swift",
     r"connectionQuiet: Duration = \.milliseconds\(([0-9_]+)\)", 1),
    ("cmux-next-ios/CmuxMobileKit/Sources/CmuxMobileDesign/QuietStatusGate.swift",
     r"threshold: Duration = \.seconds\(([0-9_]+)\)", 1000),
)

# A person action on the same unit.
PERSON_ACTIONS = re.compile(
    r"(\bonClick\s*=|\bonPress\s*=|<Button\b|<button\b|\bonAction\b|\bprimaryAction\b"  # web
    # A web component the unit draws whose name says it is a button (`<ConnectButton onConnect={...} />`).
    r"|<[A-Z]\w*Button\b"
    r"|\bButton\s*[({]|\bNSButton\b|\.onTapGesture\b|\baddAction\b|#selector\(|\bUIAction\b|\.swipeActions\b"  # Swift
    r"|\baction:\s*\{|\bactions:\s*\[|\baction:\s*\."
    # A Swift model that names the person's action for its state (`var action: Action?`), drawn by a view.
    r"|\bvar\s+action\s*:\s*\w*Action\?"
    # A sidebar section's click handler for its own rows (`func activate(_ id: LayoutItemID) -> Bool`).
    r"|\bfunc\s+activate\s*\(\s*_\s+\w+\s*:\s*LayoutItemID\b"
    # A web list row's click handler (`run: () => goTo("github")`, `run: github.onRetry`): the person picks the row.
    # Not a callback that takes an argument (`run: (agent) => resumes.run(agent)`), which is some other action,
    # and not a type (`timeout(run: () => void, ms)`, a timer or frame scheduler's signature).
    r"|\brun:\s*(?:\(\s*\)\s*=>(?!\s*(?:void|Promise\b|unknown\b))|\w+(?:\.\w+)*\.on[A-Z]\w*\b))"
)
# Lines that are not UI text: logs, errors, assertions.
NOT_UI_LINE = re.compile(
    r"\b(log(?:ger)?\.\w+|Logger|os_log|NSLog|print|debugPrint|console\.\w+|fatalError|precondition\w*|assert\w*"
    r"|throw|reject\(|signpost|trace\w*\(|breadcrumb|span\()|\w*(?:Error|Exception)\s*\("
)

STRING_LITERAL = re.compile(r'"((?:[^"\\\n]|\\.)*)"|\'((?:[^\'\\\n]|\\.)*)\'|`((?:[^`\\]|\\.)*)`')
JSX_TEXT = re.compile(r">\s*([^<>{}\n]*[A-Za-z][^<>{}\n]*)\s*<")
LINE_COMMENT = re.compile(r"(^|[^:\"'\\])//.*$")
BLOCK_COMMENT = re.compile(r"/\*.*?\*/", re.S)

TS_TOP = re.compile(
    r"^(?:export\s+)?(?:default\s+)?(?:async\s+)?(?:function\*?\s+(\w+)|(?:const|let|var)\s+(\w+)|class\s+(\w+))"
)
SWIFT_TOP = re.compile(
    r"^(?:@\w+(?:\([^)]*\))?\s+)*(?:(?:public|private|fileprivate|internal|package|open|final|nonisolated|"
    r"indirect)\s+)*(?:struct|class|enum|actor|extension|protocol|func)\s+([\w.]+)"
)
# A map property a hit sits on: `disconnected: "page.disconnected",`.
MAP_PROP = re.compile(r"^\s*[\"']?(\w+)[\"']?\s*:")
# The Swift member a hit sits in.
SWIFT_MEMBER = re.compile(r"\b(?:func|var|let|case)\s+(\w+)")
# A Swift type that only holds words for another type to draw.
SWIFT_PROVIDER = re.compile(r"(^Strings|Strings|Text|Copy|Words|Labels?|L10n|Phrases)$")
TS_IMPORT = re.compile(r"import\s*(?:type\s+)?\{([^}]*)\}\s*from\s*[\"']([^\"']+)[\"']")


@dataclass
class Hit:
    line: int
    text: str
    index: int = 0  # the hit's line within its unit's lines
    hops: int = 0  # how many providers it came through
    origin: str = ""  # the file the words are in (the provider's, for a hit passed on)


@dataclass
class Unit:
    path: str
    name: str
    surface: str
    lines: list[str] = field(default_factory=list)
    numbers: list[int] = field(default_factory=list)  # each line's number in the file
    hits: list[Hit] = field(default_factory=list)
    gated: bool = False
    acted: bool = False
    literal_grace: list[str] = field(default_factory=list)

    @property
    def id(self) -> str:
        return f"{self.path}::{self.name}"

    @property
    def ok(self) -> bool:
        return not self.hits or self.acted or (self.gated and not self.literal_grace)


class Tree:
    """The files of the working tree under ROOT."""

    def __init__(self, root: Path):
        self.root = root
        self.unit_ids: set[str] = set()  # filled by scan()
        # Tracked files that are not on disk (a sparse or partial checkout, a review sandbox that leaves out large
        # string tables, a deletion not yet staged): their units, and the strings other units read from them, are
        # unseen, so no verdict on this tree holds (a review read 19 listed rows as stale this way at dec7b89e9efc).
        self.missing: list[str] = []

    def files(self) -> list[str]:
        prefixes = [p for p, _ in SURFACES]
        try:
            out = subprocess.run(
                ["git", "-C", str(self.root), "ls-files", "-z", "--", *prefixes],
                check=True, capture_output=True,
            ).stdout.decode()
            names = [n for n in out.split("\0") if n]
        except (OSError, subprocess.CalledProcessError):
            names = [str(p.relative_to(self.root)) for pre in prefixes for p in (self.root / pre).rglob("*")
                     if p.is_file()]
        self.missing = sorted(n for n in names if not (self.root / n).exists())
        return sorted(n for n in names if (self.root / n).is_file())

    def read(self, path: str) -> str:
        return (self.root / path).read_text(encoding="utf-8", errors="replace")


def surface_of(path: str) -> str | None:
    for prefix, name in SURFACES:
        if path.startswith(prefix):
            return name
    return None


def policy_bound_ms(tree: Tree) -> int:
    try:
        return int(json.loads(tree.read(NOTICE_TIMING))["connectionQuietMs"])
    except (OSError, KeyError, ValueError):
        return 10_000


def bound_drift(tree: Tree) -> list[str]:
    """Each copy of the bound that does not say the schema's value (none when the tree has no schema)."""
    if not (tree.root / NOTICE_TIMING).is_file():
        return []
    bound = policy_bound_ms(tree)
    problems = []
    for path, pattern, scale in BOUND_COPIES:
        try:
            m = re.search(pattern, tree.read(path))
        except OSError:
            m = None
        if m is None:
            problems.append(f"{path}: no copy of the connection bound ({pattern}); {NOTICE_TIMING} says {bound} ms")
        elif int(m.group(1).replace("_", "")) * scale != bound:
            problems.append(f"{path}: the connection bound is {int(m.group(1).replace('_', '')) * scale} ms; "
                            f"{NOTICE_TIMING} says {bound} ms")
    return problems


def connection_keys(tree: Tree, files: list[str]) -> set[str]:
    """Every string-table key whose English value says a connection state."""
    keys: set[str] = set()
    for path in files:
        if not path.endswith(STRING_TABLE_SUFFIX):
            continue
        try:
            table = json.loads(tree.read(path))
        except (OSError, ValueError):
            continue
        strings = table.get("strings") if isinstance(table, dict) else None
        for key, entry in (strings if isinstance(strings, dict) else {}).items():
            english = key
            try:
                english = entry["localizations"]["en"]["stringUnit"]["value"]
            except (KeyError, TypeError):
                pass
            if not isinstance(english, str):
                english = key
            if KEY_SHAPE.match(key) and not OUTCOME_KEY.search(key) and CONNECTION_WORDS.search(english or ""):
                keys.add(key)
    return keys


def strip_comments(source: str) -> str:
    source = BLOCK_COMMENT.sub(lambda m: "\n" * m.group(0).count("\n"), source)
    return "\n".join(LINE_COMMENT.sub(lambda m: m.group(1), line) for line in source.split("\n"))


def says_connection(text: str, keys: set[str]) -> bool:
    if KEY_SHAPE.match(text):
        return text in keys  # a dotted string-table key
    if REGEX_SHAPE.search(text):
        return False  # a pattern that reads errors, not words anyone sees
    return bool(CONNECTION_WORDS.search(text)) and bool(TEXT_SHAPE.match(text))


def resolve_spec(importer: str, spec: str) -> str:
    """A relative import's target, repository-relative, without its suffix (`webviews/src/pages/editor/strings`)."""
    parts: list[str] = []
    for part in (Path(importer).parent / spec).as_posix().split("/"):
        if part == "..":
            if parts:
                parts.pop()
        elif part not in ("", "."):
            parts.append(part)
    return re.sub(r"\.(tsx?|js)$", "", "/".join(parts))


def units_of(path: str, source: str) -> list[tuple[str, int, int]]:
    """(name, first line, last line) of each top-level declaration; Swift extensions merge into their type."""
    lines = source.split("\n")
    top = SWIFT_TOP if path.endswith(".swift") else TS_TOP
    starts: list[tuple[int, str]] = []
    for i, line in enumerate(lines):
        m = top.match(line)
        if m:
            name = next(g for g in m.groups() if g)
            starts.append((i, name.split(".")[0] if path.endswith(".swift") else name))
    spans = []
    for n, (i, name) in enumerate(starts):
        end = starts[n + 1][0] - 1 if n + 1 < len(starts) else len(lines) - 1
        spans.append((name, i, end))
    if not starts or starts[0][0] > 0:
        spans.insert(0, ("<file>", 0, (starts[0][0] - 1) if starts else len(lines) - 1))
    return spans


def is_provider(unit: Unit) -> bool:
    """A unit that only says the words, for another unit to draw: a TS helper, map or label table (anything but a
    PascalCase component in a .tsx file), or a Swift strings type (`RemoteViewStrings`, `HomeText`)."""
    if unit.name == "<file>":
        return False
    if unit.path.endswith(".swift"):
        return bool(SWIFT_PROVIDER.search(unit.name))
    return not (unit.path.endswith(".tsx") and re.match(r"[A-Z][a-z]", unit.name))


def member_at(unit: Unit, index: int) -> str | None:
    """The member a hit sits in: a map property (`disconnected: "…"`) or a Swift `func/var/let/case` name."""
    if not unit.path.endswith(".swift"):
        m = MAP_PROP.match(unit.lines[index])
        return m.group(1) if m else None
    # A `let` or `var` statement may be a local inside the member (`let state = isLive ? "…on" : "…off"` in
    # `liveTooltip`): it is the member only if no declaration indented less encloses it. Read as the member `state`,
    # which no view names, the words stayed on the strings type and failed there (cmux#53574's Live tooltip).
    local: tuple[str, int] | None = None
    for back in range(index, -1, -1):
        line = unit.lines[back]
        m = SWIFT_MEMBER.search(line)
        if not m or m.group(1) == unit.name:
            continue
        indent = len(line) - len(line.lstrip())
        if line.lstrip().startswith(("let ", "var ")):
            if local is None or indent < local[1]:
                local = (m.group(1), indent)
            continue
        return local[0] if local is not None and indent >= local[1] else m.group(1)
    return local[0] if local is not None else None


def module_of(path: str) -> str:
    m = re.match(r"(.*?/Sources/[^/]+/)", path)
    return m.group(1) if m else str(Path(path).parent) + "/"


def scan(tree: Tree) -> list[Unit]:
    files = tree.files()
    keys = connection_keys(tree, files)
    bound = policy_bound_ms(tree)
    units: dict[str, Unit] = {}
    imports: dict[str, list[tuple[str, str]]] = {}  # file -> (local name, resolved module path without suffix)
    for path in files:
        surface = surface_of(path)
        if surface is None or not path.endswith(SOURCE_SUFFIXES) or SKIP.search(path):
            continue
        source = strip_comments(tree.read(path))
        lines = source.split("\n")
        if path.endswith((".ts", ".tsx")):
            imports[path] = [
                (binding.strip().split(" as ")[-1].strip(), resolve_spec(path, m.group(2)))
                for m in TS_IMPORT.finditer(source) if m.group(2).startswith(".")
                for binding in m.group(1).split(",") if binding.strip() and binding.strip() != "type"
            ]
        for name, first, last in units_of(path, source):
            uid = f"{path}::{name}"
            unit = units.setdefault(uid, Unit(path, name, surface))
            body = lines[first:last + 1]
            base = len(unit.lines)
            unit.lines.extend(body)
            unit.numbers.extend(range(first + 1, last + 2))
            for offset, line in enumerate(body):
                if NOT_UI_LINE.search(line):
                    continue
                said = [g for m in STRING_LITERAL.finditer(line) for g in m.groups() if g is not None]
                if path.endswith(".tsx"):
                    said += [m.group(1).strip() for m in JSX_TEXT.finditer(line)]
                if any(KEY_SHAPE.match(s) and OUTCOME_KEY.search(s) for s in said):
                    continue  # an outcome key and its default English (`defaultValue:`)
                hit = next((s for s in said if says_connection(s, keys)), None)
                if hit is not None:
                    unit.hits.append(Hit(first + offset + 1, hit, base + offset, 0, path))
    for unit in units.values():
        text = "\n".join(unit.lines)
        unit.gated = bool(TIME_GATES.search(text))
        unit.acted = bool(PERSON_ACTIONS.search(text))
        unit.literal_grace = [m.group(0) for m in LITERAL_GRACE.finditer(text)
                              if int(m.group(2).replace("_", "")) < bound]
        unit.literal_grace += [m.group(0) + ")" for m in SWIFT_LITERAL_GRACE.finditer(text)
                               if int(m.group(2).replace("_", "")) * (1000 if m.group(1) == "seconds" else 1) < bound]
    drawn_actions(units, imports)
    propagate(units, imports)
    tree.unit_ids = set(units)  # every declaration read, connection words or not
    for unit in units.values():
        unit.lines = []
        unit.numbers = []
    return [u for u in units.values() if u.hits and not ERROR_TYPE.search(u.name)]


# A component named for the action it draws (`ConnectButton`, `RetryAction`, `CardActions`); a component that only
# holds some other click (a disclosure, a row) does not lend it to the words beside it.
DRAWN_ACTION = re.compile(r"[A-Z]\w*(?:Button|Action|Actions)$")


def drawn_actions(units: dict[str, Unit], imports: dict[str, list[tuple[str, str]]]) -> None:
    """A web view that draws a button component (`<ConnectButton onConnect={...} />`, its `<button onClick>` inside)
    carries that action too: the button sits on the same card as the words. The component is named for its action
    (DRAWN_ACTION) and declared in the same file or imported into it; a few hops, so a button wrapping a button counts."""
    acted_by_file: dict[str, set[str]] = {}
    path_of: dict[str, str] = {}  # module path without suffix (and without a trailing /index) -> file
    for unit in units.values():
        if unit.path.endswith(".tsx"):
            stem = unit.path[:-len(".tsx")]
            path_of[stem] = unit.path
            path_of.setdefault(stem.rsplit("/index", 1)[0], unit.path)
    for _round in range(3):
        acted_by_file = {}
        for unit in units.values():
            if unit.acted and unit.path.endswith(".tsx") and DRAWN_ACTION.match(unit.name):
                acted_by_file.setdefault(unit.path, set()).add(unit.name)
        moved = False
        for unit in units.values():
            if unit.acted or not unit.path.endswith(".tsx"):
                continue
            names = set(acted_by_file.get(unit.path, set())) - {unit.name}
            for local, target in imports.get(unit.path, []):
                if local in acted_by_file.get(path_of.get(target, ""), set()):
                    names.add(local)
            if names and re.search(r"<(?:%s)\b" % "|".join(sorted(map(re.escape, names))), "\n".join(unit.lines)):
                unit.acted = True
                moved = True
        if not moved:
            break


def propagate(units: dict[str, Unit], imports: dict[str, list[tuple[str, str]]]) -> None:
    """Move a provider's unbounded hits to the units that draw them, up to a few hops. A provider with a bound or an
    action keeps its hits (it passes). A map or strings member no unit draws shows nothing and is dropped; a helper
    function no unit is seen to call keeps its hits (a call the scan cannot follow must not hide it)."""
    by_file: dict[str, list[Unit]] = {}
    for unit in units.values():
        by_file.setdefault(unit.path, []).append(unit)
    swift_units = [u for u in units.values() if u.path.endswith(".swift")]
    for _round in range(4):
        moved = False
        for unit in list(units.values()):
            if not unit.hits or unit.ok or not is_provider(unit):
                continue
            members = {member_at(unit, h.index) for h in unit.hits}
            # A label table or strings type passes its words on through two hops; a helper function through one,
            # so a call chain (a host bridge's error key) does not spread to every caller.
            if min(h.hops for h in unit.hits) >= (1 if None in members else 2):
                continue
            name = re.escape(unit.name)
            if None in members:
                use = re.compile(rf"\b{name}\b")
            else:
                alts = "|".join(sorted(re.escape(m) for m in members if m))
                use = re.compile(rf"\b{name}\s*(?:\.\s*(?P<m>{alts})\b|\[)" if not unit.path.endswith(".swift")
                                 else rf"\b{name}\.(?P<m>{alts})\b")
            # A Swift strings type held as a value (`let strings: RemoteViewStrings`, `strings.reconnecting`).
            instance = (re.compile(rf"\b(?:\w*[sS]trings|\w*[tT]ext|\w*[cC]opy|\w*[wW]ords|l10n)\.(?P<m>{alts})\b")
                        if unit.path.endswith(".swift") and None not in members
                        else None)
            named = re.compile(rf"\b{name}\b")
            if unit.path.endswith(".swift"):
                module = module_of(unit.path)
                pool = [u for u in swift_units if u is not unit and u.path.startswith(module)]
                if not any(use.search("\n".join(u.lines)) for u in pool):
                    pool = [u for u in swift_units if u is not unit]
            else:
                stem = re.sub(r"\.(tsx?)$", "", unit.path)
                pool = [u for u in by_file.get(unit.path, []) if u is not unit]
                for path, bindings in imports.items():
                    if path != unit.path and any(local == unit.name and target in (stem, stem.rsplit("/index", 1)[0])
                                                 for local, target in bindings):
                        pool.extend(by_file.get(path, []))
            consumers = []
            for other in pool:
                if other.name == "<file>":
                    continue  # its imports, not a drawing
                by_value = instance is not None and bool(named.search("\n".join(other.lines)))
                for i, line in enumerate(other.lines):
                    m = use.search(line) or (instance.search(line) if by_value else None)
                    if m:
                        member = m.groupdict().get("m")
                        said = next((h for h in unit.hits if member_at(unit, h.index) == member), unit.hits[0])
                        consumers.append((other, i, said))
                        break
            if not consumers:
                if None not in members and not unit.path.endswith(".swift"):
                    # A strings map's member that no unit draws (`L.x`, `L[...]`) shows nothing. A Swift strings
                    # member can reach its drawing through a value the scan cannot follow, so it keeps its hits.
                    unit.hits = []
                    moved = True
                continue
            for other, i, said in consumers:
                hops = min(h.hops for h in unit.hits) + 1
                other.hits.append(Hit(other.numbers[i], f"{unit.name}: {said.text}", i, hops, said.origin))
            unit.hits = []
            moved = True
        if not moved:
            break


def read_allowlist(text: str) -> dict[str, tuple[str, str, str]]:
    rows: dict[str, tuple[str, str, str]] = {}
    for line in text.split("\n"):
        if not line.strip() or line.startswith("#"):
            continue
        cells = line.split("\t")
        if len(cells) != 4 or not all(c.strip() for c in cells):
            raise ValueError(f"{ALLOWLIST}: a row needs unit, surface, owner and reason, tab-separated: {line!r}")
        rows[cells[0]] = (cells[1], cells[2], cells[3])
    return rows


def write_allowlist(path: Path, rows: dict[str, tuple[str, str, str]]) -> None:
    body = "".join(f"{unit}\t{s}\t{o}\t{r}\n" for unit, (s, o, r) in sorted(rows.items(), key=lambda kv: (kv[1][0], kv[0])))
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(ALLOWLIST_HEADER + body, encoding="utf-8")


class BaseUnreadable(Exception):
    """--base names a revision git cannot read: the ratchet cannot judge, so the check refuses."""


def git(root: Path, *args: str) -> subprocess.CompletedProcess[bytes]:
    try:
        return subprocess.run(["git", "-C", str(root), *args], capture_output=True)
    except OSError as error:
        raise BaseUnreadable(f"git did not run: {error}") from error


def base_allowlist(root: Path, rev: str) -> dict[str, tuple[str, str, str]] | None:
    """The list at REV; None only when REV resolves and has no list (the change that adds it)."""
    if git(root, "rev-parse", "--verify", "--quiet", f"{rev}^{{commit}}").returncode != 0:
        raise BaseUnreadable(f"--base {rev} does not resolve to a commit (fetch it, or a deeper checkout)")
    if git(root, "cat-file", "-e", f"{rev}:{ALLOWLIST}").returncode != 0:
        return None
    proc = git(root, "show", f"{rev}:{ALLOWLIST}")
    if proc.returncode != 0:
        raise BaseUnreadable(f"could not read {ALLOWLIST} at {rev}")
    return read_allowlist(proc.stdout.decode("utf-8", errors="replace"))


def check(root: Path, base: str | None, *, list_all: bool = False, out=sys.stdout) -> int:
    tree = Tree(root)
    units = scan(tree)
    if tree.missing:
        print(f"connection notices: cannot judge this tree: {len(tree.missing)} tracked file(s) are not on disk "
              f"(a sparse or partial checkout?), e.g. {', '.join(tree.missing[:3])}; run it in a full checkout",
              file=out)
        return 2
    path = root / ALLOWLIST
    allow = read_allowlist(path.read_text(encoding="utf-8", errors="replace")) if path.exists() else {}
    offenders = {u.id: u for u in units if not u.ok}
    unit_ids = tree.unit_ids
    problems: list[str] = bound_drift(tree)
    # Every unlisted offender is judged on every run, whatever file the change touched: whether a unit offends also
    # depends on files it does not live in (a strings map, a string table, the last in-module user of a Swift strings
    # type), so judging only touched files let an offender in that a later full run then failed on. The base passes
    # a full run, so no change pays for another's debt. --base adds the ratchet on the list's rows.
    try:
        before = base_allowlist(root, base) if base is not None else None
    except BaseUnreadable as error:
        print(f"connection notices: cannot judge the change: {error}", file=out)
        return 2
    unlisted = set(before) - set(allow) if before is not None else set()
    for uid, unit in sorted(offenders.items()):
        if uid in allow:
            continue
        first = unit.hits[0]
        why = (f"a literal grace under the bound ({', '.join(unit.literal_grace)}); name CONNECTION_QUIET_MS"
               if unit.literal_grace else "no action and no time bound")
        problems.append(f"{unit.path}:{first.line}: {unit.name} shows a connection state ({first.text!r}) with {why}")
    for uid in sorted(allow):
        if uid not in offenders:  # every run: the list never holds a fixed unit, whatever file fixed it
            problems.append(f"{ALLOWLIST}: stale row {uid}: it no longer shows an unbounded connection state; "
                            "remove the row in this change")
    if before is not None:
        # A row whose unit moved (same name and surface, another file, and the old unit no longer exists) is the
        # same debt, not a new one; each removed row covers one move. The surface comes from the paths, never from
        # the row's text, which the change writes.
        def move_key(uid: str) -> tuple[str, str | None]:
            path, name = uid.split("::", 1)
            return name, surface_of(path)
        gone = sorted((move_key(uid) for uid in unlisted if uid not in unit_ids), key=str)
        for uid in sorted(set(allow) - set(before)):
            key = move_key(uid)
            if key in gone:
                gone.remove(key)
                continue
            problems.append(f"{ALLOWLIST}: new row {uid}: the list only shrinks; give the state a bound "
                            "(CONNECTION_QUIET_MS) or one action instead")
    if list_all:
        for unit in sorted(units, key=lambda u: u.id):
            state = "action" if unit.acted else "bound" if unit.gated and not unit.literal_grace else (
                "listed" if unit.id in allow else "OFFENDER")
            for hit in unit.hits:
                print(f"{state}\t{unit.surface}\t{unit.path}:{hit.line}\t{unit.name}\t{hit.text}", file=out)
    for line in problems:
        print(line, file=out)
    if problems:
        print(f"connection notices: {len(problems)} finding(s). A connection state the person can do nothing about "
              "waits CONNECTION_QUIET_MS (useLasting / NoticeTiming.connectionQuiet) or carries one action; see "
              "cmuxterm-hq docs/handbook/connection-state-with-no-action-or-bound.md", file=out)
        return 1
    per = {}
    for uid in allow:
        per[allow[uid][0]] = per.get(allow[uid][0], 0) + 1
    print(f"connection notices: ok ({len(units)} units say a connection state; {len(allow)} listed: "
          + ", ".join(f"{k} {v}" for k, v in sorted(per.items())) + ")", file=out)
    return 0


# ---- Input blocked while connecting (report only) ----
# Leo, 2026-11-24, back in the iOS app after minutes in another app: "the reattaching dot, dot, dot type thing. ...
# the entire thing is somehow grayed out and I can't interact with anything at all." The same class as above, one
# step worse: the screen does not only say a connection state, it takes the person's input away (disabled, no hit
# testing, dimmed or grayed) until the link is back. This pass reports each place a control or a screen is disabled
# or dimmed on a connection condition. It reports; it does not fail a run (a blocking check needs Leo's word).
# A finding is fixed when input is accepted while the link comes back (queued or sent when it is up) and the screen
# stays as drawn; one that must stay (a send that cannot be queued) says why with an action.

# A condition about the link: an identifier or a state tag that names connecting, reconnecting, reattaching,
# handshaking, restoring, resuming, offline or disconnected, or the link's own state.
LINK_CONDITION = re.compile(
    r"(?i)(?<!\w)(?!can(?:dis)?connect|connector|(?-i:on[A-Z]))"
    r"\w*(?:connect|reattach|attaching|handshak|offline|resuming|linkstate|linkup|linkdown|linkislive|islinklive"
    r"|transportstate|socketstate|isreachable|unreachable|isattached)\w*"
    r"|\b(?:hub|link|relay|transport|socket|connection|session)\??\.(?:isReady|isLive|isAttached|ready|live)\b"
    r"|\bisLive\b"
)
# What takes input away or grays a view out, by language.
SWIFT_BLOCKS = re.compile(
    r"\.(?P<kind>disabled|allowsHitTesting|opacity|grayscale|saturation|redacted|blur)\s*\("
    r"|\b(?P<prop>isUserInteractionEnabled|isEnabled|alpha)\s*(?:=(?!=)|:\s)"
)
WEB_BLOCKS = re.compile(
    r"\b(?P<kind>disabled|aria-disabled|inert|readOnly|aria-busy)\s*=\s*\{"
    r"|\b(?P<prop>disabled|pointerEvents|opacity)\s*:\s*(?!\s*(?:boolean|number|string)\b)"
    r"|(?P<cls>pointer-events-none|opacity-\d+|grayscale|is-dimmed|dimmed|is-disabled)\b"
)
# A derived name that is a yes-or-no: a Bool, a comparison, a negation or a logic operator.
BOOLEAN_SHAPE = re.compile(r":\s*Bool\b|[!=]==?|!(?!=)\w|&&|\|\|")
# A dimming value: an opacity strictly between 0 and 1 (`0.6`, `.5`), not a show-or-hide toggle.
PARTIAL_OPACITY = re.compile(r"(?<![\w.])0?\.[0-9]*[1-9]")
# A Swift or TS name the unit derives from the link (`var inputBlocked: Bool { link != .live }`), one hop.
DERIVED = re.compile(r"\b(?:var|let|const)\s+(\w+)\b[^=\n{]*?(?:=(?!=)|\{)(.*)$")


@dataclass
class InputBlock:
    surface: str
    path: str
    line: int
    unit: str
    kind: str
    code: str


def _span(lines: list[str], i: int, start: int) -> str:
    """The modifier's text from START to its closing bracket, at most four lines on."""
    text = lines[i][start:]
    depth = 0
    out = []
    for n in range(i, min(i + 4, len(lines))):
        chunk = text if n == i else lines[n]
        for ch in chunk:
            out.append(ch)
            if ch in "({[":
                depth += 1
            elif ch in ")}]":
                depth -= 1
                if depth <= 0:
                    return "".join(out)
        out.append(" ")
        if depth <= 0 and n == i and not chunk.rstrip().endswith(("(", "{", "[", "?", ":", "&&", "||")):
            return "".join(out)
    return "".join(out)


def _argument(text: str) -> str:
    """A labelled value (`isEnabled: x, …`, `disabled: x,`) up to its own end: the first comma or closing bracket
    outside brackets of its own."""
    depth = 0
    for n, ch in enumerate(text):
        if ch in "({[":
            depth += 1
        elif ch in ")}]":
            if depth == 0:
                return text[:n]
            depth -= 1
        elif ch in ",;" and depth == 0:
            return text[:n]
    return text


def input_blocks(tree: Tree) -> list[InputBlock]:
    """Every place a view's input is taken away or the view is grayed out on a link condition."""
    found: list[InputBlock] = []
    for path in tree.files():
        surface = surface_of(path)
        if surface is None or not path.endswith(SOURCE_SUFFIXES) or SKIP.search(path):
            continue
        swift = path.endswith(".swift")
        blocks = SWIFT_BLOCKS if swift else WEB_BLOCKS
        lines = strip_comments(tree.read(path)).split("\n")
        for name, first, last in units_of(path, "\n".join(lines)):
            body = lines[first:last + 1]
            derived: set[str] = set()
            for _round in range(2):
                for i, line in enumerate(body):
                    m = DERIVED.search(line)
                    if not m:
                        continue
                    rest = m.group(2) + " " + (body[i + 1] if i + 1 < len(body) and len(m.group(2).strip()) < 3
                                               else "")
                    if not BOOLEAN_SHAPE.search(m.group(0)):
                        continue  # an object (`let model = …`), not a yes-or-no about the link
                    if LINK_CONDITION.search(rest) or any(re.search(rf"\b{re.escape(d)}\b", rest) for d in derived):
                        derived.add(m.group(1))
            derived_re = re.compile(r"\b(" + "|".join(map(re.escape, sorted(derived))) + r")\b") if derived else None
            for i, line in enumerate(body):
                if NOT_UI_LINE.search(line):
                    continue
                for m in blocks.finditer(line):
                    kind = m.group("kind") or m.group("prop") or m.groupdict().get("cls") or ""
                    text = line if m.groupdict().get("cls") else _span(body, i, m.start())
                    if m.group("prop"):
                        text = _argument(text)
                    if m.groupdict().get("cls"):
                        # A class is a block only when its own condition is the link: `link.up ? "" : "dimmed"`.
                        text = line
                    if kind in ("opacity", "alpha") and not PARTIAL_OPACITY.search(text):
                        continue  # shown or hidden (`shown ? 1 : 0`), not grayed out
                    if LINK_CONDITION.search(text) or (derived_re is not None and derived_re.search(text)):
                        found.append(InputBlock(surface, path, first + i + 1, name, kind,
                                                re.sub(r"\s+", " ", text.strip())[:160]))
                        break
    return found


def report_input_blocks(root: Path, *, as_json: bool = False, out=sys.stdout) -> int:
    tree = Tree(root)
    found = input_blocks(tree)
    if as_json:
        print(json.dumps({"schema": "cmux.input-blocked-while-connecting.v1", "missing": len(tree.missing),
                          "findings": [f.__dict__ for f in found]}, indent=2), file=out)
        return 0
    for f in found:
        print(f"{f.surface}\t{f.path}:{f.line}\t{f.unit}\t{f.kind}\t{f.code}", file=out)
    per: dict[str, int] = {}
    for f in found:
        per[f.surface] = per.get(f.surface, 0) + 1
    note = f"; {len(tree.missing)} tracked file(s) not on disk, unread" if tree.missing else ""
    print(f"input blocked while connecting: {len(found)} place(s) ("
          + (", ".join(f"{k} {v}" for k, v in sorted(per.items())) or "none") + f"){note}. A report, not a failing "
          "check: see cmuxterm-hq docs/handbook/connection-state-with-no-action-or-bound.md", file=out)
    return 0


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--root", type=Path, default=ROOT)
    parser.add_argument("--base", help="a revision whose allowlist this one may only shrink from (HEAD^1 on a PR)")
    parser.add_argument("--list", action="store_true", help="print every unit that says a connection state")
    parser.add_argument("--write-allowlist", action="store_true",
                        help="drop rows that are fixed; with --seed, list every offender (the first list only)")
    parser.add_argument("--seed", action="store_true", help=argparse.SUPPRESS)
    parser.add_argument("--input-block", action="store_true",
                        help="report each view disabled or dimmed while the link connects (exits 0: a report)")
    parser.add_argument("--json", action="store_true", help="with --input-block, the findings as JSON")
    args = parser.parse_args(argv)
    if args.input_block:
        return report_input_blocks(args.root, as_json=args.json)
    if args.write_allowlist:
        path = args.root / ALLOWLIST
        allow = read_allowlist(path.read_text(encoding="utf-8")) if path.exists() else {}
        offenders = {u.id: u for u in scan(Tree(args.root)) if not u.ok}
        rows = {uid: row for uid, row in allow.items() if uid in offenders}
        if args.seed:
            for uid, unit in offenders.items():
                rows.setdefault(uid, (unit.surface, "unowned", f"says {unit.hits[0].text!r} with no bound or action"))
        write_allowlist(path, rows)
        print(f"wrote {len(rows)} rows to {ALLOWLIST}")
        return 0
    return check(args.root, args.base, list_all=args.list)


if __name__ == "__main__":
    sys.exit(main())
