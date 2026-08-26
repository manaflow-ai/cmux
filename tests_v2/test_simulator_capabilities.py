#!/usr/bin/env python3
"""Simulator RPC methods must be discoverable through system.capabilities."""

import os
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from cmux import cmux, cmuxError


SOCKET_PATH = os.environ.get("CMUX_SOCKET_PATH", "/tmp/cmux-debug.sock")

EXPECTED_SIMULATOR_METHODS = {
    "simulator.type",
    "simulator.web_inspector.targets",
    "simulator.web_inspector.attach",
    "simulator.web_inspector.send",
    "simulator.web_inspector.highlight",
    "simulator.web_inspector.release",
    "simulator.context",
    "simulator.select_device",
    "simulator.recover",
    "simulator.gesture",
    "simulator.multi_touch",
    "simulator.tap",
    "simulator.swipe",
    "simulator.button",
    "simulator.rotate",
    "simulator.core_animation",
    "simulator.memory_warning",
    "simulator.event_log",
    "simulator.tools",
    "simulator.camera.configure",
    "simulator.camera.switch",
    "simulator.camera.mirror",
    "simulator.camera.status",
    "simulator.permissions.read",
    "simulator.permissions.set",
    "simulator.ui.status",
    "simulator.ui.set",
    "simulator.accessibility",
    "simulator.foreground",
}


def main() -> int:
    with cmux(SOCKET_PATH) as client:
        advertised = set(client.capabilities().get("methods") or [])

    missing = sorted(EXPECTED_SIMULATOR_METHODS - advertised)
    if missing:
        raise cmuxError(f"Missing Simulator methods in system.capabilities: {missing}")

    print("PASS: system.capabilities advertises every Simulator RPC method")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
