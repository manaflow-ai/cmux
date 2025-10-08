#!/usr/bin/env python3
"""Remote Morph instance provisioning script with parallel task graph execution.

This script boots a Morph instance from a stock snapshot, installs all runtime
requirements directly on the VM (without building a Docker image), uploads the
local cmux repository, builds custom binaries, starts essential services, runs
sanity checks, snapshots the machine, and finally validates the snapshot by
booting a fresh instance from it.

Compared to :mod:`morph_remote_snapshot`, this workflow:
* Boots an instance instead of creating a snapshot up-front.
* Executes installation steps concurrently using an in-memory dependency graph.
* Uses the Morph async APIs (``aupload``/``aexec``/``aexpose_http_service``).
* Avoids ``docker build`` entirely while still ensuring Docker tooling exists.
"""

from __future__ import annotations

import argparse
import asyncio
import os
import shlex
import shutil
import subprocess
import tarfile
import tempfile
import textwrap
import uuid
from dataclasses import dataclass
from pathlib import Path
from typing import Awaitable, Dict, Iterable, List, Optional

import dotenv
from morphcloud.api import Instance, MorphCloudClient

from morph_common import ensure_docker, ensure_docker_cli_plugins


@dataclass(frozen=True)
class RemoteTask:
    """Representation of a remote command with dependencies."""

    name: str
    command: str
    deps: tuple[str, ...] = ()
    description: Optional[str] = None


class ProvisioningError(RuntimeError):
    """Raised when a remote command exits with a non-zero status."""


def _print_header(message: str) -> None:
    print("\n" + "=" * 80)
    print(message)
    print("=" * 80)


async def _instance_aexec(instance: Instance, command: str, *, label: str) -> None:
    """Execute a bash command on the instance using the async exec API."""

    wrapped = [
        "bash",
        "-lc",
        textwrap.dedent(
            f"""
            set -Eeuo pipefail
            {command}
            """
        ).strip(),
    ]
    print(f"[{label}] $ {' '.join(shlex.quote(part) for part in wrapped)}")
    response = await instance.aexec(wrapped)
    if response.stdout:
        print(f"[{label}] stdout:\n{response.stdout}")
    if response.stderr:
        print(f"[{label}] stderr:\n{response.stderr}")
    if response.exit_code != 0:
        raise ProvisioningError(
            f"Remote command '{label}' failed with exit code {response.exit_code}"
        )


async def _execute_task_graph(instance: Instance, tasks: Iterable[RemoteTask]) -> None:
    """Execute remote tasks while respecting their dependency graph."""

    task_map: Dict[str, RemoteTask] = {task.name: task for task in tasks}
    execution_cache: Dict[str, Awaitable[None]] = {}

    async def run(name: str) -> None:
        if name not in task_map:
            raise KeyError(f"Unknown task '{name}' referenced as dependency")
        if name in execution_cache:
            await execution_cache[name]
            return

        async def _runner() -> None:
            task = task_map[name]
            for dep in task.deps:
                await run(dep)
            await _instance_aexec(
                instance,
                task.command,
                label=task.description or task.name,
            )

        execution_cache[name] = asyncio.create_task(_runner())
        await execution_cache[name]

    await asyncio.gather(*(run(task.name) for task in tasks))


def _list_repo_files(repo_root: Path) -> List[Path]:
    """Return repository files while respecting gitignore rules when possible."""

    git = shutil.which("git")
    if git:
        try:
            result = subprocess.run(
                [git, "-C", str(repo_root), "rev-parse", "--is-inside-work-tree"],
                capture_output=True,
                text=True,
                check=True,
            )
            inside = result.stdout.strip() == "true"
        except subprocess.CalledProcessError:
            inside = False
        if inside:
            files_result = subprocess.run(
                [
                    git,
                    "-C",
                    str(repo_root),
                    "ls-files",
                    "--cached",
                    "--others",
                    "--exclude-standard",
                    "-z",
                ],
                capture_output=True,
                check=True,
            )
            entries = [
                Path(entry)
                for entry in files_result.stdout.decode().split("\0")
                if entry
            ]
            return entries

    files: List[Path] = []
    for path in repo_root.rglob("*"):
        if path.is_file() and ".git" not in path.parts:
            files.append(path.relative_to(repo_root))
    return files


