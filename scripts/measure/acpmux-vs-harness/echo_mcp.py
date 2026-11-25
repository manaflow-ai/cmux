#!/usr/bin/env python3
"""A tiny stdio MCP server for the acpmux-vs-harness MCP bench (mcp.py): one tool, `echo`.

Newline-delimited JSON-RPC on stdin/stdout (the MCP stdio transport), no dependencies. It
answers `initialize`, `tools/list`, `tools/call` (echo: returns its text, the server's name
and pid) and `ping`; it exits when stdin closes, as a well-behaved stdio server does.

Every event goes to `--log FILE` as one JSON line {t (unix s), ev, name, pid, ...}:
  start      the process started
  initialize / tools_list / call   the request arrived
  eof        stdin closed (the client let go)
so the bench reads when each server started, was listed, was called, and by whom, without
asking the harness.

Usage: echo_mcp.py --name echo0 (--log FILE | --log-dir DIR) [--linger]
  --log-dir DIR  log to DIR/<basename of the cwd>.jsonl: one shared config, one log per chat folder
  --linger  keep running after stdin closes (a server that ignores EOF, to see who reaps it)
"""

import json
import os
import sys
import time

name, log, linger = "echo", None, False
argv = sys.argv[1:]
for i, a in enumerate(argv):
    if a == "--name":
        name = argv[i + 1]
    elif a == "--log":
        log = argv[i + 1]
    elif a == "--log-dir":
        # one file per chat folder: DIR/<basename of cwd>.jsonl (a harness starts its stdio
        # servers in the chat's folder), for configs every chat shares
        log = os.path.join(argv[i + 1], os.path.basename(os.getcwd()) + ".jsonl")
    elif a == "--linger":
        linger = True


def note(ev, **kw):
    if not log:
        return
    line = json.dumps({"t": time.time(), "ev": ev, "name": name, "pid": os.getpid(), "ppid": os.getppid(), "cwd": os.getcwd(), **kw})
    fd = os.open(log, os.O_WRONLY | os.O_APPEND | os.O_CREAT, 0o644)
    try:
        os.write(fd, (line + "\n").encode())
    finally:
        os.close(fd)


def send(msg):
    sys.stdout.write(json.dumps(msg) + "\n")
    sys.stdout.flush()


TOOL = {"name": "echo", "description": f"Echo the text back (server {name}).",
        "inputSchema": {"type": "object", "properties": {"text": {"type": "string"}}}}

note("start")
for line in sys.stdin:
    try:
        msg = json.loads(line)
    except ValueError:
        continue
    method, rid = msg.get("method"), msg.get("id")
    if method == "initialize":
        note("initialize", client=(msg.get("params") or {}).get("clientInfo"))
        ver = (msg.get("params") or {}).get("protocolVersion") or "2025-06-18"
        send({"jsonrpc": "2.0", "id": rid, "result": {
            "protocolVersion": ver, "capabilities": {"tools": {"listChanged": False}},
            "serverInfo": {"name": name, "version": "1"}}})
    elif method == "tools/list":
        note("tools_list")
        send({"jsonrpc": "2.0", "id": rid, "result": {"tools": [TOOL]}})
    elif method == "tools/call":
        args = (msg.get("params") or {}).get("arguments") or {}
        note("call", text=str(args.get("text", ""))[:80])
        out = f"{args.get('text', '')} [{name} pid {os.getpid()}]"
        send({"jsonrpc": "2.0", "id": rid, "result": {"content": [{"type": "text", "text": out}], "isError": False}})
    elif method == "ping":
        send({"jsonrpc": "2.0", "id": rid, "result": {}})
    elif rid is not None and method:
        send({"jsonrpc": "2.0", "id": rid, "error": {"code": -32601, "message": f"no method {method}"}})
note("eof")
if linger:
    while True:
        time.sleep(3600)
