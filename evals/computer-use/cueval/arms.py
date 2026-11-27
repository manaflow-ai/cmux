# SPDX-License-Identifier: MIT
"""Arms: which computer-use MCP server an attempt uses, how the harness sets
its deny list for a task, and (for the tool tier) how generic operations map
onto that server's tools.
"""

from __future__ import annotations

import base64
import json
import os
import re
import subprocess
import sys
from typing import Any

from . import platform_env as penv
from .mcp import McpClient, ToolResult

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
REPO = os.path.dirname(os.path.dirname(ROOT))
ARM_DIR = os.path.join(ROOT, "arms")
FAKE_SERVER = os.path.join(ROOT, "cueval", "fake_server.py")


def load_arm(arm_id: str) -> dict:
    if arm_id == "fake":
        return {"id": "fake", "label": "fake MCP server (self-test)", "adapter": "cmux", "tool_prefix": "",
                "mcp": {"server_name": "cmux-computer-use", "command": [sys.executable, "-I", FAKE_SERVER], "env": {}},
                "policy": {"method": "env", "var": "CUEVAL_FAKE_DENIED"}}
    path = os.path.join(ARM_DIR, f"{arm_id}.json")
    if not os.path.exists(path):
        known = [n[:-5] for n in os.listdir(ARM_DIR) if n.endswith(".json")] + ["fake"]
        raise SystemExit(f"unknown arm {arm_id}; known: {', '.join(sorted(known))}")
    with open(path) as f:
        return json.load(f)


def server_command(arm: dict) -> list[str]:
    mcp = arm["mcp"]
    override = mcp.get("command_env") and os.environ.get(mcp["command_env"])
    if override:
        return json.loads(override)
    cmd = list(mcp["command"])
    if any("{cua_driver_bin}" in c for c in cmd):
        binary = os.environ.get("CUEVAL_CUA_DRIVER_BIN")
        if not binary:
            r = subprocess.run([sys.executable, "-I", os.path.join(ARM_DIR, "resolve_cua_driver.py"), "fetch"],
                               capture_output=True, text=True)
            if r.returncode != 0:
                raise SystemExit(f"cua-driver fetch failed: {r.stderr.strip()}")
            binary = r.stdout.strip().splitlines()[-1]
        cmd = [c.replace("{cua_driver_bin}", binary) for c in cmd]
    return cmd


def mcp_config(arm: dict, env: dict[str, str]) -> dict:
    """The --mcp-config JSON for Claude Code (and the [mcp_servers] table for Codex)."""
    cmd = server_command(arm)
    env = {**arm["mcp"].get("env", {}), **env}
    if arm.get("adapter") == "cmux" and penv.platform_name() == "macos":
        sock = mac_daemon_socket()
        if sock and "CMUX_TUI_SOCKET" not in env:
            env["CMUX_TUI_SOCKET"] = sock
    return {"mcpServers": {arm["mcp"]["server_name"]: {
        "type": "stdio", "command": cmd[0], "args": cmd[1:], "env": env}}}


def mac_daemon_socket() -> str | None:
    """The cmux app's daemon socket on macOS. `cmux computer-use mcp` looks for the `main`
    session's socket only (CMUX_TUI_SOCKET, else main), while the app's daemon serves
    session cmux-app-<tag>; `cmux computer-use call` finds it, the MCP bridge does not
    (1.0.0 dc165ee78a81). CUEVAL_CMUX_TUI_SOCKET overrides; CUEVAL_CMUX_TAG picks the tag."""
    if os.environ.get("CUEVAL_CMUX_TUI_SOCKET"):
        return os.environ["CUEVAL_CMUX_TUI_SOCKET"]
    if os.environ.get("CMUX_TUI_SOCKET"):
        return os.environ["CMUX_TUI_SOCKET"]
    import tempfile
    tag = os.environ.get("CUEVAL_CMUX_TAG", "nightly")
    path = os.path.join(tempfile.gettempdir(), f"cmux-tui-{os.getuid()}", f"cmux-app-{tag}.sock")
    return path if os.path.exists(path) else None