def _create_repo_archive(repo_root: Path) -> Path:
    """Create a gzipped tarball of the repository."""

    files = _list_repo_files(repo_root)
    fd, archive_path = tempfile.mkstemp(prefix="cmux-repo-", suffix=".tar.gz")
    os.close(fd)
    archive = Path(archive_path)
    with tarfile.open(archive, "w:gz") as tar:
        for rel in files:
            tar.add(repo_root / rel, arcname=rel.as_posix())
    return archive


async def _upload_repository(instance: Instance, remote_path: str) -> Path:
    """Archive and upload the local repository to the remote instance."""

    repo_root = Path.cwd()
    archive = _create_repo_archive(repo_root)
    try:
        _print_header("Uploading repository archive")
        await instance.aupload(str(archive), remote_path, recursive=False)
    finally:
        archive.unlink(missing_ok=True)
    return Path(remote_path)


def _base_install_tasks() -> List[RemoteTask]:
    """Return the base system installation tasks."""

    base_packages = RemoteTask(
        name="apt-runtime",
        description="Install base runtime packages",
        command="""
        export DEBIAN_FRONTEND=noninteractive
        apt-get update
        apt-get install -y --no-install-recommends \
          ca-certificates curl wget git jq python3 make g++ build-essential \
          pkg-config libssl-dev unzip xz-utils gnupg lsb-release bash nano \
          net-tools lsof sudo iptables openssl pigz tmux htop ripgrep systemd \
          dbus util-linux xvfb x11vnc fluxbox websockify novnc xauth xdg-utils \
          socat fonts-liberation libasound2t64 libatk-bridge2.0-0 libatspi2.0-0 \
          libcups2 libdrm2 libgbm1 libgtk-3-0 libnspr4 libnss3 libpango-1.0-0 \
          libx11-xcb1 libxcomposite1 libxcursor1 libxdamage1 libxfixes3 libxi6 \
          libxkbcommon0 libxrandr2 libxrender1 libxshmfence1 libxss1
        apt-get clean
        rm -rf /var/lib/apt/lists/*
        """,
    )

    docker_engine = RemoteTask(
        name="docker",
        deps=("apt-runtime",),
        description="Install Docker engine",
        command=ensure_docker(),
    )

    docker_cli = RemoteTask(
        name="docker-cli",
        deps=("docker",),
        description="Install Docker CLI plugins",
        command=ensure_docker_cli_plugins(),
    )

    rust_install = RemoteTask(
        name="rust",
        deps=("apt-runtime",),
        description="Install Rust toolchain",
        command="""
        export RUSTUP_HOME=/usr/local/rustup
        export CARGO_HOME=/usr/local/cargo
        export PATH=/usr/local/cargo/bin:$PATH
        RUST_VERSION_RAW=${RUST_VERSION:-}
        if [ -z "${RUST_VERSION_RAW}" ]; then
          RUST_VERSION_RAW=$(curl -fsSL https://static.rust-lang.org/dist/channel-rust-stable.toml \
            | awk '/\\[pkg.rust\\]/{flag=1;next}/\\[pkg\\./{flag=0}flag && /^version =/ {gsub(/\"/,\"\",$3); split($3, parts, " "); print parts[1]; exit}')
        fi
        RUST_VERSION=$(printf '%s' "${RUST_VERSION_RAW}" | tr -d '[:space:]')
        curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | \
          sh -s -- -y --no-modify-path --profile minimal --default-toolchain "${RUST_VERSION}"
        echo 'export PATH=/usr/local/cargo/bin:$PATH' >/etc/profile.d/cmux-cargo.sh
        chmod +x /etc/profile.d/cmux-cargo.sh
        rustup component add rustfmt --toolchain "${RUST_VERSION}"
        rustup target add x86_64-unknown-linux-gnu --toolchain "${RUST_VERSION}"
        rustup default "${RUST_VERSION}"
        cargo --version
        """,
    )

    node_install = RemoteTask(
        name="node",
        deps=("apt-runtime",),
        description="Install Node.js 24",
        command="""
        NODE_VERSION=${NODE_VERSION:-24.9.0}
        arch=$(uname -m)
        case "$arch" in
          x86_64) node_arch=x64 ;;
          aarch64|arm64) node_arch=arm64 ;;
          *) echo "Unsupported architecture: $arch" >&2; exit 1 ;;
        esac
        tmp_dir=$(mktemp -d)
        trap 'rm -rf "$tmp_dir"' EXIT
        cd "$tmp_dir"
        curl -fsSLO "https://nodejs.org/dist/v${NODE_VERSION}/node-v${NODE_VERSION}-linux-${node_arch}.tar.xz"
        curl -fsSLO "https://nodejs.org/dist/v${NODE_VERSION}/SHASUMS256.txt"
        grep " node-v${NODE_VERSION}-linux-${node_arch}.tar.xz$" SHASUMS256.txt | sha256sum -c -
        tar -xJf "node-v${NODE_VERSION}-linux-${node_arch}.tar.xz" -C /usr/local --strip-components=1
        ln -sf /usr/local/bin/node /usr/bin/node
        ln -sf /usr/local/bin/npm /usr/bin/npm
        ln -sf /usr/local/bin/npx /usr/bin/npx
        ln -sf /usr/local/bin/corepack /usr/bin/corepack
        npm install -g node-gyp
        corepack enable
        corepack prepare pnpm@10.14.0 --activate
        """,
    )

    nvm_install = RemoteTask(
        name="nvm",
        deps=("node",),
        description="Install nvm",
        command="""
        export NVM_DIR=/root/.nvm
        mkdir -p "$NVM_DIR"
        curl -fsSL "https://raw.githubusercontent.com/nvm-sh/nvm/v0.39.7/install.sh" | bash
        """,
    )

    bun_install = RemoteTask(
        name="bun",
        deps=("node",),
        description="Install Bun",
        command="""
        curl -fsSL https://bun.sh/install | bash
        mv /root/.bun/bin/bun /usr/local/bin/
        ln -sf /usr/local/bin/bun /usr/local/bin/bunx
        bun --version
        bunx --version
        """,
    )

    openvscode_install = RemoteTask(
        name="openvscode",
        deps=("apt-runtime",),
        description="Install openvscode-server",
        command="""
        CODE_RELEASE=${CODE_RELEASE:-}
        if [ -z "$CODE_RELEASE" ]; then
          CODE_RELEASE=$(curl -s https://api.github.com/repos/gitpod-io/openvscode-server/releases/latest \
            | awk -F'"' '/tag_name/{print $4;exit}' | sed 's/^openvscode-server-v//')
        fi
        arch=$(dpkg --print-architecture)
        if [ "$arch" = "amd64" ]; then
          ARCH=x64
        elif [ "$arch" = "arm64" ]; then
          ARCH=arm64
        else
          echo "Unsupported architecture: $arch" >&2
          exit 1
        fi
        mkdir -p /app/openvscode-server
        url="https://github.com/gitpod-io/openvscode-server/releases/download/openvscode-server-v${CODE_RELEASE}/openvscode-server-v${CODE_RELEASE}-linux-${ARCH}.tar.gz"
        echo "Downloading $url"
        curl -fSL --retry 6 --retry-all-errors --retry-delay 2 -o /tmp/openvscode-server.tar.gz "$url"
        tar xf /tmp/openvscode-server.tar.gz -C /app/openvscode-server --strip-components=1
        rm -f /tmp/openvscode-server.tar.gz
        """,
    )

    uv_install = RemoteTask(
        name="uv",
        deps=("apt-runtime",),
        description="Install uv and Python runtime",
        command="""
        ARCH=$(uname -m)
        case "$ARCH" in
          x86_64) UV_ASSET_SUFFIX=x86_64-unknown-linux-gnu ;;
          aarch64|arm64) UV_ASSET_SUFFIX=aarch64-unknown-linux-gnu ;;
          *) echo "Unsupported architecture: $ARCH" >&2; exit 1 ;;
        esac
        UV_VERSION_RAW=${UV_VERSION:-}
        if [ -z "$UV_VERSION_RAW" ]; then
          UV_VERSION_RAW=$(curl -fsSL https://api.github.com/repos/astral-sh/uv/releases/latest | jq -r '.tag_name')
        fi
        UV_VERSION=$(printf '%s' "$UV_VERSION_RAW" | tr -d ' \t\r\n')
        curl -fsSL "https://github.com/astral-sh/uv/releases/download/${UV_VERSION}/uv-${UV_ASSET_SUFFIX}.tar.gz" -o /tmp/uv.tar.gz
        tar -xzf /tmp/uv.tar.gz -C /tmp
        install -m 0755 /tmp/uv-${UV_ASSET_SUFFIX}/uv /usr/local/bin/uv
        install -m 0755 /tmp/uv-${UV_ASSET_SUFFIX}/uvx /usr/local/bin/uvx
        rm -rf /tmp/uv.tar.gz /tmp/uv-${UV_ASSET_SUFFIX}
        uv python install --default
        python3 -m pip install --break-system-packages --upgrade pip
        """,
    )

    chrome_install = RemoteTask(
        name="chrome",
        deps=("apt-runtime",),
        description="Install Chromium/Chrome",
        command="""
        arch=$(dpkg --print-architecture)
        tmp_dir=$(mktemp -d)
        trap 'rm -rf "$tmp_dir"' EXIT
        if [ "$arch" = "amd64" ]; then
          cd "$tmp_dir"
          curl -fsSLo chrome.deb https://dl.google.com/linux/direct/google-chrome-stable_current_amd64.deb
          if ! apt-get install -y --no-install-recommends ./chrome.deb; then
            apt-get install -y --no-install-recommends -f
            apt-get install -y --no-install-recommends ./chrome.deb
          fi
          ln -sf /usr/bin/google-chrome-stable /usr/local/bin/google-chrome
          ln -sf /usr/bin/google-chrome-stable /usr/local/bin/chrome
        else
          cd "$tmp_dir"
          revision=$(curl -fsSL https://raw.githubusercontent.com/microsoft/playwright/main/packages/playwright-core/browsers.json | jq -r '.browsers[] | select(.name == "chromium") | .revision')
          curl -fsSLo chrome.zip "https://playwright.azureedge.net/builds/chromium/${revision}/chromium-linux-arm64.zip"
          unzip -q chrome.zip
          install_dir=/opt/chromium-linux-arm64
          rm -rf "$install_dir"
          mv chrome-linux "$install_dir"
          ln -sf "$install_dir/chrome" /usr/local/bin/google-chrome
          ln -sf "$install_dir/chrome" /usr/local/bin/chrome
        fi
        """,
    )

    return [
        base_packages,
        docker_engine,
        docker_cli,
        rust_install,
        node_install,
        nvm_install,
        bun_install,
        openvscode_install,
        uv_install,
        chrome_install,
    ]


