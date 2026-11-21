#!/usr/bin/env python3
"""naming-autofix: renames ids that break a naming rule CI checks mechanically, when the rename is unambiguous.

    naming_autofix.py --check [--base REF | --paths PATH...] [--repo DIR]
    naming_autofix.py --fix   [--base REF | --paths PATH...] [--repo DIR] [--only PREFIX...] [--frozen-list FILE]

#48230 registered the webviews experiment id `agent-pane.high-contrast-look`. validateExperiments
(webviews/src/experiments/experiment.ts, EXPERIMENT_ID) takes lower kebab case only, so the PR-scoped webviews check
(gallery-coverage) went red on every webviews pull request until #49118, and four other pull requests (#48723,
#49075, #49086, #49236) each made the same rename by hand. This makes that rename, and every one like it.

Rules (each reads its pattern from the TypeScript that CI runs, never a copy):
  experiment-id     `id:` of defineExperiment/defineTunable in webviews/**/*.experiment.ts; EXPERIMENT_ID from
                    webviews/src/experiments/experiment.ts (validateExperiments, validateTunables).
  gallery-entry-id  `id:` of a `...Entry({` call in webviews/**/*.gallery.ts(x); ENTRY_ID from
                    webviews/src/gallery/format.ts (validateEntries). The same id names the entry in Swift.
Left out on purpose: arm and variant names (object keys that code reads as properties: a rename needs a TS parser),
chief view ids (stored in saved layouts) and string catalog keys (looked up from Swift and stored translations).

The rename is the id's canonical form: camelCase split, lowercased, every other run of characters one `-` (for a
gallery id, per dotted segment). It is made only when that form passes the rule and no other id of the rule has it;
otherwise the violation is printed as `left:` and nothing changes. Never touches an id that passes its rule.

--fix rewrites the definition and every exact quoted reference ("old", 'old', `old`) in tracked files. A reference
line that is itself the `id:` of some other definition is never rewritten; when the old id is also a valid id of
another rule (the gallery entry of #48230 is `agent-pane.high-contrast-look`), only the definition is renamed, since
no reference can be told apart. --only PREFIX (repeatable) and --frozen-list FILE (base-autofix-frozen.txt globs)
leave a violation whose rename would touch a path outside the prefixes or a frozen one: a rename is whole or none.

--base REF limits the violations to definitions in files changed since the merge base of REF and HEAD (committed,
staged or not); --paths limits them to the given files. References are rewritten everywhere either way.
Output: --check prints `FILE:LINE OLD -> NEW (rule)` per fixable violation and `left: ...` per other one, exit 1 when
any; --fix prints `fixed: ...` and `left: ...` lines (base-autofix.sh's format), exit 1 when any is left.
"""
from __future__ import annotations

import argparse
import fnmatch
import os
import re
import subprocess
import sys
from dataclasses import dataclass, field

EXPERIMENT_TS = "webviews/src/experiments/experiment.ts"
GALLERY_FORMAT_TS = "webviews/src/gallery/format.ts"


@dataclass(frozen=True)
class Rule:
    name: str
    source: str  # the TypeScript file that holds the pattern
    constant: str  # the exported regex constant
    globs: tuple[str, ...]  # definition files (git pathspecs)
    definition: re.Pattern[str]  # group "quote", "id"
    dotted: bool


RULES = (
    Rule("experiment-id", EXPERIMENT_TS, "EXPERIMENT_ID", ("webviews/*.experiment.ts",),
         re.compile(r"^[ \t]*id:[ \t]*(?P<quote>[\"'`])(?P<id>[^\"'`\n]*)(?P=quote)", re.M), dotted=False),
    Rule("gallery-entry-id", GALLERY_FORMAT_TS, "ENTRY_ID", ("webviews/*.gallery.ts", "webviews/*.gallery.tsx"),
         re.compile(r"\b[a-z]\w*Entry(?:<[^()]*?>)?\(\{\s*id:[ \t]*(?P<quote>[\"'`])(?P<id>[^\"'`\n]*)(?P=quote)"),
         dotted=True),
)


@dataclass
class Violation:
    rule: str
    path: str
    line: int
    offset: int  # of the id's first character in the file
    old: str
    new: str | None
    reason: str = ""
    edits: dict[str, list[tuple[int, int]]] = field(default_factory=dict)  # path -> (start, end) spans

    def where(self) -> str:
        return f"{self.path}:{self.line}"


