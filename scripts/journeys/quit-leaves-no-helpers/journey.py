#!/usr/bin/env python3
"""Journey quit-leaves-no-helpers (P0): launch, use a terminal and an agent pane, quit normally, and
check that no process of the app bundle runs 5 s later except the documented survivors.

Runs on the Mac where the app runs (a capture slot; run.py beside this file leases it and starts this
with the stock /usr/bin/python3, standard library only), against the app's control socket:

    journey.py --socket S --app APP --out DIR [--quit applescript|menu] [--settle 5] [--keep-processes]

A person's quit: `quit app id <bundle id>` (the Apple event Cmd-Q, the Dock and `osascript` send), else,
when this session may not send Apple events to the app, `debug.quit {open: true}` (the same interactive
quit). When the quit question shows, the journey answers its default (Keep Sessions Running), as a
person pressing Return does.

The processes of the app are found as scripts/cmux-next/tag_teardown.py finds them (by bundle path,
terminal host `--owner`, holder socket, one level of children), never by name.

Documented survivors of a quit that keeps sessions (plans/cmux-next/quit-persistence.md):
  - the app's cmux-tui daemon (`cmux-tui --headless --session cmux-app-...`) and its terminal hosts,
    holders and their shells: the terminals the person chose to keep; they reattach at the next launch.
    With it, its `cmux-agent-screen-detection` plugin, which reads those terminals' screens and ends
    with the daemon;
  - the acpmux daemon and its agent hosts, and the Chief (`optchat-chief host`, its acpmux and router,
    its `cmux-chief-*` conversation owner), only while they work (a turn, a queued prompt, a pending
    permission, a subagent or a background process an agent started): `keep sessions` keeps agents
    and the Chief working. Idle, each exits a few seconds after the app (cp/lag-quit-helpers,
    cp/quit-chief-idle). The journey starts no turn, so all of them must be gone.
Anything else (an idle acpmux or Chief, a Chromium or app host, a helper under Resources/bin) is a leak.

Writes DIR/result.json; exit 0 pass, 1 fail, 2 the journey could not run.
"""
import argparse
import json
import os
import socket
import subprocess
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import tag_teardown  # noqa: E402  (shipped beside this file by run.py)

RPC_TIMEOUT = 30.0


def rpc(sock, method, params=None, timeout=RPC_TIMEOUT):
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as conn:
        conn.settimeout(timeout)
        conn.connect(sock)
        conn.sendall((json.dumps({"id": 1, "method": method, "params": params or {}}) + "\n").encode())
        buf = b""
        while not buf.endswith(b"\n"):
            chunk = conn.recv(1 << 20)
            if not chunk:
                break
            buf += chunk
    reply = json.loads(buf or b"{}")
    if not reply.get("ok", "result" in reply):
        raise RuntimeError(f"{method}: {reply.get('error') or 'no answer'}")
    return reply.get("result")


def alive(pid):
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    # A zombie still answers kill 0; ps says Z.
    stat = subprocess.run(["ps", "-o", "stat=", "-p", str(pid)], capture_output=True, text=True).stdout.strip()
    return bool(stat) and not stat.startswith("Z")


def executable(teardown, command):
    rel = teardown._relative(command)
    words = (rel or command).split()
    return rel, words, (os.path.basename(words[0]) if words else "")


