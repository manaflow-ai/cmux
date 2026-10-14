#!/usr/bin/env python3
"""Live behavior check of the TUI on the sidebar document (sidebar-doc-v1).

A real headless daemon and a real `cmux attach` TUI in an isolated tmux
server. The TUI's drawn workspace list is read from the tmux screen (the
workspace rail, left columns); the daemon's document from `sidebar.get`.

1. The TUI draws the document's order.
2. Pin from the TUI (`Ctrl-b S`, select the row, `p`): `sidebar.get` has the
   workspace in Pinned, and the TUI draws it first.
3. Unpin from the TUI (`p` again): `sidebar.get` has it back in this
   machine's section, and the TUI order matches.
4. `sidebar.move` and `sidebar.pin` from the CLI (`cmux raw operation`): the
   TUI order follows each one, Pinned in document order.

Usage: sidebar-tui-doc-live.py --binary path/to/cmux-tui [--workdir DIR]
Needs tmux. Prints one PASS/FAIL line per check; exits 1 on any FAIL.
"""

from __future__ import annotations

import argparse
import itertools
import json
import os
import shutil
import socket
import subprocess
import sys
import tempfile
import time
from pathlib import Path

PROTOCOL = "cmux.protocol/2"
SESSION = "s6tui"
NAMES = ["s6-alpha", "s6-bravo", "s6-charlie", "s6-delta"]
PINNED = "sec_pinned"
RAIL_COLUMNS = 26
_ids = itertools.count(1)
failures: list[str] = []


def check(name: str, ok: bool, detail: object = "") -> None:
    print(("PASS " if ok else "FAIL ") + name + ("" if ok else f" :: {detail}"), flush=True)
    if not ok:
        failures.append(name)


class Daemon:
    def __init__(self, binary: Path, root: Path) -> None:
        self.binary = binary
        self.state = root / "state"
        self.socket_path = root / "s.sock"
        self.log = root / "daemon.log"
        self.env = dict(os.environ, HOME=str(root / "home"), XDG_CONFIG_HOME=str(root / "home/.config"))
        self.process: subprocess.Popen[str] | None = None

    def start(self) -> None:
        log = open(self.log, "a")
        self.process = subprocess.Popen(
            [str(self.binary), "--headless", "--session", SESSION, "--socket",
             str(self.socket_path), "--state", str(self.state)],
            stdout=log, stderr=subprocess.STDOUT, text=True, env=self.env,
        )
        deadline = time.monotonic() + 30
        while time.monotonic() < deadline:
            if self.process.poll() is not None:
                raise SystemExit(f"daemon exited {self.process.returncode}: {self.log.read_text()[-2000:]}")
            try:
                self.raw({"cmd": "identify"})
                return
            except OSError:
                time.sleep(0.05)
        raise SystemExit("daemon did not answer identify")

    def stop(self) -> None:
        if self.process and self.process.poll() is None:
            self.process.terminate()
            try:
                self.process.wait(timeout=15)
            except subprocess.TimeoutExpired:
                self.process.kill()

    def _line(self, message: dict) -> dict:
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as connection:
            connection.settimeout(20)
            connection.connect(str(self.socket_path))
            connection.sendall(json.dumps(message).encode() + b"\n")
            buffer = b""
            while b"\n" not in buffer:
                chunk = connection.recv(1 << 16)
                if not chunk:
                    break
                buffer += chunk
        return json.loads(buffer.split(b"\n", 1)[0])

    def raw(self, message: dict) -> dict:
        reply = self._line({"id": next(_ids), **message})
        if not reply.get("ok"):
            raise RuntimeError(f"{message['cmd']} failed: {reply}")
        return reply.get("data")

    def ok(self, operation: str, params: dict | None = None, mutate: bool = False):
        envelope = {
            "protocol": PROTOCOL, "type": "request", "id": f"r{next(_ids)}", "operation": operation,
            "params": {"machine": "current", "session": "current", **(params or {})},
        }
        if mutate:
            envelope["idempotency_key"] = f"s6-{next(_ids)}"
        reply = self._line(envelope)
        if not reply.get("ok"):
            raise RuntimeError(f"{operation} failed: {reply.get('error')}")
        return reply["result"]

    def cli(self, *args: str) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            [str(self.binary), "--socket", str(self.socket_path), *args],
            capture_output=True, text=True, timeout=30, env=self.env,
        )


