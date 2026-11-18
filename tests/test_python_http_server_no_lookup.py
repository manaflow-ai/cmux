#!/usr/bin/env python3
"""Tracked Python never looks up its own address by reverse DNS: http.server binds without it, no bare getfqdn().

Failure class: a fleet desktop's console showed the system's Local Network prompt, `Allow "Python" to find
devices on local networks?`. The system log named the caller:

    mDNSResponder: [com.apple.mdns:trust] Local network access to query(<private>) policy 'denied' for (org.python.python).

The process was a python3 running a test-only HTTP server bound to 127.0.0.1. It never talks to the LAN:
`http.server.HTTPServer.server_bind` calls `socket.getfqdn(host)`, a `gethostbyaddr` reverse (PTR) query, on
every bind, and the system counts that query as local network access by the interpreter's app bundle. The first
such query from a bundle asks the person at the console, and no grant can be pre-set. `ThreadingHTTPServer` and
wsgiref's `WSGIServer` inherit the same bind.

The lookup buys nothing: it only fills `server_name`, which handlers use for CGI's SERVER_NAME and wsgiref's
environ. The bind address is a correct value for both.

Fix: each file sets the one-line PRELUDE below at module level, after its imports. It replaces the bind with
TCPServer's own and records the bind address as `server_name`, for every HTTPServer the process starts, on every
platform. A server that really needs LAN peers still binds and serves as before: this only drops the reverse
lookup of its own address.

This test fails when a tracked Python file names HTTPServer, ThreadingHTTPServer or WSGIServer (or imports
wsgiref.simple_server) without the PRELUDE (`--fix` inserts it), or calls `getfqdn()` itself (use
`socket.gethostname()`, which asks no resolver; a call that truly needs the lookup carries `# lan lookup needed`
on its line).

Usage: test_python_http_server_no_lookup.py [--fix]
"""

from __future__ import annotations

import ast
import subprocess
import sys
import tempfile
import textwrap
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SELF = Path(__file__).resolve().relative_to(ROOT).as_posix()

# One line, so a file's imports stay readable and --fix stays exact. `http.server` imports socketserver.
PRELUDE = (
    'import http.server as _hs; _hs.HTTPServer.server_bind = lambda s: (_hs.socketserver.TCPServer.server_bind(s), '
    'setattr(s, "server_name", str(s.server_address[0])), setattr(s, "server_port", s.server_address[1])) and None'
    "  # no reverse DNS on bind (Local Network prompt): tests/test_python_http_server_no_lookup.py"
)

# Trees that are not run: kept for reference only.
SKIPPED_TREES: tuple[str, ...] = ()

SERVER_NAMES = {"HTTPServer", "ThreadingHTTPServer", "WSGIServer"}
ALLOW_LOOKUP = "# lan lookup needed"


def uses_http_server(tree: ast.AST) -> bool:
    """A name, attribute or import of an http.server/wsgiref server class, or an import of wsgiref.simple_server."""
    for node in ast.walk(tree):
        if isinstance(node, ast.Name) and node.id in SERVER_NAMES:
            return True
        if isinstance(node, ast.Attribute) and node.attr in SERVER_NAMES:
            return True
        if isinstance(node, ast.ImportFrom):
            if node.module == "wsgiref.simple_server" or any(a.name in SERVER_NAMES for a in node.names):
                return True
        if isinstance(node, ast.Import) and any(a.name == "wsgiref.simple_server" for a in node.names):
            return True
    return False


def getfqdn_lines(tree: ast.AST, lines: list[str]) -> list[int]:
    """1-based lines that call getfqdn (socket.getfqdn(...) or an imported getfqdn(...)) without ALLOW_LOOKUP."""
    found = []
    for node in ast.walk(tree):
        if not isinstance(node, ast.Call):
            continue
        func = node.func
        if (isinstance(func, ast.Attribute) and func.attr == "getfqdn") or \
                (isinstance(func, ast.Name) and func.id == "getfqdn"):
            line = lines[node.lineno - 1] if node.lineno <= len(lines) else ""
            if ALLOW_LOOKUP not in line:
                found.append(node.lineno)
    return sorted(found)


def has_prelude(lines: list[str]) -> bool:
    return any(line.rstrip("\n") == PRELUDE for line in lines)


def tracked_python() -> list[str]:
    out = subprocess.run(["git", "-C", str(ROOT), "ls-files", "-z", "--", "*.py"],
                         check=True, capture_output=True).stdout.decode()
    return [p for p in out.split("\0") if p and not p.startswith(SKIPPED_TREES) and p != SELF]


def parse(path: Path) -> tuple[list[str], ast.Module] | None:
    try:
        text = path.read_text(encoding="utf-8")
        return text.splitlines(keepends=True), ast.parse(text)
    except (OSError, UnicodeDecodeError, SyntaxError, ValueError):
        return None  # not Python 3 source (a template, a fixture): nothing runs it


def scan() -> tuple[list[str], list[str]]:
    """(files that start a server without the PRELUDE, `path:line` of each bare getfqdn call)."""
    missing: list[str] = []
    lookups: list[str] = []
    for rel in tracked_python():
        path = ROOT / rel
        if path.is_symlink() or not path.is_file():
            continue
        parsed = parse(path)
        if not parsed:
            continue
        lines, tree = parsed
        if uses_http_server(tree) and not has_prelude(lines):
            missing.append(rel)
        lookups.extend(f"{rel}:{n}" for n in getfqdn_lines(tree, lines))
    return missing, lookups


