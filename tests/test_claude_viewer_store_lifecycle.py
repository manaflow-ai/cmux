#!/usr/bin/env python3
"""Real store-path lifecycle tests for acknowledged Claude viewer leases.

These run the built CLI's `__claude-viewer` sink against a fake control socket
and a real hook-state file. They cover the two Major findings: restoring the
worker route/generation and the earliest per-pane active owner, plus the
closed-attachment tombstone that must stop routing without a later event.
"""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import unittest
import uuid

from fake_socket_env import cli_environment
from test_claude_hook_clear_running_status import HookSocketServer, resolve_cmux_cli


class MappedHookSocketServer(HookSocketServer):
    def __init__(self, default_workspace, default_surface):
        super().__init__(default_workspace, default_surface)
        self.pid_surfaces = {}
        self.workspace_surfaces = {}

    def _response_for(self, line):
        if not line.startswith("{"):
            return "OK"
        try:
            request = json.loads(line)
        except json.JSONDecodeError:
            return "OK"
        method = request.get("method")
        params = request.get("params") or {}
        if method == "agent.resolve_delivery_target":
            if "pid" in params:
                workspace, surface = self.pid_surfaces.get(
                    params["pid"], (self.workspace_id, self.surface_id))
                result = {"source": "pid", "workspace_id": workspace, "surface_id": surface}
            else:
                workspace = params.get("workspace_id") or self.workspace_id
                surface = params.get("surface_id") or self.surface_id
                result = {"source": "surface", "workspace_id": workspace, "surface_id": surface}
        elif method == "surface.list":
            workspace = params.get("workspace_id") or self.workspace_id
            result = {"surfaces": [{"index": 0, "id": self.workspace_surfaces.get(workspace, self.surface_id),
                                    "ref": "surface:1", "focused": True}]}
        else:
            return super()._response_for(line)
        return json.dumps({"id": request.get("id"), "ok": True, "result": result})


def alive_process():
    return subprocess.Popen(["/bin/sleep", "60"], start_new_session=True)


def process_start(pid):
    return subprocess.check_output(
        ["ps", "-p", str(pid), "-o", "lstart="],
        env={**os.environ, "TZ": "UTC", "LC_ALL": "C"}, text=True).strip()


class ViewerProcess:
    def __init__(self, cli, socket_path, env, home, server, attachment, worker, workspace, surface):
        self.cmd = home / f"cmd-{attachment}"
        self.result = home / f"result-{attachment}"
        script = home / f"viewer-{attachment}.py"
        script.write_text(
            "import json,os,subprocess,sys,time\n"
            "cli,sock,cmd,result,attachment,worker=sys.argv[1:7]\n"
            "while True:\n"
            "    if not os.path.exists(cmd): time.sleep(0.01); continue\n"
            "    command=open(cmd).read().strip()\n"
            "    if command == 'stop': break\n"
            "    p=subprocess.run([cli,'--socket',sock,'__claude-viewer',command],\n"
            "      input=json.dumps({'attach_id':attachment,'job_id':worker[:8],\n"
            "      'viewer_pid':os.getpid()}),capture_output=True,text=True,timeout=10)\n"
            "    tmp=result+'.tmp'\n"
            "    open(tmp,'w').write(json.dumps({'code':p.returncode,'err':p.stderr}))\n"
            "    os.replace(tmp,result); os.unlink(cmd)\n"
        )
        self.process = subprocess.Popen(
            [sys.executable, str(script), cli, socket_path, str(self.cmd), str(self.result),
             attachment, worker], env=env, start_new_session=True)
        server.pid_surfaces[self.process.pid] = (workspace, surface)
        self.pid = self.process.pid

    def run(self, command, timeout=15):
        if self.result.exists():
            self.result.unlink()
        self.cmd.write_text(command)
        deadline = time.monotonic() + timeout
        while not self.result.exists() and time.monotonic() < deadline:
            time.sleep(0.02)
        if not self.result.exists():
            raise AssertionError("viewer helper did not answer before the deadline")
        outcome = json.loads(self.result.read_text())
        self.result.unlink()
        if outcome["code"] != 0:
            raise AssertionError(f"__claude-viewer {command} failed: {outcome['err']}")
        return outcome

    def close(self):
        try:
            self.cmd.write_text("stop")
            self.process.wait(timeout=5)
        except Exception:
            self.process.terminate()
            self.process.wait(timeout=5)


