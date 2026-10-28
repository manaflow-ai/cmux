#!/usr/bin/env python3
"""The Package.swift settings lander (p10-stability-198, plans/cmux-next/chrome-parity/p10-stability.md C.5).

Implementers never edit the closure's Package.swift files for a p10 setting. They add a row to
scripts/cmux-next/stability-settings.json:

  {"task": "p10-stability-038", "package": "Packages/Shared/CmuxMessagesLab", "target": "MessagesLabHome",
   "setting": ".enableUpcomingFeature(\\"StrictConcurrency\\")", "reason": "complete checking as warnings"}

  package  a closure package directory (repository-relative), or "*" for every closure package
  target   a target of that package of the row's kind, or "*" for every such target in it
  setting  one setting expression of an allowed form for the row's kind (SETTING_FORMS)
  kind     optional: "swift" (the default, a SwiftSetting on Swift targets) or "c" (a CSetting on C and
           Objective-C targets)

Where a row lands:
  - A Swift setting for every Swift target of a package ("*" target) goes into the manifest's
    `let stabilitySwiftSettings: [SwiftSetting] = [...]` (p10-stability-037) when the manifest declares it. The
    lander owns that literal: it is `[]` with no rows. Swift targets that do not carry the constant (directly or
    through a top-level constant built from it) get the setting from the generated block instead.
  - Every other Swift or C setting goes into one generated block at the end of the manifest, between the
    `BEGIN apply-stability-settings.py` and `END apply-stability-settings.py` lines. The block names the targets
    per settings group and appends the group to `target.swiftSettings` or `target.cSettings` after
    `let package = Package(...)`. A manifest with nothing to append has no block.
  - A `.swiftLanguageMode(.vN)` row replaces the mode: the lander rewrites the one literal `.swiftLanguageMode(...)`
    in the target's declaration (SwiftPM has no way to take a setting back out of a list). A target without exactly
    one such literal is refused. Removing the row later leaves the new mode: a language flip is one way.
When a setting needs a newer PackageDescription than the manifest's `swift-tools-version`, the lander raises the
header (never lowers it). Everything is a literal, never a file read: SwiftPM keys its manifest cache on the text.

The closure is every `.package(path:)` reached from Packages/macOS/CmuxNext under Packages/. A package vendored
verbatim (it has a SOURCE file, such as CmuxAgentCursor) is refused for a row that names it; a "*" row skips it
and every mode prints a note naming its targets, so a task that needs every closure target (079, 211) knows the
change has to go upstream (cmux-cua) first.

Usage: scripts/cmux-next/apply-stability-settings.py [--repo DIR] [--check [--rev REV] | --write | --commit
                                                      | --verify-commits RANGE [--rev REV] | --list-closure]
  (no flag), --check     exit 1 when a manifest differs from the rows, or a closure manifest sets a lander-only
                         setting (strictMemorySafety, treatWarning, treatAllWarnings) by hand. --rev judges a commit
                         instead of the working tree.
  --write                rewrite the manifests from the rows; a second run changes nothing
  --commit               refuse unless the rows file and the manifests it changes are committed, then --write and one
                         lander commit of exactly those manifests. It prints the fleet compile-check; running it is
                         the operator's step (push the commit, then cmux-ci build and cmux-ci wait).
  --verify-commits RANGE exit 1 when a non-merge commit in RANGE (git rev-list arguments, space separated) is
                         - a lander commit (subject starts with LANDER_SUBJECT) that changes anything but closure
                           manifests, or a manifest to anything but the rewrite of its parent from the rows at
                           that commit, or
                         - any other commit that changes a closure manifest's block, its stabilitySwiftSettings
                           literal, its swift-tools-version, a lander-only setting, or a line holding a setting
                           the rows give that package (or any language mode, when a row sets one there).
                         The closure is read at --rev (default: the working tree). prepush-gate.py runs this on the
                         push's own commits (local only). Staleness is not judged there: rows wait for the next
                         lander run.
  --list-closure         print the closure package directories
Stdlib only.
"""

from __future__ import annotations

