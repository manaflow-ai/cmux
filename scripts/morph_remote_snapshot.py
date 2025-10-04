#!/usr/bin/env python3
"""
Build a Morph snapshot by uploading the repository, building the Docker image
remotely, and extracting the resulting rootfs inside the snapshot.

The script:
1. Archives the repository (respecting .gitignore via git ls-files)
2. Creates a Morph snapshot and uploads the archive
3. Installs Docker tooling inside the snapshot
4. Extracts the archive and builds the Docker image remotely
5. Flattens the image into /opt/app/rootfs
6. Prepares overlay workspace directories for runtime mounting
7. Writes runtime environment configuration
8. Installs and enables the cmux systemd units that ship with the image
"""

from __future__ import annotations

import argparse
import atexit
import json
import os
import shlex
import shutil
import signal
import socket
import subprocess
import sys
import tarfile
import tempfile
import textwrap
import time
import typing as t
from contextlib import contextmanager
from pathlib import Path
from urllib import request as urllib_request
from urllib.error import HTTPError, URLError

import dotenv
from morphcloud.api import Instance, MorphCloudClient, Snapshot
from morph_common import ensure_docker, ensure_docker_cli_plugins, write_remote_file

dotenv.load_dotenv()

client = MorphCloudClient()

current_instance: Instance | None = None


T = t.TypeVar("T")


class Console:
    def __init__(self) -> None:
        self.quiet = False

    def info(self, *args: t.Any, **kwargs: t.Any) -> None:
        if not self.quiet:
            print(*args, **kwargs)

    def always(self, *args: t.Any, **kwargs: t.Any) -> None:
        print(*args, **kwargs)

    def info_stderr(self, value: str) -> None:
        if not self.quiet:
            sys.stderr.write(value)


console = Console()


class TimingsCollector:
    def __init__(self) -> None:
        self._sections: list[tuple[str, float]] = []

    @contextmanager
    def section(self, label: str) -> t.Iterator[None]:
        start = time.perf_counter()
        try:
            yield
        finally:
            duration = time.perf_counter() - start
            self._sections.append((label, duration))

    def time(self, label: str, func: t.Callable[[], T]) -> T:
        with self.section(label):
            return func()

    def summary_lines(self) -> list[str]:
        if not self._sections:
            return []

        lines = [f"{label}: {duration:.2f}s" for label, duration in self._sections]

        lines.append("")
        lines.append("Aggregates:")

        totals: dict[str, float] = {}
        for label, duration in self._sections:
            prefix = label.split(":", 1)[0]
            totals[prefix] = totals.get(prefix, 0.0) + duration

        for prefix, duration in totals.items():
            lines.append(f"{prefix}: {duration:.2f}s")

        total_duration = sum(duration for _, duration in self._sections)
        lines.append(f"total: {total_duration:.2f}s")

        return lines


def print_timing_summary(timings: TimingsCollector) -> None:
    lines = timings.summary_lines()
    if not lines:
        return

    console.info("\n--- Timing Summary ---")
    for line in lines:
        console.info(line)


def send_macos_notification(title: str, message: str) -> None:
    """Send a user notification on macOS without failing the build."""
    if sys.platform != "darwin":
        return

    if shutil.which("osascript") is None:
        return

    script = f"display notification {json.dumps(message)} with title {json.dumps(title)}"
    try:
        subprocess.run(["osascript", "-e", script], check=False)
    except Exception as exc:  # noqa: BLE001
        console.info(f"Failed to send macOS notification: {exc}")


def _cleanup_instance() -> None:
    global current_instance
    inst = current_instance
    if not inst:
        return
    try:
        console.info(f"Stopping instance {getattr(inst, 'id', '<unknown>')}...")
        inst.stop()
        console.info("Instance stopped")
    except Exception as e:  # noqa: BLE001
        console.always(f"Failed to stop instance: {e}")
    finally:
        current_instance = None


def _signal_handler(signum, _frame) -> None:  # type: ignore[no-untyped-def]
    console.info(f"Received signal {signum}; cleaning up...")
    _cleanup_instance()
    try:
        sys.exit(1)
    except SystemExit:
        raise


atexit.register(_cleanup_instance)
signal.signal(signal.SIGINT, _signal_handler)
signal.signal(signal.SIGTERM, _signal_handler)


