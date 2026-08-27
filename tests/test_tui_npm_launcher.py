"""Behavior tests for the dependency-free npm launcher."""

from __future__ import annotations

import base64
import gzip
import hashlib
import http.server
import io
import json
import os
import stat
import subprocess
import tarfile
import threading
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
LAUNCHER = ROOT / "cmux-tui/dist/npm/cmux/bin/cmux.js"


def make_tarball() -> bytes:
    payload = b"#!/bin/sh\nprintf '%s\\n' 'fake cmux-tui 1.2.3'\n"
    tar_buffer = io.BytesIO()
    with tarfile.open(fileobj=tar_buffer, mode="w") as archive:
        info = tarfile.TarInfo("package/bin/cmux-tui")
        info.mode = 0o755
        info.size = len(payload)
        archive.addfile(info, io.BytesIO(payload))
    return gzip.compress(tar_buffer.getvalue())


class RegistryHandler(http.server.BaseHTTPRequestHandler):
    tarball = make_tarball()
    metadata_requests = 0
    tarball_requests = 0
    status = 200

    def do_GET(self) -> None:  # noqa: N802, required by BaseHTTPRequestHandler
        if self.path.endswith((
            "/cmux-tui-darwin-arm64/1.2.3",
            "/cmux-tui-darwin-x64/1.2.3",
            "/cmux-tui-linux-arm64/1.2.3",
            "/cmux-tui-linux-x64/1.2.3",
        )):
            type(self).metadata_requests += 1
            body = json.dumps(
                {
                    "dist": {
                        "tarball": f"http://127.0.0.1:{self.server.server_port}/tarball.tgz",
                        "integrity": "sha512-"
                        + base64.b64encode(hashlib.sha512(self.tarball).digest()).decode(),
                    }
                }
            ).encode()
        elif self.path == "/tarball.tgz":
            type(self).tarball_requests += 1
            body = self.tarball
        else:
            self.send_error(404)
            return
        if self.status != 200:
            self.send_error(self.status)
            return
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *_args: object) -> None:
        return


def run_launcher(
    launcher: Path,
    cache: Path,
    registry: str,
    *args: str,
) -> subprocess.CompletedProcess[str]:
    env = os.environ.copy()
    env.update(
        {
            "CMUX_TUI_LAUNCHER_CACHE": str(cache),
            "CMUX_NPM_REGISTRY": registry,
            "NO_COLOR": "1",
        }
    )
    return subprocess.run(
        ["node", str(launcher), *args],
        check=False,
        capture_output=True,
        text=True,
        env=env,
    )


def write_launcher(tmp_path: Path) -> Path:
    package = tmp_path / "package"
    (package / "bin").mkdir(parents=True)
    (package / "package.json").write_text(
        json.dumps({"name": "cmux", "version": "1.2.3"}) + "\n"
    )
    launcher = package / "bin/cmux.js"
    launcher.write_bytes(LAUNCHER.read_bytes())
    launcher.chmod(0o755)
    return launcher


def start_registry() -> tuple[http.server.ThreadingHTTPServer, threading.Thread, str]:
    RegistryHandler.metadata_requests = 0
    RegistryHandler.tarball_requests = 0
    RegistryHandler.status = 200
    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), RegistryHandler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    return server, thread, f"http://127.0.0.1:{server.server_port}"


def test_launcher_downloads_once_and_reuses_verified_cache(tmp_path: Path) -> None:
    launcher = write_launcher(tmp_path)
    cache = tmp_path / "cache"
    server, thread, registry = start_registry()
    try:
        first = run_launcher(launcher, cache, registry, "--version")
        second = run_launcher(launcher, cache, registry, "--version")
    finally:
        server.shutdown()
        thread.join(timeout=5)
    assert first.returncode == 0, first.stderr
    assert second.returncode == 0, second.stderr
    assert first.stdout == second.stdout == "fake cmux-tui 1.2.3\n"
    assert RegistryHandler.metadata_requests == 1
    assert RegistryHandler.tarball_requests == 1
    cached = cache / "v/1.2.3/bin/cmux-tui"
    assert cached.is_file()
    assert cached.stat().st_mode & stat.S_IXUSR


def test_launcher_reports_network_failure_without_leaking_details(tmp_path: Path) -> None:
    launcher = write_launcher(tmp_path)
    result = run_launcher(launcher, tmp_path / "cache", "http://127.0.0.1:1")
    assert result.returncode != 0
    assert "could not obtain the native binary" in result.stderr
    assert "127.0.0.1" not in result.stderr
    assert "CMUX_" not in result.stderr
