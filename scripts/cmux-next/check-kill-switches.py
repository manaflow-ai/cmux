#!/usr/bin/env python3
"""Per-PR kill switches: declared once, tied to their PR, short-lived.

A risky behaviour change on feat-cmux-next can wrap its new path in `killSwitch("pr-<N>")`, N being
its own PR (leo-workspace briefs/2026-10-20-gui-push/partial-rollback.md, section 2). The change
ships; the signed `notes/flags.json` the nightly publishes (release-notes/next/flags.json) can turn
it off on running Macs, without a build, by listing `pr-<N>` in `DisabledFeatures`.

Each switch is declared in release-notes/next/kill-switches.json:

    {"version": 1, "switches": {"pr-23456": {"pr": 23456, "owner": "release-rings",
                                             "expires": "2026-11-20", "default": "new-path"}}}

This check fails when:
  - a key is not `pr-<N>`, or its entry has no `pr` equal to N, no owner or no expiry (YYYY-MM-DD);
  - an expiry is more than 90 days out, or has passed: remove the call, the old path and the entry;
  - `default` is not `new-path` (the change ships; only the signed document turns it off);
  - a `killSwitch(...)` call in app or web sources is not a `"pr-<N>"` literal, names an undeclared
    switch, or a switch is evaluated in more than one file per surface (Swift, web);
  - `killSwitch` is used other than by calling it (`let check = killSwitch`), which hides its key;
  - a declared switch has no call site;
  - flags.json turns off a `pr-<N>` that is not declared.

Usage: check-kill-switches.py [--root DIR] [--today YYYY-MM-DD]
"""

from __future__ import annotations

import argparse
import datetime
import json
import re
import sys
from pathlib import Path

REGISTRY = "release-notes/next/kill-switches.json"
FLAGS = "release-notes/next/flags.json"
# Where switches are evaluated, per surface; tests and the definitions are not call sites.
SURFACES = {
    "Swift": ("Packages/macOS/CmuxNext/Sources", (".swift",)),
    "web": ("webviews/src", (".ts", ".tsx")),
}
NOT_CALL_SITES = re.compile(r"(\.test\.tsx?|/test/|/tests/|Tests/)")
KEY = re.compile(r"^pr-([1-9][0-9]*)$")
CALL = re.compile(r"(?<![\w$])killSwitch\s*\(([^)]*)\)")
# Any use of the name: one that is not a call (`let check = killSwitch`) hides its key from this check.
NAME = re.compile(r"(?<![\w$])killSwitch(?![\w$])")
LITERAL = re.compile(r'^"(pr-[1-9][0-9]*)"$')
DEFINITION = re.compile(r"\b(func|function|const|let|export)\s+killSwitch\b")
DATE = re.compile(r"^\d{4}-\d{2}-\d{2}$")
MAX_DAYS = 90


def is_version_one(value: object) -> bool:
    """JSON booleans and floats must not pass the integer version contract."""
    return type(value) is int and value == 1


def interpolation_end(text: str, i: int, close: str) -> int:
    """The offset just past the bracket `close` that ends the interpolation opened before `i`."""
    opening = "(" if close == ")" else "{"
    depth = 1
    while i < len(text) and depth:
        if text[i] == opening:
            depth += 1
        elif text[i] == close:
            depth -= 1
        i += 1
    return i


