#!/usr/bin/env python3
"""Stress the cmux CLI and Unix socket API.

The harness is intentionally stateful: it creates one isolated stress workspace,
exercises CLI commands and raw v2 socket methods against that workspace, and
captures diagnostics whenever a command hangs, the socket stops responding, or
the app process disappears.
"""

from __future__ import annotations

import argparse
import concurrent.futures
import dataclasses
import datetime as dt
import glob
import json
import os
import pathlib
import random
import shutil
import signal
import socket
import subprocess
import sys
import threading
import time
import urllib.parse
import uuid
from typing import Any, Callable, Iterable


DEFAULT_DURATION_SECONDS = 12 * 60 * 60
DEFAULT_TIMEOUT_SECONDS = 12.0
DEFAULT_BURST_WORKERS = 6
DEFAULT_BURST_REQUESTS = 48
DIAGNOSTIC_TEXT_LIMIT_BYTES = 256 * 1024
DIAGNOSTIC_LOG_TAIL_BYTES = 512 * 1024
MIN_LIGHT_DIAGNOSTIC_FREE_BYTES = 64 * 1024 * 1024
MIN_SAMPLE_FREE_BYTES = 512 * 1024 * 1024
MIN_SPINDUMP_FREE_BYTES = 2 * 1024 * 1024 * 1024


TOP_LEVEL_COMMANDS = {
    "welcome",
    "docs",
    "settings",
    "config",
    "shortcuts",
    "disable-browser",
    "enable-browser",
    "browser-status",
    "restore-session",
    "open",
    "feedback",
    "feed",
    "themes",
    "claude-teams",
    "codex-teams",
    "omo",
    "omx",
    "omc",
    "hooks",
    "ping",
    "version",
    "capabilities",
    "events",
    "auth",
    "login",
    "logout",
    "vm",
    "cloud",
    "rpc",
    "identify",
    "list-windows",
    "current-window",
    "new-window",
    "focus-window",
    "close-window",
    "move-workspace-to-window",
    "reorder-workspace",
    "workspace-action",
    "move-tab-to-new-workspace",
    "detach-tab",
    "list-workspaces",
    "new-workspace",
    "ssh",
    "remote-daemon-status",
    "new-split",
    "list-panes",
    "list-pane-surfaces",
    "tree",
    "top",
    "focus-pane",
    "new-pane",
    "new-surface",
    "close-surface",
    "move-surface",
    "split-off",
    "reorder-surface",
    "tab-action",
    "rename-tab",
    "drag-surface-to-split",
    "refresh-surfaces",
    "reload-config",
    "surface-health",
    "debug-terminals",
    "trigger-flash",
    "list-panels",
    "focus-panel",
    "close-workspace",
    "select-workspace",
    "rename-workspace",
    "rename-window",
    "current-workspace",
    "read-screen",
    "send",
    "send-key",
    "send-panel",
    "send-key-panel",
    "notify",
    "list-notifications",
    "dismiss-notification",
    "mark-notification-read",
    "open-notification",
    "jump-to-unread",
    "clear-notifications",
    "right-sidebar",
    "set-status",
    "clear-status",
    "list-status",
    "set-progress",
    "clear-progress",
    "log",
    "clear-log",
    "list-log",
    "sidebar-state",
    "set-app-focus",
    "simulate-app-active",
    "capture-pane",
    "resize-pane",
    "pipe-pane",
    "wait-for",
    "swap-pane",
    "break-pane",
    "join-pane",
    "next-window",
    "previous-window",
    "last-window",
    "last-pane",
    "find-window",
    "clear-history",
    "set-hook",
    "popup",
    "bind-key",
    "unbind-key",
    "copy-mode",
    "set-buffer",
    "list-buffers",
    "paste-buffer",
    "respawn-pane",
    "display-message",
    "markdown",
    "browser",
}


SKIPPED_CLI_COMMANDS = {
    "auth login": "opens an external sign-in flow",
    "auth logout": "mutates the signed-in user session",
    "login": "alias for auth login, opens external sign-in",
    "logout": "alias for auth logout, mutates signed-in session",
    "vm new": "can create billable cloud VM resources",
    "vm rm": "can destroy cloud VM resources",
    "vm shell": "opens an interactive VM shell",
    "vm ssh": "opens an interactive VM SSH workspace",
    "vm ssh-attach": "opens an interactive VM SSH session",
    "cloud new": "can create billable cloud VM resources",
    "ssh": "opens an external SSH session",
    "feedback --submit": "can send external feedback",
    "feed clear": "deletes persisted feed state",
    "hooks setup": "modifies user hook config",
    "hooks uninstall": "modifies user hook config",
    "codex install-hooks": "modifies user hook config",
    "codex uninstall-hooks": "modifies user hook config",
}


SKIPPED_SOCKET_METHODS = {
    "auth.begin_sign_in": "opens an external sign-in flow",
    "auth.sign_out": "mutates the signed-in user session",
    "vm.create": "can create billable cloud VM resources",
    "vm.destroy": "can destroy cloud VM resources",
    "vm.exec": "executes commands inside a cloud VM",
    "vm.attach_info": "requires a real VM id",
    "vm.ssh_info": "requires a real VM id",
    "settings.open": "opens UI only, covered through CLI help",
    "feedback.open": "opens UI only",
    "feedback.submit": "can send external feedback",
    "browser.import.dialog": "opens an interactive import UI",
    "browser.import.cookies": "reads browser cookie stores",
    "feed.push": "mutates feed state",
    "feed.permission.reply": "mutates feed state",
    "feed.question.reply": "mutates feed state",
    "feed.exit_plan.reply": "mutates feed state",
    "events.stream": "streaming protocol, covered by cmux events --limit",
    "session.restore_previous": "mutates app session state",
    "workspace.remote.configure": "requires remote workspace credentials",
    "workspace.remote.foreground_auth_ready": "requires remote workspace state",
    "workspace.remote.reconnect": "requires remote workspace state",
    "workspace.remote.disconnect": "requires remote workspace state",
    "workspace.remote.status": "requires remote workspace state",
    "workspace.remote.terminal_session_end": "requires remote workspace state",
}


def now_slug() -> str:
    return dt.datetime.now(dt.timezone.utc).strftime("%Y%m%dT%H%M%SZ")


def parse_duration(raw: str) -> float:
    value = raw.strip().lower()
    if value.endswith("ms"):
        return float(value[:-2]) / 1000.0
    if value.endswith("s"):
        return float(value[:-1])
    if value.endswith("m"):
        return float(value[:-1]) * 60.0
    if value.endswith("h"):
        return float(value[:-1]) * 60.0 * 60.0
    return float(value)


def run_capture(
    argv: list[str],
    *,
    timeout: float,
    env: dict[str, str] | None = None,
    stdin: str | None = None,
) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        argv,
        input=stdin,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        timeout=timeout,
        env=env,
        check=False,
    )


def truncate(value: str, limit: int = 4000) -> str:
    if len(value) <= limit:
        return value
    return value[:limit] + f"\n... truncated {len(value) - limit} bytes ..."


def safe_write_text(path: pathlib.Path, value: str) -> bool:
    try:
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(value, encoding="utf-8", errors="replace")
        return True
    except OSError as exc:
        print(f"WARN: failed to write {path}: {exc}", file=sys.stderr, flush=True)
        return False


def json_dump_line(handle: Any, payload: dict[str, Any]) -> None:
    try:
        handle.write(json.dumps(payload, sort_keys=True, separators=(",", ":")) + "\n")
        handle.flush()
    except OSError as exc:
        print(f"WARN: failed to append result row: {exc}", file=sys.stderr, flush=True)


@dataclasses.dataclass(frozen=True)
class CliCase:
    name: str
    argv_factory: Callable[["StressContext"], list[str]]
    expect_codes: tuple[int, ...] = (0,)
    no_socket: bool = False
    timeout: float | None = None
    stdin_factory: Callable[["StressContext"], str | None] | None = None
    env_factory: Callable[["StressContext"], dict[str, str]] | None = None
    layout_mutation: bool = False
    covered_command: str | None = None
    skip_reason: str | None = None


@dataclasses.dataclass(frozen=True)
class SocketCase:
    name: str
    method: str
    params_factory: Callable[["StressContext"], dict[str, Any]]
    expect_ok: bool | None = True
    timeout: float | None = None
    layout_mutation: bool = False
    skip_reason: str | None = None


@dataclasses.dataclass
class CaseResult:
    kind: str
    name: str
    ok: bool
    elapsed_ms: float
    details: dict[str, Any]


class RawSocketClient:
    def __init__(self, socket_path: str) -> None:
        self.socket_path = socket_path
        self._next_id = 1
        self._lock = threading.Lock()

    def call(self, method: str, params: dict[str, Any] | None = None, timeout: float = DEFAULT_TIMEOUT_SECONDS) -> dict[str, Any]:
        with self._lock:
            req_id = self._next_id
            self._next_id += 1
        payload = {"id": req_id, "method": method, "params": params or {}}
        line = json.dumps(payload, separators=(",", ":")) + "\n"
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as sock:
            sock.settimeout(timeout)
            sock.connect(self.socket_path)
            sock.sendall(line.encode("utf-8"))
            data = bytearray()
            deadline = time.monotonic() + timeout
            while b"\n" not in data:
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    raise TimeoutError(f"timed out waiting for {method}")
                sock.settimeout(remaining)
                chunk = sock.recv(8192)
                if not chunk:
                    raise RuntimeError(f"socket closed while waiting for {method}")
                data.extend(chunk)
        raw = data.split(b"\n", 1)[0].decode("utf-8", errors="replace")
        response = json.loads(raw)
        if response.get("id") != req_id:
            raise RuntimeError(f"mismatched response id for {method}: {response!r}")
        return response


