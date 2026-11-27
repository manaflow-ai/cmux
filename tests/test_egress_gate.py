#!/usr/bin/env python3
"""Egress gate guard: every outbound connection cmux NEXT opens goes through the egress gate.

docs/privacy.md lists the hosts the app talks to, and tests/test_outbound_hosts.py keeps that list exact at CI time.
The gate enforces it at run time: in nightly and dev builds a connection to a host with no `connects` row is
refused (goals/privacy-runtime-egress-enforced.md in cmuxterm-hq; Leo, 2026-11-21: "we need to get more
ambitious"). A connection the code opens without the gate is a hole the run-time check never sees, so this guard
finds every place the code makes an HTTP client or socket by hand:

  rust   reqwest::Client::new() / ::builder() (and blocking), reqwest::get(), Client::builder(), tungstenite's
         connect_async*, ureq
  swift  (the Swift gate is Packages/Shared/CmuxEgress: CmuxEgress.session/shared/websocket/connection)
         URLSession(configuration:), URLSession(), URLSession.shared, NWConnection(, .webSocketTask(

GATES are the gate's own files, where the one real client is made. Every other site is listed in UNGATED
(tests/egress_ungated.json), file by file with a count per form. The list may only shrink: a new site fails (make
the client through the gate instead), and a site that left the code fails until its entry is removed (run
`--write`), so the count (`--json`) is exact. The scan scope is the host guard's (SCAN), with
comments, tests, mocks and Rust #[cfg(test)] modules left out the same way.

Run it: python3 tests/test_egress_gate.py. Rewrite the list after moving sites to the gate: --write.
Print the count: --json.
"""

from __future__ import annotations

import json
import re
import subprocess
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from test_classic_cloud_routes import clean, in_scope  # noqa: E402
from test_outbound_hosts import DOC, SCAN, listed  # noqa: E402

ROOT = Path(__file__).resolve().parents[1]
UNGATED = ROOT / "tests" / "egress_ungated.json"
# The gate's own sources: the only place a raw client may be made (Rust: cmux-egress; Swift: CmuxEgress).
GATES: tuple[str, ...] = ("cmux-tui/crates/cmux-egress/", "Packages/Shared/CmuxEgress/Sources/")
# The `connects` hosts the Rust gate lets through, generated from docs/privacy.md (--write).
GATE_HOSTS = ROOT / "cmux-tui" / "crates" / "cmux-egress" / "hosts.txt"
# The same hosts as Swift, for the Swift gate (Packages/Shared/CmuxEgress).
GATE_HOSTS_SWIFT = ROOT / "Packages" / "Shared" / "CmuxEgress" / "Sources" / "CmuxEgress" / "EgressHosts.swift"
FORMS = {
    ".rs": {
        "reqwest-client": r"reqwest::(?:blocking::)?Client(?:Builder)?::(?:new|builder)\(",
        "reqwest-get": r"reqwest::(?:blocking::)?get\(",
        "client-builder": r"(?<![\w:])Client::builder\(\)",
        # cmux_egress::ws:: is the gate's own WebSocket connect.
        "ws-connect": r"(?<!cmux_egress::ws::)\bconnect_async(?:_with_config|_tls_with_config)?\(",
        "ureq": r"\bureq::",
    },
    ".swift": {
        # `\s*`: the initializer split over lines, `URLSession(\n    configuration:`, is one too.
        "urlsession": r"\bURLSession\(\s*(?:configuration|\))",
        "urlsession-shared": r"\bURLSession\.shared\b",
        # A defaulted parameter or stored property: `session: URLSession = .shared` is the shared session too.
        "urlsession-default": r"\bURLSession\s*=\s*\.shared\b",
        # The shared session passed by its short name: `Client(session: .shared)`.
        "urlsession-shared-arg": r"\b[sS]ession:\s*\.shared\b",
        "nwconnection": r"\bNWConnection\(",
        "websocket-task": r"\.webSocketTask\(",
    },
}
COMPILED = {ext: re.compile("|".join(f"(?P<{k.replace('-', '_')}>{v})" for k, v in forms.items()))
            for ext, forms in FORMS.items()}


