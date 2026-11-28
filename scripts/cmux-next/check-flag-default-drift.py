#!/usr/bin/env python3
# Reads (scripts/ci/guard_step_inputs.py; check_pool_affected.py --verify --match check-flag-default-drift.py holds it):
# guard-inputs: Packages/**/*.swift cmux-tui/**/*.rs cmux-next-ios/**/*.rs cmux-next-ios/**/*.swift plans/**/*.json docs/**/*.md plans/**/*.md
"""Fails when an environment switch read against a literal disagrees with the default its own comments state.

A switch read as `== "1"` is off when unset; one read as `!= "0"` is on when unset. memory-per-chat, 2026-11-28:
CMUX_NEXT_CHAT_RENDERER_RECYCLE was read `== "1"` while its doc comment and #61534 said "on by default", so the
feature was off in every build and the bench recorded 1.357x per chat with it off (fixed in cmux#64383). The default
lived in two places and drifted. This reads every such comparison (directly on the name, or through a constant that
holds it) and the comments around the read and the constant, and names each one whose comment claims the other
default. It also reads what the docs, plans and arch exceptions say about each switch by name ("on unless NAME=0",
"NAME=0 turns it off", "off unless NAME=1", ...): #61534's arch exception said on while the code read `== "1"`. The
memory-agents bench prints the gates it depends on and refuses rows with one off
(memory-agents-cron.py GATES), so a measurement cannot hide the same drift.

Usage: check-flag-default-drift.py [ROOT]   (exit 1 and one line per mismatch)
"""
from __future__ import annotations

import os
import re
import subprocess
import sys

EXTS = (".swift", ".rs")
NAME = r"[A-Z][A-Z0-9_]{5,}"
IDENT = r"[A-Za-z_][A-Za-z0-9_.:]*"
CONST = re.compile(r'(?:static let|let|const|pub const|pub\(crate\) const|static)\s+([A-Za-z_][A-Za-z0-9_]*)\s*'
                   r'(?::\s*&?(?:\'static\s+)?\w*\s*)?=\s*"(' + NAME + r')"')
# The key is a literal name in quotes or an identifier; the comparison is to an on-literal (default off) or not-equal
# to an off-literal (default on).
KEY = r'(?:"(?P<lit>' + NAME + r')"|(?P<id>' + IDENT + r'))'
READS = [
    ("off", re.compile(r'\[\s*' + KEY + r'\s*\]\s*==\s*"(?:1|true|yes)"')),
    ("off", re.compile(r'var(?:_os)?\(\s*' + KEY + r'\s*\)[^;\n]{0,50}?==\s*(?:Ok\(|Some\()?"(?:1|true)"')),
    ("on", re.compile(r'\[\s*' + KEY + r'\s*\]\s*!=\s*"(?:0|false|no)"')),
    ("on", re.compile(r'var(?:_os)?\(\s*' + KEY + r'\s*\)[^;\n]{0,50}?!=\s*(?:Ok\(|Some\()?"(?:0|false)"')),
]
CLAIM = {
    "on": re.compile(r"on by default|defaults? (?:to )?on\b|enabled by default|=0 turns (?:it |\w+ )?off|"
                     r"anything else, or unset, leaves it on", re.I),
    "off": re.compile(r"off by default|defaults? (?:to )?off\b|disabled by default|default-off|"
                      r"=1 turns (?:it |\w+ )?on", re.I),
}
COMMENT = re.compile(r"^\s*(?://|#|\*|/\*)")


def comments(lines: list[str], index: int, before: int = 6) -> str:
    """The comment lines right above line `index` (0-based) and any trailing comment on it."""
    out = []
    i = index - 1
    while i >= 0 and index - i <= before and COMMENT.match(lines[i]):
        out.append(lines[i])
        i -= 1
    tail = lines[index].split("//", 1)
    return " ".join(out + ([tail[1]] if len(tail) == 2 else []))


