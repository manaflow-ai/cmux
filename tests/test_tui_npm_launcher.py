"""Behavior tests for the dependency-free npm launcher."""

from __future__ import annotations

import base64
import gzip
import hashlib
import http.server
import io
import json
import os
import platform
import stat
import subprocess
import sys
import tarfile
import tempfile
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
    return gzip.compress(tar_buffer.getvalue(), mtime=0)


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
    env_extra: dict[str, str] | None = None,
) -> subprocess.CompletedProcess[str]:
    env = os.environ.copy()
    env.update(
        {
            "CMUX_TUI_LAUNCHER_CACHE": str(cache),
            "CMUX_NPM_REGISTRY": registry,
            "NO_COLOR": "1",
        }
    )
    env.update(env_extra or {})
    return subprocess.run(
        ["node", str(launcher), *args],
        check=False,
        capture_output=True,
        text=True,
        env=env,
    )


def write_launcher(tmp_path: Path, version: str = "1.2.3") -> Path:
    package = tmp_path / "package"
    (package / "bin").mkdir(parents=True)
    (package / "package.json").write_text(
        json.dumps({"name": "cmux", "version": version}) + "\n"
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
    if sys.platform == "win32":
        return
    launcher = write_launcher(tmp_path)
    cache = tmp_path / "cache"
    server, thread, registry = start_registry()
    try:
        first = run_launcher(launcher, cache, registry, "--version")
        second = run_launcher(launcher, cache, registry, "--version")
    finally:
        server.shutdown()
        thread.join()
    assert first.returncode == 0, first.stderr
    assert second.returncode == 0, second.stderr
    assert first.stdout == second.stdout == "fake cmux-tui 1.2.3\n"
    assert RegistryHandler.metadata_requests == 1
    assert RegistryHandler.tarball_requests == 1
    arch = {
        "aarch64": "arm64",
        "arm64": "arm64",
        "amd64": "x64",
        "x86_64": "x64",
    }.get(platform.machine().lower())
    assert arch is not None, platform.machine()
    platform_key = f"{sys.platform}-{arch}"
    cached = cache / platform_key / "v/1.2.3/bin/cmux-tui"
    assert cached.is_file()
    assert cached.stat().st_mode & stat.S_IXUSR
    assert not (cache / platform_key / "v/1.2.3/.active").exists()


def test_launcher_reports_network_failure_without_leaking_details(tmp_path: Path) -> None:
    if sys.platform == "win32":
        return
    launcher = write_launcher(tmp_path)
    result = run_launcher(launcher, tmp_path / "cache", "http://127.0.0.1:1")
    assert result.returncode != 0
    assert "could not obtain the native binary" in result.stderr
    assert "127.0.0.1" not in result.stderr
    assert "CMUX_" not in result.stderr


def test_launcher_does_not_run_a_mismatched_installed_binary(tmp_path: Path) -> None:
    if sys.platform == "win32":
        return
    launcher = write_launcher(tmp_path)
    package = tmp_path / "node_modules/cmux-tui-darwin-arm64"
    package.mkdir(parents=True)
    (package / "package.json").write_text(
        json.dumps({"name": "cmux-tui-darwin-arm64", "version": "1.2.2"}) + "\n"
    )
    binary = package / "bin/cmux-tui"
    binary.parent.mkdir()
    binary.write_text("#!/bin/sh\nprintf '%s\\n' 'wrong binary'\n")
    binary.chmod(0o755)

    result = run_launcher(launcher, tmp_path / "cache", "http://127.0.0.1:1", "--version")
    assert result.returncode != 0
    assert result.stdout == ""
    assert "could not obtain the native binary" in result.stderr


def test_managed_launcher_honors_development_binary_override(tmp_path: Path) -> None:
    if sys.platform == "win32":
        return
    launcher = write_launcher(tmp_path, "0.0.0-managed")
    binary = tmp_path / "dev-cmux-tui"
    binary.write_text("#!/bin/sh\nprintf '%s\\n' 'development override'\n")
    binary.chmod(0o755)
    result = run_launcher(
        launcher,
        tmp_path / "cache",
        "http://127.0.0.1:1",
        env_extra={"CMUX_TUI_BIN": str(binary)},
    )
    assert result.returncode == 0, result.stderr
    assert result.stdout == "development override\n"


def test_missing_binary_override_hides_path_and_variable(tmp_path: Path) -> None:
    if sys.platform == "win32":
        return
    launcher = write_launcher(tmp_path, "1.2.3")
    missing = tmp_path / "missing-native"
    result = run_launcher(
        launcher,
        tmp_path / "cache",
        "http://127.0.0.1:1",
        env_extra={"CMUX_TUI_BIN": str(missing)},
    )
    assert result.returncode != 0
    assert "configured native binary override does not exist" in result.stderr
    assert str(missing) not in result.stderr
    assert "CMUX_TUI_BIN" not in result.stderr


def main() -> None:
    if sys.platform == "win32":
        return
    with tempfile.TemporaryDirectory(prefix="cmux-tui-launcher-test-") as directory:
        root = Path(directory)
        test_launcher_downloads_once_and_reuses_verified_cache(root / "download")
        test_launcher_reports_network_failure_without_leaking_details(root / "failure")
        test_launcher_does_not_run_a_mismatched_installed_binary(root / "mismatch")
        test_managed_launcher_honors_development_binary_override(root / "override")
        test_missing_binary_override_hides_path_and_variable(root / "missing-override")


if __name__ == "__main__":
    main()
