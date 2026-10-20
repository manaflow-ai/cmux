#!/usr/bin/env python3
"""Host-side agent-chat debug view.

Shows everything the Mac host sees about chat-capable agent sessions, and
bisects WHERE a session drops out before it reaches the phone:

  registry  -> the AgentChatSessionRegistry record exists (detection worked)
  current   -> its surface is a LIVE terminal panel in a CURRENT workspace
  phone     -> it survives the mobile.chat.sessions filter for that workspace
               (live session => pid alive; ended sessions are retained)

A session that is in `registry` but not `current` is a stale/foreign record:
its surface/workspace is gone (relaunch regenerated workspace ids, or the
agent lives in another cmux instance), so the phone never sees it.

Data sources (read live over the tagged debug socket, no app rebuild):
  cmux rpc chat.sessions.dump   -> the registry
  cmux debug-terminals          -> current surfaces and their workspaces

Usage:  CMUX_TAG=<tag> scripts/cmux-chat-debug.py [--live] [--all]
"""
import json
import os
import re
import subprocess
import sys
import time

CLI = os.path.join(os.path.dirname(__file__), "cmux-debug-cli.sh")


def cli(*args):
    if not os.environ.get("CMUX_TAG"):
        sys.exit("CMUX_TAG must be set, e.g. CMUX_TAG=asot scripts/cmux-chat-debug.py")
    out = subprocess.run([CLI, *args], capture_output=True, text=True, env=dict(os.environ))
    if out.returncode != 0:
        sys.exit("cmux-debug-cli.sh %s failed (rc=%d):\n%s"
                 % (" ".join(args), out.returncode, out.stderr.strip()))
    return out.stdout


def registry():
    raw = cli("rpc", "chat.sessions.dump")
    try:
        return json.loads(raw).get("sessions", [])
    except json.JSONDecodeError:
        # tolerate a leading notice line
        brace = raw.find("{")
        return json.loads(raw[brace:]).get("sessions", []) if brace >= 0 else []


def current_surfaces():
    """Map current surface UUID -> (workspace ref, cwd) from debug-terminals."""
    raw = cli("debug-terminals", "--id-format", "uuids")
    surfaces = {}
    cur = None
    for line in raw.splitlines():
        m = re.search(r"([0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}).*workspace=(\S+)", line)
        if m:
            cur = m.group(1)
            surfaces[cur] = {"workspace": m.group(2), "cwd": None}
        elif cur and "cwd=" in line:
            c = re.search(r"cwd=(\S+)", line)
            if c:
                surfaces[cur]["cwd"] = c.group(1)
            cur = None
    return surfaces


def classify(rec, live_surfaces):
    surf = rec.get("surface_id")
    in_current = surf in live_surfaces
    pid = rec.get("pid")
    alive = rec.get("pid_alive")
    state = rec.get("state")
    if not in_current:
        return "stale", "surface not in any current workspace"
    if state != "ended" and pid is not None and not alive:
        return "dropped", "live session, pid dead"
    return "phone", "would reach phone"


def render(show_all):
    recs = registry()
    surfaces = current_surfaces()
    buckets = {"phone": [], "dropped": [], "stale": []}
    for r in recs:
        b, why = classify(r, surfaces)
        buckets[b].append((r, why))

    alive = sum(1 for r in recs if r.get("pid_alive"))
    notx = sum(1 for r in recs if not r.get("transcript_path"))
    wsn = len({r.get("workspace_id") for r in recs})
    print("\033[1magent-chat host view\033[0m  tag=%s" % os.environ.get("CMUX_TAG", "?"))
    print("registry: %d records | live-pid %d | no-transcript %d | distinct stored ws %d"
          % (len(recs), alive, notx, wsn))
    print("current workspaces hold %d live surfaces" % len(surfaces))
    print("bisect:  \033[32mphone %d\033[0m  \033[33mdropped %d\033[0m  \033[2mstale %d\033[0m"
          % (len(buckets["phone"]), len(buckets["dropped"]), len(buckets["stale"])))
    print()

    def row(r, why):
        surf = (r.get("surface_id") or "")[:8]
        ws = (surfaces.get(r.get("surface_id"), {}).get("workspace") or (r.get("workspace_id") or "")[:8])
        tx = "Y" if r.get("transcript_path") else "N"
        return "  %-6s %-6s ws=%-10s surf=%s pid=%-6s alive=%-5s tx=%s  %s" % (
            r.get("agent"), r.get("state"), str(ws)[:10], surf,
            str(r.get("pid")), str(r.get("pid_alive")), tx, why)

    print("\033[32mWOULD REACH PHONE (%d)\033[0m" % len(buckets["phone"]))
    for r, why in buckets["phone"]:
        print(row(r, why))
    print("\n\033[33mDROPPED by mobile.chat.sessions filter (%d)\033[0m" % len(buckets["dropped"]))
    for r, why in buckets["dropped"]:
        print(row(r, why))
    if show_all:
        print("\n\033[2mSTALE/foreign — surface not in a current workspace (%d)\033[0m" % len(buckets["stale"]))
        for r, why in buckets["stale"][:40]:
            print(row(r, why))
        if len(buckets["stale"]) > 40:
            print("  ... +%d more (registry not reconciled)" % (len(buckets["stale"]) - 40))
    else:
        print("\n\033[2mstale/foreign: %d (run with --all to list)\033[0m" % len(buckets["stale"]))


def main():
    show_all = "--all" in sys.argv
    if "--live" in sys.argv:
        try:
            while True:
                sys.stdout.write("\033[2J\033[H")  # clear + home, no shell-out
                render(show_all)
                print("\n(refreshing every 2s, Ctrl-C to stop)")
                time.sleep(2)
        except KeyboardInterrupt:
            pass
    else:
        render(show_all)


if __name__ == "__main__":
    main()