import argparse
import bisect
import json
import os
import posixpath
import re
import subprocess
import sys
from dataclasses import dataclass, field
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SETTINGS_FILE = "scripts/cmux-next/stability-settings.json"
APP_PACKAGE = "Packages/macOS/CmuxNext"
MANIFEST = "Package.swift"
BEGIN = "// BEGIN apply-stability-settings.py: generated from scripts/cmux-next/stability-settings.json; do not edit.\n"
END = "// END apply-stability-settings.py\n"
LANDER_SUBJECT = "stability-settings lander:"
VENDORED_MARKER = "SOURCE"
CONSTANT = "stabilitySwiftSettings"
CONSTANT_DECL = re.compile(rf"^let {CONSTANT}: \[SwiftSetting\] = \[[^\]]*\]", re.M)

SWIFT, C = "swift", "c"
SWIFT_SUFFIXES = (".swift",)
C_SUFFIXES = (".c", ".m", ".mm", ".cc", ".cpp", ".cxx")
# The only flags a "c" row may pass through `.unsafeFlags`: Chrome's hardening and warning flags
# (chromium build/config/compiler/BUILD.gn and build/config/c++/BUILD.gn).
HARDENING_FLAGS = frozenset({
    "-Wall", "-Wextra", "-Wunsafe-buffer-usage", "-Werror=unsafe-buffer-usage", "-fstack-protector-strong",
    "-ftrivial-auto-var-init=pattern", "-fno-delete-null-pointer-checks",
})


@dataclass(frozen=True)
class Form:
    pattern: re.Pattern[str]
    tools: tuple[int, int]  # the PackageDescription version the setting needs
    kind: str


_NAME = r'"[A-Za-z][A-Za-z0-9_-]*"'
MODE = re.compile(r"\.swiftLanguageMode\(\.v[56]\)")
MODE_LITERAL = re.compile(r"\.swiftLanguageMode\(\.v\w+\)")
UNSAFE_FLAGS = re.compile(r'\.unsafeFlags\(\[("[^"]+"(?:, "[^"]+")*)\]\)')
SETTING_FORMS: tuple[Form, ...] = (
    Form(re.compile(r"\.strictMemorySafety\(\)"), (6, 2), SWIFT),
    Form(re.compile(rf"\.treatWarning\({_NAME}, as: \.(?:error|warning)\)"), (6, 2), SWIFT),
    Form(re.compile(r"\.treatAllWarnings\(as: \.(?:error|warning)\)"), (6, 2), SWIFT),
    Form(re.compile(rf"\.enableUpcomingFeature\({_NAME}\)"), (5, 8), SWIFT),
    Form(re.compile(rf"\.enableExperimentalFeature\({_NAME}\)"), (5, 8), SWIFT),
    Form(MODE, (6, 0), SWIFT),
    Form(re.compile(rf"\.treatWarning\({_NAME}, as: \.(?:error|warning)\)"), (6, 2), C),
    Form(re.compile(r"\.treatAllWarnings\(as: \.(?:error|warning)\)"), (6, 2), C),
    Form(re.compile(rf"\.enableWarning\({_NAME}\)"), (6, 2), C),
    Form(re.compile(r'\.define\("[A-Za-z_][A-Za-z0-9_]*"(?:, to: "[A-Za-z0-9_]*")?\)'), (5, 0), C),
    Form(UNSAFE_FLAGS, (5, 0), C),
)
# Settings that may appear in a closure manifest only where the lander writes them.
LANDER_ONLY = re.compile(r"\.(?:strictMemorySafety|treatWarning|treatAllWarnings)\(")
ROW_KEYS = {"task", "package", "target", "setting", "reason"}
OPTIONAL_KEYS = {"kind"}
TASK_ID = re.compile(r"^p\d{2}-[a-z0-9]+(?:-[a-z0-9]+)*-\d{3}$")
TOOLS_LINE = re.compile(r"^// swift-tools-version:\s*(\d+)\.(\d+)(?:\.\d+)?[^\n]*\n")
TARGET_DECL = re.compile(r'\.(target|testTarget|executableTarget|macro)\(\s*name:\s*"([^"]+)"')
PATH_ARG = re.compile(r'\bpath:\s*"([^"]*)"')
PACKAGE_PATH = re.compile(r'\.package\(\s*(?:name:\s*"[^"]*",\s*)?path:\s*"([^"]+)"')
PACKAGE_DECL = re.compile(r"^let package = Package\(", re.M)
TOP_LET = re.compile(r"^let ([A-Za-z_]\w*)\b", re.M)
LINE_COMMENT = re.compile(r"//[^\n]*")


class LanderError(Exception):
    """A row, manifest or repository state the lander refuses, with the reason."""


