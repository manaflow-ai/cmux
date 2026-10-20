#!/usr/bin/env python3
"""Run the actual root/work-uid socket boundary on a trusted hosted Linux runner."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile


def main() -> int:
    if sys.platform != "linux" or os.environ.get("GITHUB_ACTIONS") != "true":
        raise SystemExit("root boundary verification runs only on hosted Linux")
    workspace = Path(__file__).resolve().parents[2] / "cmux-tui"
    build = subprocess.run(
        ["cargo", "test", "-p", "cmux-link", "--test", "receiver_root", "--locked",
         "--no-run", "--message-format=json"],
        cwd=workspace, text=True, stdout=subprocess.PIPE, check=True,
    )
    executables = []
    for line in build.stdout.splitlines():
        artifact = json.loads(line)
        if (artifact.get("reason") == "compiler-artifact"
                and artifact.get("target", {}).get("name") == "receiver_root"
                and artifact.get("executable")):
            executables.append(Path(artifact["executable"]))
    if len(executables) != 1:
        raise SystemExit("expected exactly one current-source root boundary test artifact")
    # A dropped uid must be able to exec the fixture without opening the source
    # checkout or cargo cache. Only this copied test artifact is made traversable.
    with tempfile.TemporaryDirectory(prefix="cmux-root-boundary-", dir="/tmp") as directory:
        target = Path(directory) / "receiver-root-tests"
        shutil.copy2(executables[0], target)
        os.chmod(directory, 0o755)
        os.chmod(target, 0o755)
        command = [str(target), "--ignored", "receiver_root_privileged_",
                   "--test-threads=1", "--nocapture"]
        if os.geteuid() != 0:
            command = ["sudo", "-n", "--", *command]
        result = subprocess.run(command, text=True, stdout=subprocess.PIPE,
                                stderr=subprocess.STDOUT, timeout=120, check=False)
        print(result.stdout, end="", flush=True)
        if result.returncode:
            return result.returncode
        for case in ("owned_child_cross_uid", "inherited_root_parent",
                     "unrelated_child_and_uid_refused", "daemon_survives_owner_drop",
                     "channel_lifetime", "native_private_channel"):
            if f"ROOT_BOUNDARY_EXECUTED {case}" not in result.stdout:
                raise SystemExit(f"root boundary case did not execute: {case}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
