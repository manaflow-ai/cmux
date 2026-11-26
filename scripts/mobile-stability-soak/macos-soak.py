#!/usr/bin/env python3
import datetime as dt
import json
import os
import re
import subprocess
import time
from pathlib import Path


TAG = os.environ.get("CMUX_TAG", "swmob")
REPO = Path(os.environ.get("CMUX_REPO", Path(__file__).resolve().parents[2]))
DURATION_SECONDS = int(os.environ.get("SOAK_SECONDS", "43200"))
CLI_TIMEOUT_SECONDS = float(os.environ.get("CMUX_CLI_TIMEOUT_SECONDS", "20"))
soak_root = Path(os.environ.get("SOAK_ROOT", f"/tmp/cmux-mobile-soak-{TAG}"))
LOG_PATH = Path(os.environ.get("SOAK_LOG", soak_root / "macos-soak.log"))
STATUS_PATH = Path(os.environ.get("SOAK_STATUS", soak_root / "macos-soak.status"))
LOOP_SLEEP_SECONDS = float(os.environ.get("LOOP_SLEEP_SECONDS", "5"))
SURFACE_CHURN_INTERVAL = int(os.environ.get("MAC_SURFACE_CHURN_INTERVAL", "20"))
NOTIFICATION_INTERVAL = int(os.environ.get("MAC_NOTIFICATION_INTERVAL", "60"))
READ_SCREEN_RETRIES = int(os.environ.get("MAC_READ_SCREEN_RETRIES", "5"))
DIAGNOSTICS_DIR = Path(os.environ.get("SOAK_DIAGNOSTICS_DIR", soak_root / "diagnostics"))


STARTED_EPOCH = int(time.time())
STARTED_MONOTONIC = time.monotonic()
ESC = "\033"
WORKSPACE = ""
SURFACE = ""


def stamp() -> str:
    return dt.datetime.now().astimezone().strftime("%Y-%m-%dT%H:%M:%S%z")


def log(message: str) -> None:
    LOG_PATH.parent.mkdir(parents=True, exist_ok=True)
    with LOG_PATH.open("a") as f:
        f.write(f"{stamp()} {message}\n")
    print(f"{stamp()} {message}", flush=True)


def write_status(status: str, iteration: int, failures: int, **extra: object) -> None:
    payload = {
        "status": status,
        "iterations": iteration,
        "failures": failures,
        "elapsed_seconds": int(time.monotonic() - STARTED_MONOTONIC),
        "workspace": WORKSPACE,
        "surface": SURFACE,
    }
    payload.update(extra)
    STATUS_PATH.parent.mkdir(parents=True, exist_ok=True)
    tmp = STATUS_PATH.with_suffix(".tmp")
    tmp.write_text(json.dumps(payload, indent=2))
    tmp.replace(STATUS_PATH)


def cli(*args: str, timeout: float = CLI_TIMEOUT_SECONDS) -> subprocess.CompletedProcess[str]:
    env = os.environ.copy()
    env["CMUX_TAG"] = TAG
    cmd = [str(REPO / "scripts/cmux-debug-cli.sh"), *args]
    try:
        return subprocess.run(
            cmd,
            env=env,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            timeout=timeout,
        )
    except subprocess.TimeoutExpired as exc:
        out = exc.stdout or ""
        if isinstance(out, bytes):
            out = out.decode(errors="replace")
        return subprocess.CompletedProcess(cmd, 124, out + f"\ncmux-debug-cli timed out after {timeout:g}s\n")


def require_cli(*args: str, timeout: float = CLI_TIMEOUT_SECONDS) -> str:
    result = cli(*args, timeout=timeout)
    if result.returncode != 0:
        raise RuntimeError(result.stdout.strip() or f"command failed: {args}")
    return result.stdout


def write_failure_diagnostic(iteration: int, kind: str, output: str) -> None:
    diagnostic_dir = DIAGNOSTICS_DIR / f"macos-{iteration:06d}-{kind}"
    diagnostic_dir.mkdir(parents=True, exist_ok=True)
    payload = {
        "timestamp": stamp(),
        "iteration": iteration,
        "kind": kind,
        "workspace": WORKSPACE,
        "surface": SURFACE,
        "output": output,
    }
    (diagnostic_dir / "failure.json").write_text(json.dumps(payload, indent=2))


def record_cli_failure(iteration: int, kind: str, result: subprocess.CompletedProcess[str]) -> int:
    output = result.stdout.strip()
    write_failure_diagnostic(iteration, kind, output)
    log(f"fail iteration={iteration} {kind} output={output!r}")
    return 1


def extract_first_ref(kind: str, text: str) -> str:
    match = re.search(rf"({re.escape(kind)}:[0-9]+)", text)
    return match.group(1) if match else ""


