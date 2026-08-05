#!/usr/bin/env python3
"""One scripted attach through the machine-provider v1 iroh provider.

Drives exactly the seams the TUI frontend uses: spawns `cmux-tui-iroh
provider control`, performs hello -> snapshot -> open_machine over the v1
control protocol, spawns `cmux-tui-iroh provider stream`, sends the
TransportHandshake (generation bearer + one-use ticket), then speaks
protocol v10 JSON-lines on the resulting stream (identify, workspace list,
optional run) before detaching by closing the stream.

Exits nonzero if any step fails, if the target machine is absent from the
account snapshot, or if --expect-workspace is not present in the remote
session's workspace list.
"""

import argparse
import json
import queue
import secrets
import subprocess
import sys
import threading
import time


class LineReader:
    """Reads lines on a daemon thread so callers can time out."""

    def __init__(self, stream):
        self.lines: queue.Queue = queue.Queue()
        self._thread = threading.Thread(target=self._pump, args=(stream,), daemon=True)
        self._thread.start()

    def _pump(self, stream) -> None:
        for line in stream:
            self.lines.put(line)
        self.lines.put(None)

    def readline(self, timeout: float, what: str) -> str:
        try:
            line = self.lines.get(timeout=timeout)
        except queue.Empty:
            raise RuntimeError(f"{what} timed out") from None
        if line is None:
            raise RuntimeError(f"{what}: stream closed")
        return line


def log(message: str) -> None:
    print(f"[attach-once] {message}", flush=True)


class ControlClient:
    def __init__(self, argv: list[str]):
        self.process = subprocess.Popen(
            argv,
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            bufsize=1,
        )
        self.next_id = 0
        self.reader = LineReader(self.process.stdout)
        self.stderr_lines: list[str] = []
        self._stderr_thread = threading.Thread(target=self._pump_stderr, daemon=True)
        self._stderr_thread.start()

    def _pump_stderr(self) -> None:
        assert self.process.stderr is not None
        for line in self.process.stderr:
            self.stderr_lines.append(line.rstrip())
            log(f"provider: {line.rstrip()}")

    def request(self, method: str, params: dict, timeout: float = 120.0) -> dict:
        self.next_id += 1
        request_id = f"req-{self.next_id}"
        envelope = {
            "protocol": "cmux.machine-provider",
            "version": 1,
            "id": request_id,
            "method": method,
            "params": params,
        }
        assert self.process.stdin is not None
        self.process.stdin.write(json.dumps(envelope) + "\n")
        self.process.stdin.flush()
        deadline = time.monotonic() + timeout
        while True:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise RuntimeError(f"{method} timed out")
            line = self.reader.readline(remaining, method)
            message = json.loads(line)
            if message.get("id") != request_id:
                # Events (snapshot_changed etc.) interleave; skip them.
                continue
            if "error" in message:
                raise RuntimeError(f"{method} failed: {message['error']}")
            return message["result"]

    def close(self) -> None:
        if self.process.stdin:
            self.process.stdin.close()
        try:
            self.process.wait(timeout=10)
        except subprocess.TimeoutExpired:
            self.process.kill()


