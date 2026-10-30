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
5. Mouse drags in the TUI rail (SGR mouse input through tmux): a drop between
   two pinned rows pins the workspace there; a drop on the dragged row's own
   slot changes nothing (it must not unpin); a drop on the lower half of the
   last pinned row appends to Pinned; a drop on the first machine row's name
   row stays in the machine list.
6. Stream ends past the restart limit: the TUI attaches through a line proxy
   that ends its `session.events` stream and every stream it opens again;
   the TUI logs each end. A CLI sidebar.move after that still reaches the
   drawn order (the idle-tick fallback read), with no tree change to carry it.
7. Doc slice 3: the TUI echoes sidebar-doc-v1 and placement-shift-v1, and a new top workspace
   sends its event stream the new placement only (no restatement).

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
import threading
import sys
import tempfile
import time
from pathlib import Path

PROTOCOL = "cmux.protocol/2"
SESSION = "s6tui"
NAMES = ["s6-alpha", "s6-bravo", "s6-charlie", "s6-delta", "s6-echo", "s6-foxtrot", "s6-golf"]
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
        self.env = dict(os.environ, HOME=str(root / "home"), XDG_CONFIG_HOME=str(root / "home/.config"),
                        CMUX_TUI_LOG_FILE=str(root / "client.log"))
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


class Proxy:
    """A line proxy between the TUI and the daemon socket. `end_streams()`
    ends the TUI's open `session.events` streams with a `stream_end` (gap)
    and ends every stream it opens later right after the open's response;
    the daemon's items of an ended stream are dropped."""

    def __init__(self, upstream: Path, path: Path) -> None:
        self.upstream, self.path = upstream, path
        self.ending = False
        self.injected = 0
        self.lock = threading.Lock()
        self.listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.listener.bind(str(path))
        self.listener.listen(8)
        self.clients: list[dict] = []
        # What the TUI echoed in set-client-info, and the workspace_placement
        # upserts of each delta the daemon sent it (placement id -> index).
        self.echoed: list[list[str]] = []
        self.placement_deltas: list[dict[str, int]] = []
        threading.Thread(target=self._accept, daemon=True).start()

    def end_streams(self) -> None:
        with self.lock:
            self.ending = True
            for client in self.clients:
                for stream_id in list(client["open"]):
                    self._end(client, stream_id)

    def _end(self, client: dict, stream_id: str) -> None:
        line = {"protocol": PROTOCOL, "type": "stream_end", "stream_id": stream_id, "reason": "gap"}
        client["dead"].add(stream_id)
        client["open"].discard(stream_id)
        self.injected += 1
        with client["write"]:
            client["socket"].sendall(json.dumps(line).encode() + b"\n")

    def _accept(self) -> None:
        while True:
            try:
                downstream, _ = self.listener.accept()
            except OSError:
                return
            upstream = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            upstream.connect(str(self.upstream))
            client = {"socket": downstream, "write": threading.Lock(), "opens": {}, "open": set(), "dead": set()}
            with self.lock:
                self.clients.append(client)
            threading.Thread(target=self._up, args=(client, downstream, upstream), daemon=True).start()
            threading.Thread(target=self._down, args=(client, upstream, downstream), daemon=True).start()

    @staticmethod
    def _lines(source: socket.socket):
        buffer = b""
        while True:
            try:
                chunk = source.recv(1 << 16)
            except OSError:
                return
            if not chunk:
                return
            buffer += chunk
            while b"\n" in buffer:
                line, buffer = buffer.split(b"\n", 1)
                yield line

    def _up(self, client: dict, downstream: socket.socket, upstream: socket.socket) -> None:
        for line in self._lines(downstream):
            if b'"set-client-info"' in line:
                with self.lock:
                    self.echoed.append(json.loads(line).get("capabilities") or [])
            if b'"session.events"' in line:
                request = json.loads(line)
                with self.lock:
                    client["opens"][request["id"]] = request["params"]["stream_id"]
            upstream.sendall(line + b"\n")
        upstream.close()

    def _down(self, client: dict, upstream: socket.socket, downstream: socket.socket) -> None:
        for line in self._lines(upstream):
            # Daemon objects may serialize keys in any order.
            message = json.loads(line) if b'"cmux.protocol/2"' in line else None
            with self.lock:
                if message and message.get("stream_id") in client["dead"]:
                    continue
                if message and message.get("type") == "stream_item":
                    placements = {c["id"]: c["value"]["index"]
                                  for c in (message.get("item") or {}).get("changes") or []
                                  if c.get("resource") == "workspace_placement" and c.get("kind") == "state_upsert"}
                    if placements:
                        self.placement_deltas.append(placements)
                with client["write"]:
                    downstream.sendall(line + b"\n")
                stream_id = client["opens"].pop(message.get("id"), None) if message else None
                if stream_id and message.get("type") == "response" and message.get("ok"):
                    client["open"].add(stream_id)
                    if self.ending:
                        self._end(client, stream_id)
        downstream.close()


