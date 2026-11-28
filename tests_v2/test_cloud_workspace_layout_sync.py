#!/usr/bin/env python3
"""Exercise native pane moves/closes against a real cloud daemon.

Run on the leased verification Mac with CMUX_SOCKET_PATH pointing at the tagged
app, CMUX_TEST_VM_ID identifying a disposable test machine, and CMUX_TUI_CLIENT
pointing at that app's bundled cmux-tui client. The app must already be signed in.
The harness owns and removes only the workspaces and terminals it creates.
"""

import json
import os
import selectors
import subprocess
import time
import uuid
from concurrent.futures import ThreadPoolExecutor

from cmux import cmux, cmuxError


class CloudLayoutHarness:
    def __init__(self, client, machine, tui):
        self.client = client
        self.machine = machine
        self.tui = tui
        self.link_socket = client._call("vm.link_socket", {"id": machine}, timeout_s=120)["socket_path"]
        self.fixtures = []
        self.local_workspaces = []

    def remote(self, *arguments):
        command = [self.tui, "--socket", self.link_socket, "--json", *arguments]
        return json.loads(subprocess.check_output(command, timeout=30))

    def snapshot(self):
        return self.remote("session", "current", "snapshot")

    @staticmethod
    def terminal_workspaces(snapshot, terminal):
        panes = {p["id"]: p["screen_id"] for p in snapshot["panes"]}
        screens = {s["id"]: s["workspace_id"] for s in snapshot["screens"]}
        return sorted(screens[panes[t["pane_id"]]] for t in snapshot["tabs"] if t["content_id"] == terminal)

    def expect_layout(self, predicate, description):
        snapshot = self.snapshot()
        if predicate(snapshot):
            return snapshot
        cursor = snapshot["cursor"]
        command = [self.tui, "--socket", self.link_socket, "--jsonl", "session", "current", "events",
                   "--generation", cursor["generation"], "--revision", str(cursor["revision"])]
        # Replay from the observed cursor closes the snapshot/subscription race. Wait
        # on real daemon events rather than sleeping to guess when the UI has settled.
        with subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.PIPE) as events:
            selector = selectors.DefaultSelector()
            selector.register(events.stdout, selectors.EVENT_READ)
            deadline = time.monotonic() + 30
            try:
                while time.monotonic() < deadline:
                    if not selector.select(max(0, deadline - time.monotonic())):
                        break
                    if not os.read(events.stdout.fileno(), 65536):
                        raise AssertionError("daemon event stream ended before " + description)
                    snapshot = self.snapshot()
                    if predicate(snapshot):
                        return snapshot
            finally:
                selector.close()
                events.terminate()
                events.wait(timeout=5)
        raise AssertionError(description + ": " + json.dumps(snapshot))

    def create_workspace(self, name):
        fixture = self.client._call("vm.workspace_new", {
            "id": self.machine, "name": name, "focus": False,
        }, timeout_s=240)
        self.fixtures.append(fixture)
        return fixture

    def checkpoint(self, label, workspace):
        if os.environ.get("CMUX_LAYOUT_EVIDENCE_PAUSE") == "1":
            self.client._call("workspace.select", {"workspace_id": workspace})
            input("CHECKPOINT " + label + " — capture the tagged window, then continue: ")

    def run(self):
        prefix = "layout-sync-" + uuid.uuid4().hex[:8]
        source = self.create_workspace(prefix + "-source")
        target = self.create_workspace(prefix + "-target")
        terminal = source["terminal_id"]
        remote_target = target["remote_workspace_id"]
        self.expect_layout(lambda s: self.terminal_workspaces(s, terminal) == [source["remote_workspace_id"]], "initial source placement")
        self.checkpoint("before-move", source["workspace_id"])
        self.client._call("surface.move", {
            "surface_id": source["surface_id"], "workspace_id": target["workspace_id"], "focus": False,
        })
        self.expect_layout(lambda s: self.terminal_workspaces(s, terminal) == [remote_target], "native move must move the daemon tab")
        print("PASS native move updates the machine workspace", flush=True)
        self.checkpoint("after-move", target["workspace_id"])

        self.client._call("surface.close", {"surface_id": source["surface_id"], "workspace_id": target["workspace_id"]})
        detached = self.expect_layout(lambda s: self.terminal_workspaces(s, terminal) == [], "native close must detach the daemon tab")
        assert any(t["id"] == terminal for t in detached["terminals"]), "pane close killed its terminal"
        print("PASS native close detaches and preserves the terminal", flush=True)
        self.checkpoint("after-close", target["workspace_id"])

        viewer = self.client._call("workspace.create", {"focus": False})["workspace_id"]
        self.local_workspaces.append(viewer)
        self.remote("workspace", source["remote_workspace_id"], "focus")
        self.client._call("vm.tree", {"id": self.machine, "refresh": True}, timeout_s=120)

        def project(workspace):
            with cmux(os.environ["CMUX_SOCKET_PATH"]) as other_client:
                return other_client._call("surface.project", {
                    "resource": self.machine + "/terminal/" + terminal,
                    "workspace_id": workspace, "reuse": False, "focus": False,
                }, timeout_s=180)

        with ThreadPoolExecutor(max_workers=2) as pool:
            unbound_future = pool.submit(project, viewer)
            bound_future = pool.submit(project, target["workspace_id"])
            unbound, bound = unbound_future.result(), bound_future.result()
        self.expect_layout(lambda s: self.terminal_workspaces(s, terminal) == [remote_target], "concurrent pool opens must share one tab in the bound destination")
        print("PASS concurrent detached-terminal opens share one correctly placed tab", flush=True)
        self.client._call("surface.close", {"surface_id": unbound["surface_id"], "workspace_id": viewer})
        self.client._call("surface.close", {"surface_id": bound["surface_id"], "workspace_id": target["workspace_id"]})
        self.expect_layout(lambda s: self.terminal_workspaces(s, terminal) == [], "last bound pane closes its re-created tab")

        before = self.snapshot()
        self.client._call("workspace.close", {"workspace_id": target["workspace_id"]})
        after = self.snapshot()
        assert self.terminal_workspaces(before, target["terminal_id"]) == self.terminal_workspaces(after, target["terminal_id"])
        assert any(w["id"] == remote_target for w in after["workspaces"])
        print("PASS local workspace teardown preserves the machine layout", flush=True)

    def close_local_workspace(self, workspace, errors):
        try:
            self.client._call("workspace.close", {"workspace_id": workspace})
        except Exception as error:
            # A last-pane transfer or the teardown assertion may already have
            # removed this workspace. Transport and other server errors matter.
            if not (isinstance(error, cmuxError) and str(error) == "not_found: Workspace not found"):
                errors.append(f"local workspace {workspace}: {error}")

    def close(self):
        errors = []
        for workspace in self.local_workspaces:
            self.close_local_workspace(workspace, errors)
        for fixture in reversed(self.fixtures):
            self.close_local_workspace(fixture["workspace_id"], errors)
            for arguments in [("terminal", fixture["terminal_id"], "close"),
                              ("workspace", fixture["remote_workspace_id"], "close")]:
                try:
                    self.remote(*arguments)
                except Exception as error:
                    errors.append(str(error))
        if errors:
            raise RuntimeError("fixture cleanup failed: " + "; ".join(errors))


def main():
    socket_path = os.environ["CMUX_SOCKET_PATH"]
    machine = os.environ["CMUX_TEST_VM_ID"]
    tui = os.environ["CMUX_TUI_CLIENT"]
    with cmux(socket_path) as client:
        harness = CloudLayoutHarness(client, machine, tui)
        try:
            harness.run()
        finally:
            harness.close()


if __name__ == "__main__":
    main()
