#!/usr/bin/env python3
"""Runs one device hub session on this Mac with a stand-in for the hub's signaling.

  hub-session-local.py BIN [--scope view|control] [--stun HOST:PORT] [bench flags...]

BIN is a cmux-rd built with the link feature. The script plays the hub: it starts
`cmux-rd bench --link` (the viewer), reads its session key, starts `cmux-rd serve`
with that key and an approved session, passes the host's key and candidates to the
viewer and the viewer's candidates to the host, and relays later candidates. It
prints the host's lines (path, connected, ended) and the bench's report.
The host process needs Screen Recording and Accessibility (start this from a terminal
of an app that holds them).
"""
import json, os, select, subprocess, sys, time

args = sys.argv[1:]
if not args:
    sys.exit(__doc__)
binary, rest = args[0], args[1:]
scope, stun, bench_flags = "control", [], []
i = 0
while i < len(rest):
    if rest[i] == "--scope":
        scope = rest[i + 1]; i += 2
    elif rest[i] == "--stun":
        stun.append(rest[i + 1]); i += 2
    else:
        bench_flags.append(rest[i]); i += 1
session = "local-" + os.urandom(8).hex()

viewer = subprocess.Popen([binary, "bench", "--link", "1", *bench_flags], stdin=subprocess.PIPE,
                          stdout=subprocess.PIPE, text=True, bufsize=1)
viewer_key = json.loads(viewer.stdout.readline())["key"]
host = subprocess.Popen([binary, "serve"], stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True, bufsize=1)
host.stdin.write(json.dumps({"session": session, "peer_key": viewer_key, "scope": scope, "stun": stun,
                             "viewer": {"user": "viewer", "install": "bench"}}) + "\n")
host.stdin.flush()
host_key = json.loads(host.stdout.readline())["key"]

# The host's candidates (all of them, or what came within 3 s) go in the answer.
candidates, deadline = [], time.time() + 3
while time.time() < deadline:
    ready, _, _ = select.select([host.stdout], [], [], max(0, deadline - time.time()))
    if not ready:
        break
    line = json.loads(host.stdout.readline())
    if "candidate" in line:
        candidates.append(line["candidate"])
    if line.get("candidates_done"):
        break
print("host candidates:", candidates, file=sys.stderr)
viewer.stdin.write(json.dumps({"session": session, "peer_key": host_key, "stun": stun,
                               "candidates": candidates}) + "\n")
viewer.stdin.flush()

# Relay until both end.
report = None
streams = {host.stdout: "host", viewer.stdout: "viewer"}
while streams:
    ready, _, _ = select.select(list(streams), [], [], 120)
    if not ready:
        print("timed out", file=sys.stderr)
        break
    for s in ready:
        line = s.readline()
        if not line:
            del streams[s]
            continue
        who = streams[s]
        try:
            msg = json.loads(line)
        except ValueError:
            print(f"{who}: {line.rstrip()}", file=sys.stderr)
            continue
        if who == "viewer" and "candidate" in msg:
            host.stdin.write(json.dumps(msg) + "\n"); host.stdin.flush()
        elif who == "host" and "candidate" in msg:
            pass  # the viewer already has the host's first candidates; late ones are optional
        elif who == "viewer" and "g2g_ms" in msg:
            report = msg
            print(json.dumps(msg))
        else:
            print(f"{who}: {json.dumps(msg)}", file=sys.stderr)
    if report is not None and viewer.poll() is not None:
        host.stdin.write(json.dumps({"stop": True}) + "\n"); host.stdin.flush()
        break
host.wait(timeout=10)
viewer.wait(timeout=10)
sys.exit(0 if report and report.get("lost", 1) == 0 or (report and report.get("g2g_ms")) else 1)