def _repo_tasks(remote_repo_root: str) -> List[RemoteTask]:
    """Tasks that operate on the uploaded repository."""

    extract = RemoteTask(
        name="extract-repo",
        description="Extract repository archive",
        command=f"""
        rm -rf {shlex.quote(remote_repo_root)}
        mkdir -p {shlex.quote(remote_repo_root)}
        tar -xzf /tmp/cmux-repo.tar.gz -C {shlex.quote(remote_repo_root)}
        rm -f /tmp/cmux-repo.tar.gz
        """,
    )

    bun_install = RemoteTask(
        name="bun-install",
        deps=("extract-repo",),
        description="Install bun dependencies",
        command=f"""
        cd {shlex.quote(remote_repo_root)}
        bun install --frozen-lockfile
        """,
    )

    cargo_env = RemoteTask(
        name="cargo-env",
        deps=("extract-repo",),
        description="Build envd/envctl binaries",
        command=f"""
        export PATH=/usr/local/cargo/bin:$PATH
        cd {shlex.quote(remote_repo_root)}
        cargo install --path crates/cmux-env --locked --force
        """,
    )

    cargo_proxy = RemoteTask(
        name="cargo-proxy",
        deps=("extract-repo",),
        description="Build cmux-proxy binary",
        command=f"""
        export PATH=/usr/local/cargo/bin:$PATH
        cd {shlex.quote(remote_repo_root)}
        cargo install --path crates/cmux-proxy --locked --force
        """,
    )

    worker_build = RemoteTask(
        name="worker-build",
        deps=("bun-install",),
        description="Build worker bundle",
        command=f"""
        cd {shlex.quote(remote_repo_root)}
        bun build ./apps/worker/src/index.ts \
          --target node \
          --outdir ./apps/worker/build \
          --external @cmux/convex \
          --external node:*
        cp -r ./apps/worker/build /builtins/build
        cp ./apps/worker/wait-for-docker.sh /usr/local/bin/
        chmod +x /usr/local/bin/wait-for-docker.sh
        """,
    )

    return [extract, bun_install, cargo_env, cargo_proxy, worker_build]


