#!/usr/bin/env python3
"""The external server of the Hello Python sample app (manaflow-ai/hello-python).

An `external` app server is a process you start yourself, in any language. It
connects to the cmux daemon's control socket with the app's credential and
answers the app's catalog ops (cmux-tui-core apps/server_external.rs):

1. Install the app; the consent card lists `server:execute` ("Answer this
   app's commands from a Python process you start").
2. Approve a credential for it in cmux (it is shown once).
3. Start this script with the credential in CMUX_APP_CREDENTIAL and the
   daemon's socket in --socket (or CMUX_SOCKET_PATH):

       CMUX_APP_CREDENTIAL=cmuxsrv1_... python3 server.py --socket /path/to/daemon.sock

4. Run its ops from anywhere: `cmux apps run manaflow-ai/hello-python hello`.

It uses the standard library only. The credential is read from the
environment, never from argv, so it does not show in `ps`.
"""

import argparse
import json
import os
import socket
import sys

APP = "manaflow-ai/hello-python"
FAMILY = "manaflow_ai.hello_python"


class Connection:
    """One control connection: JSON lines both ways."""

    def __init__(self, path):
        self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.sock.connect(path)
        self.reader = self.sock.makefile("r", encoding="utf-8")
        self.next_id = 0

    def send(self, cmd, **fields):
        self.next_id += 1
        frame = {"id": self.next_id, "cmd": cmd, **fields}
        self.sock.sendall((json.dumps(frame) + "\n").encode("utf-8"))
        return self.next_id

    def messages(self):
        for raw in self.reader:
            raw = raw.strip()
            if raw:
                yield json.loads(raw)


def answer(op, args, served):
    """The result of one catalog op, or raises ValueError for an unknown op."""
    if op == f"{FAMILY}.hello":
        name = args.get("name") or "there"
        return {"text": f"Hello, {name}, from Python", "pid": os.getpid()}
    if op == f"{FAMILY}.status":
        return {"served": served, "python": sys.version.split()[0]}
    raise ValueError(f"no op {op}")


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--socket", default=os.environ.get("CMUX_SOCKET_PATH"))
    options = parser.parse_args()
    credential = os.environ.get("CMUX_APP_CREDENTIAL", "")
    if not options.socket:
        sys.exit("hello-python: pass --socket or set CMUX_SOCKET_PATH")
    conn = Connection(options.socket)
    attach = conn.send("apps-server-attach", app=APP, credential=credential)
    served = 0
    for message in conn.messages():
        if message.get("id") == attach:
            if not message.get("ok"):
                print(
                    f"hello-python: refused: {message.get('error_code')}: {message.get('error')}",
                    file=sys.stderr,
                )
                return 1
            print("hello-python: serving", APP, file=sys.stderr, flush=True)
            continue
        if message.get("event") != "apps-server-line" or message.get("app") != APP:
            continue
        line = message.get("line") or {}
        if line.get("type") == "stop":
            return 0
        if line.get("type") != "op":
            continue  # op.cancel: the daemon already answered the caller
        try:
            result = {"type": "result", "id": line["id"], "ok": True,
                      "result": answer(line.get("op"), line.get("args") or {}, served + 1)}
            served += 1
        except ValueError as error:
            result = {"type": "result", "id": line["id"], "ok": False,
                      "error": {"code": "cmux.op.unknown", "message": str(error), "retryable": False}}
        conn.send("apps-server-line", app=APP, line=result)
    return 0


if __name__ == "__main__":
    sys.exit(main())
