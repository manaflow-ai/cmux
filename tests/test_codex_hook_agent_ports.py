#!/usr/bin/env python3
"""
E2E regression test for Codex hook agent PID registration and sidebar ports.

Validates:
1) `cmux hooks codex session-start` records the inferred agent root PID.
2) a dev server launched under that agent process tree appears in sidebar ports.
3) the port disappears once the agent process tree exits.
"""

from __future__ import annotations

import json
import os
import shutil
import signal
import socket
import subprocess
import sys
import tempfile
import time
import uuid
from pathlib import Path

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from claude_teams_test_utils import resolve_cmux_cli
from cmux import cmux, cmuxError


_PREFERRED_BIND_HOST = "127.0.0.1"


def _parse_sidebar_state(text: str) -> dict[str, str]:
    data: dict[str, str] = {}
    for raw in (text or "").splitlines():
        line = raw.rstrip("\n")
        if not line or line.startswith("  ") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        data[key.strip()] = v.strip() if (v := value.strip()) else ""
    return data


def _wait_for(predicate, timeout: float, interval: float, label: str):
    start = time.time()
    last_error: Exception | None = None
    while time.time() - start < timeout:
        try:
            value = predicate()
            if value:
                return value
        except Exception as exc:
            last_error = exc
        time.sleep(interval)
    if last_error is not None:
        raise AssertionError(f"Timed out waiting for {label}. Last error: {last_error}")
    raise AssertionError(f"Timed out waiting for {label}.")


def _find_free_port() -> int:
    for _ in range(50):
        sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        try:
            sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
            sock.bind((_PREFERRED_BIND_HOST, 0))
            return int(sock.getsockname()[1])
        finally:
            try:
                sock.close()
            except Exception:
                pass
    raise RuntimeError("Failed to find a free test port.")


def _wait_for_lsof_listen_pid(port: int, expected_pid: int | None, timeout: float = 8.0) -> int:
    def pred():
        result = subprocess.run(
            ["lsof", "-nP", f"-iTCP:{port}", "-sTCP:LISTEN", "-t"],
            capture_output=True,
            text=True,
        )
        if result.returncode != 0:
            return None
        pids = []
        for line in (result.stdout or "").splitlines():
            line = line.strip()
            if not line:
                continue
            try:
                pids.append(int(line))
            except ValueError:
                continue
        if not pids:
            return None
        if expected_pid is not None and expected_pid not in pids:
            return None
        return expected_pid if expected_pid is not None else pids[0]

    return int(_wait_for(pred, timeout=timeout, interval=0.15, label=f"lsof LISTEN pid for {port}"))


def _wait_for_lsof_listen_gone(port: int, timeout: float = 8.0) -> None:
    def pred():
        result = subprocess.run(
            ["lsof", "-nP", f"-iTCP:{port}", "-sTCP:LISTEN", "-t"],
            capture_output=True,
            text=True,
        )
        return result.returncode != 0 or not (result.stdout or "").strip()

    _wait_for(pred, timeout=timeout, interval=0.15, label=f"lsof no LISTEN for {port}")


def _wait_for_port(client: cmux, workspace_id: str, port: int, timeout: float = 18.0) -> dict[str, str]:
    def pred():
        state = _parse_sidebar_state(client.sidebar_state(tab=workspace_id))
        raw = state.get("ports", "")
        if raw == "none" or not raw:
            return None
        try:
            ports = {int(item.strip()) for item in raw.split(",") if item.strip()}
        except ValueError:
            return None
        return state if port in ports else None

    return _wait_for(pred, timeout=timeout, interval=0.15, label=f"ports include {port}")


def _wait_for_port_absent(client: cmux, workspace_id: str, port: int, timeout: float = 18.0) -> dict[str, str]:
    def pred():
        state = _parse_sidebar_state(client.sidebar_state(tab=workspace_id))
        raw = state.get("ports", "")
        if raw == "none" or not raw:
            return state
        try:
            ports = {int(item.strip()) for item in raw.split(",") if item.strip()}
        except ValueError:
            return state
        return state if port not in ports else None

    return _wait_for(pred, timeout=timeout, interval=0.15, label=f"ports do not include {port}")


def _terminate_process_group(proc: subprocess.Popen | None) -> None:
    if proc is None:
        return
    try:
        os.killpg(proc.pid, signal.SIGTERM)
    except ProcessLookupError:
        return
    except Exception:
        try:
            proc.terminate()
        except Exception:
            return
    try:
        proc.wait(timeout=3.0)
    except subprocess.TimeoutExpired:
        try:
            os.killpg(proc.pid, signal.SIGKILL)
        except Exception:
            try:
                proc.kill()
            except Exception:
                pass
        try:
            proc.wait(timeout=2.0)
        except Exception:
            pass


