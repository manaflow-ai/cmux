#!/usr/bin/env python3
"""Outbound host guard: every host name in cmux NEXT's code is listed in docs/privacy.md.

docs/privacy.md is the one list of the hosts the NEXT app talks to (Leo, 2026-11-08: "Every conceivable possible
aspect of the app, and also in how we do the app, and just that, like how we work, how we look like to other
people"). Each host is a table row `| `host` | kind | what for |`, with kind one of KINDS:

  connects     the app (the Mac app, its daemon, its web pages or the iPhone app) opens a connection to it
  opens        a page shown only when a person opens it: a link, a search engine, a sign-in page, a site suggestion
  identifier   a name the app compares or writes, never fetches: an XML namespace, a JSON schema id, a domain list
  example      a sample, placeholder or mock value in shipping code; the app does not contact it
  not-a-host   a string that only looks like a host name: a file name, a bundle id, a symbol name

The scan reads NEXT's source (SCAN, minus test, mock and fixture files and Rust #[cfg(test)] modules, the same
rules as tests/test_classic_cloud_routes.py) with comments blanked, and finds two forms:

  url    a URL's host: "https://api.example.dev/x", `wss://${x}` has none, "https://KEY@host/1" gives host
  bare   a string literal that is a lowercase host name and nothing else ("presence.cmux.dev", "ssh.github.com"),
         ending in one of BARE_TLDS and not starting with one (a bundle id: "com.cmuxterm.app"); a host the code
         builds from parts is not seen (docs/privacy.md says so)

Reserved names (RFC 2606 and 6761: .example, .test, .invalid, .localhost, example.com), local names (.local, .lan,
.internal, .home.arpa) and IP addresses are never listed. The test fails when code names a host with no row (add
the row, saying what the app sends there), when a row's host is no longer in the code (remove it, so the list stays
exact), on a row with an unknown kind or no reason, and on a host listed twice.

Run it: python3 tests/test_outbound_hosts.py. List the hosts and where they are: python3 tests/test_outbound_hosts.py --print
"""

from __future__ import annotations

import re
import subprocess
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from test_classic_cloud_routes import clean, in_scope  # noqa: E402

ROOT = Path(__file__).resolve().parents[1]
DOC = ROOT / "docs" / "privacy.md"
KINDS = ("connects", "opens", "identifier", "example", "not-a-host")
SCAN = {
    "include": ["Packages/macOS/CmuxNext/", "Packages/Shared/", "cmux-tui/", "webviews/src/", "cmux-next-ios/"],
    # Servers and developer tools, not the app: relays and the iPhone push backend run on our side.
    "exclude": ["cmux-tui/relays/", "cmux-next-ios/backend/", "/tools/", "/src/bin/", "/benches/",
                "/typed_corpus.rs", "/hot_bench.rs", "/smoke.ts", "Fixture.swift", "/Mock", "/prototype/"],
}

LABEL = r"[a-z0-9](?:[a-z0-9-]*[a-z0-9])?"
URL = re.compile(rf"(?<![\w.+-])(?:https?|wss?)://(?:[^\s/@\"'`<>()\\]+@)?((?:{LABEL}\.)+{LABEL})(?![\w-])", re.I)
# Bare literals need a known TLD: any TLD would match thousands of string keys ("accounts.teams.new"). `.me`,
# `.in`, `.to`, `.run`, `.page`, `.link`, `.info`, `.one`, `.live` and `.cloud` are left out for that reason (string
# keys end in them); a host there is still found in URL form. Measured on feat-cmux-next 2026-11-08: this list adds
# one host (twitch.tv), ten public suffixes and one file name over the first twelve.
BARE_TLDS = ("com", "net", "org", "dev", "io", "ai", "app", "sh", "so", "gg", "co", "edu", "tv", "us", "uk", "de",
             "jp", "fr", "ca", "cn", "ru", "br", "gov", "xyz", "ly", "fm", "eu", "nl", "se", "ch", "au", "nz", "kr",
             "tw", "hk", "sg")
BARE = re.compile(rf"""(?<![\w\\])(["'`])((?:{LABEL}\.)+(?:{"|".join(BARE_TLDS)}))(?:\1|[/:])""")
RESERVED = re.compile(r"(^|\.)(example|test|invalid|localhost|local|lan|internal|home\.arpa)$"
                      r"|(^|\.)example\.(com|net|org)$|^\d+(\.\d+){3}$")
