#!/usr/bin/env python3
"""Move one CmuxNextApp group into its destination target as a pure move (p11-codebase task 000b).

One group (a folder of Sources/CmuxNextApp, or a top-level family `Name.swift` + `Name+*.swift`) goes to
its destination target in one step, in the worktree, uncommitted:

  1. git mv its source files to Sources/<Destination>/<into>/ and its tests to Tests/<Destination>Tests/
     (a moved test's `@testable import CmuxNextApp` names the destination: the subject's module).
  2. String tables: an App table only the group uses moves whole; a shared one is split by key, each key
     the group uses going to the destination's table of the same name with every locale (`bundle:
     .module` rebinds to the destination's bundle on a move, and a missing key falls back silently).
     A key both sides use is copied, and so is one a non-Swift reader takes (gen-strings.mjs builds webview
     pages from App tables); a key only the group uses leaves the App table, and a key nothing references
     is deleted from it. Destination tables get the new members as text: their other bytes stay.
  3. follow-renames.py rewrites every mention of the moved paths (a merged table's too): the path-keyed
     baselines (its REGISTRY) and every other tracked text file, so `git grep <old path>` comes back empty.
  4. The localization debt baseline is recounted for the tables it touched; architecture-layers.json gets
     the destination when it lacks it (with the group's layer); crash_ratchet.py --update-baseline --base HEAD
     carries the module-keyed crash rows with the moved hits.

It never edits Package.swift (FREEZE, rule R10): a destination or test target, or a resources entry the
move needs, is printed as a manifest request for the manifest agent (task 019).

The group comes from plans/cmux-next/app-graph.json (task 000a): the `order` entry whose `group` (or `id`)
is --group. Fields read: destination, layer, files (paths under Sources/CmuxNextApp, folders allowed),
tests, into. Without the graph, or to override it: --destination, --layer, --file, --test, --into.

  move-app-files.py --group TabSearch --destination CmuxNextPalette --dry-run
  move-app-files.py --group TabSearch            # from app-graph.json
"""
from __future__ import annotations

import argparse
import importlib.util
import json
import re
import subprocess
import sys
from dataclasses import dataclass, field
from pathlib import Path

HERE = Path(__file__).resolve().parent
PKG = "Packages/macOS/CmuxNext/"
APP = "CmuxNextApp"
APP_SOURCES = PKG + "Sources/" + APP + "/"
APP_TESTS = PKG + "Tests/" + APP + "Tests/"
GRAPH = "plans/cmux-next/app-graph.json"
LAYERS = "plans/cmux-next/architecture-layers.json"
OWNERS = "plans/cmux-next/OWNERS.md"
PERF_HOT = "scripts/cmux-next/perf-hot-benches.json"
DEBT_BASELINE = "scripts/localization-debt-baseline.json"
CRASH_RATCHET = "scripts/cmux-next/crash_ratchet.py"
CRASH_BASELINE = "scripts/cmux-next/crash-safety-baseline.json"


def load(name: str, filename: str):
    spec = importlib.util.spec_from_file_location(name, filename)
    assert spec and spec.loader
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


follow = load("cmux_next_follow_renames", HERE / "follow-renames.py")
catalog = load("cmux_localization_catalog", HERE.parent / "localization_catalog.py")


class MoveError(Exception):
    pass


def git(repo: Path, *args: str) -> str:
    done = subprocess.run(["git", "-C", str(repo), *args], capture_output=True, text=True)
    if done.returncode != 0:
        raise MoveError(f"git {' '.join(args)}: {done.stderr.strip()}")
    return done.stdout


# ------------------------------------------------------------------------------------------- the group


@dataclass
class Group:
    name: str
    destination: str
    layer: str | None = None
    files: list[str] = field(default_factory=list)  # repository paths: files or folders
    tests: list[str] | None = None
    into: str | None = None


def app_path(path: str, root: str) -> str:
    """A group path as a repository path: absolute ones stay, others are under ROOT."""
    return path if path.startswith(PKG) else root + path.lstrip("/")


def group_from_graph(repo: Path, name: str) -> dict:
    path = repo / GRAPH
    if not path.is_file():
        return {}
    data = json.loads(path.read_text(encoding="utf-8"))
    for entry in data.get("order", []):
        if name in (entry.get("group"), entry.get("id"), str(entry.get("scc_id"))):
            return entry
    return {}


def resolve_group(repo: Path, args: argparse.Namespace) -> Group:
    entry = group_from_graph(repo, args.group)
    destination = args.destination or entry.get("destination")
    if not destination:
        raise MoveError(f"group {args.group}: no destination (not in {GRAPH}; pass --destination)")
    files = args.file or entry.get("files") or []
    tests = args.test if args.test is not None else entry.get("tests")
    return Group(name=args.group, destination=destination, layer=args.layer or entry.get("layer"),
                 files=[app_path(f, APP_SOURCES) for f in files],
                 tests=None if tests is None else [app_path(t, APP_TESTS) for t in tests],
                 into=args.into if args.into is not None else entry.get("into"))


