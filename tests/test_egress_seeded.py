#!/usr/bin/env python3
"""Seeded-secret coverage: every egress gate site has a test that plants secrets and finds them in no request.

goals/privacy-runtime-egress-enforced.md (cmuxterm-hq) is done when "a seeded-secret CI test sends a planted
secret down every outbound payload path and finds it in none". The gate's sites are the `site` names code passes to
cmux-egress (`cmux_egress::client_builder("cmux_tui::owner_start::crash_forward")`, `ws::connect_async(r, "s")`).
With cmux-egress's `capture` feature, a test's gated clients send to a local TLS server that keeps each request
(cmux_egress::capture), so a test runs the real payload path and asserts `capture::leaks(secret)` is empty.

tests/egress_seeded.json maps every site to one of:
  {"test": "PATH::FN"}  a Rust test in PATH named FN that uses cmux_egress::capture;
  {"none": "why"}       the site carries no person data (a fixed probe, a public download);
  {"todo": true}        not seeded yet. Their count is `todo_max`, which may only go down: a new site needs a
                        test or a reason, never a todo.
The map stays exact both ways: a site that left the code fails until its row is removed.

Run it: python3 tests/test_egress_seeded.py. Counts: --json. Lower todo_max after seeding sites: --write.
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
from test_outbound_hosts import SCAN  # noqa: E402

ROOT = Path(__file__).resolve().parents[1]
SEEDED = ROOT / "tests" / "egress_seeded.json"
GATE = "cmux-tui/crates/cmux-egress/"
# cmux-mobile-link's `egress::http_client_builder(site)` (and `_with(site, resolver)`) wraps the gate's builder with the system proxy.
CALL = re.compile(r"\b(?:cmux_egress::(?:client_builder_with|client_builder|blocking_client_builder|client|get|"
                  r"ws::(?:connect_async_tls_with_config|connect_async_with_config|connect_async|checked))"
                  r"|(?:crate|cmux_mobile_link)::egress::http_client_builder(?:_with)?)\s*\(")
LITERAL = re.compile(r'"((?:[^"\\]|\\.)*)"')
SITE = re.compile(r"^[A-Za-z_][\w-]*(?:::[\w-]+)*$")


def call_args(text: str, open_paren: int) -> str:
    """The text between the call's parentheses (balanced, strings skipped)."""
    depth, i = 0, open_paren
    while i < len(text):
        c = text[i]
        if c == '"':
            m = LITERAL.match(text, i)
            i = m.end() if m else i + 1
            continue
        if c == "(":
            depth += 1
        elif c == ")":
            depth -= 1
            if depth == 0:
                return text[open_paren + 1:i]
        i += 1
    return text[open_paren + 1:]


def sites_in(text: str, rel: str) -> list[str]:
    """The site names one file's gate calls pass (test modules and comments left out)."""
    code = clean(text, Path(rel).suffix)
    out = []
    for m in CALL.finditer(code):
        names = [s for s in LITERAL.findall(call_args(code, m.end() - 1)) if SITE.match(s)]
        if names:
            out.append(names[-1])
    return out


def scan(root: Path = ROOT) -> dict[str, list[str]]:
    """{site: [files]} for every gate site in NEXT's Rust source."""
    p = subprocess.run(["git", "-C", str(root), "ls-files", "-z", "--", *SCAN["include"]], capture_output=True)
    if p.returncode != 0:
        raise RuntimeError(p.stderr.decode(errors="replace"))
    found: dict[str, list[str]] = {}
    for rel in sorted(r for r in p.stdout.decode().split("\0") if r):
        if not rel.endswith(".rs") or not in_scope(rel, SCAN) or rel.startswith(GATE):
            continue
        path = root / rel
        if path.is_symlink() or not path.is_file():
            continue
        for site in sites_in(path.read_text(encoding="utf-8", errors="replace"), rel):
            found.setdefault(site, [])
            if rel not in found[site]:
                found[site].append(rel)
    return found


def load(path: Path = SEEDED) -> dict:
    return json.loads(path.read_text())


def test_exists(ref: str, root: Path = ROOT) -> str | None:
    """None when PATH::FN names a test that uses the capture server, else why not."""
    rel, _, fn = ref.rpartition("::")
    path = root / rel
    if not rel or not path.is_file():
        return f"{ref}: no file {rel}"
    text = path.read_text(encoding="utf-8", errors="replace")
    found = re.search(rf"\bfn\s+{re.escape(fn)}\s*\(", text)
    if not found:
        return f"{ref}: {rel} has no fn {fn}"
    if not re.search(r"\bcapture::(leaks|requests|requests_to)\s*\(", fn_body(text, found.end())):
        return f"{ref}: fn {fn} never asks cmux_egress::capture what was sent (capture::leaks or capture::requests)"
    return None


