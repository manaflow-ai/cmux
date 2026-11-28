#!/usr/bin/env python3
"""Exercise Codex naming with isolated credentials, a fake CLI and a fake socket.

No running app, real credentials or model request is used.
"""
import argparse
from contextlib import contextmanager, suppress
import json
import os
from pathlib import Path
import socket
import subprocess
import tempfile
import threading
import time
import uuid

from claude_teams_test_utils import FIXTURE_SOCKET_PASSWORD, accept_fixture_socket_authentication


@contextmanager
def naming_socket_server(socket_path, workspace, surface, trigger):
    requests = []
    applied_event = threading.Event()
    listener = socket.socket(socket.AF_UNIX)
    listener.bind(socket_path)
    listener.listen()
    listener.settimeout(0.1)
    stopped = threading.Event()
    connection_lock = threading.Lock()
    active_connection = None

    def serve():
        nonlocal active_connection
        while not stopped.is_set():
            try:
                connection, _ = listener.accept()
            except socket.timeout:
                continue
            # Closing the buffered stream can repeat a handled broken-pipe write.
            with connection, suppress(BrokenPipeError), connection.makefile("rwb") as stream:
                with connection_lock:
                    if stopped.is_set():
                        break
                    active_connection = connection
                applied_on_connection = False
                for raw in stream:
                    prefix = b"_cmux_capability_v1 fixture-local-capability "
                    has_capability = raw.startswith(prefix)
                    if has_capability:
                        raw = raw[len(prefix):]
                    try:
                        if trigger == "stop" and not has_capability:
                            stream.write(b"ERROR: Access denied\n")
                            stream.flush()
                            break
                        if accept_fixture_socket_authentication(raw, stream):
                            continue
                        if not raw.lstrip().startswith(b"{"):
                            stream.write(b"OK\n")
                            stream.flush()
                            continue
                    except BrokenPipeError:
                        break
                    request = json.loads(raw)
                    requests.append(request)
                    result = {"enabled": True, "workspace_user_owned": False,
                              "workspace_applied": True, "panel_applied": True,
                              "surfaces": [{"id": surface, "ref": "surface:1", "focused": True}]}
                    if request.get("method") == "agent.resolve_delivery_target":
                        result = {"source": "surface", "workspace_id": workspace, "surface_id": surface}
                    applied_on_connection |= bool(request.get("params", {}).get("title"))
                    try:
                        stream.write((json.dumps({"id": request["id"], "ok": True,
                                                  "result": result}) + "\n").encode())
                        stream.flush()
                    except BrokenPipeError:
                        break
                if applied_on_connection:
                    applied_event.set()
            with connection_lock:
                active_connection = None

    server = threading.Thread(target=serve)
    server.start()
    try:
        yield requests, applied_event
    finally:
        # Serialize shutdown with accept registration so no new read can start
        # after teardown has checked the active connection.
        with connection_lock:
            stopped.set()
            if active_connection is not None:
                try:
                    active_connection.shutdown(socket.SHUT_RDWR)
                except OSError:
                    pass  # The peer or server may already have closed it.
        server.join(timeout=2)
        listener.close()
        assert not server.is_alive(), "Socket fixture thread did not stop"


def test_socket_server_closes_stalled_client():
    with tempfile.TemporaryDirectory(prefix="codex-naming-cleanup-", dir="/tmp") as temporary:
        socket_path = str(Path(temporary) / "control.sock")
        with socket.socket(socket.AF_UNIX) as client:
            # Bound this regression even when fixture teardown leaves its read blocked.
            client.settimeout(3)
            with naming_socket_server(socket_path, "workspace", "surface", "auto-name"):
                client.connect(socket_path)
                client.sendall(f"auth {FIXTURE_SOCKET_PASSWORD}\n".encode())
                assert client.recv(1024) == b"OK\n", "Fixture did not accept the client"
            assert client.recv(1) == b"", "Fixture left the stalled connection open"
    print("PASS socket fixture closes a stalled client")


