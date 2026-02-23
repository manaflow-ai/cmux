#!/usr/bin/env python3
"""Regression test for command-palette update command wiring."""

from __future__ import annotations

import re
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


def expect_regex(content: str, pattern: str, message: str, failures: list[str]) -> None:
    if re.search(pattern, content, flags=re.DOTALL) is None:
        failures.append(message)


def main() -> int:
    repo_root = get_repo_root()
    content_view_path = repo_root / "Sources" / "ContentView.swift"
    app_delegate_path = repo_root / "Sources" / "AppDelegate.swift"
    controller_path = repo_root / "Sources" / "Update" / "UpdateController.swift"

    missing_paths = [
        str(path)
        for path in [content_view_path, app_delegate_path, controller_path]
        if not path.exists()
    ]
    if missing_paths:
        print("Missing expected files:")
        for path in missing_paths:
            print(f"  - {path}")
        return 1

    content_view = read_text(content_view_path)
    app_delegate = read_text(app_delegate_path)
    controller = read_text(controller_path)

    failures: list[str] = []

    expect_regex(
        content_view,
        r'static\s+let\s+updateHasAvailable\s*=\s*"update\.hasAvailable"',
        "Missing `CommandPaletteContextKeys.updateHasAvailable`",
        failures,
    )
    expect_regex(
        content_view,
        r'if\s+case\s+\.updateAvailable\s*=\s*updateViewModel\.effectiveState\s*\{\s*snapshot\.setBool\(CommandPaletteContextKeys\.updateHasAvailable,\s*true\)\s*\}',
        "Command palette context no longer tracks update-available state",
        failures,
    )
    expect_regex(
        content_view,
        r'commandId:\s*"palette\.applyUpdateIfAvailable".*?title:\s*constant\("Apply Update \(If Available\)"\).*?keywords:\s*\[[^\]]*"apply"[^\]]*"install"[^\]]*"update"[^\]]*"available"[^\]]*\].*?when:\s*\{\s*\$0\.bool\(CommandPaletteContextKeys\.updateHasAvailable\)\s*\}',
        "Missing or incomplete `palette.applyUpdateIfAvailable` contribution visibility gating",
        failures,
    )
    expect_regex(
        content_view,
        r'commandId:\s*"palette\.attemptUpdate".*?title:\s*constant\("Attempt Update"\).*?keywords:\s*\[[^\]]*"attempt"[^\]]*"check"[^\]]*"update"[^\]]*\]',
        "Missing or incomplete `palette.attemptUpdate` contribution",
        failures,
    )
    expect_regex(
        content_view,
        r'registry\.register\(commandId:\s*"palette\.applyUpdateIfAvailable"\)\s*\{\s*AppDelegate\.shared\?\.applyUpdateIfAvailable\(nil\)\s*\}',
        "Missing handler registration for `palette.applyUpdateIfAvailable`",
        failures,
    )
    expect_regex(
        content_view,
        r'registry\.register\(commandId:\s*"palette\.attemptUpdate"\)\s*\{\s*AppDelegate\.shared\?\.attemptUpdate\(nil\)\s*\}',
        "Missing handler registration for `palette.attemptUpdate`",
        failures,
    )

    expect_regex(
        app_delegate,
        r'@objc\s+func\s+applyUpdateIfAvailable\(_\s+sender:\s+Any\?\)\s*\{\s*updateViewModel\.overrideState\s*=\s*nil\s*updateController\.installUpdate\(\)\s*\}',
        "`AppDelegate.applyUpdateIfAvailable` is missing or does not call `updateController.installUpdate()`",
        failures,
    )
    expect_regex(
        app_delegate,
        r'@objc\s+func\s+attemptUpdate\(_\s+sender:\s+Any\?\)\s*\{\s*updateViewModel\.overrideState\s*=\s*nil\s*updateController\.attemptUpdate\(\)\s*\}',
        "`AppDelegate.attemptUpdate` is missing or does not call `updateController.attemptUpdate()`",
        failures,
    )

    expect_regex(
        controller,
        r'func\s+attemptUpdate\(\)\s*\{',
        "`UpdateController.attemptUpdate()` is missing",
        failures,
    )
    if "state.confirm()" not in controller:
        failures.append("`UpdateController.attemptUpdate()` no longer auto-confirms update installation")
    if "checkForUpdates()" not in controller:
        failures.append("`UpdateController.attemptUpdate()` no longer triggers a check before install")

    if failures:
        print("FAIL: command-palette update command regression(s) detected")
        for failure in failures:
            print(f"- {failure}")
        return 1

    print("PASS: command-palette update commands expose apply + attempt wiring")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
