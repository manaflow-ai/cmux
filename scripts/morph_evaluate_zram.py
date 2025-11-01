#!/usr/bin/env python3
# /// script
# dependencies = [
#   "morphcloud",
#   "python-dotenv",
# ]
# ///
"""
Evaluate zram availability on a Morph snapshot, install the required kernel
modules, reboot if necessary, verify that zram can be activated, run the cmux
memory hardening script, and capture the result as a new snapshot.
"""

from __future__ import annotations

import argparse
import atexit
import signal
import sys
import textwrap
import uuid
from typing import Dict, List, Optional

import dotenv
from morphcloud.api import (
    ApiError,
    Instance,
    InstanceExecResponse,
    MorphCloudClient,
)

from morph_common import write_remote_file

dotenv.load_dotenv()

client = MorphCloudClient()
current_instance: Optional[Instance] = None

DEFAULT_TTL_SECONDS = 60 * 30
MAX_TTL_SECONDS = 60 * 60 * 12


class CommandError(RuntimeError):
    def __init__(self, label: str, command: str, response: InstanceExecResponse):
        message = textwrap.dedent(
            f"""
            Command '{label}' failed (exit {response.exit_code})
            stdout:
            {response.stdout.rstrip()}
            stderr:
            {response.stderr.rstrip()}
            """
        ).strip()
        super().__init__(message)
        self.label = label
        self.command = command
        self.response = response


def cleanup_instance(*_args) -> None:
    global current_instance
    if current_instance is None:
        return
    inst = current_instance
    try:
        print(f"\nStopping instance {inst.id}...")
        inst.stop()
        print("Instance stopped")
    except ApiError as exc:
        print(f"Failed to stop instance via API: {exc}", file=sys.stderr)
    except Exception as exc:  # noqa: BLE001
        print(f"Unexpected error stopping instance: {exc}", file=sys.stderr)
    finally:
        current_instance = None


atexit.register(cleanup_instance)
signal.signal(signal.SIGINT, cleanup_instance)
signal.signal(signal.SIGTERM, cleanup_instance)


def run_shell(
    instance: Instance,
    script: str,
    *,
    desc: str,
    check: bool = True,
    stream: bool = True,
    timeout: Optional[float] = None,
) -> InstanceExecResponse:
    print(f"\n[{desc}]")
    script_body = "#!/usr/bin/env bash\nset -euo pipefail\n" + script.rstrip() + "\n"
    remote_path = f"/tmp/cmux-zram-{uuid.uuid4().hex}.sh"
    write_remote_file(instance, remote_path=remote_path, content=script_body, executable=True)
    command = ["bash", remote_path]
    if stream:
        response = instance.exec(
            command,
            timeout=timeout,
            on_stdout=lambda chunk: print(chunk, end="", flush=True),
            on_stderr=lambda chunk: print(chunk, end="", flush=True, file=sys.stderr),
        )
    else:
        response = instance.exec(command, timeout=timeout)
        if response.stdout:
            print(response.stdout.rstrip())
        if response.stderr:
            print(response.stderr.rstrip(), file=sys.stderr)

    if check and response.exit_code not in (0,):
        raise CommandError(desc, script, response)
    try:
        instance.exec(["rm", "-f", remote_path])
    except Exception:
        pass
    return response


def parse_metadata(entries: List[str]) -> Dict[str, str]:
    metadata: Dict[str, str] = {}
    for entry in entries:
        if "=" not in entry:
            raise ValueError(f"Invalid metadata '{entry}'. Expected KEY=VALUE.")
        key, value = entry.split("=", 1)
        key = key.strip()
        value = value.strip()
        if not key:
            raise ValueError(f"Invalid metadata '{entry}'. Key cannot be empty.")
        metadata[key] = value
    return metadata


def detect_fallback_packages(instance: Instance) -> List[str]:
    for candidate in ("linux-image-cloud-amd64", "linux-image-amd64"):
        result = run_shell(
            instance,
            f"if apt-cache show {candidate} >/dev/null 2>&1; then echo {candidate}; fi",
            desc=f"check availability of {candidate}",
            stream=False,
        )
        if candidate in result.stdout.split():
            return [candidate]
    raise RuntimeError(
        "No suitable linux-image meta package found; cannot enable zram automatically"
    )


def check_extra_modules(instance: Instance, package: str) -> bool:
    response = run_shell(
        instance,
        textwrap.dedent(
            f"""
            set +e
            apt-cache show {package} >/dev/null 2>&1
            status=$?
            set -e
            if [ "$status" -eq 0 ]; then
              echo AVAILABLE
            else
              echo MISSING
            fi
            exit 0
            """
        ),
        desc=f"check {package}",
        stream=False,
    )
    return "AVAILABLE" in response.stdout.upper()


