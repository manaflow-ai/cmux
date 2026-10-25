#!/usr/bin/env python3
"""Move one CmuxNextApp group into its destination target as a pure move (p11-codebase task 000b).

One group (a folder of Sources/CmuxNextApp, or a top-level family `Name.swift` + `Name+*.swift`) goes to
its destination target in one step, in the worktree, uncommitted:

  1. git mv its source files to Sources/<Destination>/<into>/ and its tests to Tests/<Destination>Tests/
     (a moved test's `@testable import CmuxNextApp` names the destination: the subject's module).
  2. String tables: an App table only the group uses moves whole; a shared one is split by key, each key
     the group uses going to the destination's table of the same name with every locale (`bundle:
     .module` rebinds to the destination's bundle on a move, and a missing key falls back silently).
     A key both sides use is copied; a key only the group uses leaves the App table.
  3. follow-renames.py rewrites every mention of the moved paths: the path-keyed baselines (its REGISTRY)
     and every other tracked text file, so `git grep <old path>` comes back empty.
  4. The localization debt baseline is recounted for the tables it touched; architecture-layers.json gets
     the destination when it lacks it (with the group's layer).

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


def test_files(group: Group, sources: list[str], tracked: list[str]) -> list[str]:
    """Explicit tests, else the App tests in a folder named for the group, and each `<Name>...Tests.swift` whose
    longest prefix among the App's file stems (`Stem` of `Stem+Part.swift`) and the group's name is a moved one:
    `TabSearchFactsTests` goes with TabSearch/, `TabStripTests` stays with an unmoved `TabStrip.swift`."""
    if group.tests is not None:
        missing = [t for t in group.tests if t not in tracked]
        if missing:
            raise MoveError(f"tests not tracked: {', '.join(missing)}")
        return sorted(group.tests)
    moved = {group.name} | {stem(f) for f in sources if f.endswith(".swift")}
    every = moved | {stem(f) for f in tracked if f.startswith(APP_SOURCES) and f.endswith(".swift")}
    folder = APP_TESTS + group.name + "/"
    out = []
    for f in tracked:
        if not f.startswith(APP_TESTS) or not f.endswith(".swift"):
            continue
        name = Path(f).name
        owner = max((s for s in every if name.startswith(s)), key=len, default=None) if name.endswith("Tests.swift") else None
        if f.startswith(folder) or owner in moved:
            out.append(f)
    return sorted(out)


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


def separator(text: str) -> tuple[str, str]:
    return (",", " : ") if re.search(r'"sourceLanguage"\s:\s', text) else (",", ": ")


def dump_table(data: dict, style_of: str) -> str:
    return json.dumps(data, indent=2, ensure_ascii=False, separators=separator(style_of)) + "\n"


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


def add_entries(dest_text: str | None, entries: dict, style_of: str, version: str | None) -> str:
    if dest_text is None:
        data = {"sourceLanguage": "en", "strings": entries}
        if version:
            data["version"] = version
        return dump_table(data, style_of)
    data = json.loads(dest_text)
    strings = data["strings"]
    for key, value in entries.items():
        if key in strings and strings[key] != value:
            raise MoveError(f"key {key!r} is already in the destination table with other text")
        strings[key] = value
    if list(json.loads(dest_text)["strings"]) == sorted(json.loads(dest_text)["strings"]):
        data["strings"] = dict(sorted(strings.items()))
    return dump_table(data, dest_text)


# ------------------------------------------------------------------------------------------- the plan


@dataclass
class Plan:
    group: Group
    renames: dict[str, str] = field(default_factory=dict)  # old -> new (sources, tests, whole tables)
    tests: list[str] = field(default_factory=list)
    table_moves: list[dict] = field(default_factory=list)
    table_writes: dict[str, str] = field(default_factory=dict)  # path -> new text
    table_removes: list[str] = field(default_factory=list)  # App tables merged whole into an existing one
    moved_keys: dict[str, set[str]] = field(default_factory=dict)  # destination table -> keys it must hold
    folders: dict[str, str] = field(default_factory=dict)  # App folders that moved whole
    followed: object = None  # the follow-renames Renames the move applied
    manifest: list[str] = field(default_factory=list)
    notes: list[str] = field(default_factory=list)
    perf_hot: list[str] = field(default_factory=list)

    def as_dict(self) -> dict:
        return {"group": self.group.name, "destination": self.group.destination, "renames": self.renames,
                "tables": self.table_moves, "manifest_requests": self.manifest, "notes": self.notes,
                "perf_hot": self.perf_hot}


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


def plan_tables(repo: Path, plan: Plan, moved_sources: list[str], tracked: list[str], body: str | None) -> None:
    app_swift = [f for f in tracked if f.startswith(APP_SOURCES) and f.endswith(".swift")]
    moved = set(moved_sources)
    moved_text = "\n".join((repo / f).read_text(encoding="utf-8", errors="replace") for f in moved_sources if f.endswith(".swift"))
    rest_text = "\n".join((repo / f).read_text(encoding="utf-8", errors="replace") for f in app_swift if f not in moved)
    moved_lits, rest_lits = literals(moved_text), literals(rest_text)
    moved_named, rest_named = set(TABLE_ARG.findall(moved_text)), set(TABLE_ARG.findall(rest_text))
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
        dest = destination_table_path(repo, plan.group.destination, table.name, body, plan)
        dest_text = (repo / dest).read_text(encoding="utf-8") if (repo / dest).is_file() else None
        unreferenced = index.keys - mine - theirs
        # Whole when the App keeps no use of it; a table with keys nobody references moves whole only when
        # no remaining App file names it (Localizable is everyone's default table, so it is split).
        whole = not theirs and (not unreferenced or (table.name != "Localizable" and table.name not in rest_named))
        if whole and dest_text is None:
            plan.renames[table.path] = dest
            plan.table_moves.append({"table": table.path, "to": dest, "mode": "move", "keys": len(index.keys)})
            plan.moved_keys[dest] = set(index.keys)
            continue
        if whole:
            plan.table_writes[dest] = add_entries(dest_text, table.strings, table.text, table.data.get("version"))
            plan.table_removes.append(table.path)
            plan.table_moves.append({"table": table.path, "to": dest, "mode": "merge", "keys": len(index.keys)})
            plan.moved_keys[dest] = set(index.keys)
            continue
        only_mine, shared = mine - theirs, mine & theirs
        entries = {k: v for k, v in table.strings.items() if k in mine}
        plan.table_writes[dest] = add_entries(dest_text, entries, table.text, table.data.get("version"))
        plan.table_writes[table.path] = remove_keys(table.text, only_mine)
        plan.moved_keys[dest] = set(mine)
        plan.table_moves.append({"table": table.path, "to": dest, "mode": "split", "moved": len(only_mine),
                                 "copied": len(shared), "kept": len(index.keys - only_mine)})
        if unreferenced:
            plan.notes.append(f"{table.path}: {len(unreferenced)} key(s) neither side references stay in the App table")
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
    plan.tests = test_files(group, sources, tracked)
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


def add_layer(repo: Path, dest: str, layer: str | None, plan: Plan) -> None:
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
    start = next(i for i, ln in enumerate(lines) if ln.startswith('  "targets": {'))
    end = next(i for i in range(start + 1, len(lines)) if lines[i].startswith("  }"))
    rows = [(i, json.loads("{" + lines[i].strip().rstrip(",") + "}")) for i in range(start + 1, end)]
    names = [next(iter(r)) for _, r in rows]
    if names == sorted(names):
        after = max([i for (i, r), n in zip(rows, names) if n < dest], default=start)
    else:
        after = max([i for i, r in rows if next(iter(r.values())).get("layer") == layer], default=end - 1)
    new = f'    "{dest}": {{"layer": "{layer}"}}'
    if after == end - 1:
        lines[after] = lines[after].rstrip("\n").rstrip(",") + ",\n"
        lines.insert(after + 1, new + "\n")
    else:
        lines.insert(after + 1, new + ",\n")
    path.write_text("".join(lines), encoding="utf-8")


def owner_rows(before: str, after: str) -> list[str]:
    old = set(before.splitlines())
    rows = []
    for line in after.splitlines():
        if line not in old and line.startswith("|"):
            cells = [c.strip() for c in line.strip("|").split("|")]
            rows.append(f"{cells[0]} (owner: {cells[2] if len(cells) > 2 else '?'})")
    return rows


def apply_plan(repo: Path, plan: Plan) -> follow.Report:
    owners_before = (repo / OWNERS).read_text(encoding="utf-8") if (repo / OWNERS).is_file() else ""
    before = follow.tracked(repo, None)
    for old, new in plan.renames.items():
        (repo / new).parent.mkdir(parents=True, exist_ok=True)
        git(repo, "mv", old, new)
    for path, text in plan.table_writes.items():
        (repo / path).parent.mkdir(parents=True, exist_ok=True)
        (repo / path).write_text(text, encoding="utf-8")
        git(repo, "add", path)
    for path in plan.table_removes:
        git(repo, "rm", "-q", path)
    retarget_test_imports(repo, [plan.renames[t] for t in plan.tests], plan.group.destination)
    renames = follow.Renames(dict(plan.renames), before)
    plan.folders = renames.folders
    report = follow.apply(repo, renames)
    plan.followed = renames
    touched = {m["table"] for m in plan.table_moves} | {m["to"] for m in plan.table_moves}
    recount_debt(repo, touched)
    add_layer(repo, plan.group.destination, plan.group.layer, plan)
    if owners_before:
        plan.notes += [f"owned area changed, add the owner trailer: {row}"
                       for row in owner_rows(owners_before, (repo / OWNERS).read_text(encoding="utf-8"))]
    # Stage every edit, so the move is one `git commit` (the generated files the report names stay out).
    edited = set(report.edited) | {DEBT_BASELINE, LAYERS} | {plan.renames[t] for t in plan.tests}
    git(repo, "add", "--", *sorted(p for p in edited if (repo / p).is_file()))
    return report


def verify(repo: Path, plan: Plan, report: follow.Report, renames: follow.Renames) -> list[str]:
    """What the acceptance asks of a move: no old path left, every moved key with every locale."""
    problems = []
    problems += [f"old path still named: {line}" for line in follow.leftovers(repo, renames, report.generated)]
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
