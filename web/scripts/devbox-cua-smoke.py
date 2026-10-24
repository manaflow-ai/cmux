#!/usr/bin/env python3
"""Exercise the baked agents' MCP commands against an isolated guest desktop.

Run as the desktop user from a login shell. No model account is needed: the
client speaks MCP directly using the commands the three agent hosts consume.
Only the browser is set up through a shell; all desktop input goes through MCP.
"""

import argparse
import base64
import http.server
import json
import os
import pathlib
import queue
import re
import signal
import struct
import subprocess
import tempfile
import threading
import tomllib
import urllib.parse


class McpClient:
    def __init__(self, command):
        self.errors = tempfile.TemporaryFile(mode="w+")
        self.process = subprocess.Popen(
            command, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
            stderr=self.errors, text=True, start_new_session=True,
        )
        self.messages = queue.Queue()
        self.sequence = 0
        threading.Thread(target=self.read, daemon=True).start()

    def read(self):
        for line in self.process.stdout:
            try:
                self.messages.put(json.loads(line))
            except ValueError:
                self.messages.put({"protocol_error": "non-JSON MCP stdout"})
        self.messages.put({"protocol_error": "MCP server exited"})

    def send(self, document):
        self.process.stdin.write(json.dumps({"jsonrpc": "2.0", **document}) + "\n")
        self.process.stdin.flush()

    def request(self, method, params):
        self.sequence += 1
        request_id = self.sequence
        self.send({"id": request_id, "method": method, "params": params})
        while True:
            try:
                message = self.messages.get(timeout=45)
            except queue.Empty:
                self.errors.seek(0)
                raise AssertionError(f"MCP {method} timed out: {self.errors.read()[-2000:]}")
            if "protocol_error" in message:
                self.errors.seek(0)
                raise AssertionError(f"{message['protocol_error']}: {self.errors.read()[-2000:]}")
            if message.get("id") == request_id:
                assert "error" not in message, message.get("error")
                return message["result"]

    def call(self, tool, arguments):
        result = self.request("tools/call", {"name": tool, "arguments": arguments})
        assert not result.get("isError"), result
        structured = result.get("structuredContent", {})
        assert not structured.get("error"), structured
        assert not structured.get("refusal"), structured
        return result

    def close(self):
        self.process.stdin.close()
        try:
            self.process.wait(timeout=10)
        except subprocess.TimeoutExpired:
            os.killpg(self.process.pid, signal.SIGTERM)
            self.process.wait(timeout=10)
        self.process.stdout.close()
        self.errors.close()


def screenshot(client, destination):
    # Current cua-driver accepts an explicit destination for desktop captures;
    # older releases returned the PNG inline. Keep both forms so the image
    # proof remains useful across a rolling snapshot ladder.
    result = client.call("get_desktop_state", {"screenshot_out_file": str(destination)})
    if destination.exists():
        data = destination.read_bytes()
    else:
        images = [item for item in result.get("content", []) if item.get("type") == "image"]
        assert images, "MCP returned no desktop image"
        data = base64.b64decode(images[0]["data"], validate=True)
    assert data[:8] == b"\x89PNG\r\n\x1a\n", "desktop image is not a PNG"
    width, height = struct.unpack(">II", data[16:24])
    assert width >= 800 and height >= 600, (width, height)
    destination.write_bytes(data)
    return {"width": width, "height": height, "bytes": len(data)}


def registrations(home):
    claude = json.loads((home / ".claude.json").read_text())["mcpServers"]["cua-computer-use"]
    codex = tomllib.loads((home / ".codex/config.toml").read_text())["mcp_servers"]["cua-driver"]
    # OpenCode creates its config lazily on first launch. Exercise the exact
    # baked writer its launcher invokes without requiring a model-plane account.
    subprocess.run([
        "bash", "-lc", ". /etc/cmux/agent-config.sh; cmux_write_cua_mcp_config allow-missing",
    ], check=True, timeout=30)
    opencode = json.loads((home / ".config/opencode/opencode.json").read_text())["mcp"]["cua-driver"]
    assert opencode["enabled"] is True
    return {
        "claude": [claude["command"], *claude["args"]],
        "codex": [codex["command"], *codex["args"]],
        "opencode": opencode["command"],
    }


def native_clients():
    """Have the real agent hosts load the saved server and its tool schemas."""
    claude = subprocess.run(
        ["claude", "--bare", "mcp", "get", "cua-computer-use"],
        capture_output=True, text=True, timeout=60,
    )
    assert claude.returncode == 0 and re.search(r"Status:.*Connected", claude.stdout), claude.stdout + claude.stderr
    codex = McpClient(["codex", "app-server"])
    try:
        codex.request("initialize", {"clientInfo": {"name": "cmux-cua-image-probe", "version": "1"}})
        codex.send({"method": "initialized"})
        status = codex.request("mcpServerStatus/list", {"detail": "full"})
        server = next(item for item in status["data"] if item["name"] == "cua-driver")
        tools = {tool["name"] for tool in server["tools"].values()}
        assert {"get_desktop_state", "click", "type_text", "press_key"} <= tools, server
    finally:
        codex.close()
    # The model-plane launcher needs the create-time authenticated network.
    # The actual OpenCode MCP client needs no model account or inference call.
    opencode = subprocess.run(
        ["/usr/local/libexec/cmux-opencode-real", "mcp", "list"],
        capture_output=True, text=True, timeout=60,
    )
    health = re.sub(r"\x1b\[[0-9;]*m", "", opencode.stdout).lower()
    assert opencode.returncode == 0 and "cua-driver" in health and re.search(r"\bconnected\b", health), opencode.stdout + opencode.stderr
    print("CUA_NATIVE_CLIENTS_PASS claude codex opencode", flush=True)


