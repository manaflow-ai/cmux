#!/usr/bin/env python3

from __future__ import annotations

import json
import os
import subprocess
import sys
import time
import uuid
from pathlib import Path


_LAUNCHD_SUBPROCESS_HELPER = r"""
import json
import os
import subprocess
import sys
import traceback
from pathlib import Path

spec_path = Path(sys.argv[1])
result_path = Path(sys.argv[2])
spec = json.loads(spec_path.read_text(encoding="utf-8"))
try:
    completed = subprocess.run(
        spec["argv"],
        input=spec["input"],
        capture_output=True,
        text=True,
        check=False,
        env=spec["env"],
        cwd=spec["cwd"],
        timeout=spec["timeout"],
    )
    payload = {
        "returncode": completed.returncode,
        "stdout": completed.stdout,
        "stderr": completed.stderr,
    }
except BaseException:
    payload = {
        "returncode": 255,
        "stdout": "",
        "stderr": traceback.format_exc(),
    }

temporary_path = result_path.with_name(result_path.name + ".tmp")
temporary_path.write_text(json.dumps(payload), encoding="utf-8")
os.chmod(temporary_path, 0o600)
os.replace(temporary_path, result_path)
"""


def isolated_hook_environment(base_env: dict[str, str]) -> dict[str, str]:
    """Return the small host environment needed by a hook fixture.

    Agent lineage and authority markers must be supplied by each fixture, not
    inherited from the developer or CI process that launched the test.
    """
    allowed = {
        "HOME",
        "LANG",
        "LC_ALL",
        "LOGNAME",
        "PATH",
        "SHELL",
        "TMPDIR",
        "USER",
    }
    environment = {key: value for key, value in base_env.items() if key in allowed}
    environment.setdefault("PATH", "/usr/bin:/bin:/usr/sbin:/sbin")
    return environment


def run_root_hook_process(
    argv: list[str],
    *,
    input: str,
    env: dict[str, str],
    cwd: Path,
    root: Path,
    timeout: float,
) -> subprocess.CompletedProcess[str]:
    """Run a hook with ancestry that proves it has no agent-process parent.

    Local agent-driven tests reparent a small Python launcher to launchd. The
    hook CLI is its child, so the production ancestry walk reaches PID 1 and
    classifies the hook as a root without any test-only authority override.
    CI runners already have no agent ancestor and use a direct subprocess.
    """
    if sys.platform != "darwin" or os.environ.get("CI"):
        return subprocess.run(
            argv,
            input=input,
            capture_output=True,
            text=True,
            check=False,
            env=env,
            cwd=cwd,
            timeout=timeout,
        )

    launch_root = root / f"launchd-hook-{uuid.uuid4().hex}"
    launch_root.mkdir(mode=0o700)
    spec_path = launch_root / "spec.json"
    result_path = launch_root / "result.json"
    spec_path.write_text(
        json.dumps(
            {
                "argv": argv,
                "input": input,
                "env": env,
                "cwd": str(cwd),
                "timeout": timeout,
            }
        ),
        encoding="utf-8",
    )
    spec_path.chmod(0o600)

    label = f"com.cmux.tests.hook.{os.getpid()}.{uuid.uuid4().hex[:12]}"
    submitted = subprocess.run(
        [
            "/bin/launchctl",
            "submit",
            "-l",
            label,
            "--",
            sys.executable,
            "-c",
            _LAUNCHD_SUBPROCESS_HELPER,
            str(spec_path),
            str(result_path),
        ],
        capture_output=True,
        text=True,
        check=False,
        timeout=5,
    )
    if submitted.returncode != 0:
        raise RuntimeError(
            f"launchctl submit failed ({submitted.returncode}): {submitted.stderr.strip()}"
        )

    deadline = time.monotonic() + timeout + 5
    try:
        while time.monotonic() < deadline and not result_path.exists():
            time.sleep(0.02)
        if not result_path.exists():
            raise subprocess.TimeoutExpired(argv, timeout)
        payload = json.loads(result_path.read_text(encoding="utf-8"))
        return subprocess.CompletedProcess(
            argv,
            int(payload["returncode"]),
            str(payload["stdout"]),
            str(payload["stderr"]),
        )
    finally:
        subprocess.run(
            ["/bin/launchctl", "remove", label],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            check=False,
            timeout=5,
        )


def resolve_cmux_cli() -> str:
    explicit = os.environ.get("CMUX_CLI_BIN") or os.environ.get("CMUX_CLI")
    if explicit and os.path.exists(explicit) and os.access(explicit, os.X_OK):
        return explicit

    recorded_path = Path("/tmp/cmux-last-cli-path")
    if recorded_path.exists():
        candidate = recorded_path.read_text(encoding="utf-8").strip()
        if candidate and os.path.exists(candidate) and os.access(candidate, os.X_OK):
            return candidate

    raise RuntimeError(
        "Unable to find cmux CLI binary. Set CMUX_CLI_BIN or run ./scripts/reload.sh --tag <tag> first."
    )
