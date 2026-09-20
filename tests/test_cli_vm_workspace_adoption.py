#!/usr/bin/env python3
"""Exercise machine-create handoff using the exact built CLI and an isolated socket."""
from __future__ import annotations

import json
import os
from pathlib import Path
import socket
import subprocess
import tempfile
import threading
import unittest


class MachineSocket:
    workspace = "11111111-1111-4111-8111-111111111111"
    machine = "vm-create-adoption"
    window = "33333333-3333-4333-8333-333333333333"
    other_window = "44444444-4444-4444-8444-444444444444"

    def __init__(self, fail_at=None, bound_workspace=None, selected_workspace=None):
        self.fail_at = fail_at
        self.requests = []
        self.errors = []
        self.stopping = threading.Event()
        self.bound_workspace = bound_workspace
        self.selected_workspace = selected_workspace

    def __enter__(self):
        self.root = tempfile.TemporaryDirectory(prefix="cmux-adopt-", dir="/tmp")
        self.path = str(Path(self.root.name, "socket"))
        self.listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.listener.bind(self.path)
        self.listener.listen()
        self.thread = threading.Thread(target=self.serve)
        self.thread.start()
        return self

    def serve(self):
        try:
            with self.listener.accept()[0] as connection, connection.makefile("rwb") as stream:
                for line in stream:
                    if line.startswith(b"auth "):
                        stream.write(b"OK\n")
                    else:
                        request = json.loads(line)
                        self.requests.append(request)
                        method = request["method"]
                        if method == "workspace.cloud_vm_bind":
                            self.bound_workspace = request["params"].get("remote_workspace_id", self.bound_workspace)
                        result = self.response(method, request.get("params", {}))
                        response = {"id": request["id"], "ok": method != self.fail_at, "result": result}
                        if method == self.fail_at:
                            response["error"] = {"code": "unavailable", "message": "Fixture failure"}
                        stream.write(json.dumps(response).encode() + b"\n")
                    stream.flush()
        except Exception as error:
            if not self.stopping.is_set():
                self.errors.append(error)

    def response(self, method, params):
        if method == "vm.create":
            return {"id": self.machine, "provider": "freestyle", "image": "fixture", "slug": "brave-sapphire-lobster"}
        if method == "vm.cmux_remote_info":
            return {"route": "ws://10.0.0.1:1337/v1/link", "session": "cloud", "trusted_carrier": True}
        if method == "surface.catalog":
            return {"machines": [{"id": self.machine, "name": "brave-sapphire-lobster", "link_state": "connected",
                                  "remote_workspaces": [{"id": "ws-first", "name": "workspace-1", "focused": False},
                                                        {"id": "ws-later", "name": "workspace-2", "focused": True}]
                                  if self.bound_workspace else [{"id": "ws-first", "name": "workspace-1", "focused": True}]}],
                    "resources": [{"id": self.machine + "/terminal/term-first", "machine": self.machine,
                                   "key": "term-first", "kind": "terminal", "lifecycle": "running",
                                   "remote_views": [{"workspace": {"id": "ws-first"}, "tab_id": "tab-first", "focused": True}]}]}
        if method == "surface.project":
            return {"workspace_id": self.workspace, "surface_id": "22222222-2222-4222-8222-222222222222"}
        if method == "workspace.cloud_vm_bind":
            return {"workspace_id": self.workspace, "workspace_ref": "workspace:73",
                    "window_id": self.window, "remote_workspace_id": self.bound_workspace}
        if method == "window.list":
            return {"windows": [{"id": self.window}, {"id": self.other_window}]}
        if method == "workspace.current":
            return {"workspace_id": self.selected_workspace or "selected-workspace"}
        if method == "workspace.list":
            return {"workspaces": [] if params.get("window_id") == self.other_window else
                    [{"id": self.workspace, "ref": "workspace:73", "window_id": self.window}]}
        if method in {"workspace.cloud_vm_bind", "workspace.cloud_vm_terminal_ready", "workspace.select"}:
            return {"workspace_id": self.workspace}
        raise AssertionError("Unexpected mutation: " + method)

    def __exit__(self, *_):
        self.stopping.set()
        try:
            self.listener.shutdown(socket.SHUT_RDWR)
        except OSError:
            pass
        self.listener.close()
        self.thread.join(timeout=5)
        self.root.cleanup()
        if self.thread.is_alive() or self.errors:
            raise AssertionError(str(self.errors) or "Socket server did not exit")