class DockerImageConfig(t.TypedDict):
    entrypoint: list[str]
    cmd: list[str]
    env: list[str]
    workdir: str
    user: str


def run_snapshot_bash(snapshot: Snapshot, script: str) -> Snapshot:
    """Execute a bash script on the snapshot."""
    return snapshot.exec(f"bash -lc {shlex.quote(script)}")


def list_repo_files(repo_root: Path) -> list[Path]:
    """Return repository files respecting gitignore rules via git ls-files."""
    result = subprocess.run(
        ["git", "-C", str(repo_root), "rev-parse", "--is-inside-work-tree"],
        capture_output=True,
        text=True,
        check=False,
    )
    if result.returncode != 0 or result.stdout.strip() != "true":
        raise RuntimeError(f"{repo_root} is not inside a git work tree")

    files_result = subprocess.run(
        [
            "git",
            "-C",
            str(repo_root),
            "ls-files",
            "--cached",
            "--others",
            "--exclude-standard",
            "-z",
        ],
        capture_output=True,
        text=True,
        check=True,
    )
    entries = [entry for entry in files_result.stdout.split("\0") if entry]
    return [Path(entry) for entry in entries]


def create_repo_archive(repo_root: Path) -> str:
    """Create a gzipped tarball of the repository respecting gitignore."""
    files = list_repo_files(repo_root)
    fd, archive_path = tempfile.mkstemp(suffix=".tar.gz", prefix="cmux-repo-")
    os.close(fd)

    with tarfile.open(archive_path, "w:gz") as tar:
        for rel_path in files:
            full_path = repo_root / rel_path
            tar.add(full_path, arcname=rel_path.as_posix())

    return archive_path


def parse_image_config(data: list[t.Any]) -> DockerImageConfig:
    """Extract runtime configuration from docker image inspect output."""
    if not data:
        raise ValueError("docker image inspect returned no data")
    config = data[0]["Config"]
    return {
        "entrypoint": config.get("Entrypoint") or [],
        "cmd": config.get("Cmd") or [],
        "env": config.get("Env") or [],
        "workdir": config.get("WorkingDir") or "/",
        "user": config.get("User") or "root",
    }


def ensure_remote_tooling(snapshot: Snapshot) -> Snapshot:
    """Install base utilities and Docker tooling on the snapshot."""
    console.info("Ensuring Docker tooling...")
    docker_command = " && ".join([ensure_docker(), ensure_docker_cli_plugins()])

    console.info("Installing base utilities and preparing directories...")
    return snapshot.exec(
        f"""
        DEBIAN_FRONTEND=noninteractive apt-get update &&
        DEBIAN_FRONTEND=noninteractive apt-get install -y curl procps util-linux coreutils tar &&
        rm -rf /var/lib/apt/lists/* &&
        mkdir -p /opt/app/rootfs /opt/app/workdir &&
        {docker_command}
        """
    )


def enable_cmux_units(snapshot: Snapshot) -> Snapshot:
    """Copy and enable cmux systemd units that ship inside the rootfs."""
    console.info("Enabling cmux systemd units...")

    units = [
        "cmux.target",
        "cmux-openvscode.service",
        "cmux-worker.service",
        "cmux-dockerd.service",
    ]
    quoted_units = " ".join(shlex.quote(unit) for unit in units)

    script = textwrap.dedent(
        f"""
        set -euo pipefail
        for unit in {quoted_units}; do
            src="/opt/app/rootfs/usr/lib/systemd/system/$unit"
            dest="/etc/systemd/system/$unit"
            if [ -f "$src" ]; then
                cp "$src" "$dest"
            fi
        done

        mkdir -p /usr/local/lib/cmux
        if [ -d /opt/app/rootfs/usr/local/lib/cmux ]; then
            cp -a /opt/app/rootfs/usr/local/lib/cmux/. /usr/local/lib/cmux/
        fi

        for tool in cmux-rootfs-exec configure-openvscode; do
            path="/usr/local/lib/cmux/$tool"
            if [ -f "$path" ]; then
                chmod +x "$path"
            fi
        done

        mkdir -p /var/log/cmux
        systemctl daemon-reload
        systemctl enable cmux.target
        """
    ).strip()

    return run_snapshot_bash(snapshot, script)