@dataclass(frozen=True)
class Row:
    task: str
    package: str
    target: str
    setting: str
    reason: str
    kind: str = SWIFT

    def applies_to(self, package: str) -> bool:
        return self.package in ("*", package)


@dataclass
class PackagePlan:
    """What the rows give one closure package."""

    shared: list[str] = field(default_factory=list)  # the stabilitySwiftSettings literal
    swift: dict[str, list[str]] = field(default_factory=dict)  # per Swift target, in the block
    c: dict[str, list[str]] = field(default_factory=dict)  # per C target, in the block
    modes: dict[str, str] = field(default_factory=dict)  # per Swift target, its rewritten language mode

    def settings(self) -> list[str]:
        return [*self.shared, *self.modes.values(), *(s for group in (self.swift, self.c) for v in group.values() for s in v)]


@dataclass
class Plan:
    packages: dict[str, PackagePlan]
    notes: list[str]


def git(root: Path, *args: str, check_ok: bool = True) -> subprocess.CompletedProcess[str]:
    return subprocess.run(["git", "-C", str(root), *args], capture_output=True, text=True, check=check_ok)


class WorkTree:
    """The working tree's files, by repository-relative path."""

    def __init__(self, root: Path):
        self.root = root

    def read(self, path: str) -> str | None:
        try:
            return (self.root / path).read_text()
        except OSError:
            return None

    def has_file(self, path: str) -> bool:
        return (self.root / path).is_file()

    def has_source(self, directory: str, suffixes: tuple[str, ...]) -> bool:
        for _, _, files in os.walk(self.root / directory):
            if any(name.endswith(suffixes) for name in files):
                return True
        return False


class GitTree:
    """The files of one commit, by repository-relative path."""

    def __init__(self, root: Path, rev: str):
        self.root = root
        done = git(root, "rev-parse", "--verify", "--quiet", f"{rev}^{{commit}}", check_ok=False)
        if done.returncode:
            raise LanderError(f"{rev} is not a commit")
        self.rev = done.stdout.strip()
        self._files: list[str] | None = None
        self._texts: dict[str, str | None] = {}

    def files(self) -> list[str]:
        if self._files is None:
            out = git(self.root, "ls-tree", "-r", "-z", "--name-only", self.rev, "--", "Packages", SETTINGS_FILE).stdout
            self._files = sorted(path for path in out.split("\0") if path)
        return self._files

    def read(self, path: str) -> str | None:
        if path not in self._texts:
            done = git(self.root, "show", f"{self.rev}:{path}", check_ok=False)
            self._texts[path] = done.stdout if done.returncode == 0 else None
        return self._texts[path]

    def has_file(self, path: str) -> bool:
        files = self.files()
        index = bisect.bisect_left(files, path)
        return index < len(files) and files[index] == path

    def has_source(self, directory: str, suffixes: tuple[str, ...]) -> bool:
        files, prefix = self.files(), directory.rstrip("/") + "/"
        index = bisect.bisect_left(files, prefix)
        while index < len(files) and files[index].startswith(prefix):
            if files[index].endswith(suffixes):
                return True
            index += 1
        return False


Tree = WorkTree | GitTree


def form_of(setting: str, kind: str) -> Form:
    for form in SETTING_FORMS:
        if form.kind == kind and form.pattern.fullmatch(setting):
            flags = UNSAFE_FLAGS.fullmatch(setting)
            if flags:
                bad = sorted(set(re.findall(r'"([^"]+)"', flags.group(1))) - HARDENING_FLAGS)
                if bad:
                    raise LanderError(f"setting {setting!r} passes {bad}, not in HARDENING_FLAGS")
            return form
    raise LanderError(f"setting {setting!r} is not an allowed {kind} form; see SETTING_FORMS in apply-stability-settings.py")


def strip_block(text: str) -> str:
    """The manifest without its generated block (and the blank line the lander puts before it)."""
    begins, ends = text.count(BEGIN), text.count(END)
    if begins == 0 and ends == 0:
        return text
    if begins != 1 or ends != 1 or text.index(BEGIN) > text.index(END):
        raise LanderError("the manifest has a broken apply-stability-settings.py block; restore it from git")
    head, tail = text[: text.index(BEGIN)], text[text.index(END) + len(END):]
    if head.endswith("\n\n"):
        head = head[:-1]
    return head + tail


