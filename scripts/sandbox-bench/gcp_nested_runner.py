#!/usr/bin/env python3
"""Create and exercise one disposable nested-virt GCP worker.

The command is a dry run unless ``--apply`` is supplied. It never changes a
network or IAM policy and never deletes an instance unless this invocation
created that exact, randomly generated name. A startup watchdog stops the VM
after its TTL or after the idle marker has not been touched for the configured
idle window. The normal successful path deletes the instance in ``finally``.
"""

from __future__ import annotations

import argparse
import json
import os
import secrets
import shlex
import subprocess
import sys
import tempfile
import time
from pathlib import Path
from typing import Any, Sequence


DEFAULT_PROJECT = "<project>"
DEFAULT_OWNER = "<owner>"
DEFAULT_PURPOSE = "<purpose>"
DEFAULT_ZONE = "us-west1-a"
DEFAULT_MACHINE = "n4d-standard-16"
DEFAULT_IMAGE_FAMILY = "ubuntu-2404-lts-amd64"
DEFAULT_IMAGE_PROJECT = "ubuntu-os-cloud"
DEFAULT_TTL_HOURS = 4.0
DEFAULT_IDLE_MINUTES = 15
RUNSC_VERSION = "release-20261019.0"
RUNSC_SHA256 = "1298e8ed9c3fee900f00d2ea96ec2d79d80ed93f2175812f29b7e7da718041a3"
FIRECRACKER_VERSION = "v1.17.0"
FIRECRACKER_SHA256 = "06094a1108ae9e82aa4c23a775aa92758f53f1175d422270d9d6162cb9ade558"
CLOUD_HYPERVISOR_VERSION = "v54.0"
CLOUD_HYPERVISOR_SHA256 = "4f4f98a3d661a40f3e5272627cc895a1b2e525f2f6bedf5f895f9cd21ba5c65b"


class RunnerError(RuntimeError):
    """A command failed before a safe receipt could be produced."""


def _run(argv: Sequence[str], *, capture: bool = False) -> subprocess.CompletedProcess[str]:
    """Run gcloud without invoking a shell and preserve stderr for the receipt."""
    try:
        return subprocess.run(list(argv), check=False, text=True, capture_output=capture)
    except OSError as exc:
        raise RunnerError(f"could not execute {argv[0]!r}: {exc}") from exc


def _require_gcloud() -> None:
    if not any(Path(directory, "gcloud").is_file() for directory in os.environ.get("PATH", "").split(os.pathsep)):
        raise RunnerError("gcloud is not on PATH")


def _valid_duration(value: float, name: str, minimum: float = 0.1) -> float:
    if value < minimum or value > 168:
        raise argparse.ArgumentTypeError(f"{name} must be between {minimum} and 168")
    return value


def _valid_minutes(value: int) -> int:
    if value < 1 or value > 10080:
        raise argparse.ArgumentTypeError("idle-stop-minutes must be between 1 and 10080")
    return value


def _instance_name(prefix: str) -> str:
    prefix = prefix.strip().lower().replace("_", "-")
    if not prefix or any(ch not in "abcdefghijklmnopqrstuvwxyz0123456789-" for ch in prefix):
        raise RunnerError("name-prefix must contain only lowercase letters, digits, and hyphens")
    name = f"{prefix}-{time.strftime('%Y%m%d-%H%M%S', time.gmtime())}-{secrets.token_hex(4)}"
    if len(name) > 63:
        raise RunnerError("name-prefix leaves no room for the generated suffix")
    return name