def run_sanity_checks(snapshot: Snapshot, timings: TimingsCollector) -> Snapshot:
    """Run a battery of chroot sanity checks to verify runtime tooling."""

    console.info("Running chroot sanity checks (forkpty, docker, envctl, dev server)...")

    script = textwrap.dedent(
        """
        set -euo pipefail

        if [ ! -f /opt/app/app.env ]; then
            echo "cmux sanity: missing /opt/app/app.env" >&2
            exit 1
        fi

        set -a
        # shellcheck disable=SC1091
        . /opt/app/app.env
        set +a

        run_chroot() {
            CMUX_ROOTFS="$CMUX_ROOTFS" \
            CMUX_RUNTIME_ROOT="$CMUX_RUNTIME_ROOT" \
            CMUX_OVERLAY_UPPER="${CMUX_OVERLAY_UPPER:-}" \
            CMUX_OVERLAY_WORK="${CMUX_OVERLAY_WORK:-}" \
            /usr/local/lib/cmux/cmux-rootfs-exec "$@"
        }

        log_dir=/tmp/cmux-sanity
        rm -rf "$log_dir"
        mkdir -p "$log_dir"
        export CMUX_DEBUG=1

        forkpty_check() {
            local log="$log_dir/forkpty.log"
            if run_chroot /bin/bash >"$log" 2>&1 <<'BASH'
set -euo pipefail
if command -v script >/dev/null 2>&1; then
    if script -qfec "echo forkpty-ok" /dev/null >/dev/null; then
        exit 0
    fi
fi

if ! command -v python3 >/dev/null 2>&1; then
    echo "python3 not available for forkpty fallback" >&2
    exit 1
fi

python3 - <<'PY'
import os
import pty
import sys

pid, fd = pty.fork()
if pid == 0:
    os.execlp("sh", "sh", "-c", "echo forkpty-python")

data = os.read(fd, 1024)
if b"forkpty-python" not in data:
    raise SystemExit("forkpty output missing")
PY
BASH
            then
                echo "[sanity] forkpty ok"
            else
                echo "[sanity] forkpty failed" >&2
                cat "$log" >&2 || true
                return 1
            fi
        }

        docker_check() {
            local log="$log_dir/docker.log"
            if run_chroot /bin/bash >"$log" 2>&1 <<'BASH'
set -euo pipefail
docker run --pull=missing --rm hello-world >/dev/null
docker image rm hello-world >/dev/null 2>&1 || true
BASH
            then
                echo "[sanity] docker run ok"
            else
                echo "[sanity] docker run failed" >&2
                cat "$log" >&2 || true
                return 1
            fi
        }

        envctl_check() {
            local log="$log_dir/envctl.log"
            if run_chroot /bin/bash >"$log" 2>&1 <<'BASH'
set -euo pipefail
var_name=MY_ENV_VAR_SANITY
var_value=envctl-ok

envctl set "${var_name}=${var_value}"
actual=$(envctl get "${var_name}" || true)
if [[ "${actual}" != "${var_value}" ]]; then
    echo "expected ${var_value}, got '${actual}'" >&2
    exit 1
fi

envctl unset "${var_name}"
if envctl get "${var_name}" | grep -q .; then
    echo "envctl value persisted after unset" >&2
    exit 1
fi
BASH
            then
                echo "[sanity] envctl propagation ok"
            else
                echo "[sanity] envctl propagation failed" >&2
                cat "$log" >&2 || true
                return 1
            fi
        }


        dev_server_check() {
            local log="$log_dir/dev.log"
            if run_chroot /bin/bash >"$log" 2>&1 <<'BASH'
set -euo pipefail
if [ ! -d /root/workspace ]; then
    echo "/root/workspace missing" >&2
    exit 1
fi

cd /root/workspace
export SKIP_DOCKER_BUILD=true
export SKIP_CONVEX=true

tmp_log=$(mktemp)
cleanup() {
    if [ -n "${pid:-}" ] && kill -0 "$pid" 2>/dev/null; then
        kill "$pid" 2>/dev/null || true
        wait "$pid" 2>/dev/null || true
    fi
    rm -f "$tmp_log"
}
trap cleanup EXIT

if command -v stdbuf >/dev/null 2>&1; then
    stdbuf -oL -eL ./scripts/dev.sh --skip-convex true >"$tmp_log" 2>&1 &
else
    ./scripts/dev.sh --skip-convex true >"$tmp_log" 2>&1 &
fi
pid=$!

ready_regex='Starting Terminal App Development Environment'
for _ in $(seq 1 60); do
    if grep -q "$ready_regex" "$tmp_log"; then
        exit 0
    fi
    if ! kill -0 "$pid" 2>/dev/null; then
        cat "$tmp_log" >&2 || true
        exit 1
    fi
    sleep 2
done

cat "$tmp_log" >&2 || true
echo "dev server did not reach ready message" >&2
exit 1
BASH
            then
                echo "[sanity] dev server bootstrap ok"
            else
                echo "[sanity] dev server bootstrap failed" >&2
                cat "$log" >&2 || true
                return 1
            fi
        }

        forkpty_check
        docker_check
        envctl_check
        dev_server_check

        rm -rf "$log_dir"
        echo "[sanity] all checks passed"
        """
    ).strip()

    return timings.time(
        "build_snapshot:sanity_checks",
        lambda: run_snapshot_bash(snapshot, script),
    )

