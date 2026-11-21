#!/usr/bin/env python3
"""A background viewer, its worker, and its launcher keep distinct identities.

The launcher session owns pane L. A detached background worker (its own PID)
publishes hooks. A separate viewer process attaches in pane V and admits the
lease. A natural Stop must resolve to pane V, not to the launcher pane L.
"""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import time
import unittest
import uuid

from fake_socket_env import cli_environment
from test_claude_hook_clear_running_status import HookSocketServer, resolve_cmux_cli


class MappedHookSocketServer(HookSocketServer):
    def __init__(self, default_workspace: str, default_surface: str) -> None:
        super().__init__(default_workspace, default_surface)
        self.pid_surfaces: dict[int, tuple[str, str]] = {}
        self.workspace_surfaces: dict[str, str] = {}

    def _response_for(self, line: str) -> str:
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
            surface = self.workspace_surfaces.get(workspace, self.surface_id)
            result = {"surfaces": [{"index": 0, "id": surface, "ref": "surface:1", "focused": True}]}
        else:
            return super()._response_for(line)
        return json.dumps({"id": request.get("id"), "ok": True, "result": result})


def alive_process() -> subprocess.Popen[bytes]:
    return subprocess.Popen(["/bin/sleep", "30"], start_new_session=True)


def process_start(pid: int) -> str:
    return subprocess.check_output(
        ["ps", "-p", str(pid), "-o", "lstart="],
        env={**os.environ, "TZ": "UTC", "LC_ALL": "C"}, text=True,
    ).strip()


class ViewerRoutingTargetTests(unittest.TestCase):
    def test_stop_targets_the_viewer_surface_not_the_launcher(self):
        cli = resolve_cmux_cli()
        launcher_workspace, launcher_surface, viewer_workspace, viewer_surface = [
            str(uuid.uuid4()) for _ in range(4)]
        worker_session, launcher_session = str(uuid.uuid4()), str(uuid.uuid4())
        attachment = str(uuid.uuid4())
        worker = alive_process()
        launcher = alive_process()
        viewer = None
        try:
            with tempfile.TemporaryDirectory(prefix="cmux-viewer-routing-") as directory:
                home = Path(directory)
                config = home / ".claude"
                (config / "sessions").mkdir(parents=True)
                (config / "sessions" / f"{worker.pid}.json").write_text(json.dumps({
                    "kind": "bg", "pid": worker.pid, "sessionId": worker_session,
                    "jobId": worker_session[:8], "procStart": process_start(worker.pid),
                    "pidDomain": "darwin",
                }))
                state_path = home / "hooks.json"
                now = time.time()
                state_path.write_text(json.dumps({
                    "version": 1,
                    "sessions": {worker_session: {
                        "sessionId": worker_session,
                        "workspaceId": launcher_workspace, "surfaceId": launcher_surface,
                        "pid": worker.pid, "startedAt": now, "updatedAt": now,
                    }},
                    "activeSessionsBySurface": {
                        launcher_surface: {"sessionId": launcher_session, "updatedAt": now}},
                    "activeSessionsByWorkspace": {
                        launcher_workspace: {"sessionId": launcher_session, "updatedAt": now}},
                }))
                with MappedHookSocketServer(launcher_workspace, launcher_surface) as server:
                    server.pid_surfaces[worker.pid] = (launcher_workspace, launcher_surface)
                    server.pid_surfaces[launcher.pid] = (launcher_workspace, launcher_surface)
                    server.workspace_surfaces[launcher_workspace] = launcher_surface
                    server.workspace_surfaces[viewer_workspace] = viewer_surface
                    env = cli_environment(server.socket_path, home=directory)
                    env.update(
                        CLAUDE_CONFIG_DIR=str(config),
                        CMUX_CLAUDE_HOOK_STATE_PATH=str(state_path),
                        CMUX_CLAUDE_PID=str(worker.pid),
                        CMUX_WORKSPACE_ID=launcher_workspace,
                        CMUX_SURFACE_ID=launcher_surface,
                    )
                    go = home / "go"
                    result_file = home / "viewer-result.json"
                    stop_file = home / "viewer-stop"
                    helper = home / "viewer_helper.py"
                    helper.write_text(
                        "import json,os,subprocess,sys,time\n"
                        "cli,sock,go,result,stop,attachment,worker=sys.argv[1:8]\n"
                        "while not os.path.exists(go): time.sleep(0.01)\n"
                        "p=subprocess.run([cli,'--socket',sock,'__claude-viewer','attached'],\n"
                        " input=json.dumps({'attach_id':attachment,'job_id':worker[:8],\n"
                        " 'viewer_pid':os.getpid()}),capture_output=True,text=True,timeout=8)\n"
                        "tmp=result+'.tmp'\n"
                        "open(tmp,'w').write(json.dumps({'pid':os.getpid(),'code':p.returncode,'err':p.stderr}))\n"
                        "os.replace(tmp,result)\n"
                        "while not os.path.exists(stop): time.sleep(0.01)\n"
                    )
                    viewer = subprocess.Popen(
                        [os.sys.executable, str(helper), cli, server.socket_path, str(go),
                         str(result_file), str(stop_file), attachment, worker_session],
                        env=env, start_new_session=True)
                    server.pid_surfaces[viewer.pid] = (viewer_workspace, viewer_surface)
                    go.write_text("1")
                    deadline = time.monotonic() + 15
                    while not result_file.exists() and time.monotonic() < deadline:
                        time.sleep(0.02)
                    if not result_file.exists():
                        self.fail("viewer helper did not finish the attach call before the deadline")
                    outcome = json.loads(result_file.read_text())
                    self.assertEqual(outcome["code"], 0, outcome["err"])
                    state = json.loads(state_path.read_text())
                    self.assertEqual(state["sessions"][worker_session]["surfaceId"], viewer_surface)
                    self.assertEqual(state["activeSessionsBySurface"][viewer_surface]["sessionId"],
                                     worker_session)
                    self.assertEqual(state["activeSessionsByWorkspace"][viewer_workspace]["sessionId"],
                                     worker_session)
                    server.commands.clear()
                    stop = subprocess.run(
                        [cli, "--socket", server.socket_path, "hooks", "claude", "stop"],
                        input=json.dumps({
                            "session_id": worker_session, "hook_event_name": "Stop",
                            "cwd": directory, "last_assistant_message": "routing target test",
                        }), env=env, capture_output=True, text=True, timeout=8)
                    self.assertEqual(stop.returncode, 0, stop.stderr)
                    completed = [command for command in server.commands
                                 if "agent.turn.completed" in command]
                    self.assertTrue(completed, server.commands)
                    self.assertTrue(any(viewer_surface in command for command in completed),
                                    "completion did not target the viewer surface")
                    self.assertFalse(any(
                        "agent.turn.completed" in command and launcher_surface in command
                        for command in server.commands), "completion was routed to the launcher")
        finally:
            for process in (worker, launcher, viewer):
                if process is not None and process.poll() is None:
                    process.terminate()
                    process.wait(timeout=5)


if __name__ == "__main__":
    unittest.main()
