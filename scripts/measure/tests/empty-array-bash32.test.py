#!/usr/bin/env python3
"""Measure scripts run on macOS's /bin/bash 3.2, where `set -u` treats an empty array as unset: expanding one as
"${name[*]}" or "${name[@]}" aborts the script ("name[*]: unbound variable"). Linux's bash 4.4+ allows it, so a test
on a Linux runner never sees the abort (launch-premain.sh's root_check, 2026-11-18: every root command allowed left
`refused` empty and both row F settle=1 steps exited 1 before measuring).

This flags, in every scripts/measure/*.sh that sets -u, an array that starts empty (`name=()`) and is expanded bare.
Guard such an expansion with a default ("${name[*]:-}", "${name[*]-}") or the `+` form ("${name[@]+"${name[@]}"}").

    python3 scripts/measure/tests/empty-array-bash32.test.py
"""
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
EMPTY = re.compile(r'(?:^|[\s;(])(?:local\s+[^\n]*?\b)?([A-Za-z_][A-Za-z0-9_]*)=\(\)')
BARE = re.compile(r'(?<![+-])"\$\{([A-Za-z_][A-Za-z0-9_]*)\[[*@]\]\}"')
GUARDED = re.compile(r'\$\{([A-Za-z_][A-Za-z0-9_]*)\[[*@]\]\+')


def problems(path: Path) -> list[str]:
    text = path.read_text(errors="replace")
    if not re.search(r'^\s*set\s+-[a-z]*u', text, re.M):
        return []
    empty = set(EMPTY.findall(text))
    out = []
    for number, line in enumerate(text.splitlines(), 1):
        if line.lstrip().startswith("#"):
            continue
        guarded = set(GUARDED.findall(line))
        for name in BARE.findall(line):
            if name in empty and name not in guarded:
                out.append(f"{path.relative_to(ROOT.parents[1])}:{number}: \"${{{name}[...]}}\" starts empty: {line.strip()}")
    return out


found = [p for path in sorted(ROOT.glob("*.sh")) for p in problems(path)]
for line in found:
    print(line)
print(f"{'FAIL' if found else 'ok'}: {len(found)} bare expansion(s) of an array that starts empty")
sys.exit(1 if found else 0)
