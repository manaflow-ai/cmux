"""Every Python read of a CDN-fronted host of ours sends its own User-Agent.

The CDN in front of gh-events.cmux.com, files.cmux.com, files-next.cmux.com, presence.cmux.dev and the *.workers.dev
routes answers Python's default User-Agent ("Python-urllib/3.x") with HTTP 403 and the body "error code: 1010" (a
refused client signature) before the request reaches the service; curl's, an empty one or any honest tool name gets
through. A script that reads one of them with a bare urlopen(url) fails on every run while curl works.
2026-11-09: base_red_excuse.py's compile receipt reads (cmux#39629). 2026-11-10: scripts/cmux-next/cli-swap.py
fetched files.cmux.com with a bare urlopen, so it could never fetch a CLI; the synthetic probe of gh-events failed
three runs in a row the same way.

Each Python file of this repo (tests aside) that names one of those hosts, or names a JSON file that does, must
open URLs with a urllib.request.Request carrying a User-Agent:
- a bare urlopen(...)/urlretrieve(...) whose first argument is not a Request with one (or a name assigned one in the
  same function) fails;
- a Request whose headers this check cannot read (a name, a call) passes only in a file that names a User-Agent
  somewhere.
A call that never reaches those hosts (GitHub's API, a presigned R2 URL, loopback) says so with
`# user-agent: <why>` on its line or the comment line just above it.

FaultInjection runs the real readers against a loopback fake of the CDN that answers 403 "error code: 1010" to
Python-urllib's User-Agent and 200 to any other.
"""
import ast
import contextlib
import http.server
import importlib.util
import json
import subprocess
import threading
import unittest
import urllib.error
import urllib.request
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]
HOSTS = ("gh-events.cmux.com", "files.cmux.com", "files-next.cmux.com", "presence.cmux.dev", "workers.dev")
OPENERS = {"urlopen", "urlretrieve"}
MARK = "# user-agent:"
PYTHON_DEFAULT_AGENT = "Python-urllib/"
REFUSAL_BODY = b"error code: 1010"


def tracked(suffix: str) -> list[Path]:
    names = subprocess.run(["git", "-C", str(ROOT), "ls-files", "-z", f"*{suffix}"], capture_output=True,
                           check=True).stdout.decode().split("\0")
    out = []
    for name in filter(None, names):
        path = ROOT / name
        parts = Path(name).parts
        if parts[0] in ("tests", "tests_v2") or "node_modules" in parts or path.name.startswith("test_") \
                or path.name.endswith("_test.py"):
            continue
        out.append(path)
    return out


def read(path: Path) -> str:
    try:
        return path.read_text(errors="replace")
    except OSError:
        return ""


def config_names() -> set[str]:
    """JSON files of this repo that name a CDN host: a URL that reaches Python from one is a read of that host."""
    return {p.name for p in tracked(".json") if any(host in read(p) for host in HOSTS)}


def cdn_files():
    configs = config_names()
    for path in tracked(".py"):
        text = read(path)
        if any(host in text for host in HOSTS) or any(f'"{n}"' in text or f"'{n}'" in text for n in configs):
            yield path, text


def is_request(node) -> bool:
    if not isinstance(node, ast.Call):
        return False
    func = node.func
    return (isinstance(func, ast.Attribute) and func.attr == "Request") or (isinstance(func, ast.Name)
                                                                            and func.id == "Request")


def request_headers(request: ast.Call):
    headers = next((k.value for k in request.keywords if k.arg == "headers"), None)
    if headers is None and len(request.args) >= 3:
        headers = request.args[2]
    return headers


def names_agent(request: ast.Call) -> bool:
    """Whether a Request(...) may set a User-Agent: a dict literal with the key (or a ** spread), or headers this
    check cannot read (unread_headers holds those to the file naming one). No headers, or a literal without the key,
    sends Python-urllib's."""
    headers = request_headers(request)
    if headers is None:
        return False
    if not isinstance(headers, ast.Dict):
        return True
    keys = [k.value.lower() for k in headers.keys if isinstance(k, ast.Constant) and isinstance(k.value, str)]
    return "user-agent" in keys or None in headers.keys


