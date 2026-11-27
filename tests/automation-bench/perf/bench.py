#!/usr/bin/env python3
"""Browser-use primitive bench, no model: cmux against browser-use, Playwright MCP and Stagehand.

Results and method: plans/cmux-next/browser-use-perf.md. Every tool drives the same headless Chrome binary
on the same live pages; rounds interleave the tools so network drift hits all of them alike.

  python3 -I bench.py --tools cmux,cmux-cli,cmux-mcp,browser-use,pwmcp,stagehand --runs 20 --out DIR
  python3 -I bench.py --cold 20 --tools ... --out DIR          # cold start to first page only

Tools:
  cmux        cmux-browser-host REPL over its own socket (a private host this script starts and stops)
  cmux-cli    the same host, one `cmux-browser-host eval --session` process per call
  cmux-mcp    `cmux mcp serve --all-tools`, tool browser_repl_eval (the running cmux app's daemon host,
              headless engine, its own session, closed at the end)
  browser-use BrowserSession + Tools actions (navigate, click, input, send_keys) and
              get_browser_state_summary(include_screenshot=False) + dom_state.llm_representation()
  pwmcp       @playwright/mcp over stdio, defaults (every action answers with a snapshot)
  stagehand   Stagehand v4 localBrowser, page.snapshot() (observe's tree, no model), xpath locators

Competitors live in --deps (default /tmp/cu-bench, made by setup.sh). Nothing here needs an API key.
Every process this script starts is stopped by its own pid at the end.
"""
import argparse
import json
import os
import re
import signal
import socket
import statistics
import subprocess
import sys
import tempfile
import time

HERE = os.path.dirname(os.path.abspath(__file__))
# Overridden by --chrome and --bin (the fleet entry passes a Chrome for Testing and a host built at the ref).
CHROME = os.environ.get("BENCH_CHROME", "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome")
APP_BIN = os.environ.get("BENCH_CMUX_BIN", "/Applications/cmux NIGHTLY.app/Contents/Resources/bin")

# Targets name an element the way an agent would pick it from its page state: ARIA role + name (cmux,
# Playwright MCP and Stagehand trees), and tag + attributes for browser-use's selector map.
SITES = [
    {"id": "example", "url": "https://example.com/"},
    {"id": "hn", "url": "https://news.ycombinator.com/",
     "click": {"role": "link", "name": "new", "exact": True, "navigates": True,
               "bu": {"tag": "a", "text": "new"}}},
    {"id": "wiki_rust", "url": "https://en.wikipedia.org/wiki/Rust_(programming_language)",
     "type": {"role": "searchbox", "name": "Search Wikipedia", "text": "Rust", "submit": False,
              "bu": {"tag": "input", "attr": {"name": "search"}}}},
    {"id": "gh_bu", "url": "https://github.com/browser-use/browser-use"},
    {"id": "checkboxes", "url": "https://the-internet.herokuapp.com/checkboxes",
     "click": {"role": "checkbox", "nth": 0, "bu": {"tag": "input", "attr": {"type": "checkbox"}}}},
    # `todomvc/` (no hash) sets `#/` during load; cmux's goto never returns there (see the plan's bug list).
    {"id": "todomvc", "url": "https://demo.playwright.dev/todomvc/#/",
     "type": {"role": "textbox", "name": "What needs to be done?", "text": "buy milk", "submit": True,
              "bu": {"tag": "input", "attr": {"class": "new-todo"}}},
     "click": {"role": "checkbox", "name": "Toggle Todo", "nth": 0,
               "bu": {"tag": "input", "attr": {"class": "toggle"}}}},
    {"id": "heavy_wiki_ww2", "url": "https://en.wikipedia.org/wiki/World_War_II"},
]


def now_ms():
    return time.perf_counter() * 1000.0


def approx_tokens(text):
    # A rough count (about 4 characters a token for English); the same rule for every tool.
    return round(len(text) / 4)


# ---------------------------------------------------------------- role trees (cmux, Playwright MCP)

ARIA_LINE = re.compile(r'^[+~ ]?\s*-\s+(?P<role>[a-z]+)(?:\s+"(?P<name>(?:[^"\\]|\\.)*)")?(?P<rest>.*?)\[ref=(?P<ref>[a-z0-9]+)\]')


