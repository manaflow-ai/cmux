#!/usr/bin/env python3
"""
Automated test for ctrl+enter keybind using real keystrokes.

Requires:
  - cmuxterm running
  - Accessibility permissions for System Events (osascript)
  - keybind = ctrl+enter=text:\\r (or \\n/\\x0d) configured in Ghostty config
"""

import os
import sys
import time
import subprocess
from pathlib import Path
from typing import Optional

# Add the directory containing cmux.py to the path
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from cmux import cmux, cmuxError


def run_osascript(script: str) -> subprocess.CompletedProcess[str]:
    # Use capture_output so we can detect common permission failures and skip.
    result = subprocess.run(
        ["osascript", "-e", script],
        capture_output=True,
        text=True,
    )
    if result.returncode != 0:
        raise subprocess.CalledProcessError(
            result.returncode,
            result.args,
            output=result.stdout,
            stderr=result.stderr,
        )
    return result


def is_keystroke_permission_error(err: subprocess.CalledProcessError) -> bool:
    text = f"{getattr(err, 'stderr', '') or ''}\n{getattr(err, 'output', '') or ''}"
    return "not allowed to send keystrokes" in text or "(1002)" in text


def has_ctrl_enter_keybind(config_text: str) -> bool:
    for line in config_text.splitlines():
        stripped = line.strip()
        if not stripped or stripped.startswith("#"):
            continue
        if "ctrl+enter" in stripped and "text:" in stripped:
            if "\\r" in stripped or "\\n" in stripped or "\\x0d" in stripped:
                return True
    return False


def find_config_with_keybind() -> Optional[Path]:
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


def test_ctrl_enter_keybind(client: cmux) -> tuple[bool, str]:
    marker = Path("/tmp") / f"ghostty_ctrl_enter_{os.getpid()}"
    marker.unlink(missing_ok=True)

    # Create a fresh tab to avoid interfering with existing sessions
    new_tab_id = client.new_tab()
    client.select_tab(new_tab_id)
    time.sleep(0.3)
    try:
        # Make sure the app is focused for keystrokes
        bundle_id = cmux.default_bundle_id()
        run_osascript(f'tell application id "{bundle_id}" to activate')
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
        return ok, ("Ctrl+Enter keybind executed command" if ok else "Marker not created by Ctrl+Enter")
    finally:
        if marker.exists():
            marker.unlink(missing_ok=True)
        try:
            client.close_tab(new_tab_id)
        except Exception:
            pass


def run_tests() -> int:
    print("=" * 60)
    print("cmuxterm Ctrl+Enter Keybind Test")
    print("=" * 60)
    print()

    socket_path = cmux.default_socket_path()
    if not os.path.exists(socket_path):
        print(f"SKIP: Socket not found at {socket_path}")
        print("Tip: start cmuxterm first (or set CMUX_TAG / CMUX_SOCKET_PATH).")
        return 0

    config_path = find_config_with_keybind()
    if not config_path:
        print("SKIP: Required keybind not found in Ghostty config.")
        print("Expected a line like: keybind = ctrl+enter=text:\\r")
        return 0

    print(f"Using keybind from: {config_path}")
    print()

    try:
        with cmux() as client:
            ok, message = test_ctrl_enter_keybind(client)
            status = "✅" if ok else "❌"
            print(f"{status} {message}")
            return 0 if ok else 1
    except cmuxError as e:
        print(f"SKIP: {e}")
        return 0
    except subprocess.CalledProcessError as e:
        if is_keystroke_permission_error(e):
            print("SKIP: osascript/System Events not allowed to send keystrokes (Accessibility permission missing)")
            return 0
        print(f"Error: osascript failed: {e}")
        if getattr(e, "stderr", None):
            print(e.stderr.strip())
        if getattr(e, "output", None):
            print(e.output.strip())
        return 1


if __name__ == "__main__":
    sys.exit(run_tests())
