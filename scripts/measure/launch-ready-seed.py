#!/usr/bin/env python3
"""launch-ready.sh's session=stress3 seed: 3 windows holding 60 workspaces, in a running cmux NEXT app.

  launch-ready-seed.py SOCKET [--windows 3] [--workspaces 60]

SOCKET is the app's release control socket (launch-ready.swift starts the app with CMUX_NEXT_SOCKET_PATH set to
the short /tmp path launch-ready.sh gives it, and CMUX_NEXT_SOCKET_MODE allowAll). Only release socket methods: `snapshot.get`, `action.run` and `context.keys`.

It opens windows until there are --windows (newWindow), then makes --workspaces workspaces (workspace.newAtBottom, a
terminal each; the new id from the reply's `created`) and moves each to its window, as evenly as it can
(moveWorkspaceToWindow, `workspace:<id>` with the `window` argument), reading the window's members back after each
move. Then it shows Home in the front window (home.show acts on the active one), as the small session's front is
on its relaunches, so both sessions time the same front. On every way out it ends the app with Quit and Keep
Sessions, so the next launch with the same home is a person's relaunch of a 3-window, 60-workspace session
(cmuxterm-hq docs/design/launch-shell-first.md, stage 1).

Prints one `LR-SEED {json}` line: windows, this seed's workspaces in each window, the front, how long it took, and
`error` when the session it made is not that shape. Exit 0 when the shape holds, 1 when not, 2 when the socket never
answered.
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


class Seed:
    def __init__(self, path, windows, workspaces, front="home"):
        self.path, self.count, self.total, self.front = path, windows, workspaces, front
        self.row = {"windows_asked": windows, "workspaces_asked": workspaces, "front_asked": front}
        self.keys = {}

    def topology(self):
        reply = rpc(self.path, "snapshot.get", timeout=10)
        return (reply.get("topology") or {}) if isinstance(reply, dict) and not reply.get("error") else {}

    def front(self):
        """launch-ready.swift's front(): the focused workspace's key, its tab, the key window's top page, windows."""
        top = wait(self.topology, 1, 0.25)
        if not top:
            return {"error": "snapshot.get did not answer"}
        focus = top.get("focus") or {}
        focused = focus.get("workspace")
        key = next((w.get("key") for w in top.get("workspaces") or [] if w.get("id") == focused), None) or focused
        context = rpc(self.path, "context.keys", timeout=10)
        keys = (context.get("keys") or context) if isinstance(context, dict) and not context.get("error") else {}
        return {"workspace": key, "tab": focus.get("tab"), "top_page": keys.get("topPage"),
                "windows": len(top.get("windows") or [])}

    def window_ids(self):
        return [w.get("id") for w in self.topology().get("windows") or [] if w.get("id")]

    def members(self, window):
        found = next((w for w in self.topology().get("windows") or [] if w.get("id") == window), {})
        return set(found.get("workspaces") or [])

    def action(self, name, target=None, args=None, timeout=60):
        params = {"action": name, "origin": "script", "focus": True, "args": args or {}}
        if target:
            params["target"] = target
        reply = rpc(self.path, "action.run", params, timeout=timeout)
        if isinstance(reply, dict) and reply.get("error"):
            raise RuntimeError(f"{name}{' ' + target if target else ''}: {str(reply['error'])[:200]}")
        return reply if isinstance(reply, dict) else {}

    def close(self, key):
        """Closes the workspace whose model key (or id) is KEY and waits until the topology no longer lists it."""
        def find():
            return next((w.get("id") for w in self.topology().get("workspaces") or []
                         if key in (w.get("key"), w.get("id"))), None)
        workspace = find()
        if not workspace:
            raise RuntimeError(f"no workspace with key {key} to close")
        self.action("closeWorkspace", target=f"workspace:{workspace}")
        if not wait(lambda: find() is None, 10):
            raise RuntimeError(f"workspace {key} ({workspace}) still listed 10 s after closeWorkspace")
        self.row.update(closed=workspace, workspaces_left=len(self.topology().get("workspaces") or []))

    def build(self):
        """Raises RuntimeError naming the step that failed."""
        windows = self.window_ids()
        while len(windows) < self.count:
            self.action("newWindow")
            made = wait(lambda: next((w for w in self.window_ids() if w not in windows), None), 30)
            if not made:
                raise RuntimeError(f"newWindow made no window in 30 s (windows {windows})")
            windows.append(made)
        windows = windows[: self.count]
        self.keys = {w.get("id"): w.get("key") or w.get("id") for w in self.topology().get("windows") or []}
        ours = {w: set() for w in windows}
        for index in range(self.total):
            window = windows[index * len(windows) // self.total]
            created = [c for c in self.action("workspace.newAtBottom").get("created") or [] if str(c).startswith("ws_")]
            if len(created) != 1:
                raise RuntimeError(f"workspace.newAtBottom (workspace {index + 1}) created {created}, not one workspace")
            workspace = created[0]
            if workspace not in self.members(window):
                # The handler matches the window's model key (WindowState.id), which the target resolver also names it by.
                self.action("moveWorkspaceToWindow", target=f"workspace:{workspace}",
                            args={"window": f"window:{self.keys.get(window, window)}"})
                if not wait(lambda: workspace in self.members(window), 10):
                    raise RuntimeError(f"workspace {workspace} is not in window {window} 10 s after the move")
            ours[window].add(workspace)
        if self.front == "home":  # --front tab: the last workspace's terminal tab stays in front
            self.action("home.show")
        final = self.topology()
        listed = {w.get("id"): set(w.get("workspaces") or []) for w in final.get("windows") or []}
        mine = set().union(*ours.values())
        self.row.update(windows=len(listed), front=(final.get("focus") or {}).get("window"),
                        ours_per_window=[len(listed.get(w, set()) & mine) for w in windows],
                        members_per_window=[len(listed.get(w, set())) for w in windows])
        problems = []
        if len(listed) < self.count:
            problems.append(f"{len(listed)} windows, not {self.count}")
        if sum(self.row["ours_per_window"]) < self.total or min(self.row["ours_per_window"]) < self.total // self.count:
            problems.append(f"this seed's workspaces per window {self.row['ours_per_window']}, not {self.total} spread "
                            f"over {self.count}")
        if problems:
            raise RuntimeError("; ".join(problems))


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("socket")
    parser.add_argument("--windows", type=int, default=3)
    parser.add_argument("--workspaces", type=int, default=60)
    parser.add_argument("--front-out", help="write the front just before the quit here (launch-ready.swift's shape)")
    # launch-ready.sh front=home|tab: the front the session is left on, and --stay leaves the app running (the probe
    # quits it after reading that front).
    parser.add_argument("--front", choices=["home", "tab"], default="home")
    parser.add_argument("--stay", action="store_true")
    # launch-ready.sh snapshot=unknown: close the workspace with this model key (closeWorkspace), and nothing else.
    parser.add_argument("--close-workspace", default="")
    args = parser.parse_args(argv)
    started = time.monotonic()
    seed, code = Seed(args.socket, args.windows, args.workspaces, args.front), 0
    if args.close_workspace:
        seed.row = {"close_asked": args.close_workspace}
    if not wait(lambda: seed.topology().get("loaded") and seed.topology().get("windows"), 120, 0.25):
        seed.row["error"], code = "the control socket never answered with a loaded topology and a window in 120 s", 2
    else:
        try:
            if args.close_workspace:
                seed.close(args.close_workspace)
            else:
                seed.build()
        except RuntimeError as error:
            seed.row["error"], code = str(error), 1
        finally:
            time.sleep(1)  # measurement script: the session's save after the last change, before the quit
            # The seed quits the app itself, so the probe reads no front at its quit; this one is what run1 must reopen.
            if args.front_out:
                with open(args.front_out, "w") as out:
                    json.dump(seed.front(), out)
            if args.stay:
                seed.row["quit"] = "stay"
            else:
                # The app may end before it answers; then the reply is a read error, not a refused quit.
                reply = rpc(args.socket, "action.run", {"action": "quitKeepSessions", "origin": "script"}, timeout=20)
                seed.row["quit"] = str(reply["error"])[:200] if isinstance(reply, dict) and reply.get("error") else "ok"
    seed.row["seed_ms"] = round((time.monotonic() - started) * 1000)
    print("LR-SEED " + json.dumps(seed.row, sort_keys=True), flush=True)
    return code


if __name__ == "__main__":
    sys.exit(main())
