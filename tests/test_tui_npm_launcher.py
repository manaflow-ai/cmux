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
import re
import stat
import subprocess
import sys
import tarfile
import tempfile
import threading
import time
import urllib.parse
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
LAUNCHER = ROOT / "cmux-tui/dist/npm/cmux/bin/cmux.js"
NIGHTLY_VERSION = "1.2.3-nightly.20260827.1"


def make_tarball(
    payload: bytes | None = None,
    *,
    binary_name: str = "cmux-tui",
) -> bytes:
    if payload is None:
        payload = b"#!/bin/sh\nprintf '%s\\n' 'fake cmux-tui 1.2.3'\n"
    tar_buffer = io.BytesIO()
    with tarfile.open(fileobj=tar_buffer, mode="w") as archive:
        info = tarfile.TarInfo(f"package/bin/{binary_name}")
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
    tarballs: dict[str, bytes] = {}
    latest_version = "1.2.3"
    nightly_version = "1.2.3-nightly.20260826.1"
    block_tarball = False
    block_tarball_versions: set[str] = set()
    tarball_started = threading.Event()
    tarball_release = threading.Event()
    metadata_requests = 0
    tarball_requests = 0
    latest_requests: list[str] = []
    authorization_headers: list[str | None] = []
    request_paths: list[str] = []
    status = 200

    def do_GET(self) -> None:  # noqa: N802, required by BaseHTTPRequestHandler
        type(self).authorization_headers.append(self.headers.get("Authorization"))
        metadata_path = urllib.parse.urlsplit(self.path).path
        type(self).request_paths.append(metadata_path)
        metadata_match = re.search(
            r"/cmux-tui-[A-Za-z0-9._-]+/"
            r"([0-9]+\.[0-9]+\.[0-9]+(?:-[0-9A-Za-z.-]+)?)$",
            metadata_path,
        )
        if self.path in ("/cmux/latest", "/cmux/nightly"):
            type(self).latest_requests.append(self.path)
            version = (
                type(self).nightly_version
                if self.path == "/cmux/nightly"
                else type(self).latest_version
            )
            body = json.dumps({"version": version}).encode()
        elif metadata_match:
            type(self).metadata_requests += 1
            version = metadata_match.group(1)
            tarball = type(self).tarballs.get(version, type(self).tarball)
            body = json.dumps(
                {
                    "dist": {
                        "tarball": (
                            f"http://127.0.0.1:{self.server.server_port}/tarball.tgz?"
                            f"version={urllib.parse.quote(version, safe='')}"
                        ),
                        "integrity": "sha512-"
                        + base64.b64encode(hashlib.sha512(tarball).digest()).decode(),
                    }
                }
            ).encode()
        elif metadata_path != "/tarball.tgz" and re.fullmatch(
            r"/[A-Za-z0-9._-]+", metadata_path
        ):
            # npm's configured transport requests a package packument before
            # selecting a version. Return the same fixture tarballs as the raw
            # `/package/version` endpoint so ambient npm config cannot escape
            # this deterministic loopback registry.
            type(self).metadata_requests += 1
            package_name = metadata_path[1:]
            versions = {
                type(self).latest_version,
                type(self).nightly_version,
                *type(self).tarballs.keys(),
            }
            version_records = {}
            for version in versions:
                tarball = type(self).tarballs.get(version, type(self).tarball)
                dist = {
                    "tarball": (
                        f"http://127.0.0.1:{self.server.server_port}/tarball.tgz?"
                        f"version={urllib.parse.quote(version, safe='')}"
                    ),
                    "integrity": "sha512-"
                    + base64.b64encode(hashlib.sha512(tarball).digest()).decode(),
                }
                version_records[version] = {
                    "name": package_name,
                    "version": version,
                    "dist": dist,
                }
            body = json.dumps(
                {
                    "name": package_name,
                    "dist-tags": {
                        "latest": type(self).latest_version,
                        "nightly": type(self).nightly_version,
                    },
                    "versions": version_records,
                }
            ).encode()
        elif urllib.parse.urlsplit(self.path).path == "/tarball.tgz":
            type(self).tarball_requests += 1
            query = urllib.parse.parse_qs(urllib.parse.urlsplit(self.path).query)
            version = query.get("version", [None])[0]
            tarball = type(self).tarballs.get(version, type(self).tarball)
            blocked = type(self).block_tarball and (
                not type(self).block_tarball_versions
                or version in type(self).block_tarball_versions
            )
            if blocked:
                type(self).tarball_started.set()
                type(self).tarball_release.wait(timeout=10)
            body = tarball
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
    registry: str | None,
    *args: str,
    env_extra: dict[str, str] | None = None,
    env_remove: set[str] | None = None,
    timeout_seconds: float | None = None,
) -> subprocess.CompletedProcess[str]:
    env = os.environ.copy()
    for name in env_remove or set():
        env.pop(name, None)
    env.update(
        {
            "CMUX_TUI_LAUNCHER_CACHE": str(cache),
            "NO_COLOR": "1",
        }
    )
    if registry is None:
        for name in ("CMUX_NPM_REGISTRY", "npm_config_registry", "NPM_CONFIG_REGISTRY"):
            env.pop(name, None)
    else:
        env["CMUX_NPM_REGISTRY"] = registry
    env.update(env_extra or {})
    return subprocess.run(
        ["node", str(launcher), *args],
        check=False,
        capture_output=True,
        text=True,
        env=env,
        timeout=timeout_seconds,
    )


NPM_NETWORK_ENV_KEYS = {
    "npm_config_proxy",
    "npm_config_https-proxy",
    "npm_config_https_proxy",
    "npm_config_http-proxy",
    "npm_config_http_proxy",
    "npm_config_noproxy",
    "npm_config_cafile",
    "npm_config_ca",
    "npm_config_ca[]",
    "npm_config_cert",
    "npm_config_key",
    "npm_config_certfile",
    "npm_config_keyfile",
    "npm_config_strict-ssl",
    "npm_config_strict_ssl",
}