class Diagnostics:
    def __init__(self, artifacts_dir: pathlib.Path, tag: str | None, socket_path: str, app_pgrep: str | None) -> None:
        self.artifacts_dir = artifacts_dir
        self.tag = tag
        self.socket_path = socket_path
        self.app_pgrep = app_pgrep
        self.counter = 0
        self._lock = threading.Lock()

    def app_pids(self) -> list[int]:
        patterns: list[str] = []
        if self.app_pgrep:
            patterns.append(self.app_pgrep)
        if self.tag:
            patterns.append(f"cmux DEV {self.tag}.app/Contents/MacOS/cmux DEV")
            patterns.append(f"cmux DEV {self.tag}")
        patterns.append("cmux DEV")
        seen: set[int] = set()
        for pattern in patterns:
            try:
                proc = run_capture(["pgrep", "-f", pattern], timeout=3)
            except Exception:
                continue
            if proc.returncode != 0:
                continue
            for line in proc.stdout.splitlines():
                try:
                    pid = int(line.strip())
                except ValueError:
                    continue
                if pid != os.getpid():
                    seen.add(pid)
            if seen:
                break
        return sorted(seen)

    def capture(self, reason: str, details: dict[str, Any] | None = None) -> pathlib.Path:
        with self._lock:
            self.counter += 1
            capture_dir = self.artifacts_dir / f"diag-{self.counter:04d}-{safe_name(reason)}"
            try:
                capture_dir.mkdir(parents=True, exist_ok=True)
            except OSError as exc:
                print(f"WARN: failed to create diagnostics directory {capture_dir}: {exc}", file=sys.stderr, flush=True)
                return capture_dir

        details_payload = {
            "reason": reason,
            "details": details or {},
            "captured_at": dt.datetime.now(dt.timezone.utc).isoformat(),
            "socket_path": self.socket_path,
            "tag": self.tag,
        }
        safe_write_text(capture_dir / "details.json", json.dumps(details_payload, indent=2, sort_keys=True))

        self._capture_command(capture_dir, "ps.txt", ["ps", "-axo", "pid,ppid,stat,etime,pcpu,pmem,command"])
        self._capture_command(capture_dir, "lsof-socket.txt", ["lsof", "-nU", self.socket_path])
        if self.free_bytes(capture_dir) > MIN_LIGHT_DIAGNOSTIC_FREE_BYTES:
            self._capture_command(
                capture_dir,
                "log-show-cmux.txt",
                ["log", "show", "--last", "2m", "--style", "compact", "--predicate", 'process CONTAINS "cmux"'],
                timeout=20,
            )
        else:
            safe_write_text(capture_dir / "log-show-cmux.txt", "skipped: low free disk space\n")

        for pid in self.app_pids():
            if self.free_bytes(capture_dir) > MIN_SAMPLE_FREE_BYTES:
                self._capture_command(capture_dir, f"sample-{pid}.txt", ["sample", str(pid), "2"], timeout=8)
            else:
                safe_write_text(capture_dir / f"sample-{pid}.txt", "skipped: low free disk space\n")
            if self.free_bytes(capture_dir) > MIN_SPINDUMP_FREE_BYTES:
                self._capture_command(
                    capture_dir,
                    f"spindump-{pid}-command.txt",
                    ["spindump", str(pid), "5", "-file", str(capture_dir / f"spindump-{pid}.spindump")],
                    timeout=15,
                )
            else:
                safe_write_text(capture_dir / f"spindump-{pid}-command.txt", "skipped: low free disk space\n")

        for path in self._interesting_log_paths():
            self._copy_log_tail(path, capture_dir / f"log-{safe_name(path.name)}")

        if self.free_bytes(capture_dir) > MIN_SAMPLE_FREE_BYTES:
            self._copy_recent_crash_reports(capture_dir)
        else:
            safe_write_text(capture_dir / "crash-reports.txt", "skipped: low free disk space\n")
        return capture_dir

    def free_bytes(self, path: pathlib.Path) -> int:
        try:
            probe = path if path.exists() else path.parent
            return shutil.disk_usage(probe).free
        except OSError:
            return 0

    def _capture_command(
        self,
        capture_dir: pathlib.Path,
        name: str,
        argv: list[str],
        timeout: float = 10,
    ) -> None:
        output_path = capture_dir / name
        try:
            proc = run_capture(argv, timeout=timeout)
            output = f"$ {' '.join(argv)}\nexit={proc.returncode}\n\nSTDOUT\n{proc.stdout}\n\nSTDERR\n{proc.stderr}"
            safe_write_text(output_path, truncate(output, DIAGNOSTIC_TEXT_LIMIT_BYTES))
        except Exception as exc:
            safe_write_text(output_path, f"$ {' '.join(argv)}\nfailed: {exc}\n")

    def _interesting_log_paths(self) -> list[pathlib.Path]:
        paths = []
        if self.tag:
            paths.append(pathlib.Path(f"/tmp/cmux-debug-{self.tag}.log"))
        paths.extend(pathlib.Path(path) for path in glob.glob("/tmp/cmux-debug*.log"))
        paths.extend(pathlib.Path(path) for path in glob.glob("/tmp/cmux-launch-*.out"))
        return [path for path in paths if path.exists() and path.is_file()]

    def _copy_log_tail(self, source: pathlib.Path, target: pathlib.Path) -> None:
        try:
            with source.open("rb") as handle:
                handle.seek(0, os.SEEK_END)
                size = handle.tell()
                handle.seek(max(0, size - DIAGNOSTIC_LOG_TAIL_BYTES))
                data = handle.read(DIAGNOSTIC_LOG_TAIL_BYTES)
            if source.stat().st_size > DIAGNOSTIC_LOG_TAIL_BYTES:
                prefix = f"... tail of {source}, truncated to {DIAGNOSTIC_LOG_TAIL_BYTES} bytes ...\n".encode("utf-8")
                data = prefix + data
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(data)
        except OSError as exc:
            safe_write_text(target, f"failed to copy log tail from {source}: {exc}\n")

    def _copy_recent_crash_reports(self, capture_dir: pathlib.Path) -> None:
        now = time.time()
        candidates: list[pathlib.Path] = []
        roots = [
            pathlib.Path.home() / "Library/Logs/DiagnosticReports",
            pathlib.Path("/Library/Logs/DiagnosticReports"),
            pathlib.Path.home() / ".local/state/cmux/crash",
        ]
        for root in roots:
            if not root.exists():
                continue
            for path in root.glob("*cmux*"):
                try:
                    if now - path.stat().st_mtime <= 60 * 60:
                        candidates.append(path)
                except OSError:
                    pass
        for path in candidates[:20]:
            try:
                shutil.copy2(path, capture_dir / f"crash-{safe_name(path.name)}")
            except OSError:
                pass


def safe_name(value: str) -> str:
    cleaned = "".join(ch if ch.isalnum() or ch in "._-" else "-" for ch in value.lower())
    cleaned = "-".join(part for part in cleaned.split("-") if part)
    return cleaned[:96] or "item"


class StressContext:
    def __init__(
        self,
        *,
        cli_path: str,
        socket_path: str,
        artifacts_dir: pathlib.Path,
        timeout: float,
        diagnostics: Diagnostics,
        tag: str | None,
    ) -> None:
        self.cli_path = cli_path
        self.socket_path = socket_path
        self.artifacts_dir = artifacts_dir
        self.timeout = timeout
        self.diagnostics = diagnostics
        self.tag = tag
        self.raw = RawSocketClient(socket_path)
        self.run_id = now_slug()
        self.workspace_id: str | None = None
        self.surface_id: str | None = None
        self.pane_id: str | None = None
        self.second_pane_id: str | None = None
        self.second_surface_id: str | None = None
        self.browser_surface_id: str | None = None
        self.temp_dir = artifacts_dir / "tmp"
        self.temp_dir.mkdir(parents=True, exist_ok=True)
        self.markdown_path = self.temp_dir / "stress.md"
        self.text_path = self.temp_dir / "stress.txt"
        self.state_path = self.temp_dir / "browser-state.json"
        self.screenshot_path = self.temp_dir / "browser.png"
        self.trace_path = self.temp_dir / "browser-trace.json"
        self.markdown_path.write_text("# cmux stress\n\nsocket and cli stress fixture\n", encoding="utf-8")
        self.text_path.write_text("cmux stress file\n", encoding="utf-8")
        html = "<!doctype html><title>cmux stress</title><main><input id=i value=ready><button id=b>go</button><select id=s><option>a</option><option>b</option></select><p>stress body</p></main>"
        self.browser_url = "data:text/html," + urllib.parse.quote(html, safe="")

    def base_env(self) -> dict[str, str]:
        env = dict(os.environ)
        env["CMUX_SOCKET_PATH"] = self.socket_path
        env["CMUX_CLI_SENTRY_DISABLED"] = "1"
        env["CMUX_CLAUDE_HOOK_SENTRY_DISABLED"] = "1"
        if self.tag:
            env["CMUX_TAG"] = self.tag
            env["CMUX_BUNDLE_ID"] = f"com.cmuxterm.app.debug.{self.tag.replace('-', '.')}"
        env.pop("CMUX_SOCKET", None)
        env.pop("CMUX_SOCKET_PASSWORD", None)
        env.pop("CMUX_WORKSPACE_ID", None)
        env.pop("CMUX_SURFACE_ID", None)
        env.pop("CMUX_TAB_ID", None)
        env.pop("CMUX_PANEL_ID", None)
        return env

    def no_socket_env(self) -> dict[str, str]:
        env = self.base_env()
        env.pop("CMUX_SOCKET_PATH", None)
        env["CMUX_BUNDLE_ID"] = f"com.cmuxterm.stress.{self.run_id.lower()}"
        return env

    def setup(self) -> None:
        self.require_socket_ready()
        created = self.socket_result(
            "workspace.create",
            {
                "title": f"stress-{self.run_id}",
                "cwd": str(pathlib.Path.cwd()),
                "focus": True,
            },
            timeout=max(self.timeout, 20),
        )
        self.workspace_id = string_or_none(created.get("workspace_id")) or string_or_none(created.get("workspace_ref"))
        self.refresh_handles()
        if not self.workspace_id:
            raise RuntimeError("failed to resolve stress workspace id")

        # Ensure the workspace has enough structure for move/split/swap cases.
        try_ignore(lambda: self.socket_result("surface.create", {"workspace_id": self.workspace_id, "type": "terminal", "focus": False}))
        pane_payload = try_ignore(lambda: self.socket_result("pane.create", {"workspace_id": self.workspace_id, "type": "terminal", "direction": "right", "focus": False}))
        if isinstance(pane_payload, dict):
            self.second_pane_id = string_or_none(pane_payload.get("pane_id"))
            self.second_surface_id = string_or_none(pane_payload.get("surface_id"))
        self.refresh_handles()

        browser_payload = try_ignore(
            lambda: self.socket_result(
                "browser.open_split",
                {
                    "workspace_id": self.workspace_id,
                    "surface_id": self.surface_id,
                    "url": self.browser_url,
                    "focus": False,
                },
                timeout=max(self.timeout, 20),
            )
        )
        if isinstance(browser_payload, dict):
            self.browser_surface_id = string_or_none(browser_payload.get("surface_id"))

        self.refresh_handles()

    def require_socket_ready(self) -> None:
        deadline = time.monotonic() + max(self.timeout, 30)
        last_error: Exception | None = None
        while time.monotonic() < deadline:
            try:
                response = self.raw.call("system.ping", timeout=min(self.timeout, 5))
                if response.get("ok") is True:
                    return
            except Exception as exc:
                last_error = exc
                time.sleep(0.2)
        raise RuntimeError(f"socket not ready: {last_error}")

    def socket_result(self, method: str, params: dict[str, Any] | None = None, timeout: float | None = None) -> dict[str, Any]:
        response = self.raw.call(method, params or {}, timeout=timeout or self.timeout)
        if response.get("ok") is not True:
            raise RuntimeError(f"{method} failed: {response.get('error')}")
        result = response.get("result")
        return result if isinstance(result, dict) else {}

    def refresh_handles(self) -> None:
        ident = try_ignore(lambda: self.socket_result("system.identify", timeout=self.timeout))
        if isinstance(ident, dict):
            focused = ident.get("focused")
            if isinstance(focused, dict):
                self.workspace_id = string_or_none(focused.get("workspace_id")) or self.workspace_id
                self.pane_id = string_or_none(focused.get("pane_id")) or self.pane_id
        if self.workspace_id:
            panes = try_ignore(lambda: self.socket_result("pane.list", {"workspace_id": self.workspace_id}, timeout=self.timeout))
            if isinstance(panes, dict):
                pane_rows = panes.get("panes")
                if isinstance(pane_rows, list) and pane_rows:
                    self.pane_id = string_or_none(pane_rows[0].get("id")) or self.pane_id
                    if len(pane_rows) > 1:
                        self.second_pane_id = string_or_none(pane_rows[1].get("id")) or self.second_pane_id
            surfaces = try_ignore(lambda: self.socket_result("surface.list", {"workspace_id": self.workspace_id}, timeout=self.timeout))
            if isinstance(surfaces, dict):
                rows = surfaces.get("surfaces")
                if isinstance(rows, list) and rows:
                    terminal_ids = [
                        surface_id
                        for row in rows
                        if isinstance(row, dict)
                        and row.get("type") == "terminal"
                        for surface_id in [string_or_none(row.get("id"))]
                        if surface_id
                    ]
                    browser_ids = [
                        surface_id
                        for row in rows
                        if isinstance(row, dict)
                        and row.get("type") == "browser"
                        for surface_id in [string_or_none(row.get("id"))]
                        if surface_id
                    ]
                    if self.surface_id not in terminal_ids:
                        self.surface_id = terminal_ids[0] if terminal_ids else None
                    second_candidates = [surface_id for surface_id in terminal_ids if surface_id != self.surface_id]
                    if self.second_surface_id not in second_candidates:
                        self.second_surface_id = second_candidates[0] if second_candidates else None
                    if self.browser_surface_id not in browser_ids:
                        self.browser_surface_id = browser_ids[0] if browser_ids else None

    def ensure_core_surfaces(self) -> None:
        self.refresh_handles()
        if not self.workspace_id:
            return
        if not self.surface_id:
            self.surface_id = self.create_surface_for_case("primary")
        if not self.second_pane_id:
            pane_payload = try_ignore(
                lambda: self.socket_result(
                    "pane.create",
                    {
                        "workspace_id": self.workspace_id,
                        "type": "terminal",
                        "direction": "right",
                        "focus": False,
                    },
                    timeout=max(self.timeout, 20),
                )
            )
            if isinstance(pane_payload, dict):
                self.second_pane_id = string_or_none(pane_payload.get("pane_id"))
                self.second_surface_id = string_or_none(pane_payload.get("surface_id")) or self.second_surface_id
        if not self.second_surface_id:
            self.second_surface_id = self.create_surface_for_case("secondary")
        if not self.browser_surface_id and self.surface_id:
            browser_payload = try_ignore(
                lambda: self.socket_result(
                    "browser.open_split",
                    {
                        "workspace_id": self.workspace_id,
                        "surface_id": self.surface_id,
                        "url": self.browser_url,
                        "focus": False,
                    },
                    timeout=max(self.timeout, 20),
                )
            )
            if isinstance(browser_payload, dict):
                self.browser_surface_id = string_or_none(browser_payload.get("surface_id"))
        self.refresh_handles()

    def current_window_id(self) -> str:
        result = self.socket_result("window.current", timeout=self.timeout)
        return require(string_or_none(result.get("window_id")), "window")

    def create_window_for_case(self, label: str) -> str:
        result = self.socket_result("window.create", timeout=max(self.timeout, 20))
        return require(string_or_none(result.get("window_id")), f"{label} window")

    def create_workspace_for_case(self, label: str, window_id: str | None = None) -> str:
        params: dict[str, Any] = {
            "title": f"stress-{label}-{uuid.uuid4().hex[:8]}",
            "cwd": str(pathlib.Path.cwd()),
            "focus": False,
        }
        if window_id:
            params["window_id"] = window_id
        result = self.socket_result("workspace.create", params, timeout=max(self.timeout, 20))
        return require(string_or_none(result.get("workspace_id")), f"{label} workspace")

    def create_notification_for_case(self, label: str) -> str:
        title = f"stress-{label}-{uuid.uuid4().hex[:8]}"
        self.socket_result(
            "notification.create",
            {
                "workspace_id": self.workspace_id,
                "surface_id": self.surface_id,
                "title": title,
                "body": "socket stress",
            },
            timeout=self.timeout,
        )
        listed = self.socket_result("notification.list", timeout=self.timeout)
        for row in listed.get("notifications", []):
            if isinstance(row, dict) and row.get("title") == title:
                return require(string_or_none(row.get("id")), f"{label} notification")
        raise RuntimeError(f"missing {label} notification")

    def create_surface_for_case(self, label: str) -> str:
        result = self.socket_result(
            "surface.create",
            {
                "workspace_id": self.workspace_id,
                "type": "terminal",
                "focus": False,
            },
            timeout=max(self.timeout, 20),
        )
        return require(string_or_none(result.get("surface_id")), f"{label} surface")

    def repair_state(self) -> None:
        self.refresh_handles()
        if not self.workspace_id:
            return
        surfaces = try_ignore(lambda: self.socket_result("surface.list", {"workspace_id": self.workspace_id}, timeout=self.timeout))
        if isinstance(surfaces, dict):
            rows = [row for row in surfaces.get("surfaces", []) if isinstance(row, dict)]
            preserved = {
                surface_id
                for surface_id in [self.surface_id, self.second_surface_id, self.browser_surface_id]
                if surface_id
            }
            removable_rows = [
                row for row in rows
                if string_or_none(row.get("id")) not in preserved
            ]
            for row in removable_rows[7:]:
                sid = string_or_none(row.get("id"))
                if sid:
                    try_ignore(lambda sid=sid: self.socket_result("surface.close", {"workspace_id": self.workspace_id, "surface_id": sid}, timeout=self.timeout))
        workspaces = try_ignore(lambda: self.socket_result("workspace.list", timeout=self.timeout))
        if isinstance(workspaces, dict):
            rows = [row for row in workspaces.get("workspaces", []) if isinstance(row, dict)]
            stress_rows = [
                row for row in rows
                if string_or_none(row.get("id")) != self.workspace_id
                and str(row.get("title", "")).startswith("stress-")
            ]
            for row in stress_rows[4:]:
                wid = string_or_none(row.get("id"))
                if wid:
                    try_ignore(lambda wid=wid: self.socket_result("workspace.close", {"workspace_id": wid}, timeout=self.timeout))
        self.ensure_core_surfaces()

    def cleanup_socket_side_effects(
        self,
        method: str,
        params: dict[str, Any],
        response: dict[str, Any],
    ) -> None:
        result = response.get("result")
        result_dict = result if isinstance(result, dict) else {}
        if method == "window.create":
            window_id = string_or_none(result_dict.get("window_id"))
            if window_id:
                try_ignore(lambda: self.socket_result("window.close", {"window_id": window_id}, timeout=self.timeout))
        elif method == "workspace.create":
            workspace_id = string_or_none(result_dict.get("workspace_id"))
            if workspace_id and workspace_id != self.workspace_id:
                try_ignore(lambda: self.socket_result("workspace.close", {"workspace_id": workspace_id}, timeout=self.timeout))
        elif method == "workspace.move_to_window":
            workspace_id = string_or_none(params.get("workspace_id"))
            window_id = string_or_none(params.get("window_id"))
            if workspace_id and workspace_id != self.workspace_id:
                try_ignore(lambda: self.socket_result("workspace.close", {"workspace_id": workspace_id}, timeout=self.timeout))
            if window_id:
                try_ignore(lambda: self.socket_result("window.close", {"window_id": window_id}, timeout=self.timeout))