def run(output):
    assert os.getuid() != 0, "the probe must run as the desktop user"
    assert os.environ.get("DISPLAY") == ":1", "login shell did not inherit the desktop"
    assert os.environ.get("AT_SPI_BUS_ADDRESS"), "login shell did not inherit accessibility"
    output.mkdir(parents=True, exist_ok=True)
    ready, submitted = queue.Queue(), queue.Queue()
    page = b'''<!doctype html><title>cmux CUA image verification</title>
<style>body{background:#e6f4ea;font:24px sans-serif}input:not([type=hidden]){position:fixed;inset:0;
box-sizing:border-box;width:100%;height:100%;font:32px sans-serif;padding:40px}</style>
<form method="post"><input name="text" placeholder="Computer use: click, type, press Enter"
autocomplete="off" readonly onclick="this.readOnly=false;this.focus();document.getElementById('clicked').value='yes'">
<input type="hidden" id="clicked" name="clicked" value="no"></form><script>fetch('/ready')</script>'''

    class Handler(http.server.BaseHTTPRequestHandler):
        def log_message(self, *_args):
            pass

        def do_GET(self):
            if self.path == "/ready":
                ready.put(True)
            self.send_response(200)
            self.send_header("Content-Type", "text/html" if self.path == "/" else "text/plain")
            self.end_headers()
            self.wfile.write(page if self.path == "/" else b"ok")

        def do_POST(self):
            body = self.rfile.read(int(self.headers["Content-Length"]))
            submitted.put(urllib.parse.parse_qs(body.decode()))
            self.send_response(200)
            self.send_header("Content-Type", "text/html")
            self.end_headers()
            self.wfile.write(page)

    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    commands = registrations(pathlib.Path.home())
    native_clients()
    report = {}
    with tempfile.TemporaryDirectory(prefix="cmux-cua-chrome-") as profile:
        browser = subprocess.Popen([
            "google-chrome-stable", "--no-sandbox", "--no-first-run", "--no-default-browser-check",
            "--disable-gpu", "--disable-dev-shm-usage", "--user-data-dir=" + profile,
            "--window-position=50,50", "--window-size=1000,700", "--new-window",
            f"http://127.0.0.1:{server.server_port}/",
        ], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)
        try:
            ready.get(timeout=30)
            window = subprocess.check_output([
                "xdotool", "search", "--sync", "--onlyvisible", "--name", "^cmux CUA image verification",
            ], timeout=30, text=True).splitlines()[0]
            geometry = dict(line.split("=", 1) for line in subprocess.check_output([
                "xdotool", "getwindowgeometry", "--shell", window,
            ], text=True, timeout=10).splitlines())
            x = int(geometry["X"]) + int(geometry["WIDTH"]) // 2
            y = int(geometry["Y"]) + int(geometry["HEIGHT"]) // 2
            for name, command in commands.items():
                client = McpClient(command)
                try:
                    client.request("initialize", {
                        "protocolVersion": "2024-11-05", "capabilities": {},
                        "clientInfo": {"name": "cmux-image-verification", "version": "1"},
                    })
                    client.send({"method": "notifications/initialized"})
                    tools = client.request("tools/list", {})["tools"]
                    (output / (name + "-tools.json")).write_text(json.dumps(tools, indent=2) + "\n")
                    names = {tool["name"] for tool in tools}
                    assert {"get_desktop_state", "click", "type_text", "press_key"} <= names, names
                    before = screenshot(client, output / (name + "-before.png"))
                    client.call("click", {"scope": "desktop", "x": x, "y": y})
                    text = "cmux-cloud-cua-verified-" + name
                    client.call("type_text", {"scope": "desktop", "text": text})
                    screenshot(client, output / (name + "-typed.png"))
                    client.call("press_key", {"scope": "desktop", "key": "Return"})
                    assert submitted.get(timeout=15) == {"text": [text], "clicked": ["yes"]}, "desktop did not receive the MCP click and exact input"
                    ready.get(timeout=15)
                    report[name] = {"tools": len(tools), "screenshot": before, "input": "verified"}
                    print("CUA_MCP_PASS " + name, flush=True)
                finally:
                    client.close()
        finally:
            try:
                os.killpg(browser.pid, signal.SIGTERM)
            except ProcessLookupError:
                pass
            try:
                browser.wait(timeout=30)
            except subprocess.TimeoutExpired:
                # Chrome can leave a helper alive after the browser process
                # receives SIGTERM. Kill the isolated process group so a
                # slow cleanup never turns an otherwise valid CUA proof red.
                try:
                    os.killpg(browser.pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
                browser.wait(timeout=10)
            server.shutdown()
            server.server_close()
    (output / "result.json").write_text(json.dumps(report, indent=2) + "\n")
    print("CUA_SMOKE_PASS " + json.dumps(report), flush=True)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--out", type=pathlib.Path, required=True)
    args = parser.parse_args()
    run(args.out)
