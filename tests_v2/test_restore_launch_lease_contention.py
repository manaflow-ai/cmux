#!/usr/bin/env python3
"""Run two real restore CLIs with isolated homes, PTYs, and an app RPC fixture.

Usage: python3 tests_v2/test_restore_launch_lease_contention.py --cli /path/to/cmux
With no --cli, discover it from the test runner's configured app (read-only).
Restores never access that app's panes or real Codex data. The first restore
execs a stand-in agent and the real cmux exit watcher holds its launch lease.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import pty
import select
import socketserver
import subprocess
import sys
import tempfile
import threading
import time
import uuid


def exercise(cli: Path, reports_owner: bool, owner_cli: Path, launching: bool = False,
             presentation: str | None = None) -> None:
    with tempfile.TemporaryDirectory(prefix="cmux-15111-", dir="/tmp") as temporary:
        root = Path(temporary).resolve()
        home = root / "codex-home"
        sessions = home / "sessions"
        sessions.mkdir(parents=True)
        session = str(uuid.uuid4())
        workspace, surface = str(uuid.uuid4()), str(uuid.uuid4())
        (sessions / f"rollout-{session}.jsonl").write_text(json.dumps({
            "type": "session_meta",
            "payload": {"id": session, "cwd": str(root), "source": "cli", "originator": "codex-tui"},
        }) + "\n")
        executable = root / "codex"
        executable.write_text(
            "#!/usr/bin/python3\nimport os\n"
            "print('READY ' + str(os.getpid()), flush=True)\n"
            "os.read(0, 1)\n"
        )
        executable.chmod(0o700)
        owner_pid: int | None = None
        requests: list[str] = []
        retargeting = threading.Event()
        finished = threading.Event()
        record = {
            "kind": "codex", "mode": "resumeAgent", "checkpoint_id": session,
            "source": "session-snapshot", "working_directory": str(root),
            "environment": {"CODEX_HOME": str(home)},
            "launch_command": {"launcher": "codex", "executable_path": str(executable),
                               "arguments": [str(executable), "resume", session]},
        }

        class Handler(socketserver.StreamRequestHandler):
            def handle(self) -> None:
                for line in self.rfile:
                    request = json.loads(line)
                    method = request["method"]
                    requests.append(method)
                    if method == "surface.resume.get":
                        if retargeting.is_set() and presentation == "slow-retarget":
                            finished.wait()
                            return
                        current_workspace = str(uuid.uuid4()) if retargeting.is_set() else workspace
                        result = {"workspace_id": current_workspace, "surface_id": surface,
                                  "restore_record": record, "agent_restore_admission_supported": True}
                    elif method == "agent.restore.admit":
                        if owner_pid is None:
                            result = {"admitted": True, "claim_id": str(uuid.uuid4())}
                        elif presentation in ("slow-retarget", "moving"):
                            retargeting.set()
                            if presentation == "moving":
                                finished.wait(timeout=0.01)
                            self.wfile.write((json.dumps({"id": request.get("id"), "ok": False,
                                "error": {"code": "conflict", "message": "fixture surface moved"}}) + "\n").encode())
                            continue
                        elif presentation == "slow-release":
                            result = {"admitted": True, "claim_id": str(uuid.uuid4())}
                        else:
                            # Older apps mark even a known live owner recovering.
                            result = {"admitted": False, "recovering": True}
                            if reports_owner:
                                result["live_owner_pid"] = owner_pid
                    elif method == "agent.restore.release":
                        if presentation == "slow-release":
                            finished.wait()
                            return
                        result = {"released": True}
                    else:
                        raise AssertionError(method)
                    self.wfile.write((json.dumps({"id": request.get("id"), "ok": True, "result": result}) + "\n").encode())

        class Server(socketserver.ThreadingUnixStreamServer):
            daemon_threads = True

            def handle_error(self, request, client_address) -> None:
                # A bounded client can close while a deliberately late reply is
                # being written. Other fixture errors must remain visible.
                if not isinstance(sys.exc_info()[1], (BrokenPipeError, ConnectionResetError)):
                    super().handle_error(request, client_address)

        path = root / "app.sock"
        server = Server(str(path), Handler)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        environment = {
            "HOME": str(root), "CFFIXED_USER_HOME": str(root), "CODEX_HOME": str(home),
            "CMUX_SOCKET_PATH": str(path), "CMUX_CLI_SENTRY_DISABLED": "1",
            "SHELL": "/bin/sh", "PATH": "/usr/bin:/bin", "LANG": "en_US.UTF-8",
        }
        for key in ("DYLD_LIBRARY_PATH", "DYLD_FRAMEWORK_PATH"):
            if key in os.environ:
                environment[key] = os.environ[key]
        command = [str(cli), "restore", "--surface", surface, "codex", session]
        owner_command = [str(owner_cli), *command[1:]]
        if launching:
            directory = root / ".cmuxterm" / "agent-restore-launches"
            directory.mkdir(parents=True, mode=0o700)
            key = hashlib.sha256((str(home) + "\0" + session).encode()).hexdigest()
            lease_path = directory / (key + ".lock")
            owner_command = ["/usr/bin/python3", "-c", (
                "import fcntl, os, sys\n"
                "fd = os.open(sys.argv[1], os.O_CREAT | os.O_RDWR, 0o600)\n"
                "fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)\n"
                "print('READY ' + str(os.getpid()), flush=True)\n"
                "os.read(0, 1)\n"
            ), str(lease_path)]
        first_master, first_slave = pty.openpty()
        second_master, second_slave = pty.openpty()
        first = second = None
        try:
            first = subprocess.Popen(owner_command, env=environment, cwd=root,
                                     stdin=first_slave, stdout=first_slave, stderr=first_slave)
            deadline = time.monotonic() + 10
            output = b""
            while b"READY " not in output or not output.endswith(b"\n"):
                remaining = deadline - time.monotonic()
                assert remaining > 0, f"First restore never launched: {output!r}"
                assert select.select([first_master], [], [], remaining)[0], output
                output += os.read(first_master, 4096)
            owner_pid = int(output.split(b"READY ")[1].split()[0])
            assert owner_pid == first.pid, "The watcher must track the exec'd restore PID"
            started = time.monotonic()
            second = subprocess.Popen(command, env=environment, cwd=root,
                                      stdin=second_slave, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            try:
                # Leave startup headroom while still detecting the old 15s
                # socket timeout. Stalled fixture replies remain held until
                # cleanup, so they cannot make a missing deadline look correct.
                stdout, stderr = second.communicate(timeout=10)
            except subprocess.TimeoutExpired as error:
                raise AssertionError("Second restore waited on a live lease owner instead of rejecting") from error
            elapsed = time.monotonic() - started
            assert second.returncode != 0, (stdout, stderr)
            expected = ("another launch of this agent session is already starting" if launching
                        else f"already running in process {owner_pid}").encode()
            assert expected in stderr, (stdout, stderr, requests)
            assert first.poll() is None, "Contender must not stop the live owner"
            assert b"READY" not in stdout, "Contender launched another writer"
            print(f"PASS reports_owner={reports_owner} launching={launching} presentation={presentation}: "
                  f"terminal rejection in {elapsed:.3f}s; no second writer")
        finally:
            finished.set()
            for process in (second, first):
                if process is not None and process.poll() is None:
                    process.terminate()
                    process.wait(timeout=5)
            for descriptor in (first_master, first_slave, second_master, second_slave):
                os.close(descriptor)
            server.shutdown()
            server.server_close()
            thread.join(timeout=5)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--cli", type=Path, default=os.environ.get("CMUX_BUNDLED_CLI_PATH")
                        or os.environ.get("CMUXTERM_CLI"))
    parser.add_argument("--owner-cli", type=Path, help="Optional older CLI to verify stable/nightly interoperability")
    arguments = parser.parse_args()
    if arguments.cli is None:
        socket_path = os.environ.get("CMUX_SOCKET_PATH")
        if not socket_path:
            parser.error("Pass --cli or set CMUX_BUNDLED_CLI_PATH / CMUX_SOCKET_PATH")
        from cmux import cmux
        with cmux(socket_path) as client:
            identity = client._call("system.identify")
        arguments.cli = Path(identity["app_bundle_path"]) / "Contents/Resources/bin/cmux"
    for reports_owner in (True, False):
        exercise(arguments.cli.resolve(), reports_owner, (arguments.owner_cli or arguments.cli).resolve())
    exercise(arguments.cli.resolve(), False, arguments.cli.resolve(), launching=True)
    for presentation in ("slow-retarget", "slow-release", "moving"):
        exercise(arguments.cli.resolve(), False, arguments.cli.resolve(), presentation=presentation)


if __name__ == "__main__":
    main()
