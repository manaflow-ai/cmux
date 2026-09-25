#!/usr/bin/env python3
"""Keep every app-host xcodebuild launch behind file-backed CI capture."""

import os
from pathlib import Path
import signal
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]
WORKFLOW_DIR = ROOT / ".github/workflows"
APP_HOST_LAUNCHER = "run-app-host-xcodebuild.sh"
CONSOLE_WRAPPER = ROOT / "scripts/ci/run-in-console-session.sh"
CAPTURE_WRAPPER = ROOT / "scripts/ci/run-and-capture.sh"


def workflows_launching_app_host():
    """Every workflow that runs the app-host launcher, read from the workflows.

    This used to be a two-entry list naming ci.yml and test-e2e.yml. The
    app-host jobs moved to ci-macos.yml and the list did not follow, so the
    guard scanned a workflow with no launches at all and passed while the
    workflow that actually builds the app host went unchecked. Asking the
    directory cannot drift that way.
    """
    return [
        path for path in sorted(WORKFLOW_DIR.glob("*.y*ml"))
        if APP_HOST_LAUNCHER in path.read_text(encoding="utf-8")
    ]


def named_step_blocks(text: str):
    lines = text.splitlines()
    starts = [
        index for index, line in enumerate(lines)
        if line.startswith("      - name:")
    ]
    starts.append(len(lines))
    for pos in range(len(starts) - 1):
        yield "\n".join(lines[starts[pos]:starts[pos + 1]])


def validate_common_capture_boundary() -> None:
    console = CONSOLE_WRAPPER.read_text(encoding="utf-8")
    capture = CAPTURE_WRAPPER.read_text(encoding="utf-8")
    required_console_tokens = (
        "CMUX_CI_FILE_CAPTURE_ACTIVE",
        "run-app-host-xcodebuild.sh",
        "run-and-capture.sh",
        "cmux-app-host-console-capture-",
    )
    missing = [token for token in required_console_tokens if token not in console]
    if missing:
        raise SystemExit(
            "run-in-console-session.sh is missing app-host file capture: "
            + ", ".join(missing)
        )
    if "CMUX_CI_FILE_CAPTURE_ACTIVE=1" not in capture:
        raise SystemExit("run-and-capture.sh must mark its child as file-captured")


def validate_workflows() -> int:
    checked = 0
    workflows = workflows_launching_app_host()
    if not workflows:
        raise SystemExit(
            f"no workflow under {WORKFLOW_DIR} runs {APP_HOST_LAUNCHER}; "
            "the launcher was renamed or this guard is scanning the wrong place"
        )
    for path in workflows:
        text = path.read_text(encoding="utf-8")
        for block in named_step_blocks(text):
            if APP_HOST_LAUNCHER not in block:
                continue
            checked += 1
            if "| tee" in block or "PIPESTATUS[" in block:
                raise SystemExit(
                    f"{path}: app-host xcodebuild step still uses a CI pipe chain"
                )
            # Direct workflow calls are safe only through the common console
            # boundary, an explicit run-and-capture call, or regular-file
            # redirection. This prevents a new call from bypassing file capture.
            if (
                "run-in-console-session.sh" not in block
                and "run-and-capture.sh" not in block
                and '2>&1' not in block
            ):
                raise SystemExit(
                    f"{path}: app-host xcodebuild step bypasses file-backed capture"
                )
        if path.name == "test-e2e.yml":
            if "bash scripts/ci/run-and-capture.sh /tmp/xcodebuild-e2e.log" not in text:
                raise SystemExit(
                    "test-e2e.yml must use file-backed xcodebuild capture"
                )
    if checked == 0:
        raise SystemExit("no app-host xcodebuild workflow steps were found")
    return checked


def smoke_direct_console_capture() -> None:
    """A detached child inherited from a direct call cannot hold the step open."""
    with tempfile.TemporaryDirectory() as directory:
        root = Path(directory)
        fake = root / "run-app-host-xcodebuild.sh"
        child_pid = root / "child.pid"
        fake.write_text(
            "#!/usr/bin/env bash\n"
            "echo direct-app-host-started\n"
            "sleep 60 &\n"
            "echo $! >\"$CMUX_CAPTURE_CHILD_PID\"\n"
            "exit 7\n",
            encoding="utf-8",
        )
        fake.chmod(0o755)
        env = {
            **os.environ,
            "RUNNER_TEMP": str(root),
            "GITHUB_WORKSPACE": str(ROOT),
            "CMUX_TAG": "pipe-capture-smoke",
            "CMUX_CAPTURE_CHILD_PID": str(child_pid),
        }
        started = time.monotonic()
        completed = subprocess.run(
            ["/bin/bash", str(CONSOLE_WRAPPER), str(fake)],
            cwd=ROOT,
            env=env,
            capture_output=True,
            text=True,
            check=False,
            timeout=10,
        )
        elapsed = time.monotonic() - started
        try:
            if completed.returncode != 7:
                raise AssertionError(completed.stdout + completed.stderr)
            if elapsed >= 5:
                raise AssertionError(
                    f"direct app-host capture waited {elapsed:.1f}s for detached child"
                )
            if "direct-app-host-started" not in completed.stdout:
                raise AssertionError(completed.stdout + completed.stderr)
            captures = list(root.glob("cmux-app-host-console-capture-*.log"))
            if len(captures) != 1:
                raise AssertionError(f"expected one console capture, found {captures}")
            if "direct-app-host-started" not in captures[0].read_text(errors="replace"):
                raise AssertionError("direct app-host output missing from capture")
        finally:
            if child_pid.is_file():
                try:
                    os.kill(int(child_pid.read_text().strip()), signal.SIGTERM)
                except (ProcessLookupError, ValueError):
                    pass


def main() -> None:
    validate_common_capture_boundary()
    checked = validate_workflows()
    smoke_direct_console_capture()
    print(f"ok: {checked} app-host workflow step(s) use file-backed capture")


if __name__ == "__main__":
    main()
