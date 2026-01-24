#!/usr/bin/env python3
"""
Automated test for ctrl+enter keybind using real keystrokes.

Requires:
  - GhosttyTabs running
  - Accessibility permissions for System Events (osascript)
  - keybind = ctrl+enter=text:\\r (or \\n/\\x0d) configured in Ghostty config
"""

import os
import sys
import time
import subprocess
from pathlib import Path

# Add the directory containing ghosttytabs.py to the path
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from ghosttytabs import GhosttyTabs, GhosttyTabsError


def run_osascript(script: str) -> None:
    subprocess.run(["osascript", "-e", script], check=True)


def has_ctrl_enter_keybind(config_text: str) -> bool:
    for line in config_text.splitlines():
        stripped = line.strip()
        if not stripped or stripped.startswith("#"):
            continue
        if "ctrl+enter" in stripped and "text:" in stripped:
            if "\\r" in stripped or "\\n" in stripped or "\\x0d" in stripped:
                return True
    return False


def find_config_with_keybind() -> Path | None:
    home = Path.home()
    candidates = [
        home / "Library/Application Support/com.mitchellh.ghostty/config.ghostty",
        home / "Library/Application Support/com.mitchellh.ghostty/config",
        home / ".config/ghostty/config.ghostty",
        home / ".config/ghostty/config",
    ]
    for path in candidates:
        if not path.exists():
            continue
        try:
            if has_ctrl_enter_keybind(path.read_text(encoding="utf-8")):
                return path
        except OSError:
            continue
    return None


def test_ctrl_enter_keybind(client: GhosttyTabs) -> tuple[bool, str]:
    marker = Path("/tmp") / f"ghostty_ctrl_enter_{os.getpid()}"
    marker.unlink(missing_ok=True)

    # Create a fresh tab to avoid interfering with existing sessions
    new_tab_id = client.new_tab()
    client.select_tab(new_tab_id)
    time.sleep(0.3)

    # Make sure the app is focused for keystrokes
    run_osascript('tell application "GhosttyTabs" to activate')
    time.sleep(0.2)

    # Clear any running command
    try:
        client.send_key("ctrl-c")
        time.sleep(0.2)
    except Exception:
        pass

    # Type the command (without pressing Enter)
    run_osascript(f'tell application "System Events" to keystroke "touch {marker}"')
    time.sleep(0.1)

    # Send Ctrl+Enter (key code 36 = Return)
    run_osascript('tell application "System Events" to key code 36 using control down')
    time.sleep(0.5)

    ok = marker.exists()
    if ok:
        marker.unlink(missing_ok=True)
    try:
        client.close_tab(new_tab_id)
    except Exception:
        pass
    return ok, ("Ctrl+Enter keybind executed command" if ok else "Marker not created by Ctrl+Enter")


def run_tests() -> int:
    print("=" * 60)
    print("GhosttyTabs Ctrl+Enter Keybind Test")
    print("=" * 60)
    print()

    socket_path = GhosttyTabs.DEFAULT_SOCKET_PATH
    if not os.path.exists(socket_path):
        print(f"Error: Socket not found at {socket_path}")
        print("Please make sure GhosttyTabs is running.")
        return 1

    config_path = find_config_with_keybind()
    if not config_path:
        print("Error: Required keybind not found in Ghostty config.")
        print("Add a line like:")
        print("  keybind = ctrl+enter=text:\\r")
        print("Then restart GhosttyTabs and re-run this test.")
        return 1

    print(f"Using keybind from: {config_path}")
    print()

    try:
        with GhosttyTabs() as client:
            ok, message = test_ctrl_enter_keybind(client)
            status = "✅" if ok else "❌"
            print(f"{status} {message}")
            return 0 if ok else 1
    except GhosttyTabsError as e:
        print(f"Error: {e}")
        return 1
    except subprocess.CalledProcessError as e:
        print(f"Error: osascript failed: {e}")
        return 1


if __name__ == "__main__":
    sys.exit(run_tests())