def string_or_none(value: Any) -> str | None:
    if isinstance(value, str) and value.strip():
        return value
    return None


def try_ignore(fn: Callable[[], Any]) -> Any | None:
    try:
        return fn()
    except Exception:
        return None


def argv(*parts: str) -> Callable[[StressContext], list[str]]:
    return lambda _ctx: list(parts)


def ctx_argv(factory: Callable[[StressContext], Iterable[str]]) -> Callable[[StressContext], list[str]]:
    return lambda ctx: list(factory(ctx))


def require(value: str | None, label: str) -> str:
    if not value:
        raise RuntimeError(f"missing {label}")
    return value


def build_cli_cases(ctx: StressContext) -> list[CliCase]:
    any_code = tuple(range(0, 128))

    def focus_pane_args(c: StressContext) -> list[str]:
        c.ensure_core_surfaces()
        return [
            "focus-pane",
            "--workspace",
            require(c.workspace_id, "workspace"),
            "--pane",
            require(c.pane_id, "pane"),
        ]

    cases = [
        CliCase("version-flag", argv("--version"), no_socket=True, covered_command="version"),
        CliCase("version-command", argv("version"), no_socket=True, covered_command="version"),
        CliCase("help-flag", argv("--help"), no_socket=True, covered_command="help"),
        CliCase("help-command", argv("help"), no_socket=True, covered_command="help"),
        CliCase("welcome", argv("welcome"), no_socket=True, covered_command="welcome"),
        CliCase("docs", argv("docs"), no_socket=True, covered_command="docs"),
        CliCase("docs-settings", argv("docs", "settings"), no_socket=True, covered_command="docs"),
        CliCase("settings-path", argv("settings", "path"), no_socket=True, covered_command="settings"),
        CliCase("settings-docs", argv("settings", "docs"), no_socket=True, covered_command="settings"),
        CliCase("config-path", argv("config", "path"), no_socket=True, covered_command="config"),
        CliCase("config-doctor", argv("--json", "config", "doctor"), no_socket=True, expect_codes=any_code, covered_command="config"),
        CliCase("shortcuts-help", argv("shortcuts", "--help"), no_socket=True, covered_command="shortcuts"),
        CliCase("disable-browser-help", argv("disable-browser", "--help"), no_socket=True, covered_command="disable-browser"),
        CliCase("enable-browser-help", argv("enable-browser", "--help"), no_socket=True, covered_command="enable-browser"),
        CliCase("browser-status", argv("browser-status", "--json"), no_socket=True, covered_command="browser-status", env_factory=lambda c: c.no_socket_env()),
        CliCase("restore-session-help", argv("restore-session", "--help"), no_socket=True, covered_command="restore-session"),
        CliCase("feedback-help", argv("feedback", "--help"), no_socket=True, covered_command="feedback"),
        CliCase("feed-help", argv("feed", "--help"), no_socket=True, covered_command="feed"),
        CliCase("themes-list", argv("themes", "list"), no_socket=True, expect_codes=any_code, covered_command="themes"),
        CliCase("claude-teams-help", argv("claude-teams", "--help"), no_socket=True, covered_command="claude-teams"),
        CliCase("codex-teams-help", argv("codex-teams", "--help"), no_socket=True, covered_command="codex-teams"),
        CliCase("omo-help", argv("omo", "--help"), no_socket=True, covered_command="omo"),
        CliCase("omx-help", argv("omx", "--help"), no_socket=True, covered_command="omx"),
        CliCase("omc-help", argv("omc", "--help"), no_socket=True, covered_command="omc"),
        CliCase("hooks-help", argv("hooks", "--help"), no_socket=True, covered_command="hooks"),
        CliCase("remote-daemon-status", argv("remote-daemon-status"), no_socket=True, expect_codes=any_code, covered_command="remote-daemon-status"),
        CliCase("ping", argv("ping"), covered_command="ping"),
        CliCase("capabilities", argv("capabilities"), covered_command="capabilities"),
        CliCase("events-limit", argv("events", "--after", "0", "--limit", "1"), timeout=12, covered_command="events"),
        CliCase("auth-status", argv("auth", "status"), expect_codes=any_code, covered_command="auth"),
        CliCase("login-help", argv("login", "--help"), no_socket=True, covered_command="login"),
        CliCase("logout-help", argv("logout", "--help"), no_socket=True, covered_command="logout"),
        CliCase("vm-list", argv("vm", "ls"), expect_codes=any_code, covered_command="vm"),
        CliCase("cloud-list", argv("cloud", "ls"), expect_codes=any_code, covered_command="cloud"),
        CliCase("rpc-system-ping", argv("rpc", "system.ping", "{}"), covered_command="rpc"),
        CliCase("identify", argv("identify", "--no-caller"), covered_command="identify"),
        CliCase("list-windows", argv("list-windows"), covered_command="list-windows"),
        CliCase("current-window", argv("current-window"), covered_command="current-window"),
        CliCase("new-window-help", argv("new-window", "--help"), no_socket=True, covered_command="new-window"),
        CliCase("focus-window-current", argv("focus-window", "--window", "window:1"), expect_codes=any_code, covered_command="focus-window"),
        CliCase("close-window-help", argv("close-window", "--help"), no_socket=True, covered_command="close-window"),
        CliCase("move-workspace-to-window-help", argv("move-workspace-to-window", "--help"), no_socket=True, covered_command="move-workspace-to-window"),
        CliCase("list-workspaces", argv("list-workspaces"), covered_command="list-workspaces"),
        CliCase("new-workspace", ctx_argv(lambda c: ["new-workspace", "--name", f"stress-extra-{uuid.uuid4().hex[:8]}", "--focus", "false"]), covered_command="new-workspace", layout_mutation=True),
        CliCase("select-workspace", ctx_argv(lambda c: ["select-workspace", "--workspace", require(c.workspace_id, "workspace")]), covered_command="select-workspace"),
        CliCase("rename-workspace", ctx_argv(lambda c: ["rename-workspace", "--workspace", require(c.workspace_id, "workspace"), f"stress-{c.run_id}"]), covered_command="rename-workspace"),
        CliCase("rename-window", ctx_argv(lambda c: ["rename-window", "--workspace", require(c.workspace_id, "workspace"), f"stress-{c.run_id}"]), covered_command="rename-window"),
        CliCase("current-workspace", argv("current-workspace"), covered_command="current-workspace"),
        CliCase("workspace-action-pin", ctx_argv(lambda c: ["workspace-action", "--workspace", require(c.workspace_id, "workspace"), "--action", "pin"]), expect_codes=any_code, covered_command="workspace-action"),
        CliCase("workspace-action-unpin", ctx_argv(lambda c: ["workspace-action", "--workspace", require(c.workspace_id, "workspace"), "--action", "unpin"]), expect_codes=any_code, covered_command="workspace-action"),
        CliCase("reorder-workspace", ctx_argv(lambda c: ["reorder-workspace", "--workspace", require(c.workspace_id, "workspace"), "--index", "0"]), expect_codes=any_code, covered_command="reorder-workspace"),
        CliCase("ssh-help", argv("ssh", "--help"), no_socket=True, covered_command="ssh"),
        CliCase("list-panes", ctx_argv(lambda c: ["list-panes", "--workspace", require(c.workspace_id, "workspace")]), covered_command="list-panes"),
        CliCase("list-pane-surfaces", ctx_argv(lambda c: ["list-pane-surfaces", "--workspace", require(c.workspace_id, "workspace")]), covered_command="list-pane-surfaces"),
        CliCase("tree", argv("--json", "tree", "--all"), covered_command="tree"),
        CliCase("top", argv("--json", "top", "--all"), timeout=20, covered_command="top"),
        CliCase("focus-pane", ctx_argv(focus_pane_args), covered_command="focus-pane"),
        CliCase("new-pane", ctx_argv(lambda c: ["new-pane", "--workspace", require(c.workspace_id, "workspace"), "--type", "terminal", "--direction", "right", "--focus", "false"]), covered_command="new-pane", layout_mutation=True),
        CliCase("new-surface", ctx_argv(lambda c: ["new-surface", "--workspace", require(c.workspace_id, "workspace"), "--type", "terminal", "--focus", "false"]), covered_command="new-surface", layout_mutation=True),
        CliCase("new-split", ctx_argv(lambda c: ["new-split", "right", "--workspace", require(c.workspace_id, "workspace"), "--surface", require(c.surface_id, "surface"), "--focus", "false"]), expect_codes=any_code, covered_command="new-split", layout_mutation=True),
        CliCase("move-surface", ctx_argv(lambda c: ["move-surface", "--workspace", require(c.workspace_id, "workspace"), "--surface", require(c.surface_id, "surface"), "--index", "0"]), expect_codes=any_code, covered_command="move-surface"),
        CliCase("split-off", ctx_argv(lambda c: ["split-off", "--workspace", require(c.workspace_id, "workspace"), "--surface", require(c.second_surface_id, "second surface"), "right", "--focus", "false"]), expect_codes=any_code, covered_command="split-off", layout_mutation=True),
        CliCase("reorder-surface", ctx_argv(lambda c: ["reorder-surface", "--workspace", require(c.workspace_id, "workspace"), "--surface", require(c.surface_id, "surface"), "--index", "0"]), expect_codes=any_code, covered_command="reorder-surface"),
        CliCase("tab-action-rename", ctx_argv(lambda c: ["tab-action", "--workspace", require(c.workspace_id, "workspace"), "--tab", require(c.surface_id, "surface"), "--action", "rename", "--title", "stress tab"]), expect_codes=any_code, covered_command="tab-action"),
        CliCase("rename-tab", ctx_argv(lambda c: ["rename-tab", "--workspace", require(c.workspace_id, "workspace"), "--surface", require(c.surface_id, "surface"), "stress tab"]), expect_codes=any_code, covered_command="rename-tab"),
        CliCase("move-tab-to-new-workspace-help", argv("move-tab-to-new-workspace", "--help"), no_socket=True, covered_command="move-tab-to-new-workspace"),
        CliCase("detach-tab-help", argv("detach-tab", "--help"), no_socket=True, covered_command="detach-tab"),
        CliCase("drag-surface-to-split", ctx_argv(lambda c: ["drag-surface-to-split", "--workspace", require(c.workspace_id, "workspace"), "--surface", require(c.second_surface_id, "second surface"), "down", "--focus", "false"]), expect_codes=any_code, covered_command="drag-surface-to-split", layout_mutation=True),
        CliCase("refresh-surfaces", argv("refresh-surfaces"), covered_command="refresh-surfaces"),
        CliCase("reload-config", argv("reload-config"), expect_codes=any_code, covered_command="reload-config"),
        CliCase("surface-health", ctx_argv(lambda c: ["surface-health", "--workspace", require(c.workspace_id, "workspace")]), covered_command="surface-health"),
        CliCase("debug-terminals", argv("debug-terminals"), covered_command="debug-terminals"),
        CliCase("trigger-flash", ctx_argv(lambda c: ["trigger-flash", "--workspace", require(c.workspace_id, "workspace"), "--surface", require(c.surface_id, "surface")]), covered_command="trigger-flash"),
        CliCase("list-panels", ctx_argv(lambda c: ["list-panels", "--workspace", require(c.workspace_id, "workspace")]), covered_command="list-panels"),
        CliCase("focus-panel", ctx_argv(lambda c: ["focus-panel", "--workspace", require(c.workspace_id, "workspace"), "--panel", require(c.surface_id, "surface")]), covered_command="focus-panel"),
        CliCase("close-surface-help", argv("close-surface", "--help"), no_socket=True, covered_command="close-surface"),
        CliCase("close-workspace-help", argv("close-workspace", "--help"), no_socket=True, covered_command="close-workspace"),
        CliCase("read-screen", ctx_argv(lambda c: ["read-screen", "--workspace", require(c.workspace_id, "workspace"), "--surface", require(c.surface_id, "surface"), "--lines", "5"]), expect_codes=any_code, covered_command="read-screen"),
        CliCase("send", ctx_argv(lambda c: ["send", "--workspace", require(c.workspace_id, "workspace"), "--surface", require(c.surface_id, "surface"), "printf stress-cli\\n"]), expect_codes=any_code, covered_command="send"),
        CliCase("send-key", ctx_argv(lambda c: ["send-key", "--workspace", require(c.workspace_id, "workspace"), "--surface", require(c.surface_id, "surface"), "enter"]), expect_codes=any_code, covered_command="send-key"),
        CliCase("send-panel", ctx_argv(lambda c: ["send-panel", "--workspace", require(c.workspace_id, "workspace"), "--panel", require(c.surface_id, "surface"), "printf stress-panel\\n"]), expect_codes=any_code, covered_command="send-panel"),
        CliCase("send-key-panel", ctx_argv(lambda c: ["send-key-panel", "--workspace", require(c.workspace_id, "workspace"), "--panel", require(c.surface_id, "surface"), "enter"]), expect_codes=any_code, covered_command="send-key-panel"),
        CliCase("notify", ctx_argv(lambda c: ["notify", "--workspace", require(c.workspace_id, "workspace"), "--surface", require(c.surface_id, "surface"), "--title", "stress", "--body", "cli"]), covered_command="notify"),
        CliCase("list-notifications", argv("list-notifications"), covered_command="list-notifications"),
        CliCase("dismiss-notification", argv("dismiss-notification", "--all-read"), expect_codes=any_code, covered_command="dismiss-notification"),
        CliCase("mark-notification-read", argv("mark-notification-read", "--all"), expect_codes=any_code, covered_command="mark-notification-read"),
        CliCase("open-notification-help", argv("open-notification", "--help"), no_socket=True, covered_command="open-notification"),
        CliCase("jump-to-unread", argv("jump-to-unread"), expect_codes=any_code, covered_command="jump-to-unread"),
        CliCase("clear-notifications", ctx_argv(lambda c: ["clear-notifications", "--workspace", require(c.workspace_id, "workspace")]), expect_codes=any_code, covered_command="clear-notifications"),
        CliCase("right-sidebar-mode", argv("right-sidebar", "mode"), expect_codes=any_code, covered_command="right-sidebar"),
        CliCase("set-status", ctx_argv(lambda c: ["set-status", "stress", "running", "--workspace", require(c.workspace_id, "workspace"), "--icon", "hammer", "--color", "#ff9500"]), expect_codes=any_code, covered_command="set-status"),
        CliCase("list-status", ctx_argv(lambda c: ["list-status", "--workspace", require(c.workspace_id, "workspace")]), expect_codes=any_code, covered_command="list-status"),
        CliCase("clear-status", ctx_argv(lambda c: ["clear-status", "stress", "--workspace", require(c.workspace_id, "workspace")]), expect_codes=any_code, covered_command="clear-status"),
        CliCase("set-progress", ctx_argv(lambda c: ["set-progress", "0.5", "--label", "stress", "--workspace", require(c.workspace_id, "workspace")]), expect_codes=any_code, covered_command="set-progress"),
        CliCase("clear-progress", ctx_argv(lambda c: ["clear-progress", "--workspace", require(c.workspace_id, "workspace")]), expect_codes=any_code, covered_command="clear-progress"),
        CliCase("log", ctx_argv(lambda c: ["log", "--workspace", require(c.workspace_id, "workspace"), "--level", "info", "--source", "stress", "hello"]), expect_codes=any_code, covered_command="log"),
        CliCase("list-log", ctx_argv(lambda c: ["list-log", "--workspace", require(c.workspace_id, "workspace"), "--limit", "3"]), expect_codes=any_code, covered_command="list-log"),
        CliCase("clear-log", ctx_argv(lambda c: ["clear-log", "--workspace", require(c.workspace_id, "workspace")]), expect_codes=any_code, covered_command="clear-log"),
        CliCase("sidebar-state", ctx_argv(lambda c: ["sidebar-state", "--workspace", require(c.workspace_id, "workspace")]), expect_codes=any_code, covered_command="sidebar-state"),
        CliCase("set-app-focus-clear", argv("set-app-focus", "clear"), covered_command="set-app-focus"),
        CliCase("simulate-app-active", argv("simulate-app-active"), covered_command="simulate-app-active"),
        CliCase("capture-pane", ctx_argv(lambda c: ["capture-pane", "--workspace", require(c.workspace_id, "workspace"), "--surface", require(c.surface_id, "surface"), "--lines", "5"]), expect_codes=any_code, covered_command="capture-pane"),
        CliCase("resize-pane", ctx_argv(lambda c: ["resize-pane", "--workspace", require(c.workspace_id, "workspace"), "--pane", require(c.pane_id, "pane"), "-R", "--amount", "1"]), expect_codes=any_code, covered_command="resize-pane"),
        CliCase("pipe-pane", ctx_argv(lambda c: ["pipe-pane", "--workspace", require(c.workspace_id, "workspace"), "--surface", require(c.surface_id, "surface"), "--command", f"cat > {c.temp_dir / 'pipe-pane.txt'}"]), expect_codes=any_code, covered_command="pipe-pane"),
        CliCase("wait-for-signal", argv("wait-for", "-S", "stress-token"), expect_codes=any_code, covered_command="wait-for"),
        CliCase("swap-pane", ctx_argv(lambda c: ["swap-pane", "--workspace", require(c.workspace_id, "workspace"), "--pane", require(c.pane_id, "pane"), "--target-pane", require(c.second_pane_id, "second pane"), "--focus", "false"]), expect_codes=any_code, covered_command="swap-pane", layout_mutation=True),
        CliCase("break-pane", ctx_argv(lambda c: ["break-pane", "--workspace", require(c.workspace_id, "workspace"), "--surface", require(c.second_surface_id, "second surface"), "--focus", "false"]), expect_codes=any_code, covered_command="break-pane", layout_mutation=True),
        CliCase("join-pane", ctx_argv(lambda c: ["join-pane", "--workspace", require(c.workspace_id, "workspace"), "--surface", require(c.second_surface_id, "second surface"), "--target-pane", require(c.pane_id, "pane"), "--focus", "false"]), expect_codes=any_code, covered_command="join-pane", layout_mutation=True),
        CliCase("next-window", argv("next-window"), expect_codes=any_code, covered_command="next-window"),
        CliCase("previous-window", argv("previous-window"), expect_codes=any_code, covered_command="previous-window"),
        CliCase("last-window", argv("last-window"), expect_codes=any_code, covered_command="last-window"),
        CliCase("last-pane", ctx_argv(lambda c: ["last-pane", "--workspace", require(c.workspace_id, "workspace")]), expect_codes=any_code, covered_command="last-pane"),
        CliCase("find-window", argv("find-window", "stress"), expect_codes=any_code, covered_command="find-window"),
        CliCase("clear-history", ctx_argv(lambda c: ["clear-history", "--workspace", require(c.workspace_id, "workspace"), "--surface", require(c.surface_id, "surface")]), expect_codes=any_code, covered_command="clear-history"),
        CliCase("set-hook-list", argv("set-hook", "--list"), expect_codes=any_code, covered_command="set-hook"),
        CliCase("popup", argv("popup"), expect_codes=any_code, covered_command="popup"),
        CliCase("bind-key", argv("bind-key"), expect_codes=any_code, covered_command="bind-key"),
        CliCase("unbind-key", argv("unbind-key"), expect_codes=any_code, covered_command="unbind-key"),
        CliCase("copy-mode", argv("copy-mode"), expect_codes=any_code, covered_command="copy-mode"),
        CliCase("set-buffer", argv("set-buffer", "--name", "stress", "buffer text"), expect_codes=any_code, covered_command="set-buffer"),
        CliCase("list-buffers", argv("list-buffers"), expect_codes=any_code, covered_command="list-buffers"),
        CliCase("paste-buffer", ctx_argv(lambda c: ["paste-buffer", "--name", "stress", "--workspace", require(c.workspace_id, "workspace"), "--surface", require(c.surface_id, "surface")]), expect_codes=any_code, covered_command="paste-buffer"),
        CliCase("respawn-pane", ctx_argv(lambda c: ["respawn-pane", "--workspace", require(c.workspace_id, "workspace"), "--surface", require(c.surface_id, "surface"), "--command", "printf respawn\\n"]), expect_codes=any_code, covered_command="respawn-pane"),
        CliCase("display-message", argv("display-message", "-p", "stress"), expect_codes=any_code, covered_command="display-message"),
        CliCase("open-file", ctx_argv(lambda c: ["open", str(c.text_path), "--workspace", require(c.workspace_id, "workspace"), "--focus", "false"]), expect_codes=any_code, covered_command="open", layout_mutation=True),
        CliCase("markdown-open", ctx_argv(lambda c: ["markdown", "open", str(c.markdown_path), "--workspace", require(c.workspace_id, "workspace"), "--focus", "false"]), expect_codes=any_code, covered_command="markdown", layout_mutation=True),
        CliCase("browser-help", argv("browser", "--help"), no_socket=True, covered_command="browser"),
    ]

    if ctx.browser_surface_id:
        cases.extend(browser_cli_cases())
    else:
        cases.append(CliCase("browser-skipped", argv("browser", "--help"), no_socket=True, covered_command="browser", skip_reason="browser surface was not created"))

    return cases