def block_of(text: str) -> str:
    """The generated block, BEGIN through END, or "" when the manifest has none."""
    strip_block(text)
    return text[text.index(BEGIN): text.index(END) + len(END)] if BEGIN in text else ""


def call_text(text: str, open_paren: int) -> str:
    """The source of the call whose `(` is at `open_paren`, through its matching `)`."""
    depth, i = 0, open_paren
    while i < len(text):
        c = text[i]
        if c == '"':
            i += 1
            while i < len(text) and text[i] != '"':
                i += 2 if text[i] == "\\" else 1
        elif text.startswith("//", i):
            i = text.find("\n", i)
            if i < 0:
                break
        elif text.startswith("/*", i):
            i = text.find("*/", i)
            if i < 0:
                break
            i += 1
        elif c == "(":
            depth += 1
        elif c == ")":
            depth -= 1
            if depth == 0:
                return text[open_paren: i + 1]
        i += 1
    raise LanderError("unbalanced parentheses in a target declaration")


def target_decls(text: str) -> dict[str, tuple[str, int, str]]:
    """Per target name: its kind of declaration, the offset of its `(` and the call's source."""
    decls: dict[str, tuple[str, int, str]] = {}
    for match in TARGET_DECL.finditer(text):
        kind, name = match.groups()
        if name not in decls:
            start = text.index("(", match.start())
            decls[name] = (kind, start, call_text(text, start))
    return decls


def targets(tree: Tree, package: str) -> dict[str, str]:
    """The package's targets by language: SWIFT when its source directory holds Swift, C when it holds C-family
    sources (binary targets and resource-only directories are neither)."""
    text = strip_block(tree.read(f"{package}/{MANIFEST}") or "")
    kinds: dict[str, str] = {}
    for name, (declaration, _, call) in target_decls(text).items():
        path = PATH_ARG.search(call)
        source = f"{package}/" + (path.group(1) if path else ("Tests" if declaration == "testTarget" else "Sources") + "/" + name)
        if tree.has_source(source, SWIFT_SUFFIXES):
            kinds[name] = SWIFT
        elif tree.has_source(source, C_SUFFIXES):
            kinds[name] = C
    return dict(sorted(kinds.items()))


def swift_targets(tree: Tree, package: str) -> list[str]:
    return [name for name, kind in targets(tree, package).items() if kind == SWIFT]


def carriers(text: str) -> set[str]:
    """The targets that carry stabilitySwiftSettings: their declaration names it or a top-level constant built from
    it (uiSwiftSettings appends it). Empty when the manifest does not declare it."""
    body = strip_block(text)
    if not CONSTANT_DECL.search(body):
        return set()
    code = LINE_COMMENT.sub("", body)
    lets = list(TOP_LET.finditer(code))
    chunks = {match.group(1): code[match.end(): lets[i + 1].start() if i + 1 < len(lets) else len(code)]
              for i, match in enumerate(lets) if match.group(1) != "package"}
    names, grew = {CONSTANT}, True
    while grew:
        grew = False
        for name, chunk in chunks.items():
            if name not in names and any(re.search(rf"\b{known}\b", chunk) for known in names):
                names.add(name)
                grew = True
    carried = set()
    for name, (_, _, call) in target_decls(body).items():
        if any(re.search(rf"\b{known}\b", LINE_COMMENT.sub("", call)) for known in names):
            carried.add(name)
    return carried


def closure(tree: Tree) -> list[str]:
    """Every package under Packages/ that Packages/macOS/CmuxNext reaches through `.package(path:)`."""
    seen: list[str] = []
    queue = [APP_PACKAGE]
    while queue:
        package = queue.pop(0)
        if package in seen:
            continue
        text = tree.read(f"{package}/{MANIFEST}")
        if text is None:
            raise LanderError(f"{package}/{MANIFEST} is missing")
        seen.append(package)
        for path in PACKAGE_PATH.findall(text):
            relative = posixpath.normpath(posixpath.join(package, path))
            if relative.startswith("Packages/") and tree.has_file(f"{relative}/{MANIFEST}"):
                queue.append(relative)
    return [APP_PACKAGE] + sorted(seen[1:])