def masked(text: str, swift: bool) -> str:
    """`text` with comments blanked and string contents replaced by `x`, at the same offsets, so a
    call is found only in code and its literal argument is read back from `text`. Interpolations
    (Swift `\\(...)`, TypeScript `${...}`) stay code; Swift block comments nest."""
    out = list(text)

    def blank(begin: int, finish: int, fill: str) -> None:
        out[begin:finish] = ["\n" if c == "\n" else fill for c in text[begin:finish]]

    i, n = 0, len(text)
    while i < n:
        if text.startswith("//", i):
            end = text.find("\n", i)
            end = n if end < 0 else end
            blank(i, end, " ")
            i = end
        elif text.startswith("/*", i):
            depth, j = 1, i + 2
            while j < n and depth:
                if swift and text.startswith("/*", j):
                    depth, j = depth + 1, j + 2
                elif text.startswith("*/", j):
                    depth, j = depth - 1, j + 2
                else:
                    j += 1
            blank(i, j, " ")
            i = j
        elif text[i] in "\"'`":
            quote = '"""' if text.startswith('"""', i) else text[i]
            # Only `"""` and template strings span lines: a stray apostrophe (JSX text) masks one line at most.
            single_line = quote in ('"', "'")
            j = i + len(quote)
            while j < n and not text.startswith(quote, j) and not (single_line and text[j] == "\n"):
                if swift and quote != "'" and text.startswith("\\(", j):
                    j = interpolation_end(text, j + 2, ")")
                elif not swift and quote == "`" and text.startswith("${", j):
                    j = interpolation_end(text, j + 2, "}")
                elif text[j] == "\\":
                    out[j] = "x"
                    if j + 1 < n and text[j + 1] != "\n":
                        out[j + 1] = "x"
                    j += 2
                else:
                    if text[j] != "\n":
                        out[j] = "x"
                    j += 1
            i = j + (len(quote) if text.startswith(quote, j) else 0)
        else:
            i += 1
    return "".join(out)


def check_registry(switches: object, today: datetime.date, errors: list[str]) -> dict:
    if not isinstance(switches, dict):
        errors.append(f"{REGISTRY}: `switches` is not an object")
        return {}
    for key, entry in switches.items():
        match = KEY.match(key)
        if not match:
            errors.append(f"{key}: a key is pr-<N>, N the pull request that adds the switch")
            continue
        entry = entry if isinstance(entry, dict) else {}
        if type(entry.get("pr")) is not int or entry["pr"] != int(match.group(1)):
            errors.append(f"{key}: no PR number (`\"pr\": {match.group(1)}`)")
        if not isinstance(entry.get("owner"), str) or not entry["owner"].strip():
            errors.append(f"{key}: no owner")
        if entry.get("default") != "new-path":
            errors.append(f"{key}: `default` must be \"new-path\": the change ships, and only the signed "
                          f"flags.json turns it off")
        expires = entry.get("expires")
        try:
            if not isinstance(expires, str) or not DATE.match(expires):
                raise ValueError
            date = datetime.date.fromisoformat(expires)
        except ValueError:
            errors.append(f"{key}: no expiry (`\"expires\": \"YYYY-MM-DD\"`)")
            continue
        if date < today:
            errors.append(f"{key}: expired on {expires}: remove the killSwitch(\"{key}\") call, the old path "
                          f"and its {REGISTRY} entry")
        elif (date - today).days > MAX_DAYS:
            errors.append(f"{key}: expires {expires}, more than {MAX_DAYS} days out")
    return switches


def call_sites(root: Path, errors: list[str]) -> dict[str, dict[str, list[str]]]:
    """surface -> key -> files that evaluate it."""
    found: dict[str, dict[str, list[str]]] = {}
    for surface, (folder, suffixes) in SURFACES.items():
        base = root / folder
        if not base.is_dir():
            continue
        for path in sorted(base.rglob("*")):
            rel = path.relative_to(root).as_posix()
            if not path.is_file() or path.suffix not in suffixes or NOT_CALL_SITES.search(rel):
                continue
            try:
                text = path.read_text(encoding="utf-8")
            except (OSError, UnicodeDecodeError):
                continue
            if "killSwitch" not in text:
                continue
            # Comments, strings and the definition are not call sites.
            code = "\n".join(" " * len(line) if DEFINITION.search(line) else line
                              for line in masked(text, path.suffix == ".swift").split("\n"))
            calls = {call.start() for call in CALL.finditer(code)}
            for use in NAME.finditer(code):
                if use.start() not in calls:
                    number = code.count("\n", 0, use.start()) + 1
                    errors.append(f"{rel}:{number}: killSwitch is only called, as killSwitch(\"pr-<N>\"); "
                                  f"a reference hides its key from this check")
            for call in CALL.finditer(code):
                number = code.count("\n", 0, call.start()) + 1
                argument = text[call.start(1):call.end(1)]
                literal = LITERAL.match(argument.strip())
                if not literal:
                    errors.append(f"{rel}:{number}: not a literal: killSwitch takes \"pr-<N>\"")
                    continue
                files = found.setdefault(surface, {}).setdefault(literal.group(1), [])
                if rel not in files:
                    files.append(rel)
                found[surface].setdefault("@" + literal.group(1), []).append(f"{rel}:{number}")
    return found