def browser_cli_cases() -> list[CliCase]:
    any_code = tuple(range(0, 128))
    return [
        CliCase("browser-identify", ctx_argv(lambda c: ["browser", "identify", "--surface", require(c.browser_surface_id, "browser surface")]), expect_codes=any_code, covered_command="browser"),
        CliCase("browser-open-alias", ctx_argv(lambda c: ["browser", "--surface", require(c.browser_surface_id, "browser surface"), "open", c.browser_url]), expect_codes=any_code, covered_command="browser"),
        CliCase("open-browser-alias", ctx_argv(lambda c: ["open-browser", "--surface", require(c.browser_surface_id, "browser surface"), c.browser_url]), expect_codes=any_code, covered_command="open-browser"),
        CliCase("navigate", ctx_argv(lambda c: ["navigate", "--surface", require(c.browser_surface_id, "browser surface"), c.browser_url]), expect_codes=any_code, covered_command="navigate"),
        CliCase("browser-navigate", ctx_argv(lambda c: ["browser", "--surface", require(c.browser_surface_id, "browser surface"), "navigate", c.browser_url, "--snapshot-after"]), expect_codes=any_code, covered_command="browser"),
        CliCase("browser-reload", ctx_argv(lambda c: ["browser", "--surface", require(c.browser_surface_id, "browser surface"), "reload"]), expect_codes=any_code, covered_command="browser"),
        CliCase("browser-back", ctx_argv(lambda c: ["browser-back", "--surface", require(c.browser_surface_id, "browser surface")]), expect_codes=any_code, covered_command="browser-back"),
        CliCase("browser-forward", ctx_argv(lambda c: ["browser-forward", "--surface", require(c.browser_surface_id, "browser surface")]), expect_codes=any_code, covered_command="browser-forward"),
        CliCase("browser-reload-alias", ctx_argv(lambda c: ["browser-reload", "--surface", require(c.browser_surface_id, "browser surface")]), expect_codes=any_code, covered_command="browser-reload"),
        CliCase("get-url-alias", ctx_argv(lambda c: ["get-url", "--surface", require(c.browser_surface_id, "browser surface")]), expect_codes=any_code, covered_command="get-url"),
        CliCase("focus-webview-alias", ctx_argv(lambda c: ["focus-webview", "--surface", require(c.browser_surface_id, "browser surface")]), expect_codes=any_code, covered_command="focus-webview"),
        CliCase("is-webview-focused-alias", ctx_argv(lambda c: ["is-webview-focused", "--surface", require(c.browser_surface_id, "browser surface")]), expect_codes=any_code, covered_command="is-webview-focused"),
        CliCase("browser-snapshot", ctx_argv(lambda c: ["browser", "--surface", require(c.browser_surface_id, "browser surface"), "snapshot", "--compact"]), expect_codes=any_code, covered_command="browser"),
        CliCase("browser-eval", ctx_argv(lambda c: ["browser", "--surface", require(c.browser_surface_id, "browser surface"), "eval", "document.title"]), expect_codes=any_code, covered_command="browser"),
        CliCase("browser-wait", ctx_argv(lambda c: ["browser", "--surface", require(c.browser_surface_id, "browser surface"), "wait", "--selector", "body", "--timeout-ms", "1000"]), expect_codes=any_code, timeout=4, covered_command="browser"),
        CliCase("browser-click", ctx_argv(lambda c: ["browser", "--surface", require(c.browser_surface_id, "browser surface"), "click", "#b"]), expect_codes=any_code, covered_command="browser"),
        CliCase("browser-dblclick", ctx_argv(lambda c: ["browser", "--surface", require(c.browser_surface_id, "browser surface"), "dblclick", "#b"]), expect_codes=any_code, covered_command="browser"),
        CliCase("browser-hover", ctx_argv(lambda c: ["browser", "--surface", require(c.browser_surface_id, "browser surface"), "hover", "#b"]), expect_codes=any_code, covered_command="browser"),
        CliCase("browser-focus", ctx_argv(lambda c: ["browser", "--surface", require(c.browser_surface_id, "browser surface"), "focus", "#i"]), expect_codes=any_code, covered_command="browser"),
        CliCase("browser-fill", ctx_argv(lambda c: ["browser", "--surface", require(c.browser_surface_id, "browser surface"), "fill", "#i", "filled"]), expect_codes=any_code, covered_command="browser"),
        CliCase("browser-type", ctx_argv(lambda c: ["browser", "--surface", require(c.browser_surface_id, "browser surface"), "type", "#i", "x"]), expect_codes=any_code, covered_command="browser"),
        CliCase("browser-press", ctx_argv(lambda c: ["browser", "--surface", require(c.browser_surface_id, "browser surface"), "press", "Enter"]), expect_codes=any_code, covered_command="browser"),
        CliCase("browser-select", ctx_argv(lambda c: ["browser", "--surface", require(c.browser_surface_id, "browser surface"), "select", "#s", "b"]), expect_codes=any_code, covered_command="browser"),
        CliCase("browser-scroll", ctx_argv(lambda c: ["browser", "--surface", require(c.browser_surface_id, "browser surface"), "scroll", "--dy", "20"]), expect_codes=any_code, covered_command="browser"),
        CliCase("browser-screenshot", ctx_argv(lambda c: ["browser", "--surface", require(c.browser_surface_id, "browser surface"), "screenshot", "--out", str(c.screenshot_path)]), expect_codes=any_code, timeout=20, covered_command="browser"),
        CliCase("browser-get-title", ctx_argv(lambda c: ["browser", "--surface", require(c.browser_surface_id, "browser surface"), "get", "title"]), expect_codes=any_code, covered_command="browser"),
        CliCase("browser-get-text", ctx_argv(lambda c: ["browser", "--surface", require(c.browser_surface_id, "browser surface"), "get", "text", "body"]), expect_codes=any_code, covered_command="browser"),
        CliCase("browser-is-visible", ctx_argv(lambda c: ["browser", "--surface", require(c.browser_surface_id, "browser surface"), "is", "visible", "body"]), expect_codes=any_code, covered_command="browser"),
        CliCase("browser-find-text", ctx_argv(lambda c: ["browser", "--surface", require(c.browser_surface_id, "browser surface"), "find", "text", "stress"]), expect_codes=any_code, covered_command="browser"),
        CliCase("browser-frame-main", ctx_argv(lambda c: ["browser", "--surface", require(c.browser_surface_id, "browser surface"), "frame", "main"]), expect_codes=any_code, covered_command="browser"),
        CliCase("browser-dialog-dismiss", ctx_argv(lambda c: ["browser", "--surface", require(c.browser_surface_id, "browser surface"), "dialog", "dismiss"]), expect_codes=any_code, covered_command="browser"),
        CliCase("browser-download-wait-timeout", ctx_argv(lambda c: ["browser", "--surface", require(c.browser_surface_id, "browser surface"), "download", "wait", "--timeout-ms", "1"]), expect_codes=any_code, timeout=4, covered_command="browser"),
        CliCase("browser-profiles-list", argv("browser", "profiles", "list"), expect_codes=any_code, covered_command="browser"),
        CliCase("browser-cookies-get", ctx_argv(lambda c: ["browser", "--surface", require(c.browser_surface_id, "browser surface"), "cookies", "get"]), expect_codes=any_code, covered_command="browser"),
        CliCase("browser-storage-get", ctx_argv(lambda c: ["browser", "--surface", require(c.browser_surface_id, "browser surface"), "storage", "local", "get"]), expect_codes=any_code, covered_command="browser"),
        CliCase("browser-tab-list", ctx_argv(lambda c: ["browser", "--surface", require(c.browser_surface_id, "browser surface"), "tab", "list"]), expect_codes=any_code, covered_command="browser"),
        CliCase("browser-console-list", ctx_argv(lambda c: ["browser", "--surface", require(c.browser_surface_id, "browser surface"), "console", "list"]), expect_codes=any_code, covered_command="browser"),
        CliCase("browser-errors-list", ctx_argv(lambda c: ["browser", "--surface", require(c.browser_surface_id, "browser surface"), "errors", "list"]), expect_codes=any_code, covered_command="browser"),
        CliCase("browser-highlight", ctx_argv(lambda c: ["browser", "--surface", require(c.browser_surface_id, "browser surface"), "highlight", "body"]), expect_codes=any_code, covered_command="browser"),
        CliCase("browser-state-save", ctx_argv(lambda c: ["browser", "--surface", require(c.browser_surface_id, "browser surface"), "state", "save", str(c.state_path)]), expect_codes=any_code, covered_command="browser"),
        CliCase("browser-addscript", ctx_argv(lambda c: ["browser", "--surface", require(c.browser_surface_id, "browser surface"), "addscript", "window.__cmuxStress=1"]), expect_codes=any_code, covered_command="browser"),
        CliCase("browser-addstyle", ctx_argv(lambda c: ["browser", "--surface", require(c.browser_surface_id, "browser surface"), "addstyle", "body{outline:1px solid transparent}"]), expect_codes=any_code, covered_command="browser"),
        CliCase("browser-viewport", ctx_argv(lambda c: ["browser", "--surface", require(c.browser_surface_id, "browser surface"), "viewport", "800", "600"]), expect_codes=any_code, covered_command="browser"),
        CliCase("browser-geo", ctx_argv(lambda c: ["browser", "--surface", require(c.browser_surface_id, "browser surface"), "geo", "37.7749", "-122.4194"]), expect_codes=any_code, covered_command="browser"),
        CliCase("browser-offline", ctx_argv(lambda c: ["browser", "--surface", require(c.browser_surface_id, "browser surface"), "offline", "false"]), expect_codes=any_code, covered_command="browser"),
        CliCase("browser-trace-start", ctx_argv(lambda c: ["browser", "--surface", require(c.browser_surface_id, "browser surface"), "trace", "start", str(c.trace_path)]), expect_codes=any_code, covered_command="browser"),
        CliCase("browser-trace-stop", ctx_argv(lambda c: ["browser", "--surface", require(c.browser_surface_id, "browser surface"), "trace", "stop", str(c.trace_path)]), expect_codes=any_code, covered_command="browser"),
        CliCase("browser-network-requests", ctx_argv(lambda c: ["browser", "--surface", require(c.browser_surface_id, "browser surface"), "network", "requests"]), expect_codes=any_code, covered_command="browser"),
        CliCase("browser-screencast-start", ctx_argv(lambda c: ["browser", "--surface", require(c.browser_surface_id, "browser surface"), "screencast", "start"]), expect_codes=any_code, covered_command="browser"),
        CliCase("browser-screencast-stop", ctx_argv(lambda c: ["browser", "--surface", require(c.browser_surface_id, "browser surface"), "screencast", "stop"]), expect_codes=any_code, covered_command="browser"),
        CliCase("browser-input-keyboard", ctx_argv(lambda c: ["browser", "--surface", require(c.browser_surface_id, "browser surface"), "input", "keyboard", "Enter"]), expect_codes=any_code, covered_command="browser"),
    ]