class ViewerStoreLifecycleTests(unittest.TestCase):
    def setUp(self):
        self.cli = resolve_cmux_cli()
        self.worker = alive_process()
        self.launcher = alive_process()
        self.extra = []
        self.home = Path(tempfile.mkdtemp(prefix="cmux-viewer-store-"))
        self.config = self.home / ".claude"
        (self.config / "sessions").mkdir(parents=True)
        self.worker_session = str(uuid.uuid4())
        self.launcher_session = str(uuid.uuid4())
        self.worker_workspace = str(uuid.uuid4())
        self.worker_surface = str(uuid.uuid4())
        self.state_path = self.home / "hooks.json"
        now = time.time()
        (self.config / "sessions" / f"{self.worker.pid}.json").write_text(json.dumps({
            "kind": "bg", "pid": self.worker.pid, "sessionId": self.worker_session,
            "jobId": self.worker_session[:8], "procStart": process_start(self.worker.pid),
            "pidDomain": "darwin",
        }))
        self.reset_state()

    def worker_generation(self):
        output = subprocess.check_output(
            [self.cli, "__process-generation", str(self.worker.pid)],
            env={"PATH": os.environ.get("PATH", ""), "HOME": str(self.home),
                 "CFFIXED_USER_HOME": str(self.home),
                 "CMUX_SOCKET_PATH": "/nonexistent/cmux.sock"},
            text=True, timeout=10)
        parts = [int(part) for part in output.split()]
        self.assertEqual(len(parts), 2)
        return parts

    def reset_state(self):
        now = time.time()
        seconds, microseconds = self.worker_generation()
        self.state_path.write_text(json.dumps({
            "version": 1,
            "sessions": {self.worker_session: {
                "sessionId": self.worker_session,
                "workspaceId": self.worker_workspace, "surfaceId": self.worker_surface,
                "pid": self.worker.pid,
                "pidStartSeconds": seconds, "pidStartMicroseconds": microseconds,
                "startedAt": now, "updatedAt": now,
            }},
            "activeSessionsBySurface": {self.worker_surface: {
                "sessionId": self.launcher_session, "updatedAt": now}},
            "activeSessionsByWorkspace": {self.worker_workspace: {
                "sessionId": self.launcher_session, "updatedAt": now}},
        }))

    def set_surface_owner(self, surface_id):
        state = json.loads(self.state_path.read_text())
        state.setdefault("activeSessionsBySurface", {})[surface_id] = {
            "sessionId": self.launcher_session, "updatedAt": time.time()}
        self.state_path.write_text(json.dumps(state))
        self.server = MappedHookSocketServer(self.worker_workspace, self.worker_surface)
        self.server.__enter__()
        self.server.workspace_surfaces[self.worker_workspace] = self.worker_surface
        self.env = cli_environment(self.server.socket_path, home=self.home)
        self.env.update(CLAUDE_CONFIG_DIR=str(self.config),
                        CMUX_CLAUDE_HOOK_STATE_PATH=str(self.state_path),
                        CMUX_CLAUDE_PID=str(self.worker.pid),
                        CMUX_WORKSPACE_ID=self.worker_workspace,
                        CMUX_SURFACE_ID=self.worker_surface)

    def tearDown(self):
        try:
            self.server.__exit__(None, None, None)
        finally:
            for process in [self.worker, self.launcher, *self.extra]:
                if process.poll() is None:
                    process.terminate()
                    process.wait(timeout=5)

    def viewer(self, workspace, surface):
        attachment = str(uuid.uuid4())
        self.server.workspace_surfaces[workspace] = surface
        process = ViewerProcess(self.cli, self.server.socket_path, self.env, self.home,
                                self.server, attachment, self.worker_session, workspace, surface)
        self.extra.append(process.process)
        return process, attachment

    def record(self):
        return json.loads(self.state_path.read_text())["sessions"][self.worker_session]

    def assert_restored(self, workspace, surface, slot_surface):
        record = self.record()
        self.assertEqual(record["workspaceId"], self.worker_workspace)
        self.assertEqual(record["surfaceId"], self.worker_surface)
        self.assertEqual(record["pid"], self.worker.pid)
        seconds, microseconds = self.worker_generation()
        self.assertEqual(record.get("pidStartSeconds"), seconds)
        self.assertEqual(record.get("pidStartMicroseconds"), microseconds)
        state = json.loads(self.state_path.read_text())
        if slot_surface is not None:
            self.assertEqual(state["activeSessionsBySurface"][slot_surface]["sessionId"],
                             self.launcher_session)

    def test_same_pane_two_viewers_both_orders_restore_worker_route(self):
        for order in (("first", "second"), ("second", "first")):
            with self.subTest(order=order):
                self.reset_state()
                pane_surface = str(uuid.uuid4())
                self.set_surface_owner(pane_surface)
                first, _ = self.viewer(self.worker_workspace, pane_surface)
                second, _ = self.viewer(self.worker_workspace, pane_surface)
                first.run("attached")
                second.run("attached")
                self.assertEqual(self.record()["surfaceId"], pane_surface)
                by_name = {"first": first, "second": second}
                by_name[order[0]].run("detached")
                self.assertEqual(self.record()["surfaceId"], pane_surface)
                by_name[order[1]].run("detached")
                self.assert_restored(self.worker_workspace, self.worker_surface, pane_surface)
                first.close()
                second.close()

    def test_cross_pane_viewers_restore_each_pane_owner(self):
        pane_a, pane_b = str(uuid.uuid4()), str(uuid.uuid4())
        self.set_surface_owner(pane_a)
        self.set_surface_owner(pane_b)
        first, _ = self.viewer(self.worker_workspace, pane_a)
        second, _ = self.viewer(self.worker_workspace, pane_b)
        first.run("attached")
        second.run("attached")
        second.run("detached")
        first.run("detached")
        self.assert_restored(self.worker_workspace, self.worker_surface, pane_a)
        state = json.loads(self.state_path.read_text())
        self.assertEqual(state["activeSessionsBySurface"][pane_b]["sessionId"],
                         self.launcher_session)
        first.close()
        second.close()

    def test_empty_original_slot_is_not_replaced_by_the_worker_slot(self):
        pane_surface = str(uuid.uuid4())
        first, _ = self.viewer(self.worker_workspace, pane_surface)
        second, _ = self.viewer(self.worker_workspace, pane_surface)
        first.run("attached")
        second.run("attached")
        first.run("detached")
        second.run("detached")
        state = json.loads(self.state_path.read_text())
        self.assertIsNone(state.get("activeSessionsBySurface", {}).get(pane_surface))
        first.close()
        second.close()

    def test_later_owner_is_not_overwritten(self):
        pane_surface = str(uuid.uuid4())
        viewer, _ = self.viewer(self.worker_workspace, pane_surface)
        viewer.run("attached")
        new_owner, new_route = str(uuid.uuid4()), str(uuid.uuid4())
        state = json.loads(self.state_path.read_text())
        state["sessions"][self.worker_session]["surfaceId"] = new_route
        state.setdefault("activeSessionsBySurface", {})[pane_surface] = {
            "sessionId": new_owner, "updatedAt": time.time()}
        self.state_path.write_text(json.dumps(state))
        viewer.run("detached")
        state = json.loads(self.state_path.read_text())
        self.assertEqual(state["sessions"][self.worker_session]["surfaceId"], new_route)
        self.assertEqual(state.get("activeSessionsBySurface", {}).get(pane_surface, {}).get("sessionId"),
                         new_owner)
        viewer.close()

    def test_remaining_viewer_survives_newest_viewer_detach_across_workspaces(self):
        workspace_a, surface_a = str(uuid.uuid4()), str(uuid.uuid4())
        workspace_b, surface_b = str(uuid.uuid4()), str(uuid.uuid4())
        self.server.workspace_surfaces[workspace_a] = surface_a
        self.server.workspace_surfaces[workspace_b] = surface_b
        self.set_surface_owner(surface_a)
        older, _ = self.viewer(workspace_a, surface_a)
        newer, _ = self.viewer(workspace_b, surface_b)
        older.run("attached")
        newer.run("attached")
        newer.run("detached")
        self.server.commands.clear()
        stop = subprocess.run(
            [self.cli, "--socket", self.server.socket_path, "hooks", "claude", "stop"],
            input=json.dumps({"session_id": self.worker_session, "hook_event_name": "Stop",
                              "cwd": str(self.home), "last_assistant_message": "remaining viewer"}),
            env=self.env, capture_output=True, text=True, timeout=10)
        self.assertEqual(stop.returncode, 0, stop.stderr)
        completed = [command for command in self.server.commands
                     if "agent.turn.completed" in command]
        self.assertTrue(completed, self.server.commands)
        self.assertTrue(any(surface_a in command for command in completed),
                        "the remaining viewer was not selected")
        self.assertFalse(any(surface_b in command for command in completed),
                         "the detached newest viewer was selected")
        older.close()
        newer.close()

    def test_closed_marker_blocks_a_lease_without_a_detach_event(self):
        pane_surface = str(uuid.uuid4())
        viewer, attachment = self.viewer(self.worker_workspace, pane_surface)
        viewer.run("attached")
        marker_dir = self.state_path.parent / "claude-viewer-closed"
        marker_dir.mkdir(mode=0o700, exist_ok=True)
        (marker_dir / attachment.lower()).write_text("")
        # Simulate a failed detach with no later event: the lease stays in the
        # store, the viewer process is alive, but the connection owner recorded
        # closure. A Stop must not target that pane.
        self.server.commands.clear()
        stop = subprocess.run(
            [self.cli, "--socket", self.server.socket_path, "hooks", "claude", "stop"],
            input=json.dumps({"session_id": self.worker_session, "hook_event_name": "Stop",
                              "cwd": str(self.home), "last_assistant_message": "closed marker"}),
            env=self.env, capture_output=True, text=True, timeout=10)
        self.assertEqual(stop.returncode, 0, stop.stderr)
        completed = [command for command in self.server.commands
                     if "agent.turn.completed" in command]
        self.assertTrue(completed, self.server.commands)
        self.assertFalse(any(pane_surface in command for command in completed),
                         "completion was routed to a closed attachment")
        viewer.close()


if __name__ == "__main__":
    unittest.main()
