#!/usr/bin/env python3

from __future__ import annotations

from collections.abc import Iterator
from contextlib import contextmanager
import json
import os
import shutil
import socketserver
import subprocess
import threading
from pathlib import Path

FOCUSED_WORKSPACE_ID = "11111111-1111-4111-8111-111111111111"
FOCUSED_WINDOW_ID = "22222222-2222-4222-8222-222222222222"
FOCUSED_PANE_ID = "33333333-3333-4333-8333-333333333333"
FOCUSED_SURFACE_ID = "44444444-4444-4444-8444-444444444444"


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
            if decoded_line.startswith("auth "):
                self.server.requests.append("auth")  # type: ignore[attr-defined]
                self.wfile.write(b"OK\n")
                self.wfile.flush()
                continue

            request = json.loads(decoded_line)
            method = str(request["method"])
            self.server.requests.append(method)  # type: ignore[attr-defined]
            workspace_id = FOCUSED_WORKSPACE_ID
            window_id = FOCUSED_WINDOW_ID
            pane_id = FOCUSED_PANE_ID
            surface_id = FOCUSED_SURFACE_ID
            if method == "system.identify":
                result = {
                    "focused": {
                        "workspace_id": workspace_id,
                        "window_id": window_id,
                        "pane_id": pane_id,
                        "surface_id": surface_id,
                    }
                }
            elif method == "surface.list":
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

    def __init__(self, socket_path: str) -> None:
        self.requests: list[str] = []
        super().__init__(socket_path, _FocusedCmuxHandler)


@contextmanager
def focused_cmux_server(socket_path: Path) -> Iterator[tuple[str, list[str]]]:
    """Serve a live focused surface to prove contextless launchers do not borrow it."""
    server = _FocusedCmuxServer(str(socket_path))
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        yield str(socket_path), server.requests
    finally:
        server.shutdown()
        server.server_close()
        thread.join(timeout=2)


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
