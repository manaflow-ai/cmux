# /// script
# dependencies = [
#   "morphcloud",
#   "python-dotenv",
#   "requests",
# ]
# ///

#!/usr/bin/env python3
"""Provision a Morph instance by replaying the Dockerfile steps in parallel.

This script mirrors the runtime setup performed in the Dockerfile, but it runs the
commands directly on a live Morph instance to optimize for speed.  The install
steps are modelled as a dependency graph so independent work can happen in
parallel while preserving ordering constraints (for example, serialized apt
operations).  Once provisioning completes, the instance is snapshotted and a new
instance is started from that snapshot to double check the environment.
"""

from __future__ import annotations

import argparse
import asyncio
import json
import os
import shlex
import sys
from dataclasses import dataclass, field
from pathlib import Path
from typing import Awaitable, Callable, Dict, Optional, Sequence, Set
import textwrap

import requests

import dotenv
from morphcloud.api import Instance, MorphCloudClient

dotenv.load_dotenv()

ProvisionTask = Callable[[], Awaitable[None]]

DEFAULT_OPENVSCODE_RELEASE = "1.98.0"
OPENVSCODE_RELEASE_URL = "https://api.github.com/repos/gitpod-io/openvscode-server/releases/latest"


@dataclass(slots=True)
class GraphTask:
    name: str
    coro: ProvisionTask
    deps: Set[str] = field(default_factory=set)


class TaskGraphError(Exception):
    pass


async def run_task_graph(tasks: Sequence[GraphTask], *, concurrency: int = 4) -> None:
    """Run graph tasks respecting dependencies with bounded concurrency."""

    task_by_name: Dict[str, GraphTask] = {task.name: task for task in tasks}
    if len(task_by_name) != len(tasks):
        raise TaskGraphError("Duplicate task names detected")

    sem = asyncio.Semaphore(concurrency)
    futures: Dict[str, asyncio.Task[None]] = {}

    async def ensure_task(name: str) -> None:
        if name in futures:
            await futures[name]
            return

        graph_task = task_by_name.get(name)
        if graph_task is None:
            raise TaskGraphError(f"Unknown dependency '{name}'")

        async def runner() -> None:
            await asyncio.gather(*(ensure_task(dep) for dep in graph_task.deps))
            async with sem:
                await graph_task.coro()

        futures[name] = asyncio.create_task(runner(), name=name)
        await futures[name]

    await asyncio.gather(*(ensure_task(task.name) for task in tasks))


def log(message: str) -> None:
    print(message, flush=True)


def build_install_command(packages: Sequence[str]) -> str:
    pkg_list = " ".join(packages)
    return (
        "DEBIAN_FRONTEND=noninteractive apt-get update && "
        "DEBIAN_FRONTEND=noninteractive apt-get install -y "
        f"{pkg_list} && rm -rf /var/lib/apt/lists/*"
    )


async def run_command(
    instance: Instance,
    command: str,
    *,
    sudo: bool = True,
    check: bool = True,
    env: Optional[Dict[str, str]] = None,
    description: Optional[str] = None,
    use_shell: bool = True,
) -> None:
    desc = description or command
    log(f"→ {desc}")
    if use_shell:
        shell_command = f"bash -lc {json.dumps(command)}"
        full_command = f"sudo {shell_command}" if sudo else shell_command
    else:
        full_command = f"sudo {command}" if sudo else command
    kwargs: Dict[str, Dict[str, str]] = {}
    if env is not None:
        kwargs["env"] = env
    result = await instance.aexec(full_command, **kwargs)
    exit_code = getattr(result, "exit_code", 0)
    stdout = getattr(result, "stdout", "")
    stderr = getattr(result, "stderr", "")
    if stdout:
        sys.stdout.write(stdout)
        if not stdout.endswith("\n"):
            sys.stdout.write("\n")
    if stderr:
        sys.stderr.write(stderr)
        if not stderr.endswith("\n"):
            sys.stderr.write("\n")
    if check and exit_code:
        raise RuntimeError(f"Command failed ({desc}) exit={exit_code}")


