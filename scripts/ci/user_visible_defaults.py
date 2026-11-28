#!/usr/bin/env python3
"""Flag a pull request that changes a user-visible default. A warning, never a failure.

Leo, ask-5ad71ec59c (2026-11-27): "Flag changes to user-visible defaults (like the
banner, the Live button or Cmd+N)."

This is not the defaults guard Leo had deleted in cmux#55271 ("if it's not useful, get
rid of it"). That guard went red on every default in the 1,858-entry snapshot until an
owner approved the change, and it blocked a flip he had asked for (cmux#55028). This
check never goes red, needs no approval, and watches only the short list in
scripts/ci/user-visible-defaults.json. When a pull request changes one of those, it
writes a `::warning` annotation at the file and line, plus a row in the step summary,
so the change shows up in review. The rule itself ("flip a default only when Leo says
so") stays in the rulebook, and the PR body quoting him is still the record.

It reads only what it needs at the two commits, so it runs in about a second:
- settings: the rows in schemas/settings/source/**.json (their `default`)
- shortcuts: plans/cmux-next/action-surfaces.json (each action's default keys)
- Debug Tunables and `static let ...Enabled` flags: only the Swift files the diff touches

  python3 scripts/ci/user_visible_defaults.py --base BASE [--head HEAD]

It exits 0 on every path. Any error becomes a warning: the check fails open.
"""
from __future__ import annotations

import argparse
import fnmatch
import json
import os
import re
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts" / "ci"))
import defaults_guard as guard  # noqa: E402  (action_keys, tunables, FLAG_RE, Change)

WATCH = "scripts/ci/user-visible-defaults.json"
SETTINGS_SOURCE = "schemas/settings/source"
SWIFT_SOURCES = guard.SWIFT_SOURCES


def git(*args: str) -> str:
    return subprocess.run(["git", "-C", str(ROOT), *args], check=True, capture_output=True, text=True).stdout


def show(ref: str, path: str) -> str | None:
    result = subprocess.run(["git", "-C", str(ROOT), "show", f"{ref}:{path}"], capture_output=True, text=True)
    return result.stdout if result.returncode == 0 else None


def show_many(ref: str, paths: list[str]) -> dict[str, str]:
    """Every path's text at ref in one `git cat-file --batch` (one git call, not one per file)."""
    if not paths:
        return {}
    request = "".join(f"{ref}:{path}\n" for path in paths).encode()
    out = subprocess.run(["git", "-C", str(ROOT), "cat-file", "--batch"], input=request, check=True, capture_output=True).stdout
    found: dict[str, str] = {}
    at = 0
    for path in paths:
        end = out.index(b"\n", at)
        header = out[at:end].split()
        at = end + 1
        if len(header) == 2 and header[1] == b"missing":
            continue
        size = int(header[2])
        found[path] = out[at:at + size].decode("utf-8", "replace")
        at += size + 1
    return found


def files_at(ref: str, prefix: str) -> list[str]:
    return [p for p in git("ls-tree", "-r", "--name-only", ref, "--", prefix).splitlines() if p]


@dataclass(frozen=True)
class Value:
    value: object
    path: str
    line: int


def line_of(text: str, needle: str) -> int:
    for number, line in enumerate(text.splitlines(), 1):
        if needle in line:
            return number
    return 1


def settings(ref: str) -> dict[str, Value]:
    found: dict[str, Value] = {}
    paths = [p for p in files_at(ref, SETTINGS_SOURCE) if p.endswith(".json")]
    for path, text in show_many(ref, paths).items():
        try:
            data = json.loads(text)
        except json.JSONDecodeError:
            continue
        stack = [data]
        while stack:
            node = stack.pop()
            if isinstance(node, dict):
                key = node.get("key")
                if isinstance(key, str) and "default" in node and "kind" in node:
                    found[f"setting.{key}"] = Value(node["default"], path, line_of(text, f'"key": "{key}"'))
                stack.extend(node.values())
            elif isinstance(node, list):
                stack.extend(node)
    return found