def git(repo: str, *args: str, check: bool = True) -> str:
    done = subprocess.run(["git", "-C", repo, *args], capture_output=True, text=True)
    if check and done.returncode != 0:
        raise SystemExit(f"naming-autofix: git {' '.join(args)} failed: {done.stderr.strip()}")
    return done.stdout


def ts_regex(repo: str, source: str, constant: str) -> re.Pattern[str]:
    """The `export const NAME = /.../flags;` regex literal of SOURCE, as a Python pattern."""
    with open(os.path.join(repo, source), encoding="utf-8") as handle:
        text = handle.read()
    found = re.search(rf"^export const {constant}\s*=\s*/((?:\\.|[^/\\\n])+)/([a-z]*)\s*;", text, re.M)
    if not found:
        raise SystemExit(f"naming-autofix: no `export const {constant} = /.../` in {source}; update RULES")
    flags = re.I if "i" in found.group(2) else 0
    return re.compile(found.group(1), flags)


def kebab(text: str) -> str:
    text = re.sub(r"([a-z0-9])([A-Z])", r"\1-\2", text)
    text = re.sub(r"([A-Z]+)([A-Z][a-z])", r"\1-\2", text)
    return re.sub(r"[^a-z0-9]+", "-", text.lower()).strip("-")


def canonical(old: str, dotted: bool) -> str:
    if dotted:
        return ".".join(part for part in (kebab(segment) for segment in old.split(".")) if part)
    return kebab(old)


def line_of(text: str, offset: int) -> int:
    return text.count("\n", 0, offset) + 1


def changed_since(repo: str, base: str) -> set[str]:
    merge_base = git(repo, "merge-base", base, "HEAD").strip()
    names = git(repo, "diff", "--name-only", "--no-renames", merge_base)
    names += git(repo, "ls-files", "--others", "--exclude-standard")
    return {name for name in names.splitlines() if name}


def frozen_patterns(path: str | None) -> list[str]:
    if not path:
        return []
    with open(path, encoding="utf-8") as handle:
        return [line.strip() for line in handle if line.strip() and not line.startswith("#")]


def is_frozen(rel: str, patterns: list[str]) -> bool:
    hit = False
    for pattern in patterns:
        if pattern.startswith("!"):
            if fnmatch.fnmatchcase(rel, pattern[1:]):
                return False
        elif fnmatch.fnmatchcase(rel, pattern):
            hit = True
    return hit


def definitions(repo: str, rule: Rule) -> list[tuple[str, int, str]]:
    """(path, offset of the id, id) for every definition of RULE in the work tree."""
    found = []
    for path in git(repo, "ls-files", "-z", "--", *rule.globs).split("\0"):
        if not path or not os.path.isfile(os.path.join(repo, path)):
            continue
        with open(os.path.join(repo, path), encoding="utf-8", errors="replace") as handle:
            text = handle.read()
        for match in rule.definition.finditer(text):
            found.append((path, match.start("id"), match.group("id")))
    return found


def references(repo: str, old: str) -> dict[str, list[tuple[int, int]]]:
    """Every quoted exact occurrence of OLD in tracked files: path -> (start, end) of OLD, skipping `id:` lines."""
    listed = git(repo, "grep", "-z", "-l", "-F", "-e", old, check=False)
    quoted = re.compile(r"([\"'`])" + re.escape(old) + r"\1")
    other_id = re.compile(r"\bid\s*:\s*([\"'`])" + re.escape(old) + r"\1")
    spans: dict[str, list[tuple[int, int]]] = {}
    for path in listed.split("\0"):
        if not path:
            continue
        try:
            with open(os.path.join(repo, path), encoding="utf-8") as handle:
                text = handle.read()
        except (OSError, UnicodeDecodeError):
            continue
        for match in quoted.finditer(text):
            start = text.rfind("\n", 0, match.start()) + 1
            end = text.find("\n", match.end())
            if other_id.search(text[start:end if end >= 0 else len(text)]):
                continue
            spans.setdefault(path, []).append((match.start() + 1, match.end() - 1))
    return spans