def isolated_npm_environment(
    tmp_path: Path,
    env_extra: dict[str, str],
) -> tuple[dict[str, str], set[str]]:
    """Keep ambient npm proxy and TLS settings out of loopback fixtures."""
    empty_npmrc = tmp_path / "empty.npmrc"
    empty_npmrc.write_text("")
    isolated_home = tmp_path / "home"
    isolated_home.mkdir(parents=True, exist_ok=True)
    env_remove = {
        name
        for name in os.environ
        if name.lower().startswith("npm_config_//")
        or name.lower() in NPM_NETWORK_ENV_KEYS
    }
    isolated = dict(env_extra)
    isolated.update(
        {
            "HOME": str(isolated_home),
            "USERPROFILE": str(isolated_home),
            "npm_config_userconfig": str(empty_npmrc),
            "NPM_CONFIG_USERCONFIG": str(empty_npmrc),
            "npm_config_globalconfig": str(empty_npmrc),
            "NPM_CONFIG_GLOBALCONFIG": str(empty_npmrc),
        }
    )
    return isolated, env_remove


def process_exited_within(
    process: subprocess.Popen[str], timeout_seconds: float
) -> bool:
    """Wait for the process-exit signal without polling a guessed delay."""
    exited = threading.Event()

    def wait_for_exit() -> None:
        process.wait()
        exited.set()

    threading.Thread(target=wait_for_exit, daemon=True).start()
    return exited.wait(timeout=timeout_seconds)


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
    binary.parent.mkdir(parents=True, exist_ok=True)
    binary.write_bytes(data)
    binary.chmod(0o755)
    version_dir = binary.parent.parent
    tarball = make_tarball(data)
    tarball_integrity = "sha512-" + base64.b64encode(
        hashlib.sha512(tarball).digest()
    ).decode()
    (version_dir / "manifest.json").write_text(
        json.dumps(
            {
                "package": package,
                "version": version,
                "tarballIntegrity": tarball_integrity,
                "binaries": {"cmux-tui": hashlib.sha512(data).hexdigest()},
            }
        )
        + "\n"
    )
    if managed:
        (version_dir / "managed").write_text("cmux\n")
    return binary


def make_cache_read_only(cache: Path) -> None:
    """Mark a fixture cache immutable so the launcher may use its offline path."""
    entries = [cache, *cache.rglob("*")]
    for entry in entries:
        if entry.is_symlink():
            raise AssertionError(f"fixture cache unexpectedly contains a symlink: {entry}")
    for entry in entries:
        if entry.exists():
            entry.chmod(stat.S_IMODE(entry.stat().st_mode) & ~0o222)


def write_runtime_capability_stub(tmp_path: Path) -> Path:
    stub = tmp_path / "disable-node-network-apis.cjs"
    stub.write_text(
        "globalThis.fetch = undefined;\n"
        "if (typeof AbortSignal === \"function\") AbortSignal.timeout = undefined;\n"
    )
    return stub


def write_fake_npm(tmp_path: Path) -> Path:
    """Return a Node script that exercises the launcher npm transport path."""
    fake = tmp_path / "fake-npm.cjs"
    fake.write_text(
        """
const fs = require('fs');
const path = require('path');
const args = process.argv.slice(2);
const log = process.env.FAKE_NPM_LOG;
if (log) {
  fs.appendFileSync(log, JSON.stringify({
    args,
    proxy: process.env.npm_config_https_proxy || null,
    cafile: process.env.npm_config_cafile || null,
    certfile: process.env.npm_config_certfile || null,
    keyfile: process.env.npm_config_keyfile || null,
  }) + '\\n');
}
if (args[0] === 'view') {
  const field = args[2];
  if (field === 'version') {
    process.stdout.write(JSON.stringify(process.env.FAKE_NPM_LATEST));
    process.exit(0);
  }
  if (field === 'dist') {
    process.stdout.write(JSON.stringify({
      tarball: 'https://registry.invalid/unused.tgz',
      integrity: process.env.FAKE_NPM_INTEGRITY,
    }));
    process.exit(0);
  }
}
if (args[0] === 'pack') {
  const destinationIndex = args.indexOf('--pack-destination');
  const destination = destinationIndex >= 0 ? args[destinationIndex + 1] : null;
  if (!destination) process.exit(2);
  const filename = 'cmux-tui-fixture.tgz';
  fs.copyFileSync(process.env.FAKE_NPM_TARBALL, path.join(destination, filename));
  process.stdout.write(JSON.stringify([{ filename }]));
  process.exit(0);
}
process.exit(2);
""".lstrip()
    )
    fake.chmod(0o755)
    return fake


def write_platform_stub(
    tmp_path: Path,
    platform_name: str = "freebsd",
    arch_name: str | None = None,
) -> Path:
    stub = tmp_path / "unsupported-platform.cjs"
    # Load the host path implementation before overriding process metadata.
    # Node normally selects this module during startup, but preloading it here
    # keeps the portable branch test's filesystem paths native to the host.
    contents = (
        'require("path");\n'
        "Object.defineProperty(process, \"platform\", "
        f"{{ configurable: true, value: {json.dumps(platform_name)} }});\n"
    )
    if arch_name is not None:
        contents += (
            "Object.defineProperty(process, \"arch\", "
            f"{{ configurable: true, value: {json.dumps(arch_name)} }});\n"
        )
    stub.write_text(contents)
    return stub


def start_registry(
    *,
    tarballs: dict[str, bytes] | None = None,
    block_tarball_versions: set[str] | None = None,
) -> tuple[http.server.ThreadingHTTPServer, threading.Thread, str]:
    RegistryHandler.metadata_requests = 0
    RegistryHandler.tarball_requests = 0
    RegistryHandler.authorization_headers = []
    RegistryHandler.request_paths = []
    RegistryHandler.status = 200
    RegistryHandler.latest_version = "1.2.3"
    RegistryHandler.nightly_version = NIGHTLY_VERSION
    RegistryHandler.block_tarball = False
    RegistryHandler.tarballs = dict(tarballs or {})
    RegistryHandler.block_tarball_versions = set(block_tarball_versions or set())
    RegistryHandler.tarball_started = threading.Event()
    RegistryHandler.tarball_release = threading.Event()
    RegistryHandler.latest_requests = []
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
        # Writable cache hits require a fresh registry verification. Mark this
        # provisioned fixture read-only to exercise the documented offline path.
        make_cache_read_only(cache)
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