def _startup_script(ttl_seconds: int, idle_seconds: int) -> str:
    # Values are validated numeric arguments before interpolation. The marker
    # makes the watchdog independent of the runner process: a crash still
    # stops the VM, while an active runner can touch it before each probe.
    return f"""#!/bin/bash
set -eu
install -d -m 0755 /var/lib/rd-sandbox
install -d -m 0755 /opt/rd-sandbox/bin /tmp/rd-sandbox-download
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq --no-install-recommends ca-certificates curl bzip2 xz-utils
curl -fsSL -o /tmp/rd-sandbox-download/gvisor.tar.bz2 \\
  https://github.com/google/gvisor/releases/download/{RUNSC_VERSION}/gvisor-x86_64.tar.bz2
echo '{RUNSC_SHA256}  /tmp/rd-sandbox-download/gvisor.tar.bz2' | sha256sum -c -
mkdir -p /tmp/rd-sandbox-download/gvisor
tar -xjf /tmp/rd-sandbox-download/gvisor.tar.bz2 -C /tmp/rd-sandbox-download/gvisor
install -m 0755 /tmp/rd-sandbox-download/gvisor/runsc /opt/rd-sandbox/bin/runsc
curl -fsSL -o /tmp/rd-sandbox-download/firecracker.tgz \\
  https://github.com/firecracker-microvm/firecracker/releases/download/{FIRECRACKER_VERSION}/firecracker-{FIRECRACKER_VERSION}-x86_64.tgz
echo '{FIRECRACKER_SHA256}  /tmp/rd-sandbox-download/firecracker.tgz' | sha256sum -c -
tar -xzf /tmp/rd-sandbox-download/firecracker.tgz -C /tmp/rd-sandbox-download
install -m 0755 /tmp/rd-sandbox-download/release-{FIRECRACKER_VERSION}-x86_64/firecracker-{FIRECRACKER_VERSION}-x86_64 /opt/rd-sandbox/bin/firecracker
curl -fsSL -o /opt/rd-sandbox/bin/cloud-hypervisor \\
  https://github.com/cloud-hypervisor/cloud-hypervisor/releases/download/{CLOUD_HYPERVISOR_VERSION}/cloud-hypervisor-static
echo '{CLOUD_HYPERVISOR_SHA256}  /opt/rd-sandbox/bin/cloud-hypervisor' | sha256sum -c -
chmod 0755 /opt/rd-sandbox/bin/cloud-hypervisor
date +%s > /var/lib/rd-sandbox/boot-epoch
touch /var/lib/rd-sandbox/last-activity
cat > /usr/local/sbin/rd-sandbox-watchdog <<'WATCHDOG'
#!/bin/bash
set -eu
ttl={ttl_seconds}
idle={idle_seconds}
grace=120
while sleep 30; do
  now=$(date +%s)
  boot=$(stat -c %Y /var/lib/rd-sandbox/boot-epoch 2>/dev/null || echo "$now")
  last=$(stat -c %Y /var/lib/rd-sandbox/last-activity 2>/dev/null || echo "$boot")
  if [ "$((now - boot))" -ge "$ttl" ]; then
    logger -t rd-sandbox "TTL reached; stopping instance"
    systemctl poweroff
    exit 0
  fi
  if [ "$((now - boot))" -ge "$grace" ] && [ "$((now - last))" -ge "$idle" ]; then
    logger -t rd-sandbox "idle stop reached; stopping instance"
    systemctl poweroff
    exit 0
  fi
done
WATCHDOG
chmod 0755 /usr/local/sbin/rd-sandbox-watchdog
nohup /usr/local/sbin/rd-sandbox-watchdog >/var/log/rd-sandbox-watchdog.log 2>&1 &
touch /var/lib/rd-sandbox/startup-ready
"""


def labels(owner: str, purpose: str, ttl_hours: float) -> str:
    ttl_label = str(int(ttl_hours)) if ttl_hours.is_integer() else str(ttl_hours).replace(".", "-")
    return f"owner={owner},purpose={purpose},ttl-hours={ttl_label}"


def create_argv(args: argparse.Namespace, name: str, startup_file: Path) -> list[str]:
    return [
        "gcloud", "compute", "instances", "create", name,
        f"--project={args.project}", f"--zone={args.zone}",
        f"--machine-type={args.machine_type}",
        f"--image-family={args.image_family}",
        f"--image-project={args.image_project}",
        f"--boot-disk-size={args.boot_disk_size}",
        f"--labels={labels(args.owner, args.purpose, args.ttl_hours)}",
        f"--metadata-from-file=startup-script={startup_file}",
        "--enable-nested-virtualization",
        # This requests an ephemeral address but creates no firewall rule.
        "--network-interface=network=default,network-tier=PREMIUM,stack-type=IPV4_ONLY",
        "--quiet",
    ]