def build_socket_cases(ctx: StressContext, capabilities: set[str]) -> list[SocketCase]:
    def p_workspace(c: StressContext) -> dict[str, Any]:
        return {"workspace_id": require(c.workspace_id, "workspace")}

    def p_surface(c: StressContext) -> dict[str, Any]:
        c.ensure_core_surfaces()
        return {"workspace_id": require(c.workspace_id, "workspace"), "surface_id": require(c.surface_id, "surface")}

    def p_pane(c: StressContext) -> dict[str, Any]:
        c.ensure_core_surfaces()
        return {"workspace_id": require(c.workspace_id, "workspace"), "pane_id": require(c.pane_id, "pane")}

    cases = [
        SocketCase("system.ping", "system.ping", lambda c: {}),
        SocketCase("system.capabilities", "system.capabilities", lambda c: {}),
        SocketCase("system.identify", "system.identify", lambda c: {}),
        SocketCase("system.tree", "system.tree", lambda c: {"all": True}),
        SocketCase("system.top", "system.top", lambda c: {"all": True}, timeout=20),
        SocketCase("auth.login", "auth.login", lambda c: {}),
        SocketCase("auth.status", "auth.status", lambda c: {}, expect_ok=None),
        SocketCase("vm.list", "vm.list", lambda c: {}, expect_ok=None, timeout=20),
        SocketCase("window.list", "window.list", lambda c: {}),
        SocketCase("window.current", "window.current", lambda c: {}, expect_ok=None),
        SocketCase("window.focus", "window.focus", lambda c: {"window_id": c.current_window_id()}, expect_ok=None),
        SocketCase("window.create", "window.create", lambda c: {}, expect_ok=None, layout_mutation=True),
        SocketCase("window.close", "window.close", lambda c: {"window_id": c.create_window_for_case("close")}, expect_ok=None, layout_mutation=True),
        SocketCase("workspace.list", "workspace.list", lambda c: {}),
        SocketCase("workspace.create", "workspace.create", lambda c: {"title": f"stress-create-{uuid.uuid4().hex[:8]}", "cwd": str(pathlib.Path.cwd()), "focus": False}, layout_mutation=True),
        SocketCase("workspace.select", "workspace.select", p_workspace, expect_ok=None),
        SocketCase("workspace.current", "workspace.current", lambda c: {}),
        SocketCase("workspace.close", "workspace.close", lambda c: {"workspace_id": c.create_workspace_for_case("close")}, expect_ok=None, layout_mutation=True),
        SocketCase("workspace.move_to_window", "workspace.move_to_window", lambda c: {"workspace_id": c.create_workspace_for_case("move"), "window_id": c.create_window_for_case("move"), "focus": False}, expect_ok=None, layout_mutation=True),
        SocketCase("workspace.rename", "workspace.rename", lambda c: {"workspace_id": require(c.workspace_id, "workspace"), "title": f"stress-{c.run_id}"}),
        SocketCase("workspace.reorder", "workspace.reorder", lambda c: {"workspace_id": require(c.workspace_id, "workspace"), "index": 0}, expect_ok=None),
        SocketCase("workspace.prompt_submit", "workspace.prompt_submit", p_workspace, expect_ok=None),
        SocketCase("workspace.action.pin", "workspace.action", lambda c: {"workspace_id": require(c.workspace_id, "workspace"), "action": "pin"}, expect_ok=None),
        SocketCase("workspace.action.unpin", "workspace.action", lambda c: {"workspace_id": require(c.workspace_id, "workspace"), "action": "unpin"}, expect_ok=None),
        SocketCase("workspace.next", "workspace.next", lambda c: {}, expect_ok=None),
        SocketCase("workspace.previous", "workspace.previous", lambda c: {}, expect_ok=None),
        SocketCase("workspace.last", "workspace.last", lambda c: {}, expect_ok=None),
        SocketCase("workspace.equalize_splits", "workspace.equalize_splits", p_workspace, expect_ok=None),
        SocketCase("feed.jump", "feed.jump", lambda c: {"workstream_id": f"stress-{c.run_id}"}, expect_ok=None),
        SocketCase("feed.list", "feed.list", lambda c: {"pending_only": False}, expect_ok=None),
        SocketCase("surface.list", "surface.list", p_workspace),
        SocketCase("surface.current", "surface.current", p_workspace, expect_ok=None),
        SocketCase("surface.health", "surface.health", p_workspace),
        SocketCase("surface.focus", "surface.focus", p_surface, expect_ok=None),
        SocketCase("surface.send_text", "surface.send_text", lambda c: {**p_surface(c), "text": "printf socket-stress\\r"}),
        SocketCase("surface.send_key", "surface.send_key", lambda c: {**p_surface(c), "key": "enter"}),
        SocketCase("surface.report_tty", "surface.report_tty", lambda c: {**p_surface(c), "tty_name": f"stress-{c.run_id}"}),
        SocketCase("surface.report_shell_state", "surface.report_shell_state", lambda c: {**p_surface(c), "state": "running"}),
        SocketCase("surface.ports_kick", "surface.ports_kick", p_surface, expect_ok=None),
        SocketCase("surface.read_text", "surface.read_text", lambda c: {**p_surface(c), "lines": 5, "scrollback": True}, expect_ok=None),
        SocketCase("surface.clear_history", "surface.clear_history", p_surface, expect_ok=None),
        SocketCase("surface.trigger_flash", "surface.trigger_flash", p_surface, expect_ok=None),
        SocketCase("surface.create", "surface.create", lambda c: {"workspace_id": require(c.workspace_id, "workspace"), "type": "terminal", "focus": False}, layout_mutation=True),
        SocketCase("surface.close", "surface.close", lambda c: {"workspace_id": require(c.workspace_id, "workspace"), "surface_id": c.create_surface_for_case("close")}, expect_ok=None, layout_mutation=True),
        SocketCase("surface.split", "surface.split", lambda c: {**p_surface(c), "direction": "right", "focus": False}, expect_ok=None, layout_mutation=True),
        SocketCase("surface.reorder", "surface.reorder", lambda c: {**p_surface(c), "index": 0, "focus": False}, expect_ok=None),
        SocketCase("surface.move", "surface.move", lambda c: {**p_surface(c), "workspace_id": require(c.workspace_id, "workspace"), "focus": False}, expect_ok=None),
        SocketCase("surface.action.rename", "surface.action", lambda c: {**p_surface(c), "action": "rename", "title": "stress surface"}, expect_ok=None),
        SocketCase("tab.action.rename", "tab.action", lambda c: {**p_surface(c), "action": "rename", "title": "stress tab"}, expect_ok=None),
        SocketCase("surface.drag_to_split", "surface.drag_to_split", lambda c: {**p_surface(c), "direction": "down", "focus": False}, expect_ok=None, layout_mutation=True),
        SocketCase("surface.split_off", "surface.split_off", lambda c: {**p_surface(c), "direction": "right", "focus": False}, expect_ok=None, layout_mutation=True),
        SocketCase("surface.refresh", "surface.refresh", p_surface, expect_ok=None),
        SocketCase("pane.list", "pane.list", p_workspace),
        SocketCase("pane.focus", "pane.focus", p_pane, expect_ok=None),
        SocketCase("pane.surfaces", "pane.surfaces", p_pane, expect_ok=None),
        SocketCase("pane.create", "pane.create", lambda c: {"workspace_id": require(c.workspace_id, "workspace"), "type": "terminal", "direction": "right", "focus": False}, expect_ok=None, layout_mutation=True),
        SocketCase("pane.resize", "pane.resize", lambda c: {**p_pane(c), "direction": "right", "amount": 1}, expect_ok=None),
        SocketCase("pane.swap", "pane.swap", lambda c: {"workspace_id": require(c.workspace_id, "workspace"), "pane_id": require(c.pane_id, "pane"), "target_pane_id": require(c.second_pane_id, "second pane"), "focus": False}, expect_ok=None, layout_mutation=True),
        SocketCase("pane.break", "pane.break", lambda c: {**p_surface(c), "focus": False}, expect_ok=None, layout_mutation=True),
        SocketCase("pane.join", "pane.join", lambda c: {"workspace_id": require(c.workspace_id, "workspace"), "surface_id": require(c.second_surface_id, "second surface"), "target_pane_id": require(c.pane_id, "pane"), "focus": False}, expect_ok=None, layout_mutation=True),
        SocketCase("pane.last", "pane.last", p_workspace, expect_ok=None),
        SocketCase("notification.create", "notification.create", lambda c: {"workspace_id": c.workspace_id, "surface_id": c.surface_id, "title": "stress", "body": "socket"}),
        SocketCase("notification.create_for_caller", "notification.create_for_caller", lambda c: {"title": "stress", "body": "caller", "preferred_workspace_id": c.workspace_id, "preferred_surface_id": c.surface_id}, expect_ok=None),
        SocketCase("notification.create_for_surface", "notification.create_for_surface", lambda c: {"workspace_id": c.workspace_id, "surface_id": c.surface_id, "title": "stress", "body": "surface"}, expect_ok=None),
        SocketCase("notification.create_for_target", "notification.create_for_target", lambda c: {"workspace_id": c.workspace_id, "surface_id": c.surface_id, "title": "stress", "body": "target"}, expect_ok=None),
        SocketCase("notification.list", "notification.list", lambda c: {}),
        SocketCase("notification.clear", "notification.clear", lambda c: {}, expect_ok=None),
        SocketCase("notification.dismiss", "notification.dismiss", lambda c: {"all_read": True}, expect_ok=None),
        SocketCase("notification.mark_read", "notification.mark_read", lambda c: {"all": True}, expect_ok=None),
        SocketCase("notification.open", "notification.open", lambda c: {"id": c.create_notification_for_case("open")}, expect_ok=None),
        SocketCase("notification.jump_to_unread", "notification.jump_to_unread", lambda c: {}, expect_ok=None),
        SocketCase("app.focus_override.set", "app.focus_override.set", lambda c: {"state": "clear"}, expect_ok=None),
        SocketCase("app.simulate_active", "app.simulate_active", lambda c: {}),
        SocketCase("debug.terminals", "debug.terminals", lambda c: {}),
        SocketCase("markdown.open", "markdown.open", lambda c: {"path": str(c.markdown_path), "workspace_id": c.workspace_id, "focus": False}, expect_ok=None, layout_mutation=True),
        SocketCase("file.open", "file.open", lambda c: {"paths": [str(c.text_path)], "workspace_id": c.workspace_id, "focus": False}, expect_ok=None, layout_mutation=True),
    ]

    if ctx.browser_surface_id:
        cases.extend(browser_socket_cases())

    covered = {case.method for case in cases}
    for method in sorted(capabilities - covered):
        if method in SKIPPED_SOCKET_METHODS or method.startswith("debug."):
            cases.append(SocketCase(f"skip:{method}", method, lambda _c: {}, skip_reason=SKIPPED_SOCKET_METHODS.get(method, "debug-only method not required for public API stress")))
    return cases


