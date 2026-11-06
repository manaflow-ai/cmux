# SPDX-License-Identifier: MIT
"""A minimal MCP client over stdio (newline-delimited JSON-RPC 2.0)."""

from __future__ import annotations

import json
import os
import queue
import subprocess
import threading
import time
from typing import Any


class McpError(RuntimeError):
    pass


class McpClient:
    def __init__(self, command: list[str], env: dict[str, str] | None = None, cwd: str | None = None,
                 stderr_path: str | None = None):
        self.command = command
        self._stderr = open(stderr_path, "ab") if stderr_path else subprocess.DEVNULL
        self.proc = subprocess.Popen(
            command, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=self._stderr,
            env={**os.environ, **(env or {})}, cwd=cwd,
        )
        self._next_id = 1
        self._responses: "queue.Queue[dict[str, Any]]" = queue.Queue()
        self._reader = threading.Thread(target=self._read, daemon=True)
        self._reader.start()
        self.server_info: dict[str, Any] = {}
        self.tools: list[dict[str, Any]] = []

    def _read(self) -> None:
        assert self.proc.stdout is not None
        for raw in self.proc.stdout:
            line = raw.strip()
            if not line:
                continue
            try:
                msg = json.loads(line)
            except json.JSONDecodeError:
                continue  # a server that logs to stdout; ignore non-JSON lines
            if "id" in msg and ("result" in msg or "error" in msg):
                self._responses.put(msg)
        self._responses.put({"_eof": True})

    def _send(self, msg: dict[str, Any]) -> None:
        assert self.proc.stdin is not None
        self.proc.stdin.write((json.dumps(msg) + "\n").encode())
        self.proc.stdin.flush()

    def request(self, method: str, params: dict[str, Any] | None = None, timeout: float = 30.0) -> Any:
        rid = self._next_id
        self._next_id += 1
        self._send({"jsonrpc": "2.0", "id": rid, "method": method, "params": params or {}})
        deadline = time.monotonic() + timeout
        while True:
            left = deadline - time.monotonic()
            if left <= 0:
                raise McpError(f"{method}: no answer in {timeout:.0f}s")
            try:
                msg = self._responses.get(timeout=left)
            except queue.Empty:
                continue
            if msg.get("_eof"):
                raise McpError(f"{method}: server exited (code {self.proc.poll()})")
            if msg.get("id") != rid:
                continue
            if "error" in msg:
                raise McpError(f"{method}: {msg['error']}")
            return msg["result"]

    def notify(self, method: str, params: dict[str, Any] | None = None) -> None:
        self._send({"jsonrpc": "2.0", "method": method, "params": params or {}})

    def initialize(self) -> dict[str, Any]:
        result = self.request("initialize", {
            "protocolVersion": "2025-06-18",
            "capabilities": {},
            "clientInfo": {"name": "cmux-cu-eval", "version": "1"},
        })
        self.server_info = result.get("serverInfo", {})
        self.notify("notifications/initialized")
        return result

    def list_tools(self) -> list[dict[str, Any]]:
        tools: list[dict[str, Any]] = []
        cursor = None
        while True:
            result = self.request("tools/list", {"cursor": cursor} if cursor else {})
            tools.extend(result.get("tools", []))
            cursor = result.get("nextCursor")
            if not cursor:
                break
        self.tools = tools
        return tools

    def call(self, name: str, arguments: dict[str, Any], timeout: float = 60.0) -> "ToolResult":
        result = self.request("tools/call", {"name": name, "arguments": arguments}, timeout=timeout)
        return ToolResult(result)

    def close(self) -> None:
        try:
            if self.proc.stdin:
                self.proc.stdin.close()
            self.proc.wait(timeout=5)
        except Exception:
            self.proc.kill()
        if hasattr(self._stderr, "close"):
            self._stderr.close()


class ToolResult:
    """A tools/call result: text parts, parsed JSON (when a part is JSON), images."""

    def __init__(self, raw: dict[str, Any]):
        self.raw = raw
        self.is_error = bool(raw.get("isError"))
        self.texts = [c.get("text", "") for c in raw.get("content", []) if c.get("type") == "text"]
        self.images = [c for c in raw.get("content", []) if c.get("type") == "image"]
        self.data: Any = raw.get("structuredContent")
        if self.data is None:
            for text in self.texts:
                try:
                    self.data = json.loads(text)
                    break
                except (json.JSONDecodeError, TypeError):
                    continue

    def text(self) -> str:
        return "\n".join(self.texts)