def source_files(group: Group, tracked: list[str]) -> tuple[list[str], str]:
    """The group's tracked files and the App folder they are relative to."""
    if group.files:
        picked: list[str] = []
        for path in group.files:
            under = [f for f in tracked if f.startswith(path.rstrip("/") + "/")]
            picked += under or ([path] if path in tracked else [])
            if not under and path not in tracked:
                raise MoveError(f"{path}: not a tracked file or folder")
        folder = APP_SOURCES + group.name + "/"
        common = folder if all(p.startswith(folder) for p in picked) else APP_SOURCES
        return sorted(set(picked)), common
    folder = APP_SOURCES + group.name + "/"
    under = [f for f in tracked if f.startswith(folder)]
    if under:
        return under, folder
    family = re.compile(re.escape(APP_SOURCES + group.name) + r"(\+[^/]*)?\.swift\Z")
    picked = [f for f in tracked if family.match(f)]
    if not picked:
        raise MoveError(f"group {group.name}: no folder {folder} and no {group.name}.swift / {group.name}+*.swift")
    return picked, APP_SOURCES


def stem(path: str) -> str:
    return Path(path).name.removesuffix(".swift").split("+")[0]


def starts_with_word(name: str, prefix: str) -> bool:
    """Whether NAME starts with PREFIX as a CamelCase word: `ShareTests` and `Share+X` do, `SharedIndicator` does not."""
    rest = name[len(prefix):]
    return name.startswith(prefix) and bool(prefix) and (not rest or rest[0].isupper() or rest[0] in "+_" or rest[0].isdigit())


def test_files(repo: Path, group: Group, sources: list[str], tracked: list[str]) -> tuple[list[str], list[str]]:
    """(tests, notes). Explicit tests (the graph's `tests` field), else the App tests in a folder named for the group,
    each `<Name>...Tests.swift` whose longest CamelCase-word prefix among the App's file stems (`Stem` of
    `Stem+Part.swift`) and the group's name is a moved one (`TabSearchFactsTests` goes with TabSearch/, `TabStripTests`
    stays with an unmoved `TabStrip.swift`, `SharedIndicatorTests` is not `Share`'s), and the App test helpers
    (fixtures, fakes: files that are not `*Tests.swift`) whose types only the moving tests use."""
    if group.tests is not None:
        missing = [t for t in group.tests if t not in tracked]
        if missing:
            raise MoveError(f"tests not tracked: {', '.join(missing)}")
        return sorted(group.tests), []
    moved = {group.name} | {stem(f) for f in sources if f.endswith(".swift")}
    every = moved | {stem(f) for f in tracked if f.startswith(APP_SOURCES) and f.endswith(".swift")}
    folder = APP_TESTS + group.name + "/"
    app_tests = [f for f in tracked if f.startswith(APP_TESTS) and f.endswith(".swift")]
    chosen = set()
    for f in app_tests:
        name = Path(f).name
        owner = max((s for s in every if starts_with_word(name, s)), key=len, default=None) \
            if name.endswith("Tests.swift") else None
        if f.startswith(folder) or owner in moved:
            chosen.add(f)
    return helpers_of(repo, chosen, app_tests)


def helpers_of(repo: Path, chosen: set[str], app_tests: list[str]) -> tuple[list[str], list[str]]:
    """CHOSEN plus each App test helper whose declared types are used by chosen files only (to a fixed point), and a
    note for each helper both a moving and a staying test use (it stays: the moved test needs it from somewhere)."""
    if not chosen:
        return [], []
    texts = {f: (repo / f).read_text(encoding="utf-8", errors="replace") for f in app_tests}
    helpers = {}
    for f in app_tests:
        types = follow.declared_types(texts[f])
        if not f.endswith("Tests.swift") and types:
            helpers[f] = re.compile(r"\b(?:" + "|".join(map(re.escape, sorted(types))) + r")\b")
    users = {f: {g for g in app_tests if g != f and word.search(texts[g])} for f, word in helpers.items()}
    chosen, grew = set(chosen), True
    while grew:
        grew = False
        for f, who in users.items():
            if f not in chosen and who and who <= chosen:
                chosen.add(f)
                grew = True
    notes = [f"{f} stays in {APP}Tests: moving tests ({', '.join(sorted(Path(g).name for g in who & chosen)[:3])}) "
             "and staying ones use it" for f, who in sorted(users.items()) if f not in chosen and who & chosen]
    return sorted(chosen), notes


# ---------------------------------------------------------------------------------------- string tables

LITERAL = re.compile(r'"((?:[^"\\\n]|\\.)*)"')
INTERPOLATION = re.compile(r"\\\((?:[^()]|\([^()]*\))*\)")
TABLE_ARG = re.compile(r'\btable:\s*"([^"]+)"')
PLACEHOLDER = "\0"


def unescape(literal: str) -> str:
    def one(m: re.Match) -> str:
        c = m.group(1)
        if c.startswith("u{"):
            return chr(int(c[2:-1], 16))
        return {"n": "\n", "t": "\t", "r": "\r", "0": "\0", '"': '"', "'": "'", "\\": "\\"}.get(c, c)
    return re.sub(r"\\(u\{[0-9a-fA-F]+\}|.)", one, literal)


def literals(text: str) -> set[str]:
    """The string literals of Swift source, interpolations read as one placeholder each."""
    out = set()
    for m in LITERAL.finditer(text):
        out.add(unescape(INTERPOLATION.sub(PLACEHOLDER, m.group(1))))
    return out


def normal_key(key: str) -> str:
    """A table key with each format specifier as one placeholder, so `Window %lld` meets `Window \\(n)`."""
    return catalog.FORMAT.sub(lambda m: "%" if m.group(0) == "%%" else PLACEHOLDER, key)