def classify(teardown, pid, rows):
    """(role, documented survivor?) of one process of the app after the quit. `rows` maps every surviving
    pid to its `command` and `ppid`, so a helper is judged by the process that runs it."""
    command = rows[pid]["command"]
    rel, words, exe = executable(teardown, command)

    def exe_of(p):
        return executable(teardown, rows[p]["command"])[2] if p in rows else ""
    ppid = rows[pid].get("ppid")
    parent_exe = exe_of(ppid)
    grandparent_exe = exe_of(rows[ppid].get("ppid")) if ppid in rows else ""
    if rel is not None and exe == "cmux-tui" and "--headless" in words:
        if any(w.startswith("cmux-chief-") for w in words) or "cmux-chief-" in command:
            # The Chief's conversation owner: it holds no terminal of the person's and stops after
            # the app when nothing needs it (cmux-tui headless/chief_owner_exit.rs).
            return "the Chief's conversation owner with nothing live", False
        return "cmux-tui daemon (kept terminals)", True
    if rel is None:
        # A terminal host, holder or a shell under one (tag_teardown matched it by --owner, socket or parent).
        if "__terminal-host" in command or teardown._is_holder(command):
            return "terminal host or holder (kept terminals)", True
        return "terminal shell or its child (kept terminals)", True
    if exe == "cmux-agent-screen-detection" and parent_exe == "cmux-tui":
        if "cmux-chief-" in rows[ppid]["command"]:
            return "screen-detection plugin of the Chief's conversation owner", False
        # The kept daemon's agent plugin: it reads the kept terminals' screens and ends with its daemon.
        return "screen-detection plugin of a kept cmux-tui daemon", True
    if exe == "optchat-chief":
        # An idle Chief stops after its app (optchat-chief owner_app.rs); the journey starts no turn.
        return "Chief brain host with no live work", False
    if exe == "acpmux" and parent_exe == "optchat-chief":
        return "the Chief's own acpmux with no live work", False
    if exe == "acpmux" and "router" in words and parent_exe == "acpmux" and grandparent_exe == "optchat-chief":
        return "the Chief's acpmux router with no live work", False
    if exe == "acpmux" and "daemon" in words:
        return "the app's acpmux daemon with no live agent", False
    return f"{exe} (helper)", False


def table_row(pid):
    out = subprocess.run(["ps", "-o", "ppid=,pgid=,stat=", "-p", str(pid)], capture_output=True, text=True).stdout.split()
    return {"ppid": int(out[0]), "pgid": int(out[1]), "stat": out[2]} if len(out) >= 3 else {}