def test_launcher_runs_verified_binary_from_read_only_cache(tmp_path: Path) -> None:
    if sys.platform == "win32":
        return
    launcher = write_launcher(tmp_path)
    cache = tmp_path / "cache"
    binary = write_cached_binary(
        cache,
        "1.2.3",
        "#!/bin/sh\nprintf '%s\\n' 'read-only cached binary'\n",
        managed=True,
    )
    platform_root = cache / host_platform_key()
    cache_dirs = [path for path in platform_root.rglob("*") if path.is_dir()]
    cache_dirs.extend((platform_root, cache))
    original_modes = {
        directory: stat.S_IMODE(directory.stat().st_mode) for directory in cache_dirs
    }
    trusted_files = [
        binary,
        binary.parent.parent / "manifest.json",
        binary.parent.parent / "managed",
    ]
    original_file_modes = {
        file: stat.S_IMODE(file.stat().st_mode) for file in trusted_files if file.exists()
    }
    for directory in cache_dirs:
        directory.chmod(original_modes[directory] & ~0o222)
    for file in original_file_modes:
        file.chmod(original_file_modes[file] & ~0o222)
    try:
        result = run_launcher(launcher, cache, "http://127.0.0.1:1", "--version")
    finally:
        for file in original_file_modes:
            file.chmod(original_file_modes[file])
        for directory in reversed(cache_dirs):
            directory.chmod(original_modes[directory])

    assert result.returncode == 0, result.stderr
    assert result.stdout == "read-only cached binary\n"
    assert binary.is_file()
    assert not (platform_root / ".update.lock").exists()
    assert not (platform_root / "v/1.2.3/.active").exists()


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
    assert not (tmp_path / "cache" / host_platform_key() / "v/1.2.3/.active").exists()


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


def test_launcher_refetches_tampered_manifest_and_binary(tmp_path: Path) -> None:
    if sys.platform == "win32":
        return
    launcher = write_launcher(tmp_path)
    cache = tmp_path / "cache"
    server, thread, registry = start_registry()
    try:
        first = run_launcher(launcher, cache, registry, "--version")
        version_dir = cache / f"{host_platform_key()}/v/1.2.3"
        manifest_path = version_dir / "manifest.json"
        manifest = json.loads(manifest_path.read_text())
        tampered = b"#!/bin/sh\nprintf '%s\\n' 'tampered cache'\n"
        manifest["tarballIntegrity"] = "sha512-" + base64.b64encode(
            hashlib.sha512(b"tampered tarball").digest()
        ).decode()
        manifest["binaries"]["cmux-tui"] = hashlib.sha512(tampered).hexdigest()
        manifest_path.write_text(json.dumps(manifest) + "\n")
        (version_dir / "bin/cmux-tui").write_bytes(tampered)
        (version_dir / "bin/cmux-tui").chmod(0o755)
        second = run_launcher(launcher, cache, registry, "--version")
    finally:
        server.shutdown()
        thread.join()
    assert first.returncode == 0, first.stderr
    assert second.returncode == 0, second.stderr
    assert second.stdout == "fake cmux-tui 1.2.3\n"
    assert RegistryHandler.metadata_requests == 2
    assert RegistryHandler.tarball_requests == 2
    repaired = json.loads((version_dir / "manifest.json").read_text())
    expected_integrity = "sha512-" + base64.b64encode(
        hashlib.sha512(RegistryHandler.tarball).digest()
    ).decode()
    assert repaired["tarballIntegrity"] == expected_integrity
    expected_binary = b"#!/bin/sh\nprintf '%s\\n' 'fake cmux-tui 1.2.3'\n"
    assert repaired["binaries"]["cmux-tui"] == hashlib.sha512(
        expected_binary
    ).hexdigest()


def test_launcher_repairs_non_executable_cached_binary(tmp_path: Path) -> None:
    if sys.platform == "win32":
        return
    launcher = write_launcher(tmp_path)
    cache = tmp_path / "cache"
    server, thread, registry = start_registry()
    try:
        first = run_launcher(launcher, cache, registry, "--version")
        binary = cache / f"{host_platform_key()}/v/1.2.3/bin/cmux-tui"
        binary.chmod(0o644)
        second = run_launcher(launcher, cache, registry, "--version")
    finally:
        server.shutdown()
        thread.join()

    assert first.returncode == 0, first.stderr
    assert second.returncode == 0, second.stderr
    assert second.stdout == "fake cmux-tui 1.2.3\n"
    assert binary.stat().st_mode & stat.S_IXUSR
    assert RegistryHandler.metadata_requests == 2
    assert RegistryHandler.tarball_requests == 2


def test_prune_preserves_unmanaged_cache_version(tmp_path: Path) -> None:
    if sys.platform == "win32":
        return
    launcher = write_launcher(tmp_path, "1.2.3")
    cache = tmp_path / "cache"
    write_cached_binary(cache, "1.0.0", "#!/bin/sh\nexit 0\n", managed=True)
    write_cached_binary(cache, "1.1.0", "#!/bin/sh\nexit 0\n", managed=True)
    unmanaged = write_cached_binary(
        cache,
        "9.9.9-dev",
        "#!/bin/sh\nprintf '%s\\n' 'development binary'\n",
    )
    unmanaged.chmod(0o644)
    write_cached_binary(cache, "1.2.3", "#!/bin/sh\nexit 0\n", managed=True)

    server, thread, registry = start_registry()
    try:
        result = run_launcher(launcher, cache, registry, "--version")
    finally:
        server.shutdown()
        thread.join()

    assert result.returncode == 0, result.stderr
    assert unmanaged.is_file()
    assert not unmanaged.parent.parent.joinpath("managed").exists()
    assert not (unmanaged.stat().st_mode & stat.S_IXUSR)


def test_prune_preserves_versions_selected_by_each_channel_state(
    tmp_path: Path,
) -> None:
    if sys.platform == "win32":
        return
    launcher = write_launcher(tmp_path, "1.2.3")
    cache = tmp_path / "cache"
    stable_old = "1.0.0"
    stable_previous = "1.1.0"
    stable_current = "1.2.3"
    nightly_old = "1.0.0-nightly.20260820.1"
    nightly_previous = "1.0.0-nightly.20260821.1"
    for version in (
        stable_old,
        stable_previous,
        stable_current,
        nightly_old,
        nightly_previous,
    ):
        write_cached_binary(cache, version, "#!/bin/sh\nexit 0\n", managed=True)

    platform_root = cache / host_platform_key()
    state_root = platform_root / "state"
    state_root.mkdir(parents=True)
    (state_root / "stable.json").write_text(
        json.dumps({"version": stable_old, "channel": "stable"}) + "\n"
    )
    (state_root / "nightly.json").write_text(
        json.dumps({"version": nightly_old, "channel": "nightly"}) + "\n"
    )

    server, thread, registry = start_registry()
    try:
        result = run_launcher(launcher, cache, registry, "--version")
    finally:
        server.shutdown()
        thread.join()

    assert result.returncode == 0, result.stderr
    assert result.stdout == "fake cmux-tui 1.2.3\n"
    for version in (stable_old, nightly_old, stable_previous, nightly_previous):
        assert (platform_root / f"v/{version}").is_dir()


