#!/usr/bin/env python3
import json
import os
import socket
import subprocess
import sys
import tempfile
import time
import unittest


BIN = os.path.abspath(os.environ.get("CMUX_TUI_BIN", "target/debug/cmux-tui"))


def read_line(stream):
    data = b""
    while not data.endswith(b"\n"):
        chunk = stream.recv(65536)
        if not chunk:
            raise AssertionError("control socket closed before a complete response")
        data += chunk
    return json.loads(data)


class AgentParitySmoke(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="cmux-tui-agent-parity-")
        self.socket_path = os.path.join(self.temp.name, "mux.sock")
        self.server = subprocess.Popen(
            [BIN, "--headless", "--ephemeral", "--socket", self.socket_path],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.PIPE,
            text=True,
        )
        deadline = time.monotonic() + 15
        while time.monotonic() < deadline:
            if os.path.exists(self.socket_path):
                return
            if self.server.poll() is not None:
                break
            time.sleep(0.025)
        stderr = self.server.stderr.read() if self.server.stderr else ""
        self.fail(f"headless server did not start: {stderr[-2000:]}")

    def tearDown(self):
        if self.server.poll() is None:
            self.server.terminate()
            try:
                self.server.wait(timeout=5)
            except subprocess.TimeoutExpired:
                self.server.kill()
                self.server.wait(timeout=5)
        if self.server.stderr is not None:
            self.server.stderr.close()
        self.temp.cleanup()

    def rpc(self, command):
        with socket.socket(socket.AF_UNIX) as stream:
            stream.settimeout(5)
            stream.connect(self.socket_path)
            stream.sendall((json.dumps(command) + "\n").encode())
            response = read_line(stream)
        self.assertTrue(response.get("ok"), response)
        return response["data"]

    def cli(self, *args):
        environment = os.environ.copy()
        environment["CMUX_TUI_SOCKET"] = self.socket_path
        result = subprocess.run(
            [BIN, *args],
            env=environment,
            text=True,
            capture_output=True,
            timeout=10,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        return result.stdout

    def test_protocol_12_agent_round_trip_event_ids_and_notification_unread(self):
        self.assertEqual(self.rpc({"id": 1, "cmd": "identify"})["protocol"], 12)
        tree = self.rpc({"id": 2, "cmd": "list-workspaces"})
        if not tree["workspaces"]:
            self.rpc({"id": 3, "cmd": "new-workspace"})
            tree = self.rpc({"id": 4, "cmd": "list-workspaces"})
        workspace = tree["workspaces"][0]
        surface = workspace["screens"][0]["panes"][0]["tabs"][0]["surface"]

        marker = f"ENV:{surface}:{workspace['id']}"
        self.rpc(
            {
                "id": 5,
                "cmd": "send",
                "surface": surface,
                "text": "printf 'ENV:%s:%s\\n' \"$CMUX_TUI_SURFACE_ID\" \"$CMUX_TUI_WORKSPACE_ID\"\r",
            }
        )
        deadline = time.monotonic() + 5
        screen = ""
        while time.monotonic() < deadline:
            screen = self.rpc({"id": 6, "cmd": "read-screen", "surface": surface})["text"]
            if marker in screen:
                break
            time.sleep(0.05)
        self.assertIn(marker, screen)

        subscriber = socket.socket(socket.AF_UNIX)
        self.addCleanup(subscriber.close)
        subscriber.settimeout(5)
        subscriber.connect(self.socket_path)
        subscriber_stream = subscriber.makefile("rb")
        self.addCleanup(subscriber_stream.close)
        subscriber.sendall(b'{"id":7,"cmd":"subscribe"}\n')
        self.assertTrue(json.loads(subscriber_stream.readline())["ok"])

        self.cli(
            "report-agent",
            "--surface",
            str(surface),
            "--state",
            "error",
            "--source",
            "socket",
            "--session",
            "session-1",
            "--label",
            "root",
            "--detail",
            "reviewing",
            "--started-at-ms",
            "1700000000000",
            "--tasks-completed",
            "3",
            "--tasks-total",
            "5",
            "--jobs-running",
            "2",
            "--agents-active",
            "4",
        )
        while True:
            event = json.loads(subscriber_stream.readline())
            if event.get("event") == "agent-state-changed":
                break
        self.assertEqual(event["state"], "error")
        self.assertEqual(event["tasks_completed"], 3)

        agents = json.loads(self.cli("--json", "list-agents", "--surface", str(surface)))
        self.assertEqual(
            {key: agents["agents"][0][key] for key in (
                "state",
                "label",
                "detail",
                "started_at_ms",
                "tasks_completed",
                "tasks_total",
                "jobs_running",
                "agents_active",
            )},
            {
                "state": "error",
                "label": "root",
                "detail": "reviewing",
                "started_at_ms": 1_700_000_000_000,
                "tasks_completed": 3,
                "tasks_total": 5,
                "jobs_running": 2,
                "agents_active": 4,
            },
        )

        self.rpc({"id": 8, "cmd": "new-workspace", "name": "notification-target"})
        self.cli(
            "notify",
            "--title",
            "Agent",
            "--subtitle",
            "Error",
            "--body",
            "blocked",
            "--level",
            "error",
            "--surface",
            str(surface),
        )
        while True:
            notification_event = json.loads(subscriber_stream.readline())
            if notification_event.get("event") == "notification":
                break
        self.assertEqual(notification_event["subtitle"], "Error")
        self.assertEqual(notification_event["level"], "error")
        tree = self.rpc({"id": 9, "cmd": "list-workspaces"})
        original = next(item for item in tree["workspaces"] if item["id"] == workspace["id"])
        notification = original["screens"][0]["panes"][0]["tabs"][0]["notification"]
        self.assertTrue(notification["unread"])
        self.assertEqual(notification["level"], "error")


if __name__ == "__main__":
    unittest.main()