def sites_in(text: str, rel: str) -> dict[str, int]:
    """{form: count} for one file's source, comments and test modules blanked."""
    ext = Path(rel).suffix
    if ext not in COMPILED:
        return {}
    out: dict[str, int] = {}
    for m in COMPILED[ext].finditer(clean(text, ext)):
        form = m.lastgroup.replace("_", "-")
        out[form] = out.get(form, 0) + 1
    return out


def scan(root: Path = ROOT) -> dict[str, dict[str, int]]:
    """{file: {form: count}} for every ungated outbound site in NEXT's source."""
    p = subprocess.run(["git", "-C", str(root), "ls-files", "-z", "--", *SCAN["include"]], capture_output=True)
    if p.returncode != 0:
        raise RuntimeError(p.stderr.decode(errors="replace"))
    found: dict[str, dict[str, int]] = {}
    for rel in sorted(r for r in p.stdout.decode().split("\0") if r):
        if Path(rel).suffix not in COMPILED or not in_scope(rel, SCAN) or rel.startswith(GATES or ("\0",)):
            continue
        path = root / rel
        if path.is_symlink() or not path.is_file():
            continue
        got = sites_in(path.read_text(encoding="utf-8", errors="replace"), rel)
        if got:
            found[rel] = dict(sorted(got.items()))
    return found


def load(path: Path = UNGATED) -> dict[str, dict[str, int]]:
    data = json.loads(path.read_text())
    return data["files"]


def problems(found: dict[str, dict[str, int]], listed: dict[str, dict[str, int]]) -> list[str]:
    out = []
    for rel in sorted(set(found) | set(listed)):
        have, allowed = found.get(rel, {}), listed.get(rel, {})
        for form in sorted(set(have) | set(allowed)):
            n, cap = have.get(form, 0), allowed.get(form, 0)
            if n > cap:
                out.append(f"{rel}: {n - cap} new {form} site(s) outside the egress gate: make the client through the "
                           "gate (docs/privacy.md, Egress gate) instead of by hand")
            elif n < cap:
                out.append(f"{rel}: {cap - n} {form} site(s) left the code: run python3 tests/test_egress_gate.py "
                           "--write so the list stays exact")
    return out


def gate_hosts_text(doc: str) -> str:
    rows, _ = listed(doc)
    hosts = sorted(h for h, (kind, _) in rows.items() if kind == "connects")
    return ("# docs/privacy.md's `connects` hosts: what the egress gate lets through. Generated: "
            "python3 tests/test_egress_gate.py --write\n" + "".join(f"{h}\n" for h in hosts))


def swift_gate_hosts() -> list[str]:
    """The hosts EgressHosts.swift (hand-kept data, no generated header) lists, in file order."""
    return re.findall(r'^\s+"([^"]+)",\s*$', GATE_HOSTS_SWIFT.read_text(), re.M)


def summary(files: dict[str, dict[str, int]]) -> dict:
    by_lang: dict[str, int] = {}
    for rel, forms in files.items():
        lang = Path(rel).suffix.lstrip(".")
        by_lang[lang] = by_lang.get(lang, 0) + sum(forms.values())
    return {"ungated": sum(by_lang.values()), "file_count": len(files), "by_language": dict(sorted(by_lang.items()))}


def write(found: dict[str, dict[str, int]]) -> None:
    GATE_HOSTS.write_text(gate_hosts_text(DOC.read_text()))
    UNGATED.write_text(json.dumps({
        "about": "Outbound sites in cmux NEXT that do not go through the egress gate. Only shrinks; "
                 "tests/test_egress_gate.py keeps it exact.",
        **summary(found), "files": found}, indent=1) + "\n")


