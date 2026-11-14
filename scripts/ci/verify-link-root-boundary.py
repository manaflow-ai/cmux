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
                     "channel_lifetime"):
            if f"ROOT_BOUNDARY_EXECUTED {case}" not in output:
                raise SystemExit(f"root boundary case did not execute: {case}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