def _start_fake_codex_launcher(
    base: Path,
    cli_path: str,
    socket_path: str,
    workspace_id: str,
    surface_id: str,
    state_path: Path,
    session_id: str,
    cwd: Path,
    port: int,
) -> tuple[subprocess.Popen, Path, Path, Path]:
    launcher_script = base / "fake_codex_launcher.py"
    suffix = session_id.replace("/", "-")
    ready_file = base / f"fake_codex_ready_{suffix}"
    start_file = base / f"fake_codex_start_{suffix}"
    server_pid_file = base / f"fake_codex_server_{suffix}.pid"
    server_log_file = base / f"fake_codex_server_{suffix}.log"
    launcher_script.write_text(
        """#!/usr/bin/env python3
import json
import os
import signal
import subprocess
import sys
import time
from pathlib import Path

host = os.environ["CMUX_TEST_BIND_HOST"]
port = int(os.environ["CMUX_TEST_PORT"])
cli_path = os.environ["CMUX_TEST_CLI_PATH"]
socket_path = os.environ["CMUX_TEST_SOCKET_PATH"]
workspace_id = os.environ["CMUX_WORKSPACE_ID"]
surface_id = os.environ["CMUX_SURFACE_ID"]
state_path = os.environ["CMUX_CLAUDE_HOOK_STATE_PATH"]
session_id = os.environ["CMUX_TEST_SESSION_ID"]
cwd = os.environ["CMUX_TEST_CWD"]
ready_file = Path(os.environ["CMUX_TEST_READY_FILE"])
start_file = Path(os.environ["CMUX_TEST_START_FILE"])
server_pid_file = Path(os.environ["CMUX_TEST_SERVER_PID_FILE"])
server_log_file = Path(os.environ["CMUX_TEST_SERVER_LOG_FILE"])

hook_env = os.environ.copy()
hook_env["CMUX_SOCKET_PATH"] = socket_path
hook_env["CMUX_WORKSPACE_ID"] = workspace_id
hook_env["CMUX_SURFACE_ID"] = surface_id
hook_env["CMUX_CLAUDE_HOOK_STATE_PATH"] = state_path
payload = json.dumps({"session_id": session_id, "cwd": cwd})
result = subprocess.run(
    [cli_path, "--socket", socket_path, "hooks", "codex", "session-start"],
    input=payload,
    text=True,
    capture_output=True,
    env=hook_env,
    check=False,
)
if result.returncode != 0:
    raise SystemExit(
        f"hooks codex session-start failed: exit={result.returncode} "
        f"stdout={result.stdout!r} stderr={result.stderr!r}"
    )

ready_file.write_text("ok", encoding="utf-8")

def _handle_term(signum, frame):
    raise KeyboardInterrupt

signal.signal(signal.SIGTERM, _handle_term)
signal.signal(signal.SIGINT, _handle_term)

server = None
log_handle = None
try:
    while True:
        if server is None and start_file.exists():
            log_handle = server_log_file.open("w", encoding="utf-8")
            server = subprocess.Popen(
                [sys.executable, "-m", "http.server", str(port), "--bind", host],
                cwd=cwd,
                stdout=log_handle,
                stderr=subprocess.STDOUT,
            )
            server_pid_file.write_text(str(server.pid), encoding="utf-8")
        time.sleep(0.1 if server is None else 1.0)
except KeyboardInterrupt:
    pass
finally:
    if server is not None:
        server.terminate()
        try:
            server.wait(timeout=3.0)
        except subprocess.TimeoutExpired:
            server.kill()
    if log_handle is not None:
        log_handle.close()
""",
        encoding="utf-8",
    )

    env = os.environ.copy()
    env["CMUX_TEST_BIND_HOST"] = _PREFERRED_BIND_HOST
    env["CMUX_TEST_PORT"] = str(port)
    env["CMUX_TEST_CLI_PATH"] = cli_path
    env["CMUX_TEST_SOCKET_PATH"] = socket_path
    env["CMUX_WORKSPACE_ID"] = workspace_id
    env["CMUX_SURFACE_ID"] = surface_id
    env["CMUX_CLAUDE_HOOK_STATE_PATH"] = str(state_path)
    env["CMUX_TEST_SESSION_ID"] = session_id
    env["CMUX_TEST_CWD"] = str(cwd)
    env["CMUX_TEST_READY_FILE"] = str(ready_file)
    env["CMUX_TEST_START_FILE"] = str(start_file)
    env["CMUX_TEST_SERVER_PID_FILE"] = str(server_pid_file)
    env["CMUX_TEST_SERVER_LOG_FILE"] = str(server_log_file)

    proc = subprocess.Popen(
        [sys.executable, str(launcher_script)],
        cwd=str(base),
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        env=env,
        start_new_session=True,
    )
    return proc, ready_file, start_file, server_pid_file


def fail(message: str) -> int:
    print(f"FAIL: {message}")
    return 1