def find_ref(tree, target):
    """The ref of the nth element whose role and name match, from a YAML-ish role tree."""
    hits = []
    for line in tree.splitlines():
        m = ARIA_LINE.match(line)
        roles = target["role"] if isinstance(target["role"], list) else [target["role"]]
        if not m or m.group("role") not in roles:
            continue
        name = m.group("name") or ""
        want = target.get("name")
        if want is not None:
            if target.get("exact") and name != want:
                continue
            if not target.get("exact") and want.lower() not in name.lower():
                continue
        hits.append(m.group("ref"))
    nth = target.get("nth", 0)
    if len(hits) <= nth:
        raise RuntimeError(f"no {target['role']} {target.get('name')!r} in the tree")
    return hits[nth]


# ---------------------------------------------------------------- cmux

class HostProcess:
    """A private `cmux-browser-host serve` on its own socket."""

    def __init__(self, workdir):
        self.dir = tempfile.mkdtemp(prefix="cmuxbh-", dir=workdir)
        self.sock = os.path.join(self.dir, "bh.sock")
        env = dict(os.environ)
        for key in ("CMUX_BROWSER_HOST_SOCKET", "CMUX_TUI_SOCKET"):
            env.pop(key, None)
        env["CMUX_BROWSER_HOST_CHROMIUM"] = CHROME
        self.log = open(os.path.join(self.dir, "serve.log"), "w")
        self.proc = subprocess.Popen([os.path.join(APP_BIN, "cmux-browser-host"), "serve", "--socket", self.sock],
                                     cwd=self.dir, env=env, stdin=subprocess.DEVNULL, stdout=self.log,
                                     stderr=self.log, start_new_session=True)
        deadline = time.time() + 10
        while time.time() < deadline:
            try:
                s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
                s.connect(self.sock)
                s.close()
                return
            except OSError:
                time.sleep(0.005)
        raise RuntimeError("cmux-browser-host did not listen")

    def stop(self):
        if self.proc.poll() is None:
            # The host's process group holds its Chromium; stop the group by the host's own pid.
            try:
                os.killpg(self.proc.pid, signal.SIGTERM)
            except ProcessLookupError:
                pass
            try:
                self.proc.wait(5)
            except subprocess.TimeoutExpired:
                os.killpg(self.proc.pid, signal.SIGKILL)
                self.proc.wait(5)
        self.log.close()


class LineConn:
    def __init__(self, path):
        self.s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.s.connect(path)
        self.f = self.s.makefile("rwb")
        self.id = 0

    def call(self, method, params):
        self.id += 1
        self.f.write((json.dumps({"id": self.id, "method": method, "params": params, "origin": "cli"}) + "\n").encode())
        self.f.flush()
        reply = json.loads(self.f.readline())
        if reply.get("error"):
            raise RuntimeError(reply["error"].get("message", str(reply["error"])))
        return reply.get("result")

    def close(self):
        self.s.close()


def cmux_code(op, arg=None, ref=None, target=None):
    if op == "goto":
        # 15 s, not Playwright's 30 s: a goto that hangs (the same-document bug in the plan) costs less.
        return f"await page.goto({json.dumps(arg)}, {{ timeout: 15000 }}); null"
    if op == "state":
        return "snapshot()"
    if op == "state_interactive":
        return "snapshot({ interactive: true })"
    if op == "click":
        return f"await page.locator({json.dumps(ref)}).click(); null"
    if op == "type":
        code = f"await page.locator({json.dumps(ref)}).fill({json.dumps(target['text'])});"
        if target.get("submit"):
            code += ' await page.keyboard.press("Enter");'
        return code + " null"
    raise ValueError(op)


class CmuxBase:
    interactive = True

    def __init__(self):
        self.tree = ""

    def eval(self, code):
        raise NotImplementedError

    def op(self, op, arg=None, target=None):
        ref = find_ref(self.tree, target) if op in ("click", "type") else None
        out = self.eval(cmux_code(op, arg, ref, target))
        if op == "state":
            self.tree = out
        return out if op.startswith("state") else ""