class KeyIndex:
    """Which keys of a set of tables a set of literals uses: exactly (format specifiers and interpolations
    as placeholders), or as a dotted dynamic prefix (`"tabSearch.refusal.\\(reason)"`)."""

    def __init__(self, keys: set[str]):
        self.by_normal: dict[str, set[str]] = {}
        for key in keys:
            self.by_normal.setdefault(normal_key(key), set()).add(key)
        self.keys = keys

    def used(self, found: set[str]) -> set[str]:
        out: set[str] = set()
        for lit in found:
            out |= self.by_normal.get(lit, set())
            if PLACEHOLDER in lit:
                prefix, _, rest = lit.partition(PLACEHOLDER)
                suffix = rest.rsplit(PLACEHOLDER, 1)[-1]
                if len(prefix) >= 4 and prefix[-1] in "._-" and not any(c.isspace() for c in prefix):
                    out |= {k for k in self.keys if k.startswith(prefix) and k.endswith(suffix)}
        return out


@dataclass
class Table:
    path: str
    text: str

    @property
    def name(self) -> str:
        return Path(self.path).name.removesuffix(".xcstrings")

    @property
    def data(self) -> dict:
        return json.loads(self.text)

    @property
    def strings(self) -> dict:
        return self.data["strings"]


def member_spans(text: str) -> list[tuple[str, int, int]]:
    """(key, start of its line, end of its value) for each member of the table's `strings` object."""
    decoder = json.JSONDecoder()
    strings = re.search(r'"strings"\s*:\s*\{', text)
    if not strings:
        raise MoveError("no strings object")
    pos, out = strings.end(), []
    while True:
        while text[pos].isspace() or text[pos] == ",":
            pos += 1
        if text[pos] == "}":
            return out
        key_start = pos
        key, pos = decoder.raw_decode(text, pos)
        pos = text.index(":", pos) + 1
        while text[pos].isspace():
            pos += 1
        _, pos = decoder.raw_decode(text, pos)
        line = text.rfind("\n", 0, key_start) + 1
        if text[line:key_start].strip():
            raise MoveError("a string key that does not start its own line")
        out.append((key, line, pos))


def remove_keys(text: str, keys: set[str]) -> str:
    """TEXT without the members KEYS, every other byte as it was (the App table's diff is only deletions)."""
    spans = member_spans(text)
    if not keys & {k for k, _, _ in spans}:
        return text
    close = text.rfind("\n", 0, text.index("}", spans[-1][2])) + 1
    keep = [i for i, (k, _, _) in enumerate(spans) if k not in keys]
    out, last = [], 0
    for i, (key, line, _end) in enumerate(spans):
        nxt = spans[i + 1][1] if i + 1 < len(spans) else close
        if key in keys:
            out.append(text[last:line])
            last = nxt
    out.append(text[last:])
    result = "".join(out)
    if keep and keep[-1] != len(spans) - 1:
        # The new last member lost its follower: drop its trailing comma.
        new_spans = member_spans(result)
        end = new_spans[-1][2]
        comma = result.index(",", end) if result[end:].lstrip().startswith(",") else -1
        if comma >= 0:
            result = result[:comma] + result[comma + 1:]
    return result


def separator(text: str) -> str:
    """A table's key separator: Xcode writes `"key" : value`, json.dumps `"key": value`."""
    return " : " if re.search(r'"(?:sourceLanguage|strings)" :', text) else ": "


def line_indent(text: str, line: int) -> str:
    """The spaces and tabs that start the line at offset LINE."""
    rest = text[line:]
    return rest[:len(rest) - len(rest.lstrip(" \t"))]


# Orders a table's keys may be in (Xcode writes code point order; some tables are case-folded); a table in
# neither keeps its own order and gets new keys at the end.
KEY_ORDERS = (lambda k: k, lambda k: (k.casefold(), k))


def add_entries(dest_text: str | None, source_text: str, keys: set[str]) -> str:
    """The destination table with the members KEYS of SOURCE_TEXT added as text, every existing byte kept (its diff is
    only the added members). Each member is copied from the source with its own bytes, re-indented to the
    destination's member indent, and placed at its sorted position when the destination's keys are sorted, else
    after its last member. A new destination is the source table less every other key (the source's layout)."""
    spans = {k: (line, end) for k, line, end in member_spans(source_text)}
    if dest_text is None:
        return remove_keys(source_text, set(spans) - keys)
    source = json.loads(source_text)["strings"]
    dest = json.loads(dest_text)["strings"]
    for key in sorted(keys & set(dest)):
        if dest[key] != source[key]:
            raise MoveError(f"key {key!r} is already in the destination table with other text")
    new = sorted(keys - set(dest), key=lambda k: spans[k][0])  # source order
    if not new:
        return dest_text
    dest_spans = member_spans(dest_text)
    if not dest_spans:
        raise MoveError("the destination table has an empty strings object; add the keys by hand")
    src_indent, dest_indent = line_indent(source_text, spans[new[0]][0]), line_indent(dest_text, dest_spans[0][1])
    same_style = separator(source_text) == separator(dest_text)

    def member(key: str) -> str:
        if not same_style:  # the destination's separators, in Xcode's layout
            text = json.dumps({key: source[key]}, indent=2, ensure_ascii=False, separators=(",", separator(dest_text)))
            lines = text[1:-1].strip("\n").split("\n")
            return "\n".join(dest_indent + ln[2:] for ln in lines)
        line, end = spans[key]
        lines = source_text[line:end].split("\n")
        return "\n".join(dest_indent + ln[len(src_indent):] if ln.startswith(src_indent) else ln for ln in lines)

    names = [k for k, _, _ in dest_spans]
    order = next((o for o in KEY_ORDERS if names == sorted(names, key=o)), None)
    inserts: dict[int, list[tuple[str, str]]] = {}  # position -> (key, text), before the member there or at the end
    last_end = dest_spans[-1][2]
    for key in (new if order is None else sorted(new, key=order)):
        after = None if order is None else next((s for s in dest_spans if order(s[0]) > order(key)), None)
        if after is None:
            inserts.setdefault(last_end, []).append((key, ",\n" + member(key)))
        else:
            inserts.setdefault(after[1], []).append((key, member(key) + ",\n"))
    out, last = [], 0
    for pos in sorted(inserts):
        out += [dest_text[last:pos], *(text for _, text in inserts[pos])]
        last = pos
    return "".join(out) + dest_text[last:]