def _describe(args: argparse.Namespace, name: str) -> dict[str, Any] | None:
    completed = _run([
        "gcloud", "compute", "instances", "describe", name,
        f"--project={args.project}", f"--zone={args.zone}", "--format=json",
    ], capture=True)
    if completed.returncode != 0:
        return None
    try:
        return json.loads(completed.stdout)
    except json.JSONDecodeError as exc:
        raise RunnerError(f"gcloud describe returned invalid JSON: {exc}") from exc


def _ours(instance: dict[str, Any] | None, owner: str, purpose: str) -> bool:
    if not instance:
        return False
    got = instance.get("labels", {})
    return got.get("owner") == owner and got.get("purpose") == purpose


def _ssh_argv(args: argparse.Namespace, name: str, command: str) -> list[str]:
    return [
        "gcloud", "compute", "ssh", name,
        f"--project={args.project}", f"--zone={args.zone}", "--quiet",
        "--command", command,
    ]


def _scp_argv(args: argparse.Namespace, name: str, source: Path) -> list[str]:
    return [
        "gcloud", "compute", "scp", str(source), f"{name}:/tmp/sandbox_bench.py",
        f"--project={args.project}", f"--zone={args.zone}", "--quiet",
    ]


def _receipt_command(argv: Sequence[str]) -> str:
    return shlex.join(argv)


def _plan(args: argparse.Namespace, name: str, startup_file: Path) -> dict[str, Any]:
    create = create_argv(args, name, startup_file)
    probe = _ssh_argv(args, name, "touch /var/lib/rd-sandbox/last-activity && " + args.probe_command)
    delete = [
        "gcloud", "compute", "instances", "delete", name,
        f"--project={args.project}", f"--zone={args.zone}", "--quiet",
    ]
    return {
        "project": args.project, "zone": args.zone, "instance": name,
        "machine_type": args.machine_type, "labels": labels(args.owner, args.purpose, args.ttl_hours),
        "ttl_hours": args.ttl_hours, "idle_stop_minutes": args.idle_stop_minutes,
        "dry_run": not args.apply,
        "commands": {
            "create": _receipt_command(create),
            "probe_upload": _receipt_command(_scp_argv(args, name, Path(args.probe_file))),
            "probe": _receipt_command(probe),
            "delete": _receipt_command(delete),
        },
    }