def default_denied_apps() -> list[str]:
    """cmux's default deny list, read from the engine's source so it never drifts."""
    src = os.path.join(REPO, "cmux-tui/crates/cmux-computer-use/src/policy.rs")
    with open(src) as f:
        text = f.read()
    m = re.search(r"pub fn default_denied_apps\(\)[^{]*\{\s*&\[(.*?)\]\s*\}", text, re.S)
    if not m:
        raise SystemExit(f"default_denied_apps not found in {src}")
    body = re.sub(r"//[^\n]*", "", m.group(1))
    return re.findall(r'"([^"]+)"', body)


def denied_for(task: dict) -> list[str] | None:
    want = task.get("denied_apps") or []
    if not want:
        return None
    out: list[str] = []
    for item in want:
        out.extend(default_denied_apps() if item == "@default" else [item])
    return out


def apply_policy(arm: dict, task: dict, fake: bool = False) -> dict[str, str]:
    """Configure the arm's deny list for the task. Returns env for the server process."""
    pol = arm.get("policy", {})
    denied = denied_for(task)
    method = pol.get("method", "none")
    if method == "env":
        return {pol["var"]: json.dumps(denied or [])}
    if method == "none" or fake:
        return {}
    if method == "policy_file":
        plat = penv.platform_name()
        if denied is None:
            denied = default_denied_apps()
        if plat == "macos":
            if not task.get("denied_apps"):
                return {}  # a shared test Mac keeps its own deny list unless the task needs one
            current = _macos_denied(pol)
            mac_only = [d for d in denied if not d.endswith(".exe") and "gnome" not in d.lower()]
            if all(d in current for d in mac_only):
                return {}  # already denied (the default list): nothing to change
            # Agents may not change computerUse.deniedApps (userOnly), so a task needing an app
            # the Mac does not deny cannot run here; never work around that refusal.
            _save_macos_denied(pol)
            cmd = [c.replace("{denied_json}", json.dumps(denied)) for c in pol["macos_command"]]
            r = subprocess.run(cmd, capture_output=True, text=True)
            if r.returncode != 0:
                _MACOS_RESTORE.clear()
                raise RuntimeError(f"cannot deny {sorted(set(mac_only) - set(current))} on this Mac: "
                                   f"{(r.stderr or r.stdout).strip()[:200]}")
            return {}
        path = pol["paths"][plat]
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "w") as f:
            json.dump({**pol["base"], "deniedApps": denied}, f, indent=2)
        return {}
    raise SystemExit(f"unknown policy method {method}")


_MACOS_RESTORE: list[list[str]] = []


def _macos_denied(pol: dict) -> list[str]:
    r = subprocess.run([pol["macos_command"][0], "settings", "get", "computerUse.deniedApps", "--json"],
                       capture_output=True, text=True, check=True)
    cur = json.loads(r.stdout)
    value = cur.get("value")
    return value if isinstance(value, list) else (cur.get("row") or {}).get("default") or []


def _save_macos_denied(pol: dict) -> None:
    """Remember the Mac's deny list before a task changes it (restore_policy puts it back)."""
    if _MACOS_RESTORE:
        return
    cli = pol["macos_command"][0]
    r = subprocess.run([cli, "settings", "get", "computerUse.deniedApps", "--json"],
                       capture_output=True, text=True, check=True)
    cur = json.loads(r.stdout)
    if cur.get("row", {}).get("customized"):
        _MACOS_RESTORE.append([cli, "settings", "set", "computerUse.deniedApps", json.dumps(cur.get("value"))])
    else:
        _MACOS_RESTORE.append([cli, "settings", "reset", "computerUse.deniedApps"])


def restore_policy() -> None:
    while _MACOS_RESTORE:
        cmd = _MACOS_RESTORE.pop()
        r = subprocess.run(cmd, capture_output=True, text=True)
        if r.returncode != 0:
            print(f"warning: restoring the deny list failed: {' '.join(cmd)}: {r.stderr.strip()}", file=sys.stderr)