def insertion_line(tree: ast.Module) -> int:
    """0-based line after the module's leading docstring and imports (the prelude needs only to be top level and run
    before any server binds, which a file does after its imports)."""
    at = 0
    for index, node in enumerate(tree.body):
        docstring = index == 0 and isinstance(node, ast.Expr) and isinstance(node.value, ast.Constant) \
            and isinstance(node.value.value, str)
        if not (docstring or isinstance(node, (ast.Import, ast.ImportFrom))):
            break
        at = node.end_lineno or at
    return at


def fix(path: Path) -> None:
    parsed = parse(path)
    if not parsed or has_prelude(parsed[0]):
        return
    lines, tree = parsed
    at = insertion_line(tree)
    if at == 0 and lines and lines[0].startswith("#!"):
        at = 1
    if at and at <= len(lines) and not lines[at - 1].endswith("\n"):
        lines[at - 1] += "\n"
    lines[at:at] = [PRELUDE + "\n"]
    path.write_text("".join(lines), encoding="utf-8")


def bind_lookups(prelude: bool, server: str) -> tuple[int, str]:
    """Bind SERVER on 127.0.0.1 in a fresh interpreter, counting gethostbyaddr calls; (calls, server_name)."""
    script = textwrap.dedent(f"""
        import socket, http.server, wsgiref.simple_server
        calls = []
        real = socket.gethostbyaddr
        socket.gethostbyaddr = lambda name: (calls.append(name), real(name))[1]
        {PRELUDE if prelude else ""}
        server = {server}(("127.0.0.1", 0), http.server.BaseHTTPRequestHandler)
        server.server_close()
        print(len(calls), server.server_name)
    """)
    with tempfile.TemporaryDirectory() as tmp:
        out = subprocess.run([sys.executable, "-I", "-c", script], cwd=tmp, check=True, capture_output=True,
                             text=True, timeout=60).stdout.split()
    return int(out[0]), out[1]


class HttpServerNoLookupTest(unittest.TestCase):
    def test_every_http_server_file_sets_the_prelude(self):
        missing, _ = scan()
        self.assertEqual(
            missing, [],
            "These Python files start an http.server/wsgiref server whose bind does a reverse DNS lookup, which the "
            "system counts as local network access (a console prompt).\n"
            f"Run `python3 {SELF} --fix`, or add after the file's imports:\n{PRELUDE}\n\n" + "\n".join(missing))

    def test_no_bare_getfqdn(self):
        _, lookups = scan()
        self.assertEqual(
            lookups, [],
            "getfqdn() is a reverse DNS lookup of this host, which the system counts as local network access (a "
            f"console prompt). Use socket.gethostname(), or mark a call that truly needs it `{ALLOW_LOOKUP}`.\n"
            + "\n".join(lookups))

    def test_stock_bind_does_a_reverse_lookup_and_the_prelude_removes_it(self):
        for server in ("http.server.HTTPServer", "http.server.ThreadingHTTPServer",
                       "wsgiref.simple_server.WSGIServer"):
            with self.subTest(server=server):
                calls, _ = bind_lookups(False, server)
                self.assertGreater(calls, 0, "the stock bind no longer looks itself up: this guard can go")
                self.assertEqual(bind_lookups(True, server), (0, "127.0.0.1"))

    def test_detector(self):
        for text in ("from http.server import ThreadingHTTPServer", "import http.server\nhttp.server.HTTPServer",
                     "from wsgiref.simple_server import make_server", "import wsgiref.simple_server",
                     "class S(HTTPServer): pass"):
            self.assertTrue(uses_http_server(ast.parse(text)), text)
        for text in ("import socketserver\nsocketserver.TCPServer", "x = 'HTTPServer'", "# HTTPServer"):
            self.assertFalse(uses_http_server(ast.parse(text)), text)

    def test_getfqdn_detector(self):
        for text, want in (("import socket\nsocket.getfqdn()", [2]), ("from socket import getfqdn\ngetfqdn('x')", [2]),
                           (f"import socket\nsocket.getfqdn()  {ALLOW_LOOKUP}: dials LAN peers", []),
                           ("import socket\nsocket.gethostname()", []), ("x = 'socket.getfqdn()'", [])):
            self.assertEqual(getfqdn_lines(ast.parse(text), text.splitlines(keepends=True)), want, text)

    def test_fix_inserts_once_after_docstring_and_imports(self):
        source = '#!/usr/bin/env python3\n"""Doc."""\nfrom __future__ import annotations\nimport http.server\n\n' \
                 'def main():\n    http.server.HTTPServer(("127.0.0.1", 0), None)\n'
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "s.py"
            path.write_text(source)
            fix(path)
            fix(path)
            lines = path.read_text().splitlines()
            self.assertEqual(lines[4], PRELUDE)
            self.assertEqual(sum(line == PRELUDE for line in lines), 1)
            ast.parse(path.read_text())


if __name__ == "__main__":
    if sys.argv[1:] == ["--fix"]:
        for rel in scan()[0]:
            fix(ROOT / rel)
            print(f"fixed {rel}")
        sys.exit(0)
    unittest.main()
