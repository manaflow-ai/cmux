#!/usr/bin/env python3
"""Crash-surface sweep: runs every socket action of a running tagged cmux-next build and stops at
the first one after which the app no longer answers.

It changes real state: settings, files, workspaces, and system defaults (makeDefaultBrowser and
makeDefaultTerminal run too). Run it only against a disposable tagged build on a fleet capture
slot, never on a machine someone uses; it refuses any socket that is not a tagged debug socket.

For each action in `action.list` (sorted by id, from `--start`), it runs the action with no
arguments, again with `focus: true`, then a few fuzzed values for each declared argument (empty,
huge, wrong type, out of range, a bogus target for target-kind arguments). After each call it checks that the app still
answers and presses Escape twice to close what the action opened. One JSON line per call goes to
`--out`. When the app stops answering, it prints `DEAD <index> <action>` and exits 3, so a caller
can relaunch the app and resume at the next index. Actions that end the app on purpose (quit,
relaunch, a debug crash) are skipped.

It attaches to an app already running through its debug socket; it never launches or quits it.

Usage: action-crash-sweep.py --socket /tmp/cmux-debug-<tag>[-capslot<N>].sock --out sweep.jsonl [--start 0] [--only id,id]
Exit status 0 when every action ran and the app answered after each; 3 when it died.
"""
import argparse, json, re, socket, sys, time

parser = argparse.ArgumentParser()
parser.add_argument("--socket", required=True)
parser.add_argument("--out", required=True)
parser.add_argument("--start", type=int, default=0)
parser.add_argument("--only", default="")
opts = parser.parse_args()

SKIP = re.compile(r"(?i)(^|\.)(quit|relaunch|restart|terminate|logout|signout|crash|abort|hang|freeze|spin|installupdate|update\.install|checkforupdates)")


def rpc(method, params=None, timeout=30):
    """One line-JSON request on the app's control socket; an error dict when it does not answer."""
    try:
        conn = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        conn.settimeout(timeout)
        conn.connect(opts.socket)
        conn.sendall((json.dumps({"id": 1, "method": method, "params": params or {}}) + "\n").encode())
        buf = b""
        while not buf.endswith(b"\n"):
            chunk = conn.recv(1 << 20)
            if not chunk:
                break
            buf += chunk
        conn.close()
        reply = json.loads(buf)
        return reply.get("result") if reply.get("ok") else {"error": reply.get("error")}
    except (OSError, ValueError) as error:
        return {"error": str(error), "unreachable": True}


def alive():
    for _ in range(3):
        if (rpc("debug.windows", timeout=10) or {}).get("windows") is not None:
            return True
        time.sleep(2)  # test harness: a busy main thread may answer late
    return False


def fuzz(argument):
    kind = argument.get("kind")
    if kind == "int":
        low, high = argument.get("min", 0), argument.get("max", 0)
        return [-1, 2**63 - 1, low - 1, high + 1, "seven"]
    if kind == "bool":
        return ["yes", None]
    if kind == "enum":
        return ["bogus-choice", ""]
    if kind == "target":
        return ["tab:nope", "workspace:", ""]
    return ["", "x" * 5000, "\u0000‮🙂", "../../../../etc/passwd"]


def calls(action):
    yield {}
    yield {"focus": True}
    for argument in action.get("arguments") or []:
        if not argument.get("name"):
            continue
        for value in fuzz(argument):
            yield {"args": {argument["name"]: value}}


def main():
    if not re.search(r"/cmux-debug-[\w.-]+\.sock$", opts.socket):
        sys.exit("refusing: only a tagged debug socket (/tmp/cmux-debug-<tag>[-capslot<N>].sock)")
    listed = rpc("action.list") or {}
    actions = sorted(listed.get("actions") or [], key=lambda a: a["id"])
    if not actions:
        sys.exit(f"action.list returned nothing: {json.dumps(listed)[:300]}")
    only = {a for a in opts.only.split(",") if a}
    with open(opts.out, "a") as out:
        for index, action in enumerate(actions):
            if index < opts.start or (only and action["id"] not in only):
                continue
            if SKIP.search(action["id"]):
                out.write(json.dumps({"index": index, "action": action["id"], "skipped": True}) + "\n")
                continue
            for extra in calls(action):
                params = {"action": action["id"], **extra}
                started = time.time()
                reply = rpc("action.run", params, timeout=20)
                seconds = round(time.time() - started, 2)
                up = alive()
                error = (reply or {}).get("error") if isinstance(reply, dict) else None
                record = {"index": index, "action": action["id"], "params": extra, "seconds": seconds, "alive": up,
                          "error": (error.get("code") if isinstance(error, dict) else error)}
                out.write(json.dumps(record) + "\n")
                out.flush()
                if not up:
                    print(f"DEAD {index} {action['id']} {json.dumps(extra)[:200]}", flush=True)
                    sys.exit(3)
                for _ in range(2):
                    rpc("debug.key", {"key": "escape"}, timeout=5)
            print(f"ok {index} {action['id']}", flush=True)
    print(f"DONE {len(actions)}", flush=True)


main()
