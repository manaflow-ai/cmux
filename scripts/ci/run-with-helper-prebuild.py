#!/usr/bin/env python3
"""Run an optional helper alongside the build; only the build determines success."""
import argparse
import os
from pathlib import Path
import signal
import subprocess
import time


def signal_group(pgid, sig):
    """Signal a process group; False when no member can take the signal.

    ESRCH means the group is empty. macOS returns EPERM when every member left
    is a zombie (an exited leader not yet reaped, or orphans awaiting launchd),
    so EPERM on a group we created is the same "already gone" answer.
    """
    try:
        os.killpg(pgid, sig)
    except (ProcessLookupError, PermissionError):
        return False
    return True


def stop_group(process):
    if process is None:
        return
    # Kill the group even if its leader exited: grandchildren can still be alive.
    if not signal_group(process.pid, signal.SIGTERM):
        # The group refused the signal; still stop a leader that has not exited.
        if process.poll() is None:
            process.kill()
        process.wait()
        return
    time.sleep(0.2)
    signal_group(process.pid, signal.SIGKILL)
    process.wait()


def run(helper_command, build_command, log_path, helper_timeout=600):
    helper = build = None
    cancelled = 0

    def cancel(signum, _frame):
        nonlocal cancelled
        cancelled = signum

    previous = {sig: signal.signal(sig, cancel) for sig in (signal.SIGINT, signal.SIGTERM)}
    try:
        with open(log_path, "w") as log:
            try:
                helper = subprocess.Popen(helper_command, stdout=log, stderr=subprocess.STDOUT,
                                          start_new_session=True)
            except OSError as error:
                print(f"::warning::Optional helper prebuild could not start: {error}", flush=True)
            build = subprocess.Popen(build_command, start_new_session=True)
            deadline = time.monotonic() + helper_timeout
            while build.poll() is None and not cancelled:
                if helper is not None and helper.poll() is not None:
                    if helper.returncode:
                        print("::warning::Optional helper prebuild failed; build phases remain authoritative", flush=True)
                    stop_group(helper)
                    helper = None
                if helper is not None and time.monotonic() >= deadline:
                    print("::warning::Optional helper prebuild reached its deadline; build phases remain authoritative", flush=True)
                    stop_group(helper)
                    helper = None
                time.sleep(0.05)
            if cancelled:
                return 128 + cancelled
            return build.returncode if build.returncode >= 0 else 128 - build.returncode
    finally:
        # Neither an unsuccessful build nor cancellation waits for optional work.
        try:
            stop_group(helper)
        finally:
            stop_group(build)
        for sig, handler in previous.items():
            signal.signal(sig, handler)
        if Path(log_path).exists():
            print(Path(log_path).read_text(errors="replace"), end="", flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--derived-data", required=True)
    parser.add_argument("--configuration", default="Release")
    parser.add_argument("--archs", required=True)
    parser.add_argument("--log", required=True)
    parser.add_argument("command", nargs=argparse.REMAINDER)
    args = parser.parse_args()
    command = args.command[1:] if args.command[:1] == ["--"] else args.command
    if not command:
        parser.error("a build command is required")
    helper = Path(__file__).with_name("prebuild-app-helpers.sh")
    return run(["nice", "-n", "10", str(helper), "--derived-data", args.derived_data,
                "--configuration", args.configuration, "--archs", args.archs], command, args.log)


if __name__ == "__main__":
    raise SystemExit(main())
