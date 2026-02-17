#!/usr/bin/env python3
"""
Automated test for ctrl+enter keybind using real keystrokes.

Requires:
  - cmux running
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


class SkipTest(Exception):
    """Raised to skip this test when the environment can't support it."""

def infer_app_name_for_osascript(socket_path: str) -> str:
    """
    Infer the app display name from the socket path.

    Examples:
      - /tmp/cmux-debug.sock          -> "cmux DEV"
      - /tmp/cmux-debug-foo.sock      -> "cmux DEV foo"
      - /tmp/cmux.sock                -> "cmux"
      - /tmp/cmux-foo.sock            -> "cmux foo"
    """
    base = Path(socket_path).name
    if base.startswith("cmux-debug") and base.endswith(".sock"):
        suffix = base[len("cmux-debug") : -len(".sock")]
        if suffix.startswith("-") and suffix[1:]:
            return f"cmux DEV {suffix[1:]}"
        return "cmux DEV"
    if base.startswith("cmux") and base.endswith(".sock"):
        suffix = base[len("cmux") : -len(".sock")]
        if suffix.startswith("-") and suffix[1:]:
            return f"cmux {suffix[1:]}"
        return "cmux"
    # Fallback: tests usually run against Debug builds.
    return "cmux DEV"


def run_osascript(script: str) -> None:
    # Use capture_output so we can detect the common "keystrokes not allowed" error
    # in SSH / non-interactive environments without Accessibility permissions.
    proc = subprocess.run(
        ["osascript", "-e", script],
        capture_output=True,
        text=True,
    )
    if proc.returncode == 0:
        return

    combined = (proc.stdout or "") + (proc.stderr or "")
    if "not allowed to send keystrokes" in combined:
        raise SkipTest("osascript is not allowed to send keystrokes (Accessibility permissions missing).")

    raise subprocess.CalledProcessError(
        proc.returncode,
        proc.args,
        output=proc.stdout,
        stderr=proc.stderr,
    )


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
    new_workspace_id = client.new_workspace()
    client.select_workspace(new_workspace_id)
    time.sleep(0.3)

    # Make sure the app is focused for keystrokes
    app_name = infer_app_name_for_osascript(client.socket_path)
    run_osascript(f'tell application "{app_name}" to activate')
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
        client.close_workspace(new_workspace_id)
    except Exception:
        pass
    return ok, ("Ctrl+Enter keybind executed command" if ok else "Marker not created by Ctrl+Enter")


def run_tests() -> int:
    print("=" * 60)
    print("cmux Ctrl+Enter Keybind Test")
    print("=" * 60)
    print()

    socket_path = cmux.DEFAULT_SOCKET_PATH
    if not os.path.exists(socket_path):
        print(f"Error: Socket not found at {socket_path}")
        print("Please make sure cmux is running.")
        return 1

    config_path = find_config_with_keybind()
    if not config_path:
        print("SKIP: Required keybind not found in Ghostty config.")
        print("Add a line like `keybind = ctrl+enter=text:\\r` to enable this test.")
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
        print(f"Error: {e}")
        return 1
    except SkipTest as e:
        print(f"SKIP: {e}")
        return 0
    except subprocess.CalledProcessError as e:
        print(f"Error: osascript failed: {e}")
        return 1


if __name__ == "__main__":
    sys.exit(run_tests())
