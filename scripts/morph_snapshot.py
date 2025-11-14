#!/usr/bin/env python3
"""
This script parses a Dockerfile and applies its instructions to a Morph
snapshot using the MorphCloud Python API.
"""

from __future__ import annotations

import argparse
import atexit
import hashlib
import os
import shlex
import signal
import sys
import time
import typing as t
from dataclasses import dataclass
from urllib import request as urllib_request
from urllib.error import HTTPError, URLError

import dotenv
from morphcloud.api import MorphCloudClient, Snapshot

dotenv.load_dotenv()

client = MorphCloudClient()

# Morph snapshots run on x86_64 hardware; Docker plugins must match this arch
MORPH_EXPECTED_UNAME_ARCH = "x86_64"
DOCKER_COMPOSE_VERSION = "v2.32.2"
DOCKER_BUILDX_VERSION = "v0.18.0"

# Track live instance for cleanup on exit
current_instance: t.Optional[object] = None


def _cleanup_instance() -> None:
    global current_instance
    inst = current_instance
    if not inst:
        return
    try:
        print(f"Stopping instance {getattr(inst, 'id', '<unknown>')}...")
        inst.stop()
        print("Instance stopped")
    except Exception as e:
        print(f"Failed to stop instance: {e}")
    finally:
        current_instance = None


def _signal_handler(signum, _frame) -> None:
    print(f"Received signal {signum}; cleaning up...")
    _cleanup_instance()
    # Exit immediately after cleanup
    try:
        sys.exit(1)
    except SystemExit:
        raise


# Ensure cleanup happens on normal exit and on signals
atexit.register(_cleanup_instance)
signal.signal(signal.SIGINT, _signal_handler)
signal.signal(signal.SIGTERM, _signal_handler)


@dataclass
class Instruction:
    """Represents a Dockerfile instruction."""

    type: str
    content: str


class DockerfileParser:
    """Very small Dockerfile parser supporting a subset of instructions."""

    def __init__(self, text: str) -> None:
        self.lines = text.splitlines()
        self.index = 0

    def parse(self) -> t.List[Instruction]:
        instructions: t.List[Instruction] = []
        while self.index < len(self.lines):
            line = self.lines[self.index].strip()
            if not line or line.startswith("#"):
                self.index += 1
                continue

            inst = self._parse_instruction(line)
            if inst:
                instructions.append(inst)
        return instructions

    def _parse_instruction(self, line: str) -> Instruction | None:
        # Handle heredoc like: RUN <<EOF ... EOF
        heredoc_match = line.startswith("RUN <<") or line.startswith("COPY <<")
        if heredoc_match:
            return self._parse_heredoc(line)

        if " " not in line:
            self.index += 1
            return None
        inst_type, rest = line.split(" ", 1)
        self.index += 1

        # handle line continuations with \
        while rest.endswith("\\") and self.index < len(self.lines):
            rest = rest[:-1].rstrip() + " " + self.lines[self.index].strip()
            self.index += 1
        return Instruction(inst_type, rest.strip())

    def _parse_heredoc(self, line: str) -> Instruction:
        inst_type, delimiter = line.split("<<", 1)
        inst_type = inst_type.strip()
        delimiter = delimiter.strip().strip("-'")
        self.index += 1
        body: t.List[str] = []
        while self.index < len(self.lines):
            cur = self.lines[self.index]
            if cur.strip() == delimiter:
                self.index += 1
                break
            body.append(cur)
            self.index += 1
        return Instruction(inst_type, "\n".join(body))


