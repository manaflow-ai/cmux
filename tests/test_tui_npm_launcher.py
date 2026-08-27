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
import time
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


def make_negative_size_tarball() -> bytes:
    tar = bytearray(gzip.decompress(make_tarball()))
    # -1000 is -512 in octal. The launcher must reject it before the tar
    # cursor can move backwards and parse the same header forever.
    tar[124:136] = b"-1000" + b"\0" * 7
    return gzip.compress(bytes(tar), mtime=0)


class RegistryHandler(http.server.BaseHTTPRequestHandler):
    tarball = make_tarball()
    metadata_requests = 0
    tarball_requests = 0
    authorization_headers: list[str | None] = []
    status = 200

    def do_GET(self) -> None:  # noqa: N802, required by BaseHTTPRequestHandler
        type(self).authorization_headers.append(self.headers.get("Authorization"))
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
    timeout_seconds: float | None = None,
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
        timeout=timeout_seconds,
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


def host_platform_key() -> str:
    arch = {
        "aarch64": "arm64",
        "arm64": "arm64",
        "amd64": "x64",
        "x86_64": "x64",
    }.get(platform.machine().lower())
    assert arch is not None, platform.machine()
    return f"{sys.platform}-{arch}"


def write_cached_binary(
    cache: Path,
    version: str,
    payload: str,
    *,
    managed: bool = False,
) -> Path:
    platform_key = host_platform_key()
    package = f"cmux-tui-{platform_key}"
    binary = cache / platform_key / f"v/{version}/bin/cmux-tui"
    data = payload.encode()
    binary.parent.mkdir(parents=True)
    binary.write_bytes(data)
    binary.chmod(0o755)
    version_dir = binary.parent.parent
    (version_dir / "manifest.json").write_text(
        json.dumps(
            {
                "package": package,
                "version": version,
                "tarballIntegrity": "sha512-fixture",
                "binaries": {"cmux-tui": hashlib.sha512(data).hexdigest()},
            }
        )
        + "\n"
    )
    if managed:
        (version_dir / "managed").write_text("cmux\n")
    return binary


def write_runtime_capability_stub(tmp_path: Path) -> Path:
    stub = tmp_path / "disable-node-network-apis.cjs"
    stub.write_text(
        "globalThis.fetch = undefined;\n"
        "if (typeof AbortSignal === \"function\") AbortSignal.timeout = undefined;\n"
    )
    return stub


def write_platform_stub(tmp_path: Path, platform_name: str = "freebsd") -> Path:
    stub = tmp_path / "unsupported-platform.cjs"
    stub.write_text(
        "Object.defineProperty(process, \"platform\", "
        f"{{ configurable: true, value: {json.dumps(platform_name)} }});\n"
    )
    return stub


def start_registry() -> tuple[http.server.ThreadingHTTPServer, threading.Thread, str]:
    RegistryHandler.metadata_requests = 0
    RegistryHandler.tarball_requests = 0
    RegistryHandler.authorization_headers = []
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
    runtime_stub = write_runtime_capability_stub(tmp_path)
    server, thread, registry = start_registry()
    try:
        first = run_launcher(launcher, cache, registry, "--version")
        # A verified cache hit must remain usable when the Node network APIs
        # are unavailable. The capability guard belongs on the download path.
        second = run_launcher(
            launcher,
            cache,
            registry,
            "--version",
            env_extra={"NODE_OPTIONS": f"--require={runtime_stub}"},
        )
    finally:
        server.shutdown()
        thread.join()
    assert first.returncode == 0, first.stderr
    assert second.returncode == 0, second.stderr
    assert first.stdout == second.stdout == "fake cmux-tui 1.2.3\n"
    assert RegistryHandler.metadata_requests == 1
    assert RegistryHandler.tarball_requests == 1
    platform_key = host_platform_key()
    cached = cache / platform_key / "v/1.2.3/bin/cmux-tui"
    assert cached.is_file()
    assert cached.stat().st_mode & stat.S_IXUSR
    assert not (cache / platform_key / "v/1.2.3/.active").exists()


def test_launcher_requires_network_runtime_capabilities(tmp_path: Path) -> None:
    if sys.platform == "win32":
        return
    launcher = write_launcher(tmp_path)
    runtime_stub = write_runtime_capability_stub(tmp_path)
    result = run_launcher(
        launcher,
        tmp_path / "cache",
        "http://127.0.0.1:1",
        "--version",
        env_extra={"NODE_OPTIONS": f"--require={runtime_stub}"},
    )
    assert result.returncode != 0
    assert "requires Node.js 18 or newer" in result.stderr
    assert "fetch" in result.stderr
    assert "AbortSignal.timeout" in result.stderr
    assert "127.0.0.1" not in result.stderr


def test_launcher_declares_node_engine_requirement() -> None:
    metadata = json.loads(
        (ROOT / "cmux-tui/dist/npm/cmux/package.json").read_text()
    )
    assert metadata.get("engines", {}).get("node") == ">=18"


