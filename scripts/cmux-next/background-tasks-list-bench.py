#!/usr/bin/env python3
"""Background tasks panel: what its first list shows for a chat, from acpmux's socket.

measure: the Background tasks panel's time to its first list of a chat's running subagents, and
whether that list holds them, before and after `_acpmux/subagents` (Leo, 2026-11-24: "this bugged?
or had an ultra slow load").

Before, the panel found subagents only in the rows of the chat's opening page (the newest records,
up to 128 KiB, webviews direct.ts OPEN_PAGE_BYTES); a coordinator that started its helpers hours ago
has none of them there. This times that page and counts the running subagents it names, against the
running ones acpmux's tree knows (`_acpmux/info` `recentSubagents`, `subagentsRunning`). After, the
panel reads `_acpmux/subagents`; when the daemon serves it, this times that call and counts what it
lists.

Read only and light: one opening page, one info, one list. Runs against the daemon on this machine
(`--socket` for another).

    python3 scripts/cmux-next/background-tasks-list-bench.py SESSION_ID [--socket PATH] [--json]
"""

import argparse
import json
import os
import re
import socket
import sys
import time

OPEN_PAGE_BYTES = 128 * 1024
KEPT_EVENTS = 2000


class Socket:
    def __init__(self, path):
        self.conn = socket.socket(socket.AF_UNIX)
        self.conn.connect(path)
        self.file = self.conn.makefile("rwb")
        self.next = 0

    def call(self, method, params):
        self.next += 1
        mine = self.next
        frame = {"jsonrpc": "2.0", "id": mine, "method": method, "params": params}
        self.file.write((json.dumps(frame) + "\n").encode())
        self.file.flush()
        started = time.perf_counter()
        while True:
            line = self.file.readline()
            if not line:
                raise SystemExit("acpmux closed the socket")
            msg = json.loads(line)
            if msg.get("id") == mine:
                return msg, (time.perf_counter() - started) * 1000


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("session")
    ap.add_argument("--socket", default=os.path.expanduser("~/.acpmux/acpmux.sock"))
    ap.add_argument("--json", action="store_true")
    args = ap.parse_args()
    s = Socket(args.socket)
    init, _ = s.call("initialize", {"protocolVersion": 1, "clientInfo": {"name": "background-tasks-list-bench"}})
    caps = set((((init.get("result") or {}).get("_meta") or {}).get("acpmux") or {}).get("capabilities") or [])

    page, page_ms = s.call(
        "_acpmux/events",
        {"sessionId": args.session, "beforeSeq": 2**53 - 1, "limit": KEPT_EVENTS, "maxBytes": OPEN_PAGE_BYTES},
    )
    events = (page.get("result") or {}).get("events") or []
    blob = json.dumps(events)
    info, info_ms = s.call("_acpmux/info", {"sessionId": args.session, "waitLogs": False})
    res = info.get("result") or {}
    running = [x["id"] for x in res.get("recentSubagents", []) if x.get("state") == "running"]
    in_page = [x for x in running if re.search(r'"' + re.escape(x) + r'"', blob)]
    out = {
        "session": args.session,
        "subagentsSeen": res.get("subagentsSeen"),
        "subagentsRunning": res.get("subagentsRunning"),
        "before": {
            "openPageMs": round(page_ms, 1),
            "openPageRecords": len(events),
            "runningNamedInPage": len(in_page),
            "runningChecked": len(running),
        },
    }
    if "subagent-list-v1" in caps:
        listing, list_ms = s.call("_acpmux/subagents", {"sessionId": args.session})
        lres = listing.get("result") or {}
        out["after"] = {
            "listMs": round(list_ms, 1),
            "running": len(lres.get("running", [])),
            "ended": len(lres.get("ended", [])),
            "bytes": len(json.dumps(lres)),
            "error": listing.get("error"),
        }
    else:
        out["after"] = "this acpmux does not serve _acpmux/subagents (subagent-list-v1)"
    if args.json:
        print(json.dumps(out, indent=2))
        return
    b = out["before"]
    print(f"chat {args.session}: {out['subagentsSeen']} subagents seen, {out['subagentsRunning']} running")
    print(
        f"before: opening page {b['openPageMs']} ms, {b['openPageRecords']} records, "
        f"names {b['runningNamedInPage']} of {b['runningChecked']} running subagents"
    )
    a = out["after"]
    if isinstance(a, dict):
        print(f"after: _acpmux/subagents {a['listMs']} ms, {a['running']} running, {a['ended']} ended, {a['bytes']} bytes")
    else:
        print(f"after: {a}")


if __name__ == "__main__":
    sys.exit(main())