ROW = re.compile(r"^\|\s*`([^`]+)`\s*\|\s*([\w-]+)\s*\|\s*(.*?)\s*\|\s*$")
PREFILTER = ("://", *(f".{tld}" for tld in BARE_TLDS))


def hosts_in(text: str, rel: str) -> dict[str, list[int]]:
    """{host: [line, ...]} for one file's source, comments blanked."""
    code = clean(text, Path(rel).suffix)
    out: dict[str, list[int]] = {}

    def add(host: str, at: int) -> None:
        host = host.lower().rstrip(".")
        if not RESERVED.search(host):
            out.setdefault(host, []).append(code.count("\n", 0, at) + 1)

    for m in URL.finditer(code):
        add(m.group(1), m.start())
    for m in BARE.finditer(code):
        if m.group(2).split(".", 1)[0] not in BARE_TLDS:  # a reverse-DNS bundle id or log subsystem: com.cmuxterm.app
            add(m.group(2), m.start())
    return out


def candidate_files(root: Path) -> list[str]:
    argv = ["git", "-C", str(root), "grep", "-I", "-l", "-z", "-F"]
    for word in PREFILTER:
        argv += ["-e", word]
    p = subprocess.run([*argv, "--", *SCAN["include"]], capture_output=True)
    if p.returncode not in (0, 1):
        raise RuntimeError(p.stderr.decode(errors="replace"))
    return sorted(rel for rel in p.stdout.decode().split("\0") if rel and in_scope(rel, SCAN))


def scan(root: Path = ROOT) -> dict[str, dict[str, list[int]]]:
    """{host: {file: [line, ...]}} across NEXT's source."""
    found: dict[str, dict[str, list[int]]] = {}
    for rel in candidate_files(root):
        path = root / rel
        if path.is_symlink() or not path.is_file():
            continue
        try:
            text = path.read_text()
        except (UnicodeDecodeError, OSError):
            continue
        for host, lines in hosts_in(text, rel).items():
            found.setdefault(host, {})[rel] = lines
    return found


def listed(doc: str) -> tuple[dict[str, tuple[str, str]], list[str]]:
    """({host: (kind, reason)}, problems) from the doc's table rows."""
    rows: dict[str, tuple[str, str]] = {}
    bad = []
    for line in doc.splitlines():
        m = ROW.match(line)
        if not m:
            continue
        host, kind, reason = m.group(1).strip().lower(), m.group(2), m.group(3)
        if host in rows:
            bad.append(f"{host}: listed twice")
        if kind not in KINDS:
            bad.append(f"{host}: kind {kind!r} is not one of {', '.join(KINDS)}")
        if not reason:
            bad.append(f"{host}: say what the app sends there, or why it is not contacted")
        rows[host] = (kind, reason)
    return rows, bad


def problems(found: dict[str, dict[str, list[int]]], doc: str) -> list[str]:
    rows, out = listed(doc)
    for host, where in sorted(found.items()):
        if host not in rows:
            rel, lines = sorted(where.items())[0]
            more = f" (and {len(where) - 1} more files)" if len(where) > 1 else ""
            out.append(f"{host}: not in docs/privacy.md, named at {rel}:{lines[0]}{more}")
    for host in sorted(set(rows) - set(found)):
        out.append(f"{host}: listed in docs/privacy.md but no longer in NEXT's code; remove its row")
    return out


HOW = ("every host NEXT's code names has a row in docs/privacy.md: `| `host` | kind | what the app sends there |`, "
       f"kind one of {', '.join(KINDS)}")


class OutboundHosts(unittest.TestCase):
    def test_every_host_is_listed(self):
        bad = problems(scan(), DOC.read_text())
        self.assertEqual(bad, [], f"outbound host guard ({HOW}):\n  " + "\n  ".join(bad))

    def test_scanned_paths_exist(self):
        for prefix in SCAN["include"]:
            with self.subTest(prefix=prefix):
                hits = subprocess.run(["git", "-C", str(ROOT), "ls-files", "--", prefix + "*"],
                                      capture_output=True, text=True).stdout
                self.assertTrue(hits.strip(), f"{prefix} matches no tracked file")