def browser_socket_cases() -> list[SocketCase]:
    def p_surface(c: StressContext) -> dict[str, Any]:
        c.ensure_core_surfaces()
        return {"workspace_id": require(c.workspace_id, "workspace"), "surface_id": require(c.surface_id, "surface")}

    def p_browser(c: StressContext) -> dict[str, Any]:
        c.ensure_core_surfaces()
        return {"surface_id": require(c.browser_surface_id, "browser surface")}

    return [
        SocketCase("browser.open_split", "browser.open_split", lambda c: {**p_surface(c), "url": c.browser_url, "focus": False}, expect_ok=None, layout_mutation=True),
        SocketCase("browser.navigate", "browser.navigate", lambda c: {**p_browser(c), "url": c.browser_url}),
        SocketCase("browser.back", "browser.back", p_browser, expect_ok=None),
        SocketCase("browser.forward", "browser.forward", p_browser, expect_ok=None),
        SocketCase("browser.reload", "browser.reload", p_browser, expect_ok=None),
        SocketCase("browser.url.get", "browser.url.get", p_browser, expect_ok=None),
        SocketCase("browser.focus_webview", "browser.focus_webview", p_browser, expect_ok=None),
        SocketCase("browser.is_webview_focused", "browser.is_webview_focused", p_browser, expect_ok=None),
        SocketCase("browser.snapshot", "browser.snapshot", lambda c: {**p_browser(c), "compact": True}, expect_ok=None),
        SocketCase("browser.eval", "browser.eval", lambda c: {**p_browser(c), "script": "document.title"}, expect_ok=None),
        SocketCase("browser.wait", "browser.wait", lambda c: {**p_browser(c), "selector": "body", "timeout_ms": 1000}, expect_ok=None, timeout=4),
        SocketCase("browser.click", "browser.click", lambda c: {**p_browser(c), "selector": "#b"}, expect_ok=None),
        SocketCase("browser.dblclick", "browser.dblclick", lambda c: {**p_browser(c), "selector": "#b"}, expect_ok=None),
        SocketCase("browser.hover", "browser.hover", lambda c: {**p_browser(c), "selector": "#b"}, expect_ok=None),
        SocketCase("browser.focus", "browser.focus", lambda c: {**p_browser(c), "selector": "#i"}, expect_ok=None),
        SocketCase("browser.type", "browser.type", lambda c: {**p_browser(c), "selector": "#i", "text": "x"}, expect_ok=None),
        SocketCase("browser.fill", "browser.fill", lambda c: {**p_browser(c), "selector": "#i", "text": "filled"}, expect_ok=None),
        SocketCase("browser.press", "browser.press", lambda c: {**p_browser(c), "key": "Enter"}, expect_ok=None),
        SocketCase("browser.keydown", "browser.keydown", lambda c: {**p_browser(c), "key": "Shift"}, expect_ok=None),
        SocketCase("browser.keyup", "browser.keyup", lambda c: {**p_browser(c), "key": "Shift"}, expect_ok=None),
        SocketCase("browser.check", "browser.check", lambda c: {**p_browser(c), "selector": "#i"}, expect_ok=None),
        SocketCase("browser.uncheck", "browser.uncheck", lambda c: {**p_browser(c), "selector": "#i"}, expect_ok=None),
        SocketCase("browser.select", "browser.select", lambda c: {**p_browser(c), "selector": "#s", "value": "b"}, expect_ok=None),
        SocketCase("browser.scroll", "browser.scroll", lambda c: {**p_browser(c), "dy": 20}, expect_ok=None),
        SocketCase("browser.scroll_into_view", "browser.scroll_into_view", lambda c: {**p_browser(c), "selector": "body"}, expect_ok=None),
        SocketCase("browser.screenshot", "browser.screenshot", p_browser, expect_ok=None, timeout=20),
        SocketCase("browser.get.text", "browser.get.text", lambda c: {**p_browser(c), "selector": "body"}, expect_ok=None),
        SocketCase("browser.get.html", "browser.get.html", lambda c: {**p_browser(c), "selector": "body"}, expect_ok=None),
        SocketCase("browser.get.value", "browser.get.value", lambda c: {**p_browser(c), "selector": "#i"}, expect_ok=None),
        SocketCase("browser.get.attr", "browser.get.attr", lambda c: {**p_browser(c), "selector": "#i", "attr": "id"}, expect_ok=None),
        SocketCase("browser.get.title", "browser.get.title", p_browser, expect_ok=None),
        SocketCase("browser.get.count", "browser.get.count", lambda c: {**p_browser(c), "selector": "body"}, expect_ok=None),
        SocketCase("browser.get.box", "browser.get.box", lambda c: {**p_browser(c), "selector": "body"}, expect_ok=None),
        SocketCase("browser.get.styles", "browser.get.styles", lambda c: {**p_browser(c), "selector": "body", "property": "display"}, expect_ok=None),
        SocketCase("browser.is.visible", "browser.is.visible", lambda c: {**p_browser(c), "selector": "body"}, expect_ok=None),
        SocketCase("browser.is.enabled", "browser.is.enabled", lambda c: {**p_browser(c), "selector": "#i"}, expect_ok=None),
        SocketCase("browser.is.checked", "browser.is.checked", lambda c: {**p_browser(c), "selector": "#i"}, expect_ok=None),
        SocketCase("browser.find.role", "browser.find.role", lambda c: {**p_browser(c), "role": "button"}, expect_ok=None),
        SocketCase("browser.find.text", "browser.find.text", lambda c: {**p_browser(c), "text": "stress"}, expect_ok=None),
        SocketCase("browser.find.label", "browser.find.label", lambda c: {**p_browser(c), "text": "missing"}, expect_ok=None),
        SocketCase("browser.find.placeholder", "browser.find.placeholder", lambda c: {**p_browser(c), "text": "missing"}, expect_ok=None),
        SocketCase("browser.find.alt", "browser.find.alt", lambda c: {**p_browser(c), "text": "missing"}, expect_ok=None),
        SocketCase("browser.find.title", "browser.find.title", lambda c: {**p_browser(c), "text": "cmux stress"}, expect_ok=None),
        SocketCase("browser.find.testid", "browser.find.testid", lambda c: {**p_browser(c), "text": "missing"}, expect_ok=None),
        SocketCase("browser.find.first", "browser.find.first", lambda c: {**p_browser(c), "selector": "body"}, expect_ok=None),
        SocketCase("browser.find.last", "browser.find.last", lambda c: {**p_browser(c), "selector": "body"}, expect_ok=None),
        SocketCase("browser.find.nth", "browser.find.nth", lambda c: {**p_browser(c), "selector": "body", "index": 0}, expect_ok=None),
        SocketCase("browser.frame.main", "browser.frame.main", p_browser, expect_ok=None),
        SocketCase("browser.frame.select", "browser.frame.select", lambda c: {**p_browser(c), "selector": "body"}, expect_ok=None),
        SocketCase("browser.dialog.accept", "browser.dialog.accept", p_browser, expect_ok=None),
        SocketCase("browser.dialog.dismiss", "browser.dialog.dismiss", p_browser, expect_ok=None),
        SocketCase("browser.download.wait", "browser.download.wait", lambda c: {**p_browser(c), "timeout_ms": 1}, expect_ok=None, timeout=4),
        SocketCase("browser.cookies.get", "browser.cookies.get", p_browser, expect_ok=None),
        SocketCase("browser.cookies.set", "browser.cookies.set", lambda c: {**p_browser(c), "name": "stress", "value": "1", "url": "https://example.com"}, expect_ok=None),
        SocketCase("browser.cookies.clear", "browser.cookies.clear", lambda c: {**p_browser(c), "name": "stress", "url": "https://example.com"}, expect_ok=None),
        SocketCase("browser.storage.get", "browser.storage.get", lambda c: {**p_browser(c), "type": "local"}, expect_ok=None),
        SocketCase("browser.storage.set", "browser.storage.set", lambda c: {**p_browser(c), "type": "local", "key": "stress", "value": "1"}, expect_ok=None),
        SocketCase("browser.storage.clear", "browser.storage.clear", lambda c: {**p_browser(c), "type": "local"}, expect_ok=None),
        SocketCase("browser.tab.new", "browser.tab.new", lambda c: {**p_browser(c), "url": c.browser_url}, expect_ok=None, layout_mutation=True),
        SocketCase("browser.tab.list", "browser.tab.list", p_browser, expect_ok=None),
        SocketCase("browser.tab.switch", "browser.tab.switch", lambda c: {**p_browser(c), "index": 0}, expect_ok=None),
        SocketCase("browser.tab.close", "browser.tab.close", lambda c: {**p_browser(c), "index": 99}, expect_ok=None),
        SocketCase("browser.console.list", "browser.console.list", p_browser, expect_ok=None),
        SocketCase("browser.console.clear", "browser.console.clear", p_browser, expect_ok=None),
        SocketCase("browser.errors.list", "browser.errors.list", p_browser, expect_ok=None),
        SocketCase("browser.highlight", "browser.highlight", lambda c: {**p_browser(c), "selector": "body"}, expect_ok=None),
        SocketCase("browser.state.save", "browser.state.save", lambda c: {**p_browser(c), "path": str(c.state_path)}, expect_ok=None),
        SocketCase("browser.state.load", "browser.state.load", lambda c: {**p_browser(c), "path": str(c.state_path)}, expect_ok=None),
        SocketCase("browser.addinitscript", "browser.addinitscript", lambda c: {**p_browser(c), "script": "window.__stressInit=1"}, expect_ok=None),
        SocketCase("browser.addscript", "browser.addscript", lambda c: {**p_browser(c), "script": "window.__stressScript=1"}, expect_ok=None),
        SocketCase("browser.addstyle", "browser.addstyle", lambda c: {**p_browser(c), "css": "body{outline:0}"}, expect_ok=None),
        SocketCase("browser.viewport.set", "browser.viewport.set", lambda c: {**p_browser(c), "width": 800, "height": 600}, expect_ok=None),
        SocketCase("browser.geolocation.set", "browser.geolocation.set", lambda c: {**p_browser(c), "latitude": 37.7749, "longitude": -122.4194}, expect_ok=None),
        SocketCase("browser.offline.set", "browser.offline.set", lambda c: {**p_browser(c), "enabled": False}, expect_ok=None),
        SocketCase("browser.trace.start", "browser.trace.start", lambda c: {**p_browser(c), "path": str(c.trace_path)}, expect_ok=None),
        SocketCase("browser.trace.stop", "browser.trace.stop", lambda c: {**p_browser(c), "path": str(c.trace_path)}, expect_ok=None),
        SocketCase("browser.network.route", "browser.network.route", lambda c: {**p_browser(c), "url": "**/*", "abort": False}, expect_ok=None),
        SocketCase("browser.network.unroute", "browser.network.unroute", lambda c: {**p_browser(c), "url": "**/*"}, expect_ok=None),
        SocketCase("browser.network.requests", "browser.network.requests", p_browser, expect_ok=None),
        SocketCase("browser.screencast.start", "browser.screencast.start", p_browser, expect_ok=None),
        SocketCase("browser.screencast.stop", "browser.screencast.stop", p_browser, expect_ok=None),
        SocketCase("browser.input_mouse", "browser.input_mouse", lambda c: {**p_browser(c), "args": ["move", "1", "1"]}, expect_ok=None),
        SocketCase("browser.input_keyboard", "browser.input_keyboard", lambda c: {**p_browser(c), "args": ["press", "Enter"]}, expect_ok=None),
        SocketCase("browser.input_touch", "browser.input_touch", lambda c: {**p_browser(c), "args": ["tap", "1", "1"]}, expect_ok=None),
        SocketCase("browser.profiles.list", "browser.profiles.list", lambda c: {}, expect_ok=None),
    ]