class CmuxSocket(CmuxBase):
    name = "cmux"

    def __init__(self, workdir, host=None):
        super().__init__()
        self.own_host = host is None
        self.host = host or HostProcess(workdir)
        self.conn = LineConn(self.host.sock)
        self.session = f"{self.name}-{os.getpid()}"

    def start(self):
        self.conn.call("browser.repl.open", {"session": self.session, "engine": "headless", "cwd": self.host.dir})

    def eval(self, code):
        r = self.conn.call("browser.repl.eval", {"session": self.session, "code": code, "timeoutMs": 60000})
        if r.get("error"):
            raise RuntimeError(r["error"])
        return r.get("output", "")

    def stop(self):
        try:
            self.conn.call("browser.repl.close", {"session": self.session})
        except Exception:
            pass
        self.conn.close()
        if self.own_host:
            self.host.stop()


class CmuxTuned(CmuxSocket):
    """Not a shipped default: emulates two fixes from the plan with REPL code, to measure their gain.
    1. A navigation drops the snapshot diff baselines (no diff against another document).
    2. Agent pointer motion "instant" (no human path, dwell or press hold) for a headless tab."""
    name = "cmux-tuned"

    def start(self):
        super().start()
        self.eval("page.mouse.configure({ motion: 'instant' }); null")

    def op(self, op, arg=None, target=None):
        if op == "goto":
            self.eval(f"await page.goto({json.dumps(arg)}, {{ timeout: 15000 }}); page._snapshotBaselines && page._snapshotBaselines.clear(); null")
            return ""
        return super().op(op, arg, target)


class CmuxCli(CmuxBase):
    """One `cmux-browser-host eval` process per call against the same private host."""
    name = "cmux-cli"

    def __init__(self, workdir, host):
        super().__init__()
        self.host = host
        self.session = f"benchcli-{os.getpid()}"

    def start(self):
        self.eval("null")

    def eval(self, code):
        env = dict(os.environ)
        for key in ("CMUX_BROWSER_HOST_SOCKET", "CMUX_TUI_SOCKET"):
            env.pop(key, None)
        p = subprocess.run([os.path.join(APP_BIN, "cmux-browser-host"), "eval", "--socket", self.host.sock,
                            "--session", self.session, "--engine", "headless", code],
                           cwd=self.host.dir, env=env, capture_output=True, text=True, timeout=90)
        if p.returncode != 0:
            raise RuntimeError(p.stderr.strip()[-300:])
        return p.stdout

    def stop(self):
        try:
            LineConn(self.host.sock).call("browser.repl.close", {"session": self.session})
        except Exception:
            pass


# ---------------------------------------------------------------- MCP over stdio

class McpClient:
    def __init__(self, argv, cwd, env=None):
        self.proc = subprocess.Popen(argv, cwd=cwd, env=env, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                     stderr=open(os.path.join(cwd, "mcp-stderr.log"), "a"), start_new_session=True)
        self.id = 0
        self.request("initialize", {"protocolVersion": "2025-06-18", "capabilities": {},
                                    "clientInfo": {"name": "cmux-browser-use-perf", "version": "1"}})
        self.notify("notifications/initialized", {})

    def notify(self, method, params):
        self.proc.stdin.write((json.dumps({"jsonrpc": "2.0", "method": method, "params": params}) + "\n").encode())
        self.proc.stdin.flush()

    def request(self, method, params):
        self.id += 1
        rid = self.id
        self.proc.stdin.write((json.dumps({"jsonrpc": "2.0", "id": rid, "method": method, "params": params}) + "\n").encode())
        self.proc.stdin.flush()
        while True:
            line = self.proc.stdout.readline()
            if not line:
                raise RuntimeError(f"MCP server closed ({method})")
            msg = json.loads(line)
            if msg.get("id") == rid and ("result" in msg or "error" in msg):
                if "error" in msg:
                    raise RuntimeError(msg["error"].get("message"))
                return msg["result"]

    def tool(self, name, args):
        r = self.request("tools/call", {"name": name, "arguments": args})
        text = "\n".join(c.get("text", "") for c in r.get("content", []) if c.get("type") == "text")
        if r.get("isError"):
            raise RuntimeError(text[:300])
        return text

    def stop(self):
        if self.proc.poll() is None:
            try:
                self.proc.stdin.close()
            except Exception:
                pass
            try:
                self.proc.wait(5)
            except subprocess.TimeoutExpired:
                os.killpg(self.proc.pid, signal.SIGTERM)
                try:
                    self.proc.wait(5)
                except subprocess.TimeoutExpired:
                    os.killpg(self.proc.pid, signal.SIGKILL)


