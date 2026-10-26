#!/usr/bin/env python3
"""The Package.swift settings lander (p10-stability-198, plans/cmux-next/chrome-parity/p10-stability.md C.5).

Implementers never edit the closure's Package.swift files for a p10 setting. They add a row to
scripts/cmux-next/stability-settings.json:

  {"task": "p10-stability-038", "package": "Packages/Shared/CmuxMessagesLab", "target": "MessagesLabHome",
   "setting": ".enableUpcomingFeature(\\"StrictConcurrency\\")", "reason": "complete checking as warnings"}

  package  a closure package directory (repository-relative), or "*" for every closure package
  target   a Swift target of that package, or "*" for every Swift target in it
  setting  one SwiftSetting expression of an allowed form (SETTING_FORMS)

The lander renders every row into one generated block at the end of each manifest, between the
`BEGIN apply-stability-settings.py` and `END apply-stability-settings.py` lines. The block lists target
names per settings group and appends the group's settings to those targets after `let package = Package(...)`,
so no hand-written target line changes. A manifest with no rows has no block. When a setting needs a newer
PackageDescription than the manifest's `swift-tools-version`, the lander bumps the header (never lowers it).
The block is a literal, never a file read: SwiftPM keys its manifest cache on the manifest text.

The closure is every `.package(path:)` reached from Packages/macOS/CmuxNext under Packages/. A package
vendored verbatim (it has a SOURCE file, such as CmuxAgentCursor) is refused: change its upstream first.

Usage: scripts/cmux-next/apply-stability-settings.py [--check | --write | --commit | --verify-commits RANGE
                                                      | --list-closure]
  (no flag), --check     exit 1 when a manifest's block differs from the rows, or a closure manifest sets a
                         lander-only setting (strictMemorySafety, treatWarning, treatAllWarnings) by hand
  --write                rewrite the manifests from the rows; a second run changes nothing
  --commit               --write, then one lander commit of exactly the changed manifests; prints the fleet
                         compile-check to run on that commit
  --verify-commits RANGE exit 1 when a non-merge commit in RANGE changes a block or a lander-only setting and
                         is not a lander commit (subject starts with LANDER_SUBJECT)
  --list-closure         print the closure package directories
Stdlib only.
"""

from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SETTINGS_FILE = "scripts/cmux-next/stability-settings.json"
APP_PACKAGE = "Packages/macOS/CmuxNext"
MANIFEST = "Package.swift"
BEGIN = "// BEGIN apply-stability-settings.py: generated from scripts/cmux-next/stability-settings.json; do not edit.\n"
END = "// END apply-stability-settings.py\n"
LANDER_SUBJECT = "stability-settings lander:"
VENDORED_MARKER = "SOURCE"

_NAME = r'"[A-Za-z][A-Za-z0-9_]*"'
# The settings a row may add, with the PackageDescription version each needs. `lander_only` settings may appear in
# a closure manifest only inside the generated block.
SETTING_FORMS: tuple[tuple[re.Pattern[str], tuple[int, int], bool], ...] = (
    (re.compile(r"\.strictMemorySafety\(\)"), (6, 2), True),
    (re.compile(rf"\.treatWarning\({_NAME}, as: \.(?:error|warning)\)"), (6, 2), True),
    (re.compile(r"\.treatAllWarnings\(as: \.(?:error|warning)\)"), (6, 2), True),
    (re.compile(rf"\.enableUpcomingFeature\({_NAME}\)"), (5, 8), False),
    (re.compile(rf"\.enableExperimentalFeature\({_NAME}\)"), (5, 8), False),
)
LANDER_ONLY = re.compile(r"\.(?:strictMemorySafety|treatWarning|treatAllWarnings)\(")
ROW_KEYS = {"task", "package", "target", "setting", "reason"}
TASK_ID = re.compile(r"^p\d{2}-[a-z0-9]+(?:-[a-z0-9]+)*-\d{3}$")
TOOLS_LINE = re.compile(r"^// swift-tools-version:\s*(\d+)\.(\d+)(?:\.\d+)?[^\n]*\n")
TARGET_DECL = re.compile(r'\.(target|testTarget|executableTarget|macro)\(\s*name:\s*"([^"]+)"')
PATH_ARG = re.compile(r'\bpath:\s*"([^"]*)"')
PACKAGE_PATH = re.compile(r'\.package\(\s*(?:name:\s*"[^"]*",\s*)?path:\s*"([^"]+)"')
PACKAGE_DECL = re.compile(r"^let package = Package\(", re.M)


