#!/usr/bin/env python3
"""Egress gate guard: every outbound connection cmux NEXT opens goes through the egress gate.

The gate's allowlist (cmux-tui/crates/cmux-egress/hosts.txt, each host with what the app sends there) is the one
source: the Rust gate compiles it in, the Swift gate's EgressHosts.swift must equal it, and docs/privacy.md's
"The app connects to" table is generated from it (scripts/privacy_hosts_from_gate.py), so the doc cannot drift from
what the gate lets through. tests/test_outbound_hosts.py keeps the doc exact against the code at CI time. The gate
enforces it at run time: in nightly and dev builds a connection to a host with no `connects` row is
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

On a pull request (CMUX_GUARDS_BASE_SHA set) it reads only the files the change touched, at the base and at the
head (tests/guard_delta.py), plus every file whose entry in egress_ungated.json the change edited, and reports the
problems those files have at the head that they did not have at the base. A site is counted in its own file, so
nothing else can change. A change to RULES scans everything, as does a branch's own run.

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
import guard_delta  # noqa: E402
from test_classic_cloud_routes import clean, in_scope  # noqa: E402
from test_outbound_hosts import DOC, SCAN  # noqa: E402

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts"))
import privacy_hosts_from_gate as gate_doc  # noqa: E402

ROOT = Path(__file__).resolve().parents[1]
UNGATED = ROOT / "tests" / "egress_ungated.json"
# A change to one of these scans everything: this guard and the scope it borrows (guard_delta.py adds itself).
RULES = ["tests/test_egress_gate.py", "tests/test_classic_cloud_routes.py", "tests/test_outbound_hosts.py"]
# The gate's own sources: the only place a raw client may be made (Rust: cmux-egress; Swift: CmuxEgress).
GATES: tuple[str, ...] = ("cmux-tui/crates/cmux-egress/", "Packages/Shared/CmuxEgress/Sources/")
# The allowlist: the `connects` hosts the Rust gate lets through, each with what the app sends there. The source
# docs/privacy.md's connects table is generated from (scripts/privacy_hosts_from_gate.py).
GATE_HOSTS = gate_doc.HOSTS
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


def scanned(rel: str) -> bool:
    """Whether the scan reads this file: a Rust or Swift source in SCAN, not the gate's own."""
    return Path(rel).suffix in COMPILED and in_scope(rel, SCAN) and not rel.startswith(GATES or ("\0",))


def found_in(texts: dict[str, str]) -> dict[str, dict[str, int]]:
    found: dict[str, dict[str, int]] = {}
    for rel in sorted(texts):
        got = sites_in(texts[rel], rel)
        if got:
            found[rel] = dict(sorted(got.items()))
    return found


def scan(root: Path = ROOT) -> dict[str, dict[str, int]]:
    """{file: {form: count}} for every ungated outbound site in NEXT's source."""
    p = subprocess.run(["git", "-C", str(root), "ls-files", "-z", "--", *SCAN["include"]], capture_output=True)
    if p.returncode != 0:
        raise RuntimeError(p.stderr.decode(errors="replace"))
    rels = [r for r in p.stdout.decode().split("\0") if r and scanned(r)]
    return found_in(guard_delta.text_at_head(rels, root, errors="replace"))


def change_problems(base: str, paths: list[str], listed: dict[str, dict[str, int]],
                    root: Path = ROOT) -> list[str] | None:
    """The problems the change since `base` added: the touched files and the files whose list entry it edited,
    read at the base and at the head. None when the base's list cannot be read (scan everything)."""
    rel_list = UNGATED.relative_to(ROOT).as_posix()
    base_text = guard_delta.blobs_at(base, [rel_list], root).get(rel_list)
    if base_text is None:
        return None
    base_listed = json.loads(base_text)["files"]
    edited = {r for r in set(listed) | set(base_listed) if listed.get(r) != base_listed.get(r)}
    rels = sorted({p for p in paths if scanned(p)} | edited)
    head = problems(found_in(guard_delta.text_at_head(rels, root, errors="replace")),
                    {r: listed[r] for r in rels if r in listed})
    was = set(problems(found_in(guard_delta.blobs_at(base, rels, root, errors="replace")),
                       {r: base_listed[r] for r in rels if r in base_listed}))
    return [p for p in head if p not in was]