# ------------------------------------------------------------------------------------------- the plan


@dataclass
class Plan:
    group: Group
    renames: dict[str, str] = field(default_factory=dict)  # old -> new (sources, tests, whole tables)
    tests: list[str] = field(default_factory=list)
    table_moves: list[dict] = field(default_factory=list)
    table_writes: dict[str, str] = field(default_factory=dict)  # path -> new text
    table_removes: list[str] = field(default_factory=list)  # App tables merged whole into an existing one
    merged_tables: dict[str, str] = field(default_factory=dict)  # those App tables -> the table they merged into
    moved_keys: dict[str, set[str]] = field(default_factory=dict)  # destination table -> keys it must hold
    reader_keys: dict[str, set[str]] = field(default_factory=dict)  # split App table -> keys a non-Swift reader reads
    layer_text: str | None = None  # architecture-layers.json with the new destination, when it lacks it
    folders: dict[str, str] = field(default_factory=dict)  # App folders that moved whole
    followed: object = None  # the follow-renames Renames the move applied
    manifest: list[str] = field(default_factory=list)
    notes: list[str] = field(default_factory=list)
    perf_hot: list[str] = field(default_factory=list)
    problems: list[str] = field(default_factory=list)  # found while applying (a crash row that could not follow)

    def as_dict(self) -> dict:
        return {"group": self.group.name, "destination": self.group.destination, "renames": self.renames,
                "tables": self.table_moves, "manifest_requests": self.manifest, "notes": self.notes,
                "perf_hot": self.perf_hot, "tests": self.tests}


def target_body(manifest: str, kind: str, name: str) -> str | None:
    m = re.search(r"\." + kind + r'\(\s*name:\s*"' + re.escape(name) + r'"(.*?)\n        \)', manifest, re.S)
    return m.group(1) if m else None


def destination_table_path(repo: Path, dest: str, table: str, body: str | None, plan: Plan) -> str:
    root = PKG + "Sources/" + dest + "/"
    existing = sorted(p.relative_to(repo).as_posix() for p in (repo / root).rglob(table + ".xcstrings")) \
        if (repo / root).is_dir() else []
    if existing:
        return existing[0]
    processes = re.findall(r'\.(?:process|copy)\("([^"]+)"\)', body or "")
    if "Resources" in processes or (repo / root / "Resources").is_dir():
        path = root + "Resources/" + table + ".xcstrings"
    elif any(p.endswith(".xcstrings") for p in processes):
        path = root + table + ".xcstrings"
    else:
        path = root + "Resources/" + table + ".xcstrings"
    rel = path[len(root):]
    if body is not None and "resources:" not in body:
        plan.manifest.append(f'{dest}: add resources: [.process("Resources")] (it gets {rel})')
    elif body is not None and not any(rel == p or rel.startswith(p.rstrip("/") + "/") for p in processes):
        plan.manifest.append(f'{dest}: add .process("{rel}") to resources')
    return path


# Non-Swift code that reads App string tables by path (webviews/scripts/pages/gen-strings.mjs builds the webview
# pages' strings from them). Tests and the move tools only name paths.
READER_SUFFIXES = (".mjs", ".js", ".cjs", ".ts", ".tsx", ".py", ".sh", ".rb")
READER_TABLE = re.compile(r"CmuxNextApp/((?:[A-Za-z0-9_+\-]+/)*[A-Za-z0-9_+\-]+\.xcstrings)")
# A gen-strings catalog's key filter: `key.startsWith("p.")`, `key === "k"`, `() => ["k", ...]`. Any other test
# (a regex, endsWith, a helper) reads as every key.
KEY_PREFIX = re.compile(r"startsWith\(\s*([\"'`])([^\"'`]+)\1\s*\)")
KEY_EXACT = re.compile(r"===\s*([\"'])([^\"']+)\1|^\s*\(\)\s*=>\s*\[([^\]]*)\]")
KEY_CALL = re.compile(r"([A-Za-z_$][\w$]*)\s*\(")
KEY_CALLS_READ = {"filter", "startsWith"}


@dataclass
class Reader:
    path: str  # the reading file
    prefixes: tuple[str, ...] = ()
    exact: frozenset[str] = frozenset()
    every: bool = True

    def reads(self, key: str) -> bool:
        return self.every or key in self.exact or key.startswith(self.prefixes)


def key_filter(path: str, expression: str | None) -> Reader:
    """The keys a reader takes from a table: EXPRESSION is its `keys:` filter, None when it has none (every key)."""
    if expression is None:
        return Reader(path)
    expression = re.sub(r"//[^\n]*", "", expression)
    if any(call not in KEY_CALLS_READ for call in KEY_CALL.findall(expression)):
        return Reader(path)
    prefixes = tuple(m.group(2) for m in KEY_PREFIX.finditer(expression))
    exact = {m.group(2) for m in KEY_EXACT.finditer(expression) if m.group(2)}
    for m in KEY_EXACT.finditer(expression):
        if m.group(3) is not None:
            exact |= set(re.findall(r"[\"'`]([^\"'`]+)[\"'`]", m.group(3)))
    if not prefixes and not exact:
        return Reader(path)
    return Reader(path, prefixes, frozenset(exact), every=False)


