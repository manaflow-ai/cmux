#!/usr/bin/env python3
"""
cmux Python Client

A client library for programmatically controlling cmux via Unix socket.

Usage:
    from cmux import cmux

    client = cmux()
    client.connect()

    # Send text to terminal
    client.send("echo hello\\n")

    # Send special keys
    client.send_key("ctrl-c")
    client.send_key("ctrl-d")

    # Tab management
    client.new_tab()
    client.list_tabs()
    client.select_tab(0)
    client.new_split("right")
    client.list_surfaces()
    client.focus_surface(0)

    client.close()
"""

import socket
import select
import os
import time
import errno
import glob
import re
from typing import Optional, List, Tuple, Union


class cmuxError(Exception):
    """Exception raised for cmux errors"""
    pass


_LAST_SOCKET_PATH_FILE = "/tmp/cmux-last-socket-path"
_DEFAULT_DEBUG_BUNDLE_ID = "com.cmux.app.debug"


def _sanitize_tag_slug(raw: str) -> str:
    cleaned = re.sub(r"[^a-z0-9]+", "-", (raw or "").strip().lower())
    cleaned = re.sub(r"-+", "-", cleaned).strip("-")
    return cleaned or "agent"


def _sanitize_bundle_suffix(raw: str) -> str:
    # Must match scripts/reload.sh sanitize_bundle() so tagged tests can
    # reliably target the correct app via AppleScript.
    cleaned = re.sub(r"[^a-z0-9]+", ".", (raw or "").strip().lower())
    cleaned = re.sub(r"\.+", ".", cleaned).strip(".")
    return cleaned or "agent"


def _quote_option_value(value: str) -> str:
    # Must match TerminalController.parseOptions() quoting rules.
    escaped = (value or "").replace("\\", "\\\\").replace('"', '\\"')
    return f"\"{escaped}\""


def _default_bundle_id() -> str:
    override = os.environ.get("CMUX_BUNDLE_ID")
    if override:
        return override

    tag = os.environ.get("CMUX_TAG")
    if tag:
        suffix = _sanitize_bundle_suffix(tag)
        return f"{_DEFAULT_DEBUG_BUNDLE_ID}.{suffix}"

    return _DEFAULT_DEBUG_BUNDLE_ID


def _read_last_socket_path() -> Optional[str]:
    try:
        with open(_LAST_SOCKET_PATH_FILE, "r", encoding="utf-8") as f:
            path = f.read().strip()
        if path:
            return path
    except OSError:
        pass
    return None


def _can_connect(path: str, timeout: float = 0.15, retries: int = 4) -> bool:
    # Best-effort check to avoid getting stuck on stale socket files.
    for _ in range(max(1, retries)):
        s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        try:
            s.settimeout(timeout)
            s.connect(path)
            return True
        except OSError:
            time.sleep(0.05)
        finally:
            try:
                s.close()
            except Exception:
                pass
    return False


def _default_socket_path() -> str:
    tag = os.environ.get("CMUX_TAG")
    if tag:
        slug = _sanitize_tag_slug(tag)
        tagged_candidates = [
            f"/tmp/cmux-debug-{slug}.sock",
            f"/tmp/cmux-{slug}.sock",
        ]
        for path in tagged_candidates:
            if os.path.exists(path) and _can_connect(path):
                return path
        # If nothing is connectable yet (e.g. the app is still starting),
        # fall back to the first existing candidate.
        for path in tagged_candidates:
            if os.path.exists(path):
                return path
        # Prefer the debug naming convention when we have to guess.
        return tagged_candidates[0]

    override = os.environ.get("CMUX_SOCKET_PATH")
    if override:
        if os.path.exists(override) and _can_connect(override):
            return override
        # Fall back to other heuristics if the override points at a stale socket file.
        if not os.path.exists(override):
            return override

    last_socket = _read_last_socket_path()
    if last_socket:
        if os.path.exists(last_socket) and _can_connect(last_socket):
            return last_socket

    # Prefer the non-tagged sockets when present.
    candidates = ["/tmp/cmux-debug.sock", "/tmp/cmux.sock"]
    for path in candidates:
        if os.path.exists(path) and _can_connect(path):
            return path

    # Otherwise, fall back to the newest tagged debug socket if there is one.
    tagged = glob.glob("/tmp/cmux-debug-*.sock")
    tagged = [p for p in tagged if os.path.exists(p)]
    if tagged:
        tagged.sort(key=lambda p: os.path.getmtime(p), reverse=True)
        for p in tagged:
            if _can_connect(p, timeout=0.1, retries=2):
                return p

    return candidates[0]


