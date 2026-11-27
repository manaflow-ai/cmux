"""Check the palette prompt's generated catalog and run its built command in cmux-app-host."""

from __future__ import annotations

import json
import socket
import subprocess
import time
from pathlib import Path


TITLE = "Stand-up: Copy my note"
DONE = ["Fixed the sidebar focus", "Added the offline replay"]
MAX_LINE = 4 * 1024 * 1024  # cmux-app-host's protocol::MAX_LINE_BYTES


def package_text(folder: Path, name: str) -> str:
    path = (folder / name).resolve()
    path.relative_to(folder.resolve())
    return path.read_text(encoding="utf-8")


def run_note(folder: Path, manifest: dict, export: str) -> str | None:
    main = manifest["runtime"]["main"]
    init = {"t": "init", "app": {"id": manifest["id"], "version": manifest["version"]},
            "api_version": "1.0.0", "main_name": main, "main": package_text(folder, main)}
    supervisor, child = socket.socketpair()
    # The sandboxed host takes a full-duplex socket on fd 3. stdin passes it through
    # Popen without changing the calling process's descriptors.
    with supervisor, child, subprocess.Popen(
        ["/bin/sh", "-c", "exec cmux-app-host 3<&0 </dev/null"], stdin=child
    ) as host:
        child.close()
        try:
            supervisor.settimeout(10)
            deadline = time.monotonic() + 10
            with supervisor.makefile("rb") as reader:
                def send(message: dict) -> None:
                    supervisor.sendall(json.dumps(message).encode() + b"\n")

                send(init)
                toasts = []
                running = False
                while (remaining := deadline - time.monotonic()) > 0:
                    supervisor.settimeout(remaining)
                    line = reader.readline(MAX_LINE + 1)
                    if not line:
                        return "cmux-app-host closed before the command returned"
                    if len(line) > MAX_LINE:
                        return "cmux-app-host response exceeds its protocol limit"
                    msg = json.loads(line)
                    if msg["t"] == "ready":
                        running = True
                        send({"t": "run", "cb": 1, "export": export,
                              "gesture": "prompt-check", "args": {"done": DONE}})
                    elif msg["t"] == "call":
                        if running and msg["name"] == "toast.show":
                            params = msg["params"]
                            toasts.append("\n".join(str(params.get(k, "")) for k in ("title", "message")))
                        # As in ext dev --headless, acknowledge host effects without executing them.
                        send({"t": "resolve", "cb": msg["cb"], "ok": True, "body": {"value": None}})
                    elif msg["t"] == "done" and running and msg["cb"] == 1:
                        if not msg["ok"]:
                            return f"standup note failed: {msg['body']}"
                        result = msg["body"].get("value")
                        fields = result.values() if isinstance(result, dict) else [result]
                        notes = [s for s in fields if isinstance(s, str) and all(item in s for item in DONE)]
                        if not notes:
                            return "standup note did not return a note containing both done items"
                        if not any(note in toast for toast in toasts for note in notes):
                            return "standup note did not show the returned note in a toast"
                        return None
                    elif msg["t"] in ("init-failed", "fatal"):
                        return f"cmux-app-host: {msg}"
                return "standup note timed out"
        finally:
            supervisor.close()  # EOF shuts down the host.
            try:
                host.wait(timeout=1)
            except subprocess.TimeoutExpired:
                host.kill()


def check_palette(folder: Path) -> str | None:
    """After ext dev validates/builds, check the palette row and short CLI route share a handler."""
    try:
        name = "cmux-app.json" if (folder / "cmux-app.json").is_file() else "cmux-app.v2.json"
        manifest = json.loads(package_text(folder, name))
        if (manifest.get("cli") or {}).get("name") != "standup" or not manifest.get("catalog"):
            return "the extension does not register cmux standup note"
        catalog = json.loads(package_text(folder, manifest["catalog"]))
        matches = [op for op in catalog["operations"] if (op.get("cli") or {}).get("path") == "note"]
        if len(matches) != 1:
            return "the catalog must register one handler for cmux standup note"
        op = matches[0]
        title = (op.get("palette") or {}).get("title")
        if (title.get("en") if isinstance(title, dict) else title) != TITLE:
            return f"the standup note palette row must be titled {TITLE!r}"
        done = op.get("input", {}).get("properties", {}).get("done", {})
        if done.get("type") != "array" or done.get("items", {}).get("type") != "string":
            return "standup note must accept a done list of strings"
        return run_note(folder, manifest, op["export"])
    except (OSError, ValueError, TypeError, KeyError, AttributeError) as error:
        return f"could not check standup note: {error}"
