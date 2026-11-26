#!/usr/bin/env python3
"""Render docs/privacy.md's "The app connects to" table from the egress gate's allowlist.

The allowlist is the one source: cmux-tui/crates/cmux-egress/hosts.txt, which the Rust gate compiles in
(include_str!) and the Swift gate (Packages/Shared/CmuxEgress/.../EgressHosts.swift) is checked equal to. Each
host there carries what the app sends to it, as the `#` comment lines directly above it:

    # the Anthropic API, when you use an Anthropic key or sign in a Cloud machine's Claude
    api.anthropic.com

A comment block with a blank line after it (the file header) belongs to no host. The doc's table, between the
`egress-hosts:begin` and `egress-hosts:end` markers, is a build artifact of that file: edit hosts.txt, then run
this script. tests/test_egress_gate.py fails CI when the doc and the allowlist differ (`--check`).

Run it: python3 scripts/privacy_hosts_from_gate.py (rewrites the doc); --check exits 1 on drift.
"""

from __future__ import annotations

import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
HOSTS = ROOT / "cmux-tui" / "crates" / "cmux-egress" / "hosts.txt"
DOC = ROOT / "docs" / "privacy.md"
BEGIN = ("<!-- egress-hosts:begin: generated from cmux-tui/crates/cmux-egress/hosts.txt by "
         "python3 scripts/privacy_hosts_from_gate.py; edit hosts.txt, not this table -->")
END = "<!-- egress-hosts:end -->"


def read_hosts(text: str) -> list[tuple[str, str]]:
    """[(host, what the app sends there)] in file order; raises ValueError on a host with no description or a
    host listed twice."""
    out: list[tuple[str, str]] = []
    seen: set[str] = set()
    comment: list[str] = []
    for n, raw in enumerate(text.splitlines(), 1):
        line = raw.strip()
        if not line:
            comment = []
        elif line.startswith("#"):
            comment.append(line[1:].strip())
        else:
            host = line.lower()
            if host in seen:
                raise ValueError(f"hosts.txt:{n}: {host} is listed twice")
            what = " ".join(c for c in comment if c)
            if not what:
                raise ValueError(f"hosts.txt:{n}: {host} has no `# what the app sends there` line above it")
            seen.add(host)
            out.append((host, what))
            comment = []
    return out


def table(hosts: list[tuple[str, str]]) -> str:
    rows = "".join(f"| `{h}` | connects | {what} |\n" for h, what in hosts)
    return f"{BEGIN}\n\n| Host | Kind | What for |\n|---|---|---|\n{rows}\n{END}"


def render(doc: str, hosts: list[tuple[str, str]]) -> str:
    """The doc with the text between the markers replaced by the table."""
    start, end = doc.find("<!-- egress-hosts:begin"), doc.find(END)
    if start < 0 or end < start:
        raise ValueError(f"{DOC.relative_to(ROOT)}: no egress-hosts:begin ... {END} markers")
    return doc[:start] + table(hosts) + doc[end + len(END):]


def main(argv: list[str]) -> int:
    doc = DOC.read_text()
    want = render(doc, read_hosts(HOSTS.read_text()))
    if "--check" in argv:
        if want != doc:
            print(f"{DOC.relative_to(ROOT)}'s connects table differs from {HOSTS.relative_to(ROOT)}: "
                  "run python3 scripts/privacy_hosts_from_gate.py", file=sys.stderr)
            return 1
        return 0
    if want != doc:
        DOC.write_text(want)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