def build_snapshot(
    dockerfile_path: str | None,
    image_name: str | None,
    platform: str,
    target: str | None,
    timings: TimingsCollector,
) -> Snapshot:
    """Build a Morph snapshot by performing the Docker build remotely."""

    repo_root = Path.cwd()
    archive_path: str | None = None
    remote_archive_path = "/opt/app/repo.tar.gz"
    remote_repo_root = "/opt/app/workdir/repo"
    build_log_remote = "/opt/app/docker-build.log"
    built_image: str

    try:
        console.info("Creating Morph snapshot...")
        snapshot = timings.time(
            "build_snapshot:create_snapshot",
            lambda: client.snapshots.create(
                vcpus=10,
                memory=32768,
                disk_size=32768,
                digest="cmux:base-docker",
            ),
        )

        snapshot = timings.time(
            "build_snapshot:ensure_tooling",
            lambda: ensure_remote_tooling(snapshot),
        )

        if image_name:
            console.info(
                f"Pulling Docker image on snapshot: {image_name} (platform: {platform})"
            )
            snapshot = timings.time(
                "build_snapshot:remote_pull_image",
                lambda: snapshot.exec(
                    f"docker pull --platform {shlex.quote(platform)} {shlex.quote(image_name)}"
                ),
            )
            built_image = image_name
        else:
            dockerfile_local = dockerfile_path or "Dockerfile"
            dockerfile_abs = (repo_root / dockerfile_local).resolve()
            try:
                dockerfile_rel = dockerfile_abs.relative_to(repo_root.resolve())
            except ValueError as exc:  # noqa: TRY003
                raise ValueError(
                    f"Dockerfile {dockerfile_abs} is outside the repository root"
                ) from exc

            if not dockerfile_abs.exists():
                raise FileNotFoundError(f"Dockerfile not found: {dockerfile_abs}")

            console.info("Packaging repository for remote build...")
            archive_path = timings.time(
                "build_snapshot:create_repo_archive",
                lambda: create_repo_archive(repo_root),
            )

            console.info("Uploading repository archive...")
            snapshot = timings.time(
                "build_snapshot:upload_repo_archive",
                lambda: snapshot.upload(
                    archive_path,
                    remote_archive_path,
                    recursive=False,
                ),
            )

            console.info("Extracting repository archive on snapshot...")
            snapshot = timings.time(
                "build_snapshot:extract_repo_archive",
                lambda: run_snapshot_bash(
                    snapshot,
                    textwrap.dedent(
                        f"""
                        set -euo pipefail
                        mkdir -p {shlex.quote(remote_repo_root)}
                        tar -xzf {shlex.quote(remote_archive_path)} -C {shlex.quote(remote_repo_root)}
                        rm {shlex.quote(remote_archive_path)}
                        """
                    ).strip(),
                ),
            )

            context_rel = dockerfile_rel.parent
            context_rel_posix = context_rel.as_posix()
            remote_context_dir = (
                remote_repo_root
                if context_rel_posix == "."
                else f"{remote_repo_root}/{context_rel_posix}"
            )
            remote_dockerfile_path = (
                f"{remote_repo_root}/{dockerfile_rel.as_posix()}"
            )

            build_tag = f"cmux-morph-temp:{os.getpid()}"
            build_parts = [
                "docker buildx build",
                "--progress=plain",
                f"--platform {shlex.quote(platform)}",
                f"-t {shlex.quote(build_tag)}",
                f"-f {shlex.quote(remote_dockerfile_path)}",
                "--load",
                ".",
            ]
            if target:
                build_parts.insert(4, f"--target {shlex.quote(target)}")
            build_command = " ".join(build_parts)

            build_script = textwrap.dedent(
                f"""
                set -euo pipefail
                logfile={shlex.quote(build_log_remote)}
                rm -f "$logfile"
                cd {shlex.quote(remote_context_dir)}
                {build_command} |& tee "$logfile"
                """
            ).strip()

            console.info("Building Docker image on snapshot...")
            try:
                snapshot = timings.time(
                    "build_snapshot:remote_build_image",
                    lambda: run_snapshot_bash(snapshot, build_script),
                )
            except RuntimeError as build_err:
                console.always(
                    f"Remote docker build failed; attempting to download log from {build_log_remote}"
                )
                local_fd, local_log_path = tempfile.mkstemp(
                    prefix="cmux-docker-build-",
                    suffix=".log",
                )
                os.close(local_fd)
                try:
                    snapshot = snapshot.download(
                        build_log_remote,
                        local_log_path,
                        recursive=False,
                    )
                    console.always(
                        f"Remote docker build log saved to {local_log_path}"
                    )
                    try:
                        log_tail = Path(local_log_path).read_text().splitlines()[-200:]
                        if log_tail:
                            console.always("--- docker build log tail ---")
                            console.always("\n".join(log_tail))
                    except Exception as read_err:  # noqa: BLE001
                        console.always(
                            f"Failed to read docker build log tail: {read_err}"
                        )
                except Exception as log_err:  # noqa: BLE001
                    console.always(
                        f"Failed to download docker build log: {log_err}"
                    )
                raise

            built_image = build_tag

        inspect_remote_path = "/opt/app/docker-image-config.json"
        console.info("Recording Docker image configuration...")
        snapshot = timings.time(
            "build_snapshot:inspect_image",
            lambda: snapshot.exec(
                f"docker image inspect {shlex.quote(built_image)} > {shlex.quote(inspect_remote_path)}"
            ),
        )

        with tempfile.NamedTemporaryFile(delete=False) as tmp_file:
            local_inspect_path = tmp_file.name

        snapshot = timings.time(
            "build_snapshot:download_image_config",
            lambda: snapshot.download(
                inspect_remote_path,
                local_inspect_path,
                recursive=False,
            ),
        )
        inspect_data = json.loads(Path(local_inspect_path).read_text())
        os.unlink(local_inspect_path)
        snapshot = snapshot.exec(f"rm {shlex.quote(inspect_remote_path)}")

        config = parse_image_config(inspect_data)
        console.info(
            f"Image config: entrypoint={config['entrypoint']}, cmd={config['cmd']}, "
            f"workdir={config['workdir']}, user={config['user']}"
        )

        rootfs_tar_remote = "/opt/app/rootfs.tar"
        console.info("Exporting Docker image to rootfs tarball...")
        snapshot = timings.time(
            "build_snapshot:export_rootfs",
            lambda: run_snapshot_bash(
                snapshot,
                textwrap.dedent(
                    f"""
                    set -euo pipefail
                    cid=$(docker create --platform {shlex.quote(platform)} {shlex.quote(built_image)})
                    cleanup() {{
                        docker rm -f "$cid" >/dev/null 2>&1 || true
                    }}
                    trap cleanup EXIT
                    docker export "$cid" -o {shlex.quote(rootfs_tar_remote)}
                    cleanup
                    trap - EXIT
                    """
                ).strip(),
            ),
        )

        console.info("Extracting rootfs on snapshot...")
        snapshot = timings.time(
            "build_snapshot:extract_rootfs",
            lambda: snapshot.exec(
                "tar -xf {tar_path} -C /opt/app/rootfs && rm {tar_path}".format(
                    tar_path=shlex.quote(rootfs_tar_remote)
                )
            ),
        )

        console.info("Hydrating workspace with repository contents...")
        snapshot = timings.time(
            "build_snapshot:hydrate_workspace",
            lambda: run_snapshot_bash(
                snapshot,
                textwrap.dedent(
                    f"""
                    set -euo pipefail
                    workspace_dir=/opt/app/rootfs/root/workspace
                    mkdir -p "$workspace_dir"
                    tar -C {shlex.quote(remote_repo_root)} -cf - . | \
                        tar -C "$workspace_dir" -xf -
                    ls -A "$workspace_dir" | head -n 5
                    """
                ).strip(),
            ),
        )

        console.info("Cleaning up build workspace...")
        snapshot = snapshot.exec(f"rm -rf {shlex.quote(remote_repo_root)}")

        console.info("Removing temporary Docker image from snapshot...")
        snapshot = snapshot.exec(
            f"docker image rm {shlex.quote(built_image)} >/dev/null 2>&1 || true"
        )

        console.info("Preparing overlay directories...")
        snapshot = timings.time(
            "build_snapshot:prepare_overlay",
            lambda: snapshot.exec(
                "mkdir -p /opt/app/runtime /opt/app/overlay/upper /opt/app/overlay/work"
            ),
        )

        console.info("Writing environment file...")
        env_lines = list(config.get("env", []))
        env_lines.extend(
            [
                "CMUX_ROOTFS=/opt/app/rootfs",
                "CMUX_RUNTIME_ROOT=/opt/app/runtime",
                "CMUX_OVERLAY_UPPER=/opt/app/overlay/upper",
                "CMUX_OVERLAY_WORK=/opt/app/overlay/work",
            ]
        )
        env_content = "\n".join(env_lines) + "\n"
        snapshot = timings.time(
            "build_snapshot:write_env_file",
            lambda: write_remote_file(
                snapshot,
                remote_path="/opt/app/app.env",
                content=env_content,
            ),
        )

        snapshot = timings.time(
            "build_snapshot:enable_cmux_units",
            lambda: enable_cmux_units(snapshot),
        )

        snapshot = run_sanity_checks(snapshot, timings)

        return snapshot
    finally:
        if archive_path and os.path.exists(archive_path):
            os.unlink(archive_path)