def _desktop_tasks() -> List[RemoteTask]:
    """Tasks that prepare and start VS Code + VNC services."""

    prepare_dirs = RemoteTask(
        name="prepare-dirs",
        description="Create runtime directories",
        command="""
        mkdir -p /var/log/cmux
        mkdir -p /opt/app/workspace
        """,
    )

    start_services = RemoteTask(
        name="start-services",
        deps=("prepare-dirs",),
        description="Start VSCode, Xvfb, Fluxbox, and noVNC",
        command="""
        cat <<'EOF' >/usr/local/bin/cmux-start-desktop.sh
        #!/usr/bin/env bash
        set -Eeuo pipefail
        export DISPLAY=:1
        mkdir -p /var/log/cmux
        if ! pgrep -f '^Xvfb :1' >/dev/null 2>&1; then
          nohup Xvfb :1 -screen 0 1440x900x24 >/var/log/cmux/xvfb.log 2>&1 &
          sleep 2
        fi
        if ! pgrep -f fluxbox >/dev/null 2>&1; then
          nohup fluxbox >/var/log/cmux/fluxbox.log 2>&1 &
        fi
        if ! pgrep -f 'x11vnc.*:1' >/dev/null 2>&1; then
          nohup x11vnc -display :1 -forever -rfbport 5901 -shared -nopw >/var/log/cmux/x11vnc.log 2>&1 &
        fi
        if ! pgrep -f 'websockify.*39380' >/dev/null 2>&1; then
          nohup websockify --web=/usr/share/novnc/ 39380 localhost:5901 >/var/log/cmux/websockify.log 2>&1 &
        fi
        if ! pgrep -f 'openvscode-server.*39378' >/dev/null 2>&1; then
          nohup /app/openvscode-server/bin/openvscode-server \
            --host 0.0.0.0 \
            --port 39378 \
            --without-connection-token \
            --accept-server-license-terms \
            >/var/log/cmux/openvscode.log 2>&1 &
        fi
        EOF
        chmod +x /usr/local/bin/cmux-start-desktop.sh
        /usr/local/bin/cmux-start-desktop.sh
        """,
    )

    return [prepare_dirs, start_services]