async def upload_recursive(instance: Instance, local_path: Path, remote_path: str) -> None:
    log(f"→ Uploading {local_path} → {remote_path}")
    await instance.aupload(str(local_path), remote_path, recursive=True)


async def expose_ports(instance: Instance, ports: Sequence[int]) -> None:
    async def expose(port: int) -> None:
        name = f"port-{port}"
        log(f"→ Exposing {name}")
        await instance.aexpose_http_service(name=name, port=port)

    await asyncio.gather(*(expose(port) for port in ports))


async def ensure_docker_on_instance(instance: Instance) -> None:
    log("→ Installing Docker via ensure_docker")
    docker_install = (
        "DEBIAN_FRONTEND=noninteractive apt-get update && "
        "DEBIAN_FRONTEND=noninteractive apt-get install -y "
        "docker.io docker-compose python3-docker git curl && "
        "rm -rf /var/lib/apt/lists/*"
    )
    await run_command(
        instance,
        docker_install,
        description="Install Docker engine and dependencies",
    )
    docker_post_install = " && ".join(
        [
            "mkdir -p /etc/docker",
            "echo '{\"features\":{\"buildkit\":true}}' > /etc/docker/daemon.json",
            "echo 'DOCKER_BUILDKIT=1' >> /etc/environment",
            "systemctl restart docker",
            "for i in {1..30}; do if docker info >/dev/null 2>&1; then echo Docker ready; break; else echo Waiting for Docker...; [ $i -eq 30 ] && { echo 'Docker failed to start after 30 attempts'; exit 1; }; sleep 2; fi; done",
            "docker --version",
            "docker-compose --version",
            "docker compose version || echo 'docker compose plugin not available'",
            "echo 'Docker commands verified'",
        ]
    )
    await run_command(
        instance,
        docker_post_install,
        description="Configure Docker BuildKit and verify",
    )
    docker_plugins = " && ".join(
        [
            "mkdir -p /usr/local/lib/docker/cli-plugins",
            "arch=$(uname -m)",
            'if [ "$arch" != "x86_64" ]; then echo "Morph snapshot architecture mismatch: expected x86_64 but got $arch" >&2; exit 1; fi',
            "curl -fsSL https://github.com/docker/compose/releases/download/v2.32.2/docker-compose-linux-x86_64 -o /usr/local/lib/docker/cli-plugins/docker-compose",
            "chmod +x /usr/local/lib/docker/cli-plugins/docker-compose",
            "curl -fsSL https://github.com/docker/buildx/releases/download/v0.18.0/buildx-v0.18.0.linux-amd64 -o /usr/local/lib/docker/cli-plugins/docker-buildx",
            "chmod +x /usr/local/lib/docker/cli-plugins/docker-buildx",
            "docker compose version",
            "docker buildx version",
        ]
    )
    await run_command(
        instance,
        docker_plugins,
        description="Install Docker CLI plugins",
    )
    await run_command(
        instance,
        "echo '::1       localhost' >> /etc/hosts",
        description="Ensure IPv6 localhost entry",
    )


def resolve_openvscode_release() -> str:
    env_value = os.environ.get("OPENVSCODE_RELEASE")
    if env_value:
        return env_value

    try:
        response = requests.get(OPENVSCODE_RELEASE_URL, timeout=30)
        response.raise_for_status()
        payload = response.json()
        tag_name = payload.get("tag_name", "")
        if isinstance(tag_name, str) and tag_name:
            if tag_name.startswith("openvscode-server-v"):
                return tag_name[len("openvscode-server-v") :]
            return tag_name
    except Exception as exc:  # noqa: BLE001
        log(
            f"Warning: failed to resolve openvscode release ({exc}); "
            f"using default {DEFAULT_OPENVSCODE_RELEASE}"
        )
    return DEFAULT_OPENVSCODE_RELEASE