def run(args: argparse.Namespace) -> dict[str, Any]:
    _require_gcloud()
    if args.apply and any(value.startswith("<") for value in (args.project, args.owner, args.purpose)):
        raise RunnerError("--apply requires explicit --project, --owner, and --purpose values")
    name = _instance_name(args.name_prefix)
    with tempfile.TemporaryDirectory(prefix="rd-sandbox-startup-") as temp:
        startup_file = Path(temp) / "startup.sh"
        startup_file.write_text(_startup_script(int(args.ttl_hours * 3600), args.idle_stop_minutes * 60))
        receipt = _plan(args, name, startup_file)
        if not args.apply:
            receipt["status"] = "dry-run"
            return receipt

        if _describe(args, name) is not None:
            raise RunnerError(f"refusing to reuse existing instance {name!r}")

        created = False
        try:
            create = _run(create_argv(args, name, startup_file), capture=True)
            if create.returncode != 0:
                # A transport error can occur after the API accepted create.
                # Recover only an exact generated name carrying our labels.
                if _ours(_describe(args, name), args.owner, args.purpose):
                    created = True
                raise RunnerError(f"instance create failed ({create.returncode}): {create.stderr.strip()[-500:]}")
            created = True
            deadline = time.monotonic() + args.wait_seconds
            ready = False
            while time.monotonic() < deadline:
                check = _run(_ssh_argv(args, name, "test -f /var/lib/rd-sandbox/startup-ready"), capture=True)
                if check.returncode == 0:
                    ready = True
                    break
                time.sleep(min(10, max(1, deadline - time.monotonic())))
            if not ready:
                raise RunnerError("guest did not become SSH-ready before wait-seconds")

            probe_file = Path(args.probe_file)
            if not probe_file.is_file():
                raise RunnerError(f"probe file does not exist: {probe_file}")
            upload = _run(_scp_argv(args, name, probe_file), capture=True)
            if upload.returncode != 0:
                raise RunnerError(f"probe upload failed: {upload.stderr.strip()[-500:]}")
            probe = _run(_ssh_argv(args, name, "touch /var/lib/rd-sandbox/last-activity && " + args.probe_command), capture=True)
            receipt["probe"] = {
                "returncode": probe.returncode, "stdout": probe.stdout[-10000:],
                "stderr": probe.stderr[-2000:],
            }
            if probe.returncode != 0:
                raise RunnerError(f"probe failed with exit code {probe.returncode}")
            receipt["status"] = "completed"
            return receipt
        finally:
            if created and not args.keep:
                delete = _run([
                    "gcloud", "compute", "instances", "delete", name,
                    f"--project={args.project}", f"--zone={args.zone}", "--quiet",
                ], capture=True)
                receipt["cleanup"] = {
                    "attempted": True, "returncode": delete.returncode,
                    "stderr": delete.stderr[-2000:],
                }
            elif created:
                receipt["cleanup"] = {"attempted": False, "kept": True}


def parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--apply", action="store_true", help="perform GCP mutations (default is dry-run)")
    p.add_argument("--project", default=os.environ.get("CMUX_GCP_PROJECT", DEFAULT_PROJECT))
    p.add_argument("--zone", default=DEFAULT_ZONE)
    p.add_argument("--machine-type", default=DEFAULT_MACHINE)
    p.add_argument("--image-family", default=DEFAULT_IMAGE_FAMILY)
    p.add_argument("--image-project", default=DEFAULT_IMAGE_PROJECT)
    p.add_argument("--owner", default=os.environ.get("CMUX_RESOURCE_OWNER", DEFAULT_OWNER))
    p.add_argument("--purpose", default=os.environ.get("CMUX_RESOURCE_PURPOSE", DEFAULT_PURPOSE))
    p.add_argument("--boot-disk-size", default="50GB")
    p.add_argument("--name-prefix", default="rd-biz-sbx")
    p.add_argument("--ttl-hours", type=lambda value: _valid_duration(float(value), "ttl-hours"), default=DEFAULT_TTL_HOURS)
    p.add_argument("--idle-stop-minutes", type=lambda value: _valid_minutes(int(value)), default=DEFAULT_IDLE_MINUTES)
    p.add_argument("--wait-seconds", type=int, default=600)
    p.add_argument("--probe-file", default=str(Path(__file__).with_name("sandbox_bench.py")))
    p.add_argument(
        "--probe-command",
        default=(
            "python3 /tmp/sandbox_bench.py probe --json "
            "--runsc /opt/rd-sandbox/bin/runsc "
            "--firecracker /opt/rd-sandbox/bin/firecracker "
            "--cloud-hypervisor /opt/rd-sandbox/bin/cloud-hypervisor"
        ),
    )
    p.add_argument("--keep", action="store_true", help="keep created instance; TTL/idle watchdog still applies")
    p.add_argument("--json", action="store_true", dest="json_output")
    return p


def main(argv: Sequence[str] | None = None) -> int:
    args = parser().parse_args(argv)
    try:
        receipt = run(args)
    except RunnerError as exc:
        payload = {"status": "error", "error": str(exc)}
        print(json.dumps(payload, indent=2) if args.json_output else f"error: {exc}", file=sys.stderr)
        return 2
    print(json.dumps(receipt, indent=2, sort_keys=True) if args.json_output else json.dumps(receipt, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