def test_update_uses_channel_latest_and_persists_channel_state(tmp_path: Path) -> None:
    if sys.platform == "win32":
        return

    nightly_version = "1.2.3-nightly.20260826.1"
    nightly_launcher = write_launcher(tmp_path / "nightly", nightly_version)
    nightly_cache = tmp_path / "nightly-cache"
    server, thread, registry = start_registry()
    try:
        result = run_launcher(nightly_launcher, nightly_cache, registry, "update")
    finally:
        server.shutdown()
        thread.join()

    assert result.returncode == 0, result.stderr
    assert RegistryHandler.latest_requests == ["/cmux/nightly"]
    nightly_state = json.loads(
        (nightly_cache / host_platform_key() / "state/nightly.json").read_text()
    )
    assert nightly_state["version"] == RegistryHandler.nightly_version
    assert nightly_state["channel"] == "nightly"

    stable_launcher = write_launcher(tmp_path / "stable", "1.2.2")
    stable_cache = tmp_path / "stable-cache"
    server, thread, registry = start_registry()
    try:
        result = run_launcher(stable_launcher, stable_cache, registry, "update")
    finally:
        server.shutdown()
        thread.join()

    assert result.returncode == 0, result.stderr
    assert RegistryHandler.latest_requests == ["/cmux/latest"]
    stable_state = json.loads(
        (stable_cache / host_platform_key() / "state/stable.json").read_text()
    )
    assert stable_state["version"] == RegistryHandler.latest_version
    assert stable_state["channel"] == "stable"


def test_launcher_keeps_stable_and_nightly_state_channels_separate(
    tmp_path: Path,
) -> None:
    if sys.platform == "win32":
        return

    nightly_version = "1.2.3-nightly.20260826.1"
    cache = tmp_path / "shared-cache"
    nightly_launcher = write_launcher(tmp_path / "nightly", nightly_version)
    stable_launcher = write_launcher(tmp_path / "stable", "1.2.2")

    server, thread, registry = start_registry()
    try:
        nightly_update = run_launcher(nightly_launcher, cache, registry, "update")
    finally:
        server.shutdown()
        thread.join()
    assert nightly_update.returncode == 0, nightly_update.stderr
    assert RegistryHandler.latest_requests == ["/cmux/nightly"]

    server, thread, registry = start_registry()
    try:
        stable_update = run_launcher(stable_launcher, cache, registry, "update")
    finally:
        server.shutdown()
        thread.join()
    assert stable_update.returncode == 0, stable_update.stderr
    assert RegistryHandler.latest_requests == ["/cmux/latest"]

    platform_root = cache / host_platform_key()
    nightly_state = json.loads((platform_root / "state/nightly.json").read_text())
    stable_state = json.loads((platform_root / "state/stable.json").read_text())
    assert nightly_state["version"] == RegistryHandler.nightly_version
    assert nightly_state["channel"] == "nightly"
    assert stable_state["version"] == RegistryHandler.latest_version
    assert stable_state["channel"] == "stable"

    # Replace the downloaded fixture payloads with channel-specific markers,
    # then launch older shims offline using their persisted channel state.
    write_cached_binary(
        cache,
        RegistryHandler.nightly_version,
        "#!/bin/sh\nprintf '%s\\n' 'nightly binary'\n",
        managed=True,
    )
    write_cached_binary(
        cache,
        RegistryHandler.latest_version,
        "#!/bin/sh\nprintf '%s\\n' 'stable binary'\n",
        managed=True,
    )
    # A legacy shared file from an older launcher must not cross-satisfy a
    # stable shim with a nightly version.
    (platform_root / "state.json").write_text(
        json.dumps({"version": RegistryHandler.nightly_version}) + "\n"
    )
    make_cache_read_only(cache)
    nightly_result = run_launcher(
        nightly_launcher, cache, "http://127.0.0.1:1", "--version"
    )
    stable_result = run_launcher(
        stable_launcher, cache, "http://127.0.0.1:1", "--version"
    )
    assert nightly_result.returncode == 0, nightly_result.stderr
    assert nightly_result.stdout == "nightly binary\n"
    assert stable_result.returncode == 0, stable_result.stderr
    assert stable_result.stdout == "stable binary\n"