def test_launcher_rejects_negative_tar_size_without_hanging(tmp_path: Path) -> None:
    if sys.platform == "win32":
        return
    launcher = write_launcher(tmp_path)
    cache = tmp_path / "cache"
    original_tarball = RegistryHandler.tarball
    RegistryHandler.tarball = make_negative_size_tarball()
    server, thread, registry = start_registry()
    try:
        try:
            result = run_launcher(
                launcher,
                cache,
                registry,
                "--version",
                timeout_seconds=2,
            )
        except subprocess.TimeoutExpired as error:
            raise AssertionError("malformed tar header caused the launcher to hang") from error
    finally:
        server.shutdown()
        thread.join()
        RegistryHandler.tarball = original_tarball
    assert result.returncode != 0
    assert "could not obtain the native binary" in result.stderr


def test_launcher_refetches_a_tampered_cached_binary(tmp_path: Path) -> None:
    if sys.platform == "win32":
        return
    launcher = write_launcher(tmp_path)
    cache = tmp_path / "cache"
    server, thread, registry = start_registry()
    try:
        first = run_launcher(launcher, cache, registry, "--version")
        arch = {
            "aarch64": "arm64",
            "arm64": "arm64",
            "amd64": "x64",
            "x86_64": "x64",
        }[platform.machine().lower()]
        binary = cache / f"{sys.platform}-{arch}/v/1.2.3/bin/cmux-tui"
        binary.write_text("#!/bin/sh\nprintf '%s\\n' 'tampered binary'\n")
        binary.chmod(0o755)
        second = run_launcher(launcher, cache, registry, "--version")
    finally:
        server.shutdown()
        thread.join()
    assert first.returncode == 0, first.stderr
    assert second.returncode == 0, second.stderr
    assert second.stdout == "fake cmux-tui 1.2.3\n"
    assert RegistryHandler.metadata_requests == 2
    assert RegistryHandler.tarball_requests == 2


def test_launcher_reports_network_failure_without_leaking_details(tmp_path: Path) -> None:
    if sys.platform == "win32":
        return
    launcher = write_launcher(tmp_path)
    result = run_launcher(launcher, tmp_path / "cache", "http://127.0.0.1:1")
    assert result.returncode != 0
    assert "could not obtain the native binary" in result.stderr
    assert "127.0.0.1" not in result.stderr
    assert "CMUX_" not in result.stderr


def test_launcher_reads_registry_token_from_npmrc(tmp_path: Path) -> None:
    if sys.platform == "win32":
        return
    launcher = write_launcher(tmp_path)
    cache = tmp_path / "cache"
    server, thread, registry = start_registry()
    npmrc = tmp_path / ".npmrc"
    npmrc.write_text(f"//127.0.0.1:{server.server_port}/:_authToken=fixture-token\n")
    try:
        result = run_launcher(
            launcher,
            cache,
            registry,
            env_extra={"npm_config_userconfig": str(npmrc)},
        )
    finally:
        server.shutdown()
        thread.join()
    assert result.returncode == 0, result.stderr
    assert RegistryHandler.authorization_headers
    assert all(value == "Bearer fixture-token" for value in RegistryHandler.authorization_headers)


def test_launcher_scopes_registry_token_to_npmrc_path(tmp_path: Path) -> None:
    if sys.platform == "win32":
        return
    launcher = write_launcher(tmp_path)
    cache = tmp_path / "cache"
    server, thread, registry = start_registry()
    npmrc = tmp_path / ".npmrc"
    npmrc.write_text(f"//127.0.0.1:{server.server_port}/private/:_authToken=fixture-token\n")
    try:
        result = run_launcher(
            launcher,
            cache,
            registry,
            env_extra={"npm_config_userconfig": str(npmrc)},
            timeout_seconds=3,
        )
        assert result.returncode == 0, result.stderr
        assert RegistryHandler.authorization_headers
        assert all(value is None for value in RegistryHandler.authorization_headers)

        RegistryHandler.authorization_headers = []
        scoped = run_launcher(
            launcher,
            cache / "private",
            f"{registry}/private",
            env_extra={"npm_config_userconfig": str(npmrc)},
            timeout_seconds=3,
        )
        assert scoped.returncode == 0, scoped.stderr
        assert RegistryHandler.authorization_headers == ["Bearer fixture-token", None]
    finally:
        server.shutdown()
        thread.join()


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


def test_binary_override_works_on_an_unsupported_platform(tmp_path: Path) -> None:
    if sys.platform == "win32":
        return
    launcher = write_launcher(tmp_path)
    binary = tmp_path / "dev-cmux-tui"
    binary.write_text("#!/bin/sh\nprintf '%s\\n' 'unsupported-platform override'\n")
    binary.chmod(0o755)
    platform_stub = write_platform_stub(tmp_path)
    result = run_launcher(
        launcher,
        tmp_path / "cache",
        "http://127.0.0.1:1",
        env_extra={
            "CMUX_TUI_BIN": str(binary),
            "NODE_OPTIONS": f"--require={platform_stub}",
        },
    )
    assert result.returncode == 0, result.stderr
    assert result.stdout == "unsupported-platform override\n"


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