def table_readers(repo: Path, tracked: list[str]) -> dict[str, list[Reader]]:
    """App table path -> the non-Swift code that reads it, with the keys each takes."""
    out: dict[str, list[Reader]] = {}
    for path in tracked:
        name = Path(path).name
        if (not path.endswith(READER_SUFFIXES) or "/tests/" in "/" + path or name.startswith("test_")
                or name in ("move-app-files.py", "follow-renames.py")):
            continue
        try:
            text = (repo / path).read_text(encoding="utf-8")
        except (OSError, UnicodeDecodeError):
            continue
        if "CmuxNextApp/" not in text:
            continue
        for m in READER_TABLE.finditer(text):
            # The catalog entry is the text up to the next catalog (`file:`) or page (`out:`).
            ends = [i for i in (text.find("file:", m.end()), text.find("out:", m.end())) if i >= 0]
            entry = text[m.end():min(ends, default=len(text))]
            keys = entry.find("keys:")
            out.setdefault(APP_SOURCES + m.group(1), []).append(
                key_filter(path, entry[keys + len("keys:"):] if keys >= 0 else None))
    return out


def plan_tables(repo: Path, plan: Plan, moved_sources: list[str], tracked: list[str], body: str | None) -> None:
    """Each App table the group uses: moved whole when no staying App file uses it (merged when the destination has
    the table), else split by key. A split moves the keys only the group uses, copies the keys staying App code or a
    non-Swift reader (table_readers) also uses, and deletes from the App table the keys nothing references (no App
    source or test literal, no dynamic prefix, no reader): no App table keeps an unreferenced key."""
    app_swift = [f for f in tracked if f.startswith(APP_SOURCES) and f.endswith(".swift")]
    moved = set(moved_sources)
    moved_text = "\n".join((repo / f).read_text(encoding="utf-8", errors="replace") for f in moved_sources if f.endswith(".swift"))
    rest_text = "\n".join((repo / f).read_text(encoding="utf-8", errors="replace") for f in app_swift if f not in moved)
    test_text = "\n".join((repo / f).read_text(encoding="utf-8", errors="replace") for f in tracked
                          if f.startswith(APP_TESTS) and f.endswith(".swift"))
    moved_lits, rest_lits, test_lits = literals(moved_text), literals(rest_text), literals(test_text)
    moved_named, rest_named = set(TABLE_ARG.findall(moved_text)), set(TABLE_ARG.findall(rest_text))
    prefixes = tuple(sorted(lit for lit in moved_lits | rest_lits | test_lits
                            if len(lit) >= 4 and lit[-1] in "._-" and PLACEHOLDER not in lit
                            and not any(c.isspace() for c in lit)))
    readers = table_readers(repo, tracked)
    tables = [Table(f, (repo / f).read_text(encoding="utf-8")) for f in tracked
              if f.startswith(APP_SOURCES) and f.endswith(".xcstrings") and f not in moved]
    all_keys: set[str] = set()
    for table in tables:
        index = KeyIndex(set(table.strings))
        all_keys |= index.keys
        mine = index.used(moved_lits)
        if not mine:
            if table.name in moved_named:
                plan.notes.append(f"{table.path}: the group names table {table.name} but uses none of its keys")
            continue
        theirs = index.used(rest_lits)
        read = {k for k in index.keys if any(r.reads(k) for r in readers.get(table.path, []))}
        dest = destination_table_path(repo, plan.group.destination, table.name, body, plan)
        dest_text = plan.table_writes.get(dest) or ((repo / dest).read_text(encoding="utf-8") if (repo / dest).is_file() else None)
        unreferenced = index.keys - mine - theirs - read
        # Whole when the App keeps no use of it (a reader's path follows the table); a table with keys nobody
        # references moves whole only when no remaining App file names it (Localizable is everyone's default table).
        whole = not theirs and (not unreferenced or (table.name != "Localizable" and table.name not in rest_named))
        if whole and dest_text is None:
            plan.renames[table.path] = dest
            plan.table_moves.append({"table": table.path, "to": dest, "mode": "move", "keys": len(index.keys)})
            plan.moved_keys[dest] = set(index.keys)
            continue
        if whole:
            plan.table_writes[dest] = add_entries(dest_text, table.text, set(index.keys))
            plan.table_removes.append(table.path)
            plan.merged_tables[table.path] = dest
            plan.table_moves.append({"table": table.path, "to": dest, "mode": "merge", "keys": len(index.keys)})
            plan.moved_keys[dest] = set(index.keys)
            plan.notes += [f"{r.path} reads {table.path}, which merges into {dest}: it now reads that table's other keys too"
                           for r in readers.get(table.path, []) if r.every]
            continue
        only_mine, kept = mine - theirs - read, mine & (theirs | read)
        # A key no App source or test literal names, no interpolated prefix (`"x.\(y)"`) and no concatenated one
        # (`"x." + y`) reaches, and no reader takes: dead, deleted from the App table.
        dead = {k for k in unreferenced - index.used(test_lits) if not k.startswith(prefixes)}
        plan.table_writes[dest] = add_entries(dest_text, table.text, mine)
        plan.table_writes[table.path] = remove_keys(table.text, only_mine | dead)
        plan.moved_keys[dest] = set(mine)
        if read:
            plan.reader_keys[table.path] = read
        plan.table_moves.append({"table": table.path, "to": dest, "mode": "split", "moved": len(only_mine),
                                 "copied": len(kept), "deleted_unreferenced": sorted(dead),
                                 "kept": len(index.keys - only_mine - dead)})
    # Explicit lookups whose key no App table has: they fall back today and will after the move.
    explicit = set(re.findall(r'localized:\s*"((?:[^"\\\n]|\\.)*)"', moved_text))
    known = KeyIndex(all_keys)
    missing = {k for k in explicit if "\\(" not in k and not known.used({unescape(k)})}
    for key in sorted(missing):
        plan.notes.append(f"key {key!r} is in no App table (already falls back before the move)")