def test_launcher_windows_path_covers_exe_snapshot_lock_and_update(
    tmp_path: Path,
) -> None:
    """Exercise the Windows launcher branches on every supported CI host.

    Native Windows runs this path with the system ``cmd.exe``. Unix runners
    preload a small process metadata shim so the same launcher code selects
    ``win32-x64`` and ``cmux-tui.exe`` while executing a real host executable.
    This keeps the Windows-specific cache, snapshot, lock, and update behavior
    covered even when the surrounding workflow has no Windows Python job.
    """
    tmp_path.mkdir(parents=True, exist_ok=True)
    if sys.platform == "win32":
        assert host_platform_key() == "win32-x64"
        command_path = os.environ.get("ComSpec") or os.environ.get("COMSPEC")
        if not command_path:
            command_path = str(
                Path(os.environ.get("SystemRoot", r"C:\\Windows"))
                / "System32"
                / "cmd.exe"
            )
        executable = Path(command_path)
        child_args = ("/d", "/c", "echo", "windows-cache-snapshot")
        env_extra: dict[str, str] = {}
    else:
        executable = Path("/bin/sh")
        child_args = ("-c", "printf '%s\\n' windows-cache-snapshot")
        platform_stub = write_platform_stub(tmp_path, "win32", "x64")
        env_extra = {"NODE_OPTIONS": f"--require={platform_stub}"}
    env_extra, env_remove = isolated_npm_environment(tmp_path, env_extra)

    assert executable.is_file(), executable
    payload = executable.read_bytes()
    tarball = make_tarball(payload, binary_name="cmux-tui.exe")
    launcher = write_launcher(tmp_path / "launcher", "1.0.0")
    cache = tmp_path / "cache"
    server, thread, registry = start_registry(tarballs={"1.2.3": tarball})
    platform_root = cache / "win32-x64"
    update_process = None
    update_stdout = ""
    update_stderr = ""
    try:
        # Hold the tarball response so the test can observe the update-wide
        # lock and target lease before any bytes are published.
        RegistryHandler.block_tarball = True
        RegistryHandler.block_tarball_versions = {"1.2.3"}
        update_env = os.environ.copy()
        for name in env_remove:
            update_env.pop(name, None)
        update_env.update(
            {
                "CMUX_TUI_LAUNCHER_CACHE": str(cache),
                "CMUX_NPM_REGISTRY": registry,
                "NO_COLOR": "1",
                **env_extra,
            }
        )
        update_process = subprocess.Popen(
            ["node", str(write_launcher(tmp_path / "update", "1.0.0")), "update"],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            env=update_env,
        )
        assert RegistryHandler.tarball_started.wait(timeout=5), (
            "Windows update did not start its tarball request"
        )
        update_lock = platform_root / ".update-operation.lock"
        assert (update_lock / "owner").is_file(), (
            "Windows update did not hold the operation lock"
        )
        active_root = platform_root / "v/1.2.3/.active"
        assert any(entry.is_dir() for entry in active_root.iterdir()), (
            "Windows update did not publish its target lease"
        )
        RegistryHandler.tarball_release.set()
        update_stdout, update_stderr = update_process.communicate(timeout=10)
    finally:
        RegistryHandler.tarball_release.set()
        if update_process is not None and update_process.poll() is None:
            update_process.kill()
            update_process.communicate(timeout=5)
        server.shutdown()
        thread.join()

    assert update_process is not None
    assert update_process.returncode == 0, update_stderr or update_stdout
    assert RegistryHandler.latest_requests == ["/cmux/latest"]
    binary = platform_root / "v/1.2.3/bin/cmux-tui.exe"
    assert binary.is_file()
    assert binary.read_bytes() == payload
    state = json.loads((platform_root / "state/stable.json").read_text())
    assert state["version"] == "1.2.3"
    assert state["channel"] == "stable"
    assert not (platform_root / ".update-operation.lock").exists()
    assert not (platform_root / ".update.lock").exists()
    assert not (platform_root / "v/1.2.3/.active").exists()
    assert RegistryHandler.metadata_requests == 1
    assert RegistryHandler.tarball_requests == 1

    # The update check above intentionally blocks the registry thread. Start a
    # fresh local fixture for the launch checks after that process is cleaned up.
    server, thread, registry = start_registry(tarballs={"1.2.3": tarball})
    try:
        first = run_launcher(
            launcher,
            cache,
            registry,
            *child_args,
            env_extra=env_extra,
            env_remove=env_remove,
        )
        assert first.returncode == 0, (
            f"{first.stderr}\nregistry requests: {RegistryHandler.request_paths!r}"
        )
        assert "windows-cache-snapshot" in first.stdout
        assert RegistryHandler.metadata_requests == 1
        assert RegistryHandler.tarball_requests == 1

        # A writable cache hit is authenticated by a fresh registry response.
        # A matching local manifest cannot bless a replaced executable or
        # tarball.
        version_dir = binary.parent.parent
        manifest_path = version_dir / "manifest.json"
        manifest = json.loads(manifest_path.read_text())
        tampered = b"tampered Windows executable"
        manifest["tarballIntegrity"] = "sha512-" + base64.b64encode(
            hashlib.sha512(b"tampered tarball").digest()
        ).decode()
        manifest["binaries"]["cmux-tui.exe"] = hashlib.sha512(tampered).hexdigest()
        manifest_path.write_text(json.dumps(manifest) + "\n")
        binary.write_bytes(tampered)

        second = run_launcher(
            launcher,
            cache,
            registry,
            *child_args,
            env_extra=env_extra,
            env_remove=env_remove,
        )
        assert second.returncode == 0, second.stderr
        assert "windows-cache-snapshot" in second.stdout
        assert binary.read_bytes() == payload
        assert RegistryHandler.metadata_requests == 2
        assert RegistryHandler.tarball_requests == 2
        assert not (platform_root / ".update-operation.lock").exists()
        assert not (platform_root / ".update.lock").exists()
        assert not (platform_root / "v/1.2.3/.active").exists()
    finally:
        server.shutdown()
        thread.join()


def test_launcher_reports_network_failure_without_leaking_details(tmp_path: Path) -> None:
    if sys.platform == "win32":
        return
    launcher = write_launcher(tmp_path)
    cache = tmp_path / "cache"
    result = run_launcher(launcher, cache, "http://127.0.0.1:1")
    assert result.returncode != 0
    assert "could not obtain the native binary" in result.stderr
    assert "127.0.0.1" not in result.stderr
    assert "CMUX_" not in result.stderr
    assert not (cache / host_platform_key() / "v/1.2.3/.active").exists()


def test_launcher_releases_lease_when_native_launch_fails(tmp_path: Path) -> None:
    if sys.platform == "win32":
        return
    launcher = write_launcher(tmp_path)
    cache = tmp_path / "cache"
    write_cached_binary(
        cache,
        "1.2.3",
        "#!/definitely/missing/interpreter\n",
        managed=True,
    )

    bad_payload = b"#!/definitely/missing/interpreter\n"
    server, thread, registry = start_registry(
        tarballs={"1.2.3": make_tarball(bad_payload)}
    )
    try:
        result = run_launcher(launcher, cache, registry, "--version")
    finally:
        server.shutdown()
        thread.join()

    assert result.returncode != 0
    assert "failed to launch the native binary" in result.stderr
    assert not (cache / host_platform_key() / "v/1.2.3/.active").exists()


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


def test_launcher_reads_registry_from_npmrc(tmp_path: Path) -> None:
    if sys.platform == "win32":
        return
    launcher = write_launcher(tmp_path)
    cache = tmp_path / "cache"
    server, thread, registry = start_registry()
    npmrc = tmp_path / ".npmrc"
    npmrc.write_text(f"registry={registry}\n")
    try:
        result = run_launcher(
            launcher,
            cache,
            None,
            "--version",
            env_extra={"npm_config_userconfig": str(npmrc)},
        )
    finally:
        server.shutdown()
        thread.join()
    assert result.returncode == 0, result.stderr
    assert result.stdout == "fake cmux-tui 1.2.3\n"
    assert RegistryHandler.metadata_requests == 1
    assert RegistryHandler.tarball_requests == 1


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