class VMWorkspaceAdoptionTests(unittest.TestCase):
    def run_open(self, server, verb="new", detach=False, target=None, window=None, json_output=False):
        cli = os.environ["CMUX_CLI_BIN"]
        environment = {key: value for key, value in os.environ.items() if not key.startswith("CMUX")}
        with tempfile.TemporaryDirectory(prefix="cmux-adopt-home-") as home:
            environment.update({"HOME": home, "CFFIXED_USER_HOME": home, "CMUX_CLI_SENTRY_DISABLED": "1"})
            args = ["vm", verb] + ([server.machine] if verb == "open" else [])
            if detach:
                args += ["--detach"]
            if window:
                args += ["--window", window]
            if json_output:
                args += ["--json"]
            global_args = ["--id-format", "both"] if json_output else []
            result = subprocess.run([cli, "--socket", server.path, *global_args, *args, "--workspace", target or server.workspace, "--focus", "false"],
                                    env=environment, capture_output=True, text=True, timeout=30)
        return result

    def test_detached_create_has_no_local_workspace_lifecycle(self):
        with MachineSocket() as server:
            result = self.run_open(server, detach=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual([r["method"] for r in server.requests], ["vm.create"])

    def test_retry_honors_the_first_workspace_binding(self):
        with MachineSocket(bound_workspace="ws-first") as server:
            result = self.run_open(server, "open")
            self.assertEqual(result.returncode, 0, result.stderr)
            project = next(r["params"] for r in server.requests if r["method"] == "surface.project")
            self.assertEqual(project["remote_workspace_id"], "ws-first")
            self.assertEqual(project["resource"], server.machine + "/terminal/term-first")

    def test_selected_background_target_keeps_focus_without_selecting_another_workspace(self):
        with MachineSocket(selected_workspace=MachineSocket.workspace) as server:
            result = self.run_open(server, "open")
            self.assertEqual(result.returncode, 0, result.stderr)
            project = next(r["params"] for r in server.requests if r["method"] == "surface.project")
            self.assertIs(project["focus"], True)
            self.assertNotIn("workspace.select", [r["method"] for r in server.requests])

    def test_app_receipt_resolves_cross_window_refs_and_uuid_targets(self):
        for target in [MachineSocket.workspace, "workspace:73"]:
            with self.subTest(target=target), MachineSocket() as server:
                result = self.run_open(server, "open", target=target, window=server.other_window, json_output=True)
                self.assertEqual(result.returncode, 0, result.stderr)
                receipt = json.loads(result.stdout)
                self.assertEqual(receipt["workspace_id"], server.workspace)
                self.assertEqual(receipt["workspace_ref"], "workspace:73")
                self.assertEqual(receipt["window_id"], server.window)
                self.assertNotIn("workspace.list", [r["method"] for r in server.requests])

    def test_create_and_retry_preserve_the_reserved_workspace_and_first_terminal(self):
        for verb in ["new", "open"]:
            with self.subTest(verb=verb), MachineSocket() as server:
                result = self.run_open(server, verb)
                self.assertEqual(result.returncode, 0, result.stderr)
                methods = [request["method"] for request in server.requests]
                self.assertLess(methods.index("surface.catalog"), methods.index("workspace.cloud_vm_bind"))
                self.assertNotIn("workspace.cloud_vm_terminal_ready", methods)
                self.assertNotIn("workspace.create", methods)
                self.assertNotIn("surface.new_terminal", methods)
                self.assertNotIn("workspace.select", methods)
                project = next(r["params"] for r in server.requests if r["method"] == "surface.project")
                self.assertEqual(project["workspace_id"], server.workspace)
                self.assertEqual(project["remote_workspace_id"], "ws-first")
                self.assertEqual(project["remote_tab_id"], "tab-first")
                self.assertIs(project["focus"], False)
                self.assertIs(project["reuse"], True)
                self.assertIs(project["reuse_in_workspace"], True)
                before_project = server.requests[:methods.index("surface.project")]
                initial_binding = next(r for r in before_project if r["method"] == "workspace.cloud_vm_bind" and
                                       r["params"].get("remote_workspace_id") == "ws-first")
                self.assertIs(initial_binding["params"].get("defer_projection"), True)
                self.assertIn("OK workspace=workspace:73", result.stdout)

    def test_failures_leave_the_owning_card_for_retry(self):
        for failure in ["vm.create", "surface.catalog", "surface.project"]:
            with self.subTest(failure=failure), MachineSocket(fail_at=failure) as server:
                result = self.run_open(server)
                self.assertNotEqual(result.returncode, 0)
                methods = [request["method"] for request in server.requests]
                self.assertNotIn("workspace.cloud_vm_terminal_ready", methods)
                self.assertNotIn("workspace.close", methods)
                self.assertNotIn("surface.close", methods)


if __name__ == "__main__":
    unittest.main(verbosity=2)