def main() -> None:
    ap = argparse.ArgumentParser(
        description="Build Morph snapshot from Docker image (remote build approach)"
    )
    group = ap.add_mutually_exclusive_group()
    group.add_argument(
        "--dockerfile",
        help="Path to Dockerfile to build (default: Dockerfile)",
    )
    group.add_argument("--image", help="Docker image name to use")
    ap.add_argument(
        "--platform",
        default="linux/amd64",
        help="Docker platform to target (default: linux/amd64)",
    )
    ap.add_argument(
        "--target",
        default="morph",
        help="Docker build stage when using --dockerfile (default: morph)",
    )
    ap.add_argument(
        "--resnapshot",
        action="store_true",
        help="After starting the instance, wait for Enter and snapshot again",
    )
    ap.add_argument(
        "--exec",
        dest="exec_script",
        help="Bash script to run on the instance before optional resnapshot",
    )
    ap.add_argument(
        "--quiet",
        action="store_true",
        help="Reduce log output for non-interactive use",
    )
    args = ap.parse_args()

    console.quiet = args.quiet

    if args.dockerfile is None and args.image is None:
        args.dockerfile = "Dockerfile"

    timings = TimingsCollector()

    try:
        snapshot = build_snapshot(
            args.dockerfile,
            args.image,
            args.platform,
            args.target,
            timings=timings,
        )
        console.always(f"Snapshot ID: {snapshot.id}")

        console.info("Starting instance...")
        instance = timings.time(
            "main:start_instance",
            lambda: client.instances.start(
                snapshot_id=snapshot.id,
                ttl_seconds=3600,
                ttl_action="pause",
            ),
        )
        global current_instance
        current_instance = instance

        console.always(f"Instance ID: {instance.id}")

        expose_ports = [39376, 39377, 39378, 39379]
        with timings.section("main:expose_http_services"):
            for port in expose_ports:
                instance.expose_http_service(port=port, name=f"port-{port}")

        timings.time("main:wait_until_ready", instance.wait_until_ready)
        console.info(instance.networking.http_services)

        # Ensure cmux target is started regardless of quiet mode
        with timings.section("main:start_cmux_target"):
            instance.exec(
                "systemctl start cmux.target || systemctl start cmux.service || true"
            )

        if not console.quiet:
            try:
                with timings.section("main:instance_diagnostics"):
                    console.info("\n--- Instance diagnostics ---")
                    start_res = instance.exec(
                        "systemctl status cmux.target --no-pager -l | tail -n 40 || true"
                    )
                    if getattr(start_res, "stdout", None):
                        console.info(start_res.stdout)
                    if getattr(start_res, "stderr", None):
                        console.info_stderr(str(start_res.stderr))

                    diag_cmds = [
                        "systemctl is-enabled cmux.target || true",
                        "systemctl is-active cmux.target || true",
                        "systemctl status cmux.target --no-pager -l | tail -n 40 || true",
                        "systemctl status cmux-openvscode.service --no-pager -l | tail -n 80 || true",
                        "ps aux | grep -E 'openvscode-server|node /builtins/build/index.js' | grep -v grep || true",
                        "ss -lntp | grep ':39378' || true",
                        "ss -lntp | grep ':39379' || true",
                        "tail -n 80 /var/log/cmux/openvscode.log || true",
                    ]
                    for cmd in diag_cmds:
                        console.info(f"\n$ {cmd}")
                        res = instance.exec(cmd)
                        if getattr(res, "stdout", None):
                            console.info(res.stdout)
                        if getattr(res, "stderr", None):
                            console.info_stderr(str(res.stderr))
            except Exception as e:  # noqa: BLE001
                console.always(f"Diagnostics failed: {e}")

        try:
            with timings.section("main:port_39378_check"):
                services = getattr(instance.networking, "http_services", [])

                def _get(obj: object, key: str) -> t.Any:
                    if isinstance(obj, dict):
                        return obj.get(key)
                    return getattr(obj, key, None)

                vscode_service = None
                proxy_service = None
                for svc in services or []:
                    port = _get(svc, "port")
                    name = _get(svc, "name")
                    if port == 39378 or name == "port-39378":
                        vscode_service = svc
                    elif port == 39379 or name == "port-39379":
                        proxy_service = svc

                url = (
                    _get(vscode_service, "url") if vscode_service is not None else None
                )
                if not url:
                    console.always("No exposed HTTP service found for port 39378")
                else:
                    health_url = f"{url.rstrip('/')}/?folder=/root/workspace"
                    ok = False
                    for _ in range(30):
                        log = console.always if console.quiet else console.info

                        try:
                            with urllib_request.urlopen(health_url, timeout=5) as resp:
                                code = getattr(
                                    resp, "status", getattr(resp, "code", None)
                                )
                                if code == 200:
                                    log(f"Port 39378 check: HTTP {code}")
                                    ok = True
                                    break
                                else:
                                    log(
                                        f"Port 39378 not ready yet, HTTP {code}; retrying..."
                                    )
                        except (HTTPError, URLError, socket.timeout, TimeoutError) as e:
                            log(f"Port 39378 not ready yet ({e}); retrying...")
                        time.sleep(2)
                    if not ok:
                        console.always(
                            "Port 39378 did not return HTTP 200 within timeout"
                        )

                    console.always(f"VSCode URL: {health_url}")

                proxy_url = (
                    _get(proxy_service, "url") if proxy_service is not None else None
                )
                if proxy_url:
                    console.always(f"Proxy URL: {proxy_url}")
                else:
                    console.always("No exposed HTTP service found for port 39379")
        except Exception as e:  # noqa: BLE001
            console.always(f"Error checking port 39378: {e}")

        print_timing_summary(timings)

        if args.exec_script:
            console.always("Running custom --exec script...")
            exec_result = instance.exec(f"bash -lc {shlex.quote(args.exec_script)}")
            if getattr(exec_result, "stdout", None):
                console.always(exec_result.stdout)
            if getattr(exec_result, "stderr", None):
                console.always(str(exec_result.stderr))
            exit_code = getattr(exec_result, "exit_code", 0)
            if exit_code not in (None, 0):
                raise RuntimeError(f"--exec script exited with code {exit_code}")

        if args.resnapshot:
            send_macos_notification(
                "cmux snapshot ready",
                f"Instance {instance.id} is ready to resnapshot.",
            )
            input("Press Enter to snapshot again...")
            console.info("Snapshotting...")
            final_snapshot = instance.snapshot()
            console.always(f"Snapshot ID: {final_snapshot.id}")
    finally:
        _cleanup_instance()


if __name__ == "__main__":
    main()