class EgressGate(unittest.TestCase):
    def test_no_new_ungated_site(self):
        bad = problems(scan(), load())
        self.assertFalse(bad, "\n" + "\n".join(bad))

    def test_the_gate_lets_through_exactly_the_doc_hosts(self):
        self.assertEqual(GATE_HOSTS.read_text(), gate_hosts_text(DOC.read_text()),
                         "cmux-egress/hosts.txt differs from docs/privacy.md's connects rows: run --write")

    def test_the_swift_gate_lets_through_exactly_the_doc_hosts(self):
        rows, _ = listed(DOC.read_text())
        want = sorted(h for h, (kind, _) in rows.items() if kind == "connects")
        self.assertEqual(swift_gate_hosts(), want,
                         "CmuxEgress/EgressHosts.swift differs from docs/privacy.md's connects rows: edit it to match "
                         "(it is hand-kept, sorted, one host per line)")

    def test_the_counts_are_the_sum(self):
        data = json.loads(UNGATED.read_text())
        self.assertEqual({k: data.get(k) for k in ("ungated", "file_count", "by_language")}, summary(data["files"]),
                         "tests/egress_ungated.json's totals are stale: run --write")


class Matcher(unittest.TestCase):
    def test_forms_are_found(self):
        rs = ('let a = reqwest::Client::builder().build();\nlet b = reqwest::blocking::Client::new();\n'
              'let c = Client::builder().build();\nlet d = reqwest::get(u);\nconnect_async(req);\n'
              'cmux_egress::ws::connect_async(req, "s");\ncmux_egress::client_builder("s");\n')
        self.assertEqual(sites_in(rs, "cmux-tui/crates/x/src/a.rs"),
                         {"reqwest-client": 2, "client-builder": 1, "reqwest-get": 1, "ws-connect": 1})
        sw = ('let s = URLSession(configuration: c)\nURLSession.shared.data(for: r)\nNWConnection(to: e, using: p)\n'
              'session.webSocketTask(with: u)\n')
        self.assertEqual(sites_in(sw, "Packages/macOS/CmuxNext/Sources/X/A.swift"),
                         {"urlsession": 1, "urlsession-shared": 1, "nwconnection": 1, "websocket-task": 1})
        # The shared session by its short name: a defaulted parameter, a stored property, an argument.
        sw = ('init(session: URLSession = .shared) {}\nvar session: URLSession = .shared\n'
              'func f(session: sending URLSession = .shared) {}\nlet c = Client(session: .shared)\n')
        self.assertEqual(sites_in(sw, "Packages/macOS/CmuxNext/Sources/X/A.swift"),
                         {"urlsession-default": 3, "urlsession-shared-arg": 1})
        # The initializer split over lines.
        sw = 'session = URLSession(\n    configuration: c,\n    delegate: d,\n    delegateQueue: nil\n)\n'
        self.assertEqual(sites_in(sw, "Packages/macOS/CmuxNext/Sources/X/A.swift"), {"urlsession": 1})

    def test_comments_and_test_modules_are_skipped(self):
        self.assertEqual(sites_in("// reqwest::Client::new()\n#[cfg(test)]\nmod tests {\n fn t() { "
                                  "reqwest::Client::new(); }\n}\n", "cmux-tui/crates/x/src/a.rs"), {})
        self.assertEqual(sites_in("/* URLSession.shared */\n", "Packages/Shared/X/A.swift"), {})

    def test_exactness_both_ways(self):
        self.assertEqual(len(problems({"a.rs": {"ureq": 2}}, {"a.rs": {"ureq": 1}})), 1)
        self.assertEqual(len(problems({}, {"a.rs": {"ureq": 1}})), 1)
        self.assertEqual(problems({"a.rs": {"ureq": 1}}, {"a.rs": {"ureq": 1}}), [])


if __name__ == "__main__":
    if "--write" in sys.argv:
        write(scan())
        print(json.dumps(summary(load())))
    elif "--json" in sys.argv:
        print(json.dumps(summary(load())))
    else:
        unittest.main()