class LanderError(Exception):
    """A row, manifest or repository state the lander refuses, with the reason."""


@dataclass(frozen=True)
class Row:
    task: str
    package: str
    target: str
    setting: str
    reason: str


def setting_tools(setting: str) -> tuple[int, int]:
    for pattern, tools, _ in SETTING_FORMS:
        if pattern.fullmatch(setting):
            return tools
    raise LanderError(f"setting {setting!r} is not an allowed form; see SETTING_FORMS in apply-stability-settings.py")


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


def swift_targets(root: Path, package: str) -> list[str]:
    """The package's targets whose source directory holds Swift (C and binary targets take no Swift settings)."""
    directory = root / package
    text = strip_block((directory / MANIFEST).read_text())
    names: list[str] = []
    for match in TARGET_DECL.finditer(text):
        kind, name = match.groups()
        call = call_text(text, text.index("(", match.start()))
        path = PATH_ARG.search(call)
        source = directory / (path.group(1) if path else ("Tests" if kind == "testTarget" else "Sources") + "/" + name)
        if source.is_dir() and next(source.rglob("*.swift"), None) is not None and name not in names:
            names.append(name)
    return sorted(names)


def closure(root: Path) -> list[str]:
    """Every package under Packages/ that Packages/macOS/CmuxNext reaches through `.package(path:)`."""
    seen: list[str] = []
    queue = [APP_PACKAGE]
    while queue:
        package = queue.pop(0)
        if package in seen:
            continue
        seen.append(package)
        text = (root / package / MANIFEST).read_text()
        for path in PACKAGE_PATH.findall(text):
            resolved = (root / package / path).resolve()
            try:
                relative = resolved.relative_to(root.resolve()).as_posix()
            except ValueError:
                continue
            if relative.startswith("Packages/") and (resolved / MANIFEST).is_file():
                queue.append(relative)
    return [APP_PACKAGE] + sorted(seen[1:])


def load_rows(root: Path) -> list[Row]:
    try:
        data = json.loads((root / SETTINGS_FILE).read_text())
    except (OSError, json.JSONDecodeError) as error:
        raise LanderError(f"{SETTINGS_FILE}: {error}") from error
    if not isinstance(data, dict) or not isinstance(data.get("rows"), list):
        raise LanderError(f'{SETTINGS_FILE}: expected an object with a "rows" list')
    rows: list[Row] = []
    for index, raw in enumerate(data["rows"]):
        where = f"{SETTINGS_FILE} rows[{index}]"
        if not isinstance(raw, dict) or set(raw) != ROW_KEYS or not all(isinstance(v, str) and v for v in raw.values()):
            raise LanderError(f"{where}: needs exactly the non-empty strings {sorted(ROW_KEYS)}")
        if not TASK_ID.match(raw["task"]):
            raise LanderError(f"{where}: task {raw['task']!r} is not a task id like p10-stability-038")
        setting_tools(raw["setting"])
        rows.append(Row(**raw))
    return rows


