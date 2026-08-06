#!/usr/bin/env python3
"""Keep debug mobile transport request handling out of TerminalController.swift."""

from __future__ import annotations

from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
CONTROLLER = ROOT / "Sources" / "TerminalController.swift"
DEBUG_HANDLER = ROOT / "Sources" / "Debug" / "TerminalController+MobileTransportDebug.swift"
PROJECT = ROOT / "cmux.xcodeproj" / "project.pbxproj"


def main() -> None:
    controller = CONTROLLER.read_text(encoding="utf-8")
    if "debugCloseConnections(connectionID:" in controller:
        raise AssertionError("TerminalController.swift still owns the debug transport operation")
    if 'message: "connection_id must be a UUID"' in controller:
        raise AssertionError("TerminalController.swift still owns debug transport request parsing")

    if not DEBUG_HANDLER.is_file():
        raise AssertionError(f"missing dedicated debug handler: {DEBUG_HANDLER.relative_to(ROOT)}")
    handler = DEBUG_HANDLER.read_text(encoding="utf-8")
    for snippet in (
        "#if DEBUG",
        "v2DebugMobileTransportDisconnect",
        "debugCloseConnections(connectionID:",
        'message: "connection_id must be a UUID"',
    ):
        if snippet not in handler:
            raise AssertionError(f"dedicated debug handler is missing: {snippet}")

    project = PROJECT.read_text(encoding="utf-8")
    if project.count("TerminalController+MobileTransportDebug.swift") < 3:
        raise AssertionError("dedicated debug handler is not fully wired into the Xcode target")

    print("PASS: debug mobile transport parsing and execution live in Sources/Debug")


if __name__ == "__main__":
    main()
