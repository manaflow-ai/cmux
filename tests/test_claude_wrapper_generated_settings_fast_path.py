#!/usr/bin/env python3
"""The built CLI's inject-settings output must take the wrapper's fast path.

The Claude wrapper skips its Node validation only for the exact document
`cmux hooks claude inject-settings` prints. If the CLI's document changes
without the wrapper's copy, launches stay correct (Node validates the new
document) but silently lose the fast path. This test runs the built CLI and
fails on that drift.
"""

from __future__ import annotations

import glob
import os
import shutil
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from node_runtime import ensure_node_on_path  # noqa: E402
from test_claude_wrapper_hooks import run_generated_settings_case  # noqa: E402


def resolve_cmux_cli() -> str:
    explicit = os.environ.get("CMUX_CLI_BIN") or os.environ.get("CMUX_CLI")
    if explicit and os.path.exists(explicit) and os.access(explicit, os.X_OK):
        return explicit

    candidates = glob.glob(
        os.path.expanduser("~/Library/Developer/Xcode/DerivedData/*/Build/Products/Debug/cmux")
    )
    candidates.extend(glob.glob("/tmp/cmux-*/Build/Products/Debug/cmux"))
    candidates = [path for path in candidates if os.access(path, os.X_OK)]
    if candidates:
        candidates.sort(key=os.path.getmtime, reverse=True)
        return candidates[0]

    in_path = shutil.which("cmux")
    if in_path:
        return in_path

    raise RuntimeError("Unable to find cmux CLI binary. Set CMUX_CLI_BIN.")


def main() -> int:
    if ensure_node_on_path() is None:
        print("SKIP: node runtime not found; wrapper fakes exec node")
        return 0

    cli = resolve_cmux_cli()
    env = {
        "HOME": os.environ.get("HOME", "/tmp"),
        "PATH": "/usr/bin:/bin",
        "CMUX_CLI_SENTRY_DISABLED": "1",
    }
    generated = subprocess.run(
        [cli, "hooks", "claude", "inject-settings"],
        env=env,
        capture_output=True,
        text=True,
        check=False,
        timeout=30,
    )
    if generated.returncode != 0 or not generated.stdout:
        print(f"FAIL: {cli} hooks claude inject-settings exited {generated.returncode}: {generated.stderr}")
        return 1

    code, _argv, stderr, settings_text, validations = run_generated_settings_case(generated.stdout)
    failures = []
    if code != 0:
        failures.append(f"wrapper exited {code}: {stderr}")
    if settings_text != generated.stdout.rstrip("\n"):
        failures.append("Claude did not receive the CLI's settings document unchanged")
    if validations != 0:
        failures.append(
            "the CLI's inject-settings document took the Node validation path; update "
            "cmux_claude_build_standard_hook_settings in Resources/bin/cmux-claude-wrapper "
            "and generated_claude_hook_settings in tests/test_claude_wrapper_hooks.py "
            "to match CLI/CMUXCLI+ClaudeHookSettings.swift"
        )

    if failures:
        print("FAIL: generated settings fast path")
        for failure in failures:
            print(f"- {failure}")
        return 1
    print(f"PASS: {cli} inject-settings output takes the wrapper fast path")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