def load_rows(tree: Tree) -> list[Row]:
    text = tree.read(SETTINGS_FILE)
    if text is None:
        raise LanderError(f"{SETTINGS_FILE} is missing")
    try:
        data = json.loads(text)
    except json.JSONDecodeError as error:
        raise LanderError(f"{SETTINGS_FILE}: {error}") from error
    if not isinstance(data, dict) or not isinstance(data.get("rows"), list):
        raise LanderError(f'{SETTINGS_FILE}: expected an object with a "rows" list')
    rows: list[Row] = []
    for index, raw in enumerate(data["rows"]):
        where = f"{SETTINGS_FILE} rows[{index}]"
        if (not isinstance(raw, dict) or not ROW_KEYS <= set(raw) <= ROW_KEYS | OPTIONAL_KEYS
                or not all(isinstance(v, str) and v for v in raw.values())):
            raise LanderError(f"{where}: needs exactly the non-empty strings {sorted(ROW_KEYS)} (and optionally kind)")
        if raw.get("kind", SWIFT) not in (SWIFT, C):
            raise LanderError(f"{where}: kind is {SWIFT!r} or {C!r}")
        if not TASK_ID.match(raw["task"]):
            raise LanderError(f"{where}: task {raw['task']!r} is not a task id like p10-stability-038")
        if raw["package"] == "*" and raw["target"] != "*":
            raise LanderError(f'{where}: a "*" package row gives every target the setting; its target is "*"')
        row = Row(**raw)
        form_of(row.setting, row.kind)
        rows.append(row)
    return rows


def _add(settings: list[str], setting: str) -> None:
    if setting not in settings:
        settings.append(setting)


def plan(tree: Tree, rows: list[Row]) -> Plan:
    """Per closure package, what each row adds (row order, duplicates once), and notes on vendored packages skipped."""
    packages = closure(tree)
    result = {package: PackagePlan() for package in packages}
    notes: list[str] = []
    info: dict[str, tuple[dict[str, str], set[str], bool]] = {}
    for row in rows:
        if row.package != "*" and row.package not in packages:
            raise LanderError(f"{row.task}: {row.package} is not a CmuxNext closure package")
        for package in packages if row.package == "*" else [row.package]:
            if package not in info:
                text = tree.read(f"{package}/{MANIFEST}") or ""
                info[package] = (targets(tree, package), carriers(text), bool(CONSTANT_DECL.search(strip_block(text))))
            kinds, carrying, has_constant = info[package]
            eligible = [name for name, kind in kinds.items() if kind == row.kind]
            if tree.has_file(f"{package}/{VENDORED_MARKER}"):
                if row.package != "*":
                    raise LanderError(f"{row.task}: {package} is vendored verbatim; change its upstream first")
                if eligible and row.target == "*":
                    notes.append(f"{row.task}: {package} is vendored verbatim, so its {row.kind} targets "
                                 f"{', '.join(eligible)} do not get {row.setting}; change its upstream first")
                continue
            if row.target != "*" and row.target not in eligible:
                raise LanderError(f"{row.task}: {row.target} is not a {'Swift' if row.kind == SWIFT else 'C'} target of {package}")
            chosen = eligible if row.target == "*" else [row.target]
            this = result[package]
            if MODE.fullmatch(row.setting):
                for target in chosen:
                    if this.modes.get(target, row.setting) != row.setting:
                        raise LanderError(f"{package} {target}: rows ask for both {this.modes[target]} and {row.setting}")
                    this.modes[target] = row.setting
                continue
            if row.kind == C:
                for target in chosen:
                    _add(this.c.setdefault(target, []), row.setting)
                continue
            if row.target == "*" and has_constant:
                _add(this.shared, row.setting)
                chosen = [target for target in chosen if target not in carrying]
            for target in chosen:
                _add(this.swift.setdefault(target, []), row.setting)
    for package, this in result.items():
        carrying = info.get(package, ({}, set(), False))[1]
        for target in list(this.swift):
            if target in carrying:
                this.swift[target] = [s for s in this.swift[target] if s not in this.shared]
            if not this.swift[target]:
                del this.swift[target]
        effective = {t: (this.shared if t in carrying else []) + this.swift.get(t, [])
                     for t in carrying | set(this.swift)}
        for scope in (effective, this.c):
            for target, settings in scope.items():
                levels: dict[str, str] = {}
                for setting in settings:
                    key = re.sub(r"as: \.\w+\)$", "", setting)
                    if key in levels and levels[key] != setting:
                        raise LanderError(f"{package} {target}: rows ask for both {levels[key]} and {setting}")
                    levels[key] = setting
    return Plan(result, notes)