IMPORT = re.compile(r"^(?:@testable\s+|@_spi\([^)]*\)\s+)*import\s+(?:(?:struct|class|enum|protocol|func|var)\s+)?([A-Za-z_][A-Za-z0-9_]*)", re.M)


def plan_dependencies(repo: Path, plan: Plan, manifest: str, target: str, body: str | None, files: list[str],
                      subject: str | None = None) -> None:
    """Ask the manifest agent for each package target the moved FILES import that TARGET does not depend on."""
    declared = set(re.findall(r'\.(?:target|testTarget)\(\s*name:\s*"([^"]+)"', manifest))
    deps = set(re.findall(r'"([^"]+)"', body.split("dependencies:", 1)[1].split("]", 1)[0])) \
        if body and "dependencies:" in body else set()
    imports: set[str] = set()
    for path in files:
        if path.endswith(".swift"):
            imports |= set(IMPORT.findall((repo / path).read_text(encoding="utf-8", errors="replace")))
    imports.discard(target)
    if subject:
        imports.discard(APP)  # a moved test's `@testable import CmuxNextApp` becomes the subject's module
        imports.add(subject)
    if APP in imports:
        plan.notes.append(f"{target}: a moved file imports {APP} (upward edge): the seam commit (gen-host-seam.py) comes first")
        imports.discard(APP)
    missing = sorted(imports & declared - deps)
    if body is None and missing:
        plan.manifest.append(f"{target}: its dependencies: {', '.join(missing)}")
    elif body is not None:
        plan.manifest += [f'{target}: add dependency "{module}"' for module in missing]


def plan_move(repo: Path, group: Group) -> Plan:
    if group.destination == APP:
        raise MoveError("the destination is CmuxNextApp")
    tracked = follow.tracked(repo, None)
    trackset = set(tracked)
    plan = Plan(group)
    sources, base = source_files(group, tracked)
    into = group.into if group.into is not None else (group.name if base != APP_SOURCES else "")
    dest_root = PKG + "Sources/" + group.destination + "/" + (into.strip("/") + "/" if into.strip("/") else "")
    for src in sources:
        plan.renames[src] = dest_root + src[len(base):]
    plan.tests, test_notes = test_files(repo, group, sources, tracked)
    plan.notes += test_notes
    test_root = PKG + "Tests/" + group.destination + "Tests/"
    for test in plan.tests:
        plan.renames[test] = test_root + test[len(APP_TESTS):]
    manifest = (repo / PKG / "Package.swift").read_text(encoding="utf-8") if (repo / PKG / "Package.swift").is_file() else ""
    body = target_body(manifest, "target", group.destination)
    if body is None:
        plan.manifest.append(f"declare .target {group.destination} (task 007 scaffolds destinations)")
    test_body = target_body(manifest, "testTarget", group.destination + "Tests")
    if plan.tests and test_body is None:
        plan.manifest.append(f"declare .testTarget {group.destination}Tests (dependencies: [\"{group.destination}\"])")
    plan_dependencies(repo, plan, manifest, group.destination, body, sources)
    plan_dependencies(repo, plan, manifest, group.destination + "Tests", test_body, plan.tests, group.destination)
    plan_tables(repo, plan, sources, tracked, body)
    plan_layer(repo, group.destination, group.layer, plan)
    # Pure-move preconditions: nothing overwritten, one basename per module (Swift refuses a duplicate).
    for old, new in plan.renames.items():
        if new in trackset or (repo / new).exists():
            raise MoveError(f"{new} already exists (moving {old})")
    for root in (PKG + "Sources/" + group.destination + "/", test_root):
        present = {Path(f).name for f in tracked if f.startswith(root) and f.endswith(".swift")}
        incoming = [Path(n).name for n in plan.renames.values() if n.startswith(root) and n.endswith(".swift")]
        clash = sorted((present & set(incoming)) | {n for n in incoming if incoming.count(n) > 1})
        if clash:
            raise MoveError(f"{root}: Swift file name(s) already in the module: {', '.join(clash)}")
    hot = re.compile(r"//\s*perf-hot:\s*(\S+)\s+(\S+)")
    benches = {}
    if (repo / PERF_HOT).is_file():
        benches = json.loads((repo / PERF_HOT).read_text(encoding="utf-8")).get("paths", {})
    for src in sources:
        if src.endswith(".swift"):
            for m in hot.finditer((repo / src).read_text(encoding="utf-8", errors="replace")):
                bench = benches.get(m.group(2), {}).get("bench", "no bench listed")
                plan.perf_hot.append(f"{plan.renames[src]}: {m.group(2)} ({m.group(1)}): run {bench} on Release before and after")
    return plan


# -------------------------------------------------------------------------------------------- applying


def retarget_test_imports(repo: Path, tests: list[str], dest: str) -> None:
    pattern = re.compile(r"^@testable import " + APP + r"$", re.M)
    for path in tests:
        file = repo / path
        text = file.read_text(encoding="utf-8")
        new = pattern.sub(f"@testable import {dest}", text)
        if new != text:
            file.write_text(new, encoding="utf-8")