class CmuxMcp(CmuxBase):
    """`cmux mcp serve --all-tools`: browser_repl_eval through the running app's daemon (headless engine)."""
    name = "cmux-mcp"

    def __init__(self, workdir):
        super().__init__()
        self.dir = tempfile.mkdtemp(prefix="cmuxmcp-", dir=workdir)
        self.session = f"cubench-{os.getpid()}"
        self.mcp = McpClient([os.path.join(APP_BIN, "cmux"), "mcp", "serve", "--all-tools"], self.dir)

    def start(self):
        self.mcp.tool("browser_repl_open", {"session": self.session, "engine": "headless"})

    def eval(self, code):
        text = self.mcp.tool("browser_repl_eval", {"session": self.session, "code": code, "timeoutMs": 60000})
        # The tool answers the host's reply as JSON: {output, error, durationMs, ...}.
        reply = json.loads(text)
        if reply.get("error"):
            raise RuntimeError(str(reply["error"])[:300])
        return reply.get("output", "")

    def stop(self):
        try:
            self.mcp.tool("browser_repl_close", {"session": self.session})
        except Exception:
            pass
        self.mcp.stop()


class PlaywrightMcp:
    name = "pwmcp"
    interactive = False

    def __init__(self, workdir, deps, extra=()):
        self.dir = tempfile.mkdtemp(prefix="pwmcp-", dir=workdir)
        cli = os.path.join(deps, "playwright-mcp/node_modules/@playwright/mcp/cli.js")
        self.mcp = McpClient(["node", cli, "--headless", "--isolated", "--executable-path", CHROME,
                              "--output-dir", self.dir, *extra], self.dir)
        self.tree = ""

    def start(self):
        pass

    def op(self, op, arg=None, target=None):
        if op == "goto":
            return self.mcp.tool("browser_navigate", {"url": arg}) and ""
        if op == "state":
            self.tree = self.mcp.tool("browser_snapshot", {})
            return self.tree
        ref = find_ref(self.tree, target)
        if op == "click":
            self.mcp.tool("browser_click", {"element": target.get("name") or target["role"], "target": ref})
            return ""
        if op == "type":
            self.mcp.tool("browser_type", {"element": target.get("name") or target["role"], "target": ref,
                                           "text": target["text"], "submit": bool(target.get("submit"))})
            return ""
        raise ValueError(op)

    def stop(self):
        self.mcp.stop()


class PlaywrightMcpNoSnap(PlaywrightMcp):
    """Playwright MCP with --snapshot-mode none: actions answer without the page snapshot."""
    name = "pwmcp-nosnap"

    def __init__(self, workdir, deps):
        super().__init__(workdir, deps, extra=("--snapshot-mode", "none"))


# ---------------------------------------------------------------- JSON-line driver processes

class LineDriver:
    def __init__(self, argv, cwd, env=None):
        self.proc = subprocess.Popen(argv, cwd=cwd, env=env, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                     stderr=open(os.path.join(cwd, "driver-stderr.log"), "a"),
                                     start_new_session=True, text=True)
        ready = self.proc.stdout.readline()
        if not ready.startswith("{"):
            raise RuntimeError(f"driver did not start: {ready!r}")

    def send(self, msg):
        self.proc.stdin.write(json.dumps(msg) + "\n")
        self.proc.stdin.flush()
        line = self.proc.stdout.readline()
        if not line:
            raise RuntimeError("driver exited")
        reply = json.loads(line)
        if not reply.get("ok"):
            raise RuntimeError(reply.get("error", "driver error")[:300])
        return reply

    def op(self, op, arg=None, target=None):
        return self.send({"op": op, "arg": arg, "target": target}).get("text", "")

    def start(self):
        self.send({"op": "start"})

    def stop(self):
        if self.proc.poll() is None:
            try:
                self.send({"op": "stop"})
            except Exception:
                pass
            try:
                self.proc.wait(10)
            except subprocess.TimeoutExpired:
                os.killpg(self.proc.pid, signal.SIGKILL)
                self.proc.wait(5)


