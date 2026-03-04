#!/usr/bin/env python3
"""Regression test for command-palette socket-listener restart command wiring."""

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
    content_view_path = repo_root / "Sources" / "ContentView.swift"
    app_delegate_path = repo_root / "Sources" / "AppDelegate.swift"

    missing_paths = [
        str(path)
        for path in [content_view_path, app_delegate_path]
        if not path.exists()
    ]
    if missing_paths:
        print("Missing expected files:")
        for path in missing_paths:
            print(f"  - {path}")
        return 1

    content_view = read_text(content_view_path)
    app_delegate = read_text(app_delegate_path)

    failures: list[str] = []

    require(
        content_view,
        'commandId: "palette.restartSocketListener"',
        "Missing `palette.restartSocketListener` command contribution",
        failures,
    )
    require(
        content_view,
        'title: constant("Restart CLI Listener")',
        "Missing `Restart CLI Listener` command title",
        failures,
    )
    require(
        content_view,
        'registry.register(commandId: "palette.restartSocketListener") {',
        "Missing command handler registration for `palette.restartSocketListener`",
        failures,
    )
    require(
        content_view,
        "AppDelegate.shared?.restartSocketListener(nil)",
        "Socket restart command handler does not call `AppDelegate.restartSocketListener`",
        failures,
    )

    require(
        app_delegate,
        "@objc func restartSocketListener(_ sender: Any?) {",
        "Missing `AppDelegate.restartSocketListener` action",
        failures,
    )
    require(
        app_delegate,
        "private func socketListenerConfigurationIfEnabled() -> (mode: SocketControlMode, path: String)? {",
        "Missing shared socket listener configuration helper",
        failures,
    )
    require(
        app_delegate,
        'restartSocketListenerIfEnabled(source: "menu.command")',
        "`restartSocketListener` no longer delegates to restart helper",
        failures,
    )
    require(
        app_delegate,
        "TerminalController.shared.stop()",
        "`restartSocketListenerIfEnabled` no longer stops current listener before restart",
        failures,
    )
    require(
        app_delegate,
        "TerminalController.shared.start(tabManager: tabManager, socketPath: config.path, accessMode: config.mode)",
        "`restartSocketListenerIfEnabled` no longer starts listener with current settings",
        failures,
    )

    if failures:
        print("FAIL: command-palette socket restart command regression(s) detected")
        for failure in failures:
            print(f"- {failure}")
        return 1

    print("PASS: command-palette socket restart command wiring is intact")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