def _groups(name: str, kind: str, per_target: dict[str, list[str]], field_name: str) -> list[str]:
    groups: dict[tuple[str, ...], list[str]] = {}
    for target in sorted(per_target):
        groups.setdefault(tuple(per_target[target]), []).append(target)
    if not groups:
        return []
    lines = [f"let {name}: [(targets: [String], settings: [{kind}])] = ["]
    for settings, names in sorted(groups.items(), key=lambda item: item[1][0]):
        lines += ["    (", "        targets: ["]
        lines += [f'            "{target}",' for target in names]
        lines += ["        ],", "        settings: ["]
        lines += [f"            {setting}," for setting in settings]
        lines += ["        ]", "    ),"]
    lines += [
        "]",
        f"for group in {name} {{",
        "    for target in package.targets where group.targets.contains(target.name) {",
        f"        target.{field_name} = (target.{field_name} ?? []) + group.settings",
        "    }",
        "}",
    ]
    return lines


def render_block(this: PackagePlan) -> str:
    body = (_groups("stabilitySettingGroups", "SwiftSetting", this.swift, "swiftSettings")
            + _groups("stabilityCSettingGroups", "CSetting", this.c, "cSettings"))
    if not body:
        return ""
    lines = [
        BEGIN.rstrip("\n"),
        "// p10 stability settings per target (plans/cmux-next/chrome-parity/p10-stability.md C.5): add a row to",
        "// stability-settings.json and run the lander instead of editing this block or a target's settings.",
        *body,
        END.rstrip("\n"),
    ]
    return "\n".join(lines) + "\n"


def render_constant(settings: list[str]) -> str:
    if not settings:
        return f"let {CONSTANT}: [SwiftSetting] = []"
    return f"let {CONSTANT}: [SwiftSetting] = [\n" + "".join(f"    {s},\n" for s in settings) + "]"


def rewrite(text: str, this: PackagePlan) -> str:
    """The manifest with the plan applied: language-mode literals, the stabilitySwiftSettings literal, the block, and
    the tools version raised when a setting needs it."""
    body = strip_block(text)
    decls = target_decls(body)
    edits = []
    for target, mode in this.modes.items():
        _, start, call = decls[target]
        found = list(MODE_LITERAL.finditer(call))
        if len(found) != 1:
            raise LanderError(f"{target}: a language-mode row needs exactly one literal `.swiftLanguageMode(...)` in the "
                              f"target's declaration, and it has {len(found)}")
        edits.append((start + found[0].start(), start + found[0].end(), mode))
    for begin, end, mode in sorted(edits, reverse=True):
        body = body[:begin] + mode + body[end:]
    constant = CONSTANT_DECL.search(body)
    if constant:
        body = body[: constant.start()] + render_constant(this.shared) + body[constant.end():]
    elif this.shared:
        raise LanderError(f"the manifest does not declare `let {CONSTANT}: [SwiftSetting] = [...]`")
    block = render_block(this)
    if block:
        if not PACKAGE_DECL.search(body):
            raise LanderError("the manifest has no top-level `let package = Package(`")
        body = (body if body.endswith("\n") else body + "\n") + "\n" + block
    kind_of = {s: SWIFT for s in [*this.shared, *this.modes.values()] + [s for v in this.swift.values() for s in v]}
    kind_of.update({s: C for v in this.c.values() for s in v})
    needed = max((form_of(s, kind).tools for s, kind in kind_of.items()), default=(0, 0))
    tools = TOOLS_LINE.match(body)
    if tools is None:
        raise LanderError("the manifest does not start with a `// swift-tools-version:` line")
    if (int(tools.group(1)), int(tools.group(2))) < needed:
        body = f"// swift-tools-version: {needed[0]}.{needed[1]}\n" + body[tools.end():]
    return body


def generated_free(text: str) -> str:
    """The manifest without the text the lander writes outside its language-mode edits."""
    return CONSTANT_DECL.sub("", strip_block(text))


def hand_set(text: str) -> list[str]:
    """Lander-only settings written outside the block and the stabilitySwiftSettings literal."""
    return [line.strip() for line in generated_free(text).splitlines()
            if LANDER_ONLY.search(line) and not line.lstrip().startswith("//")]


def pending(tree: Tree, the_plan: Plan) -> dict[str, str]:
    """Each closure manifest whose text the rows would change, with its new text."""
    changes = {}
    for package, this in the_plan.packages.items():
        path = f"{package}/{MANIFEST}"
        text = tree.read(path) or ""
        try:
            new = rewrite(text, this)
        except LanderError as error:
            raise LanderError(f"{path}: {error}") from error
        if new != text:
            changes[path] = new
    return changes