class BrowserUse(LineDriver):
    name = "browser-use"
    interactive = False

    def __init__(self, workdir, deps):
        d = tempfile.mkdtemp(prefix="bu-", dir=workdir)
        env = dict(os.environ, ANONYMIZED_TELEMETRY="false", BROWSER_USE_CLOUD_SYNC="false",
                   BROWSER_USE_LOGGING_LEVEL="result", CHROME_PATH=CHROME)
        super().__init__([os.path.join(deps, "browser-use/.venv/bin/python"), "-I",
                          os.path.join(HERE, "bu_driver.py"), CHROME], d, env)


class Stagehand(LineDriver):
    name = "stagehand"
    interactive = False

    def __init__(self, workdir, deps):
        d = tempfile.mkdtemp(prefix="sh-", dir=workdir)
        mod = os.path.join(deps, "stagehand/node_modules/@browserbasehq/stagehand/dist/index.mjs")
        super().__init__(["node", os.path.join(HERE, "sh_driver.mjs"), mod, CHROME], d)


# ---------------------------------------------------------------- runner

def make(name, workdir, deps, host):
    if name == "cmux":
        return CmuxSocket(workdir, host)
    if name == "cmux-cli":
        return CmuxCli(workdir, host)
    if name == "cmux-tuned":
        return CmuxTuned(workdir, host)
    if name == "cmux-mcp":
        return CmuxMcp(workdir)
    if name == "browser-use":
        return BrowserUse(workdir, deps)
    if name == "pwmcp":
        return PlaywrightMcp(workdir, deps)
    if name == "pwmcp-nosnap":
        return PlaywrightMcpNoSnap(workdir, deps)
    if name == "stagehand":
        return Stagehand(workdir, deps)
    raise SystemExit(f"unknown tool {name}")


def timed(rows, tool, site, prim, fn, run):
    t0 = now_ms()
    try:
        out = fn()
        ms = now_ms() - t0
        row = {"tool": tool, "site": site, "prim": prim, "run": run, "ms": round(ms, 2), "ok": True}
        if isinstance(out, str) and out:
            row["chars"] = len(out)
            row["tokens"] = approx_tokens(out)
            row["diff"] = bool(re.search(r"^[+~-] ", out, re.M)) and not re.search(r"^url: ", out, re.M)
        rows.append(row)
        return out
    except Exception as e:  # a failure is a data point, never a crash
        rows.append({"tool": tool, "site": site, "prim": prim, "run": run, "ms": round(now_ms() - t0, 2),
                     "ok": False, "error": str(e)[:300]})
        return None


def run_site(rows, tool, drv, site, run, samples):
    sid = site["id"]
    if timed(rows, tool.name, sid, "goto", lambda: drv.op("goto", site["url"]), run) is None:
        return
    tree = timed(rows, tool.name, sid, "state", lambda: drv.op("state"), run)
    if tree and run == 0:
        samples[f"{tool.name}/{sid}"] = tree
    if drv.interactive:
        out = timed(rows, tool.name, sid, "state_interactive", lambda: drv.op("state_interactive"), run)
        if out and run == 0:
            samples[f"{tool.name}/{sid}/interactive"] = out
    if "type" in site:
        if timed(rows, tool.name, sid, "type", lambda: drv.op("type", target=site["type"]), run) is not None:
            out = timed(rows, tool.name, sid, "state_after", lambda: drv.op("state"), run)
            if out and run == 0:
                samples[f"{tool.name}/{sid}/after_type"] = out
    if "click" in site:
        if timed(rows, tool.name, sid, "click", lambda: drv.op("click", target=site["click"]), run) is not None:
            timed(rows, tool.name, sid, "state_after_click", lambda: drv.op("state"), run)