def named_claims(text: str, names: set[str]) -> list[tuple[str, str, int]]:
    """(name, on|off, 0-based line) for each line that states a switch's default by its name (pure)."""
    out = []
    for i, line in enumerate(text.split("\n")):
        for name in set(re.findall(NAME, line)) & names:
            n = re.escape(name)
            if re.search(rf"(?:on|enabled|runs) unless `?{n}=0|{n}=0`? (?:turns|switches|keeps) (?:it |\w+ )?off", line, re.I):
                out.append((name, "on", i))
            if re.search(rf"(?:off|disabled) unless `?{n}=1|{n}=1`? (?:turns|switches) (?:it |\w+ )?on|opt in with `?{n}=1",
                         line, re.I):
                out.append((name, "off", i))
    return out


def defaults_in(text: str) -> dict[str, set[str]]:
    """Each switch's default as the code reads it in one file (pure): name -> {"on", "off"}."""
    lines = text.split("\n")
    consts = {m.group(1): m.group(2) for line in lines for m in CONST.finditer(line)}
    out: dict[str, set[str]] = {}
    for line in lines:
        for default, pattern in READS:
            for m in pattern.finditer(line):
                name = m.group("lit") or consts.get(re.split(r"[.:]", m.group("id") or "")[-1])
                if name:
                    out.setdefault(name, set()).add(default)
    return out


def check_named(defaults: dict[str, set[str]], docs: dict[str, str]) -> list[str]:
    """Docs that state a switch's default by name against the code's one default for it (pure). A switch the code
    reads both ways is left to check_text (two readers of one name)."""
    found = []
    single = {name: next(iter(d)) for name, d in defaults.items() if len(d) == 1}
    for path, text in sorted(docs.items()):
        for name, said, i in named_claims(text, set(single)):
            if said != single[name]:
                found.append(f"{path}:{i + 1}: says {name} is {said} by default, but the code reads it {single[name]} "
                             f"when unset")
    return found


def check_text(path: str, text: str) -> list[str]:
    """Mismatches in one file (pure)."""
    lines = text.split("\n")
    consts = {}
    for i, line in enumerate(lines):
        for m in CONST.finditer(line):
            consts[m.group(1)] = (m.group(2), i)
    found = []
    for i, line in enumerate(lines):
        for default, pattern in READS:
            for m in pattern.finditer(line):
                name, where = m.group("lit"), [i]
                if not name:
                    ident = re.split(r"[.:]", m.group("id"))[-1]
                    if ident not in consts:
                        continue
                    name, at = consts[ident]
                    where.append(at)
                other = "on" if default == "off" else "off"
                said = " ".join(comments(lines, w) for w in where)
                # A comment that names the switch with =0/=1 only counts when it names this switch.
                if CLAIM[other].search(said) and not CLAIM[default].search(said):
                    found.append(f"{path}:{i + 1}: {name} is {default} when unset in the code, but its comment says "
                                 f"{other} by default")
    return found


def main(argv: list[str]) -> int:
    root = argv[1] if len(argv) > 1 else os.getcwd()
    files = subprocess.run(["git", "-C", root, "ls-files", "--", *[f"*{e}" for e in EXTS]],
                           capture_output=True, text=True, check=True).stdout.split("\n")
    docs_files = subprocess.run(["git", "-C", root, "ls-files", "--", "plans/*.json", "*.md", *[f"*{e}" for e in EXTS]],
                                capture_output=True, text=True, check=True).stdout.split("\n")
    found, defaults, texts = [], {}, {}
    for rel in sorted(set(files) | set(docs_files)):
        if not rel:
            continue
        try:
            with open(os.path.join(root, rel), errors="ignore") as f:
                text = f.read()
        except OSError:
            continue
        if "=0" in text or "=1" in text:
            texts[rel] = text
        if rel.endswith(EXTS) and ('"0"' in text or '"1"' in text or '"true"' in text or '"false"' in text):
            found += check_text(rel, text)
            for name, d in defaults_in(text).items():
                defaults.setdefault(name, set()).update(d)
    found += check_named(defaults, texts)
    for line in found:
        print(line)
    if found:
        print(f"check-flag-default-drift: {len(found)} switch(es) whose code default and written default disagree; "
              "fix the one that is wrong (a default Leo set stays; a stale comment changes)", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