def shortcuts(ref: str) -> dict[str, Value]:
    text = show(ref, guard.ACTION_SURFACES)
    if text is None:
        return {}
    found: dict[str, Value] = {}
    for action in json.loads(text).get("actions", []):
        keys = guard.action_keys(action)
        if keys:
            found[f"key.{action['id']}"] = Value(keys, guard.ACTION_SURFACES, line_of(text, f'"id" : "{action["id"]}"'))
    return found


def swift(ref: str, paths: list[str]) -> dict[str, Value]:
    found: dict[str, Value] = {}
    for path, text in show_many(ref, paths).items():
        for key, value in guard.tunables(text):
            found[f"tunable.{key}"] = Value(value, path, line_of(text, f'"{key}"'))
        for number, line in enumerate(text.splitlines(), 1):
            for flag, value in guard.FLAG_RE.findall(line):
                name = path.removeprefix(SWIFT_SOURCES + "/").removesuffix(".swift")
                found.setdefault(f"flag.{name}.{flag}", Value(value == "true", path, number))
    return found


def defaults(ref: str, swift_paths: list[str]) -> dict[str, Value]:
    return {**settings(ref), **shortcuts(ref), **swift(ref, swift_paths)}


@dataclass(frozen=True)
class Rule:
    name: str
    ids: tuple[str, ...]
    keys: tuple[str, ...]

    def matches(self, id: str, old: object, new: object) -> bool:
        if any(fnmatch.fnmatchcase(id.lower(), pattern.lower()) for pattern in self.ids):
            return True
        if not id.startswith("key.") or not self.keys:
            return False
        bound = {str(k) for v in (old, new) if isinstance(v, list) for k in v}
        return any(k in bound for k in self.keys)


def rules(text: str) -> list[Rule]:
    return [Rule(row["name"], tuple(row.get("ids", [])), tuple(row.get("keys", []))) for row in json.loads(text)["watch"]]


@dataclass(frozen=True)
class Flag:
    rule: str
    change: guard.Change
    path: str
    line: int

    @property
    def annotation(self) -> str:
        title = guard.plain(f"user-visible default changed: {self.rule}")
        return f"::warning file={self.path},line={self.line},title={title}::{self.change.line}"


def flags(old: dict[str, Value], new: dict[str, Value], watched: list[Rule]) -> list[Flag]:
    found = []
    for change in guard.changes({k: v.value for k, v in old.items()}, {k: v.value for k, v in new.items()}):
        rule = next((r for r in watched if r.matches(change.id, change.old, change.new)), None)
        if rule is None:
            continue
        where = new.get(change.id) or old[change.id]
        found.append(Flag(rule.name, change, where.path, where.line))
    return found


def summary(found: list[Flag]) -> str:
    rows = [f"| {f.rule} | `{f.change.id}` | {guard.plain(f.change.detail)} | `{f.path}:{f.line}` |" for f in found]
    return "\n".join([
        "### User-visible defaults this PR changes",
        "",
        "A heads-up, not a failure (ask-5ad71ec59c). Quote Leo's words in the PR body if he asked for it.",
        "",
        "| default | id | old -> new | where |",
        "|---|---|---|---|",
        *rows,
        "",
    ])


def run(base: str, head: str) -> list[Flag]:
    changed = [p for p in git("diff", "--name-only", "--no-renames", base, head).splitlines()
               if p.startswith(SWIFT_SOURCES + "/") and p.endswith(".swift")]
    watch = show(head, WATCH) or (ROOT / WATCH).read_text()
    return flags(defaults(base, changed), defaults(head, changed), rules(watch))


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--base", required=True)
    parser.add_argument("--head", default="HEAD")
    args = parser.parse_args(argv)
    try:
        found = run(args.base, args.head)
    except Exception as error:  # fail open: a broken read is a warning, never a red PR
        print(f"::warning title=user-visible defaults check skipped::{guard.plain(repr(error))}")
        return 0
    for flag in found:
        print(flag.annotation)
    print(f"{len(found)} user-visible default(s) changed against {args.base}")
    if found and os.environ.get("GITHUB_STEP_SUMMARY"):
        with open(os.environ["GITHUB_STEP_SUMMARY"], "a", encoding="utf-8") as out:
            out.write(summary(found))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