def recount_debt(repo: Path, catalogs: set[str]) -> None:
    path = repo / DEBT_BASELINE
    if not path.is_file() or not catalogs:
        return
    baseline = json.loads(path.read_text(encoding="utf-8"))["catalogs"]
    omissions = catalog.load_metadata("localization-allowed-omissions.json")
    counts = catalog.load_metadata("localization-plurals.json")
    for name in sorted(catalogs):
        file = repo / name
        baseline.pop(name, None)
        if not file.is_file():
            continue
        kinds: dict[str, int] = {}
        for entry in catalog.catalog_entries(file.read_text(encoding="utf-8")):
            for locale in catalog.LOCALES:
                for error in catalog.check_entry(entry, locale, omissions, counts):
                    kind = catalog.debt_kind(error)
                    kinds[kind] = kinds.get(kind, 0) + 1
        if kinds:
            baseline[name] = dict(sorted(kinds.items()))
    path.write_text(catalog.debt_json(dict(sorted(baseline.items()))), encoding="utf-8")


def plan_layer(repo: Path, dest: str, layer: str | None, plan: Plan) -> None:
    """architecture-layers.json with DEST added (plan.layer_text), planned before any file moves: one line
    `"Dest": {"layer": "x"}` after the last target of its layer (or at its sorted place when the targets are sorted),
    every other byte kept. Blank lines between the layer blocks are kept; a target entry that spans lines refuses."""
    path = repo / LAYERS
    if not path.is_file():
        return
    text = path.read_text(encoding="utf-8")
    targets = json.loads(text)["targets"]
    if dest in targets:
        if layer and targets[dest].get("layer") != layer:
            plan.notes.append(f"{LAYERS}: {dest} is {targets[dest].get('layer')}, the graph says {layer}: a relabel "
                              "is its own push (the map's _relayered_doc)")
        return
    if not layer:
        raise MoveError(f"{dest} is not in {LAYERS}: pass --layer (core, service, domain, ui)")
    lines = text.splitlines(keepends=True)
    start = next((i for i, ln in enumerate(lines) if re.match(r'\s*"targets"\s*:\s*\{\s*$', ln)), None)
    end = next((i for i in range(start + 1, len(lines)) if lines[i].strip().startswith("}")), None) \
        if start is not None else None
    if start is None or end is None:
        raise MoveError(f"{LAYERS}: no one-line-per-target \"targets\" object; add {dest} ({layer}) by hand")
    rows = []  # (line, name, layer)
    for i in range(start + 1, end):
        row = lines[i].strip()
        if not row or row.startswith("//"):
            continue
        try:
            (name, value), = json.loads("{" + row.rstrip(",") + "}").items()
        except ValueError:
            raise MoveError(f"{LAYERS}:{i + 1}: a target entry that is not one line; add {dest} ({layer}) by hand") from None
        rows.append((i, name, value.get("layer") if isinstance(value, dict) else None))
    names = [n for _, n, _ in rows]
    if not rows:
        after = start
    elif names == sorted(names):
        after = max([i for i, n, _ in rows if n < dest], default=start)
    else:
        after = max([i for i, _, lay in rows if lay == layer], default=rows[-1][0])
    indent = line_indent(lines[rows[0][0]], 0) if rows else "    "
    new = f'{indent}"{dest}": {{"layer": "{layer}"}}'
    if rows and after == rows[-1][0]:
        lines[after] = lines[after].rstrip("\n").rstrip(",") + ",\n"
        lines.insert(after + 1, new + "\n")
    else:
        lines.insert(after + 1, new + (",\n" if rows else "\n"))
    out = "".join(lines)
    if json.loads(out)["targets"].get(dest) != {"layer": layer}:
        raise MoveError(f"{LAYERS}: could not add {dest}; add it ({layer}) by hand")
    plan.layer_text = out


def owner_rows(before: str, after: str) -> list[str]:
    old = set(before.splitlines())
    rows = []
    for line in after.splitlines():
        if line not in old and line.startswith("|"):
            cells = [c.strip() for c in line.strip("|").split("|")]
            rows.append(f"{cells[0]} (owner: {cells[2] if len(cells) > 2 else '?'})")
    return rows


def carry_crash_rows(repo: Path, plan: Plan) -> list[str]:
    """crash_ratchet.py --update-baseline --base HEAD (the repository's own copy, which writes the baseline next to
    it): its module-keyed rows follow the moved hits (the same lines, proven against HEAD's tree), so the
    destination's row rises by what the App's row loses. Problems when a row stays above the baseline."""
    script = repo / CRASH_RATCHET
    if not script.is_file():
        return []
    done = subprocess.run([sys.executable, "-I", str(script), "--repo", str(repo), "--update-baseline", "--base", "HEAD"],
                          capture_output=True, text=True, stdin=subprocess.DEVNULL)
    plan.notes += [line for line in done.stdout.splitlines() if line.startswith("crash-ratchet: moved:")]
    if done.returncode == 0:
        return []
    held = [line for line in (done.stdout + done.stderr).splitlines() if "not raised" in line or "refused" in line]
    return [f"{CRASH_RATCHET}: {line}" for line in held or [f"exit {done.returncode}: {done.stderr.strip()[-300:]}"]]