# ---------------------------------------------------------------- tool-tier adapters

def _walk(obj: Any):
    if isinstance(obj, dict):
        yield obj
        for v in obj.values():
            yield from _walk(v)
    elif isinstance(obj, list):
        for v in obj:
            yield from _walk(v)


class Window:
    def __init__(self, raw: dict):
        self.raw = raw
        self.window_id = raw.get("window_id", raw.get("id"))
        self.pid = raw.get("pid")
        self.title = raw.get("title") or raw.get("name") or ""


class Adapter:
    """Generic operations over one arm's MCP tools. Coordinates are window pixels."""

    def __init__(self, client: McpClient, prefix: str = ""):
        self.c = client
        self.p = prefix
        self.calls: list[dict] = []

    def call(self, name: str, args: dict) -> ToolResult:
        try:
            r = self.c.call(self.p + name, args)
        except Exception as e:  # a JSON-RPC error is a failed call, recorded like one
            self.calls.append({"name": name, "args": args, "result_text": str(e), "is_error": True})
            raise
        self.calls.append({"name": name, "args": args, "result_text": r.text()[:4000], "is_error": r.is_error})
        return r

    def windows(self) -> list[Window]:
        r = self.call("list_windows", self.list_windows_args())
        return [Window(d) for d in _walk(r.data) if isinstance(d, dict) and ("window_id" in d or ("id" in d and "title" in d))]

    def find(self, title: str) -> Window:
        for w in self.windows():
            if w.title == title:
                return w
        raise LookupError(f"no window titled {title!r}")

    def list_windows_args(self) -> dict:
        return {}


class CmuxAdapter(Adapter):
    def click(self, w: Window, x: float, y: float) -> ToolResult:
        return self.call("click", {"window_id": str(w.window_id), "x": x, "y": y})

    def type_text(self, w: Window, text: str) -> ToolResult:
        return self.call("type_text", {"window_id": str(w.window_id), "text": text})

    def press_key(self, w: Window, keys: str) -> ToolResult:
        return self.call("press_key", {"window_id": str(w.window_id), "keys": keys})

    def scroll(self, w: Window, x: float, y: float, dy: float) -> ToolResult:
        return self.call("scroll", {"window_id": str(w.window_id), "x": x, "y": y, "dy": dy})

    def screenshot(self, w: Window) -> tuple[ToolResult, bytes | None]:
        r = self.call("screenshot", {"window_id": str(w.window_id), "force": True})
        return r, (base64.b64decode(r.images[0]["data"]) if r.images else None)


class CuaDriverAdapter(Adapter):
    """cua-driver v0.38.0's tool shapes (its published contract manifest)."""

    def _target(self, w: Window) -> dict:
        return {"kind": "window", "pid": w.pid, "window_id": w.window_id}

    def click(self, w, x, y):
        return self.call("click", {"target": self._target(w), "x": x, "y": y, "delivery_mode": "background"})

    def type_text(self, w, text):
        return self.call("type_text", {"target": self._target(w), "text": text})

    def press_key(self, w, keys):
        return self.call("press_key", {"target": self._target(w), "key": keys})

    def scroll(self, w, x, y, dy):
        return self.call("scroll", {"target": self._target(w), "x": x, "y": y,
                                    "direction": "down" if dy > 0 else "up", "amount": abs(int(dy))})

    def screenshot(self, w):
        r = self.call("get_window_state", {"pid": w.pid, "window_id": w.window_id, "include_screenshot": True,
                                           "include_accessibility_tree": False})
        return r, (base64.b64decode(r.images[0]["data"]) if r.images else None)


def adapter_for(arm: dict, client: McpClient) -> Adapter:
    cls = {"cmux": CmuxAdapter, "cua-driver": CuaDriverAdapter}[arm["adapter"]]
    return cls(client, arm.get("tool_prefix", ""))