def main() -> int:
    try:
        cli_path = resolve_cmux_cli()
    except Exception as exc:
        return fail(str(exc))

    state_path = Path(tempfile.gettempdir()) / f"cmux_codex_hook_state_{os.getpid()}.json"
    lock_path = Path(str(state_path) + ".lock")
    base = Path(tempfile.gettempdir()) / f"cmux_codex_ports_{os.getpid()}"
    launcher_procs: list[subprocess.Popen] = []

    try:
        if base.exists():
            shutil.rmtree(base)
        base.mkdir(parents=True, exist_ok=True)
        if state_path.exists():
            state_path.unlink()
        if lock_path.exists():
            lock_path.unlink()

        project_dir = base / "project"
        project_dir.mkdir(parents=True, exist_ok=True)
        session_ids = [f"codex-sess-{uuid.uuid4().hex}", f"codex-sess-{uuid.uuid4().hex}"]
        ports: list[int] = []
        while len(ports) < 2:
            candidate = _find_free_port()
            if candidate not in ports:
                ports.append(candidate)

        with cmux() as client:
            workspace_id = client.new_workspace()
            client.select_workspace(workspace_id)
            surfaces = client.list_surfaces(tab=workspace_id)
            if not surfaces:
                return fail("Expected at least one surface in new workspace")

            focused = next((surface for surface in surfaces if surface[2]), surfaces[0])
            surface_id = focused[1]

            launcher_infos: list[tuple[subprocess.Popen, str, int, Path, Path, Path]] = []
            for session_id, port in zip(session_ids, ports):
                launcher_proc, ready_file, start_file, server_pid_file = _start_fake_codex_launcher(
                    base=base,
                    cli_path=cli_path,
                    socket_path=client.socket_path,
                    workspace_id=workspace_id,
                    surface_id=surface_id,
                    state_path=state_path,
                    session_id=session_id,
                    port=port,
                    cwd=project_dir,
                )
                launcher_procs.append(launcher_proc)
                launcher_infos.append((launcher_proc, session_id, port, ready_file, start_file, server_pid_file))

            for _, session_id, port, ready_file, _, server_pid_file in launcher_infos:
                _wait_for(lambda: ready_file.exists(), timeout=6.0, interval=0.1, label=f"{session_id} ready file")
                if server_pid_file.exists():
                    return fail(f"Server for {session_id} should not exist before start trigger")

            if not state_path.exists():
                return fail(f"Expected state file at {state_path}")
            with state_path.open("r", encoding="utf-8") as handle:
                state_data = json.load(handle)
            sessions = state_data.get("sessions") or {}
            for launcher_proc, session_id, _, _, _, _ in launcher_infos:
                session_row = sessions.get(session_id)
                if not session_row:
                    return fail(f"Expected mapped session row for {session_id} after codex session-start")
                if session_row.get("pid") != launcher_proc.pid:
                    return fail(
                        f"Expected codex hook to store launcher pid {launcher_proc.pid} for {session_id}, "
                        f"got {session_row.get('pid')!r}"
                    )

            for _, _, port, _, _, _ in launcher_infos:
                _wait_for_port_absent(client, workspace_id, port, timeout=3.0)

            for _, session_id, port, _, start_file, server_pid_file in launcher_infos:
                start_file.write_text("start", encoding="utf-8")
                _wait_for(lambda: server_pid_file.exists(), timeout=6.0, interval=0.1, label=f"{session_id} server pid file")
                server_pid = int(server_pid_file.read_text(encoding="utf-8").strip())
                _wait_for_lsof_listen_pid(port, expected_pid=server_pid, timeout=8.0)
                _wait_for_port(client, workspace_id, port, timeout=18.0)

            first_launcher, first_session_id, first_port, _, _, _ = launcher_infos[0]
            _terminate_process_group(first_launcher)
            launcher_procs = [proc for proc in launcher_procs if proc.pid != first_launcher.pid]
            _wait_for_lsof_listen_gone(first_port, timeout=8.0)
            _wait_for_port_absent(client, workspace_id, first_port, timeout=18.0)
            _wait_for_port(client, workspace_id, ports[1], timeout=18.0)
            client.clear_agent_pid(f"codex.{first_session_id}", tab=workspace_id)

            second_launcher, second_session_id, second_port, _, _, _ = launcher_infos[1]
            _terminate_process_group(second_launcher)
            launcher_procs = [proc for proc in launcher_procs if proc.pid != second_launcher.pid]
            _wait_for_lsof_listen_gone(second_port, timeout=8.0)
            _wait_for_port_absent(client, workspace_id, second_port, timeout=18.0)
            client.clear_agent_pid(f"codex.{second_session_id}", tab=workspace_id)

            print("PASS: Codex hook agent PID registration keeps multiple agent-owned ports accurate")
            return 0

    except (cmuxError, RuntimeError, AssertionError, ValueError) as exc:
        return fail(str(exc))
    finally:
        for launcher_proc in launcher_procs:
            _terminate_process_group(launcher_proc)
        try:
            if state_path.exists():
                state_path.unlink()
            if lock_path.exists():
                lock_path.unlink()
            shutil.rmtree(base, ignore_errors=True)
        except Exception:
            pass


if __name__ == "__main__":
    raise SystemExit(main())