class MorphDockerfileExecutor:
    """Apply parsed Dockerfile instructions to a Morph snapshot."""

    def __init__(self, snapshot: Snapshot) -> None:
        self.snapshot = snapshot
        self.workdir = "/root"
        # Docker command configuration
        self.cmd: str | None = None
        self.entrypoint: str | None = None
        # Parsed argv representations (to support arbitrary entrypoints safely)
        self.cmd_argv: list[str] | None = None
        self.entrypoint_argv: list[str] | None = None
        # Whether the original form was shell-form (affects how CMD combines)
        self.cmd_shell: bool = False
        self.entrypoint_shell: bool = False
        # Default run user
        self.user: str = "root"
        # Track build-time (ARG) and run-time (ENV) variables
        self.build_env: dict[str, str] = {}
        self.run_env: dict[str, str] = {}

    def _exec_with_retry(self, command: str, *, attempts: int = 4) -> None:
        """Run a command on the snapshot with simple retry/backoff.

        This helps ride over transient SSH issues like Paramiko 'Channel closed'.
        """
        last_err: Exception | None = None
        for i in range(attempts):
            try:
                self.snapshot = self.snapshot.exec(command)
                return
            except Exception as e:
                last_err = e
                # small linear backoff; try to poke the instance to refresh connection
                time.sleep(1.0 + i * 0.5)
                try:
                    # No-op effect to keep the chain alive if needed
                    _ = self.snapshot
                except Exception:
                    pass
        if last_err is not None:
            raise last_err

    def _upload_with_retry(
        self, local_path: str, remote_path: str, *, recursive: bool, attempts: int = 4
    ) -> None:
        import time

        last_err: Exception | None = None
        for i in range(attempts):
            try:
                self.snapshot = self.snapshot.upload(
                    local_path, remote_path, recursive=recursive
                )
                return
            except Exception as e:  # Transient SSH/SFTP errors
                last_err = e
                # small backoff and try to touch the instance to refresh connection
                time.sleep(1.0 + i * 0.5)
                try:
                    self.snapshot = self.snapshot.exec("true")
                except Exception:
                    # ignore and continue retrying
                    pass
        if last_err is not None:
            raise last_err

    def execute(self, instructions: t.Iterable[Instruction]) -> Snapshot:
        for inst in instructions:
            handler = getattr(self, f"handle_{inst.type.lower()}", None)
            if handler:
                handler(inst.content)
        # After applying instructions, synthesize a boot-time service that
        # replicates Docker's ENTRYPOINT/CMD semantics for the Morph VM.
        # We do NOT run the command now; we configure it to run on boot.
        self._configure_boot_service()
        # Do not run final CMD/ENTRYPOINT during snapshot build
        return self.snapshot

    def handle_run(self, content: str) -> None:
        # Strip BuildKit RUN flags at the beginning, e.g., --mount=..., --network=...
        # Do this without shlex splitting to preserve original quoting of the rest of the command.
        s = content.lstrip()
        while s.startswith("--"):
            # Remove the first whitespace-delimited token
            # token ends at next whitespace (no spaces inside supported flags)
            j = 0
            while j < len(s) and not s[j].isspace():
                j += 1
            s = s[j:].lstrip()
        cleaned_cmd = s

        # Export current ARG/ENV into shell for this command
        exports: list[str] = []
        merged_env = {**self.build_env, **self.run_env}
        for k, v in merged_env.items():
            if v == "":
                exports.append(f"export {k}='';")
            else:
                if "$" in v:
                    # Allow variable expansion; escape embedded quotes
                    v_escaped = v.replace('"', '\\"')
                    exports.append(f'export {k}="{v_escaped}";')
                else:
                    exports.append(f"export {k}={shlex.quote(v)};")
        export_prefix = " ".join(exports)
        command = (
            f"{export_prefix} cd {self.workdir} && {cleaned_cmd}"
            if export_prefix
            else f"cd {self.workdir} && {cleaned_cmd}"
        )
        self._exec_with_retry(command)

    def handle_workdir(self, content: str) -> None:
        path = content.strip()
        # Docker semantics: relative WORKDIR appends to current
        if not os.path.isabs(path):
            path = os.path.join(self.workdir, path)
        self.workdir = path
        self._exec_with_retry(f"mkdir -p {self.workdir}")

    def handle_copy(self, content: str) -> None:
        import glob

        tokens = shlex.split(content)
        if not tokens:
            return

        # Parse COPY flags we care about; ignore unsupported ones gracefully.
        parents = False
        from_stage: str | None = None
        filtered: list[str] = []
        for tok in tokens:
            if tok == "--parents":
                parents = True
                continue
            # Skip other docker COPY flags if present
            if tok.startswith("--from="):
                from_stage = tok.split("=", 1)[1]
                continue
            if (
                tok.startswith("--chown=")
                or tok.startswith("--chmod=")
                or tok == "--link"
            ):
                # We don't currently implement these semantics in snapshot uploads
                continue
            filtered.append(tok)

        if len(filtered) < 2:
            return

        dest = filtered[-1]
        sources = filtered[:-1]

        # Compute absolute destination base within snapshot (respect WORKDIR for relative paths)
        def resolve_dest_base(path: str) -> str:
            if path in (".", "./"):
                return self.workdir
            if os.path.isabs(path):
                return path
            return os.path.join(self.workdir, path)

        dest_base = resolve_dest_base(dest)

        # Determine if destination should be treated as a directory
        dest_is_dir = dest.endswith("/") or dest in (".", "./") or len(sources) > 1

        # Build the list of sources to process
        expanded_sources: list[str] = []
        if from_stage is not None:
            # Treat sources as in-snapshot absolute or relative paths; do not glob on local FS
            expanded_sources = sources
        else:
            # Expand globs against local workspace
            for src in sources:
                matches = glob.glob(src, recursive=True)
                if matches:
                    expanded_sources.extend(matches)
                else:
                    # Keep literal if it exists; otherwise skip to avoid accidental '--flag' uploads
                    if os.path.exists(src):
                        expanded_sources.append(src)

        for src in expanded_sources:
            recursive = os.path.isdir(src)
            # If copying from another stage, perform an in-instance copy.
            if from_stage is not None:
                if parents:
                    rel_src = src.lstrip("./")
                    remote = os.path.join(dest_base, rel_src)
                else:
                    remote = (
                        os.path.join(dest_base, os.path.basename(src))
                        if dest_is_dir
                        else dest_base
                    )
                parent_dir = os.path.dirname(remote)
                if parent_dir:
                    self._exec_with_retry(f"mkdir -p {shlex.quote(parent_dir)}")
                # Skip if source and destination resolve to the same path
                if os.path.normpath(src) != os.path.normpath(remote):
                    # Use cp -a if supported; fallback to cp -r
                    self.snapshot = self.snapshot.exec(
                        "sh -lc 'cp -a "
                        + shlex.quote(src)
                        + " "
                        + shlex.quote(remote)
                        + " 2>/dev/null || cp -r "
                        + shlex.quote(src)
                        + " "
                        + shlex.quote(remote)
                        + "'"
                    )
            else:
                # Compute remote path for upload
                if parents:
                    # Preserve the source path under the destination base
                    rel_src = src.lstrip("./")
                    remote = os.path.join(dest_base, rel_src)
                else:
                    if dest_is_dir:
                        remote = os.path.join(dest_base, os.path.basename(src))
                    else:
                        remote = dest_base

                # Ensure target directory exists when needed
                parent_dir = (
                    os.path.dirname(remote)
                    if parents or dest_is_dir
                    else os.path.dirname(remote)
                )
                if parent_dir:
                    self._exec_with_retry(f"mkdir -p {shlex.quote(parent_dir)}")

                self._upload_with_retry(src, remote, recursive=recursive)
                # Preserve executable bit for uploaded files (non-recursive)
                try:
                    if not recursive:
                        st_mode = os.stat(src).st_mode
                        if (st_mode & 0o111) != 0:
                            # Make remote executable if local was executable
                            self._exec_with_retry(f"chmod +x {shlex.quote(remote)}")
                except FileNotFoundError:
                    # If the local file disappeared between glob and stat, skip
                    pass

    def handle_add(self, content: str) -> None:
        self.handle_copy(content)

    def handle_env(self, content: str) -> None:
        # Persist environment variables and apply to subsequent RUN steps
        parts = shlex.split(content)
        i = 0
        pairs: list[tuple[str, str]] = []
        while i < len(parts):
            if "=" in parts[i]:
                k, v = parts[i].split("=", 1)
                pairs.append((k, v))
                i += 1
            elif i + 1 < len(parts):
                k, v = parts[i], parts[i + 1]
                pairs.append((k, v))
                i += 2
            else:
                break
        for k, v in pairs:
            self.run_env[k] = v
            # Try to persist into /etc/environment for later sessions
            line = f"{k}={v}"
            self.snapshot = self.snapshot.exec(
                f"sh -lc 'printf %s\\n {shlex.quote(line)} >> /etc/environment'"
            )

    def handle_arg(self, content: str) -> None:
        # Support ARG name[=default] ... (multiple allowed on one line)
        parts = [p for p in shlex.split(content) if p]
        for part in parts:
            if "=" in part:
                k, v = part.split("=", 1)
                # Allow environment to override default (supports .env via dotenv)
                env_val = os.environ.get(k)
                self.build_env[k] = env_val if env_val is not None else v
            else:
                # No default -> read from environment if present, else empty string
                if part not in self.build_env:
                    self.build_env[part] = os.environ.get(part, "")

    def handle_cmd(self, content: str) -> None:
        self.cmd = self._parse_command(content)
        argv, is_shell = self._parse_command_argv(content)
        self.cmd_argv = argv
        self.cmd_shell = is_shell

    def handle_entrypoint(self, content: str) -> None:
        self.entrypoint = self._parse_command(content)
        argv, is_shell = self._parse_command_argv(content)
        self.entrypoint_argv = argv
        self.entrypoint_shell = is_shell

    def handle_user(self, content: str) -> None:
        # Accept forms: "user", "uid", or "user:group"; we only set the user part.
        val = content.strip()
        if ":" in val:
            user_part = val.split(":", 1)[0].strip()
        else:
            user_part = val
        if user_part:
            self.user = user_part

    def _run_final_command(self) -> None:
        if self.entrypoint and self.cmd:
            command = f"{self.entrypoint} {self.cmd}"
        elif self.entrypoint:
            command = self.entrypoint
        elif self.cmd:
            command = self.cmd
        else:
            return
        self.snapshot = self.snapshot.exec(f"cd {self.workdir} && {command}")

    @staticmethod
    def _parse_command(content: str) -> str:
        if content.startswith("["):
            try:
                import json

                arr = json.loads(content)
                return " ".join(arr)
            except Exception:
                pass
        return content.strip()

    def _parse_command_argv(self, content: str) -> tuple[list[str], bool]:
        """Parse a Docker command into argv list and indicate shell-form.

        - Exec form (JSON array) -> returns list, is_shell=False
        - Shell form (string) -> returns ["bash", "-lc", content], is_shell=True
        """
        s = content.strip()
        if s.startswith("["):
            try:
                import json

                arr = json.loads(s)
                # Ensure string elements
                argv = [str(x) for x in arr]
                return argv, False
            except Exception:
                # Fall back to shell form if JSON parsing fails
                pass
        return ["bash", "-lc", s], True

    def _compose_final_argv(self) -> list[str] | None:
        """Compose argv honoring Docker semantics:
        - ENTRYPOINT exec-form + CMD -> concat arrays
        - ENTRYPOINT shell-form -> ignore CMD
        - no ENTRYPOINT -> use CMD
        """
        if self.entrypoint_argv is not None:
            if not self.entrypoint_shell and self.cmd_argv is not None:
                return self.entrypoint_argv + self.cmd_argv
            return self.entrypoint_argv
        if self.cmd_argv is not None:
            return self.cmd_argv
        return None

    def _configure_boot_service(self) -> None:
        """Create a systemd unit so the final command runs on instance boot.

        - Writes a small wrapper at /usr/local/bin/cmux-entrypoint.sh that
          cd's into the WORKDIR and execs the composed command.
        - If the entrypoint is /startup.sh, copy it to a non-ephemeral path
          (/usr/local/bin/cmux-startup.sh) to avoid self-deletion inside the
          original script.
        - Installs and enables a systemd service that launches the wrapper.
        """
        final_argv = self._compose_final_argv()
        if not final_argv:
            return

        # If the entrypoint points at /startup.sh, copy it to a stable path and use that
        # This avoids issues with self-deletion inside the script and missing exec bit
        if final_argv and final_argv[0] == "/startup.sh":
            # Ensure the script exists and is executable at a stable path
            stable_path = "/usr/local/bin/cmux-startup.sh"
            self.snapshot = self.snapshot.exec(
                "sh -lc 'if [ -f /startup.sh ]; then cp /startup.sh "
                + shlex.quote(stable_path)
                + "; chmod +x "
                + shlex.quote(stable_path)
                + "; fi'"
            )
            final_argv[0] = stable_path

        # Create wrapper script to avoid fragile quoting in systemd unit
        wrapper_path = "/usr/local/bin/cmux-entrypoint.sh"
        # Build bash array with proper quoting
        argv_items = " ".join(shlex.quote(x) for x in final_argv)
        wrapper = (
            "#!/usr/bin/env bash\n"
            "set -euo pipefail\n"
            f"cd {shlex.quote(self.workdir)}\n"
            f"cmd=( {argv_items} )\n"
            'exec "${cmd[@]}"\n'
        )
        # Write wrapper content robustly via base64 to avoid shell expansion issues
        import base64

        wrapper_b64 = base64.b64encode(wrapper.encode("utf-8")).decode("ascii")
        self.snapshot = self.snapshot.exec(
            "sh -lc 'dir=$(dirname "
            + shlex.quote(wrapper_path)
            + '); mkdir -p "$dir"; printf %s '
            + shlex.quote(wrapper_b64)
            + " | base64 -d > "
            + shlex.quote(wrapper_path)
            + "'"
        )
        self.snapshot = self.snapshot.exec(f"chmod +x {shlex.quote(wrapper_path)}")

        unit_path = "/etc/systemd/system/cmux.service"
        unit_text = """
[Unit]
Description=Cmux Entrypoint Autostart
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
EnvironmentFile=-/etc/environment
ExecStart=/usr/local/bin/cmux-entrypoint.sh
ExecStartPre=/bin/mkdir -p /var/log/cmux
StandardOutput=append:/var/log/cmux/cmux.service.log
StandardError=append:/var/log/cmux/cmux.service.log
Restart=no
User={USER}

[Install]
WantedBy=multi-user.target
""".strip()

        unit_payload = unit_text.replace("{USER}", self.user)
        unit_b64 = base64.b64encode(unit_payload.encode("utf-8")).decode("ascii")
        self.snapshot = self.snapshot.exec(
            "sh -lc 'printf %s "
            + shlex.quote(unit_b64)
            + " | base64 -d > "
            + shlex.quote(unit_path)
            + "'"
        )
        # Ensure the service user exists if not root
        if self.user != "root":
            self.snapshot = self.snapshot.exec(
                "sh -lc 'id -u "
                + shlex.quote(self.user)
                + " >/dev/null 2>&1 || useradd -m "
                + shlex.quote(self.user)
                + "'"
            )

        # Ensure log directory exists (startup.sh writes here) and enable on boot
        self.snapshot = self.snapshot.exec("mkdir -p /var/log/cmux")
        # Enable on boot (do not start during build)
        self.snapshot = self.snapshot.exec(
            "systemctl daemon-reload && systemctl enable cmux.service"
        )