def check(root: Path = ROOT, listed: dict[str, dict[str, int]] | None = None) -> list[str]:
    """The ungated-site problems: on a pull request the change's own, else the whole tree's."""
    listed = load(root / UNGATED.relative_to(ROOT)) if listed is None else listed
    base = guard_delta.base_commit(root)
    paths = guard_delta.changed(RULES, root, base) if base else None
    if base and paths is not None:
        got = change_problems(base, paths, listed, root)
        if got is not None:
            guard_delta.note("egress gate", base, paths)
            return got
    return problems(scan(root), listed)


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


def gate_hosts() -> list[str]:
    """The allowlist's hosts, in file order."""
    return [row.host for row in gate_doc.read_hosts(GATE_HOSTS.read_text())]


def swift_gate_hosts() -> list[str]:
    """The hosts EgressHosts.swift (hand-kept data, no generated header) lists, in file order."""
    return re.findall(r'^\s+"([^"]+)",\s*$', GATE_HOSTS_SWIFT.read_text(), re.M)


def connects_outside_table(doc: str) -> list[str]:
    """`connects` rows written by hand outside the generated table: every one belongs in hosts.txt."""
    start, end = doc.find("<!-- egress-hosts:begin"), doc.find(gate_doc.END)
    outside = doc[:start] + doc[end:]
    return re.findall(r"^\|\s*`([^`]+)`\s*\|\s*connects\s*\|", outside, re.M)


def summary(files: dict[str, dict[str, int]]) -> dict:
    by_lang: dict[str, int] = {}
    for rel, forms in files.items():
        lang = Path(rel).suffix.lstrip(".")
        by_lang[lang] = by_lang.get(lang, 0) + sum(forms.values())
    return {"ungated": sum(by_lang.values()), "file_count": len(files), "by_language": dict(sorted(by_lang.items()))}


def write(found: dict[str, dict[str, int]]) -> None:
    UNGATED.write_text(json.dumps({
        "about": "Outbound sites in cmux NEXT that do not go through the egress gate. Only shrinks; "
                 "tests/test_egress_gate.py keeps it exact.",
        **summary(found), "files": found}, indent=1) + "\n")


class EgressGate(unittest.TestCase):
    def test_no_new_ungated_site(self):
        bad = check()
        self.assertFalse(bad, "\n" + "\n".join(bad))

    def test_the_allowlist_is_sorted_and_described(self):
        hosts = gate_hosts()  # raises on a host with no description or listed twice
        self.assertEqual(hosts, sorted(hosts), "cmux-egress/hosts.txt: keep the hosts sorted")

    def test_a_row_missing_sends_when_or_off_fails(self):
        whole = "# the API\n# sends: a\n# when: b\n# off: c\napi.cmux.dev\n"
        self.assertEqual(gate_doc.read_hosts(whole)[0].off, "c")
        for key in gate_doc.FIELDS:
            short = "".join(line + "\n" for line in whole.splitlines() if not line.startswith(f"# {key}:"))
            with self.assertRaisesRegex(ValueError, f"no `# {key}:`"):
                gate_doc.read_hosts(short)

    def test_the_doc_is_generated_from_the_allowlist(self):
        doc = DOC.read_text()
        self.assertEqual(doc, gate_doc.render(doc, gate_doc.read_hosts(GATE_HOSTS.read_text())),
                         "docs/privacy.md's connects table differs from cmux-egress/hosts.txt (the source): edit "
                         "hosts.txt, then run python3 scripts/privacy_hosts_from_gate.py")
        self.assertEqual(gate_doc.main(["--check"]), 0)

    def test_the_swift_gate_lets_through_exactly_the_allowlist(self):
        self.assertEqual(swift_gate_hosts(), sorted(gate_hosts()),
                         "CmuxEgress/EgressHosts.swift differs from cmux-egress/hosts.txt: edit it to match "
                         "(it is hand-kept, sorted, one host per line)")

    def test_a_connects_row_outside_the_generated_table_fails(self):
        doc = DOC.read_text()
        end = doc.index(gate_doc.END) + len(gate_doc.END)
        hand = doc[:end] + "\n| `stray.cmux.dev` | connects | x |\n" + doc[end:]
        self.assertEqual(connects_outside_table(hand), ["stray.cmux.dev"])
        self.assertEqual(connects_outside_table(doc), [])

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