async def _expose_standard_ports(instance: Instance) -> None:
    ports = [39376, 39377, 39378, 39379, 39380, 39381]
    await asyncio.gather(
        *(instance.aexpose_http_service(f"port-{port}", port) for port in ports)
    )


async def _sanity_checks(instance: Instance, label: str) -> None:
    _print_header(f"Running sanity checks on {label}")
    checks = [
        ("cargo", "cargo --version"),
        ("node", "node --version"),
        ("bun", "bun --version"),
        ("uv", "uv --version"),
        ("envd", "command -v envd && envd --help | head -n 1"),
        ("envctl", "command -v envctl && envctl --help | head -n 1"),
        ("curl-vscode", "curl -fsSLo /tmp/vscode-index.html http://127.0.0.1:39378/"),
        ("curl-vnc", "curl -fsSLo /tmp/vnc.html http://127.0.0.1:39380/vnc.html"),
    ]
    for name, command in checks:
        await _instance_aexec(instance, command, label=f"sanity-{label}-{name}")


async def provision(args: argparse.Namespace) -> None:
    dotenv.load_dotenv()
    client = MorphCloudClient()

    base_snapshot = args.snapshot_id
    metadata = {"app": "cmux-instance-provision", "mode": "async"}

    _print_header("Booting base instance")
    instance = await client.instances.aboot(
        snapshot_id=base_snapshot,
        vcpus=args.vcpus,
        memory=args.memory,
        disk_size=args.disk_size,
        metadata=metadata,
        ttl_seconds=args.ttl_seconds,
        ttl_action=args.ttl_action,
    )
    await instance.await_until_ready()

    cleanup_instances: List[Instance] = [instance]

    try:
        _print_header("Installing base packages")
        await _execute_task_graph(instance, _base_install_tasks())

        _print_header("Uploading repository")
        remote_archive = "/tmp/cmux-repo.tar.gz"
        await _upload_repository(instance, remote_archive)

        repo_root = "/opt/app/cmux"
        combined_tasks = _repo_tasks(repo_root) + _desktop_tasks()
        await _execute_task_graph(instance, combined_tasks)

        await _expose_standard_ports(instance)
        await _sanity_checks(instance, "primary")

        _print_header("Creating snapshot of configured instance")
        snapshot_name = f"cmux-instance-{uuid.uuid4().hex}"
        snapshot = await instance.asnapshot(metadata={"source": snapshot_name})

        _print_header("Booting validation instance from snapshot")
        new_instance = await client.instances.astart(
            snapshot_id=snapshot.id,
            metadata={"app": "cmux-instance-validation"},
            ttl_seconds=args.ttl_seconds,
            ttl_action=args.ttl_action,
        )
        await new_instance.await_until_ready()
        cleanup_instances.append(new_instance)
        await _expose_standard_ports(new_instance)
        await _sanity_checks(new_instance, "validation")

    finally:
        _print_header("Cleaning up instances")
        await asyncio.gather(*(inst.astop() for inst in cleanup_instances if inst))


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--snapshot-id",
        default=os.environ.get("CMUX_STOCK_SNAPSHOT", "stock_exact"),
        help="Base snapshot or stock identifier to boot",
    )
    parser.add_argument("--vcpus", type=int, default=10, help="Number of vCPUs")
    parser.add_argument("--memory", type=int, default=32768, help="Memory in MB")
    parser.add_argument(
        "--disk-size",
        type=int,
        default=131072,
        help="Disk size in MB (default 128GB)",
    )
    parser.add_argument(
        "--ttl-seconds",
        type=int,
        default=3600,
        help="Instance TTL in seconds",
    )
    parser.add_argument(
        "--ttl-action",
        default="pause",
        choices=["pause", "stop"],
        help="Action to take when TTL expires",
    )
    return parser


def main() -> None:
    parser = build_parser()
    args = parser.parse_args()
    asyncio.run(provision(args))


if __name__ == "__main__":
    main()