class SessionStream:
    """Protocol v10 JSON-lines over a provider stream process."""

    def __init__(self, argv: list[str], token: str, ticket: str):
        self.process = subprocess.Popen(
            argv,
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            bufsize=1,
        )
        assert self.process.stdin is not None
        self.reader = LineReader(self.process.stdout)
        handshake = {
            "protocol": "cmux.machine-provider",
            "version": 1,
            "role": "transport",
            "token": token,
            "ticket": ticket,
        }
        self.process.stdin.write(json.dumps(handshake) + "\n")
        self.process.stdin.flush()
        result = json.loads(self.reader.readline(30.0, "transport handshake"))
        if not result.get("accepted"):
            raise RuntimeError(f"transport handshake rejected: {result}")
        self.next_id = 0

    def command(self, cmd: str, timeout: float = 60.0, **params) -> dict:
        self.next_id += 1
        request = {"id": self.next_id, "cmd": cmd, **params}
        assert self.process.stdin is not None
        self.process.stdin.write(json.dumps(request) + "\n")
        self.process.stdin.flush()
        deadline = time.monotonic() + timeout
        while True:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise RuntimeError(f"{cmd} timed out")
            message = json.loads(self.reader.readline(remaining, cmd))
            if message.get("id") != self.next_id:
                continue  # interleaved events
            if not message.get("ok"):
                raise RuntimeError(f"{cmd} failed: {message.get('error')}")
            return message.get("data") or {}

    def detach(self) -> None:
        if self.process.stdin:
            self.process.stdin.close()
        try:
            self.process.wait(timeout=10)
        except subprocess.TimeoutExpired:
            self.process.kill()


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--binary", required=True)
    parser.add_argument("--state", required=True)
    parser.add_argument("--broker", required=True)
    parser.add_argument("--machine-tag")
    parser.add_argument("--machine-id")
    parser.add_argument("--expect-workspace")
    parser.add_argument("--send-command")
    args = parser.parse_args()

    provider_argv = [
        args.binary,
        "provider",
        "--state",
        args.state,
        "--broker",
        args.broker,
    ]
    bearer = secrets.token_hex(24)
    control = ControlClient([*provider_argv, "control"])
    try:
        hello = control.request(
            "hello",
            {
                "token": bearer,
                "client": {
                    "name": "attach-once",
                    "version": "1.0",
                    "supported_versions": [1],
                },
            },
        )
        log(f"hello ok: provider {hello['provider_id']}")

        snapshot = control.request("snapshot", {})
        machines = snapshot.get("machines", [])
        log(
            "snapshot rev "
            f"{snapshot.get('revision')}: "
            + ", ".join(f"{m['display_name']} ({m.get('subtitle', '')})" for m in machines)
        )
        # Machine ids are the broker binding ids; --machine-id selects
        # exactly. --machine-tag matches the display name the listener
        # registers ("cmux-tui <tag>") and must be unique.
        if args.machine_id:
            matches = [m for m in machines if m["id"] == args.machine_id]
        else:
            matches = [
                m
                for m in machines
                if m["display_name"] == f"cmux-tui {args.machine_tag}"
            ]
        if not matches:
            log(f"FAIL: no machine for {args.machine_id or args.machine_tag!r} in account snapshot")
            return 1
        if len(matches) > 1:
            log(f"FAIL: {len(matches)} machines match; pass --machine-id")
            return 1
        target = matches[0]
        log(f"target machine: {target['display_name']} id={target['id']}")

        opened = control.request("open_machine", {"machine_id": target["id"]}, timeout=180.0)
        transport = opened["transport"]
        log(f"open_machine ok: connection {opened['connection_id']}")

        stream = SessionStream([*provider_argv, "stream"], bearer, transport["ticket"])
        identity = stream.command("identify")
        protocol = identity.get("protocol")
        log(f"identify ok: protocol {protocol}")
        if protocol != 10:
            log(f"FAIL: expected protocol 10, got {protocol}")
            return 1

        workspaces = stream.command("list-workspaces")
        names = [w.get("name") for w in workspaces.get("workspaces", [])]
        log(f"workspaces: {names}")
        if args.expect_workspace and args.expect_workspace not in names:
            log(f"FAIL: expected workspace {args.expect_workspace!r} in {names}")
            return 1

        if args.send_command:
            # Run a real command in the first workspace's active surface and
            # prove its output landed on the remote screen.
            first = workspaces.get("workspaces", [])[0]
            surface = (
                first["screens"][0]["panes"][0]["tabs"][0]["surface"]
            )
            # Quote-split the echo argument so the typed command line never
            # contains the literal marker; only real shell output does.
            marker = f"ATTACH_RUN_{int(time.time())}"
            split = f"{marker[:6]}'{marker[6:12]}'{marker[12:]}"
            stream.command(
                "send",
                surface=surface,
                text=f"echo {split}\r",
            )
            deadline = time.monotonic() + 15
            seen = False
            while time.monotonic() < deadline and not seen:
                time.sleep(1)
                screen = stream.command("read-screen", surface=surface)
                seen = marker in screen.get("text", "")
            if not seen:
                log(f"FAIL: marker {marker} never appeared on remote screen")
                return 1
            log(f"remote command ran: {marker} visible on screen")

        stream.detach()
        log("detached cleanly")
        return 0
    finally:
        control.close()


if __name__ == "__main__":
    sys.exit(main())