def fn_body(text: str, start: int) -> str:
    """The text of the fn whose signature starts before START, from its first { to the matching }."""
    open_at = text.find("{", start)
    if open_at < 0:
        return ""
    depth = 0
    for i in range(open_at, len(text)):
        if text[i] == "{":
            depth += 1
        elif text[i] == "}":
            depth -= 1
            if depth == 0:
                return text[open_at:i + 1]
    return text[open_at:]


def problems(found: dict[str, list[str]], data: dict, root: Path = ROOT) -> list[str]:
    out = []
    rows = data["sites"]
    for site in sorted(set(found) - set(rows)):
        out.append(f"{site} ({', '.join(found[site])}): new gate site with no seeded test: add a test that plants "
                   "secrets and asserts cmux_egress::capture::leaks finds none, or a \"none\" reason, in "
                   "tests/egress_seeded.json")
    for site in sorted(set(rows) - set(found)):
        out.append(f"{site}: no longer in the code: remove its row from tests/egress_seeded.json")
    for site, row in sorted(rows.items()):
        kinds = [k for k in ("test", "none", "todo") if k in row]
        if len(kinds) != 1:
            out.append(f"{site}: needs exactly one of test, none, todo")
        elif "test" in row and (why := test_exists(row["test"], root)):
            out.append(f"{site}: {why}")
        elif "none" in row and len(str(row["none"]).strip()) < 12:
            out.append(f"{site}: a \"none\" row says why the site carries no person data")
    todo = sum(1 for row in rows.values() if row.get("todo"))
    if todo > data.get("todo_max", 0):
        out.append(f"{todo} todo sites > todo_max {data.get('todo_max', 0)}: a new site needs a seeded test or a "
                   "reason, not a todo")
    return out


def summary(data: dict) -> dict:
    rows = data["sites"].values()
    return {"sites": len(data["sites"]), "seeded": sum("test" in r for r in rows),
            "no_payload": sum("none" in r for r in rows), "todo": sum(bool(r.get("todo")) for r in rows)}


class EgressSeeded(unittest.TestCase):
    def test_every_site_is_seeded_or_reasoned(self):
        bad = problems(scan(), load())
        self.assertFalse(bad, "\n" + "\n".join(bad))


class Matcher(unittest.TestCase):
    def test_site_names_are_found(self):
        rs = ('let a = cmux_egress::client_builder("a::b").build();\n'
              'cmux_egress::ws::connect_async(format!("wss://{h}/x"), "c::ws").await;\n'
              'cmux_egress::client_builder_with(\n    "d",\n    resolver(),\n);\n'
              'crate::egress::http_client_builder_with("e::api", RouteResolve)\n'
              '// cmux_egress::client("commented")\n')
        self.assertEqual(sites_in(rs, "cmux-tui/crates/x/src/a.rs"), ["a::b", "c::ws", "d", "e::api"])

    def test_exact_both_ways_and_todo_only_shrinks(self):
        data = {"todo_max": 1, "sites": {"a": {"todo": True}, "gone": {"none": "a fixed public probe"}}}
        bad = problems({"a": ["x.rs"], "new": ["y.rs"]}, data)
        self.assertTrue(any(b.startswith("new ") for b in bad))
        self.assertTrue(any(b.startswith("gone:") for b in bad))
        data = {"todo_max": 0, "sites": {"a": {"todo": True}}}
        self.assertTrue(any("todo_max" in b for b in problems({"a": ["x.rs"]}, data)))

    def test_the_named_fn_itself_must_ask_capture(self):
        import tempfile
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / "t.rs").write_text(
                "fn helper() { let _ = capture::leaks(\"s\"); }\n"
                "#[test]\nfn seeded() {\n    let x = { 1 };\n    send(x);\n}\n"
                "#[test]\nfn checked() {\n    if true { send(1); }\n    assert!(capture::leaks(\"s\").is_empty());\n}\n")
            self.assertIn("never asks", test_exists("t.rs::seeded", root))
            self.assertIsNone(test_exists("t.rs::checked", root))


if __name__ == "__main__":
    if "--write" in sys.argv:
        data = load()
        data["todo_max"] = summary(data)["todo"]
        SEEDED.write_text(json.dumps(data, indent=1) + "\n")
        print(json.dumps(summary(data)))
    elif "--json" in sys.argv:
        print(json.dumps(summary(load())))
    else:
        unittest.main()