def wait_for(predicate, timeout, interval=0.25):
    end = time.monotonic() + timeout
    while time.monotonic() < end:
        value = predicate()
        if value:
            return value
        time.sleep(interval)
    return predicate()


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--socket", required=True)
    ap.add_argument("--app", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--quit", choices=("applescript", "menu"), default="applescript")
    ap.add_argument("--settle", type=float, default=5.0, help="seconds after the app exits before the check")
    ap.add_argument("--keep-processes", action="store_true", help="leave the survivors running (default: end them)")
    a = ap.parse_args(argv)
    os.makedirs(a.out, exist_ok=True)
    result = {"id": "quit-leaves-no-helpers", "priority": "P0", "steps": [], "status": "not run", "reason": ""}

    def step(name, **facts):
        facts["step"], facts["t"] = name, round(time.monotonic() - t0, 3)
        result["steps"].append(facts)
        print(f"journey: {name} {json.dumps({k: v for k, v in facts.items() if k not in ('step', 't')})[:400]}", flush=True)

    t0 = time.monotonic()
    teardown = tag_teardown.TagTeardown(a.app, log=lambda line: step("teardown", line=line))
    try:
        info = rpc(a.socket, "system.identify") or {}
        app_pid, bundle_id = int(info["pid"]), info.get("bundle_id") or teardown.bundle_id()
        if ".debug" not in (bundle_id or ""):
            raise SystemExit(f"journey: refusing {a.app} ({bundle_id}): not a tagged DEV build")
        step("identify", pid=app_pid, bundle_id=bundle_id, tag=info.get("tag"))

        # 1. Use a terminal: a new tab, a command typed key by key.
        nonce = str(int(time.time()))[-6:]
        rpc(a.socket, "action.run", {"action": "newTab", "args": {"name": "jr-quit", "focus": True}})
        time.sleep(1.0)
        for char in f"echo quit-{nonce}":
            rpc(a.socket, "debug.key", {"key": char, "modifiers": []})
        rpc(a.socket, "debug.key", {"key": "return", "modifiers": []})

        def echoed():
            report = rpc(a.socket, "debug.surfaces", {"text": True}) or {}
            panes = [p for w in report.get("windows", []) for p in w.get("panes", []) if isinstance(p, dict)]
            return any(f"quit-{nonce}" in (p.get("text") or "") for p in panes)
        step("terminal", echoed=bool(wait_for(echoed, 20)))

        # 2. Use an agent pane: the New Agent Chat a person opens (it starts the app's acpmux daemon).
        try:
            reply = rpc(a.socket, "action.run", {"action": "palette.newAgentChat"})
        except RuntimeError as error:
            reply = {"error": str(error)}
        acpmux = os.path.join(teardown.bin, "acpmux")
        started = wait_for(lambda: [p for p, c in teardown.processes() if c.startswith(acpmux + " daemon run")], 60, 0.5)
        step("agent pane", reply=reply, acpmux_pids=started)

        before = teardown.remember()
        step("before quit", processes=[{"pid": p, "command": teardown.shown(c)} for p, c in before])

        # 3. Quit normally.
        quitter, how = None, a.quit
        if a.quit == "applescript":
            quitter = subprocess.Popen(["/usr/bin/osascript", "-e", f'tell application id "{bundle_id}" to quit'],
                                       stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
            time.sleep(2.0)
            if quitter.poll() not in (None, 0):
                step("applescript quit refused", stderr=quitter.stderr.read()[-300:])
                quitter, how = None, "menu"
        if how == "menu":
            rpc(a.socket, "debug.quit", {"open": True})
        pressed = None

        def asked_or_gone():
            nonlocal pressed
            if not alive(app_pid):
                return True
            try:
                report = rpc(a.socket, "debug.quit", timeout=5) or {}
            except (OSError, RuntimeError, ValueError):
                return False
            if report.get("asking") and pressed is None:
                pressed = report.get("prompt", {}).get("default") or "keep"
                rpc(a.socket, "debug.quit", {"press": "keep"}, timeout=5)
                step("quit question", prompt=report.get("prompt"), lines=report.get("lines"), pressed="keep")
            return False
        exited = wait_for(asked_or_gone, 60, 0.25)
        step("quit", how=how, app_exited=bool(exited))
        if quitter is not None and quitter.poll() is None:
            quitter.kill()
        if not exited:
            result.update(status="fail", reason="the app did not exit within 60 s of the quit")
            return 1

        # 4. Settle, then every process of the app bundle.
        time.sleep(a.settle)
        after = teardown.processes()
        rows = {pid: {"command": command, **table_row(pid)} for pid, command in after}
        survivors = []
        for pid, row in rows.items():
            role, documented = classify(teardown, pid, rows)
            survivors.append({"pid": pid, "command": teardown.shown(row["command"]), "role": role,
                              "documented": documented, **{k: v for k, v in row.items() if k != "command"}})
        leaks = [s for s in survivors if not s["documented"]]
        step("after quit", settle_seconds=a.settle, survivors=survivors)
        result["survivors"], result["leaks"] = survivors, leaks
        if leaks:
            result.update(status="fail", reason=f"{len(leaks)} process(es) of the app outlived the quit: "
                          + ", ".join(f"{s['pid']} {s['role']}" for s in leaks))
        else:
            result.update(status="pass", reason="only documented survivors remain"
                          + (f" ({len(survivors)}: kept terminals)" if survivors else " (none)"))
        return 0 if not leaks else 1
    except (OSError, RuntimeError, KeyError, ValueError) as error:
        result.update(status="not run", reason=str(error)[-400:])
        return 2
    finally:
        if not a.keep_processes:
            teardown.end()
        result["seconds"] = round(time.monotonic() - t0, 2)
        with open(os.path.join(a.out, "result.json"), "w") as f:
            json.dump(result, f, indent=1, default=str)
            f.write("\n")
        print(f"journey quit-leaves-no-helpers: {result['status']} {result['reason']}", flush=True)


if __name__ == "__main__":
    sys.exit(main())