def warm(opts, workdir):
    rows, samples = [], {}
    host = HostProcess(workdir) if any(t in ("cmux", "cmux-cli", "cmux-tuned") for t in opts.tools) else None
    drivers = []
    try:
        for name in opts.tools:
            d = make(name, workdir, opts.deps, host)
            drivers.append(d)
            d.start()
            # One untimed warm-up visit per site (DNS, TLS, HTTP cache), the same for every tool.
            for site in SITES:
                try:
                    d.op("goto", site["url"])
                except Exception:
                    pass
        for run in range(opts.runs):
            order = drivers if run % 2 == 0 else list(reversed(drivers))
            for site in SITES:
                for d in order:
                    run_site(rows, d, d, site, run, samples)
            print(f"round {run + 1}/{opts.runs} done", file=sys.stderr, flush=True)
    finally:
        for d in drivers:
            d.stop()
        if host:
            host.stop()
    return rows, samples


def cold(opts, workdir):
    """Process start to first page (example.com) loaded, a fresh browser each run."""
    rows = []
    url = "https://example.com/"
    for run in range(opts.cold):
        for name in opts.tools:
            if name in ("cmux-mcp", "cmux-cli", "cmux-tuned"):
                continue  # cmux-mcp: the app's daemon owns that host; the others start like cmux
            t0 = now_ms()
            d = host = None
            try:
                if name in ("cmux", "cmux-cli", "cmux-tuned"):
                    host = HostProcess(workdir)
                d = make(name, workdir, opts.deps, host)
                t1 = now_ms()
                d.start()
                d.op("goto", url)
                t2 = now_ms()
                rows.append({"tool": name, "site": "example", "prim": "cold_total", "run": run, "ms": round(t2 - t0, 2), "ok": True})
                rows.append({"tool": name, "site": "example", "prim": "cold_browser", "run": run, "ms": round(t2 - t1, 2), "ok": True})
            except Exception as e:
                rows.append({"tool": name, "site": "example", "prim": "cold_total", "run": run, "ms": round(now_ms() - t0, 2), "ok": False, "error": str(e)[:300]})
            finally:
                if d:
                    d.stop()
                if host:
                    host.stop()
        print(f"cold {run + 1}/{opts.cold} done", file=sys.stderr, flush=True)
    return rows


YOUTUBE_QUERY = "rust programming"
YOUTUBE_BOX = {"role": ["combobox", "searchbox", "textbox"], "name": "Search", "text": YOUTUBE_QUERY, "submit": True,
               "bu": {"tag": "input", "attr": {"name": "search_query"}}}


def task_youtube(opts, workdir):
    """"Top 5 YouTube results for a query": cmux's site tool (one call) against the DOM steps an agent takes
    with every tool (open youtube.com, type the query and Enter, read the results page). Each DOM step is one
    model turn in an agent loop; the model's own time per turn is not measured here (no model)."""
    rows = []
    host = HostProcess(workdir) if any(t.startswith("cmux") and t != "cmux-mcp" for t in opts.tools) else None
    drivers = []
    try:
        for name in opts.tools:
            d = make(name, workdir, opts.deps, host)
            drivers.append(d)
            d.start()
        for run in range(opts.runs):
            for d in drivers:
                if isinstance(d, CmuxBase):
                    code = (f"const r = await sites.youtube.search({json.dumps(YOUTUBE_QUERY)}, {{ limit: 5 }});"
                            " JSON.stringify(Array.from({ length: 5 }, (_, i) => r[i] && { title: r[i].title, url: r[i].url }))")
                    timed(rows, d.name, "youtube", "site_tool", lambda: d.eval(code), run)
                    continue
                if timed(rows, d.name, "youtube", "dom_goto", lambda: d.op("goto", "https://www.youtube.com/"), run) is None:
                    continue
                time.sleep(1.5)  # the same pause before every read: the model's turn would take longer anyway
                timed(rows, d.name, "youtube", "dom_state1", lambda: d.op("state"), run)
                if timed(rows, d.name, "youtube", "dom_type_enter", lambda: d.op("type", target=YOUTUBE_BOX), run) is None:
                    continue
                # The results page renders after Enter; give every tool the same 1.5 s before its read, as an
                # agent's next turn would come later anyway (the model's time). Not counted in the step.
                time.sleep(1.5)
                timed(rows, d.name, "youtube", "dom_state2", lambda: d.op("state"), run)
            print(f"youtube {run + 1}/{opts.runs} done", file=sys.stderr, flush=True)
    finally:
        for d in drivers:
            d.stop()
        if host:
            host.stop()
    return rows


