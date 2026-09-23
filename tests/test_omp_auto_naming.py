#!/usr/bin/env python3
"""Exercise bundled CLI naming against strict Pi/OMP subprocess fixtures.

Run with --cli /path/to/tagged/app/Contents/Resources/bin/cmux.
The fake socket and HOME are isolated; no running app or provider is required.
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


def run_case(cli, agent, override=None):
    with tempfile.TemporaryDirectory(prefix="omp-naming-", dir="/tmp") as temporary:
        root = Path(temporary)
        workspace, surface = str(uuid.uuid4()), str(uuid.uuid4())
        session = "naming-regression"
        selected = override or agent
        agent_binary = root / selected
        flags = ["--print", "--no-tools", "--no-session", "--no-extensions", "--no-skills"]
        flags += ["--no-rules"] if selected == "omp" else ["--no-prompt-templates", "--no-context-files"]
        agent_binary.write_text(
            "#!/usr/bin/python3\nimport json, pathlib, sys\n"
            f"pathlib.Path({str(root / 'argv.json')!r}).write_text(json.dumps(sys.argv[1:]))\n"
            f"expected = {flags!r}\n"
            "if sys.argv[1:1+len(expected)] != expected: sys.exit(2)\n"
            "assert len(sys.argv) == len(expected) + 3\n"
            "prompt = pathlib.Path(sys.argv[-2][1:])\n"
            "assert prompt.is_file() and prompt.stat().st_mode & 0o777 == 0o600\n"
            "assert 'Repair OMP workspace naming' in prompt.read_text()\n"
            "print('Repair OMP Naming')\n"
        )
        agent_binary.chmod(0o755)
        now = time.time()
        store = root / f"{agent}-hook-sessions.json"
        store.write_text(json.dumps({"version": 1, "sessions": {session: {
            "sessionId": session, "workspaceId": workspace, "surfaceId": surface,
            "startedAt": now, "updatedAt": now,
            "autoNameMessageSequence": 20,
            "autoNameRecentMessages": [
                {"role": "user", "text": "Repair OMP workspace naming"},
                {"role": "assistant", "text": "Use the supported isolation flags."}
            ]
        }}}))
        requests = []
        socket_path = str(root / "control.sock")
        listener = socket.socket(socket.AF_UNIX)
        listener.bind(socket_path)
        listener.listen()
        listener.settimeout(0.2)
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
                        request = json.loads(raw)
                        requests.append(request)
                        result = {"enabled": True, "workspace_user_owned": False,
                                  "workspace_applied": True, "panel_applied": True}
                        if override:
                            result["summarizer_agent"] = override
                        stream.write((json.dumps({"id": request["id"], "ok": True,
                                                  "result": result}) + "\n").encode())
                        stream.flush()

        server = threading.Thread(target=serve)
        server.start()
        try:
            environment = {
                "HOME": temporary, "PATH": f"{temporary}:/usr/bin:/bin",
                "CMUX_AGENT_HOOK_STATE_DIR": temporary,
                "CMUX_CLAUDE_HOOK_STATE_PATH": str(store),
                "CMUX_SOCKET_PATH": socket_path,
                "CMUX_CLI_SENTRY_DISABLED": "1",
            }
            result = subprocess.run([
                cli, "--socket", socket_path, "hooks", agent, "auto-name",
                "--session", session, "--workspace", workspace, "--surface", surface
            ], env=environment, capture_output=True, text=True, timeout=20)
        finally:
            stopped.set()
            server.join(timeout=2)
            listener.close()
        assert result.returncode == 0, result.stderr
        applied = [r["params"] for r in requests if r.get("params", {}).get("title")]
        argv = (root / "argv.json").read_text() if (root / "argv.json").exists() else "not invoked"
        assert applied and applied[-1]["title"] == "Repair OMP Naming", (requests, argv)
        assert applied[-1]["workspace_id"] == workspace
        assert applied[-1]["panel_id"] == surface
        record = json.loads(store.read_text())["sessions"][session]
        assert record["autoNameLastTitle"] == "Repair OMP Naming", record
        assert not record.get("autoNameInFlightAt"), record
        print(f"PASS {agent} / {override or 'auto'}: title applied and persisted; argv={argv}")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--cli", default=os.environ.get("CMUX_CLI_BIN"))
    args = parser.parse_args()
    if not args.cli:
        parser.error("--cli or CMUX_CLI_BIN is required")
    for agent, override in [("omp", None), ("pi", None), ("pi", "omp")]:
        run_case(str(Path(args.cli).resolve()), agent, override)