class StressRunner:
    def __init__(self, ctx: StressContext, args: argparse.Namespace) -> None:
        self.ctx = ctx
        self.args = args
        self.artifacts_dir = ctx.artifacts_dir
        self.results_path = self.artifacts_dir / "results.jsonl"
        self.summary_path = self.artifacts_dir / "summary.json"
        self.stop_event = threading.Event()
        self.failures: list[CaseResult] = []
        self.counts = {"cli": 0, "socket": 0, "burst": 0, "skip": 0}
        self.cli_cases: list[CliCase] = []
        self.socket_cases: list[SocketCase] = []
        self.capabilities: set[str] = set()

    def prepare(self) -> None:
        self.ctx.setup()
        capabilities_payload = self.ctx.socket_result("system.capabilities", timeout=max(self.ctx.timeout, 20))
        methods = capabilities_payload.get("methods", [])
        self.capabilities = {method for method in methods if isinstance(method, str)}
        self.cli_cases = build_cli_cases(self.ctx)
        self.socket_cases = build_socket_cases(self.ctx, self.capabilities)
        self.write_plan()

    def write_plan(self) -> None:
        covered_cli = {case.covered_command or first_command(case, self.ctx) for case in self.cli_cases if not case.skip_reason}
        missing_cli = sorted(TOP_LEVEL_COMMANDS - covered_cli)
        covered_socket = {case.method for case in self.socket_cases if not case.skip_reason}
        skipped_socket = {case.method for case in self.socket_cases if case.skip_reason}
        missing_socket = sorted(self.capabilities - covered_socket - skipped_socket)
        plan = {
            "cli_cases": [case.name for case in self.cli_cases],
            "socket_cases": [case.name for case in self.socket_cases],
            "covered_cli_commands": sorted(covered_cli),
            "missing_cli_commands": missing_cli,
            "skipped_cli_commands": SKIPPED_CLI_COMMANDS,
            "covered_socket_methods": sorted(covered_socket),
            "missing_socket_methods": missing_socket,
            "skipped_socket_methods": {
                case.method: case.skip_reason
                for case in self.socket_cases
                if case.skip_reason
            },
            "capability_count": len(self.capabilities),
            "workspace_id": self.ctx.workspace_id,
            "surface_id": self.ctx.surface_id,
            "browser_surface_id": self.ctx.browser_surface_id,
        }
        safe_write_text(self.artifacts_dir / "plan.json", json.dumps(plan, indent=2, sort_keys=True))
        if missing_cli or missing_socket:
            print(f"WARN: coverage gaps written to {self.artifacts_dir / 'plan.json'}")

    def run(self) -> int:
        duration = parse_duration(self.args.duration)
        end_at = time.monotonic() + duration
        iteration_limit = self.args.iterations
        heartbeat = threading.Thread(target=self.heartbeat_loop, name="cmux-stress-heartbeat", daemon=True)
        heartbeat.start()
        started_at = time.time()
        cycle = 0

        with self.results_path.open("a", encoding="utf-8") as result_log:
            while time.monotonic() < end_at and (iteration_limit is None or cycle < iteration_limit):
                cycle += 1
                random.shuffle(self.cli_cases)
                random.shuffle(self.socket_cases)
                for case in self.cli_cases:
                    if self._deadline_reached(end_at, cycle, iteration_limit):
                        break
                    result = self.run_cli_case(case)
                    json_dump_line(result_log, dataclasses.asdict(result))
                    self.record_result(result)
                    if case.layout_mutation:
                        self.ctx.repair_state()
                for case in self.socket_cases:
                    if self._deadline_reached(end_at, cycle, iteration_limit):
                        break
                    result = self.run_socket_case(case)
                    json_dump_line(result_log, dataclasses.asdict(result))
                    self.record_result(result)
                    if case.layout_mutation:
                        self.ctx.repair_state()
                if self._deadline_reached(end_at, cycle, iteration_limit):
                    break
                burst_result = self.run_parallel_burst()
                json_dump_line(result_log, dataclasses.asdict(burst_result))
                self.record_result(burst_result)
                self.ctx.repair_state()
                print(
                    f"cycle={cycle} cli={self.counts['cli']} socket={self.counts['socket']} burst={self.counts['burst']} failures={len(self.failures)}",
                    flush=True,
                )

        self.stop_event.set()
        heartbeat.join(timeout=2)
        elapsed = time.time() - started_at
        summary = {
            "ok": not self.failures,
            "elapsed_seconds": elapsed,
            "cycles": cycle,
            "counts": self.counts,
            "failures": [dataclasses.asdict(item) for item in self.failures[:50]],
            "artifact_dir": str(self.artifacts_dir),
            "socket_path": self.ctx.socket_path,
            "cli_path": self.ctx.cli_path,
        }
        safe_write_text(self.summary_path, json.dumps(summary, indent=2, sort_keys=True))
        print(json.dumps(summary, indent=2, sort_keys=True))
        return 0 if not self.failures else 1

    def _deadline_reached(self, end_at: float, cycle: int, iteration_limit: int | None) -> bool:
        _ = cycle
        _ = iteration_limit
        return time.monotonic() >= end_at and not self.args.finish_cycle

    def record_result(self, result: CaseResult) -> None:
        if result.kind in self.counts:
            self.counts[result.kind] += 1
        if not result.ok:
            self.failures.append(result)

    def run_cli_case(self, case: CliCase) -> CaseResult:
        started = time.monotonic()
        if case.skip_reason:
            self.counts["skip"] += 1
            return CaseResult("cli", case.name, True, 0, {"skipped": case.skip_reason})
        try:
            case_argv = case.argv_factory(self.ctx)
            full_argv = [self.ctx.cli_path]
            if not case.no_socket:
                full_argv.extend(["--socket", self.ctx.socket_path])
            full_argv.extend(case_argv)
            env = case.env_factory(self.ctx) if case.env_factory else (self.ctx.no_socket_env() if case.no_socket else self.ctx.base_env())
            stdin = case.stdin_factory(self.ctx) if case.stdin_factory else None
            proc = run_capture(full_argv, timeout=case.timeout or self.ctx.timeout, env=env, stdin=stdin)
            elapsed_ms = (time.monotonic() - started) * 1000
            ok = proc.returncode in case.expect_codes
            details = {
                "argv": full_argv,
                "returncode": proc.returncode,
                "stdout": truncate(proc.stdout),
                "stderr": truncate(proc.stderr),
            }
            if proc.returncode < 0:
                details["signal"] = -proc.returncode
                ok = False
            if not ok:
                self.ctx.diagnostics.capture(f"cli-{case.name}", details)
            return CaseResult("cli", case.name, ok, elapsed_ms, details)
        except subprocess.TimeoutExpired as exc:
            elapsed_ms = (time.monotonic() - started) * 1000
            details = {"timeout": case.timeout or self.ctx.timeout, "argv": exc.cmd}
            diag = self.ctx.diagnostics.capture(f"cli-timeout-{case.name}", details)
            details["diagnostics"] = str(diag)
            return CaseResult("cli", case.name, False, elapsed_ms, details)
        except Exception as exc:
            elapsed_ms = (time.monotonic() - started) * 1000
            details = {"exception": repr(exc)}
            diag = self.ctx.diagnostics.capture(f"cli-exception-{case.name}", details)
            details["diagnostics"] = str(diag)
            return CaseResult("cli", case.name, False, elapsed_ms, details)

    def run_socket_case(self, case: SocketCase) -> CaseResult:
        started = time.monotonic()
        if case.skip_reason:
            self.counts["skip"] += 1
            return CaseResult("socket", case.name, True, 0, {"skipped": case.skip_reason, "method": case.method})
        try:
            params = case.params_factory(self.ctx)
            response = self.ctx.raw.call(case.method, params, timeout=case.timeout or self.ctx.timeout)
            elapsed_ms = (time.monotonic() - started) * 1000
            response_ok = response.get("ok") is True
            ok = case.expect_ok is None or response_ok == case.expect_ok
            details = {
                "method": case.method,
                "params": scrub_payload(params),
                "response": scrub_payload(response),
            }
            if not ok:
                self.ctx.diagnostics.capture(f"socket-{case.name}", details)
            self.ctx.cleanup_socket_side_effects(case.method, params, response)
            return CaseResult("socket", case.name, ok, elapsed_ms, details)
        except Exception as exc:
            elapsed_ms = (time.monotonic() - started) * 1000
            details = {"method": case.method, "exception": repr(exc)}
            diag = self.ctx.diagnostics.capture(f"socket-exception-{case.name}", details)
            details["diagnostics"] = str(diag)
            return CaseResult("socket", case.name, False, elapsed_ms, details)

    def run_parallel_burst(self) -> CaseResult:
        started = time.monotonic()
        methods = [
            ("system.ping", {}),
            ("system.identify", {}),
            ("workspace.list", {}),
            ("pane.list", {"workspace_id": self.ctx.workspace_id}),
            ("surface.list", {"workspace_id": self.ctx.workspace_id}),
            ("surface.health", {"workspace_id": self.ctx.workspace_id}),
            ("surface.read_text", {"workspace_id": self.ctx.workspace_id, "surface_id": self.ctx.surface_id, "lines": 2}),
        ]
        methods = [(method, {k: v for k, v in params.items() if v}) for method, params in methods]
        failures: list[str] = []

        def one(index: int) -> None:
            method, params = methods[index % len(methods)]
            response = self.ctx.raw.call(method, params, timeout=self.ctx.timeout)
            if response.get("ok") is not True and method in {"system.ping", "workspace.list", "surface.list"}:
                raise RuntimeError(f"{method} returned {response}")

        with concurrent.futures.ThreadPoolExecutor(max_workers=self.args.burst_workers) as executor:
            futures = [executor.submit(one, i) for i in range(self.args.burst_requests)]
            try:
                for future in concurrent.futures.as_completed(futures, timeout=max(self.ctx.timeout * 2, 30)):
                    try:
                        future.result()
                    except Exception as exc:
                        failures.append(repr(exc))
            except concurrent.futures.TimeoutError as exc:
                pending = sum(1 for future in futures if not future.done())
                failures.append(f"parallel burst timed out with {pending} pending requests: {exc!r}")
                for future in futures:
                    future.cancel()
        elapsed_ms = (time.monotonic() - started) * 1000
        ok = not failures
        details = {
            "workers": self.args.burst_workers,
            "requests": self.args.burst_requests,
            "failures": failures[:20],
        }
        if not ok:
            diag = self.ctx.diagnostics.capture("parallel-burst", details)
            details["diagnostics"] = str(diag)
        return CaseResult("burst", "parallel-burst", ok, elapsed_ms, details)

    def heartbeat_loop(self) -> None:
        while not self.stop_event.wait(self.args.heartbeat_interval):
            started = time.monotonic()
            try:
                response = self.ctx.raw.call("system.ping", timeout=min(self.ctx.timeout, 5))
                if response.get("ok") is not True:
                    self.ctx.diagnostics.capture("heartbeat-bad-response", {"response": response})
            except Exception as exc:
                self.ctx.diagnostics.capture("heartbeat-failed", {"exception": repr(exc)})
            elapsed = time.monotonic() - started
            if elapsed > max(5, self.ctx.timeout):
                self.ctx.diagnostics.capture("heartbeat-slow", {"elapsed_seconds": elapsed})


