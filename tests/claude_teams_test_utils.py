#!/usr/bin/env python3

from __future__ import annotations

from collections.abc import Iterator
from contextlib import contextmanager
import json
import os
import shutil
import socketserver
import subprocess
import tempfile
import threading
import uuid
from pathlib import Path

FOCUSED_WORKSPACE_ID = "11111111-1111-4111-8111-111111111111"
FOCUSED_WINDOW_ID = "22222222-2222-4222-8222-222222222222"
FOCUSED_PANE_ID = "33333333-3333-4333-8333-333333333333"
FOCUSED_SURFACE_ID = "44444444-4444-4444-8444-444444444444"


def stable_tmux_numeric_id(raw: str) -> str:
    value = 14695981039346656037
    for byte in raw.encode("utf-8"):
        value ^= byte
        value = (value * 1099511628211) & 0xFFFFFFFFFFFFFFFF
    value &= 0x7FFFFFFFFFFFFFFF
    return str(value or 1)


def resolve_cmux_cli() -> str:
    explicit = os.environ.get("CMUX_CLI_BIN") or os.environ.get("CMUX_CLI")
    if explicit and os.path.exists(explicit) and os.access(explicit, os.X_OK):
        return explicit

    recorded_path = Path("/tmp/cmux-last-cli-path")
    if recorded_path.exists():
        candidate = recorded_path.read_text(encoding="utf-8").strip()
        if candidate and os.path.exists(candidate) and os.access(candidate, os.X_OK):
            return candidate

    raise RuntimeError(
        "Unable to find cmux CLI binary. Set CMUX_CLI_BIN or run ./scripts/reload.sh --tag <tag> first."
    )


class _FocusedCmuxHandler(socketserver.StreamRequestHandler):
    def handle(self) -> None:
        while line := self.rfile.readline():
            decoded_line = line.decode("utf-8").rstrip("\r\n")
            capability_prefix = "_cmux_capability_v1 "
            if decoded_line.startswith(capability_prefix):
                envelope_parts = decoded_line.split(" ", 2)
                if len(envelope_parts) != 3 or not envelope_parts[1] or not envelope_parts[2]:
                    self.wfile.write(b"ERROR: malformed capability envelope\n")
                    self.wfile.flush()
                    continue
                decoded_line = envelope_parts[2]

            if decoded_line.startswith("auth "):
                self.server.requests.append("auth")  # type: ignore[attr-defined]
                self.wfile.write(b"OK\n")
                self.wfile.flush()
                continue

            request = json.loads(decoded_line)
            method = str(request["method"])
            self.server.requests.append(method)  # type: ignore[attr-defined]
            workspace_id = self.server.workspace_id  # type: ignore[attr-defined]
            window_id = self.server.window_id  # type: ignore[attr-defined]
            pane_id = self.server.pane_id  # type: ignore[attr-defined]
            surface_id = self.server.surface_id  # type: ignore[attr-defined]
            if method == "system.identify":
                result = {
                    "focused": {
                        "workspace_id": self.server.identified_workspace_id,  # type: ignore[attr-defined]
                        "window_id": self.server.identified_window_id,  # type: ignore[attr-defined]
                        "pane_id": self.server.identified_pane_id,  # type: ignore[attr-defined]
                        "surface_id": self.server.identified_surface_id,  # type: ignore[attr-defined]
                    }
                }
            elif method == "surface.list":
                params = request.get("params") or {}
                stale_workspace_id = self.server.stale_workspace_id  # type: ignore[attr-defined]
                if stale_workspace_id and params.get("workspace_id") == stale_workspace_id:
                    result = {
                        "workspace_id": stale_workspace_id,
                        "surfaces": [],
                    }
                else:
                    result = {
                        "workspace_id": workspace_id,
                        "window_id": window_id,
                        "surfaces": [{"id": surface_id, "pane_id": pane_id}],
                    }
            else:
                result = {}
            response = {"ok": True, "result": result, "id": request.get("id")}
            self.wfile.write((json.dumps(response) + "\n").encode("utf-8"))
            self.wfile.flush()