def try_modprobe(instance: Instance) -> bool:
    try:
        run_shell(instance, "modprobe zram", desc="modprobe zram", stream=False)
        return True
    except CommandError as exc:
        print(f"modprobe failed: {exc}", file=sys.stderr)
        return False


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Evaluate and enable zram support on Morph snapshots."
    )
    parser.add_argument(
        "--source-snapshot",
        required=True,
        help="Snapshot ID to start the evaluation instance from.",
    )
    parser.add_argument(
        "--ttl",
        type=int,
        default=DEFAULT_TTL_SECONDS,
        help="TTL in seconds for the temporary instance (default: 1800, max 43200).",
    )
    parser.add_argument(
        "--snapshot-metadata",
        action="append",
        default=[],
        metavar="KEY=VALUE",
        help="Metadata to attach to the resulting snapshot (can be repeated).",
    )
    parser.add_argument(
        "--snapshot-note",
        default="zram-evaluation",
        help="Short note stored under metadata['note'] for the resulting snapshot.",
    )
    args = parser.parse_args()

    metadata = {"purpose": "zram-evaluation", "note": args.snapshot_note}
    metadata.update(parse_metadata(args.snapshot_metadata))

    print(f"Starting instance from snapshot {args.source_snapshot}...")
    requested_ttl = max(60, min(args.ttl, MAX_TTL_SECONDS))

    instance = client.instances.start(
        snapshot_id=args.source_snapshot,
        ttl_seconds=requested_ttl,
        ttl_action="pause",
    )
    global current_instance
    current_instance = instance
    print(f"Instance {instance.id} ready.")

    kernel_result = run_shell(instance, "uname -r", desc="kernel version", stream=False)
    kernel_version = kernel_result.stdout.strip()
    print(f"Kernel: {kernel_version}")

    run_shell(
        instance,
        "DEBIAN_FRONTEND=noninteractive apt-get update",
        desc="apt update",
        timeout=600,
    )

    extra_pkg = f"linux-modules-extra-{kernel_version}"
    installed_packages: List[str] = []
    needs_reboot = False

    fallback_packages: List[str] = []

    if check_extra_modules(instance, extra_pkg):
        run_shell(
            instance,
            f"DEBIAN_FRONTEND=noninteractive apt-get install -y {extra_pkg}",
            desc=f"install {extra_pkg}",
            timeout=900,
        )
        installed_packages.append(extra_pkg)
    else:
        fallback_packages = detect_fallback_packages(instance)
        print(
            f"{extra_pkg} not available; installing fallback kernel packages {' '.join(fallback_packages)}"
        )
        run_shell(
            instance,
            f"DEBIAN_FRONTEND=noninteractive apt-get install -y {' '.join(fallback_packages)}",
            desc="install fallback kernel packages",
            timeout=1800,
        )
        installed_packages.extend(fallback_packages)
        needs_reboot = True

    modprobe_ready = False

    if not needs_reboot:
        modprobe_ready = try_modprobe(instance)
        if not modprobe_ready:
            if not fallback_packages:
                fallback_packages = detect_fallback_packages(instance)
            missing = [pkg for pkg in fallback_packages if pkg not in installed_packages]
            if missing:
                print(
                    "Installing fallback kernel packages "
                    + " ".join(missing)
                    + " to obtain zram module."
                )
                run_shell(
                    instance,
                    f"DEBIAN_FRONTEND=noninteractive apt-get install -y {' '.join(missing)}",
                    desc="install fallback kernel packages",
                    timeout=1800,
                )
                installed_packages.extend(missing)
            needs_reboot = True

    if needs_reboot:
        print("Rebooting instance to load newly installed kernel modules...")
        instance.reboot()
        instance.wait_until_ready()
        print("Instance back online.")
        kernel_result = run_shell(
            instance, "uname -r", desc="kernel after reboot", stream=False
        )
        kernel_version = kernel_result.stdout.strip()
        print(f"Kernel after reboot: {kernel_version}")
        try:
            run_shell(
                instance,
                "modprobe zram",
                desc="modprobe zram post-reboot",
                stream=False,
            )
            modprobe_ready = True
        except CommandError as exc:
            print(
                "zram module still unavailable after kernel installation; "
                "aborting evaluation."
            )
            return
    elif not modprobe_ready:
        raise RuntimeError("Unable to load zram module without reboot; manual review.")

    run_shell(
        instance,
        "/usr/local/sbin/cmux-configure-memory",
        desc="configure cmux memory safeguards",
        timeout=600,
    )

    verification_cmds = [
        ("free -h", "free -h"),
        ("swapon --show=NAME,TYPE,SIZE,USED,PRIO", "swap summary"),
        ("zramctl", "zramctl"),
        (
            "systemctl show -p MemoryLow,CPUWeight,IOWeight ssh.service cmux-openvscode.service",
            "systemd memory protections",
        ),
    ]
    for cmd, label in verification_cmds:
        run_shell(instance, cmd, desc=f"verify {label}", stream=False)

    print("\nCreating snapshot with zram support enabled...")
    snapshot = instance.snapshot(metadata=metadata)
    print(f"New snapshot created: {snapshot.id}")

    print("\nEvaluation complete.")


if __name__ == "__main__":
    try:
        main()
    finally:
        cleanup_instance()