def ensure_docker_cli_plugins(snapshot: Snapshot) -> Snapshot:
    """Install docker compose/buildx CLI plugins and verify versions."""

    docker_plugin_cmds = [
        "mkdir -p /usr/local/lib/docker/cli-plugins",
        "arch=$(uname -m)",
        f'[ "$arch" = "{MORPH_EXPECTED_UNAME_ARCH}" ] || (echo "Morph snapshot architecture mismatch: expected {MORPH_EXPECTED_UNAME_ARCH} but got $arch" >&2; exit 1)',
        f"curl -fsSL https://github.com/docker/compose/releases/download/{DOCKER_COMPOSE_VERSION}/docker-compose-linux-{MORPH_EXPECTED_UNAME_ARCH} "
        f"-o /usr/local/lib/docker/cli-plugins/docker-compose",
        "chmod +x /usr/local/lib/docker/cli-plugins/docker-compose",
        f"curl -fsSL https://github.com/docker/buildx/releases/download/{DOCKER_BUILDX_VERSION}/buildx-{DOCKER_BUILDX_VERSION}.linux-amd64 "
        f"-o /usr/local/lib/docker/cli-plugins/docker-buildx",
        "chmod +x /usr/local/lib/docker/cli-plugins/docker-buildx",
        "docker compose version",
        "docker buildx version",
    ]
    return snapshot.exec(" && ".join(docker_plugin_cmds))


