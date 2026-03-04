#!/usr/bin/env python3
"""Regression guard for CMUXTERM-MACOS-2VZ (socket listener unhealthy dedupe)."""

from __future__ import annotations

import subprocess
from pathlib import Path


def get_repo_root() -> Path:
    result = subprocess.run(
        ["git", "rev-parse", "--show-toplevel"],
        capture_output=True,
        text=True,
    )
    if result.returncode == 0:
        return Path(result.stdout.strip())
    return Path.cwd()


def read_text(path: Path) -> str:
    return path.read_text(encoding="utf-8")


def require(content: str, needle: str, message: str, failures: list[str]) -> None:
    if needle not in content:
        failures.append(message)


def main() -> int:
    repo_root = get_repo_root()
    app_delegate_path = repo_root / "Sources" / "AppDelegate.swift"
    if not app_delegate_path.exists():
        print(f"Missing expected file: {app_delegate_path}")
        return 1

    app_delegate = read_text(app_delegate_path)
    failures: list[str] = []

    require(
        app_delegate,
        "lastSocketListenerUnhealthySignature",
        "AppDelegate is missing signature tracking for unhealthy socket captures",
        failures,
    )
    require(
        app_delegate,
        "socketListenerUnhealthyUnchangedCaptureCooldown",
        "AppDelegate is missing a separate cooldown for unchanged unhealthy socket state",
        failures,
    )
    require(
        app_delegate,
        "private static func socketListenerUnhealthySignature(",
        "Missing helper that computes an unhealthy socket signature",
        failures,
    )
    require(
        app_delegate,
        "guard let config = socketListenerConfigurationIfEnabled() else {",
        "Health monitor no longer handles disabled socket configuration explicitly",
        failures,
    )
    require(
        app_delegate,
        "lastSocketListenerUnhealthySignature = nil",
        "Healthy socket state no longer resets unhealthy signature tracking",
        failures,
    )
    require(
        app_delegate,
        "let signatureChanged = signature != lastSocketListenerUnhealthySignature",
        "Capture logic no longer detects unhealthy signature changes",
        failures,
    )
    require(
        app_delegate,
        "let captureCooldown = signatureChanged",
        "Capture cooldown no longer depends on unhealthy signature changes",
        failures,
    )
    require(
        app_delegate,
        "captureData[\"signature\"] = signature",
        "Capture payload no longer includes unhealthy signature for diagnostics",
        failures,
    )

    if failures:
        print("FAIL: issue 2VZ regression(s) detected")
        for failure in failures:
            print(f"- {failure}")
        return 1

    print("PASS: issue 2VZ socket listener unhealthy dedupe guards are present")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