def check(tree: Tree) -> tuple[list[str], list[str]]:
    """(problems, notes) for the tree."""
    the_plan = plan(tree, load_rows(tree))
    problems = [f"{path}: stale; run scripts/cmux-next/apply-stability-settings.py --commit"
                for path in pending(tree, the_plan)]
    for package in closure(tree):
        path = f"{package}/{MANIFEST}"
        for line in hand_set(tree.read(path) or ""):
            problems.append(f"{path}: `{line}` is a lander-only setting; add a row to {SETTINGS_FILE} instead")
    return problems, the_plan.notes


def write(root: Path) -> tuple[list[str], list[str]]:
    tree = WorkTree(root)
    the_plan = plan(tree, load_rows(tree))
    changes = pending(tree, the_plan)
    for path, text in changes.items():
        (root / path).write_text(text)
    return sorted(changes), the_plan.notes


def _uncommitted(root: Path, path: str) -> bool:
    return bool(git(root, "status", "--porcelain", "--", path).stdout.strip())


def commit(root: Path) -> tuple[str | None, list[str]]:
    """Land the rows in one commit; (its sha or None when nothing changes, notes)."""
    if _uncommitted(root, SETTINGS_FILE):
        raise LanderError(f"{SETTINGS_FILE} has uncommitted changes; commit the rows first, so the lander commit's "
                          "manifests match the rows in its own tree")
    tree = WorkTree(root)
    rows = load_rows(tree)
    the_plan = plan(tree, rows)
    changes = pending(tree, the_plan)
    dirty = [path for path in sorted(changes) if _uncommitted(root, path)]
    if dirty:
        raise LanderError(f"uncommitted edits in {', '.join(dirty)}; the lander commits only its own rewrite")
    if not changes:
        return None, the_plan.notes
    originals = {path: tree.read(path) or "" for path in changes}
    paths = sorted(changes)
    tasks = sorted({row.task for row in rows})
    subject = f"{LANDER_SUBJECT} apply {SETTINGS_FILE} to {len(paths)} manifest(s)"
    body = ("Rows from: " + ", ".join(tasks) + "\n\nManifests:\n" + "".join(f"- {p}\n" for p in paths)
            + "\nTest phase: fleet compile-check of this commit after it is pushed (cmux-ci build cmux --ref <this sha>, "
              "then cmux-ci wait); the operator runs it, the lander does not.")
    try:
        for path, text in changes.items():
            (root / path).write_text(text)
        git(root, "add", "--", *paths)
        git(root, "commit", "-q", "-m", subject, "-m", body, "--", *paths)
    except (OSError, subprocess.CalledProcessError) as error:
        for path, text in originals.items():
            (root / path).write_text(text)
        git(root, "reset", "-q", "--", *paths, check_ok=False)
        detail = error.stderr.strip() if isinstance(error, subprocess.CalledProcessError) and error.stderr else str(error)
        raise LanderError(f"the lander commit failed ({detail}); the manifests are restored") from error
    return git(root, "rev-parse", "HEAD").stdout.strip(), the_plan.notes


def fingerprint(text: str, package: str, rows: list[Row]) -> tuple:
    """What a non-lander commit must leave alone in a closure manifest: the block, the stabilitySwiftSettings
    literal (declaring it empty is p10-stability-037's interface, not a setting), the tools version, the lander-only
    settings and the lines holding a setting the rows give the package (any language mode, when a row sets one
    there)."""
    try:
        body = strip_block(text)
    except LanderError:
        return ("broken", text)
    tools = TOOLS_LINE.match(text)
    constant = CONSTANT_DECL.search(body)
    applying = [row for row in rows if row.applies_to(package)]
    watched = {row.setting for row in applying if not MODE.fullmatch(row.setting)}
    if any(MODE.fullmatch(row.setting) for row in applying):
        watched.add(".swiftLanguageMode(")
    lines = sorted(line.strip() for line in generated_free(text).splitlines()
                   if not line.lstrip().startswith("//")
                   and (LANDER_ONLY.search(line) or any(setting in line for setting in watched)))
    shared = constant.group(0) if constant and constant.group(0) != render_constant([]) else ""
    return (block_of(text), tools.groups() if tools else None, shared, lines)