def marked(lines: list[str], lineno: int) -> bool:
    return MARK in lines[lineno - 1] or (lineno >= 2 and lines[lineno - 2].strip().startswith(MARK))


def bare_opens(text: str) -> list[int]:
    """Lines of urlopen/urlretrieve calls whose first argument is not a Request naming a User-Agent, unmarked."""
    tree, lines, out = ast.parse(text), text.splitlines(), []
    for scope in (n for n in ast.walk(tree) if isinstance(n, (ast.Module, ast.FunctionDef, ast.AsyncFunctionDef))):
        requests = {t.id for n in ast.walk(scope) if isinstance(n, ast.Assign) and is_request(n.value)
                    and names_agent(n.value) for t in n.targets if isinstance(t, ast.Name)}
        for n in ast.walk(scope):
            if not (isinstance(n, ast.Call) and n.args):
                continue
            name = n.func.attr if isinstance(n.func, ast.Attribute) else getattr(n.func, "id", "")
            if name not in OPENERS:
                continue
            arg = n.args[0]
            if (is_request(arg) and names_agent(arg)) or (isinstance(arg, ast.Name) and arg.id in requests):
                continue
            if not marked(lines, n.lineno):
                out.append(n.lineno)
    return sorted(set(out))


def unread_headers(text: str) -> list[int]:
    """Lines of Request(...) calls with headers this check cannot read, unmarked, in a file naming no User-Agent."""
    if "user-agent" in text.lower():
        return []
    tree, lines = ast.parse(text), text.splitlines()
    return sorted({n.lineno for n in ast.walk(tree) if is_request(n) and request_headers(n) is not None
                   and names_agent(n) and not marked(lines, n.lineno)})


class CdnRefusal(http.server.BaseHTTPRequestHandler):
    """The CDN's refusal, on loopback: Python-urllib's User-Agent (or none) gets 403 "error code: 1010", any other
    gets 200 with ANSWER."""
    ANSWER = b"{}"
    agents: list = []

    def do_GET(self):  # noqa: N802 - http.server's name
        agent = self.headers.get("User-Agent") or ""
        type(self).agents.append(agent)
        code, body = (403, REFUSAL_BODY) if not agent or agent.startswith(PYTHON_DEFAULT_AGENT) else (200, self.ANSWER)
        self.send_response(code)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *args):
        pass


@contextlib.contextmanager
def fake_cdn(answer: bytes = b"{}"):
    CdnRefusal.agents, CdnRefusal.ANSWER = [], answer
    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), CdnRefusal)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        yield f"http://127.0.0.1:{server.server_address[1]}"
    finally:
        server.shutdown()
        server.server_close()
        thread.join(5)