async def perform_sanity_checks(instance: Instance, *, label: str) -> None:
    log(f"→ Running sanity checks ({label})")
    checks = [
        "cargo --version",
        "node --version",
        "bun --version",
        "uv --version",
        "envd --version",
        "envctl --version",
        "curl -IsSf http://127.0.0.1:39378 | head -n 1",
        "curl -IsSf http://127.0.0.1:6080 | head -n 1",
    ]
    for command in checks:
        await run_command(instance, command, sudo=False, description=f"Sanity: {command}")


async def main() -> None:
    parser = argparse.ArgumentParser(description="Provision Morph instance with parallel steps")
    parser.add_argument(
        "--snapshot-id",
        required=True,
        help="Source snapshot to bootstrap the instance",
    )
    parser.add_argument(
        "--workspace",
        default=str(Path.cwd()),
        help="Local path to the cmux repository to upload",
    )
    parser.add_argument(
        "--remote-root",
        default="/root/workspace/cmux",
        help="Remote path for the repository upload",
    )
    parser.add_argument(
        "--concurrency",
        type=int,
        default=4,
        help="Maximum number of provisioning tasks to run concurrently",
    )
    args = parser.parse_args()

    workspace_path = Path(args.workspace).resolve()
    if not workspace_path.exists():
        parser.error(f"Workspace path not found: {workspace_path}")

    client = MorphCloudClient()

    log("Starting base instance")
    instance = client.instances.start(
        snapshot_id=args.snapshot_id,
        vcpus=10,
        memory=32768,
        disk_size=65536,
        ttl_seconds=3600,
        ttl_action="pause",
    )
    instance.wait_until_ready()
    log(f"Instance ready: {instance.id}")

    try:
        await expose_ports(instance, [39376, 39377, 39378, 5173, 6080, 9777, 9778])

        # Prepare directories required for uploads and runtime assets
        await run_command(
            instance,
            "mkdir -p /workspace /root/workspace /builtins",
            description="Create workspace directories",
        )

        remote_root_shell = shlex.quote(args.remote_root)
        remote_parent_shell = shlex.quote(str(Path(args.remote_root).parent))

        openvscode_release = resolve_openvscode_release()

        async def install_system_packages() -> None:
            await run_command(
                instance,
                build_install_command(
                    [
                        "ca-certificates",
                        "curl",
                        "wget",
                        "git",
                        "python3",
                        "bash",
                        "nano",
                        "net-tools",
                        "lsof",
                        "sudo",
                        "supervisor",
                        "iptables",
                        "openssl",
                        "pigz",
                        "xz-utils",
                        "tmux",
                        "htop",
                        "ripgrep",
                        "jq",
                        "make",
                        "g++",
                        "unzip",
                        "gnupg",
                    ]
                ),
                description="Install base system packages",
            )

        async def install_github_cli() -> None:
            cmd = textwrap.dedent(
                """\
                set -euo pipefail
                curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg | tee /usr/share/keyrings/githubcli-archive-keyring.gpg >/dev/null
                chmod go+r /usr/share/keyrings/githubcli-archive-keyring.gpg
                echo 'deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main' | tee /etc/apt/sources.list.d/github-cli.list >/dev/null
                apt-get update
                apt-get install -y gh
                rm -rf /var/lib/apt/lists/*
                """
            ).strip()
            await run_command(instance, cmd, description="Install GitHub CLI")

        async def install_node() -> None:
            cmd = textwrap.dedent(
                """\
                set -euo pipefail
                curl -fsSL https://deb.nodesource.com/setup_24.x | bash -
                apt-get install -y nodejs
                rm -rf /var/lib/apt/lists/*
                corepack enable
                corepack prepare pnpm@10.14.0 --activate
                """
            ).strip()
            await run_command(instance, cmd, description="Install Node.js 24.x and configure corepack")

        async def install_bun() -> None:
            cmd = textwrap.dedent(
                """\
                set -euo pipefail
                curl -fsSL https://bun.sh/install | bash
                mv /root/.bun/bin/bun /usr/local/bin/
                ln -sf /usr/local/bin/bun /usr/local/bin/bunx
                bun --version
                bunx --version
                """
            ).strip()
            await run_command(instance, cmd, description="Install Bun")

        async def install_openvscode() -> None:
            log(f"Using openvscode release {openvscode_release}")
            cmd = textwrap.dedent(
                f"""\
                set -euo pipefail
                arch=$(dpkg --print-architecture)
                case "$arch" in
                  amd64) code_arch=x64 ;;
                  arm64) code_arch=arm64 ;;
                  *) echo "Unsupported architecture: $arch" >&2; exit 1 ;;
                esac
                mkdir -p /app/openvscode-server
                url="https://github.com/gitpod-io/openvscode-server/releases/download/openvscode-server-v{openvscode_release}/openvscode-server-v{openvscode_release}-linux-${{code_arch}}.tar.gz"
                if ! curl -fSL --retry 6 --retry-all-errors --retry-delay 2 --connect-timeout 20 --max-time 600 -o /tmp/openvscode-server.tar.gz "$url"; then
                  curl -fSL4 --retry 6 --retry-all-errors --retry-delay 2 --connect-timeout 20 --max-time 600 -o /tmp/openvscode-server.tar.gz "$url"
                fi
                tar xf /tmp/openvscode-server.tar.gz -C /app/openvscode-server/ --strip-components=1
                rm -f /tmp/openvscode-server.tar.gz
                """
            ).strip()
            await run_command(instance, cmd, description="Install openvscode-server")

        async def upload_repo() -> None:
            await run_command(
                instance,
                f"rm -rf {remote_root_shell} && mkdir -p {remote_parent_shell}",
                description="Prepare remote workspace directory",
            )
            await upload_recursive(instance, workspace_path, args.remote_root)

        async def install_docker() -> None:
            await ensure_docker_on_instance(instance)

        async def install_uv() -> None:
            cmd = textwrap.dedent(
                """\
                set -euo pipefail
                curl -fsSL https://astral.sh/uv/install.sh | sh
                install -m 0755 /root/.local/bin/uv /usr/local/bin/uv
                uv --version
                """
            ).strip()
            await run_command(instance, cmd, description="Install uv CLI")

        async def install_bun_global_cli() -> None:
            cmd = textwrap.dedent(
                """\
                set -euo pipefail
                bun add -g @openai/codex@0.42.0 @anthropic-ai/claude-code@2.0.0 @google/gemini-cli@0.1.21 opencode-ai@0.6.4 codebuff @devcontainers/cli @sourcegraph/amp
                """
            ).strip()
            await run_command(instance, cmd, description="Install global CLI tools via Bun")

        async def install_cursor_cli() -> None:
            cmd = textwrap.dedent(
                """\
                set -euo pipefail
                curl https://cursor.com/install -fsS | bash
                /root/.local/bin/cursor-agent --version
                """
            ).strip()
            await run_command(instance, cmd, description="Install Cursor CLI")

        async def switch_iptables() -> None:
            await run_command(
                instance,
                "update-alternatives --set iptables /usr/sbin/iptables-legacy",
                description="Switch iptables to legacy backend",
            )

        async def install_envctl() -> None:
            cmd = textwrap.dedent(
                """\
                set -euo pipefail
                CMUX_ENV_VERSION=0.0.8
                arch=$(uname -m)
                case "$arch" in
                  x86_64) arch_name="x86_64" ;;
                  aarch64|arm64) arch_name="aarch64" ;;
                  *) echo "Unsupported architecture: $arch" >&2; exit 1 ;;
                esac
                tmpdir=$(mktemp -d)
                curl -fsSL "https://github.com/lawrencecchen/cmux-env/releases/download/v${CMUX_ENV_VERSION}/cmux-env-${CMUX_ENV_VERSION}-${arch_name}-unknown-linux-musl.tar.gz" | tar -xz -C "$tmpdir"
                install -m 0755 "$tmpdir/cmux-env-${CMUX_ENV_VERSION}-${arch_name}-unknown-linux-musl/envctl" /usr/local/bin/envctl
                install -m 0755 "$tmpdir/cmux-env-${CMUX_ENV_VERSION}-${arch_name}-unknown-linux-musl/envd" /usr/local/bin/envd
                rm -rf "$tmpdir"
                envctl --version
                envctl install-hook bash
                printf '%s\n' '[ -f ~/.bashrc ] && . ~/.bashrc' > /root/.profile
                printf '%s\n' '[ -f ~/.bashrc ] && . ~/.bashrc' > /root/.bash_profile
                mkdir -p /run/user/0
                chmod 700 /run/user/0
                printf '%s\n' 'export XDG_RUNTIME_DIR=/run/user/0' >> /root/.bashrc
                """
            ).strip()
            await run_command(instance, cmd, description="Install envctl/envd")

        async def setup_repo_assets() -> None:
            install_deps_cmd = textwrap.dedent(
                f"""\
                set -euo pipefail
                cd {remote_root_shell}
                bun install --frozen-lockfile
                """
            ).strip()
            await run_command(instance, install_deps_cmd, description="Install workspace dependencies with Bun")

            worker_build_cmd = textwrap.dedent(
                f"""\
                set -euo pipefail
                cd {remote_root_shell}
                bun build ./apps/worker/src/index.ts \\
                    --target node \\
                    --outdir ./apps/worker/build \\
                    --external '@cmux/convex' \\
                    --external 'node:*'
                """
            ).strip()
            await run_command(instance, worker_build_cmd, description="Build worker bundle")

            await run_command(
                instance,
                "rm -rf /builtins/build && mkdir -p /builtins",
                description="Prepare builtins directory",
            )

            await run_command(
                instance,
                f"cp -r {remote_root_shell}/apps/worker/build /builtins/build",
                description="Copy worker build into builtins",
            )

            scripts_install_cmd = textwrap.dedent(
                f"""\
                set -euo pipefail
                install -m 0755 {remote_root_shell}/apps/worker/scripts/collect-relevant-diff.sh /usr/local/bin/cmux-collect-relevant-diff.sh
                install -m 0755 {remote_root_shell}/apps/worker/scripts/collect-crown-diff.sh /usr/local/bin/cmux-collect-crown-diff.sh
                install -m 0755 {remote_root_shell}/apps/worker/wait-for-docker.sh /usr/local/bin/wait-for-docker.sh
                """
            ).strip()
            await run_command(instance, scripts_install_cmd, description="Install worker helper scripts")

            extension_build_cmd = textwrap.dedent(
                f"""\
                set -euo pipefail
                cd {remote_root_shell}/packages/vscode-extension
                bun run package
                """
            ).strip()
            await run_command(instance, extension_build_cmd, description="Build VS Code extension")

            extension_install_cmd = textwrap.dedent(
                f"""\
                set -euo pipefail
                cd {remote_root_shell}
                latest_vsix=$(ls -t packages/vscode-extension/*.vsix | head -n 1)
                cp "$latest_vsix" /tmp/cmux-vscode-extension.vsix
                /app/openvscode-server/bin/openvscode-server --install-extension /tmp/cmux-vscode-extension.vsix
                rm /tmp/cmux-vscode-extension.vsix
                """
            ).strip()
            await run_command(instance, extension_install_cmd, description="Install VS Code extension")

        async def install_tmux_config() -> None:
            cmd = textwrap.dedent(
                f"""\
                set -euo pipefail
                install -m 0644 {remote_root_shell}/configs/tmux.conf /etc/tmux.conf
                """
            ).strip()
            await run_command(instance, cmd, description="Install tmux configuration")

        async def configure_openvscode_settings() -> None:
            cmd = textwrap.dedent(
                """\
                set -euo pipefail
                mkdir -p /root/.openvscode-server/data/User
                mkdir -p /root/.openvscode-server/data/User/profiles/default-profile
                mkdir -p /root/.openvscode-server/data/Machine
                settings_json='{"workbench.startupEditor": "none", "terminal.integrated.macOptionClickForcesSelection": true, "terminal.integrated.shell.linux": "bash", "terminal.integrated.shellArgs.linux": ["-l"]}'
                printf '%s\n' "$settings_json" > /root/.openvscode-server/data/User/settings.json
                cp /root/.openvscode-server/data/User/settings.json /root/.openvscode-server/data/User/profiles/default-profile/settings.json
                cp /root/.openvscode-server/data/User/settings.json /root/.openvscode-server/data/Machine/settings.json
                """
            ).strip()
            await run_command(instance, cmd, description="Configure openvscode-server settings")

        system_packages = GraphTask("system-packages", install_system_packages)
        github_cli = GraphTask("github-cli", install_github_cli, deps={"system-packages"})
        node_install = GraphTask("node", install_node, deps={"github-cli"})
        docker_task = GraphTask("docker", install_docker, deps={"node"})
        bun_task = GraphTask("bun", install_bun, deps={"system-packages"})
        uv_task = GraphTask("uv", install_uv, deps={"system-packages"})
        openvscode_task = GraphTask("openvscode", install_openvscode, deps={"system-packages"})
        upload_task = GraphTask("upload", upload_repo)
        bun_global_cli = GraphTask("bun-global-cli", install_bun_global_cli, deps={"bun"})
        cursor_task = GraphTask("cursor", install_cursor_cli, deps={"system-packages"})
        iptables_task = GraphTask("iptables", switch_iptables, deps={"docker"})
        envctl_task = GraphTask("envctl", install_envctl, deps={"upload", "system-packages"})
        repo_setup_task = GraphTask(
            "repo-setup",
            setup_repo_assets,
            deps={"upload", "bun", "node", "openvscode"},
        )
        tmux_task = GraphTask("tmux-config", install_tmux_config, deps={"upload"})
        vscode_settings = GraphTask("vscode-settings", configure_openvscode_settings, deps={"openvscode"})

        await run_task_graph(
            [
                system_packages,
                github_cli,
                node_install,
                docker_task,
                bun_task,
                uv_task,
                openvscode_task,
                upload_task,
                bun_global_cli,
                cursor_task,
                iptables_task,
                envctl_task,
                repo_setup_task,
                tmux_task,
                vscode_settings,
            ],
            concurrency=args.concurrency,
        )

        await perform_sanity_checks(instance, label="primary instance")

        log("Creating snapshot of provisioned instance")
        snapshot = instance.snapshot()
        log(f"Snapshot created: {snapshot.id}")

        log("Starting validation instance from snapshot")
        verify_instance = client.instances.start(
            snapshot_id=snapshot.id,
            vcpus=10,
            memory=32768,
            disk_size=65536,
            ttl_seconds=3600,
            ttl_action="pause",
        )
        try:
            verify_instance.wait_until_ready()
            await expose_ports(
                verify_instance, [39376, 39377, 39378, 5173, 6080, 9777, 9778]
            )
            await perform_sanity_checks(verify_instance, label="validation instance")
            log("Validation instance checks passed")
        finally:
            try:
                log("Stopping validation instance")
                verify_instance.stop()
            except Exception as err:  # noqa: BLE001
                log(f"Failed to stop validation instance cleanly: {err}")
    finally:
        try:
            log("Stopping primary instance")
            instance.stop()
        except Exception as err:  # noqa: BLE001
            log(f"Failed to stop primary instance cleanly: {err}")


if __name__ == "__main__":
    asyncio.run(main())
