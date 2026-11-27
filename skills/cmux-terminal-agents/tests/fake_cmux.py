#!/usr/bin/env python3
"""A fake `cmux` CLI for the cmux-terminal-agents tests.

Each `workspace create` starts tests/fake_tui.py in the background; `terminal
T write` feeds its FIFO, `terminal T screen read` returns its screen file.
State lives in $FAKE_CMUX_DIR. Extra fake TUI flags come from $FAKE_TUI_ARGS.
"""

import base64
import json
import os
import shlex
import signal
import subprocess
import sys
import uuid

HERE = os.path.dirname(os.path.abspath(__file__))
DIR = os.environ["FAKE_CMUX_DIR"]


def out(obj):
    print(json.dumps(obj))
    sys.exit(0)


def fail(msg):
    print(msg, file=sys.stderr)
    sys.exit(1)


def main():
    args = sys.argv[1:]
    clean = []
    i = 0
    while i < len(args):
        if args[i] == "--json":
            i += 1
        elif args[i] == "--idempotency-key":
            i += 2
        else:
            clean.append(args[i])
            i += 1
    a = clean
    with open(os.path.join(DIR, "calls.log"), "a") as f:
        f.write(json.dumps(a) + "\n")
    if a[:3] == ["workspace", "group", "list"]:
        out([])
    if a[:3] == ["workspace", "group", "create"]:
        out({"value": {"id": "grp_fake"}})
    if a[:2] == ["workspace", "group"]:
        out({"value": {}})
    if a[:2] == ["workspace", "create"]:
        argv = a[a.index("--") + 1:] if "--" in a else []
        prompt = argv[-1] if len(argv) > 2 else ""  # "sr2 claude PROMPT"
        term = "term_" + uuid.uuid4().hex[:12]
        fifo = os.path.join(DIR, term + ".in")
        os.mkfifo(fifo)
        cmd = [sys.executable, os.path.join(HERE, "fake_tui.py"), "--dir", DIR, "--term", term]
        cmd += shlex.split(os.environ.get("FAKE_TUI_ARGS", ""))
        if prompt:
            cmd += ["--prompt", prompt]
        p = subprocess.Popen(cmd, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                             stderr=open(os.path.join(DIR, term + ".stderr"), "w"), start_new_session=True)
        with open(os.path.join(DIR, term + ".pid"), "w") as f:
            f.write(str(p.pid))
        ws = "ws_" + term[5:]
        out({"value": {"workspace_id": ws, "terminal_id": term, "tab_id": "tab_" + term[5:]}})
    if a[0] == "workspace" and len(a) >= 3 and a[2] == "close":
        term = "term_" + a[1][3:]
        try:
            with open(os.path.join(DIR, term + ".pid")) as f:
                os.kill(int(f.read()), signal.SIGTERM)
        except (OSError, ValueError):
            pass
        out({"value": {}})
    if a[:2] == ["agent", "list"]:
        recs = []
        for path in sorted(os.listdir(DIR)):
            if path.endswith(".hook"):
                try:
                    with open(os.path.join(DIR, path)) as f:
                        recs.append(json.load(f))
                except ValueError:
                    pass
        out(recs)
    if a[0] == "terminal" and len(a) >= 3:
        term, verb = a[1], a[2:]
        if not os.path.exists(os.path.join(DIR, term + ".in")):
            fail(f"no terminal {term}")
        if verb[0] == "write":
            data = base64.b64decode(verb[verb.index("--bytes-base64") + 1])
            fd = os.open(os.path.join(DIR, term + ".in"), os.O_WRONLY)
            os.write(fd, data)
            os.close(fd)
            out({"value": {}})
        if verb[:2] == ["screen", "read"]:
            try:
                with open(os.path.join(DIR, term + ".screen")) as f:
                    out({"text": f.read()})
            except FileNotFoundError:
                out({"text": ""})
        if verb[0] == "status":
            out([])
        if verb[:2] == ["process", "show"]:
            out({"pid": 1})
    fail(f"fake cmux: unsupported {a}")


if __name__ == "__main__":
    main()