def apply_plan(repo: Path, plan: Plan) -> follow.Report:
    """Moves the files, writes the tables and follows the paths; every decision was made in plan_move. A failure after
    the first `git mv` is reported as a MoveError that says the worktree holds a partial move."""
    owners_before = (repo / OWNERS).read_text(encoding="utf-8") if (repo / OWNERS).is_file() else ""
    before = follow.tracked(repo, None)
    started = False
    try:
        for old, new in plan.renames.items():
            (repo / new).parent.mkdir(parents=True, exist_ok=True)
            git(repo, "mv", old, new)
            started = True
        for path, text in plan.table_writes.items():
            (repo / path).parent.mkdir(parents=True, exist_ok=True)
            (repo / path).write_text(text, encoding="utf-8")
            git(repo, "add", path)
            started = True
        for path in plan.table_removes:
            git(repo, "rm", "-q", path)
        retarget_test_imports(repo, [plan.renames[t] for t in plan.tests], plan.group.destination)
        # A table merged into the destination's is a rename for every mention (gen-strings.mjs reads it by path).
        renames = follow.Renames({**plan.renames, **plan.merged_tables}, before)
        plan.folders = renames.folders
        report = follow.apply(repo, renames)
        plan.followed = renames
        touched = {m["table"] for m in plan.table_moves} | {m["to"] for m in plan.table_moves}
        recount_debt(repo, touched)
        if plan.layer_text is not None:
            (repo / LAYERS).write_text(plan.layer_text, encoding="utf-8")
        plan.problems += carry_crash_rows(repo, plan)
        if owners_before:
            plan.notes += [f"owned area changed, add the owner trailer: {row}"
                           for row in owner_rows(owners_before, (repo / OWNERS).read_text(encoding="utf-8"))]
        # Stage every edit, so the move is one `git commit` (the generated files the report names stay out).
        edited = set(report.edited) | {DEBT_BASELINE, LAYERS, CRASH_BASELINE} | {plan.renames[t] for t in plan.tests}
        git(repo, "add", "--", *sorted(p for p in edited if (repo / p).is_file()))
    except Exception as error:
        if not started:
            raise
        raise MoveError(f"failed after the move started ({type(error).__name__}: {error}); the worktree and index hold "
                        "a partial move: see git status") from error
    return report


def verify(repo: Path, plan: Plan, report: follow.Report, renames: follow.Renames) -> list[str]:
    """What the acceptance asks of a move: no old path left, every moved key with every locale, every key a non-Swift
    reader takes still in the App table, and the crash rows carried (plan.problems)."""
    problems = list(plan.problems)
    problems += [f"old path still named: {line}" for line in follow.leftovers(repo, renames, report.generated)]
    # Left as it was: its new spelling would also cover what the destination folder already held.
    problems += [f"old folder or glob still named, review it by hand: {line}" for line in report.widened]
    for path, keys in plan.reader_keys.items():
        table = json.loads((repo / path).read_text(encoding="utf-8"))["strings"]
        problems += [f"{path}: lost {key!r}, which a non-Swift reader takes" for key in sorted(keys - set(table))]
    for dest, keys in plan.moved_keys.items():
        table = json.loads((repo / dest).read_text(encoding="utf-8"))["strings"]
        for key in sorted(keys):
            if key not in table:
                problems.append(f"{dest}: missing key {key!r}")
    for move in plan.table_moves:
        src = repo / move["table"]
        if move["mode"] == "split" and src.is_file():
            source = json.loads(src.read_text(encoding="utf-8"))["strings"]
            dest = json.loads((repo / move["to"]).read_text(encoding="utf-8"))["strings"]
            for key, value in source.items():
                if key in dest and set(value.get("localizations", {})) != set(dest[key].get("localizations", {})):
                    problems.append(f"{move['to']}: {key!r} lost locales")
    return problems


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--group", required=True, help="the app-graph group (an App folder or file family name)")
    parser.add_argument("--destination", help="destination target (overrides the graph)")
    parser.add_argument("--layer", help="the destination's layer, when architecture-layers.json lacks it")
    parser.add_argument("--file", action="append", help="a group path under Sources/CmuxNextApp (repeatable)")
    parser.add_argument("--test", action="append", help="a test path under Tests/CmuxNextAppTests (repeatable)")
    parser.add_argument("--into", help="folder under the destination (default: the group's folder name)")
    parser.add_argument("--repo", type=Path, help="repository root (default: this checkout)")
    parser.add_argument("--dry-run", action="store_true", help="print the plan, change nothing")
    parser.add_argument("--json", action="store_true", help="print the plan and report as JSON")
    args = parser.parse_args(argv)
    repo = args.repo or Path(git(HERE, "rev-parse", "--show-toplevel").strip())
    try:
        plan = plan_move(repo, resolve_group(repo, args))
        if args.dry_run:
            print(json.dumps(plan.as_dict(), indent=2, sort_keys=True))
            return 0
        report = apply_plan(repo, plan)
        problems = verify(repo, plan, report, plan.followed)
    except MoveError as error:
        print(f"move-app-files: {error}", file=sys.stderr)
        return 2
    if args.json:
        print(json.dumps({**plan.as_dict(), "follow": report.as_dict(), "problems": problems}, indent=2, sort_keys=True))
    else:
        print(f"move-app-files: {len(plan.renames)} file(s) moved to {plan.group.destination}")
        for move in plan.table_moves:
            print(f"move-app-files: table {move}")
        follow.print_report(report)
        for line in dict.fromkeys(plan.manifest):
            print(f"move-app-files: manifest request (task 019, not edited here): {line}")
        for line in plan.perf_hot + plan.notes:
            print(f"move-app-files: {line}")
        for line in problems:
            print(f"move-app-files: PROBLEM {line}")
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())