def ensure_docker(snapshot: Snapshot) -> Snapshot:
    """Install Docker, docker compose, and enable BuildKit."""
    snapshot = snapshot.setup(
        "DEBIAN_FRONTEND=noninteractive apt-get update && "
        "DEBIAN_FRONTEND=noninteractive apt-get install -y "
        "docker.io docker-compose python3-docker git curl && "
        "rm -rf /var/lib/apt/lists/*"
    )
    snapshot = snapshot.exec(
        "mkdir -p /etc/docker && "
        'echo \'{"features":{"buildkit":true}}\' > /etc/docker/daemon.json && '
        "echo 'DOCKER_BUILDKIT=1' >> /etc/environment && "
        "systemctl restart docker && "
        "for i in {1..30}; do "
        "  if docker info >/dev/null 2>&1; then "
        "    echo 'Docker ready'; break; "
        "  else "
        "    echo 'Waiting for Docker...'; "
        "    [ $i -eq 30 ] && { echo 'Docker failed to start after 30 attempts'; exit 1; }; "
        "    sleep 2; "
        "  fi; "
        "done && "
        "docker --version && docker-compose --version && "
        "(docker compose version 2>/dev/null || echo 'docker compose plugin not available') && "
        "echo 'Docker commands verified'"
    )
    snapshot = ensure_docker_cli_plugins(snapshot)
    # Ensure IPv6 localhost resolution
    snapshot = snapshot.exec("echo '::1       localhost' >> /etc/hosts")
    return snapshot