def test_launcher_uses_npm_for_proxy_and_tls_config(tmp_path: Path) -> None:
    if sys.platform == "win32":
        return
    launcher = write_launcher(tmp_path)
    cache = tmp_path / "cache"
    fake_npm = write_fake_npm(tmp_path)
    tarball = tmp_path / "fixture.tgz"
    tarball.write_bytes(make_tarball())
    integrity = "sha512-" + base64.b64encode(hashlib.sha512(tarball.read_bytes()).digest()).decode()
    log = tmp_path / "npm.log"
    cafile = tmp_path / "ca.pem"
    certfile = tmp_path / "client.crt"
    keyfile = tmp_path / "client.key"
    for file in (cafile, certfile, keyfile):
        file.write_text("fixture\n")

    result = run_launcher(
        launcher,
        cache,
        "http://127.0.0.1:1",
        "--version",
        env_extra={
            "npm_execpath": str(fake_npm),
            "npm_config_https_proxy": "http://proxy.invalid:8080",
            "npm_config_cafile": str(cafile),
            "npm_config_certfile": str(certfile),
            "npm_config_keyfile": str(keyfile),
            "FAKE_NPM_LOG": str(log),
            "FAKE_NPM_TARBALL": str(tarball),
            "FAKE_NPM_INTEGRITY": integrity,
        },
    )

    assert result.returncode == 0, result.stderr
    assert result.stdout == "fake cmux-tui 1.2.3\n"
    records = [json.loads(line) for line in log.read_text().splitlines()]
    assert [record["args"][0] for record in records] == ["view", "pack"]
    view_args, pack_args = (record["args"] for record in records)
    assert f"cmux-tui-{host_platform_key()}@1.2.3" in view_args
    assert f"cmux-tui-{host_platform_key()}@1.2.3" in pack_args
    for args in (view_args, pack_args):
        assert "--ignore-scripts" in args
        assert "--registry" in args
        assert "http://127.0.0.1:1" in args
    assert all(record["proxy"] == "http://proxy.invalid:8080" for record in records)
    assert all(record["cafile"] == str(cafile) for record in records)
    assert all(record["certfile"] == str(certfile) for record in records)
    assert all(record["keyfile"] == str(keyfile) for record in records)


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


def test_launcher_runs_matching_installed_binary_without_cache_access(tmp_path: Path) -> None:
    if sys.platform == "win32":
        return
    launcher = write_launcher(tmp_path)
    package_name = f"cmux-tui-{host_platform_key()}"
    package = tmp_path / "node_modules" / package_name
    package.mkdir(parents=True)
    (package / "package.json").write_text(
        json.dumps({"name": package_name, "version": "1.2.3"}) + "\n"
    )
    binary = package / "bin/cmux-tui"
    binary.parent.mkdir()
    binary.write_text("#!/bin/sh\nprintf '%s\\n' 'installed offline binary'\n")
    binary.chmod(0o755)
    cache_file = tmp_path / "cache-file"
    cache_file.write_text("cache is intentionally unavailable\n")

    result = run_launcher(launcher, cache_file, "http://127.0.0.1:1", "--version")

    assert result.returncode == 0, result.stderr
    assert result.stdout == "installed offline binary\n"
    assert cache_file.read_text() == "cache is intentionally unavailable\n"


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


def test_launcher_reclaims_cache_lock_when_owner_pid_is_reused(tmp_path: Path) -> None:
    if sys.platform == "win32":
        return
    launcher = write_launcher(tmp_path)
    cache = tmp_path / "cache"
    write_cached_binary(
        cache,
        "1.2.3",
        "#!/bin/sh\nprintf '%s\\n' 'cached after pid reuse'\n",
    )
    lock = cache / host_platform_key() / ".update.lock"
    lock.mkdir(parents=True)
    # Keep the test process PID but use a different process-start identity. A
    # stale timestamp also covers legacy records without that identity.
    stale_created_at = int((time.time() - 11 * 60) * 1000)
    (lock / "owner").write_text(
        f"{os.getpid()}\nfixture-owner-token\nproc:old-start\n{stale_created_at}\n"
    )
    os.utime(lock, (stale_created_at / 1000, stale_created_at / 1000))

    payload = b"#!/bin/sh\nprintf '%s\\n' 'cached after pid reuse'\n"
    server, thread, registry = start_registry(
        tarballs={"1.2.3": make_tarball(payload)}
    )
    try:
        result = run_launcher(launcher, cache, registry, "--version")
    finally:
        server.shutdown()
        thread.join()

    assert result.returncode == 0, result.stderr
    assert result.stdout == "cached after pid reuse\n"
    assert not lock.exists()


def test_launcher_waits_for_short_cache_lock_contention(tmp_path: Path) -> None:
    if sys.platform == "win32":
        return
    launcher = write_launcher(tmp_path)
    cache = tmp_path / "cache"
    write_cached_binary(
        cache,
        "1.2.3",
        "#!/bin/sh\nprintf '%s\\n' 'cached after short lock contention'\n",
    )
    lock = cache / host_platform_key() / ".update.lock"
    lock.mkdir(parents=True)
    (lock / "owner").write_text(f"{os.getpid()}\nfixture-owner-token\n")

    payload = b"#!/bin/sh\nprintf '%s\\n' 'cached after short lock contention'\n"
    server, thread, registry = start_registry(
        tarballs={"1.2.3": make_tarball(payload)}
    )
    process = subprocess.Popen(
        ["node", str(launcher), "--version"],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        env={
            **os.environ,
            "CMUX_TUI_LAUNCHER_CACHE": str(cache),
            "CMUX_NPM_REGISTRY": registry,
            "NO_COLOR": "1",
        },
    )
    stdout = ""
    stderr = ""
    try:
        assert not process_exited_within(
            process, timeout_seconds=0.2
        ), "launcher failed before the short lock was released"
        (lock / "owner").unlink()
        lock.rmdir()
        stdout, stderr = process.communicate(timeout=5)
    finally:
        if process.poll() is None:
            process.kill()
            process.communicate(timeout=5)
        server.shutdown()
        thread.join()

    assert process.returncode == 0, stderr or stdout
    assert stdout == "cached after short lock contention\n"


