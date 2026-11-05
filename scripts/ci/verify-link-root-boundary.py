#!/usr/bin/env python3
"""Run the actual root/work-uid socket boundary on a trusted hosted Linux runner."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile


def build_artifacts(workspace: Path, package: str, target: str | None) -> list[dict]:
    selector = ["--test", target] if target else ["--lib"]
    build = subprocess.run(
        ["cargo", "test", "-p", package, *selector, "--locked",
         "--no-run", "--message-format=json"],
        cwd=workspace, text=True, stdout=subprocess.PIPE, check=True,
    )
    return [artifact for line in build.stdout.splitlines()
            if (artifact := json.loads(line)).get("reason") == "compiler-artifact"]


def executable(artifacts: list[dict], name: str, kind: str) -> Path:
    paths = {Path(artifact["executable"]) for artifact in artifacts
             if artifact.get("target", {}).get("name") == name
             and kind in artifact["target"].get("kind", [])
             and artifact.get("executable")}
    if len(paths) != 1:
        raise SystemExit(f"expected exactly one current-source {name} {kind} artifact")
    return paths.pop()


def run_root(command: list[str]) -> str:
    if os.geteuid() != 0:
        command = ["sudo", "-n", "--", *command]
    result = subprocess.run(command, text=True, stdout=subprocess.PIPE,
                            stderr=subprocess.STDOUT, timeout=120, check=False)
    print(result.stdout, end="", flush=True)
    if result.returncode:
        raise SystemExit(result.returncode)
    return result.stdout


def main() -> int:
    if sys.platform != "linux" or os.environ.get("GITHUB_ACTIONS") != "true":
        raise SystemExit("root boundary verification runs only on hosted Linux")
    workspace = Path(__file__).resolve().parents[2] / "cmux-tui"
    link = build_artifacts(workspace, "cmux-link", "receiver_root")
    native = build_artifacts(workspace, "cmux-tui", "receiver_native_root")
    producer = build_artifacts(workspace, "cmux-host", None)
    host_cli = build_artifacts(workspace, "cmux-host", "linux_agent")
    # A dropped uid must be able to exec the fixture without opening the source
    # checkout or cargo cache. Only copied current-source artifacts are exposed.
    with tempfile.TemporaryDirectory(prefix="cmux-root-boundary-", dir="/tmp") as directory:
        target = Path(directory) / "receiver-root-tests"
        shutil.copy2(executable(link, "receiver_root", "test"), target)
        os.chmod(directory, 0o755)
        os.chmod(target, 0o755)
        command = [str(target), "--ignored", "receiver_root_privileged_",
                   "--test-threads=1", "--nocapture"]
        output = run_root(command)
        for case in ("owned_child_cross_uid", "inherited_root_parent",
                     "unrelated_child_and_uid_refused", "daemon_survives_owner_drop",
                     "channel_lifetime", "native_private_channel", "native_ticket_drain_barrier"):
            if f"ROOT_BOUNDARY_EXECUTED {case}" not in output:
                raise SystemExit(f"root boundary case did not execute: {case}")
        native_target = Path(directory) / "receiver-native-root-tests"
        binary = Path(directory) / "cmux-tui"
        shutil.copy2(executable(native, "receiver_native_root", "test"), native_target)
        shutil.copy2(executable(native, "cmux-tui", "bin"), binary)
        os.chmod(native_target, 0o755)
        os.chmod(binary, 0o755)
        output = run_root(["env", "GITHUB_ACTIONS=true", f"CMUX_NATIVE_ROOT_BINARY={binary}",
                           str(native_target), "--ignored", "receiver_root_privileged_",
                           "--test-threads=1", "--nocapture"])
        if "ROOT_BOUNDARY_EXECUTED native_pending_policy_chain" not in output:
            raise SystemExit("Native pending-policy process chain did not execute")
        if "ROOT_BOUNDARY_EXECUTED native_encrypted_daemon_chain" not in output:
            raise SystemExit("Native encrypted daemon process chain did not execute")
        if "ROOT_BOUNDARY_EXECUTED native_private_process_inspection" not in output:
            raise SystemExit("Native private process inspection boundary did not execute")
        host_target = Path(directory) / "receiver-host-cli-tests"
        shutil.copy2(executable(host_cli, "linux_agent", "test"), host_target)
        os.chmod(host_target, 0o755)
        output = run_root(["env", "GITHUB_ACTIONS=true", str(host_target), "--ignored",
                           "receiver_root_privileged_host_run_activates_native_bootstrap",
                           "--test-threads=1", "--nocapture"])
        if "ROOT_BOUNDARY_EXECUTED native_host_run_activation" not in output:
            raise SystemExit("production host Native activation did not execute")
        producer_target = Path(directory) / "receiver-producer-root-tests"
        shutil.copy2(executable(producer, "cmux_host", "lib"), producer_target)
        os.chmod(producer_target, 0o755)
        output = run_root(["env", "GITHUB_ACTIONS=true", f"CMUX_NATIVE_ROOT_BINARY={binary}",
                           str(producer_target), "--ignored", "receiver_root_privileged_",
                           "--test-threads=1", "--nocapture"])
        for case in ("native_original_producer_chain", "native_canceled_producer_read",
                     "native_original_generation_restart", "native_original_policy_retirement"):
            if f"ROOT_BOUNDARY_EXECUTED {case}" not in output:
                raise SystemExit(f"Native original producer case did not execute: {case}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
