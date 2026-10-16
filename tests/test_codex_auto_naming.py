#!/usr/bin/env python3
"""Exercise Codex naming with isolated credentials, a fake CLI and a fake socket.

No running app, real credentials or model request is used.
"""
import argparse
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


def run_case(cli, custom_home):
    with tempfile.TemporaryDirectory(prefix="codex-naming-", dir="/tmp") as temporary:
        root = Path(temporary)
        workspace, surface = str(uuid.uuid4()), str(uuid.uuid4())
        session = str(uuid.uuid4())
        codex_home = root / ("custom-codex-home" if custom_home else ".codex")
        codex_home.mkdir(mode=0o700)
        config = 'model = "fixture-model"\n'
        (codex_home / "config.toml").write_text(config)
        credentials = '{"OPENAI_API_KEY":"fixture-key"}\n'
        auth = codex_home / "auth.json"
        auth.write_text(credentials)
        auth.chmod(0o600)
        observed = root / "observed.json"
        binary = root / "codex"
        binary.write_text(
            "#!/usr/bin/python3\n"
            "import json, os, pathlib, stat, sys\n"
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
            "auth.write_text('refreshed-fixture-login\\n')\n"
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
        requests = []
        socket_path = str(root / "control.sock")
        listener = socket.socket(socket.AF_UNIX)
        listener.bind(socket_path)
        listener.listen()
        listener.settimeout(0.1)
        stopped = threading.Event()

        def serve():
            while not stopped.is_set():
                try:
                    connection, _ = listener.accept()
                except socket.timeout:
                    continue
                with connection:
                    stream = connection.makefile("rwb")
                    for raw in stream:
                        if accept_fixture_socket_authentication(raw, stream):
                            continue
                        request = json.loads(raw)
                        requests.append(request)
                        result = {"enabled": True, "workspace_user_owned": False,
                                  "workspace_applied": True, "panel_applied": True}
                        stream.write((json.dumps({"id": request["id"], "ok": True,
                                                  "result": result}) + "\n").encode())
                        stream.flush()

        server = threading.Thread(target=serve)
        server.start()
        try:
            environment = {
                "HOME": temporary, "CFFIXED_USER_HOME": temporary,
                "PATH": f"{temporary}:/usr/bin:/bin",
                "CMUX_AGENT_HOOK_STATE_DIR": temporary,
                "CMUX_CLAUDE_HOOK_STATE_PATH": str(store),
                "CMUX_SOCKET_PATH": socket_path,
                "CMUX_CLI_SENTRY_DISABLED": "1"
            }
            if custom_home:
                environment["CODEX_HOME"] = str(codex_home)
            result = subprocess.run([
                cli, "--socket", socket_path, "--password", FIXTURE_SOCKET_PASSWORD,
                "hooks", "codex", "auto-name", "--session", session,
                "--workspace", workspace, "--surface", surface,
                "--transcript", str(transcript)
            ], env=environment, capture_output=True, text=True, timeout=15)
        finally:
            stopped.set()
            server.join(timeout=2)
            listener.close()
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
        assert auth.read_text() == "refreshed-fixture-login\n", "Refreshed login was discarded"
        assert (codex_home / "config.toml").read_text() == config
        print(f"PASS Codex saved login ({'custom CODEX_HOME' if custom_home else 'default home'})")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--cli", default=os.environ.get("CMUX_CLI_BIN"))
    args = parser.parse_args()
    if not args.cli:
        parser.error("--cli or CMUX_CLI_BIN is required")
    for custom_home in (False, True):
        run_case(str(Path(args.cli).resolve()), custom_home)