def plan(root: Path, rows: list[Row]) -> dict[str, dict[str, list[str]]]:
    """Per closure package, per target, the settings to append in row order (duplicates once)."""
    packages = closure(root)
    result: dict[str, dict[str, list[str]]] = {package: {} for package in packages}
    targets_of: dict[str, list[str]] = {}
    for row in rows:
        if row.package != "*" and row.package not in packages:
            raise LanderError(f"{row.task}: {row.package} is not a CmuxNext closure package")
        for package in packages if row.package == "*" else [row.package]:
            if (root / package / VENDORED_MARKER).is_file():
                if row.package == "*":
                    continue
                raise LanderError(f"{row.task}: {package} is vendored verbatim; change its upstream first")
            if package not in targets_of:
                targets_of[package] = swift_targets(root, package)
            known = targets_of[package]
            if row.target != "*" and row.target not in known:
                raise LanderError(f"{row.task}: {row.target} is not a Swift target of {package}")
            for target in known if row.target == "*" else [row.target]:
                settings = result[package].setdefault(target, [])
                if row.setting not in settings:
                    settings.append(row.setting)
    for package, targets in result.items():
        for target, settings in targets.items():
            levels = {}
            for setting in settings:
                key = re.sub(r"as: \.\w+\)$", "", setting)
                if key in levels and levels[key] != setting:
                    raise LanderError(f"{package} {target}: rows ask for both {levels[key]} and {setting}")
                levels[key] = setting
    return result


def render_block(targets: dict[str, list[str]]) -> str:
    groups: dict[tuple[str, ...], list[str]] = {}
    for target in sorted(targets):
        groups.setdefault(tuple(targets[target]), []).append(target)
    if not groups:
        return ""
    lines = [
        BEGIN.rstrip("\n"),
        "// p10 stability settings per target (plans/cmux-next/chrome-parity/p10-stability.md C.5): add a row to",
        "// stability-settings.json and run the lander instead of editing this block or a target's settings.",
        "let stabilitySettingGroups: [(targets: [String], settings: [SwiftSetting])] = [",
    ]
    for settings, names in sorted(groups.items(), key=lambda item: item[1][0]):
        lines.append("    (")
        lines.append("        targets: [")
        lines += [f'            "{name}",' for name in names]
        lines.append("        ],")
        lines.append("        settings: [")
        lines += [f"            {setting}," for setting in settings]
        lines.append("        ]")
        lines.append("    ),")
    lines += [
        "]",
        "for group in stabilitySettingGroups {",
        "    for target in package.targets where group.targets.contains(target.name) {",
        "        target.swiftSettings = (target.swiftSettings ?? []) + group.settings",
        "    }",
        "}",
        END.rstrip("\n"),
    ]
    return "\n".join(lines) + "\n"


def rewrite(text: str, targets: dict[str, list[str]]) -> str:
    """The manifest with its block rendered from `targets` and its tools version raised when a setting needs it."""
    body = strip_block(text)
    block = render_block(targets)
    if block:
        if not PACKAGE_DECL.search(body):
            raise LanderError("the manifest has no top-level `let package = Package(`")
        body = (body if body.endswith("\n") else body + "\n") + "\n" + block
    needed = max((setting_tools(s) for settings in targets.values() for s in settings), default=(0, 0))
    tools = TOOLS_LINE.match(body)
    if tools is None:
        raise LanderError("the manifest does not start with a `// swift-tools-version:` line")
    if (int(tools.group(1)), int(tools.group(2))) < needed:
        body = f"// swift-tools-version: {needed[0]}.{needed[1]}\n" + body[tools.end():]
    return body


def hand_set(text: str) -> list[str]:
    """Lander-only settings written outside the block."""
    return [line.strip() for line in strip_block(text).splitlines()
            if LANDER_ONLY.search(line) and not line.lstrip().startswith("//")]


def pending(root: Path) -> dict[str, str]:
    """Each closure manifest whose text the rows would change, with its new text."""
    changes = {}
    for package, targets in plan(root, load_rows(root)).items():
        path = f"{package}/{MANIFEST}"
        text = (root / path).read_text()
        new = rewrite(text, targets)
        if new != text:
            changes[path] = new
    return changes