def test_launcher_fails_closed_when_another_process_holds_cache_lock(tmp_path: Path) -> None:
    if sys.platform == "win32":
        return
    launcher = write_launcher(tmp_path)
    cache = tmp_path / "cache"
    write_cached_binary(
        cache,
        "1.2.3",
        "#!/bin/sh\nprintf '%s\\n' 'cached while lock held'\n",
    )
    lock = cache / host_platform_key() / ".update.lock"
    lock.mkdir(parents=True)
    owner = f"{os.getpid()}\nfixture-owner-token\n"
    owner_path = lock / "owner"
    owner_path.write_text(owner)

    result = run_launcher(
        launcher,
        cache,
        "http://127.0.0.1:1",
        "--version",
    )

    assert result.returncode != 0
    assert result.stdout == ""
    assert "could not reserve the native binary" in result.stderr
    assert owner_path.read_text() == owner


def test_concurrent_launchers_preserve_an_active_lease_during_prune(tmp_path: Path) -> None:
    if sys.platform == "win32":
        return
    old_launcher = write_launcher(tmp_path / "old", "1.0.0")
    new_launcher = write_launcher(tmp_path / "new", "1.2.3")
    cache = tmp_path / "cache"
    started = tmp_path / "old-started"
    old_payload = (
        "#!/bin/sh\n"
        f"printf '%s' started > {json.dumps(str(started))}\n"
        "sleep 2\n"
        "printf '%s\\n' 'old binary'\n"
    )
    write_cached_binary(cache, "1.0.0", old_payload, managed=True)
    write_cached_binary(cache, "1.1.0", "#!/bin/sh\nexit 0\n", managed=True)
    write_cached_binary(cache, "1.2.3", "#!/bin/sh\nexit 0\n", managed=True)

    env = os.environ.copy()
    env.update(
        {
            "CMUX_TUI_LAUNCHER_CACHE": str(cache),
            "CMUX_NPM_REGISTRY": "http://127.0.0.1:1",
            "NO_COLOR": "1",
        }
    )
    old_process = subprocess.Popen(
        ["node", str(old_launcher)],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        env=env,
    )
    try:
        deadline = time.monotonic() + 3
        while not started.exists() and time.monotonic() < deadline:
            time.sleep(0.01)
        assert started.exists(), "old launcher did not start its binary"

        new_result = run_launcher(
            new_launcher,
            cache,
            "http://127.0.0.1:1",
            "--version",
        )
        assert new_result.returncode == 0, new_result.stderr
        assert (cache / host_platform_key() / "v/1.0.0").exists()
    finally:
        try:
            old_process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            old_process.kill()
            old_process.wait(timeout=5)
    assert old_process.returncode == 0


def test_launcher_prunes_old_managed_cache_after_download(tmp_path: Path) -> None:
    if sys.platform == "win32":
        return
    launcher = write_launcher(tmp_path)
    cache = tmp_path / "cache"
    arch = {
        "aarch64": "arm64",
        "arm64": "arm64",
        "amd64": "x64",
        "x86_64": "x64",
    }[platform.machine().lower()]
    platform_root = cache / f"{sys.platform}-{arch}" / "v"
    for version in ("0.9.0", "1.0.0", "1.1.0"):
        binary = platform_root / version / "bin/cmux-tui"
        binary.parent.mkdir(parents=True)
        binary.write_text("#!/bin/sh\nexit 0\n")
        binary.chmod(0o755)
        binary.parent.parent.joinpath("managed").write_text("cmux\n")
    server, thread, registry = start_registry()
    try:
        result = run_launcher(launcher, cache, registry)
    finally:
        server.shutdown()
        thread.join()
    assert result.returncode == 0, result.stderr
    assert not (platform_root / "0.9.0").exists()
    assert not (platform_root / "1.0.0").exists()
    assert (platform_root / "1.1.0").exists()
    assert (platform_root / "1.2.3").exists()


def main() -> None:
    if sys.platform == "win32":
        return
    with tempfile.TemporaryDirectory(prefix="cmux-tui-launcher-test-") as directory:
        root = Path(directory)
        test_launcher_downloads_once_and_reuses_verified_cache(root / "download")
        test_launcher_requires_network_runtime_capabilities(root / "runtime")
        test_launcher_rejects_negative_tar_size_without_hanging(root / "negative-size")
        test_launcher_refetches_a_tampered_cached_binary(root / "tampered-cache")
        test_launcher_reports_network_failure_without_leaking_details(root / "failure")
        test_launcher_reads_registry_token_from_npmrc(root / "npmrc")
        test_launcher_scopes_registry_token_to_npmrc_path(root / "npmrc-scope")
        test_launcher_does_not_run_a_mismatched_installed_binary(root / "mismatch")
        test_managed_launcher_honors_development_binary_override(root / "override")
        test_binary_override_works_on_an_unsupported_platform(root / "unsupported-override")
        test_missing_binary_override_hides_path_and_variable(root / "missing-override")
        test_launcher_fails_closed_when_another_process_holds_cache_lock(root / "held-lock")
        test_concurrent_launchers_preserve_an_active_lease_during_prune(root / "concurrent")
        test_launcher_prunes_old_managed_cache_after_download(root / "prune")


if __name__ == "__main__":
    main()
