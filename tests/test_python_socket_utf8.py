#!/usr/bin/env python3
"""Python clients must decode replies independently of socket read boundaries."""

import importlib.util
import json
import os
from pathlib import Path
import socket
import tempfile
import unittest
from unittest.mock import patch


ROOT = Path(__file__).resolve().parents[1]


def load_client(directory):
    spec = importlib.util.spec_from_file_location(f"utf8_{directory}", ROOT / directory / "cmux.py")
    module = importlib.util.module_from_spec(spec)
    # Default-path discovery runs on import. Keep it away from the user's files.
    with tempfile.TemporaryDirectory() as home, patch.dict(os.environ, {
        "HOME": home, "CFFIXED_USER_HOME": home, "CMUX_SOCKET_PATH": home + "/fixture.sock",
    }):
        spec.loader.exec_module(module)
    return module.cmux


class FragmentedSocket:
    """A real socket whose recv boundaries are controlled by the test."""

    def __init__(self, sock, sizes):
        self.sock = sock
        self.sizes = iter(sizes)

    def fileno(self):
        return self.sock.fileno()

    def recv(self, limit):
        return self.sock.recv(min(limit, next(self.sizes, 1)))

    def sendall(self, data):
        self.sock.sendall(data)

    def close(self):
        self.sock.close()


class SocketUnicodeTests(unittest.TestCase):
    def client_with_reply(self, directory, reply, sizes=()):
        receiver, sender = socket.socketpair()
        self.addCleanup(receiver.close)
        self.addCleanup(sender.close)
        sender.sendall(reply)
        client = load_client(directory)(socket_path="/unused-fixture.sock")
        client._socket = FragmentedSocket(receiver, sizes)
        return client

    def test_v2_fragmented_unicode_response(self):
        expected = {"title": "café 日本語 🧪"}
        reply = json.dumps({"id": 1, "ok": True, "result": expected}, ensure_ascii=False).encode() + b"\n"
        client = self.client_with_reply("tests_v2", reply)
        self.assertEqual(client._call("workspace.list"), expected)

    def test_v2_buffered_line_with_partial_next_character(self):
        client = self.client_with_reply("tests_v2", "first\n🧪 next\nthird\n".encode(), [8, 8192])
        self.assertEqual(client._recv_line(), "first")
        self.assertEqual(client._recv_line(), "🧪 next")
        self.assertEqual(client._recv_line(), "third")

    def test_v2_invalid_utf8_keeps_replacement_behavior(self):
        client = self.client_with_reply("tests_v2", b"bad \xff\n")
        self.assertEqual(client._recv_line(), "bad \ufffd")

    def test_v1_fragmented_multiline_unicode_response(self):
        expected = "0: workspace café\n1: workspace 日本語 🧪"
        client = self.client_with_reply("tests", (expected + "\n").encode())
        self.assertEqual(client._send_command("list_workspaces"), expected)


if __name__ == "__main__":
    unittest.main()