def check(root: Path) -> list[str]:
    problems = [f"{path}: stale; run scripts/cmux-next/apply-stability-settings.py --commit"
                for path in pending(root)]
    for package in closure(root):
        path = f"{package}/{MANIFEST}"
        for line in hand_set((root / path).read_text()):
            problems.append(f"{path}: `{line}` is a lander-only setting; add a row to {SETTINGS_FILE} instead")
    return problems


def git(root: Path, *args: str, check_ok: bool = True) -> subprocess.CompletedProcess[str]:
    return subprocess.run(["git", "-C", str(root), *args], capture_output=True, text=True, check=check_ok)


def write(root: Path) -> list[str]:
    changes = pending(root)
    for path, text in changes.items():
        (root / path).write_text(text)
    return sorted(changes)


def commit(root: Path) -> str | None:
    changes = pending(root)
    dirty = [path for path in changes if git(root, "diff", "--quiet", "HEAD", "--", path, check_ok=False).returncode]
    if dirty:
        raise LanderError(f"uncommitted edits in {', '.join(dirty)}; the lander commits only its own rewrite")
    if not changes:
        return None
    for path, text in changes.items():
        (root / path).write_text(text)
    tasks = sorted({row.task for row in load_rows(root)})
    paths = sorted(changes)
    subject = f"{LANDER_SUBJECT} apply {SETTINGS_FILE} to {len(paths)} manifest(s)"
    body = ("Rows from: " + ", ".join(tasks) + "\n\nManifests:\n" + "".join(f"- {p}\n" for p in paths)
            + "\nTest phase: fleet compile-check of this commit (cmux-ci build cmux --ref <this sha>).")
    git(root, "add", "--", *paths)
    git(root, "commit", "-m", subject, "-m", body, "--", *paths)
    return git(root, "rev-parse", "HEAD").stdout.strip()


def verify_commits(root: Path, revision_range: str) -> list[str]:
    manifests = [f"{package}/{MANIFEST}" for package in closure(root)]
    shas = git(root, "rev-list", "--no-merges", revision_range, "--", *manifests).stdout.split()
    problems = []
    for sha in shas:
        subject = git(root, "log", "-1", "--format=%s", sha).stdout.strip()
        if subject.startswith(LANDER_SUBJECT):
            continue
        changed = git(root, "diff-tree", "--no-commit-id", "--name-only", "-r", sha, "--", *manifests).stdout.split()
        for path in changed:
            before = git(root, "show", f"{sha}^:{path}", check_ok=False).stdout
            after = git(root, "show", f"{sha}:{path}", check_ok=False).stdout
            try:
                moved = (block_of(before), hand_set(before)) != (block_of(after), hand_set(after))
            except LanderError:
                moved = True
            if moved:
                problems.append(f"{sha[:12]} {path}: changes p10 settings outside a lander commit ({subject})")
    return problems


def main(argv: list[str] | None = None, root: Path = ROOT) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--check", action="store_true")
    mode.add_argument("--write", action="store_true")
    mode.add_argument("--commit", action="store_true")
    mode.add_argument("--verify-commits", metavar="RANGE")
    mode.add_argument("--list-closure", action="store_true")
    args = parser.parse_args(argv)
    try:
        if args.list_closure:
            print("\n".join(closure(root)))
            return 0
        if args.write:
            for path in write(root):
                print(f"wrote {path}")
            return 0
        if args.commit:
            sha = commit(root)
            if sha is None:
                print("nothing to land: every manifest matches the rows")
            else:
                print(f"landed {sha}; compile-check it on the fleet:\n"
                      f"  cmux-ci build cmux --ref {sha} --tag stability-settings-{sha[:9]}")
            return 0
        problems = verify_commits(root, args.verify_commits) if args.verify_commits else check(root)
    except LanderError as error:
        print(f"apply-stability-settings: {error}", file=sys.stderr)
        return 2
    for problem in problems:
        print(problem, file=sys.stderr)
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())