class Tui:
    def __init__(self, daemon: Daemon, root: Path, socket_path: Path) -> None:
        self.daemon = daemon
        self.socket_path = socket_path
        self.server = f"s6tui-{os.getpid()}"
        self.log = root / "tui.log"

    def tmux(self, *args: str) -> str:
        return subprocess.run(["tmux", "-L", self.server, *args], check=True, capture_output=True,
                              text=True, timeout=20).stdout

    def start(self) -> None:
        env = " ".join(f"{key}={value}" for key, value in (
            ("HOME", self.daemon.env["HOME"]), ("XDG_CONFIG_HOME", self.daemon.env["XDG_CONFIG_HOME"]),
            ("TERM", "xterm-256color"), ("CMUX_TUI_LOG_FILE", self.daemon.env["CMUX_TUI_LOG_FILE"]),
        ))
        # The TUI's stderr goes to tui.log.
        inner = f"env {env} {self.daemon.binary} attach --socket {self.socket_path} 2>>{self.log}; exit $?"
        command = f"exec /bin/sh -c '{inner}'"
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

    def row_of(self, name: str) -> tuple[int, int]:
        """(column, row), 0-based, of `name` in the rail."""
        for row, line in enumerate(self.screen()):
            column = line[:RAIL_COLUMNS].find(name)
            if column >= 0:
                return column, row
        raise RuntimeError(f"{name} is not drawn")

    def mouse(self, code: int, column: int, row: int, release: bool = False) -> None:
        sequence = f"\x1b[<{code};{column + 1};{row + 1}{'m' if release else 'M'}"
        self.tmux("send-keys", "-t", "tui", "-l", sequence)
        time.sleep(0.1)

    def drag(self, name: str, to_row: int) -> None:
        """Press on `name`, move to `to_row` in steps, release there."""
        column, row = self.row_of(name)
        self.mouse(0, column, row)
        step = 1 if to_row >= row else -1
        for y in list(range(row + step, to_row + step, step)) or [to_row]:
            self.mouse(32, column, y)
        self.mouse(0, column, to_row, release=True)

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
    proxy = Proxy(daemon.socket_path, root / "proxy.sock")
    tui = Tui(daemon, root, proxy.path)
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

        # Doc slice 3: the TUI reads the order from the document, so it
        # echoes sidebar-doc-v1 and placement-shift-v1, and a new top workspace
        # sends its stream only the new placement, not a restatement of every
        # row it shifted.
        check("the TUI echoes sidebar-doc-v1 and placement-shift-v1 in set-client-info",
              any("sidebar-doc-v1" in caps and "placement-shift-v1" in caps for caps in proxy.echoed),
              proxy.echoed)
        with proxy.lock:
            proxy.placement_deltas.clear()
        known = {(r["session_id"], r["workspace_key"]) for r in daemon.raw({"cmd": "list-personal"})["workspaces"]}
        probe = daemon.ok("workspace.create", {"name": "s6-probe", "initial_content": "empty"}, mutate=True)
        probe_id = probe["value"]["workspace_id"]
        rows = daemon.raw({"cmd": "list-personal"})["workspaces"]
        probe_row = next(r for r in rows if (r["session_id"], r["workspace_key"]) not in known)
        shifted = [r for r in rows if r["index"] > probe_row["index"]]
        seen = wait_for("probe placement", lambda: list(proxy.placement_deltas), timeout=10)
        check("a new top workspace sends the TUI one placement, no restatement of the shifted rows",
              bool(seen) and len(shifted) >= len(NAMES) and all(len(delta) == 1 for delta in seen),
              {"deltas": seen, "shifted": len(shifted)})
        daemon.ok("workspace.close", {"workspace": probe_id}, mutate=True)
        wait_for("probe gone", lambda: "s6-probe" not in "".join(tui.screen()), timeout=10)

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
        listed = daemon.raw({"cmd": "list-workspaces"})
        session_order = [w["name"] for w in (listed["workspaces"] if isinstance(listed, dict) else listed) if w.get("name") in ids]
        check("the drawn order is the document's, not the session order",
              tui.order() != session_order, {"tui": tui.order(), "list-workspaces": session_order})
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
        # Drag s6-charlie onto s6-alpha's name row: the slot between the two
        # pinned rows s6-bravo and s6-alpha.
        tui.keys("Escape")
        _, alpha_row = tui.row_of("s6-alpha")
        tui.drag("s6-charlie", alpha_row)
        dragged = wait_for("drag pin", lambda: ws_item(daemon.ok("sidebar.get"), ids["s6-charlie"])["section"] == PINNED
                           and tui.order()[:3] == ["s6-bravo", "s6-charlie", "s6-alpha"])
        check("TUI drag into Pinned -> sidebar.get has it there, drawn in place", bool(dragged),
              {"tui": tui.order(), "doc": doc_order(daemon.ok("sidebar.get"), names_by_id)})
        check("TUI order == sidebar.get order (after drag)", bool(wait_for("after drag", matches_doc)),
              {"tui": tui.order(), "doc": doc_order(daemon.ok("sidebar.get"), names_by_id)})
        # Drag the last pinned row (s6-alpha) and drop it on its own second
        # row: its own slot, so nothing changes (the next row is unpinned).
        before = daemon.ok("sidebar.get")["revision"]
        _, alpha_row = tui.row_of("s6-alpha")
        tui.drag("s6-alpha", alpha_row + 1)
        time.sleep(1.5)
        after = daemon.ok("sidebar.get")
        check("TUI drop on the dragged row's own slot changes nothing",
              after["revision"] == before and ws_item(after, ids["s6-alpha"])["section"] == PINNED,
              {"revision": [before, after["revision"]], "alpha": ws_item(after, ids["s6-alpha"])})
        # A drop on the lower half of the last pinned row pins (it appends to
        # Pinned); a drop on the first machine row's name row stays in the
        # machine list.
        doc = daemon.ok("sidebar.get")
        pinned_names = [n for n in doc_order(doc, names_by_id) if ws_item(doc, ids[n])["section"] == PINNED]
        machine_names = [n for n in doc_order(doc, names_by_id) if ws_item(doc, ids[n])["section"] == machine]
        last_pinned, mover = pinned_names[-1], machine_names[-1]
        _, last_row = tui.row_of(last_pinned)
        tui.drag(mover, last_row + 1)
        appended = wait_for("gap under pinned", lambda: doc_order(daemon.ok("sidebar.get"), names_by_id)[:len(pinned_names) + 1]
                            == pinned_names + [mover]
                            and ws_item(daemon.ok("sidebar.get"), ids[mover])["section"] == PINNED)
        check("TUI drop on the lower half of the last pinned row appends to Pinned", bool(appended),
              {"mover": mover, "doc": doc_order(daemon.ok("sidebar.get"), names_by_id), "tui": tui.order()})
        check("TUI order == sidebar.get order (after the Pinned-end drop)", bool(wait_for("after end drop", matches_doc)),
              {"tui": tui.order(), "doc": doc_order(daemon.ok("sidebar.get"), names_by_id)})
        doc = daemon.ok("sidebar.get")
        machine_names = [n for n in doc_order(doc, names_by_id) if ws_item(doc, ids[n])["section"] == machine]
        if len(machine_names) >= 2:
            first_machine, mover = machine_names[0], machine_names[-1]
            _, first_row = tui.row_of(first_machine)
            tui.drag(mover, first_row)
            stayed = wait_for("machine border", timeout=30, probe=lambda: [n for n in doc_order(daemon.ok("sidebar.get"), names_by_id)
                                                          if ws_item(daemon.ok("sidebar.get"), ids[n])["section"] == machine][:1] == [mover])
            check("TUI drop on the first machine row's name row stays in the machine list, first", bool(stayed),
                  {"mover": mover, "first": first_machine, "machine": machine_names, "row": first_row,
                   "doc": doc_order(daemon.ok("sidebar.get"), names_by_id), "tui": tui.order(),
                   "screen": tui.screen()[:30]})

        # The border marker: while a machine row is dragged over the border
        # of Pinned and the machine list, the marker's corner points at the
        # section the drop joins. Released on its own row: no change.
        doc = daemon.ok("sidebar.get")
        order = doc_order(doc, names_by_id)
        pinned_names = [n for n in order if ws_item(doc, ids[n])["section"] == PINNED]
        machine_names = [n for n in order if ws_item(doc, ids[n])["section"] == machine]
        mover = machine_names[-1]
        revision = doc["revision"]
        column, mover_row = tui.row_of(mover)
        _, last_pinned_row = tui.row_of(pinned_names[-1])
        _, first_machine_row = tui.row_of(machine_names[0])
        tui.mouse(0, column, mover_row)
        tui.mouse(32, column, mover_row - 1)
        tui.mouse(32, column, last_pinned_row + 1)
        up = wait_for("corner up", lambda: any("┘" in line[:RAIL_COLUMNS] for line in tui.screen()), timeout=5)
        tui.mouse(32, column, first_machine_row)
        down = wait_for("corner down", lambda: any("┐" in line[:RAIL_COLUMNS] for line in tui.screen()), timeout=5)
        tui.mouse(32, column, mover_row)
        tui.mouse(0, column, mover_row, release=True)
        check("the marker points up on the lower half of the last pinned row (joins Pinned)", bool(up), tui.screen()[:24])
        check("the marker points down on the first machine row's name row (joins the machine list)", bool(down),
              tui.screen()[:24])
        time.sleep(1.0)
        check("released on its own row: no change", daemon.ok("sidebar.get")["revision"] == revision,
              doc_order(daemon.ok("sidebar.get"), names_by_id))

        # A scrolled rail: a short window, the rail scrolled to its end with
        # the wheel; a drop on a visible row's name row lands before that row.
        tui.tmux("resize-window", "-t", "tui", "-y", "14")
        time.sleep(0.5)
        column, _ = tui.row_of(tui.order()[0])
        for _ in range(12):
            tui.mouse(65, column, 5)
        full = doc_order(daemon.ok("sidebar.get"), names_by_id)
        scrolled = wait_for("scrolled", lambda: tui.order() and tui.order()[0] != full[0] and tui.order(), timeout=5)
        check("the rail is scrolled", bool(scrolled), {"visible": tui.order(), "all": full})
        doc = daemon.ok("sidebar.get")
        visible_machine = [n for n in tui.order() if ws_item(doc, ids[n])["section"] == machine]
        if len(visible_machine) >= 2:
            target, mover = visible_machine[0], visible_machine[-1]
            _, target_row = tui.row_of(target)
            tui.drag(mover, target_row)
            landed = wait_for("scrolled drop", lambda: (lambda o: o.index(mover) == o.index(target) - 1)(
                doc_order(daemon.ok("sidebar.get"), names_by_id)), timeout=15)
            check("scrolled rail: the drop lands before the row under the pointer", bool(landed),
                  {"target": target, "mover": mover, "doc": doc_order(daemon.ok("sidebar.get"), names_by_id)})
        else:
            check("scrolled rail shows two machine rows", False, tui.order())
        tui.tmux("resize-window", "-t", "tui", "-y", "50")
        for _ in range(12):
            tui.mouse(64, column, 5)
        wait_for("unscrolled", lambda: len(tui.order()) == len(NAMES), timeout=5)

        # Stream ends past the restart limit: the proxy ends the TUI's event
        # stream now and every stream it opens from here on.
        log = Path(daemon.env["CMUX_TUI_LOG_FILE"])

        def stream_ends() -> int:
            return log.read_text(errors="replace").count("sidebar event stream ended") if log.exists() else 0

        proxy.end_streams()
        ended = wait_for("stream ends", lambda: stream_ends() > 3 and stream_ends(), timeout=20)
        check("the TUI saw more stream ends than the restart limit (3)", bool(ended),
              {"logged": stream_ends(), "injected": proxy.injected})
        doc = daemon.ok("sidebar.get")
        machine_items = [ws_item(doc, ids[n]) for n in doc_order(doc, names_by_id)
                         if ws_item(doc, ids[n])["section"] == machine]
        params = {"machine": "current", "session": "current", "items": [machine_items[-1]["id"]],
                  "to": {"section": machine, "before": machine_items[0]["id"]}}
        drawn_before = tui.order()
        moved = daemon.cli("--json", "raw", "operation", "sidebar.move", "--params-json", json.dumps(params))
        check("CLI sidebar.move after the stream ends exits 0", moved.returncode == 0, moved.stderr + moved.stdout)
        check("the move changes the document order (the next check is not trivially true)",
              doc_order(daemon.ok("sidebar.get"), names_by_id) != drawn_before,
              {"drawn": drawn_before, "doc": doc_order(daemon.ok("sidebar.get"), names_by_id)})
        check("TUI order == sidebar.get order (stream ends past the limit: idle-tick read)",
              bool(wait_for("fallback", matches_doc, timeout=15)),
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
