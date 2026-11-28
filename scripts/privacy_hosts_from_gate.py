#!/usr/bin/env python3
"""Render docs/privacy.md's "The app connects to" table from the egress gate's allowlist.

The allowlist is the one source: cmux-tui/crates/cmux-egress/hosts.txt, which the Rust gate compiles in
(include_str!) and the Swift gate (Packages/Shared/CmuxEgress/.../EgressHosts.swift) is checked equal to. Each
host there carries, in the `#` comment lines directly above it, what it is for and three required keys: what the
app sends there, what makes it connect, and how a person turns it off:

    # the Anthropic API, when you use an Anthropic key or sign in a Cloud machine's Claude
    # sends: your prompts, the files and output the agent sends, and your Anthropic key
    # when: when an agent uses your Anthropic key or sign-in
    # off: remove the Anthropic key or sign-in
    api.anthropic.com

A comment block with a blank line after it (the file header) belongs to no host. The doc's table, between the
`egress-hosts:begin` and `egress-hosts:end` markers, is a build artifact of that file: edit hosts.txt, then run
this script. tests/test_egress_gate.py fails CI when the doc and the allowlist differ (`--check`).

Run it: python3 scripts/privacy_hosts_from_gate.py (rewrites the doc); --check exits 1 on drift.
"""

from __future__ import annotations

import sys
from pathlib import Path
from typing import NamedTuple

ROOT = Path(__file__).resolve().parents[1]
HOSTS = ROOT / "cmux-tui" / "crates" / "cmux-egress" / "hosts.txt"
DOC = ROOT / "docs" / "privacy.md"
BEGIN = ("<!-- egress-hosts:begin: generated from cmux-tui/crates/cmux-egress/hosts.txt by "
         "python3 scripts/privacy_hosts_from_gate.py; edit hosts.txt, not this table -->")
END = "<!-- egress-hosts:end -->"


FIELDS = ("sends", "when", "off")  # what the app sends there, what makes it connect, how a person stops it


class Host(NamedTuple):
    host: str
    what: str  # what the host is for
    sends: str
    when: str
    off: str


def read_hosts(text: str) -> list[Host]:
    """The allowlist's rows in file order. Raises ValueError on a host listed twice, or one missing its description
    or any of the `# sends:`, `# when:` and `# off:` lines."""
    out: list[Host] = []
    seen: set[str] = set()
    plain: list[str] = []
    keyed: dict[str, str] = {}
    for n, raw in enumerate(text.splitlines(), 1):
        line = raw.strip()
        if not line:
            plain, keyed = [], {}
        elif line.startswith("#"):
            body = line[1:].strip()
            key, sep, value = body.partition(":")
            if sep and key in FIELDS:
                if key in keyed:
                    raise ValueError(f"hosts.txt:{n}: `# {key}:` given twice")
                keyed[key] = value.strip()
            elif body:
                plain.append(body)
        else:
            host = line.lower()
            if host in seen:
                raise ValueError(f"hosts.txt:{n}: {host} is listed twice")
            what = " ".join(plain)
            if not what:
                raise ValueError(f"hosts.txt:{n}: {host} has no `# what the host is for` line above it")
            gone = [f"`# {k}:`" for k in FIELDS if not keyed.get(k)]
            if gone:
                raise ValueError(f"hosts.txt:{n}: {host} has no {', '.join(gone)} line above it "
                                 "(what the app sends there, what makes it connect, how a person turns it off)")
            seen.add(host)
            out.append(Host(host, what, keyed["sends"], keyed["when"], keyed["off"]))
            plain, keyed = [], {}
    return out


def cell(text: str) -> str:
    return text.replace("|", "\\|")


def table(hosts: list[Host]) -> str:
    rows = "".join(f"| `{h.host}` | connects | {cell(h.what)} | {cell(h.sends)} | {cell(h.when)} | {cell(h.off)} |\n"
                   for h in hosts)
    head = "| Host | Kind | What for | Sends | When | Turn it off |\n|---|---|---|---|---|---|\n"
    return f"{BEGIN}\n\n{head}{rows}\n{END}"


def render(doc: str, hosts: list[Host]) -> str:
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
