#!/usr/bin/env python3
"""Regression: impossible memory-trim grace durations fail during parsing."""

from __future__ import annotations

import glob
import os
import subprocess
import tempfile
import uuid


def resolve_cmux_cli() -> str:
    explicit = os.environ.get("CMUX_CLI_BIN") or os.environ.get("CMUX_CLI")
    if explicit and os.path.exists(explicit) and os.access(explicit, os.X_OK):
        return explicit

    candidates = [
        path
        for path in glob.glob(
            os.path.expanduser("~/Library/Developer/Xcode/DerivedData/*/Build/Products/Debug/cmux")
        )
        if os.path.exists(path) and os.access(path, os.X_OK)
    ]
    if candidates:
        candidates.sort(key=os.path.getmtime, reverse=True)
        return candidates[0]

    raise RuntimeError("Unable to find cmux CLI binary. Set CMUX_CLI_BIN.")


def main() -> int:
    try:
        cli_path = resolve_cmux_cli()
    except RuntimeError as exc:
        print(f"FAIL: {exc}")
        return 1

    env = dict(os.environ)
    env["CMUX_CLI_SENTRY_DISABLED"] = "1"

    with tempfile.TemporaryDirectory(prefix="cmux-memory-trim-duration-") as tmpdir:
        env["CMUX_SOCKET_PATH"] = os.path.join(tmpdir, f"missing-{uuid.uuid4().hex}.sock")
        result = subprocess.run(  # noqa: S603
            [
                cli_path,
                "memory",
                "trim",
                "--workspace",
                "workspace:1",
                "--agent",
                "auto",
                "--grace-seconds",
                "1e19",
                "--json",
            ],
            text=True,
            capture_output=True,
            check=False,
            timeout=5.0,
            env=env,
        )

    merged = f"{result.stdout}\n{result.stderr}"
    expected = "--grace-seconds must be a non-negative duration"
    if result.returncode == 0:
        print("FAIL: impossible grace duration unexpectedly succeeded")
        print(f"stdout={result.stdout!r}")
        print(f"stderr={result.stderr!r}")
        return 1
    if expected not in merged:
        print("FAIL: impossible grace duration should fail before socket access")
        print(f"expected={expected!r}")
        print(f"exit={result.returncode}")
        print(f"stdout={result.stdout!r}")
        print(f"stderr={result.stderr!r}")
        return 1

    print("PASS: memory trim rejects impossible grace durations before socket access")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