class Tui:
    def __init__(self, daemon: Daemon, root: Path) -> None:
        self.daemon = daemon
        self.server = f"s6tui-{os.getpid()}"
        self.log = root / "tui.log"

    def tmux(self, *args: str) -> str:
        return subprocess.run(["tmux", "-L", self.server, *args], check=True, capture_output=True,
                              text=True, timeout=20).stdout

    def start(self) -> None:
        env = " ".join(f"{key}={value}" for key, value in (
            ("HOME", self.daemon.env["HOME"]), ("XDG_CONFIG_HOME", self.daemon.env["XDG_CONFIG_HOME"]),
            ("TERM", "xterm-256color"),
        ))
        command = f"env {env} {self.daemon.binary} attach --socket {self.daemon.socket_path} 2>>{self.log}"
        self.tmux("-f", "/dev/null", "new-session", "-d", "-s", "tui", "-x", "180", "-y", "50", command)

    def stop(self) -> None:
        subprocess.run(["tmux", "-L", self.server, "kill-server"], capture_output=True, timeout=20)

    def screen(self) -> list[str]:
        return self.tmux("capture-pane", "-p", "-t", "tui").splitlines()

    def order(self) -> list[str]:
        """The workspace names in the order the rail draws them."""
        seen: list[str] = []
        for line in self.screen():
            rail = line[:RAIL_COLUMNS]
            for name in NAMES:
                if name in rail and name not in seen:
                    seen.append(name)
        return seen

    def keys(self, *keys: str) -> None:
        for key in keys:
            self.tmux("send-keys", "-t", "tui", key)
            time.sleep(0.15)


def wait_for(what: str, probe, timeout: float = 15.0):
    """Poll a read-only probe (screen or sidebar.get) until it returns truthy."""
    deadline = time.monotonic() + timeout
    value = None
    while time.monotonic() < deadline:
        value = probe()
        if value:
            return value
        time.sleep(0.2)
    return value


def doc_order(doc: dict, names_by_id: dict[str, str]) -> list[str]:
    """The workspace names in document display order (sections by region and
    key, items by key, group members after their group)."""
    region = {"top": 0, "middle": 1, "bottom": 2}
    sections = {s["id"]: (region.get(s.get("region", "middle"), 3), s.get("order", ""), s["id"])
                for s in doc["sections"]}
    items = {item["id"]: item for item in doc["items"]}

    def key(item: dict):
        parent = item.get("parent")
        top = (items[parent]["order"] if parent in items else "") if parent else item["order"]
        group = parent or item["id"]
        return (sections.get(item["section"], (255, "", item["section"])), top, group,
                1 if parent else 0, item["order"], item["id"])

    ordered = sorted(doc["items"], key=key)
    out = []
    for item in ordered:
        body = item["body"]
        if body.get("type") == "workspace" and body["ref"]["workspace_id"] in names_by_id:
            out.append(names_by_id[body["ref"]["workspace_id"]])
    return out


