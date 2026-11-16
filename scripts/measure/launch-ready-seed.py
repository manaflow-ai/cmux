#!/usr/bin/env python3
"""launch-ready.sh's session=stress3 seed: 3 windows holding 60 workspaces, in a running cmux NEXT app.

  launch-ready-seed.py SOCKET [--windows 3] [--workspaces 60]

SOCKET is the app's release control socket (launch-ready.swift starts the app with CMUX_NEXT_SOCKET_PATH
HOME_ROOT/app.sock and CMUX_NEXT_SOCKET_MODE allowAll). Only release socket methods: `snapshot.get` and `action.run`.

It opens windows until there are --windows (newWindow), then puts --workspaces workspaces in them, as evenly as it can,
each made in its own window (workspace.newAtBottom aimed at `window:<id>`, a terminal each). Then it shows Home in
the front window (home.show), as the small session's front is on its relaunches, so both sessions time the same
front, and ends the app with Quit and Keep Sessions, so the next launch with the same home is a person's relaunch
of a 3-window, 60-workspace session (cmuxterm-hq docs/design/launch-shell-first.md, stage 1).

Prints one `LR-SEED {json}` line: windows, workspaces per window, the front, how long it took, and `error` when the
session it made is not that shape. Exit 0 when the shape holds, 1 when not, 2 when the socket never answered.
"""
import argparse, json, socket, sys, time


def rpc(path, method, params=None, timeout=60):
    """One request on the control socket (line JSON): the result, or {"error": ...}."""
    try:
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as conn:
            conn.settimeout(timeout)
            conn.connect(path)
            conn.sendall((json.dumps({"id": 1, "method": method, "params": params or {}}) + "\n").encode())
            buf = b""
            while not buf.endswith(b"\n"):
                chunk = conn.recv(1 << 22)
                if not chunk:
                    break
                buf += chunk
        reply = json.loads(buf)
    except (OSError, ValueError) as error:
        return {"error": str(error)}
    return reply.get("result") if reply.get("ok") else {"error": reply.get("error")}


def wait(check, seconds, step=0.1):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:  # measurement script: a bounded wait for the app's own state
        value = check()
        if value:
            return value
        time.sleep(step)
    return None


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("socket")
    parser.add_argument("--windows", type=int, default=3)
    parser.add_argument("--workspaces", type=int, default=60)
    args = parser.parse_args(argv)
    started = time.monotonic()
    row = {"windows_asked": args.windows, "workspaces_asked": args.workspaces}

    def done(code, error=None):
        if error:
            row["error"] = error
        row["seed_ms"] = round((time.monotonic() - started) * 1000)
        print("LR-SEED " + json.dumps(row, sort_keys=True), flush=True)
        return code

    def topology():
        reply = rpc(args.socket, "snapshot.get", timeout=10)
        return (reply.get("topology") or {}) if isinstance(reply, dict) and not reply.get("error") else {}

    def action(name, target=None, timeout=60):
        params = {"action": name, "origin": "script", "focus": True}
        if target:
            params["target"] = target
        return rpc(args.socket, "action.run", params, timeout=timeout)

    def refused(reply):
        return isinstance(reply, dict) and reply.get("error")

    if not wait(lambda: topology().get("loaded") and topology().get("windows"), 120, 0.25):
        return done(2, "the control socket never answered with a loaded topology and a window in 120 s")
    windows = [w["id"] for w in topology()["windows"]]
    while len(windows) < args.windows:
        reply = action("newWindow")
        if refused(reply):
            return done(1, f"newWindow: {str(reply['error'])[:200]}")
        made = wait(lambda: next((w["id"] for w in topology().get("windows") or [] if w["id"] not in windows), None), 30)
        if not made:
            return done(1, f"newWindow made no window in 30 s (windows {windows})")
        windows.append(made)
    windows = windows[: args.windows]
    known = {w["id"] for w in topology().get("workspaces") or []}
    made_in = {w: 0 for w in windows}
    for index in range(args.workspaces):
        window = windows[index * len(windows) // args.workspaces]
        reply = action("workspace.newAtBottom", target=f"window:{window}")
        if refused(reply):
            return done(1, f"workspace.newAtBottom in {window} (workspace {index + 1}): {str(reply['error'])[:200]}")
        fresh = wait(lambda: [w["id"] for w in topology().get("workspaces") or [] if w["id"] not in known], 30)
        if not fresh:
            return done(1, f"workspace {index + 1} never appeared in 30 s")
        known.update(fresh)
        made_in[window] += 1
    reply = action("home.show", target=f"window:{windows[0]}")
    if refused(reply):
        return done(1, f"home.show: {str(reply['error'])[:200]}")
    final = topology()
    shown = {w["id"]: w for w in final.get("windows") or []}
    row.update(windows=len(shown), made_per_window=list(made_in.values()),
               workspaces=len([w for w in final.get("workspaces") or [] if (w.get("screens") or [])]),
               members_per_window=[len(shown.get(w, {}).get("workspaces") or []) for w in windows],
               front=(final.get("focus") or {}).get("window"), home_window=windows[0])
    problems = []
    if len(shown) < args.windows:
        problems.append(f"{len(shown)} windows, not {args.windows}")
    if row["workspaces"] < args.workspaces:
        problems.append(f"{row['workspaces']} workspaces with a pane, not {args.workspaces}")
    if any(count < args.workspaces // args.windows for count in row["members_per_window"]):
        problems.append(f"a window lists fewer than {args.workspaces // args.windows} workspaces: {row['members_per_window']}")
    time.sleep(1)  # measurement script: the session's save after the last change, before the quit
    reply = rpc(args.socket, "action.run", {"action": "quitKeepSessions", "origin": "script"}, timeout=20)
    row["quit"] = str(reply.get("error"))[:200] if refused(reply) else "ok"
    return done(1 if problems else 0, "; ".join(problems) or None)


if __name__ == "__main__":
    sys.exit(main())