def scan(repo: str, limit: set[str] | None, only: list[str], frozen: list[str]) -> list[Violation]:
    patterns = {rule.name: ts_regex(repo, rule.source, rule.constant) for rule in RULES}
    defined = {rule.name: definitions(repo, rule) for rule in RULES}
    valid_anywhere = {ident for rule in RULES for _, _, ident in defined[rule.name] if patterns[rule.name].fullmatch(ident)}
    violations = []
    for rule in RULES:
        pattern = patterns[rule.name]
        taken = {ident for _, _, ident in defined[rule.name]}
        for path, offset, old in defined[rule.name]:
            if pattern.fullmatch(old) or (limit is not None and path not in limit):
                continue
            with open(os.path.join(repo, path), encoding="utf-8", errors="replace") as handle:
                line = line_of(handle.read(), offset)
            violation = Violation(rule.name, path, line, offset, old, canonical(old, rule.dotted))
            violations.append(violation)
            if not violation.new or not pattern.fullmatch(violation.new):
                violation.reason = f"its canonical form {violation.new!r} does not pass {rule.constant} either"
                violation.new = None
                continue
            if violation.new in taken:
                violation.reason = f"{violation.new} is already a {rule.name}"
                violation.new = None
                continue
            if sum(1 for _, _, ident in defined[rule.name] if ident == old) > 1:
                violation.reason = "the id is defined more than once"
                violation.new = None
                continue
            if old in valid_anywhere:
                # Also a valid id of another rule: no reference can be told apart, so only the definition moves.
                violation.edits = {path: [(offset, offset + len(old))]}
            else:
                violation.edits = references(repo, old)
                violation.edits.setdefault(path, [])
                if (offset, offset + len(old)) not in violation.edits[path]:
                    violation.edits[path].append((offset, offset + len(old)))
            outside = [p for p in violation.edits if only and not any(p.startswith(prefix) for prefix in only)]
            held = [p for p in violation.edits if is_frozen(p, frozen)]
            if outside or held:
                violation.reason = ("the rename also touches " + ", ".join(sorted(outside + held))
                                    + (" (outside " + ", ".join(only) + ")" if outside else "")
                                    + (" (frozen)" if held else ""))
                violation.new = None
    return violations


def apply(repo: str, violations: list[Violation]) -> None:
    by_path: dict[str, list[tuple[int, int, str]]] = {}
    for violation in violations:
        if violation.new is None:
            continue
        for path, spans in violation.edits.items():
            by_path.setdefault(path, []).extend((start, end, violation.new) for start, end in spans)
    for path, edits in by_path.items():
        full = os.path.join(repo, path)
        with open(full, encoding="utf-8", newline="") as handle:
            text = handle.read()
        for start, end, new in sorted(set(edits), reverse=True):
            text = text[:start] + new + text[end:]
        with open(full, "w", encoding="utf-8", newline="") as handle:
            handle.write(text)


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument("--check", action="store_true", help="print violations, exit 1 when any")
    mode.add_argument("--fix", action="store_true", help="rename the ids and their references in place")
    scope = parser.add_mutually_exclusive_group()
    scope.add_argument("--base", help="only definitions in files changed since the merge base with REF")
    scope.add_argument("--paths", nargs="+", help="only definitions in these repository paths")
    parser.add_argument("--repo", default=None, help="the checkout (default: the one around the working directory)")
    parser.add_argument("--only", action="append", default=[], help="leave a rename touching a path outside PREFIX")
    parser.add_argument("--frozen-list", help="leave a rename touching a path these globs freeze")
    args = parser.parse_args(argv)
    repo = args.repo or git(os.getcwd(), "rev-parse", "--show-toplevel").strip()
    repo = os.path.abspath(repo)
    if not os.path.isfile(os.path.join(repo, EXPERIMENT_TS)):
        return 0  # a checkout without the webviews rules (a sparse one, or another branch): nothing to check
    limit = None
    if args.base:
        limit = changed_since(repo, args.base)
    elif args.paths:
        limit = {os.path.relpath(os.path.abspath(p), repo) if os.path.isabs(p) else p for p in args.paths}
    violations = scan(repo, limit, args.only, frozen_patterns(args.frozen_list))
    if args.fix:
        apply(repo, violations)
    for violation in violations:
        if violation.new is None:
            print(f"left: {violation.where()} {violation.old}: no unambiguous rename ({violation.rule}: {violation.reason})")
        elif args.fix:
            touched = sorted(violation.edits)
            print(f"fixed: {violation.where()} {violation.old} -> {violation.new} ({violation.rule}; "
                  f"{len(touched)} file(s): {', '.join(touched)})")
        else:
            print(f"{violation.where()} {violation.old} -> {violation.new} ({violation.rule})")
    if args.check and violations:
        print("naming-autofix: fix with python3 scripts/ci/naming_autofix.py --fix"
              + (f" --base {args.base}" if args.base else ""), file=sys.stderr)
    if args.check:
        return 1 if violations else 0
    return 1 if any(v.new is None for v in violations) else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