def run_case(cli, custom_home, trigger, codex=None):
    with tempfile.TemporaryDirectory(prefix="codex-naming-", dir="/tmp") as temporary:
        root = Path(temporary)
        workspace, surface = str(uuid.uuid4()).upper(), str(uuid.uuid4()).upper()
        session = str(uuid.uuid4())
        codex_home = root / ("custom-codex-home" if custom_home else ".codex")
        codex_home.mkdir(mode=0o700)
        config = 'model = "fixture-model"\ncli_auth_credentials_store = "auto"\n'
        (codex_home / "config.toml").write_text(config)
        credentials = '{"OPENAI_API_KEY":"fixture-key"}\n'
        auth = codex_home / "auth.json"
        auth.write_text(credentials)
        auth.chmod(0o600)
        observed = root / "observed.json"
        binary = root / "codex"
        binary.write_text(
            "#!/usr/bin/python3\n"
            "import json, os, pathlib, stat, subprocess, sys\n"
            "home = pathlib.Path(os.environ['CODEX_HOME'])\n"
            "auth = home / 'auth.json'\n"
            "args = sys.argv[1:]\n"
            f"pathlib.Path({str(observed)!r}).write_text(json.dumps({{\n"
            "    'home': str(home), 'args': args,\n"
            "    'home_mode': stat.S_IMODE(home.stat().st_mode),\n"
            "    'auth_present': auth.is_file(),\n"
            "    'auth_mode': stat.S_IMODE(auth.stat().st_mode) if auth.is_file() else None\n"
            "}))\n"
            "sys.stdin.read()\n"
            f"if not auth.is_file() or auth.read_text() != {credentials!r}: sys.exit(1)\n"
            "store = 'auto'\n"
            "for flag, value in zip(args, args[1:]):\n"
            "    if flag == '-c' and value.startswith('cli_auth_credentials_store='):\n"
            "        store = json.loads(value.split('=', 1)[1])\n"
            f"codex = {codex!r}\n"
            "if codex:\n"
            "    # Never let this probe access the real OS keyring. Login and\n"
            "    # OAuth refresh share Codex's credential storage backend.\n"
            "    if store != 'file': sys.exit('Linked credentials must use file storage')\n"
            "    subprocess.run([codex, 'login', '-c', 'cli_auth_credentials_store=\\\"file\\\"',\n"
            "                    '--with-api-key'], input='refreshed-fixture-login\\n',\n"
            "                   text=True, env=os.environ, check=True, timeout=10)\n"
            "elif store == 'file':\n"
            "    auth.write_text('refreshed-fixture-login\\n')\n"
            "else:\n"
            "    # auto can load the file, then save to the keyring and remove\n"
            "    # the fallback link, leaving the original credentials stale.\n"
            "    auth.unlink()\n"
            "output = pathlib.Path(args[args.index('--output-last-message') + 1])\n"
            "output.write_text('Repair Codex Naming')\n"
        )
        binary.chmod(0o755)
        transcript = root / "rollout.jsonl"
        transcript.write_text("\n".join(json.dumps({
            "type": "response_item", "payload": {
                "type": "message", "role": role,
                "content": [{"type": "input_text" if role == "user" else "output_text",
                             "text": "Repair Codex workspace naming"}]
            }
        }) for _ in range(8) for role in ("user", "assistant")))
        now = time.time()
        store = root / "codex-hook-sessions.json"
        store.write_text(json.dumps({"version": 1, "sessions": {session: {
            "sessionId": session, "workspaceId": workspace, "surfaceId": surface,
            "transcriptPath": str(transcript), "startedAt": now, "updatedAt": now
        }}}))
        socket_path = str(root / "control.sock")
        with naming_socket_server(socket_path, workspace, surface, trigger) as (requests, applied_event):
            environment = {
                "HOME": temporary, "CFFIXED_USER_HOME": temporary,
                "PATH": f"{temporary}:/usr/bin:/bin",
                "CMUX_AGENT_HOOK_STATE_DIR": temporary,
                "CMUX_CLAUDE_HOOK_STATE_PATH": str(store),
                "CMUX_SOCKET_PATH": socket_path,
                "CMUX_SOCKET_PASSWORD": FIXTURE_SOCKET_PASSWORD,
                "CMUX_WORKSPACE_ID": workspace, "CMUX_SURFACE_ID": surface,
                "CMUX_CODEX_PID": str(os.getpid()),
                "CMUX_CLI_SENTRY_DISABLED": "1"
            }
            if custom_home:
                environment["CODEX_HOME"] = str(codex_home)
            arguments = [
                cli, "--socket", socket_path, "--password", FIXTURE_SOCKET_PASSWORD,
                "hooks", "codex", trigger
            ]
            if trigger == "auto-name":
                arguments += ["--session", session, "--workspace", workspace,
                              "--surface", surface, "--transcript", str(transcript)]
            else:
                # Model the app-issued worker capability. The separate delivery
                # process regression verifies that local workers receive it.
                environment["CMUX_SOCKET_CAPABILITY"] = "fixture-local-capability"
            result = subprocess.run(arguments, input=json.dumps({
                "hook_event_name": "Stop", "session_id": session,
                "cwd": temporary, "transcript_path": str(transcript),
                "last_assistant_message": "Repair Codex Naming"
            }), env=environment, capture_output=True, text=True, timeout=15)
            if trigger == "stop":
                assert applied_event.wait(8), "Stop hook never applied an automatic title"
        assert result.returncode == 0, result.stderr
        assert observed.is_file(), "Codex summarizer was not invoked"
        invocation = json.loads(observed.read_text())
        assert invocation["auth_present"], "Isolated Codex profile lost the saved login"
        assert invocation["home_mode"] == 0o700, invocation
        assert invocation["auth_mode"] == 0o600, invocation
        assert "fixture-key" not in " ".join(invocation["args"]), invocation
        applied = [r["params"] for r in requests if r.get("params", {}).get("title")]
        assert applied and applied[-1]["title"] == "Repair Codex Naming", requests
        assert applied[-1]["workspace_id"] == workspace
        assert applied[-1]["panel_id"] == surface
        record = json.loads(store.read_text())["sessions"][session]
        assert record["autoNameLastTitle"] == "Repair Codex Naming", record
        assert not record.get("autoNameInFlightAt"), record
        assert not Path(invocation["home"]).exists(), "Temporary credentials were not cleaned up"
        saved = json.loads(auth.read_text())["OPENAI_API_KEY"] if codex else auth.read_text().strip()
        assert saved == "refreshed-fixture-login", "Refreshed login was discarded"
        assert (codex_home / "config.toml").read_text() == config
        print(f"PASS Codex {trigger} ({'custom CODEX_HOME' if custom_home else 'default home'})")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--cli", default=os.environ.get("CMUX_CLI_BIN"))
    parser.add_argument("--codex", help="Use a real Codex login storage backend with fixture credentials")
    args = parser.parse_args()
    if not args.cli:
        parser.error("--cli or CMUX_CLI_BIN is required")
    test_socket_server_closes_stalled_client()
    for trigger in ("auto-name", "stop"):
        for custom_home in (False, True):
            run_case(str(Path(args.cli).resolve()), custom_home, trigger,
                     str(Path(args.codex).resolve()) if args.codex else None)