class Matcher(unittest.TestCase):
    def hosts(self, source: str, rel: str = "Packages/macOS/CmuxNext/Sources/CmuxNextApp/X.swift") -> set[str]:
        return set(hosts_in(source, rel))

    def test_urls_and_bare_hosts_are_found(self):
        self.assertEqual(self.hosts('let u = URL(string: "https://api.cmux.dev/v1/x")'), {"api.cmux.dev"})
        self.assertEqual(self.hosts('static let host = "presence.cmux.dev"'), {"presence.cmux.dev"})
        self.assertEqual(self.hosts('let dsn = "https://abc123@o1.ingest.us.sentry.io/42"'), {"o1.ingest.us.sentry.io"})
        self.assertEqual(self.hosts("const ws = `wss://Relay.Chatmux.dev/socket`;", "webviews/src/a.ts"),
                         {"relay.chatmux.dev"})
        self.assertEqual(self.hosts('const HOSTS: [&str; 2] = ["ssh.github.com", "hf.co"];', "cmux-tui/x/src/a.rs"),
                         {"ssh.github.com", "hf.co"})
        self.assertEqual(self.hosts('export const TOP_SITES = ["twitch.tv", "bbc.co.uk"];', "webviews/src/a.ts"),
                         {"twitch.tv", "bbc.co.uk"})
        self.assertEqual(self.hosts('let u = "http://cmux-lawrences-mac-mini.tail137216.ts.net:31415"'),
                         {"cmux-lawrences-mac-mini.tail137216.ts.net"})

    def test_comments_reserved_names_and_non_hosts_are_skipped(self):
        for source in ('// see https://cmux.com/docs\nlet x = 1',
                       '/* https://api.cmux.dev */ let x = 1',
                       'let u = "https://api.example.com/v1"',
                       'let u = "https://evil.example/x"',
                       'let u = "http://localhost:3000"',
                       'let u = "http://127.0.0.1:7320"',
                       'let u = "http://nas.lan/share"',
                       'let u = "https://\\(host)/v1"',
                       'let f = "App.tsx"',
                       'let f = "build.rs"',
                       'let v = "1.2.3"',
                       'Logger(subsystem: "com.cmuxterm.app", category: "auth")'):
            with self.subTest(source=source):
                self.assertEqual(self.hosts(source), set())

    def test_rust_cfg_test_modules_are_skipped(self):
        source = ('const A: &str = "https://a.cmux.dev";\n#[cfg(test)]\nmod tests {\n'
                  '    const B: &str = "https://b.cmux.dev";\n}\n')
        self.assertEqual(set(hosts_in(source, "cmux-tui/crates/x/src/lib.rs")), {"a.cmux.dev"})

    def test_test_mock_and_server_files_are_out_of_scope(self):
        self.assertTrue(in_scope("Packages/macOS/CmuxNext/Sources/CmuxNextUpdater/ReleasePushListener.swift", SCAN))
        for rel in ("Packages/macOS/CmuxNext/Tests/CmuxNextAppTests/X.swift",
                    "Packages/macOS/CmuxNext/Sources/CmuxNextAgentPane/Mock/MockOutput.swift",
                    "Packages/macOS/CmuxNext/Sources/CmuxNextHome/McpConnect/McpConnectCardFixture.swift",
                    "webviews/src/a/b.test.ts",
                    "cmux-tui/relays/cloudflare-do/src/index.ts",
                    "cmux-next-ios/backend/src/push.ts"):
            with self.subTest(rel=rel):
                self.assertFalse(in_scope(rel, SCAN))

    def test_the_list_is_exact(self):
        doc = ("| Host | Kind | What for |\n|---|---|---|\n"
               "| `api.cmux.dev` | connects | the Cloud API |\n| `cmux.com` | opens | docs links |\n")
        found = {"api.cmux.dev": {"a.swift": [1]}, "cmux.com": {"b.swift": [2]}}
        self.assertEqual(problems(found, doc), [])
        self.assertTrue(any("not in docs/privacy.md" in p and "a.swift:9" in p
                            for p in problems({**found, "new.cmux.dev": {"a.swift": [9]}}, doc)))
        self.assertTrue(any("no longer in NEXT's code" in p for p in problems({"api.cmux.dev": {"a.swift": [1]}}, doc)))
        self.assertTrue(any("not one of" in p for p in problems(found, doc.replace("| opens |", "| linked |"))))
        self.assertTrue(any("say what" in p for p in problems(found, doc.replace("docs links", ""))))
        self.assertTrue(any("listed twice" in p for p in problems(found, doc + "| `cmux.com` | opens | again |\n")))


def print_hosts() -> None:
    for host, where in sorted(scan().items()):
        for rel, lines in sorted(where.items()):
            print(f"{host}\t{rel}\t{','.join(map(str, lines))}")


if __name__ == "__main__":
    if sys.argv[1:] == ["--print"]:
        print_hosts()
    else:
        unittest.main()
