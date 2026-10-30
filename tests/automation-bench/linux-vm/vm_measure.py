#!/usr/bin/env python3
"""Browser use and computer use on a cmux Linux VM, as an agent there gets them (run by hand).

Runs ON the VM as the work user, inside a terminal of the VM's own cmux daemon (so the
environment is an agent's: CMUX_BROWSER_HOST_SOCKET, CMUX_AGENT_TOOLS_BIN_DIR). It starts the two
MCP servers acpmux gives every agent, from the agent tool dir, and calls them over stdio:

- browser: `cmux mcp serve`, tool browser_repl_eval. The daemon starts the browser host on the
  first call (the daemon-started host, the path that broke when the daemon and host pins
  disagreed). 5 tasks from the dogfood suite: example.com, news.ycombinator.com,
  en.wikipedia.org search, the-internet.herokuapp.com/checkboxes, demo.playwright.dev/todomvc.
- computer use: `cmux-cua mcp` (CMUX_CUA_MCP_FORCE_PROXY=1, as acpmux starts it). 4 checks:
  doctor (health_report "ok"), a desktop screenshot, an AT-SPI tree of gedit (more than 10
  elements), a click on its text view and background typing whose text shows in the tree.
  gedit must be installed (run_on_vm.ts installs it on the throwaway VM).

Usage on the VM: python3 vm_measure.py --out result.json
Prints one line per item and `SCORE browser=x/5 cua=y/4`. No credential is read or written.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import select
import subprocess
import time


class Mcp:
    """A stdio MCP client for one server."""

    def __init__(self, argv: list[str], env: dict[str, str], stderr_path: str):
        self.p = subprocess.Popen(argv, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                  stderr=open(stderr_path, "wb"), env={**os.environ, **env})
        self.buf = b""
        self.n = 0
        init = self.rpc("initialize", {"protocolVersion": "2025-06-18", "capabilities": {},
                                       "clientInfo": {"name": "cmux-vm-measure", "version": "1"}})
        self.ok = "result" in init
        self.p.stdin.write(b'{"jsonrpc":"2.0","method":"notifications/initialized"}\n')
        self.p.stdin.flush()

    def rpc(self, method: str, params: dict, timeout: float = 150) -> dict:
        self.n += 1
        ident = self.n
        self.p.stdin.write((json.dumps({"jsonrpc": "2.0", "id": ident, "method": method, "params": params}) + "\n").encode())
        self.p.stdin.flush()
        end = time.time() + timeout
        while time.time() < end:
            while b"\n" in self.buf:
                line, self.buf = self.buf.split(b"\n", 1)
                try:
                    msg = json.loads(line)
                except ValueError:
                    continue
                if msg.get("id") == ident:
                    return msg
            ready, _, _ = select.select([self.p.stdout], [], [], 1)
            if ready:
                chunk = os.read(self.p.stdout.fileno(), 1 << 22)
                if not chunk:
                    return {"error": "server closed"}
                self.buf += chunk
        return {"error": "timeout"}

    def call(self, name: str, args: dict) -> tuple[bool, str, dict]:
        """(ok, text, structuredContent) of one tool call."""
        res = self.rpc("tools/call", {"name": name, "arguments": args})
        body = res.get("result", {})
        text = " ".join(c.get("text", "") for c in body.get("content", []) if c.get("type") == "text")
        ok = "error" not in res and not body.get("isError")
        return ok, text or str(res.get("error", "")), body.get("structuredContent") or {}

    def close(self) -> None:
        self.p.stdin.close()
        try:
            self.p.wait(10)
        except subprocess.TimeoutExpired:
            self.p.kill()


BROWSER_TASKS = [
    ("example-title", 'await page.goto("https://example.com/"); console.log("RESULT", await page.evaluate(() => document.title === "Example Domain"))'),
    ("hn-story-links", 'await page.goto("https://news.ycombinator.com/"); const s = String(await snapshot()); console.log("RESULT", (await page.locator(".athing").count()) >= 30 && s.includes(\'link "new"\'))'),
    ("wikipedia-search", 'await page.goto("https://en.wikipedia.org/wiki/Main_Page"); await page.locator("#searchInput").first().fill("Rust (programming language)"); await page.keyboard.press("Enter"); await page.waitForURL(/Rust_\\(programming_language\\)/, {timeout: 20000}); console.log("RESULT", /Rust/.test(await page.locator("h1").first().innerText()))'),
    ("internet-checkboxes", 'await page.goto("https://the-internet.herokuapp.com/checkboxes"); await page.check("#checkboxes input:nth-of-type(1)"); console.log("RESULT", await page.evaluate(() => document.querySelectorAll("#checkboxes input")[0].checked))'),
    ("todomvc-add", 'await page.goto("https://demo.playwright.dev/todomvc/"); for (const t of ["dogfood one", "dogfood two"]) { await page.fill(".new-todo", t); await page.press(".new-todo", "Enter"); } await page.check(".todo-list li:nth-child(1) .toggle"); console.log("RESULT", await page.evaluate(() => document.querySelectorAll(".todo-list li").length === 2 && document.querySelectorAll(".todo-list li.completed").length === 1))'),
]


def browser(bin_dir: str, work: str) -> list[dict]:
    rows = []
    mcp = Mcp([f"{bin_dir}/cmux", "mcp", "serve"], {}, f"{work}/mcp-cmux.stderr")
    for task, code in BROWSER_TASKS:
        t0 = time.time()
        ok, text, _ = mcp.call("browser_repl_eval", {"session": "measure", "code": code})
        try:
            reply = json.loads(text)
        except ValueError:
            reply = {"output": "", "error": text}
        passed = ok and reply.get("error") in (None, "") and "RESULT true" in (reply.get("output") or "")
        detail = (reply.get("output") or "").strip() or str(reply.get("error") or text)
        rows.append({"suite": "browser", "item": task, "pass": passed, "ms": int((time.time() - t0) * 1000), "detail": detail[:300]})
    mcp.close()
    return rows


def cua(bin_dir: str, work: str) -> list[dict]:
    rows = []

    def row(item: str, passed: bool, detail: str) -> None:
        rows.append({"suite": "cua", "item": item, "pass": passed, "detail": detail[:300]})

    mcp = Mcp([f"{bin_dir}/cmux-cua", "mcp"], {"CMUX_CUA_MCP_FORCE_PROXY": "1"}, f"{work}/mcp-cua.stderr")
    ok, text, _ = mcp.call("health_report", {})
    version = re.search(r"cmux-cua [0-9.]+", text)
    row("doctor", ok and "— ok" in text, text.splitlines()[0] if text else "no answer")
    mcp.call("set_config", {"capture_scope": "desktop"})
    shot = f"{work}/desktop.png"
    ok, text, _ = mcp.call("get_desktop_state", {"screenshot_out_file": shot})
    row("screenshot", ok and os.path.exists(shot) and os.path.getsize(shot) > 2000, text)
    subprocess.run(["pkill", "-u", str(os.getuid()), "-x", "gedit"], check=False)
    mcp.call("launch_app", {"name": "gedit"})
    window = None
    for _ in range(30):
        time.sleep(1)
        _, _, sc = mcp.call("list_windows", {"on_screen_only": True})
        window = next((w for w in sc.get("windows") or [] if "gedit" in (w.get("title") or "")), None)
        if window:
            break
    if not window:
        row("atspi-tree", False, "no gedit window")
        row("click-type", False, "no gedit window")
        mcp.close()
        return rows
    pid, wid = window["pid"], window["window_id"]
    ok, text, sc = mcp.call("get_window_state", {"pid": pid, "window_id": wid, "screenshot_out_file": f"{work}/gedit.png"})
    elements = sc.get("elements") or []
    row("atspi-tree", ok and len(elements) > 10, f"{len(elements)} elements")
    view = next((e for e in elements if e.get("role") == "text" and not e.get("label")), None)
    target = {"element_index": view["element_index"]} if view else {"x": 300, "y": 300}
    ok_click, click_text, _ = mcp.call("click", {"pid": pid, "window_id": wid, **target})
    ok_type, type_text, _ = mcp.call("type_text", {"pid": pid, "window_id": wid, "text": "hello cmux 42"})
    time.sleep(1)
    _, text, sc = mcp.call("get_window_state", {"pid": pid, "window_id": wid, "screenshot_out_file": f"{work}/gedit-typed.png"})
    # gedit marks a changed document with "*" in its title.
    typed = "*Untitled" in text or "hello cmux 42" in json.dumps(sc)
    row("click-type", ok_click and ok_type and typed, f"{click_text} | {type_text}")
    mcp.close()
    for r in rows:
        r["version"] = version.group(0) if version else ""
    return rows


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--out", required=True)
    parser.add_argument("--bin-dir", default=os.environ.get("CMUX_AGENT_TOOLS_BIN_DIR", "/opt/cmux/agent-tools/bin"))
    args = parser.parse_args()
    work = os.path.dirname(os.path.abspath(args.out))
    rows = browser(args.bin_dir, work) + cua(args.bin_dir, work)
    for r in rows:
        print(f"{'PASS' if r['pass'] else 'FAIL'} {r['suite']}/{r['item']}: {r['detail']}")
    b = sum(r["pass"] for r in rows if r["suite"] == "browser")
    c = sum(r["pass"] for r in rows if r["suite"] == "cua")
    print(f"SCORE browser={b}/5 cua={c}/4")
    with open(args.out, "w") as f:
        json.dump({"rows": rows, "browser": b, "cua": c}, f, indent=2)


if __name__ == "__main__":
    main()
