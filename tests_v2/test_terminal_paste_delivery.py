#!/usr/bin/env python3
"""Verify native paste acknowledges literal delivery without submitting Return."""
import json
import os
from pathlib import Path
import shlex
import sys
import tempfile
import time

from cmux import cmux


def wait_for(predicate, description):
    deadline = time.monotonic() + 15
    while time.monotonic() < deadline:
        if predicate():
            return
        time.sleep(0.05)
    raise AssertionError(f"Timed out: {description}")


def main():
    socket_path = os.environ["CMUX_SOCKET_PATH"]
    assert "12930-terminal-paste-delivery" in socket_path, "Use the isolated issue tag"
    with tempfile.TemporaryDirectory(prefix="cmux-12930-") as directory:
        root = Path(directory)
        capture = root / "bytes"
        ready = root / "ready"
        recorder = root / "recorder.py"
        recorder.write_text('''import os, tty
from pathlib import Path
tty.setraw(0)
os.write(1, b"\\x1b[?2004h")
Path(__file__).with_name("ready").touch()
with Path(__file__).with_name("bytes").open("ab", buffering=0) as output:
    while True:
        output.write(os.read(0, 4096))
''')
        evidence = []
        with cmux(socket_path) as client:
            workspace = client._call("workspace.create", {
                "initial_command": f"{shlex.quote(sys.executable)} {shlex.quote(str(recorder))}"
            })["workspace_id"]
            try:
                client.select_workspace(workspace)
                wait_for(ready.exists, "raw PTY recorder ready")
                surface = client._call("surface.list", {"workspace_id": workspace})["surfaces"][0]["id"]
                expected = b""
                for method in ("terminal.paste", "mobile.terminal.paste"):
                    text = "literal\n世界 🧪"
                    result = client._call(method, {"workspace_id": workspace, "surface_id": surface,
                                                    "text": text, "submit_key": "none"})
                    expected += b"\x1b[200~" + text.encode() + b"\x1b[201~"
                    wait_for(lambda: capture.exists() and len(capture.read_bytes()) >= len(expected), "literal bytes")
                    actual = capture.read_bytes()
                    assert actual == expected, (actual.hex(), expected.hex())
                    assert result.get("delivery") == "delivered", result
                    assert result["submitted"] is False, result
                    evidence.append({"method": method, "response": result, "bytes_hex": actual.hex()})
                client._call("surface.send_key", {"workspace_id": workspace, "surface_id": surface, "key": "enter"})
                expected += b"\r"
                wait_for(lambda: len(capture.read_bytes()) >= len(expected), "separate Return")
                assert capture.read_bytes() == expected
                evidence.append({"separate_return_hex": capture.read_bytes().hex()})
                print(json.dumps(evidence, indent=2))
            finally:
                client.close_workspace(workspace)


if __name__ == "__main__":
    main()
