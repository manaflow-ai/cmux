#!/usr/bin/env python3
"""Regression test: cmux advertises and allows microphone access."""

from __future__ import annotations

import plistlib
import subprocess
from pathlib import Path


def get_repo_root() -> Path:
    result = subprocess.run(
        ["git", "rev-parse", "--show-toplevel"],
        capture_output=True,
        text=True,
        check=False,
    )
    if result.returncode == 0:
        return Path(result.stdout.strip())
    return Path.cwd()


def load_plist(path: Path, failures: list[str]) -> dict:
    if not path.exists():
        failures.append(f"Missing expected file: {path}")
        return {}
    with path.open("rb") as f:
        return plistlib.load(f)


def main() -> int:
    repo_root = get_repo_root()
    failures: list[str] = []

    info = load_plist(repo_root / "Resources" / "Info.plist", failures)
    entitlements = load_plist(repo_root / "cmux.entitlements", failures)

    mic_usage = info.get("NSMicrophoneUsageDescription")
    if not isinstance(mic_usage, str) or not mic_usage.strip():
        failures.append(
            "Resources/Info.plist must define a non-empty NSMicrophoneUsageDescription"
        )
    elif mic_usage.strip() != "A program running within cmux would like to use your microphone.":
        failures.append(
            "Resources/Info.plist NSMicrophoneUsageDescription should match the Ghostty-style wording"
        )

    if entitlements.get("com.apple.security.device.audio-input") is not True:
        failures.append(
            "cmux.entitlements must set com.apple.security.device.audio-input to true"
        )

    if failures:
        print("FAIL: microphone access metadata regression(s) detected")
        for failure in failures:
            print(f"- {failure}")
        return 1

    print("PASS: microphone usage description and entitlement are present")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