def main() -> int:
    global WORKSPACE, SURFACE

    try:
        WORKSPACE = extract_first_ref(
            "workspace",
            require_cli("new-workspace", "--name", f"mac soak {STARTED_EPOCH}", "--command", "zsh -l", "--focus", "false"),
        )
        if not WORKSPACE:
            raise RuntimeError("missing workspace ref")
        time.sleep(1)
        SURFACE = extract_first_ref("surface", require_cli("list-pane-surfaces", "--workspace", WORKSPACE))
        if not SURFACE:
            raise RuntimeError("missing surface ref")
    except Exception as exc:
        log(f"fail bootstrap {exc}")
        write_status("failed", 0, 1, error=str(exc))
        return 1

    log(f"started workspace={WORKSPACE} surface={SURFACE} duration={DURATION_SECONDS}s")

    iteration = 0
    failures = 0
    deadline = STARTED_MONOTONIC + DURATION_SECONDS

    while time.monotonic() < deadline:
        iteration += 1
        marker = f"mac-soak-{STARTED_EPOCH}-{iteration}"
        color_cmd = (
            f"printf '{ESC}[48;2;220;40;40;38;2;255;255;255mMAC_RED_E2E_{iteration}{ESC}[0m'; print -r -- ''; "
            f"printf '{ESC}[48;2;40;180;80;38;2;0;0;0mMAC_GREEN_E2E_{iteration}{ESC}[0m'; print -r -- ''; "
            f"printf '{ESC}[48;2;50;120;240;38;2;255;255;255mMAC_BLUE_E2E_{iteration}{ESC}[0m'; print -r -- ''; "
            f"printf '{ESC}[48;2;230;210;50;38;2;0;0;0mMAC_YELLOW_E2E_{iteration}{ESC}[0m'; print -r -- ''; "
            f"print -r -- '{marker}'\\n"
        )

        ping = cli("ping")
        if ping.returncode != 0:
            failures += 1
            write_failure_diagnostic(iteration, "ping", ping.stdout.strip())
            log(f"fail iteration={iteration} failures={failures} ping output={ping.stdout.strip()!r}")
        else:
            sent = cli("send", "--workspace", WORKSPACE, "--surface", SURFACE, color_cmd)
            if sent.returncode != 0:
                failures += 1
                write_failure_diagnostic(iteration, "send", sent.stdout.strip())
                log(f"fail iteration={iteration} failures={failures} send output={sent.stdout.strip()!r}")
            else:
                screen_text = ""
                found = False
                for _ in range(READ_SCREEN_RETRIES):
                    time.sleep(0.5)
                    read = cli("read-screen", "--workspace", WORKSPACE, "--surface", SURFACE, "--lines", "120")
                    screen_text = read.stdout
                    tokens = (
                        marker,
                        f"MAC_RED_E2E_{iteration}",
                        f"MAC_GREEN_E2E_{iteration}",
                        f"MAC_BLUE_E2E_{iteration}",
                        f"MAC_YELLOW_E2E_{iteration}",
                    )
                    if read.returncode == 0 and all(token in screen_text for token in tokens):
                        found = True
                        break

                if not found:
                    failures += 1
                    write_failure_diagnostic(iteration, "missing_marker_or_color", screen_text[-4000:])
                    log(f"fail iteration={iteration} failures={failures} missing_marker_or_color marker={marker}")
                else:
                    checks = [
                        ("list-workspaces", cli("list-workspaces")),
                        ("tree", cli("tree", "--workspace", WORKSPACE)),
                        ("surface-health", cli("surface-health", "--workspace", WORKSPACE)),
                        ("mobile-host-status", cli("rpc", "mobile.host.status", "{}")),
                        ("set-status", cli("set-status", "mac-soak", f"iter:{iteration}", "--workspace", WORKSPACE)),
                        ("set-progress", cli("set-progress", f"0.{iteration % 10}", "--label", f"mac soak {iteration}", "--workspace", WORKSPACE)),
                    ]
                    for kind, result in checks:
                        if result.returncode != 0:
                            failures += record_cli_failure(iteration, kind, result)

                    if SURFACE_CHURN_INTERVAL > 0 and iteration % SURFACE_CHURN_INTERVAL == 0:
                        new_surface = cli("new-surface", "--type", "terminal", "--workspace", WORKSPACE, "--focus", "false")
                        temp_surface = extract_first_ref("surface", new_surface.stdout)
                        if new_surface.returncode == 0 and temp_surface:
                            closed = cli("close-surface", "--workspace", WORKSPACE, "--surface", temp_surface)
                            if closed.returncode != 0:
                                failures += record_cli_failure(iteration, "close-surface", closed)
                        else:
                            failures += record_cli_failure(iteration, "new-surface", new_surface)

                    if NOTIFICATION_INTERVAL > 0 and iteration % NOTIFICATION_INTERVAL == 0:
                        notify = cli("notify", "--title", f"mac soak {iteration}", "--body", marker, "--workspace", WORKSPACE, "--surface", SURFACE)
                        listed = cli("list-notifications")
                        if notify.returncode != 0:
                            failures += record_cli_failure(iteration, "notify", notify)
                        if listed.returncode != 0:
                            failures += record_cli_failure(iteration, "list-notifications", listed)

                    log(f"ok iteration={iteration} failures={failures} workspace={WORKSPACE} surface={SURFACE} marker={marker}")

        write_status("running", iteration, failures)
        if failures >= 3:
            write_status("failed", iteration, failures, error="failure threshold reached")
            return 1
        time.sleep(LOOP_SLEEP_SECONDS)

    cli("clear-progress", "--workspace", WORKSPACE)
    cli("clear-status", "mac-soak", "--workspace", WORKSPACE)
    write_status("passed", iteration, failures)
    log(f"passed iterations={iteration} failures={failures}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