def flagged_off(root: Path, errors: list[str]) -> set[str]:
    path = root / FLAGS
    if not path.is_file():
        return set()
    try:
        document = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError) as error:
        errors.append(f"{FLAGS}: not JSON: {error}")
        return set()
    if not isinstance(document, dict):
        errors.append(f"{FLAGS}: not an object")
        return set()
    if not is_version_one(document.get("version")):
        errors.append(f"{FLAGS}: not a version 1 document")
        return set()
    cohorts = document.get("cohorts", {})
    if not isinstance(cohorts, dict):
        errors.append(f"{FLAGS}: `cohorts` is not an object")
        cohorts = {}
    off = set()
    for name, item in [("default", document.get("default"))] + list(cohorts.items()):
        if item is None:
            continue
        features = item.get("DisabledFeatures") if isinstance(item, dict) else None
        if not isinstance(item, dict) or ("DisabledFeatures" in item and not isinstance(features, list)):
            errors.append(f"{FLAGS}: `{name}` is not an object with a `DisabledFeatures` list")
            continue
        off.update(key for key in features or [] if isinstance(key, str) and key.startswith("pr-"))
    return off


def check(root: Path, today: datetime.date) -> list[str]:
    errors: list[str] = []
    path = root / REGISTRY
    try:
        registry = json.loads(path.read_text(encoding="utf-8")) if path.is_file() else {"version": 1, "switches": {}}
    except (OSError, ValueError) as error:
        return [f"{REGISTRY}: not JSON: {error}"]
    if not isinstance(registry, dict) or not is_version_one(registry.get("version")):
        return [f"{REGISTRY}: not a version 1 registry"]
    switches = check_registry(registry.get("switches"), today, errors)
    sites = call_sites(root, errors)
    used: set[str] = set()
    for surface, keys in sites.items():
        for key, files in keys.items():
            if key.startswith("@"):
                continue
            used.add(key)
            if key not in switches:
                for site in keys["@" + key]:
                    errors.append(f"{site}: {key} is not in {REGISTRY}")
            evaluations = keys["@" + key]
            if len(evaluations) > 1:
                errors.append(f"{key}: {len(evaluations)} {surface} call sites ({', '.join(evaluations)}); "
                              f"one per surface")
    for key in switches:
        if KEY.match(key) and key not in used:
            errors.append(f"{key}: no killSwitch(\"{key}\") call; remove the entry with the switch")
    for key in sorted(flagged_off(root, errors) - set(switches)):
        errors.append(f"{FLAGS} turns off {key}, which {REGISTRY} does not declare")
    return errors


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--root", default=str(Path(__file__).resolve().parents[2]))
    parser.add_argument("--today", help="YYYY-MM-DD (tests); default: today, UTC")
    args = parser.parse_args()
    today = (datetime.date.fromisoformat(args.today) if args.today
             else datetime.datetime.now(datetime.timezone.utc).date())
    errors = check(Path(args.root), today)
    for error in errors:
        print(f"error: {error}")
    if errors:
        print(f"kill switches: {len(errors)} error(s); see {REGISTRY} and scripts/cmux-next/check-kill-switches.py")
        return 1
    print("kill switches: ok")
    return 0


if __name__ == "__main__":
    sys.exit(main())