class cmux:
    """Client for controlling cmux via Unix socket"""

    @staticmethod
    def default_socket_path() -> str:
        return _default_socket_path()

    @staticmethod
    def default_bundle_id() -> str:
        return _default_bundle_id()

    def __init__(self, socket_path: str = None):
        # Resolve at init time so imports don't "lock in" a stale path.
        self.socket_path = socket_path or _default_socket_path()
        self._socket: Optional[socket.socket] = None
        self._recv_buffer: str = ""

    def connect(self) -> None:
        """Connect to the cmux socket"""
        if self._socket is not None:
            return

        start = time.time()
        while not os.path.exists(self.socket_path):
            if time.time() - start >= 2.0:
                raise cmuxError(
                    f"Socket not found at {self.socket_path}. "
                    "Is cmux running?"
                )
            time.sleep(0.1)

        last_error: Optional[socket.error] = None
        while True:
            self._socket = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            try:
                self._socket.connect(self.socket_path)
                self._socket.settimeout(5.0)
                return
            except socket.error as e:
                last_error = e
                self._socket.close()
                self._socket = None
                if e.errno in (errno.ECONNREFUSED, errno.ENOENT) and time.time() - start < 2.0:
                    time.sleep(0.1)
                    continue
                raise cmuxError(f"Failed to connect: {e}")

    def close(self) -> None:
        """Close the connection"""
        if self._socket is not None:
            self._socket.close()
            self._socket = None

    def __enter__(self):
        self.connect()
        return self

    def __exit__(self, exc_type, exc_val, exc_tb):
        self.close()
        return False

    def _send_command(self, command: str) -> str:
        """Send a command and receive response"""
        if self._socket is None:
            raise cmuxError("Not connected")

        try:
            self._socket.sendall((command + "\n").encode())
            data = self._recv_buffer
            self._recv_buffer = ""
            saw_newline = "\n" in data
            start = time.time()
            while True:
                if saw_newline:
                    ready, _, _ = select.select([self._socket], [], [], 0.1)
                    if not ready:
                        break
                try:
                    chunk = self._socket.recv(8192)
                except socket.timeout:
                    if saw_newline:
                        break
                    if time.time() - start >= 5.0:
                        raise cmuxError("Command timed out")
                    continue
                if not chunk:
                    break
                data += chunk.decode()
                if "\n" in data:
                    saw_newline = True
            if data.endswith("\n"):
                data = data[:-1]
            return data
        except socket.timeout:
            raise cmuxError("Command timed out")
        except socket.error as e:
            raise cmuxError(f"Socket error: {e}")

    def ping(self) -> bool:
        """Check if the server is responding"""
        response = self._send_command("ping")
        return response == "PONG"

    def list_tabs(self) -> List[Tuple[int, str, str, bool]]:
        """
        List all tabs.
        Returns list of (index, id, title, is_selected) tuples.
        """
        response = self._send_command("list_tabs")
        if response == "No tabs":
            return []

        tabs = []
        for line in response.split("\n"):
            if not line.strip():
                continue
            selected = line.startswith("*")
            parts = line.lstrip("* ").split(" ", 2)
            if len(parts) >= 3:
                index = int(parts[0].rstrip(":"))
                tab_id = parts[1]
                title = parts[2] if len(parts) > 2 else ""
                tabs.append((index, tab_id, title, selected))
        return tabs

    def new_tab(self) -> str:
        """Create a new tab. Returns the new tab's ID."""
        response = self._send_command("new_tab")
        if response.startswith("OK "):
            return response[3:]
        raise cmuxError(response)

    def new_split(self, direction: str) -> None:
        """Create a split in the given direction (left/right/up/down)."""
        response = self._send_command(f"new_split {direction}")
        if not response.startswith("OK"):
            raise cmuxError(response)

    def close_tab(self, tab_id: str) -> None:
        """Close a tab by ID"""
        response = self._send_command(f"close_tab {tab_id}")
        if not response.startswith("OK"):
            raise cmuxError(response)

    def select_tab(self, tab: Union[str, int]) -> None:
        """Select a tab by ID or index"""
        response = self._send_command(f"select_tab {tab}")
        if not response.startswith("OK"):
            raise cmuxError(response)

    def list_surfaces(self, tab: Union[str, int, None] = None) -> List[Tuple[int, str, bool]]:
        """
        List surfaces for a tab. Returns list of (index, id, is_focused) tuples.
        If tab is None, uses the current tab.
        """
        arg = "" if tab is None else str(tab)
        response = self._send_command(f"list_surfaces {arg}".rstrip())
        if response in ("No surfaces", "ERROR: Tab not found"):
            return []

        surfaces = []
        for line in response.split("\n"):
            if not line.strip():
                continue
            selected = line.startswith("*")
            parts = line.lstrip("* ").split(" ", 1)
            if len(parts) >= 2:
                index = int(parts[0].rstrip(":"))
                surface_id = parts[1]
                surfaces.append((index, surface_id, selected))
        return surfaces

    def focus_surface(self, surface: Union[str, int]) -> None:
        """Focus a surface by ID or index in the current tab."""
        response = self._send_command(f"focus_surface {surface}")
        if not response.startswith("OK"):
            raise cmuxError(response)

    def current_tab(self) -> str:
        """Get the current tab's ID"""
        response = self._send_command("current_tab")
        if response.startswith("ERROR"):
            raise cmuxError(response)
        return response

    def send(self, text: str) -> None:
        """
        Send text to the current terminal.
        Use \\n for newline (Enter), \\t for tab, etc.

        Note: The text is sent as-is. Use actual escape sequences:
            client.send("echo hello\\n")  # Sends: echo hello<Enter>
            client.send("echo hello" + "\\n")  # Same thing
        """
        # Escape actual newlines/tabs to their backslash forms for protocol
        # The server will unescape them
        escaped = text.replace("\n", "\\n").replace("\r", "\\r").replace("\t", "\\t")
        response = self._send_command(f"send {escaped}")
        if not response.startswith("OK"):
            raise cmuxError(response)

    def send_surface(self, surface: Union[str, int], text: str) -> None:
        """Send text to a specific surface by ID or index in the current tab."""
        escaped = text.replace("\n", "\\n").replace("\r", "\\r").replace("\t", "\\t")
        response = self._send_command(f"send_surface {surface} {escaped}")
        if not response.startswith("OK"):
            raise cmuxError(response)

    def send_key(self, key: str) -> None:
        """
        Send a special key to the current terminal.

        Supported keys:
            ctrl-c, ctrl-d, ctrl-z, ctrl-\\
            enter, tab, escape, backspace
            ctrl-<letter> for any letter
        """
        response = self._send_command(f"send_key {key}")
        if not response.startswith("OK"):
            raise cmuxError(response)

    def send_key_surface(self, surface: Union[str, int], key: str) -> None:
        """Send a special key to a specific surface by ID or index in the current tab."""
        response = self._send_command(f"send_key_surface {surface} {key}")
        if not response.startswith("OK"):
            raise cmuxError(response)

    def send_line(self, text: str) -> None:
        """Send text followed by Enter"""
        self.send(text + "\\n")

    def send_ctrl_c(self) -> None:
        """Send Ctrl+C (SIGINT)"""
        self.send_key("ctrl-c")

    def send_ctrl_d(self) -> None:
        """Send Ctrl+D (EOF)"""
        self.send_key("ctrl-d")

    def help(self) -> str:
        """Get help text from server"""
        return self._send_command("help")

    def notify(self, title: str, subtitle: str = "", body: str = "") -> None:
        """Create a notification for the focused surface."""
        if subtitle or body:
            payload = f"{title}|{subtitle}|{body}"
        else:
            payload = title
        response = self._send_command(f"notify {payload}")
        if not response.startswith("OK"):
            raise cmuxError(response)

    def notify_surface(self, surface: Union[str, int], title: str, subtitle: str = "", body: str = "") -> None:
        """Create a notification for a specific surface by ID or index."""
        if subtitle or body:
            payload = f"{title}|{subtitle}|{body}"
        else:
            payload = title
        response = self._send_command(f"notify_surface {surface} {payload}")
        if not response.startswith("OK"):
            raise cmuxError(response)

    def list_notifications(self) -> list[dict]:
        """
        List notifications.
        Returns list of dicts with keys: id, tab_id, surface_id, is_read, title, subtitle, body.
        """
        response = self._send_command("list_notifications")
        if response == "No notifications":
            return []

        items = []
        for line in response.split("\n"):
            if not line.strip():
                continue
            _, payload = line.split(":", 1)
            parts = payload.split("|", 6)
            if len(parts) < 7:
                continue
            notif_id, tab_id, surface_id, read_text, title, subtitle, body = parts
            items.append({
                "id": notif_id,
                "tab_id": tab_id,
                "surface_id": None if surface_id == "none" else surface_id,
                "is_read": read_text == "read",
                "title": title,
                "subtitle": subtitle,
                "body": body,
            })
        return items

    def clear_notifications(self) -> None:
        """Clear all notifications."""
        response = self._send_command("clear_notifications")
        if not response.startswith("OK"):
            raise cmuxError(response)

    def set_app_focus(self, active: Union[bool, None]) -> None:
        """Override app focus state. Use None to clear override."""
        if active is None:
            value = "clear"
        else:
            value = "active" if active else "inactive"
        response = self._send_command(f"set_app_focus {value}")
        if not response.startswith("OK"):
            raise cmuxError(response)

    def simulate_app_active(self) -> None:
        """Trigger the app active handler."""
        response = self._send_command("simulate_app_active")
        if not response.startswith("OK"):
            raise cmuxError(response)

    def set_status(self, key: str, value: str, icon: str = None, color: str = None, tab: str = None) -> None:
        """Set a sidebar status entry."""
        # Put options before `--` so value can contain arbitrary tokens like `--tab`.
        cmd = f"set_status {key}"
        if icon:
            cmd += f" --icon={icon}"
        if color:
            cmd += f" --color={color}"
        if tab:
            cmd += f" --tab={tab}"
        cmd += f" -- {_quote_option_value(value)}"
        response = self._send_command(cmd)
        if not response.startswith("OK"):
            raise cmuxError(response)

    def clear_status(self, key: str, tab: str = None) -> None:
        """Remove a sidebar status entry."""
        cmd = f"clear_status {key}"
        if tab:
            cmd += f" --tab={tab}"
        response = self._send_command(cmd)
        if not response.startswith("OK"):
            raise cmuxError(response)

    def log(self, message: str, level: str = None, source: str = None, tab: str = None) -> None:
        """Append a sidebar log entry."""
        # TerminalController.parseOptions treats any --* token as an option until
        # a `--` separator. Put options first and then use `--` so messages can
        # contain arbitrary tokens like `--force`.
        cmd = "log"
        if level:
            cmd += f" --level={level}"
        if source:
            cmd += f" --source={source}"
        if tab:
            cmd += f" --tab={tab}"
        cmd += f" -- {_quote_option_value(message)}"
        response = self._send_command(cmd)
        if not response.startswith("OK"):
            raise cmuxError(response)

    def set_progress(self, value: float, label: str = None, tab: str = None) -> None:
        """Set sidebar progress bar (0.0-1.0)."""
        cmd = f"set_progress {value}"
        if label:
            cmd += f" --label={_quote_option_value(label)}"
        if tab:
            cmd += f" --tab={tab}"
        response = self._send_command(cmd)
        if not response.startswith("OK"):
            raise cmuxError(response)

    def clear_progress(self, tab: str = None) -> None:
        """Clear sidebar progress bar."""
        cmd = "clear_progress"
        if tab:
            cmd += f" --tab={tab}"
        response = self._send_command(cmd)
        if not response.startswith("OK"):
            raise cmuxError(response)

    def report_git_branch(self, branch: str, status: str = None, tab: str = None) -> None:
        """Report git branch for sidebar display."""
        cmd = f"report_git_branch {branch}"
        if status:
            cmd += f" --status={status}"
        if tab:
            cmd += f" --tab={tab}"
        response = self._send_command(cmd)
        if not response.startswith("OK"):
            raise cmuxError(response)

    def report_ports(self, *ports: int, tab: str = None) -> None:
        """Report listening ports for sidebar display."""
        port_str = " ".join(str(p) for p in ports)
        cmd = f"report_ports {port_str}"
        if tab:
            cmd += f" --tab={tab}"
        response = self._send_command(cmd)
        if not response.startswith("OK"):
            raise cmuxError(response)

    def clear_ports(self, tab: str = None) -> None:
        """Clear listening ports for sidebar display."""
        cmd = "clear_ports"
        if tab:
            cmd += f" --tab={tab}"
        response = self._send_command(cmd)
        if not response.startswith("OK"):
            raise cmuxError(response)

    def sidebar_state(self, tab: str = None) -> str:
        """Dump all sidebar metadata for a tab."""
        cmd = "sidebar_state"
        if tab:
            cmd += f" --tab={tab}"
        return self._send_command(cmd)

    def reset_sidebar(self, tab: str = None) -> None:
        """Clear all sidebar metadata for a tab."""
        cmd = "reset_sidebar"
        if tab:
            cmd += f" --tab={tab}"
        response = self._send_command(cmd)
        if not response.startswith("OK"):
            raise cmuxError(response)

    def focus_notification(self, tab: Union[str, int], surface: Union[str, int, None] = None) -> None:
        """Focus tab/surface using the notification flow."""
        if surface is None:
            command = f"focus_notification {tab}"
        else:
            command = f"focus_notification {tab} {surface}"
        response = self._send_command(command)
        if not response.startswith("OK"):
            raise cmuxError(response)

    def flash_count(self, surface: Union[str, int]) -> int:
        """Get flash count for a surface by ID or index."""
        response = self._send_command(f"flash_count {surface}")
        if response.startswith("OK "):
            return int(response.split(" ", 1)[1])
        raise cmuxError(response)

    def reset_flash_counts(self) -> None:
        """Reset flash counters."""
        response = self._send_command("reset_flash_counts")
        if not response.startswith("OK"):
            raise cmuxError(response)

    def read_screen(self) -> str:
        """Read the visible terminal text from the focused surface."""
        return self._send_command("read_screen")


def main():
    """CLI interface for cmux"""
    import sys
    import argparse

    parser = argparse.ArgumentParser(description="cmux CLI")
    parser.add_argument("command", nargs="?", help="Command to send")
    parser.add_argument("args", nargs="*", help="Command arguments")
    parser.add_argument("-s", "--socket", default=None,
                        help="Socket path (default: auto-detect)")

    args = parser.parse_args()

    try:
        with cmux(args.socket) as client:
            if not args.command:
                # Interactive mode
                print("cmux CLI (type 'help' for commands, 'quit' to exit)")
                while True:
                    try:
                        line = input("> ").strip()
                        if line.lower() in ("quit", "exit"):
                            break
                        if line:
                            response = client._send_command(line)
                            print(response)
                    except EOFError:
                        break
                    except KeyboardInterrupt:
                        print()
                        break
            else:
                # Single command mode
                command = args.command
                if args.args:
                    command += " " + " ".join(args.args)
                response = client._send_command(command)
                print(response)
    except cmuxError as e:
        print(f"Error: {e}", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