def test_launcher_recovers_stale_empty_cache_lock(tmp_path: Path) -> None:
    if sys.platform == "win32":
        return
    launcher = write_launcher(tmp_path)
    cache = tmp_path / "cache"
    write_cached_binary(
        cache,
        "1.2.3",
        "#!/bin/sh\nprintf '%s\\n' 'cached after interrupted lock'\n",
    )
    lock = cache / host_platform_key() / ".update.lock"
    lock.mkdir(parents=True)
    stale = time.time() - 10 * 60
    os.utime(lock, (stale, stale))

    payload = b"#!/bin/sh\nprintf '%s\\n' 'cached after interrupted lock'\n"
    server, thread, registry = start_registry(
        tarballs={"1.2.3": make_tarball(payload)}
    )
    try:
        result = run_launcher(launcher, cache, registry, "--version")
    finally:
        server.shutdown()
        thread.join()

    assert result.returncode == 0, result.stderr
    assert result.stdout == "cached after interrupted lock\n"
    assert not lock.exists()


def test_launcher_keeps_fresh_empty_cache_lock(tmp_path: Path) -> None:
    if sys.platform == "win32":
        return
    launcher = write_launcher(tmp_path)
    cache = tmp_path / "cache"
    write_cached_binary(
        cache,
        "1.2.3",
        "#!/bin/sh\nprintf '%s\\n' 'cached while lock initializes'\n",
    )
    lock = cache / host_platform_key() / ".update.lock"
    lock.mkdir(parents=True)

    result = run_launcher(
        launcher,
        cache,
        "http://127.0.0.1:1",
        "--version",
    )

    assert result.returncode != 0
    assert result.stdout == ""
    assert "could not reserve the native binary" in result.stderr
    assert lock.is_dir()
    assert not (lock / "owner").exists()


def test_launcher_reclaims_stale_empty_lease_during_prune(tmp_path: Path) -> None:
    if sys.platform == "win32":
        return
    launcher = write_launcher(tmp_path)
    cache = tmp_path / "cache"
    write_cached_binary(cache, "1.0.0", "#!/bin/sh\nexit 0\n", managed=True)
    write_cached_binary(cache, "1.1.0", "#!/bin/sh\nexit 0\n", managed=True)
    lease_root = cache / host_platform_key() / "v/1.0.0/.active"
    stale_lease = lease_root / "interrupted-lease"
    stale_lease.mkdir(parents=True)
    stale = time.time() - 10 * 60
    os.utime(stale_lease, (stale, stale))

    server, thread, registry = start_registry()
    try:
        result = run_launcher(launcher, cache, registry)
    finally:
        server.shutdown()
        thread.join()

    assert result.returncode == 0, result.stderr
    assert not (cache / host_platform_key() / "v/1.0.0").exists()


def test_launcher_reclaims_cache_lease_when_owner_pid_is_reused(tmp_path: Path) -> None:
    if sys.platform == "win32":
        return
    launcher = write_launcher(tmp_path)
    cache = tmp_path / "cache"
    write_cached_binary(cache, "1.0.0", "#!/bin/sh\nexit 0\n", managed=True)
    write_cached_binary(cache, "1.1.0", "#!/bin/sh\nexit 0\n", managed=True)
    lease = cache / host_platform_key() / "v/1.0.0/.active/reused-lease"
    lease.mkdir(parents=True)
    stale_created_at = int((time.time() - 11 * 60) * 1000)
    (lease / "pid").write_text(
        f"{os.getpid()}\nfixture-owner-token\nproc:old-start\n{stale_created_at}\n"
    )
    os.utime(lease, (stale_created_at / 1000, stale_created_at / 1000))

    server, thread, registry = start_registry()
    try:
        result = run_launcher(launcher, cache, registry)
    finally:
        server.shutdown()
        thread.join()

    assert result.returncode == 0, result.stderr
    assert not (cache / host_platform_key() / "v/1.0.0").exists()