def ws_item(doc: dict, workspace_id: str) -> dict | None:
    return next((i for i in doc["items"] if i["body"].get("type") == "workspace"
                 and i["body"]["ref"]["workspace_id"] == workspace_id), None)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--binary", required=True, type=Path)
    parser.add_argument("--workdir", type=Path)
    args = parser.parse_args()
    if shutil.which("tmux") is None:
        print("FAIL tmux is required")
        return 1
    root = Path(args.workdir or tempfile.mkdtemp(prefix="s6tui-"))
    (root / "home/.config").mkdir(parents=True, exist_ok=True)
    daemon = Daemon(args.binary.resolve(), root)
    daemon.start()
    tui = Tui(daemon, root)
    try:
        caps = daemon.raw({"cmd": "identify"}).get("capabilities", [])
        check("daemon advertises sidebar-doc-v1", "sidebar-doc-v1" in caps, caps)
        ids: dict[str, str] = {}
        for name in NAMES:
            created = daemon.ok("workspace.create", {"name": name, "initial_content": "empty"}, mutate=True)
            ids[name] = created["value"]["workspace_id"]
        names_by_id = {v: k for k, v in ids.items()}
        doc = daemon.ok("sidebar.get")
        machine = ws_item(doc, ids["s6-alpha"])["section"]
        check("new workspaces sit in this machine's section", machine.startswith("sec_m_"), machine)

        tui.start()
        drawn = wait_for("tui draws the workspaces", lambda: len(tui.order()) == len(NAMES) and tui.order())
        check("TUI draws every workspace", drawn and len(drawn) == len(NAMES), tui.screen()[:30])

        def matches_doc():
            want = doc_order(daemon.ok("sidebar.get"), names_by_id)
            got = tui.order()
            return (got == want) and got

        check("TUI order == sidebar.get order (initial)", bool(wait_for("initial", matches_doc)),
              {"tui": tui.order(), "doc": doc_order(daemon.ok("sidebar.get"), names_by_id)})

        # Pin from the TUI: focus the rail, select s6-charlie, press p.
        def select(name: str) -> None:
            tui.keys("C-b", "S", "Home")
            for _ in range(tui.order().index(name)):
                tui.keys("j")

        select("s6-charlie")
        tui.keys("p")
        pinned = wait_for("pinned", lambda: ws_item(daemon.ok("sidebar.get"), ids["s6-charlie"])["section"] == PINNED)
        check("TUI pin -> sidebar.get has s6-charlie in Pinned", bool(pinned),
              ws_item(daemon.ok("sidebar.get"), ids["s6-charlie"]))
        first = wait_for("drawn first", lambda: tui.order()[:1] == ["s6-charlie"])
        check("TUI draws the pinned workspace first", bool(first), tui.order())
        check("TUI order == sidebar.get order (after TUI pin)", bool(wait_for("after pin", matches_doc)),
              {"tui": tui.order(), "doc": doc_order(daemon.ok("sidebar.get"), names_by_id)})

        # Unpin from the TUI.
        tui.keys("Escape")
        select("s6-charlie")
        tui.keys("p")
        unpinned = wait_for("unpinned", lambda: ws_item(daemon.ok("sidebar.get"), ids["s6-charlie"])["section"] == machine)
        check("TUI unpin -> sidebar.get has s6-charlie in this machine's section", bool(unpinned),
              ws_item(daemon.ok("sidebar.get"), ids["s6-charlie"]))
        check("TUI order == sidebar.get order (after TUI unpin)", bool(wait_for("after unpin", matches_doc)),
              {"tui": tui.order(), "doc": doc_order(daemon.ok("sidebar.get"), names_by_id)})
        tui.keys("Escape")

        # Move from the CLI: s6-delta before s6-alpha.
        doc = daemon.ok("sidebar.get")
        delta, alpha = ws_item(doc, ids["s6-delta"]), ws_item(doc, ids["s6-alpha"])
        params = {"machine": "current", "session": "current", "items": [delta["id"]],
                  "to": {"section": alpha["section"], "before": alpha["id"]}}
        moved = daemon.cli("--json", "raw", "operation", "sidebar.move", "--params-json", json.dumps(params))
        check("CLI sidebar.move exits 0", moved.returncode == 0, moved.stderr + moved.stdout)
        check("TUI order == sidebar.get order (after CLI move)",
              bool(wait_for("after move", lambda: matches_doc() and tui.order().index("s6-delta") < tui.order().index("s6-alpha"))),
              {"tui": tui.order(), "doc": doc_order(daemon.ok("sidebar.get"), names_by_id)})

        # Pin two from the CLI: Pinned holds them in document order.
        for name in ("s6-bravo", "s6-alpha"):
            item = ws_item(daemon.ok("sidebar.get"), ids[name])
            pin = daemon.cli("--json", "raw", "operation", "sidebar.pin", "--params-json",
                             json.dumps({"machine": "current", "session": "current", "items": [item["id"]]}))
            check(f"CLI sidebar.pin {name} exits 0", pin.returncode == 0, pin.stderr + pin.stdout)
        check("TUI draws Pinned first, in document order (after CLI pins)",
              bool(wait_for("after pins", lambda: matches_doc() and tui.order()[:2] == ["s6-bravo", "s6-alpha"])),
              {"tui": tui.order(), "doc": doc_order(daemon.ok("sidebar.get"), names_by_id)})
        print("final TUI order:", tui.order(), flush=True)
        print("final doc order:", doc_order(daemon.ok("sidebar.get"), names_by_id), flush=True)
    finally:
        tui.stop()
        daemon.stop()
    if failures:
        tail = (root / "tui.log").read_text()[-3000:] if (root / "tui.log").exists() else ""
        print("TUI log tail:\n" + tail)
    print(f"{len(failures)} failure(s)")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