def first_command(case: CliCase, ctx: StressContext) -> str:
    try:
        argv_value = case.argv_factory(ctx)
    except Exception:
        return case.name
    if not argv_value:
        return case.name
    if argv_value[0].startswith("-") and len(argv_value) > 1:
        return argv_value[1]
    return argv_value[0]


def scrub_payload(value: Any, depth: int = 0) -> Any:
    if depth > 4:
        return "<truncated>"
    if isinstance(value, dict):
        return {str(k): scrub_payload(v, depth + 1) for k, v in list(value.items())[:80]}
    if isinstance(value, list):
        return [scrub_payload(v, depth + 1) for v in value[:80]]
    if isinstance(value, str):
        return truncate(value, 1000)
    return value


def resolve_cli_path(raw: str | None, tag: str | None) -> str:
    candidates: list[str] = []
    if raw:
        candidates.append(os.path.expanduser(raw))
    env_cli = os.environ.get("CMUXTERM_CLI") or os.environ.get("CMUX_BUNDLED_CLI_PATH")
    if env_cli:
        candidates.append(os.path.expanduser(env_cli))
    if tag:
        candidates.append(os.path.expanduser(f"~/Library/Developer/Xcode/DerivedData/cmux-{tag}/Build/Products/Debug/cmux DEV {tag}.app/Contents/Resources/bin/cmux"))
        candidates.append(os.path.expanduser(f"~/Library/Developer/Xcode/DerivedData/cmux-{tag}/Build/Products/Debug/cmux"))
    last_cli = pathlib.Path("/tmp/cmux-last-cli-path")
    if last_cli.exists():
        try:
            candidates.append(last_cli.read_text(encoding="utf-8").strip())
        except OSError:
            pass
    candidates.extend(glob.glob(os.path.expanduser("~/Library/Developer/Xcode/DerivedData/**/Build/Products/Debug/cmux"), recursive=True))
    for candidate in candidates:
        if candidate and os.path.isfile(candidate) and os.access(candidate, os.X_OK):
            return candidate
    raise SystemExit("error: could not find cmux CLI. Pass --cli or set CMUXTERM_CLI.")


def resolve_socket_path(raw: str | None, tag: str | None) -> str:
    if raw:
        return os.path.expanduser(raw)
    env_socket = os.environ.get("CMUX_SOCKET_PATH")
    if env_socket:
        return env_socket
    if tag:
        return f"/tmp/cmux-debug-{tag}.sock"
    last_socket = pathlib.Path("/tmp/cmux-last-socket-path")
    if last_socket.exists():
        try:
            value = last_socket.read_text(encoding="utf-8").strip()
            if value:
                return value
        except OSError:
            pass
    raise SystemExit("error: socket path required. Pass --socket or --tag, or set CMUX_SOCKET_PATH.")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--cli", help="Path to cmux CLI binary. Defaults to CMUXTERM_CLI, tagged DerivedData, then recent DerivedData.")
    parser.add_argument("--socket", help="Unix socket path. Defaults to CMUX_SOCKET_PATH or /tmp/cmux-debug-<tag>.sock.")
    parser.add_argument("--tag", help="Tagged dev app slug, for path defaults and diagnostics.")
    parser.add_argument("--duration", default=f"{DEFAULT_DURATION_SECONDS}s", help="Stress duration, e.g. 30s, 10m, 12h. Default: 12h.")
    parser.add_argument("--iterations", type=int, help="Stop after this many cycles. Useful for smoke runs.")
    parser.add_argument("--finish-cycle", action="store_true", help="Finish the current cycle when --duration expires.")
    parser.add_argument("--timeout", type=float, default=DEFAULT_TIMEOUT_SECONDS, help="Per-command timeout in seconds.")
    parser.add_argument("--artifacts", help="Artifact directory. Default: /tmp/cmux-cli-socket-stress-<timestamp>.")
    parser.add_argument("--app-pgrep", help="pgrep -f pattern used to locate the app process for diagnostics.")
    parser.add_argument("--heartbeat-interval", type=float, default=15.0, help="Socket heartbeat interval in seconds.")
    parser.add_argument("--burst-workers", type=int, default=DEFAULT_BURST_WORKERS, help="Parallel socket burst worker count.")
    parser.add_argument("--burst-requests", type=int, default=DEFAULT_BURST_REQUESTS, help="Parallel socket burst request count per cycle.")
    parser.add_argument("--list-plan", action="store_true", help="Prepare context, write plan.json, then exit.")
    args = parser.parse_args()

    tag = safe_name(args.tag) if args.tag else None
    artifacts_dir = pathlib.Path(args.artifacts or f"/tmp/cmux-cli-socket-stress-{now_slug()}").expanduser()
    artifacts_dir.mkdir(parents=True, exist_ok=True)
    cli_path = resolve_cli_path(args.cli, tag)
    socket_path = resolve_socket_path(args.socket, tag)
    diagnostics = Diagnostics(artifacts_dir, tag, socket_path, args.app_pgrep)
    ctx = StressContext(
        cli_path=cli_path,
        socket_path=socket_path,
        artifacts_dir=artifacts_dir,
        timeout=args.timeout,
        diagnostics=diagnostics,
        tag=tag,
    )
    runner = StressRunner(ctx, args)
    try:
        runner.prepare()
    except Exception as exc:
        diag = diagnostics.capture("prepare-failed", {"exception": repr(exc)})
        print(f"error: prepare failed: {exc}. diagnostics: {diag}", file=sys.stderr)
        return 2
    if args.list_plan:
        print(f"plan: {artifacts_dir / 'plan.json'}")
        return 0
    return runner.run()


if __name__ == "__main__":
    signal.signal(signal.SIGPIPE, signal.SIG_DFL)
    raise SystemExit(main())