def test_launcher_keeps_fresh_empty_lease_during_prune(tmp_path: Path) -> None:
    if sys.platform == "win32":
        return
    launcher = write_launcher(tmp_path)
    cache = tmp_path / "cache"
    write_cached_binary(cache, "1.0.0", "#!/bin/sh\nexit 0\n", managed=True)
    write_cached_binary(cache, "1.1.0", "#!/bin/sh\nexit 0\n", managed=True)
    lease_root = cache / host_platform_key() / "v/1.0.0/.active"
    fresh_lease = lease_root / "initializing-lease"
    fresh_lease.mkdir(parents=True)

    server, thread, registry = start_registry()
    try:
        result = run_launcher(launcher, cache, registry)
    finally:
        server.shutdown()
        thread.join()

    assert result.returncode == 0, result.stderr
    assert fresh_lease.is_dir()


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

    server, thread, registry = start_registry(
        tarballs={
            "1.0.0": make_tarball(old_payload.encode()),
            "1.2.3": make_tarball(b"#!/bin/sh\nexit 0\n"),
        }
    )
    env = os.environ.copy()
    env.update(
        {
            "CMUX_TUI_LAUNCHER_CACHE": str(cache),
            "CMUX_NPM_REGISTRY": registry,
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
            registry,
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
        server.shutdown()
        thread.join()
    assert old_process.returncode == 0


def test_update_lease_protects_download_from_concurrent_prune(tmp_path: Path) -> None:
    if sys.platform == "win32":
        return
    update_launcher = write_launcher(tmp_path / "update", "1.0.0")
    launch_launcher = write_launcher(tmp_path / "launch", "1.1.0")
    cache = tmp_path / "cache"
    write_cached_binary(cache, "1.0.0", "#!/bin/sh\nexit 0\n", managed=True)
    write_cached_binary(
        cache,
        "1.1.0",
        "#!/bin/sh\nprintf '%s\\n' 'cached while update is downloading'\n",
        managed=True,
    )
    # This version is deliberately un-managed. A concurrent launcher's prune
    # would delete it unless the update process publishes its lease first.
    target = write_cached_binary(
        cache,
        "1.2.3",
        "#!/bin/sh\nprintf '%s\\n' 'fake cmux-tui 1.2.3'\n",
    )

    launch_payload = b"#!/bin/sh\nprintf '%s\\n' 'cached while update is downloading'\n"
    server, thread, registry = start_registry(
        tarballs={"1.1.0": make_tarball(launch_payload)},
        block_tarball_versions={"1.2.3"},
    )
    RegistryHandler.block_tarball = True
    env = os.environ.copy()
    env.update(
        {
            "CMUX_TUI_LAUNCHER_CACHE": str(cache),
            "CMUX_NPM_REGISTRY": registry,
            "NO_COLOR": "1",
        }
    )
    update_process = subprocess.Popen(
        ["node", str(update_launcher), "update"],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        env=env,
    )
    update_stdout = ""
    update_stderr = ""
    try:
        assert RegistryHandler.tarball_started.wait(timeout=3), (
            "update did not start its download"
        )
        update_lock = cache / host_platform_key() / ".update-operation.lock"
        assert (update_lock / "owner").is_file(), (
            "update did not hold the operation lock during its download"
        )
        active_root = cache / host_platform_key() / "v/1.2.3/.active"
        assert any(entry.is_dir() for entry in active_root.iterdir()), (
            "update did not publish its target lease before downloading"
        )
        launch_result = run_launcher(
            launch_launcher,
            cache,
            registry,
            "--version",
            timeout_seconds=5,
        )
        assert launch_result.returncode == 0, launch_result.stderr
        assert launch_result.stdout == "cached while update is downloading\n"
        assert target.is_file(), "concurrent prune removed the leased update target"
    finally:
        RegistryHandler.tarball_release.set()
        try:
            update_stdout, update_stderr = update_process.communicate(timeout=10)
        except subprocess.TimeoutExpired:
            update_process.kill()
            update_stdout, update_stderr = update_process.communicate(timeout=5)
        server.shutdown()
        thread.join()

    assert update_process.returncode == 0, update_stderr or update_stdout
    assert target.is_file()
    assert (target.parent.parent / "managed").is_file()


def test_concurrent_updates_fail_closed_while_one_downloads(tmp_path: Path) -> None:
    if sys.platform == "win32":
        return
    update_launcher = write_launcher(tmp_path / "first", "1.0.0")
    concurrent_launcher = write_launcher(tmp_path / "second", "1.0.0")
    cache = tmp_path / "cache"
    write_cached_binary(cache, "1.0.0", "#!/bin/sh\nexit 0\n", managed=True)

    server, thread, registry = start_registry()
    RegistryHandler.block_tarball = True
    env = os.environ.copy()
    env.update(
        {
            "CMUX_TUI_LAUNCHER_CACHE": str(cache),
            "CMUX_NPM_REGISTRY": registry,
            "NO_COLOR": "1",
        }
    )
    first_process = subprocess.Popen(
        ["node", str(update_launcher), "update"],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        env=env,
    )
    first_stdout = ""
    first_stderr = ""
    try:
        assert RegistryHandler.tarball_started.wait(timeout=3), (
            "first update did not start its download"
        )
        second = run_launcher(
            concurrent_launcher,
            cache,
            registry,
            "update",
            timeout_seconds=5,
        )
        assert second.returncode != 0
        assert "could not reserve the native binary for update" in second.stderr
    finally:
        RegistryHandler.tarball_release.set()
        try:
            first_stdout, first_stderr = first_process.communicate(timeout=10)
        except subprocess.TimeoutExpired:
            first_process.kill()
            first_stdout, first_stderr = first_process.communicate(timeout=5)
        server.shutdown()
        thread.join()

    assert first_process.returncode == 0, first_stderr or first_stdout
    state = json.loads(
        (cache / host_platform_key() / "state/stable.json").read_text()
    )
    assert state["version"] == "1.2.3"
    assert not (cache / host_platform_key() / ".update-operation.lock").exists()


def test_launcher_keeps_current_and_one_previous_after_download(tmp_path: Path) -> None:
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
    retained = {
        entry.name for entry in platform_root.iterdir() if entry.is_dir()
    }
    assert retained == {"1.1.0", "1.2.3"}


def main() -> None:
    with tempfile.TemporaryDirectory(prefix="cmux-tui-launcher-test-") as directory:
        root = Path(directory)
        test_launcher_windows_path_covers_exe_snapshot_lock_and_update(
            root / "windows"
        )
        if sys.platform == "win32":
            return
        test_launcher_downloads_once_and_reuses_verified_cache(root / "download")
        test_launcher_requires_network_runtime_capabilities(root / "runtime")
        test_launcher_rejects_negative_tar_size_without_hanging(root / "negative-size")
        test_launcher_refetches_a_tampered_cached_binary(root / "tampered-cache")
        test_launcher_refetches_tampered_manifest_and_binary(
            root / "tampered-manifest-cache"
        )
        test_launcher_repairs_non_executable_cached_binary(root / "non-executable-cache")
        test_launcher_reports_network_failure_without_leaking_details(root / "failure")
        test_launcher_releases_lease_when_native_launch_fails(root / "launch-failure")
        test_launcher_reads_registry_token_from_npmrc(root / "npmrc")
        test_launcher_scopes_registry_token_to_npmrc_path(root / "npmrc-scope")
        test_launcher_uses_npm_for_proxy_and_tls_config(root / "npm-network-config")
        test_launcher_does_not_run_a_mismatched_installed_binary(root / "mismatch")
        test_launcher_runs_matching_installed_binary_without_cache_access(root / "installed-offline")
        test_managed_launcher_honors_development_binary_override(root / "override")
        test_binary_override_works_on_an_unsupported_platform(root / "unsupported-override")
        test_missing_binary_override_hides_path_and_variable(root / "missing-override")
        test_launcher_fails_closed_when_another_process_holds_cache_lock(root / "held-lock")
        test_launcher_reclaims_cache_lock_when_owner_pid_is_reused(
            root / "reused-lock"
        )
        test_launcher_waits_for_short_cache_lock_contention(root / "short-lock")
        test_launcher_recovers_stale_empty_cache_lock(root / "stale-empty-lock")
        test_launcher_keeps_fresh_empty_cache_lock(root / "fresh-empty-lock")
        test_launcher_reclaims_stale_empty_lease_during_prune(root / "stale-empty-lease")
        test_launcher_reclaims_cache_lease_when_owner_pid_is_reused(
            root / "reused-lease"
        )
        test_launcher_keeps_fresh_empty_lease_during_prune(root / "fresh-empty-lease")
        test_concurrent_launchers_preserve_an_active_lease_during_prune(root / "concurrent")
        test_update_lease_protects_download_from_concurrent_prune(root / "update-concurrent")
        test_concurrent_updates_fail_closed_while_one_downloads(root / "update-serialization")
        test_prune_preserves_unmanaged_cache_version(root / "unmanaged-cache")
        test_update_uses_channel_latest_and_persists_channel_state(
            root / "channel-update"
        )
        test_launcher_keeps_stable_and_nightly_state_channels_separate(
            root / "channel-state"
        )
        test_launcher_keeps_current_and_one_previous_after_download(root / "prune")


if __name__ == "__main__":
    main()
