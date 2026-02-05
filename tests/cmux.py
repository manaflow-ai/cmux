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
from typing import Optional, List, Tuple, Union


class cmuxError(Exception):
    """Exception raised for cmux errors"""
    pass


def _default_socket_path() -> str:
    override = os.environ.get("CMUX_SOCKET_PATH")
    if override:
        return override
    candidates = ["/tmp/cmuxterm-debug.sock", "/tmp/cmuxterm.sock"]
    for path in candidates:
        if os.path.exists(path):
            return path
    return candidates[0]


class cmux:
    """Client for controlling cmux via Unix socket"""

    DEFAULT_SOCKET_PATH = _default_socket_path()

    def __init__(self, socket_path: str = None):
        self.socket_path = socket_path or self.DEFAULT_SOCKET_PATH
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

    # Bonsplit pane commands

    def list_panes(self) -> List[Tuple[int, str, int, bool]]:
        """
        List all panes in the current sidebar tab.
        Returns list of (index, pane_id, tab_count, is_focused) tuples.
        """
        response = self._send_command("list_panes")
        if response in ("No panes", "ERROR: No tab selected"):
            return []

        panes = []
        for line in response.split("\n"):
            if not line.strip():
                continue
            selected = line.startswith("*")
            # Format: "* 0: <pane_id> [N tabs]" or "  0: <pane_id> [N tabs]"
            parts = line.lstrip("* ").split()
            if len(parts) >= 4:
                index = int(parts[0].rstrip(":"))
                pane_id = parts[1]
                # Extract tab count from "[N tabs]"
                tab_count = int(parts[2].lstrip("["))
                panes.append((index, pane_id, tab_count, selected))
        return panes

    def focus_pane(self, pane: Union[str, int]) -> None:
        """Focus a pane by ID or index in the current sidebar tab."""
        response = self._send_command(f"focus_pane {pane}")
        if not response.startswith("OK"):
            raise cmuxError(response)

    def list_bonsplit_tabs(self, pane: Union[str, int, None] = None) -> List[Tuple[int, str, str, bool]]:
        """
        List bonsplit tabs in a pane.
        Returns list of (index, tab_id, title, is_selected) tuples.
        If pane is None, uses the focused pane.
        """
        if pane is not None:
            response = self._send_command(f"list_bonsplit_tabs --pane={pane}")
        else:
            response = self._send_command("list_bonsplit_tabs")

        if "ERROR" in response or response == "No tabs":
            return []

        tabs = []
        for line in response.split("\n"):
            if not line.strip():
                continue
            selected = line.startswith("*")
            parts = line.lstrip("* ").split(" ", 2)
            if len(parts) >= 2:
                index = int(parts[0].rstrip(":"))
                tab_id = parts[1]
                title = parts[2] if len(parts) > 2 else ""
                tabs.append((index, tab_id, title, selected))
        return tabs

    def focus_bonsplit_tab(self, tab_id: str) -> None:
        """Focus a bonsplit tab by ID."""
        response = self._send_command(f"focus_bonsplit_tab {tab_id}")
        if not response.startswith("OK"):
            raise cmuxError(response)

    def new_bonsplit_tab(self, pane: Union[str, int, None] = None,
                         panel_type: str = "terminal", url: str = None) -> str:
        """
        Create a new bonsplit tab in a pane.
        Returns the new tab ID.
        """
        args = []
        if panel_type != "terminal":
            args.append(f"--type={panel_type}")
        if pane is not None:
            args.append(f"--pane={pane}")
        if url:
            args.append(f"--url={url}")

        cmd = "new_bonsplit_tab"
        if args:
            cmd += " " + " ".join(args)

        response = self._send_command(cmd)
        if response.startswith("OK "):
            return response[3:]
        raise cmuxError(response)

    def new_pane(self, direction: str = "right", panel_type: str = "terminal",
                 url: str = None) -> str:
        """
        Create a new pane (split).
        Returns the new pane ID.
        """
        args = [f"--direction={direction}"]
        if panel_type != "terminal":
            args.append(f"--type={panel_type}")
        if url:
            args.append(f"--url={url}")

        cmd = "new_pane " + " ".join(args)
        response = self._send_command(cmd)
        if response.startswith("OK "):
            return response[3:]
        raise cmuxError(response)

    def close_surface(self, surface: Union[str, int, None] = None) -> None:
        """
        Close a surface (collapse split) by ID or index.
        If surface is None, closes the focused surface.
        """
        if surface is None:
            response = self._send_command("close_surface")
        else:
            response = self._send_command(f"close_surface {surface}")
        if not response.startswith("OK"):
            raise cmuxError(response)


def main():
    """CLI interface for cmux"""
    import sys
    import argparse

    parser = argparse.ArgumentParser(description="cmux CLI")
    parser.add_argument("command", nargs="?", help="Command to send")
    parser.add_argument("args", nargs="*", help="Command arguments")
    parser.add_argument("-s", "--socket", default=cmux.DEFAULT_SOCKET_PATH,
                        help="Socket path")

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