def verify_commits(root: Path, revision_range: str, tip: Tree) -> list[str]:
    packages = {f"{package}/{MANIFEST}": package for package in closure(tip)}
    tip_rows = load_rows(tip) if tip.read(SETTINGS_FILE) is not None else []
    shas = git(root, "rev-list", "--no-merges", *revision_range.split(), "--", *packages).stdout.split()
    problems = []
    for sha in shas:
        subject = git(root, "log", "-1", "--format=%s", sha).stdout.strip()
        changed = git(root, "diff-tree", "--no-commit-id", "--name-only", "-r", "--root", sha).stdout.split()
        manifests = [path for path in changed if path in packages]
        tree = GitTree(root, sha)
        if subject.startswith(LANDER_SUBJECT):
            others = [path for path in changed if path not in packages]
            if others:
                problems.append(f"{sha[:12]}: a lander commit changes {', '.join(others)}, not only closure manifests")
            try:
                the_plan = plan(tree, load_rows(tree))
            except LanderError as error:
                problems.append(f"{sha[:12]}: a lander commit whose rows do not plan ({error})")
                continue
            for path in manifests:
                parent = git(root, "show", f"{sha}^:{path}", check_ok=False).stdout
                try:
                    expected = rewrite(parent, the_plan.packages[packages[path]]) if packages[path] in the_plan.packages else None
                except LanderError:
                    expected = None
                if expected != tree.read(path):
                    problems.append(f"{sha[:12]} {path}: a lander commit whose manifest is not the rewrite of its parent "
                                    "from the rows at that commit")
            continue
        try:
            rows = load_rows(tree) if tree.read(SETTINGS_FILE) is not None else []
        except LanderError:
            rows = []
        rows = [*rows, *tip_rows]
        for path in manifests:
            shown = git(root, "show", f"{sha}^:{path}", check_ok=False)
            old = fingerprint(shown.stdout, packages[path], rows)
            new = fingerprint(tree.read(path) or "", packages[path], rows)
            if shown.returncode:  # a new package picks its own tools version
                old, new = old[:1] + old[2:], new[:1] + new[2:]
            if old != new:
                problems.append(f"{sha[:12]} {path}: changes p10 settings outside a lander commit ({subject})")
    return problems


def fleet_steps(sha: str) -> str:
    return (f"landed {sha}. Compile-check it on the fleet (the operator's step; the lander does not run it):\n"
            "  git push origin HEAD\n"
            f"  cmux-ci build cmux --ref {sha} --tag stability-settings-{sha[:9]} --workspace <PR or branch URL> "
            f"--receipt artifacts/fleet/{sha}-submit.json\n"
            "  cmux-ci wait <the job id the build prints>")


def main(argv: list[str] | None = None, root: Path = ROOT) -> int:
    parser = argparse.ArgumentParser(description=(__doc__ or "").splitlines()[0])
    parser.add_argument("--repo", type=Path, help="the repository (default: this script's)")
    parser.add_argument("--rev", help="judge this commit instead of the working tree (--check, --verify-commits)")
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--check", action="store_true")
    mode.add_argument("--write", action="store_true")
    mode.add_argument("--commit", action="store_true")
    mode.add_argument("--verify-commits", metavar="RANGE")
    mode.add_argument("--list-closure", action="store_true")
    args = parser.parse_args(argv)
    root = args.repo.resolve() if args.repo else root
    notes: list[str] = []
    try:
        if args.rev and (args.write or args.commit):
            raise LanderError("--rev judges a commit; --write and --commit change the working tree")
        tree: Tree = GitTree(root, args.rev) if args.rev else WorkTree(root)
        if args.list_closure:
            print("\n".join(closure(tree)))
            return 0
        if args.write:
            paths, notes = write(root)
            for path in paths:
                print(f"wrote {path}")
            problems: list[str] = []
        elif args.commit:
            sha, notes = commit(root)
            print("nothing to land: every manifest matches the rows" if sha is None else fleet_steps(sha))
            problems = []
        elif args.verify_commits:
            problems = verify_commits(root, args.verify_commits, tree)
        else:
            problems, notes = check(tree)
    except LanderError as error:
        print(f"apply-stability-settings: {error}", file=sys.stderr)
        return 2
    for note in notes:
        print(f"apply-stability-settings: note: {note}", file=sys.stderr)
    for problem in problems:
        print(problem, file=sys.stderr)
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())