class _FocusedCmuxServer(socketserver.ThreadingUnixStreamServer):
    allow_reuse_address = True

    def __init__(
        self,
        socket_path: str,
        workspace_id: str,
        window_id: str,
        pane_id: str,
        surface_id: str,
        identified_workspace_id: str,
        identified_window_id: str,
        identified_pane_id: str,
        identified_surface_id: str,
        stale_workspace_id: str | None,
    ) -> None:
        self.requests: list[str] = []
        self.workspace_id = workspace_id
        self.window_id = window_id
        self.pane_id = pane_id
        self.surface_id = surface_id
        self.identified_workspace_id = identified_workspace_id
        self.identified_window_id = identified_window_id
        self.identified_pane_id = identified_pane_id
        self.identified_surface_id = identified_surface_id
        self.stale_workspace_id = stale_workspace_id
        super().__init__(socket_path, _FocusedCmuxHandler)


@contextmanager
def focused_cmux_server(
    socket_path_hint: Path,
    *,
    workspace_id: str = FOCUSED_WORKSPACE_ID,
    window_id: str = FOCUSED_WINDOW_ID,
    pane_id: str = FOCUSED_PANE_ID,
    surface_id: str = FOCUSED_SURFACE_ID,
    identified_workspace_id: str | None = None,
    identified_window_id: str | None = None,
    identified_pane_id: str | None = None,
    identified_surface_id: str | None = None,
    stale_workspace_id: str | None = None,
) -> Iterator[tuple[str, list[str]]]:
    """Serve a focused surface from a short helper-owned AF_UNIX endpoint.

    Callers may supply paths beneath arbitrarily deep test roots as a naming
    hint, but must use the live path yielded here. Darwin limits AF_UNIX paths
    to roughly one hundred bytes, so the shared server boundary owns a short
    endpoint instead of making every caller reason about that platform limit.
    """
    del socket_path_hint
    with tempfile.TemporaryDirectory(
        prefix="cmux-focused-socket-", dir="/tmp"
    ) as socket_dir:
        socket_path = Path(socket_dir) / "cmux.sock"
        server = _FocusedCmuxServer(
            str(socket_path),
            workspace_id,
            window_id,
            pane_id,
            surface_id,
            identified_workspace_id or workspace_id,
            identified_window_id or window_id,
            identified_pane_id or pane_id,
            identified_surface_id or surface_id,
            stale_workspace_id,
        )
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            yield str(socket_path), server.requests
        finally:
            server.shutdown()
            server.server_close()
            thread.join(timeout=2)


@contextmanager
def canonical_managed_claude_shim_root() -> Iterator[tuple[str, Path]]:
    """Create an isolated per-surface shim at the app-owned temporary root."""
    surface_id = str(uuid.uuid4())
    parent = Path(tempfile.gettempdir()) / "cmux-cli-shims"
    root = parent / surface_id
    root.mkdir(parents=True)
    try:
        yield surface_id, root
    finally:
        shutil.rmtree(root, ignore_errors=True)
        try:
            parent.rmdir()
        except OSError:
            pass


def install_pi_extension(config_dir: Path, cli_path: str | None = None) -> Path:
    env = os.environ.copy()
    env["PI_CODING_AGENT_DIR"] = str(config_dir)
    install = subprocess.run(
        [cli_path or resolve_cmux_cli(), "hooks", "pi", "install", "--yes"],
        capture_output=True,
        text=True,
        check=False,
        env=env,
        timeout=20,
    )
    if install.returncode != 0:
        raise RuntimeError(
            f"exit={install.returncode} stdout={install.stdout!r} stderr={install.stderr!r}"
        )

    extension_path = config_dir / "extensions" / "cmux-session.ts"
    if not extension_path.exists():
        raise RuntimeError(f"expected extension at {extension_path}")
    override = os.environ.get("CMUX_TEST_PI_EXTENSION_OVERRIDE")
    if override:
        shutil.copyfile(override, extension_path)
    return extension_path