def pct(values, p):
    if not values:
        return None
    s = sorted(values)
    k = (len(s) - 1) * p
    lo, hi = int(k), min(int(k) + 1, len(s) - 1)
    return s[lo] + (s[hi] - s[lo]) * (k - lo)


def summarize(rows):
    groups = {}
    for r in rows:
        groups.setdefault((r["tool"], r["site"], r["prim"]), []).append(r)
    out = []
    for (tool, site, prim), rs in sorted(groups.items()):
        ok = [r["ms"] for r in rs if r["ok"]]
        chars = [r["chars"] for r in rs if r.get("chars")]
        out.append({"tool": tool, "site": site, "prim": prim, "n": len(rs), "ok": len(ok),
                    "p50": round(pct(ok, 0.5), 1) if ok else None, "p95": round(pct(ok, 0.95), 1) if ok else None,
                    "max": round(max(ok), 1) if ok else None,
                    "chars_first": next((r.get("chars") for r in sorted(rs, key=lambda r: r["run"]) if r.get("chars")), None),
                    "chars_p50": round(statistics.median(chars)) if chars else None,
                    "errors": sorted({r["error"] for r in rs if not r["ok"]})[:3]})
    return out


def main():
    global CHROME, APP_BIN
    ap = argparse.ArgumentParser()
    ap.add_argument("--tools", default="cmux,cmux-cli,cmux-mcp,browser-use,pwmcp,stagehand")
    ap.add_argument("--runs", type=int, default=20)
    ap.add_argument("--cold", type=int, default=0, help="cold-start runs only (no warm runs)")
    ap.add_argument("--sites", default="", help="comma list of site ids (default: all)")
    ap.add_argument("--task", default="", help="youtube: the end-to-end task instead of primitives")
    ap.add_argument("--deps", default="/tmp/cu-bench")
    ap.add_argument("--chrome", default=CHROME, help="the Chrome every tool launches")
    ap.add_argument("--bin", default=APP_BIN, help="directory with cmux-browser-host (and cmux for cmux-mcp)")
    ap.add_argument("--out", required=True)
    opts = ap.parse_args()
    opts.tools = [t for t in opts.tools.split(",") if t]
    CHROME, APP_BIN = opts.chrome, opts.bin
    if opts.sites:
        keep = set(opts.sites.split(","))
        SITES[:] = [s for s in SITES if s["id"] in keep]
    os.makedirs(opts.out, exist_ok=True)
    workdir = tempfile.mkdtemp(prefix="work-", dir=opts.out)
    meta = {"started": time.strftime("%Y-%m-%dT%H:%M:%S%z"), "tools": opts.tools, "runs": opts.runs,
            "cold": opts.cold, "chrome": subprocess.run([CHROME, "--version"], capture_output=True, text=True).stdout.strip(),
            "host": subprocess.run([os.path.join(APP_BIN, "cmux-browser-host"), "version"], capture_output=True, text=True).stdout.strip(),
            "mac": subprocess.run(["sysctl", "-n", "hw.model", "machdep.cpu.brand_string"], capture_output=True, text=True).stdout.split(),
            "macos": subprocess.run(["sw_vers", "-productVersion"], capture_output=True, text=True).stdout.strip()}
    if opts.task == "youtube":
        rows, samples = task_youtube(opts, workdir), {}
        tag = "youtube"
    elif opts.cold:
        rows, samples = cold(opts, workdir), {}
        tag = "cold"
    else:
        rows, samples = warm(opts, workdir)
        tag = "warm"
    with open(os.path.join(opts.out, f"{tag}-rows.jsonl"), "w") as f:
        for r in rows:
            f.write(json.dumps(r) + "\n")
    summary = summarize(rows)
    with open(os.path.join(opts.out, f"{tag}-summary.json"), "w") as f:
        json.dump({"meta": meta, "summary": summary}, f, indent=1)
    with open(os.path.join(opts.out, f"{tag}-samples.json"), "w") as f:
        json.dump(samples, f, indent=1, ensure_ascii=False)
    for s in summary:
        print(json.dumps(s))


if __name__ == "__main__":
    main()