def _file_sha256_hex(path: str) -> str:
    try:
        with open(path, "rb") as f:
            h = hashlib.sha256()
            for chunk in iter(lambda: f.read(8192), b""):
                h.update(chunk)
            return h.hexdigest()
    except FileNotFoundError:
        return "no-file"


def build_snapshot(
    dockerfile_path: str,
) -> Snapshot:
    # snapshot = client.snapshots.get(base_snapshot)
    vcpus = 8
    memory = 16384
    disk_size = 32768
    snapshot = client.snapshots.create(
        vcpus=vcpus,
        memory=memory,
        disk_size=disk_size,
        digest=None,
    )
    snapshot = ensure_docker(snapshot)
    with open(dockerfile_path, "r", encoding="utf-8") as f:
        parser = DockerfileParser(f.read())
    executor = MorphDockerfileExecutor(snapshot)
    final_snapshot = executor.execute(parser.parse())
    # Ensure Morph-provisioned Docker CLI plugins are in place after Dockerfile commands.
    final_snapshot = ensure_docker_cli_plugins(final_snapshot)
    return final_snapshot


def main() -> None:
    ap = argparse.ArgumentParser(description="Build Morph snapshot from Dockerfile")
    ap.add_argument("dockerfile", nargs="?", default="Dockerfile")
    ap.add_argument(
        "--resnapshot",
        action="store_true",
        help="After starting the instance, wait for Enter and snapshot again",
    )
    args = ap.parse_args()

    try:
        snapshot = build_snapshot(args.dockerfile)
        print(f"Snapshot ID: {snapshot.id}")

        # then we want to start an instance from the snapshot
        instance = client.instances.start(
            snapshot_id=snapshot.id,
            ttl_seconds=3600,
            ttl_action="pause",
        )
        # track for cleanup
        global current_instance
        current_instance = instance

        print(f"Instance ID: {instance.id}")
        # expose the ports
        expose_ports = [39375, 39376, 39377, 39378, 39379, 39380, 39381]
        for port in expose_ports:
            instance.expose_http_service(port=port, name=f"port-{port}")
        instance.wait_until_ready()
        print(instance.networking.http_services)
        # print the instance's public IP

        # Quick diagnostics before checking the VS Code port
        try:
            print("\n--- Instance diagnostics ---")
            # Ensure the service is started on first boot; some environments don't auto-start enabled units
            start_res = instance.exec("systemctl start cmux.service || true")
            if getattr(start_res, "stdout", None):
                print(start_res.stdout)
            if getattr(start_res, "stderr", None):
                sys.stderr.write(str(start_res.stderr))

            diag_cmds = [
                "systemctl is-enabled cmux.service || true",
                "systemctl is-active cmux.service || true",
                "systemctl status cmux.service --no-pager -l | tail -n 80 || true",
                "ps aux | rg -n 'openvscode-server|node /builtins/build/index.js' -N || true",
                "ss -lntp | rg -n ':39378' -N || true",
                "ss -lntp | rg -n ':39379' -N || true",
                "ss -lntp | rg -n ':39380' -N || true",
                "ss -lntp | rg -n ':39381' -N || true",
                "tail -n 80 /var/log/cmux/cmux.service.log || true",
                "tail -n 80 /var/log/cmux/server.log || true",
                "tail -n 80 /var/log/cmux/websockify.log || true",
                "tail -n 80 /var/log/cmux/tigervnc.log || true",
            ]
            for cmd in diag_cmds:
                print(f"\n$ {cmd}")
                res = instance.exec(cmd)
                if getattr(res, "stdout", None):
                    print(res.stdout)
                if getattr(res, "stderr", None):
                    sys.stderr.write(str(res.stderr))
        except Exception as e:
            print(f"Diagnostics failed: {e}")

        # check if port 39378 returns a 200
        url: t.Optional[str] = None
        try:
            services = getattr(instance.networking, "http_services", [])

            def _get(obj: object, key: str) -> t.Any:
                if isinstance(obj, dict):
                    return obj.get(key)
                return getattr(obj, key, None)

            vscode_service = None
            proxy_service = None
            vnc_service = None
            cdp_service = None
            for svc in services or []:
                port = _get(svc, "port")
                name = _get(svc, "name")
                if port == 39378 or name == "port-39378":
                    vscode_service = svc
                elif port == 39379 or name == "port-39379":
                    proxy_service = svc
                elif port == 39380 or name == "port-39380":
                    vnc_service = svc
                elif port == 39381 or name == "port-39381":
                    cdp_service = svc

            url = _get(vscode_service, "url") if vscode_service is not None else None
            if not url:
                print("No exposed HTTP service found for port 39378")
            else:
                ok = False
                # retry for up to ~60s
                for _ in range(30):
                    try:
                        with urllib_request.urlopen(url, timeout=5) as resp:
                            code = getattr(resp, "status", getattr(resp, "code", None))
                            if code == 200:
                                print(f"Port 39378 check: HTTP {code}")
                                ok = True
                                break
                            else:
                                print(
                                    f"Port 39378 not ready yet, HTTP {code}; retrying..."
                                )
                    except (HTTPError, URLError) as e:
                        print(f"Port 39378 not ready yet ({e}); retrying...")
                    time.sleep(2)
                if not ok:
                    print("Port 39378 did not return HTTP 200 within timeout")

            proxy_url = _get(proxy_service, "url") if proxy_service is not None else None
            if proxy_url:
                print(f"Proxy URL: {proxy_url}")
            else:
                print("No exposed HTTP service found for port 39379")

            vnc_url = _get(vnc_service, "url") if vnc_service is not None else None
            if vnc_url:
                novnc_url = f"{vnc_url.rstrip('/')}/vnc.html"
                ok = False
                for _ in range(30):
                    try:
                        with urllib_request.urlopen(novnc_url, timeout=5) as resp:
                            code = getattr(resp, "status", getattr(resp, "code", None))
                            if code == 200:
                                print(f"Port 39380 check: HTTP {code}")
                                ok = True
                                break
                            print(f"Port 39380 not ready yet, HTTP {code}; retrying...")
                    except (HTTPError, URLError) as e:
                        print(f"Port 39380 not ready yet ({e}); retrying...")
                    time.sleep(2)
                if not ok:
                    print("Port 39380 did not return HTTP 200 within timeout")
                print(f"VNC URL: {novnc_url}")
            else:
                print("No exposed HTTP service found for port 39380")

            cdp_url = _get(cdp_service, "url") if cdp_service is not None else None
            if cdp_url:
                print(f"DevTools endpoint: {cdp_url}/json/version")
            else:
                print("No exposed DevTools service found for port 39381")
        except Exception as e:
            print(f"Error checking exposed services: {e}")

        # print the vscode url
        if url:
            print(f"VSCode URL: {url}/?folder=/root/workspace")
        else:
            print("VSCode URL unavailable")

        if args.resnapshot:
            # next, wait for any keypress and then snapshot again
            input("Press Enter to snapshot again...")
            print("Snapshotting...")
            final_snapshot = instance.snapshot()
            print(f"Snapshot ID: {final_snapshot.id}")
    finally:
        _cleanup_instance()


if __name__ == "__main__":
    main()