def load(relative: str, name: str):
    spec = importlib.util.spec_from_file_location(name, ROOT / relative)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class CdnUserAgent(unittest.TestCase):
    def test_every_read_of_a_cdn_host_sends_a_user_agent(self):
        found, unread = [], []
        for path, text in cdn_files():
            try:
                found += [f"{path.relative_to(ROOT)}:{line}" for line in bare_opens(text)]
                unread += [f"{path.relative_to(ROOT)}:{line}" for line in unread_headers(text)]
            except SyntaxError:
                continue
        self.assertEqual(found, [], "a bare urlopen in a file that reads a CDN host (HOSTS): open a "
                                    "urllib.request.Request with a User-Agent of the script's own, or mark the line "
                                    f"`{MARK} <why>` when it never reaches those hosts")
        self.assertEqual(unread, [], "a Request whose headers come from elsewhere, in a file that reads a CDN host "
                                     f"and never names a User-Agent: add one, or mark the line `{MARK} <why>`")

    def test_the_known_readers_are_in_scope(self):
        scoped = {str(p.relative_to(ROOT)) for p, _ in cdn_files()}
        for path in ("scripts/ci/base_red_excuse.py", "scripts/cmux-next/cli-swap.py"):
            self.assertIn(path, scoped)

    def test_the_detector_sees_a_bare_read_and_passes_a_named_request(self):
        bare = "import urllib.request\ndef f(url):\n    return urllib.request.urlopen(url, timeout=5)\n"
        self.assertEqual(bare_opens(bare), [3])
        named = ("import urllib.request\ndef f(url):\n"
                 "    req = urllib.request.Request(url, headers={'User-Agent': 'x/1'})\n"
                 "    return urllib.request.urlopen(req)\n")
        self.assertEqual(bare_opens(named), [])
        no_agent = ("from urllib.request import Request, urlopen\nurlopen(Request('u'))\n"
                    "urlopen(Request('u', headers={'Accept': 'x'}))\nr = Request('u')\nurlopen(r)\n")
        self.assertEqual(bare_opens(no_agent), [2, 3, 5])
        self.assertEqual(bare_opens("import urllib.request\nurllib.request.urlopen(u)  # user-agent: R2\n"), [])
        self.assertEqual(bare_opens("import urllib.request\n# user-agent: R2\nurllib.request.urlopen(u)\n"), [])
        unnamed = ("import urllib.request\ndef get(url, headers):\n"
                   "    return urllib.request.urlopen(urllib.request.Request(url, headers=headers))\n")
        self.assertEqual(unread_headers(unnamed), [3])
        self.assertEqual(unread_headers("UA = {'User-Agent': 'x/1'}\n" + unnamed), [])


class FaultInjection(unittest.TestCase):
    """The real readers against a fake CDN that refuses Python-urllib's User-Agent the way the zone does."""

    def test_the_fake_refuses_the_default_and_answers_a_named_client(self):
        with fake_cdn() as base:
            with self.assertRaises(urllib.error.HTTPError) as refused:
                urllib.request.urlopen(base + "/x", timeout=5)
            self.assertEqual((refused.exception.code, refused.exception.read()), (403, REFUSAL_BODY))
            with urllib.request.urlopen(urllib.request.Request(base + "/x", headers={"User-Agent": "t/1"}),
                                        timeout=5) as answer:
                self.assertEqual(answer.status, 200)

    def test_base_red_excuse_reads_a_compile_receipt_through_the_cdn(self):
        excuse = load("scripts/ci/base_red_excuse.py", "cdn_base_red_excuse")
        repo, sha = "manaflow-ai/cmux", "a" * 40
        receipt = {"repo": repo, "sha": sha, "state": "pass", "recipe_version": 2, "configuration": "release-onone"}
        with fake_cdn(json.dumps(receipt).encode()) as base, \
                mock.patch.object(excuse, "COMPILE_RECEIPTS", base + "/compile-checks/v1"):
            self.assertEqual(excuse.compile_receipt(repo, sha)["state"], "pass")
            self.assertFalse(CdnRefusal.agents[-1].startswith(PYTHON_DEFAULT_AGENT))
            # The same read with urllib's default: refused at the edge, said so, and never "the host is down".
            with mock.patch.object(excuse, "COMPILE_RECEIPT_USER_AGENT", "Python-urllib/3.12"), \
                    self.assertRaises(excuse.Refused) as refused:
                excuse.compile_receipt(repo, sha)
        self.assertNotIsInstance(refused.exception, excuse.ReceiptUnreachable)
        self.assertIn("the CDN refused this reader's signature", str(refused.exception))

    def test_cli_swap_fetches_through_the_cdn(self):
        swap = load("scripts/cmux-next/cli-swap.py", "cdn_cli_swap")
        with fake_cdn(b"cli bytes") as base:
            self.assertEqual(swap.fetch(base + "/cmux-tui/tree/k/cmux"), b"cli bytes")
        self.assertEqual(CdnRefusal.agents, [swap.USER_AGENT])


if __name__ == "__main__":
    unittest.main()
