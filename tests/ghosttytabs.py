#!/usr/bin/env python3
"""
GhosttyTabs Python Client

A client library for programmatically controlling GhosttyTabs via Unix socket.

Usage:
    from ghosttytabs import GhosttyTabs

    client = GhosttyTabs()
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
import os
from typing import Optional, List, Tuple


class GhosttyTabsError(Exception):
    """Exception raised for GhosttyTabs errors"""
    pass


class GhosttyTabs:
    """Client for controlling GhosttyTabs via Unix socket"""

    DEFAULT_SOCKET_PATH = "/tmp/ghosttytabs.sock"

    def __init__(self, socket_path: str = None):
        self.socket_path = socket_path or self.DEFAULT_SOCKET_PATH
        self._socket: Optional[socket.socket] = None

    def connect(self) -> None:
        """Connect to the GhosttyTabs socket"""
        if self._socket is not None:
            return

        if not os.path.exists(self.socket_path):
            raise GhosttyTabsError(
                f"Socket not found at {self.socket_path}. "
                "Is GhosttyTabs running?"
            )

        self._socket = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        try:
            self._socket.connect(self.socket_path)
            self._socket.settimeout(5.0)
        except socket.error as e:
            self._socket = None
            raise GhosttyTabsError(f"Failed to connect: {e}")

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
            raise GhosttyTabsError("Not connected")

        try:
            self._socket.sendall((command + "\n").encode())
            response = self._socket.recv(8192).decode().strip()
            return response
        except socket.timeout:
            raise GhosttyTabsError("Command timed out")
        except socket.error as e:
            raise GhosttyTabsError(f"Socket error: {e}")

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
        raise GhosttyTabsError(response)

    def new_split(self, direction: str) -> None:
        """Create a split in the given direction (left/right/up/down)."""
        response = self._send_command(f"new_split {direction}")
        if not response.startswith("OK"):
            raise GhosttyTabsError(response)

    def close_tab(self, tab_id: str) -> None:
        """Close a tab by ID"""
        response = self._send_command(f"close_tab {tab_id}")
        if not response.startswith("OK"):
            raise GhosttyTabsError(response)

    def select_tab(self, tab: str | int) -> None:
        """Select a tab by ID or index"""
        response = self._send_command(f"select_tab {tab}")
        if not response.startswith("OK"):
            raise GhosttyTabsError(response)

    def list_surfaces(self, tab: str | int | None = None) -> List[Tuple[int, str, bool]]:
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

    def focus_surface(self, surface: str | int) -> None:
        """Focus a surface by ID or index in the current tab."""
        response = self._send_command(f"focus_surface {surface}")
        if not response.startswith("OK"):
            raise GhosttyTabsError(response)

    def current_tab(self) -> str:
        """Get the current tab's ID"""
        response = self._send_command("current_tab")
        if response.startswith("ERROR"):
            raise GhosttyTabsError(response)
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
            raise GhosttyTabsError(response)

    def send_surface(self, surface: str | int, text: str) -> None:
        """Send text to a specific surface by ID or index in the current tab."""
        escaped = text.replace("\n", "\\n").replace("\r", "\\r").replace("\t", "\\t")
        response = self._send_command(f"send_surface {surface} {escaped}")
        if not response.startswith("OK"):
            raise GhosttyTabsError(response)

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
            raise GhosttyTabsError(response)

    def send_key_surface(self, surface: str | int, key: str) -> None:
        """Send a special key to a specific surface by ID or index in the current tab."""
        response = self._send_command(f"send_key_surface {surface} {key}")
        if not response.startswith("OK"):
            raise GhosttyTabsError(response)

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


def main():
    """CLI interface for ghosttytabs"""
    import sys
    import argparse

    parser = argparse.ArgumentParser(description="GhosttyTabs CLI")
    parser.add_argument("command", nargs="?", help="Command to send")
    parser.add_argument("args", nargs="*", help="Command arguments")
    parser.add_argument("-s", "--socket", default=GhosttyTabs.DEFAULT_SOCKET_PATH,
                        help="Socket path")

    args = parser.parse_args()

    try:
        with GhosttyTabs(args.socket) as client:
            if not args.command:
                # Interactive mode
                print("GhosttyTabs CLI (type 'help' for commands, 'quit' to exit)")
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
    except GhosttyTabsError as e:
        print(f"Error: {e}", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
